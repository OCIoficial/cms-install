<script lang="ts">
  // Vista previa: valores normalizados, qué pasará con cada fila y errores por
  // celda. Los errores se corrigen en la planilla y se vuelve a pegar.
  import { FIELDS, type Field, type RowResult, type Team } from "./api";

  let {
    results,
    mapped,
    withContest,
    teams,
    firstRowNumber,
  }: {
    results: RowResult[];
    mapped: Field[];
    withContest: boolean;
    teams: Team[];
    firstRowNumber: number;
  } = $props();

  let onlyErrors = $state(false);
  let showPasswords = $state(false);

  const teamName = $derived(new Map(teams.map((t) => [t.code, t.name])));
  const shown = $derived(FIELDS.filter((f) => mapped.includes(f.key)));
  const rows = $derived(
    results
      .map((r, i) => ({ r, number: firstRowNumber + i }))
      .filter(({ r }) => !onlyErrors || Object.keys(r.errors).length > 0),
  );

  const PARTICIPATION = {
    new: { text: "Joins contest", kind: "ok" },
    team: { text: "Region changes", kind: "warn" },
    same: { text: "Already in contest", kind: "muted" },
  } as const;
</script>

<div class="toolbar">
  <label><input type="checkbox" bind:checked={onlyErrors} /> Only rows with errors</label>
  {#if mapped.includes("password")}
    <label><input type="checkbox" bind:checked={showPasswords} /> Show passwords</label>
  {/if}
</div>

<div class="table-wrap">
  <table>
    <thead>
      <tr>
        <th class="num">Row</th>
        <th>Result</th>
        {#each shown as f (f.key)}
          <th class:ignored={f.key === "region" && !withContest}>{f.label}</th>
        {/each}
      </tr>
    </thead>
    <tbody>
      {#each rows as { r, number } (number)}
        <tr class:has-error={Object.keys(r.errors).length > 0}>
          <td class="num">{number}</td>
          <td class="status">
            {#if r.user === "new"}
              <span class="chip ok">New user</span>
            {:else}
              <span class="chip muted">Existing user</span>
            {/if}
            {#if r.participation}
              <span class="chip {PARTICIPATION[r.participation].kind}">
                {PARTICIPATION[r.participation].text}
              </span>
            {/if}
          </td>
          {#each shown as f (f.key)}
            {@const value = r.values[f.key] ?? ""}
            {@const error = r.errors[f.key]}
            <td class:error={error} class:ignored={f.key === "region" && !withContest}>
              {#if f.key === "password" && !showPasswords && value}
                <span class="value">{"•".repeat(Math.min(value.length, 12))}</span>
              {:else if f.key === "region" && !withContest}
                <span class="value">{value}</span>
              {:else if f.key === "region"}
                <span class="value">{value}</span>
                {#if !error}
                  <span class="team">
                    {r.team ? `→ ${teamName.get(r.team) ?? r.team}` : "no region"}
                  </span>
                {/if}
              {:else}
                <span class="value">{value}</span>
              {/if}
              {#if error}<div class="message">{error}</div>{/if}
            </td>
          {/each}
        </tr>
      {:else}
        <tr><td class="empty" colspan={shown.length + 2}>No rows with errors.</td></tr>
      {/each}
    </tbody>
  </table>
</div>

{#if !withContest && mapped.includes("region")}
  <p class="note">Without a contest, the Region column is ignored.</p>
{/if}

<style>
  .toolbar {
    display: flex;
    gap: 1.25rem;
    margin-bottom: 0.5rem;
    font-size: 0.9rem;
  }

  .table-wrap {
    overflow: auto;
    max-height: 60vh;
    border: 1px solid var(--border);
    border-radius: var(--radius);
    background: var(--surface);
  }

  table {
    border-collapse: collapse;
    width: 100%;
    font-size: 0.9rem;
  }

  th,
  td {
    padding: 0.4rem 0.6rem;
    border-bottom: 1px solid var(--border);
    text-align: left;
    vertical-align: top;
  }

  th {
    position: sticky;
    top: 0;
    background: var(--bg);
    font-weight: 600;
    z-index: 1;
  }

  .num {
    color: var(--muted);
    width: 3.5rem;
  }

  tr.has-error .num {
    box-shadow: inset 3px 0 var(--error);
  }

  .status {
    white-space: nowrap;
  }

  .chip {
    display: inline-block;
    font-size: 0.75rem;
    border-radius: 999px;
    padding: 0.05rem 0.5rem;
    margin-right: 0.25rem;
  }

  .chip.ok {
    background: var(--ok-soft);
    color: var(--ok);
  }

  .chip.warn {
    background: var(--warn-soft);
    color: var(--warn);
  }

  .chip.muted {
    background: var(--bg);
    color: var(--muted);
  }

  td.error {
    background: var(--error-soft);
  }

  .message {
    color: var(--error);
    font-size: 0.8rem;
  }

  .team {
    color: var(--muted);
    font-size: 0.8rem;
    margin-left: 0.25rem;
  }

  .ignored {
    color: var(--muted);
    text-decoration: line-through;
  }

  .empty {
    color: var(--muted);
    text-align: center;
  }

  .note {
    color: var(--muted);
    font-size: 0.85rem;
  }
</style>
