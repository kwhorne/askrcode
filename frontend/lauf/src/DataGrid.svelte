<!--
  DataGrid.

  To modi i én komponent, og valget er det viktigste i hele filen:

  * **Tjenermodus** — `grid`-propen kommer fra `TGrid<M>` i Pascal.
    Sortering, søk og paginering skjer i databasen. Komponenten eier ingen
    datalogikk; den sender tilstanden videre med `onstate` og tegner det den
    får. Det er standarden for Askr, fordi databasen står der allerede, har
    indeksene, og er raskere enn nettverket.
  * **Klientmodus** — uten `grid` sorterer og filtrerer den arrayet den får.
    Greit opp til noen tusen rader; over det henter man en tabell over
    nettet for å gjøre det databasen gjorde bedre.

  Virtualisering er **valgfri**, ikke på. Den holder DOM-en liten når en
  side er høy, men den koster Ctrl+F i nettleseren og utskrift. `aria-rowcount`
  og `aria-rowindex` settes uansett, slik at en skjermleser kjenner den
  ekte lengden også når bare et vindu er tegnet — og på tvers av sider i
  tjenermodus.

  Det griden **ikke** gjør, med vilje: kolonneomstokking og festing ved
  dragning, gruppering, redigering i cellene, uendelig rulling og eksport.
  Hver av dem er sitt eget prosjekt, og dragning med tastaturstøtte er like
  vanskelig som resten til sammen.
