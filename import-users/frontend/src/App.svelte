<script lang="ts">
  import { onMount } from "svelte";
  import {
    ApiError,
    FIELDS,
    getMeta,
    preview,
    runImport,
    type CheckResponse,
    type Field,
    type ImportResponse,
    type Meta,
    type Payload,
  } from "./lib/api";
  import ColumnMapper, { type Column } from "./lib/ColumnMapper.svelte";
  import PreviewTable from "./lib/PreviewTable.svelte";
  import { columnLetter, parseTsv } from "./lib/tsv";

  const emptyMapping = () =>
    Object.fromEntries(FIELDS.map((f) => [f.key, null])) as Record<Field, number | null>;

  let meta = $state<Meta | null>(null);
  let fatal = $state<{ message: string; login?: string } | null>(null);

  let grid = $state<string[][]>([]);
  let hasHeader = $state(false);
  let mapping = $state(emptyMapping());
  let contestId = $state<number | null>(null);

  let checked = $state<{ key: string; data: CheckResponse } | null>(null);
  let checking = $state(false);
  let checkError = $state<string | null>(null);

  let importing = $state(false);
  let imported = $state<ImportResponse | null>(null);
  let importError = $state<string | null>(null);

  const dataRows = $derived(hasHeader ? grid.slice(1) : grid);
  const columns: Column[] = $derived(
    (grid[0] ?? []).map((_, i) => ({
      index: i,
      label: (hasHeader && grid[0][i].trim()) || columnLetter(i),
      samples: dataRows.slice(0, 3).map((r) => r[i]),
    })),
  );
  const mapped = $derived(FIELDS.map((f) => f.key).filter((k) => mapping[k] !== null));

  const payload: Payload | null = $derived.by(() => {
    if (mapping.username === null || dataRows.length === 0) return null;
    return {
      contest_id: contestId,
      mapped,
      rows: dataRows.map((r) => Object.fromEntries(mapped.map((k) => [k, r[mapping[k]!]]))),
    };
  });
  const payloadKey = $derived(payload ? JSON.stringify(payload) : "");
  const current = $derived(checked && checked.key === payloadKey ? checked.data : null);
  const canImport = $derived(
    !!current && current.summary.errors === 0 && !checking && !importing,
  );

  function handleError(e: unknown): string {
    if (e instanceof ApiError && e.status === 401) {
      fatal = { message: e.message, login: String(e.body.login ?? "/login") };
    } else if (e instanceof ApiError && e.status === 403) {
      fatal = { message: e.message };
    }
    return e instanceof Error ? e.message : String(e);
  }

  onMount(async () => {
    try {
      meta = await getMeta();
    } catch (e) {
      const message = handleError(e);
      fatal ??= { message };
    }
  });

  // Vista previa: se pide de nuevo (con una pausa) cada vez que cambian las
  // filas, las columnas asignadas o el concurso. Solo vale la última respuesta.
  let sequence = 0;
  $effect(() => {
    const key = payloadKey;
    const body = payload;
    checkError = null;
    if (!body) {
      checking = false;
      return;
    }
    const mine = ++sequence;
    checking = true;
    const timer = setTimeout(async () => {
      try {
        const data = await preview(body);
        if (mine === sequence) checked = { key, data };
      } catch (e) {
        if (mine === sequence) checkError = handleError(e);
      } finally {
        if (mine === sequence) checking = false;
      }
    }, 300);
    return () => clearTimeout(timer);
  });

  function loadText(text: string) {
    const parsed = parseTsv(text);
    if (parsed.length === 0) return;
    const width = parsed[0].length;
    // Si se vuelve a pegar (p. ej. después de corregir la planilla), se
    // mantienen las columnas asignadas que todavía existen
    const next = { ...mapping };
    for (const f of FIELDS) if (next[f.key] !== null && next[f.key]! >= width) next[f.key] = null;
    mapping = next;
    grid = parsed;
    imported = null;
    importError = null;
  }

  function onPaste(e: ClipboardEvent) {
    const target = e.target as HTMLElement | null;
    if (target?.closest("input, select, textarea")) return;
    const text = e.clipboardData?.getData("text/plain");
    if (!text) return;
    e.preventDefault();
    loadText(text);
  }

  async function pasteButton() {
    try {
      loadText(await navigator.clipboard.readText());
    } catch {
      alert("The browser didn't allow reading the clipboard. Use Ctrl+V instead.");
    }
  }

  function clearAll() {
    grid = [];
    checked = null;
    imported = null;
    importError = null;
  }

  async function doImport() {
    if (!payload || !current) return;
    const s = current.summary;
    const contest = meta?.contests.find((c) => c.id === contestId);
    const lines = [
      `${s.users_created} new users`,
      contest ? `${s.participations_created} added to “${contest.name}”` : null,
      contest && s.teams_changed ? `${s.teams_changed} region changes` : null,
    ].filter(Boolean);
    if (!confirm(`Import ${s.rows} rows?\n\n${lines.join("\n")}`)) return;
    importing = true;
    importError = null;
    try {
      imported = await runImport(payload);
      grid = [];
      checked = null;
    } catch (e) {
      importError = handleError(e);
      if (e instanceof ApiError && e.body.rows) {
        checked = { key: payloadKey, data: e.body as unknown as CheckResponse };
      }
    } finally {
      importing = false;
    }
  }
