// Lo que pone Google Sheets en el portapapeles (text/plain) al copiar celdas:
// columnas separadas por tab y filas por salto de línea. Una celda con tab,
// salto de línea o comillas va entre comillas, con las comillas internas
// duplicadas.

export function parseTsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let cell = "";
  let i = 0;
  let atCellStart = true;

  const endCell = () => {
    row.push(cell);
    cell = "";
    atCellStart = true;
  };
  const endRow = () => {
    endCell();
    rows.push(row);
    row = [];
  };

  while (i < text.length) {
    const c = text[i];
    if (atCellStart && c === '"') {
      // Celda entre comillas: hasta la comilla de cierre
      const close = findClosingQuote(text, i + 1);
      if (close !== -1) {
        cell = text.slice(i + 1, close).replaceAll('""', '"');
        i = close + 1;
        atCellStart = false;
        continue;
      }
    }
    atCellStart = false;
    if (c === "\t") {
      endCell();
    } else if (c === "\n" || c === "\r") {
      if (c === "\r" && text[i + 1] === "\n") i++;
      endRow();
    } else {
      cell += c;
    }
    i++;
  }
  if (cell !== "" || row.length > 0) endRow();

  // Sin filas vacías, y todas con el mismo número de columnas
  const nonEmpty = rows.filter((r) => r.some((c) => c.trim() !== ""));
  const width = Math.max(0, ...nonEmpty.map((r) => r.length));
  return nonEmpty.map((r) => [...r, ...Array(width - r.length).fill("")]);
}

// Índice de la comilla que cierra la celda, si después viene tab, salto de
// línea o el final. Si no, la celda no estaba entre comillas.
function findClosingQuote(text: string, from: number): number {
  let i = from;
  while (i < text.length) {
    if (text[i] === '"') {
      if (text[i + 1] === '"') {
        i += 2;
        continue;
      }
      const next = text[i + 1];
      return next === undefined || next === "\t" || next === "\n" || next === "\r" ? i : -1;
    }
    i++;
  }
  return -1;
}

// Nombre de columna al estilo de las planillas: A, B, ..., Z, AA, AB, ...
export function columnLetter(index: number): string {
  let s = "";
  let n = index + 1;
  while (n > 0) {
    const r = (n - 1) % 26;
    s = String.fromCharCode(65 + r) + s;
    n = Math.floor((n - 1) / 26);
  }
  return s;
}