-->
<script>
  import { tick, untrack } from 'svelte'
  import { cn } from './utils.js'
  import { uid } from './context.js'
  import {
    sortRows, filterRows, pageSlice, clampPage,
    windowFor, selectionState, nextSort,
  } from './datagrid.svelte.js'
  import Icon from './Icon.svelte'
  import Input from './Input.svelte'
  import Button from './Button.svelte'
  import Checkbox from './Checkbox.svelte'
  import Pagination from './Pagination.svelte'
  import Skeleton from './Skeleton.svelte'
  import Dropdown from './Dropdown.svelte'
  import DropdownItem from './DropdownItem.svelte'
  import {
    ChevronUp, ChevronDown, MagnifyingGlass, ViewColumns,
  } from './icons/micro/index.js'

  let {
    /** Radene som skal vises. I tjenermodus er dette allerede én side. */
    rows = [],
    /**
     * [{ key, label, align, width, minWidth, sortable, searchable, hidden,
     *    format, cell }]
     * `cell` er en snippet som får (row, value) og tegner cella selv.
     */
    columns = [],
    /** Stabil nøkkel per rad. Uten den kan ikke valg overleve en sortering. */
    rowKey = (row) => row.id,
    /** Tilstanden fra TGrid i Pascal. Gjør griden til tjenermodus. */
    grid = null,
    /** Kalles med { sort, dir, page, per, q } når noe endrer seg. */
    onstate,
    /** Avkrysningskolonne. */
    selectable = false,
    /** Set med radnøkler. */
    selected = $bindable(new Set()),
    /** Kalles når en rad aktiveres med Enter eller dobbeltklikk. */
    onrowactivate,
    /** Slå på virtualisering. Krever fast radhøyde. */
    virtual = false,
    rowHeight = 41,
    /** Høyden på rulleboksen når griden er virtualisert. */
    height = 480,
    /** Rader per side i klientmodus. */
    perPage = 25,
    /** Viser skjelett i stedet for rader. */
    loading = false,
    /** Teksten når ingenting finnes. */
    empty = 'Nothing here',
    /** Navnet på tabellen, for den som ikke ser den. Påkrevd. */
    caption,
    /** Skjuler søkefeltet. */
    searchable = true,
    class: klass,
    ...rest
  } = $props()

  const server = $derived(!!grid)
  const base = uid('lauf-grid')

  // Klienttilstand. I tjenermodus er den bare det vi sist sendte, slik at
  // kontrollene viser riktig med én gang i stedet for å vente på svaret.
  //
  // untrack med vilje: `grid` er utgangspunktet, ikke en kilde tilstanden
  // følger. Effekten under synkroniserer den når tjeneren svarer — det er
  // to forskjellige ting, og uten untrack advarer Svelte om at bare
  // startverdien fanges, hvilket er nettopp det vi vil.
  let sort = $state(untrack(() => grid?.sort ?? ''))
  let dir = $state(untrack(() => grid?.dir ?? 'asc'))
  let page = $state(untrack(() => grid?.page ?? 1))
  let q = $state(untrack(() => grid?.q ?? ''))
  let skjulte = $state(new Set())

  // Tjeneren er fasit når den svarer. Uten dette henger kontrollene igjen
  // på det man klikket hvis tjeneren valgte noe annet — for eksempel fordi
  // kolonnen ikke sto i hvitelisten.
  $effect(() => {
    if (!grid) return
    sort = grid.sort ?? ''
    dir = grid.dir ?? 'asc'
    page = grid.page ?? 1
  })

  const synlige = $derived(columns.filter((c) => !c.hidden && !skjulte.has(c.key)))
  const perSide = $derived(server ? (grid.per ?? perPage) : perPage)

  function verdi(row, key) {
    const col = columns.find((c) => c.key === key)
    if (col?.value) return col.value(row)
    return row?.[key]
  }

  const sokeNokler = $derived(
    columns.filter((c) => c.searchable !== false && !c.cell).map((c) => c.key)
  )

  // Klientmodus gjør arbeidet; tjenermodus tegner det den fikk.
  const behandlet = $derived.by(() => {
    if (server) return rows
    const filtrert = filterRows(rows, q, sokeNokler, verdi)
    return sortRows(filtrert, sort, dir, verdi)
  })

  const total = $derived(server ? (grid.total ?? rows.length) : behandlet.length)
  const siden = $derived(server ? rows : pageSlice(behandlet, page, perSide))
  const forsteIndeks = $derived((clampPage(page, total, perSide) - 1) * perSide)

  const nokler = $derived(siden.map((r) => rowKey(r)))
  const valgTilstand = $derived(selectionState(selected, nokler))

  // Samme tilstand ut i begge modi. I klientmodus er onstate valgfri —
  // griden gjør jobben selv — men appen kan ville legge den i URL-en
  // likevel, slik at en sortert liste kan bokmerkes.
  function send(neste) {
    sort = neste.sort ?? sort
    dir = neste.dir ?? dir
    page = neste.page ?? page
    q = neste.q ?? q
    onstate?.({ sort, dir, page, per: perSide, q })
  }

  function klikkKolonne(col) {
    if (!col.sortable) return
    const n = nextSort({ sort, dir }, col.key)
    send({ ...n, page: 1 })
  }

  let sokeTimer
  function sokEndret(v) {
    clearTimeout(sokeTimer)
    // Ikke én request per tastetrykk. 250 ms er kort nok til å kjennes
    // umiddelbart og langt nok til at «kunde» blir én spørring, ikke fem.
    sokeTimer = setTimeout(() => send({ q: v, page: 1 }), 250)
  }

  function velgAlle() {
    const neste = new Set(selected)
    if (valgTilstand === 'all') for (const k of nokler) neste.delete(k)
    else for (const k of nokler) neste.add(k)
    selected = neste
  }

  function velg(key) {
    const neste = new Set(selected)
    if (neste.has(key)) neste.delete(key)
    else neste.add(key)
    selected = neste
  }

  // ---- virtualisering -------------------------------------------------
  let boks = $state(null)
  let scrollTop = $state(0)
  let viewport = $state(untrack(() => height))

  const vindu = $derived(
    virtual
      ? windowFor({ scrollTop, viewport, rowHeight, count: siden.length })
      : { start: 0, end: siden.length, padTop: 0, padBottom: 0 }
  )
  const tegnede = $derived(siden.slice(vindu.start, vindu.end))

  // ---- tastaturnavigering ---------------------------------------------
  // WAI-ARIAs grid-mønster: én celle i tabbrekkefølgen, pilene flytter
  // mellom cellene. Er hver celle tabbar, må man tabbe gjennom hele
  // tabellen for å komme forbi den.
  //
  // Svelte-lintern advarer om tabindex på td og span, fordi den ikke ser at
  // de står i et role="grid". Der er nettopp det mønsteret krever, så
  // advarselen er slått av på hvert sted med denne begrunnelsen — ikke i
  // bulk, og ikke i stillhet.
  let aktiv = $state({ r: 0, c: 0 })

  function cellId(r, c) {
    return `${base}-c-${r}-${c}`
  }

  // Rad -1 er hoderaden, slik at pil opp fra første rad lander på
  // kolonneoverskriften og ikke i ingenting.
  async function flytt(dr, dc, e) {
    const nyR = Math.min(Math.max(aktiv.r + dr, -1), siden.length - 1)
    const nyC = Math.min(Math.max(aktiv.c + dc, 0), kolonneAntall - 1)
    aktiv = { r: nyR, c: nyC }
    e.preventDefault()

    if (virtual && nyR >= 0) {
      // Rull målet inn i vinduet før vi prøver å fokusere det — er raden
      // utenfor, finnes ikke elementet.
      const top = nyR * rowHeight
      if (boks) {
        if (top < scrollTop) boks.scrollTop = top
        else if (top + rowHeight > scrollTop + viewport)
          boks.scrollTop = top + rowHeight - viewport
      }
    }
    await tick()
    document.getElementById(cellId(nyR, nyC))?.focus()
  }

  const kolonneAntall = $derived(synlige.length + (selectable ? 1 : 0))

  function tast(e) {
    switch (e.key) {
      case 'ArrowDown': flytt(1, 0, e); break
      case 'ArrowUp': flytt(-1, 0, e); break
      case 'ArrowRight': flytt(0, 1, e); break
      case 'ArrowLeft': flytt(0, -1, e); break
      case 'Home':
        if (e.ctrlKey || e.metaKey) flytt(-aktiv.r - 1, -aktiv.c, e)
        else flytt(0, -aktiv.c, e)
        break
      case 'End':
        if (e.ctrlKey || e.metaKey) flytt(siden.length - 1 - aktiv.r, kolonneAntall, e)
        else flytt(0, kolonneAntall, e)
        break
      case 'PageDown': flytt(10, 0, e); break
      case 'PageUp': flytt(-10, 0, e); break
      case 'Enter':
        if (aktiv.r >= 0 && siden[aktiv.r]) {
          onrowactivate?.(siden[aktiv.r])
          e.preventDefault()
        }
        break
    }
  }

  function tabIndex(r, c) {
    return aktiv.r === r && aktiv.c === c ? 0 : -1
  }

  const sortRetning = (col) =>
    sort === col.key ? (dir === 'desc' ? 'descending' : 'ascending') : 'none'