</script>

<svelte:window onpaste={onPaste} />

<header>
  <div class="wrap header-row">
    <h1>Import users</h1>
    <nav>
      {#if meta}<span class="admin">{meta.admin}</span>{/if}
      <a href="/">Admin panel</a>
    </nav>
  </div>
</header>

<main class="wrap">
  {#if fatal}
    <div class="banner error">
      {fatal.message}
      {#if fatal.login}<a href={fatal.login}>Log in</a>{/if}
    </div>
  {:else if !meta}
    <p class="muted">Loading…</p>
  {:else}
    {#if imported}
      {@const s = imported.summary}
      <section class="banner ok">
        <strong>Import done.</strong>
        {s.users_created} users created, {s.participations_created} added to the contest,
        {s.teams_changed} region changes, {s.unchanged} unchanged.
        {#if imported.ranking_notified === false}
          <div class="small">
            The ranking wasn't updated because CMS isn't attached to this contest. It will
            get the users when the contest is activated (<code>contest_id</code>).
          </div>
        {/if}
      </section>
    {/if}

    <section>
      <h2><span class="step">1</span> Paste the rows</h2>
      {#if grid.length === 0}
        <div class="paste-zone" tabindex="0" role="button" aria-label="Paste area">
          <p>
            Copy the cells in Google Sheets (<kbd>Ctrl</kbd>+<kbd>C</kbd>) and press
            <kbd>Ctrl</kbd>+<kbd>V</kbd> anywhere on this page.
          </p>
          <button onclick={pasteButton}>Paste from clipboard</button>
        </div>
      {:else}
        <div class="pasted">
          <span>
            {dataRows.length} rows × {columns.length} columns.
            Paste again to replace them (column assignments are kept).
          </span>
          <label><input type="checkbox" bind:checked={hasHeader} /> First row is a header</label>
          <button onclick={clearAll}>Clear</button>
        </div>
      {/if}
    </section>

    {#if grid.length > 0}
      <section>
        <h2><span class="step">2</span> Assign columns</h2>
        <p class="muted">Drag each column onto its field. Columns left unassigned are ignored.</p>
        <ColumnMapper {columns} bind:mapping />
      </section>

      <section>
        <h2><span class="step">3</span> Contest</h2>
        <select
          value={contestId === null ? "" : String(contestId)}
          onchange={(e) => (contestId = e.currentTarget.value ? Number(e.currentTarget.value) : null)}
        >
          <option value="">No contest (only create users)</option>
          {#each meta.contests as c (c.id)}
            <option value={String(c.id)}>{c.name} — {c.description}</option>
          {/each}
        </select>
        <p class="muted small">
          Users that already exist are only added to the contest, if their data matches.
          If they're already in it, their region is updated.
        </p>
      </section>

      <section>
        <h2><span class="step">4</span> Check and import</h2>
        {#if mapping.username === null}
          <p class="muted">Assign a column to <strong>Username</strong> to see the preview.</p>
        {:else}
          {#if checkError}<div class="banner error">{checkError}</div>{/if}
          {#if importError}<div class="banner error">{importError}</div>{/if}
          {#if current || checked}
            {@const data = current ?? checked!.data}
            {@const s = data.summary}
            <div class="summary" class:stale={!current}>
              <span><strong>{s.rows}</strong> rows</span>
              <span class:bad={s.errors > 0}><strong>{s.errors}</strong> with errors</span>
              <span><strong>{s.users_created}</strong> new users</span>
              {#if contestId !== null}
                <span><strong>{s.participations_created}</strong> join the contest</span>
                <span><strong>{s.teams_changed}</strong> region changes</span>
              {/if}
              <span><strong>{s.unchanged}</strong> unchanged</span>
              <span class="spacer"></span>
              {#if checking}<span class="muted">Checking…</span>{/if}
              <button class="primary" disabled={!canImport} onclick={doImport}>
                {importing ? "Importing…" : "Import"}
              </button>
            </div>
            {#if s.errors > 0}
              <p class="small bad">Fix the errors in the spreadsheet and paste again.</p>
            {/if}
            <PreviewTable
              results={data.rows}
              {mapped}
              withContest={contestId !== null}
              teams={meta.teams}
              firstRowNumber={hasHeader ? 2 : 1}
            />
          {:else if checking}
            <p class="muted">Checking…</p>
          {/if}
        {/if}
      </section>
    {/if}
  {/if}
</main>

<style>
  .wrap {
    max-width: 1200px;
    margin: 0 auto;
    padding: 0 16px;
  }

  header {
    background: var(--surface);
    border-bottom: 1px solid var(--border);
  }

  .header-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    height: 56px;
  }

  h1 {
    font-size: 1.2rem;
    margin: 0;
  }

  nav {
    display: flex;
    gap: 1rem;
    align-items: center;
  }

  .admin {
    color: var(--muted);
  }

  main {
    padding-top: 1.25rem;
    padding-bottom: 3rem;
  }

  section {
    margin-bottom: 1.75rem;
  }

  h2 {
    font-size: 1.05rem;
    margin: 0 0 0.6rem;
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }

  .step {
    display: inline-grid;
    place-items: center;
    width: 1.5rem;
    height: 1.5rem;
    border-radius: 50%;
    background: var(--accent);
    color: #fff;
    font-size: 0.8rem;
  }

  .muted {
    color: var(--muted);
  }

  .small {
    font-size: 0.85rem;
  }

  .bad {
    color: var(--error);
  }

  .paste-zone {
    border: 2px dashed var(--border);
    border-radius: var(--radius);
    background: var(--surface);
    padding: 2rem 1rem;
    text-align: center;
  }

  .paste-zone:focus {
    outline: none;
    border-color: var(--accent);
  }

  .pasted {
    display: flex;
    flex-wrap: wrap;
    gap: 1rem;
    align-items: center;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 0.6rem 0.8rem;
  }

  kbd {
    border: 1px solid var(--border);
    border-bottom-width: 2px;
    border-radius: 4px;
    padding: 0 0.3rem;
    background: var(--bg);
    font-size: 0.85em;
  }

  .banner {
    border-radius: var(--radius);
    padding: 0.7rem 0.9rem;
    margin-bottom: 1rem;
  }

  .banner.error {
    background: var(--error-soft);
    color: var(--error);
  }

  .banner.ok {
    background: var(--ok-soft);
    color: var(--ok);
  }

  .summary {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 0.5rem 1.25rem;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 0.6rem 0.8rem;
    margin-bottom: 0.6rem;
  }

  .summary.stale {
    opacity: 0.6;
  }

  .spacer {
    flex: 1;
  }

  main > section > select {
    min-width: min(100%, 420px);
  }
</style>
