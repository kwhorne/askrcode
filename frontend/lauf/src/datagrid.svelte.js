// Logikken i DataGrid, skilt fra tegningen.
//
// Den ligger for seg fordi det er her feilene bor: sorteringsrekkefølge,
// sidegrenser, hva «velg alle» betyr når det finnes flere sider, og hvilket
// vindu som skal tegnes når lista er virtualisert. Alt det kan prøves uten
// en DOM, og da blir testene raske nok til å dekke kantene.

/** Sammenligner to verdier stabilt, med tomme verdier sist. */
export function compare(a, b) {
  // Tomt er ikke «minst» — en tom e-post skal ligge nederst uansett retning,
  // ellers fyller de første siden når man sorterer stigende.
  const aTom = a === null || a === undefined || a === ''
  const bTom = b === null || b === undefined || b === ''
  if (aTom && bTom) return 0
  if (aTom) return 1
  if (bTom) return -1

  if (typeof a === 'number' && typeof b === 'number') return a - b
  if (typeof a === 'boolean' && typeof b === 'boolean') return (a ? 1 : 0) - (b ? 1 : 0)

  const na = Number(a)
  const nb = Number(b)
  if (!Number.isNaN(na) && !Number.isNaN(nb) && String(a).trim() !== '' && String(b).trim() !== '') {
    return na - nb
  }
  // localeCompare med numeric: «Sak 10» etter «Sak 9», som folk forventer.
  return String(a).localeCompare(String(b), undefined, { numeric: true, sensitivity: 'base' })
}

/**
 * Sorterer en kopi. Aldri på plass — kalleren eier arrayet sitt, og en
 * grid som stokker om på appens data er en feil som viser seg et helt
 * annet sted.
 */
export function sortRows(rows, key, dir, valueOf) {
  if (!key) return rows
  const tegn = dir === 'desc' ? -1 : 1
  // Indeksen som siste kriterium gjør sorteringen stabil på alle motorer,
  // ikke bare der Array.sort tilfeldigvis er det.
  return rows
    .map((row, i) => ({ row, i }))
    .sort((a, b) => tegn * compare(valueOf(a.row, key), valueOf(b.row, key)) || a.i - b.i)
    .map((x) => x.row)
}

/** Fritekstsøk over de kolonnene som er søkbare. */
export function filterRows(rows, text, keys, valueOf) {
  const q = (text ?? '').trim().toLowerCase()
  if (!q || keys.length === 0) return rows
  return rows.filter((row) =>
    keys.some((k) => String(valueOf(row, k) ?? '').toLowerCase().includes(q))
  )
}

/** Klemmer et sidetall inn i det som finnes. */
export function clampPage(page, total, per) {
  const pages = Math.max(1, Math.ceil(total / Math.max(1, per)))
  return Math.min(Math.max(1, page | 0), pages)
}

export function pageSlice(rows, page, per) {
  const p = clampPage(page, rows.length, per)
  return rows.slice((p - 1) * per, (p - 1) * per + per)
}

/**
 * Hvilke rader som skal tegnes når lista er virtualisert.
 *
 * `overscan` er rader utenfor synsfeltet i hver ende. Uten dem blinker det
 * hvitt i kanten når man ruller fort, og en rad som akkurat har fokus kan
 * forsvinne under føttene på den som bruker tastatur.
 */
export function windowFor({ scrollTop, viewport, rowHeight, count, overscan = 6 }) {
  if (rowHeight <= 0 || count === 0) return { start: 0, end: count, padTop: 0, padBottom: 0 }
  const synlige = Math.ceil(viewport / rowHeight) + 1
  const start = Math.max(0, Math.floor(scrollTop / rowHeight) - overscan)
  const end = Math.min(count, start + synlige + overscan * 2)
  return {
    start,
    end,
    padTop: start * rowHeight,
    padBottom: Math.max(0, (count - end) * rowHeight),
  }
}

/**
 * Tilstanden til «velg alle»-boksen.
 *
 * Tre tilstander, ikke to: ingen, noen, alle. Uten den midterste vet ikke
 * den som ser boksen om et klikk vil velge eller fravelge, og en boks som
 * ser tom ut mens tolv rader er valgt er direkte misvisende.
 */
export function selectionState(selected, visibleKeys) {
  if (visibleKeys.length === 0) return 'none'
  let n = 0
  for (const k of visibleKeys) if (selected.has(k)) n++
  if (n === 0) return 'none'
  return n === visibleKeys.length ? 'all' : 'some'
}

/** Neste sorteringsretning når man klikker på en kolonne. */
export function nextSort(current, key) {
  if (current.sort !== key) return { sort: key, dir: 'asc' }
  return { sort: key, dir: current.dir === 'asc' ? 'desc' : 'asc' }
}