</script>

<div class={cn('flex flex-col gap-3', klass)} data-lauf="datagrid" {...rest}>
  {#if searchable || columns.some((c) => c.hideable !== false)}
    <div class="flex items-center gap-2">
      {#if searchable}
        <div class="max-w-xs flex-1">
          <Input
            icon={MagnifyingGlass}
            type="search"
            value={q}
            placeholder="Search"
            aria-label="Search {caption}"
            oninput={(e) => sokEndret(e.currentTarget.value)}
          />
        </div>
      {/if}
      <div class="flex-1"></div>
      <Dropdown>
        {#snippet trigger(props)}
          <Button {...props} size="sm" icon={ViewColumns} label="Columns" />
        {/snippet}
        {#each columns.filter((c) => c.hideable !== false) as col (col.key)}
          <DropdownItem
            onclick={(e) => {
              e.preventDefault()
              const n = new Set(skjulte)
              if (n.has(col.key)) n.delete(col.key)
              else n.add(col.key)
              skjulte = n
            }}
          >
            <span class="flex-1">{col.label}</span>
            <span aria-hidden="true">{skjulte.has(col.key) ? '' : '✓'}</span>
            <span class="sr-only">{skjulte.has(col.key) ? 'hidden' : 'shown'}</span>
          </DropdownItem>
        {/each}
      </Dropdown>
    </div>
  {/if}

  <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
  <div
    class={cn('w-full overflow-auto rounded-surface border border-line', virtual && 'relative')}
    style={virtual ? `height: ${height}px` : undefined}
    bind:this={boks}
    onscroll={(e) => {
      scrollTop = e.currentTarget.scrollTop
      viewport = e.currentTarget.clientHeight
    }}
  >
    <table
      role="grid"
      aria-label={caption}
      aria-rowcount={total + 1}
      aria-colcount={kolonneAntall}
      class="w-full border-collapse text-sm"
      onkeydown={tast}
    >
      <caption class="sr-only">{caption}</caption>
      <thead class="sticky top-0 z-10 bg-raised">
        <tr aria-rowindex={1}>
          {#if selectable}
            <th scope="col" aria-colindex={1} class="w-10 px-2 py-2">
              <!-- svelte-ignore a11y_no_noninteractive_tabindex -->
              <span id={cellId(-1, 0)} tabindex={tabIndex(-1, 0)} class="inline-flex">
                <Checkbox
                  label=""
                  aria-label="Select all rows on this page"
                  checked={valgTilstand === 'all'}
                  indeterminate={valgTilstand === 'some'}
                  onchange={velgAlle}
                />
              </span>
            </th>
          {/if}
          {#each synlige as col, i (col.key)}
            {@const ci = i + (selectable ? 1 : 0)}
            <th
              scope="col"
              aria-colindex={ci + 1}
              aria-sort={col.sortable ? sortRetning(col) : undefined}
              style={col.width ? `width: ${col.width}` : undefined}
              class={cn(
                'border-b border-line px-2 py-2 text-xs font-semibold uppercase tracking-wide text-muted',
                col.align === 'right' ? 'text-right' : 'text-left'
              )}
            >
              {#if col.sortable}
                <button
                  id={cellId(-1, ci)}
                  tabindex={tabIndex(-1, ci)}
                  type="button"
                  onclick={() => klikkKolonne(col)}
                  class={cn(
                    'inline-flex items-center gap-1 rounded-sm hover:text-fg',
                    'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent',
                    col.align === 'right' && 'flex-row-reverse'
                  )}
                >
                  {col.label}
                  {#if sort === col.key}
                    <Icon icon={dir === 'desc' ? ChevronDown : ChevronUp} size="sm" />
                  {/if}
                </button>
              {:else}
                <!-- svelte-ignore a11y_no_noninteractive_tabindex -->
                <span id={cellId(-1, ci)} tabindex={tabIndex(-1, ci)}>{col.label}</span>
              {/if}
            </th>
          {/each}
        </tr>
      </thead>

      <tbody>
        {#if loading}
          {#each Array(5) as _, r (r)}
            <tr aria-rowindex={r + 2}>
              {#each Array(kolonneAntall) as _, c (c)}
                <td class="px-2 py-2"><Skeleton /></td>
              {/each}
            </tr>
          {/each}
        {:else if siden.length === 0}
          <tr aria-rowindex={2}>
            <td colspan={kolonneAntall} class="px-2 py-10 text-center text-muted">
              {empty}
            </td>
          </tr>
        {:else}
          {#if virtual && vindu.padTop > 0}
            <tr aria-hidden="true"><td colspan={kolonneAntall} style="height: {vindu.padTop}px; padding: 0"></td></tr>
          {/if}

          {#each tegnede as row, i (rowKey(row))}
            {@const r = vindu.start + i}
            {@const key = rowKey(row)}
            <!-- aria-rowindex er den absolutte plassen i hele settet, ikke
                 i vinduet — det er den som gjør at en skjermleser sier
                 «rad 4013 av 91000» også når bare tjue er tegnet. -->
            <tr
              aria-rowindex={forsteIndeks + r + 2}
              aria-selected={selectable ? selected.has(key) : undefined}
              ondblclick={() => onrowactivate?.(row)}
              class={cn(
                'border-b border-line last:border-0',
                selected.has(key) && 'bg-accent/10'
              )}
              style={virtual ? `height: ${rowHeight}px` : undefined}
            >
              {#if selectable}
                <td aria-colindex={1} class="px-2 py-2">
                  <!-- svelte-ignore a11y_no_noninteractive_tabindex -->
                  <span id={cellId(r, 0)} tabindex={tabIndex(r, 0)} class="inline-flex">
                    <Checkbox
                      label=""
                      aria-label="Select row {forsteIndeks + r + 1}"
                      checked={selected.has(key)}
                      onchange={() => velg(key)}
                    />
                  </span>
                </td>
              {/if}
              {#each synlige as col, ci (col.key)}
                {@const c = ci + (selectable ? 1 : 0)}
                {@const v = verdi(row, col.key)}
                <td
                  id={cellId(r, c)}
                  tabindex={tabIndex(r, c)}
                  aria-colindex={c + 1}
                  class={cn(
                    'px-2 py-2 align-middle',
                    'focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-accent',
                    col.align === 'right' ? 'text-right tabular-nums' : 'text-left'
                  )}
                >
                  {#if col.cell}{@render col.cell(row, v)}
                  {:else if col.format}{col.format(v, row)}
                  {:else}{v ?? '—'}{/if}
                </td>
              {/each}
            </tr>
          {/each}

          {#if virtual && vindu.padBottom > 0}
            <tr aria-hidden="true"><td colspan={kolonneAntall} style="height: {vindu.padBottom}px; padding: 0"></td></tr>
          {/if}
        {/if}
      </tbody>
    </table>
  </div>

  <div class="flex items-center justify-between gap-4 flex-wrap">
    {#if selectable && selected.size > 0}
      <p class="text-xs text-muted tabular-nums" role="status">
        {selected.size} selected
      </p>
    {:else}
      <span></span>
    {/if}
    <Pagination
      page={clampPage(page, total, perSide)}
      perPage={perSide}
      {total}
      label="{caption} pages"
      onnavigate={(n) => send({ page: n })}
    />
  </div>
</div>
