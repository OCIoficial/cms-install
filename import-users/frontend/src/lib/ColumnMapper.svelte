<script lang="ts">
  // Columnas pegadas (tarjetas que se arrastran) y los campos fijos donde se
  // sueltan. Cada columna va a lo más en un campo. Arrastrar una tarjeta de
  // vuelta a la lista de columnas la desasigna. Los <select> de cada campo
  // hacen lo mismo sin arrastrar.
  import { FIELDS, type Field } from "./api";

  export interface Column {
    index: number;
    label: string;
    samples: string[];
  }

  let {
    columns,
    mapping = $bindable(),
  }: { columns: Column[]; mapping: Record<Field, number | null> } = $props();

  const MIME = "application/x-cms-column";
  let dragging = $state<number | null>(null);
  let over = $state<Field | "pool" | null>(null);

  const fieldOf = (col: number) => FIELDS.find((f) => mapping[f.key] === col);

  function assign(field: Field, col: number | null) {
    const next = { ...mapping };
    for (const f of FIELDS) if (col !== null && next[f.key] === col) next[f.key] = null;
    next[field] = col;
    mapping = next;
  }

  function unassign(col: number) {
    const f = fieldOf(col);
    if (f) assign(f.key, null);
  }

  function onDragStart(e: DragEvent, col: number) {
    e.dataTransfer!.setData(MIME, String(col));
    e.dataTransfer!.effectAllowed = "move";
    dragging = col;
  }

  function onDragEnd() {
    dragging = null;
    over = null;
  }

  function droppedColumn(e: DragEvent): number | null {
    const raw = e.dataTransfer?.getData(MIME);
    return raw ? Number(raw) : null;
  }

  function onDragOver(e: DragEvent, target: Field | "pool") {
    if (!e.dataTransfer?.types.includes(MIME)) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = "move";
    over = target;
  }

  function onDrop(e: DragEvent, target: Field | "pool") {
    e.preventDefault();
    const col = droppedColumn(e);
    over = null;
    if (col === null) return;
    if (target === "pool") unassign(col);
    else assign(target, col);
  }

  function onSelect(field: Field, value: string) {
    assign(field, value === "" ? null : Number(value));
  }
</script>

{#snippet card(col: Column, compact: boolean)}
  <div
    class="card"
    class:compact
    class:dragging={dragging === col.index}
    draggable="true"
    role="listitem"
    aria-label={`Column ${col.label}`}
    ondragstart={(e) => onDragStart(e, col.index)}
    ondragend={onDragEnd}
  >
    <div class="card-label">{col.label}</div>
    {#if !compact}
      <ul class="samples">
        {#each col.samples as s}
          <li>{s || "—"}</li>
        {/each}
      </ul>
    {:else if col.samples[0]}
      <div class="first-sample">{col.samples[0]}</div>
    {/if}
  </div>
{/snippet}

<div class="targets">
  {#each FIELDS as f (f.key)}
    {@const col = mapping[f.key] === null ? undefined : columns[mapping[f.key]!]}
    <div
      class="slot"
      class:filled={col}
      class:over={over === f.key}
      role="group"
      aria-label={f.label}
      ondragover={(e) => onDragOver(e, f.key)}
      ondragleave={() => (over = null)}
      ondrop={(e) => onDrop(e, f.key)}
    >
      <div class="slot-head">
        <span class="slot-label">{f.label}</span>
        <span class="slot-hint">{f.hint}</span>
      </div>
      {#if col}
        {@render card(col, true)}
      {:else}
        <div class="placeholder">Drop a column here</div>
      {/if}
      <select
        aria-label={`Column for ${f.label}`}
        value={mapping[f.key] === null ? "" : String(mapping[f.key])}
        onchange={(e) => onSelect(f.key, e.currentTarget.value)}
      >
        <option value="">—</option>
        {#each columns as c (c.index)}
          <option value={String(c.index)}>{c.label}</option>
        {/each}
      </select>
    </div>
  {/each}
</div>

<div
  class="pool"
  class:over={over === "pool"}
  role="list"
  aria-label="Pasted columns"
  ondragover={(e) => onDragOver(e, "pool")}
  ondragleave={() => (over = null)}
  ondrop={(e) => onDrop(e, "pool")}
>
  {#each columns as col (col.index)}
    {@const f = fieldOf(col.index)}
    <div class="pool-item" class:used={f}>
      {@render card(col, false)}
      {#if f}<div class="used-as">→ {f.label}</div>{/if}
    </div>
  {/each}
</div>

<style>
  .targets {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(165px, 1fr));
    gap: 0.75rem;
    margin-bottom: 1rem;
  }

  .slot {
    border: 2px dashed var(--border);
    border-radius: var(--radius);
    padding: 0.6rem;
    background: var(--surface);
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
    transition: border-color 0.1s, background 0.1s;
  }

  .slot.filled {
    border-style: solid;
    border-color: var(--accent);
  }

  .slot.over,
  .pool.over {
    border-color: var(--accent);
    background: var(--accent-soft);
  }

  .slot-head {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    gap: 0.5rem;
  }

  .slot-label {
    font-weight: 600;
  }

  .slot-hint {
    font-size: 0.78rem;
    color: var(--muted);
  }

  .placeholder {
    color: var(--muted);
    font-size: 0.85rem;
    min-height: 3.1rem;
    display: grid;
    place-items: center;
    text-align: center;
  }

  .slot select {
    width: 100%;
    font-size: 0.85rem;
  }

  .pool {
    display: flex;
    gap: 0.6rem;
    overflow-x: auto;
    padding: 0.6rem;
    border: 2px dashed transparent;
    border-radius: var(--radius);
  }

  .pool-item {
    flex: 0 0 auto;
    width: 160px;
  }

  .pool-item.used {
    opacity: 0.55;
  }

  .used-as {
    font-size: 0.8rem;
    color: var(--accent);
    margin-top: 0.25rem;
    text-align: center;
  }

  .card {
    border: 1px solid var(--border);
    border-radius: 6px;
    background: var(--surface);
    padding: 0.45rem 0.6rem;
    cursor: grab;
    user-select: none;
    box-shadow: 0 1px 2px rgb(0 0 0 / 6%);
  }

  .card.dragging {
    opacity: 0.4;
  }

  .card.compact {
    background: var(--accent-soft);
    border-color: var(--accent);
    min-height: 3.1rem;
  }

  .card-label {
    font-weight: 600;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .samples,
  .first-sample {
    margin: 0.3rem 0 0;
    padding: 0;
    list-style: none;
    font-size: 0.8rem;
    color: var(--muted);
  }

  .samples li,
  .first-sample {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
</style>
