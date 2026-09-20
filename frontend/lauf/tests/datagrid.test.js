import { describe, it, expect, afterEach } from 'vitest'
import { render, cleanup, fireEvent, waitFor } from '@testing-library/svelte'
import { violations } from './axe.js'

import GridDemo from './fixtures/GridDemo.svelte'

afterEach(cleanup)

const rows = [
  { id: 1, name: 'Grace Hopper', email: 'grace@navy.mil', balance: 300 },
  { id: 2, name: 'Ada Lovelace', email: 'ada@example.com', balance: 100 },
  { id: 3, name: 'Katherine Johnson', email: 'kj@nasa.gov', balance: 200 },
]

const grid = (c) => c.querySelector('[role="grid"]')
const kropp = (c) => [...c.querySelectorAll('tbody tr')]
const navn = (c) => kropp(c).map((tr) => tr.querySelector('td:first-child')?.textContent.trim())

describe('DataGrid — struktur', () => {
  it('er et grid med navn, radtall og kolonnetall', () => {
    const { container } = render(GridDemo, { rows })
    const g = grid(container)
    expect(g.getAttribute('aria-label')).toBe('Customers')
    // +1 for hoderaden: aria-rowcount teller hele settet inkludert den.
    expect(g.getAttribute('aria-rowcount')).toBe('4')
    expect(g.getAttribute('aria-colcount')).toBe('3')
  })

  it('nummererer radene absolutt, ikke innenfor siden', () => {
    const { container } = render(GridDemo, { rows, perPage: 2 })
    // Side 1: hoderad er 1, første datarad 2.
    expect(kropp(container)[0].getAttribute('aria-rowindex')).toBe('2')
  })

  it('merker sorterbare kolonner, og bare dem', () => {
    const { container } = render(GridDemo, { rows })
    const th = [...container.querySelectorAll('th')]
    expect(th[0].getAttribute('aria-sort')).toBe('none')
    // E-post er ikke sorterbar, og skal da ikke late som den er det.
    expect(th[1].hasAttribute('aria-sort')).toBe(false)
  })

  it('sier fra når det ikke er noe å vise', () => {
    const { container } = render(GridDemo, { rows: [] })
    expect(container.textContent).toContain('Nothing here')
  })

  it('viser skjelett mens den laster', () => {
    const { container } = render(GridDemo, { rows: [], loading: true })
    expect(container.querySelectorAll('[data-lauf="skeleton"]').length).toBeGreaterThan(0)
    expect(container.textContent).not.toContain('Nothing here')
  })
})

describe('DataGrid — klientmodus', () => {
  it('sorterer når man klikker på overskriften, og snur ved andre klikk', async () => {
    const { container } = render(GridDemo, { rows })
    const knapp = container.querySelector('th button')

    await fireEvent.click(knapp)
    await waitFor(() => expect(navn(container)[0]).toBe('Ada Lovelace'))
    expect(container.querySelectorAll('th')[0].getAttribute('aria-sort')).toBe('ascending')

    await fireEvent.click(knapp)
    await waitFor(() => expect(navn(container)[0]).toBe('Katherine Johnson'))
    expect(container.querySelectorAll('th')[0].getAttribute('aria-sort')).toBe('descending')
  })

  it('bytter kolonne uten å beholde retningen fra den forrige', async () => {
    const { container } = render(GridDemo, { rows })
    const [navnKnapp, balanseKnapp] = container.querySelectorAll('th button')
    await fireEvent.click(navnKnapp)
    await fireEvent.click(navnKnapp) // desc
    await fireEvent.click(balanseKnapp)
    await waitFor(() =>
      expect(container.querySelectorAll('th')[2].getAttribute('aria-sort')).toBe('ascending')
    )
  })

  it('søker på tvers av kolonnene', async () => {
    const { container } = render(GridDemo, { rows })
    const sok = container.querySelector('input[type="search"]')
    await fireEvent.input(sok, { target: { value: 'nasa' } })
    await waitFor(() => expect(kropp(container)).toHaveLength(1), { timeout: 2000 })
    expect(navn(container)[0]).toBe('Katherine Johnson')
  })

  it('pagineres, og siste side kan være kortere', async () => {
    const mange = Array.from({ length: 5 }, (_, i) => ({
      id: i, name: `N${i}`, email: `e${i}@x.no`, balance: i,
    }))
    const { container } = render(GridDemo, { rows: mange, perPage: 2 })
    expect(kropp(container)).toHaveLength(2)
    expect(container.textContent).toContain('1–2 of 5')
  })
})

describe('DataGrid — tjenermodus', () => {
  // Griden skal ikke røre radene den får. Gjør den det, sorterer den én
  // side for seg mens tjeneren har sortert hele settet — og resultatet er
  // en liste som ser sortert ut og ikke er det.
  it('tegner radene som de kom, og sorterer dem ikke om', () => {
    const { container } = render(GridDemo, {
      rows,
      grid: { sort: 'name', dir: 'asc', page: 1, per: 25, q: '', total: 9000, pages: 360 },
    })
    expect(navn(container)[0]).toBe('Grace Hopper')
  })

  it('bruker tjenerens total, ikke lengden på siden', () => {
    const { container } = render(GridDemo, {
      rows,
      grid: { sort: '', dir: 'asc', page: 2, per: 25, q: '', total: 9000, pages: 360 },
    })
    expect(grid(container).getAttribute('aria-rowcount')).toBe('9001')
    expect(container.textContent).toContain('of 9000')
  })

  it('nummererer radene fra sidens plass i hele settet', () => {
    const { container } = render(GridDemo, {
      rows,
      grid: { sort: '', dir: 'asc', page: 3, per: 25, q: '', total: 9000, pages: 360 },
    })
    // Side 3, 25 per side: første rad er nummer 51, pluss hoderaden.
    expect(kropp(container)[0].getAttribute('aria-rowindex')).toBe('52')
  })

  it('melder fra om ny tilstand i stedet for å gjøre jobben selv', async () => {
    const sendt = []
    const { container } = render(GridDemo, {
      rows,
      grid: { sort: '', dir: 'asc', page: 1, per: 25, q: '', total: 9000 },
      onstate: (s) => sendt.push(s),
    })
    await fireEvent.click(container.querySelector('th button'))
    expect(sendt).toHaveLength(1)
    expect(sendt[0]).toMatchObject({ sort: 'name', dir: 'asc', page: 1 })
    // Radene står urørt til tjeneren svarer.
    expect(navn(container)[0]).toBe('Grace Hopper')
  })

  it('samler tastetrykk i søkefeltet til én forespørsel', async () => {
    const sendt = []
    const { container } = render(GridDemo, {
      rows,
      grid: { sort: '', dir: 'asc', page: 1, per: 25, q: '', total: 9000 },
      onstate: (s) => sendt.push(s),
    })
    const sok = container.querySelector('input[type="search"]')
    for (const v of ['a', 'ad', 'ada']) {
      await fireEvent.input(sok, { target: { value: v } })
    }
    await waitFor(() => expect(sendt).toHaveLength(1), { timeout: 2000 })
    expect(sendt[0].q).toBe('ada')
  })
})

describe('DataGrid — valg', () => {
  it('har en boks per rad og en for hele siden', () => {
    const { container } = render(GridDemo, { rows, selectable: true })
    expect(container.querySelectorAll('input[type="checkbox"]')).toHaveLength(4)
  })

  it('velger alle på siden, og fravelger dem igjen', async () => {
    const { container } = render(GridDemo, { rows, selectable: true })
    const alle = container.querySelector('thead input[type="checkbox"]')
    await fireEvent.click(alle)
    await waitFor(() => expect(container.textContent).toContain('3 selected'))
    await fireEvent.click(alle)
    await waitFor(() => expect(container.textContent).not.toContain('selected'))
  })

  // Tre tilstander, ikke to. En boks som ser tom ut mens én rad er valgt
  // er direkte misvisende.
  it('står i mellomtilstand når bare noen er valgt', async () => {
    const { container } = render(GridDemo, { rows, selectable: true })
    const rad = container.querySelector('tbody input[type="checkbox"]')
    await fireEvent.click(rad)
    const alle = container.querySelector('thead input[type="checkbox"]')
    await waitFor(() => expect(alle.indeterminate).toBe(true))
    expect(alle.getAttribute('aria-checked')).toBe('mixed')
  })

  it('merker valgte rader for skjermlesere', async () => {
    const { container } = render(GridDemo, { rows, selectable: true })
    await fireEvent.click(container.querySelector('tbody input[type="checkbox"]'))
    await waitFor(() =>
      expect(kropp(container)[0].getAttribute('aria-selected')).toBe('true')
    )
  })
})

describe('DataGrid — tastatur', () => {
  // WAI-ARIAs grid-mønster: én celle i tabbrekkefølgen. Er hver celle
  // tabbar, må man tabbe gjennom hele tabellen for å komme forbi den.
  it('har nøyaktig én celle i tabbrekkefølgen', () => {
    const { container } = render(GridDemo, { rows })
    const tabbare = [...container.querySelectorAll('[tabindex]')].filter(
      (e) => e.tabIndex === 0
    )
    expect(tabbare).toHaveLength(1)
  })

  it('flytter markøren med piltastene', async () => {
    const { container } = render(GridDemo, { rows })
    const g = grid(container)
    await fireEvent.keyDown(g, { key: 'ArrowDown' })
    await waitFor(() => {
      const aktiv = [...container.querySelectorAll('[tabindex]')].find((e) => e.tabIndex === 0)
      expect(aktiv.closest('tr')).toBe(kropp(container)[1])
    })
  })

  it('pil opp fra første rad lander på kolonneoverskriften', async () => {
    const { container } = render(GridDemo, { rows })
    const g = grid(container)
    await fireEvent.keyDown(g, { key: 'ArrowUp' })
    await waitFor(() => {
      const aktiv = [...container.querySelectorAll('[tabindex]')].find((e) => e.tabIndex === 0)
      expect(aktiv.closest('thead')).not.toBeNull()
    })
  })

  it('stopper ved kanten i stedet for å gå ut av tabellen', async () => {
    const { container } = render(GridDemo, { rows })
    const g = grid(container)
    for (let i = 0; i < 20; i++) await fireEvent.keyDown(g, { key: 'ArrowDown' })
    await waitFor(() => {
      const aktiv = [...container.querySelectorAll('[tabindex]')].find((e) => e.tabIndex === 0)
      expect(aktiv.closest('tr')).toBe(kropp(container).at(-1))
    })
  })
})

describe('DataGrid — virtualisering', () => {
  const mange = Array.from({ length: 2000 }, (_, i) => ({
    id: i, name: `Row ${i}`, email: `r${i}@x.no`, balance: i,
  }))

  it('tegner et vindu, ikke hele siden', () => {
    const { container } = render(GridDemo, { rows: mange, perPage: 500, virtual: true })
    const tegnede = kropp(container).filter((tr) => !tr.hasAttribute('aria-hidden'))
    expect(tegnede.length).toBeGreaterThan(0)
    expect(tegnede.length).toBeLessThan(80)
  })

  // Dette er hele poenget med aria-rowcount: en skjermleser skal kjenne
  // den ekte lengden selv om bare tjue rader står i DOM-en.
  it('melder likevel om hele lengden', () => {
    const { container } = render(GridDemo, { rows: mange, perPage: 500, virtual: true })
    expect(grid(container).getAttribute('aria-rowcount')).toBe('2001')
  })

  it('holder rullehøyden med fyll over og under', () => {
    const { container } = render(GridDemo, { rows: mange, perPage: 500, virtual: true })
    const fyll = kropp(container).filter((tr) => tr.hasAttribute('aria-hidden'))
    expect(fyll.length).toBeGreaterThan(0)
    // Fyllet er ikke innhold og skal ikke leses opp.
    for (const f of fyll) expect(f.getAttribute('aria-hidden')).toBe('true')
  })
})

describe('DataGrid — tilgjengelighet', () => {
  it('har ingen axe-brudd i noen av tilstandene', async () => {
    for (const props of [
      { rows },
      { rows, selectable: true },
      { rows: [] },
      { rows, loading: true },
      { rows, grid: { sort: 'name', dir: 'desc', page: 2, per: 2, q: '', total: 90 } },
    ]) {
      const { container } = render(GridDemo, props)
      expect(await violations(container), JSON.stringify(Object.keys(props))).toEqual([])
      cleanup()
    }
  }, 60000)
})
