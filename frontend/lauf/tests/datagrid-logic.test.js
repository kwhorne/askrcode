// @vitest-environment node
//
// Ren logikk, ingen DOM. Det er her feilene i en grid bor — rekkefølge,
// sidegrenser, hva «velg alle» betyr, og hvilket vindu som skal tegnes.

import { describe, it, expect } from 'vitest'
import {
  compare, sortRows, filterRows, clampPage, pageSlice,
  windowFor, selectionState, nextSort,
} from '../src/datagrid.svelte.js'

const v = (row, key) => row[key]

describe('compare', () => {
  it('sorterer tall som tall, ikke som tekst', () => {
    expect(compare(9, 10)).toBeLessThan(0)
    // Den klassiske: '10' < '9' leksikalsk.
    expect(compare('9', '10')).toBeLessThan(0)
  })

  it('sorterer tekst med tall inni slik folk forventer', () => {
    expect(compare('Sak 9', 'Sak 10')).toBeLessThan(0)
  })

  it('bryr seg ikke om store bokstaver', () => {
    expect(compare('ada', 'Ada')).toBe(0)
  })

  // Tomt er ikke «minst». Ligger de først, fyller de hele første side når
  // man sorterer stigende, og da ser lista tom ut.
  it('legger tomme verdier sist uansett retning', () => {
    expect(compare('', 'a')).toBeGreaterThan(0)
    expect(compare(null, 'a')).toBeGreaterThan(0)
    expect(compare(undefined, 0)).toBeGreaterThan(0)
    expect(compare('', '')).toBe(0)
  })
})

describe('sortRows', () => {
  const rows = [
    { id: 1, name: 'Grace', n: 2 },
    { id: 2, name: 'Ada', n: 1 },
    { id: 3, name: 'Katherine', n: 2 },
  ]

  it('rører ikke arrayet den fikk', () => {
    const kopi = [...rows]
    sortRows(rows, 'name', 'asc', v)
    expect(rows).toEqual(kopi)
  })

  it('sorterer begge veier', () => {
    expect(sortRows(rows, 'name', 'asc', v).map((r) => r.name)).toEqual([
      'Ada', 'Grace', 'Katherine',
    ])
    expect(sortRows(rows, 'name', 'desc', v).map((r) => r.name)).toEqual([
      'Katherine', 'Grace', 'Ada',
    ])
  })

  // Uten stabilitet hopper rader med lik verdi rundt mellom to klikk, og
  // det ser ut som om dataene endrer seg.
  it('er stabil på like verdier', () => {
    expect(sortRows(rows, 'n', 'asc', v).map((r) => r.id)).toEqual([2, 1, 3])
  })

  it('uten nøkkel gjør den ingenting', () => {
    expect(sortRows(rows, '', 'asc', v)).toBe(rows)
  })
})

describe('filterRows', () => {
  const rows = [
    { name: 'Ada Lovelace', email: 'ada@example.com' },
    { name: 'Grace Hopper', email: 'grace@navy.mil' },
  ]

  it('søker i alle oppgitte kolonner', () => {
    expect(filterRows(rows, 'navy', ['name', 'email'], v)).toHaveLength(1)
    expect(filterRows(rows, 'ada', ['name', 'email'], v)).toHaveLength(1)
  })

  it('bryr seg ikke om store bokstaver eller kantmellomrom', () => {
    expect(filterRows(rows, '  ADA ', ['name'], v)).toHaveLength(1)
  })

  it('tomt søk gir alt tilbake, uten å kopiere', () => {
    expect(filterRows(rows, '', ['name'], v)).toBe(rows)
    expect(filterRows(rows, '   ', ['name'], v)).toBe(rows)
  })
})

describe('sider', () => {
  const rows = Array.from({ length: 53 }, (_, i) => ({ id: i }))

  it('klemmer et sidetall inn i det som finnes', () => {
    expect(clampPage(0, 53, 25)).toBe(1)
    expect(clampPage(99, 53, 25)).toBe(3)
    expect(clampPage(2, 53, 25)).toBe(2)
  })

  it('en tom liste har fortsatt side 1', () => {
    expect(clampPage(1, 0, 25)).toBe(1)
  })

  it('siste side kan være kortere', () => {
    expect(pageSlice(rows, 3, 25)).toHaveLength(3)
  })

  // Skjer når noen sletter rader mens du står på siste side.
  it('en side utenfor området gir siste side, ikke tomt', () => {
    expect(pageSlice(rows, 99, 25).map((r) => r.id)).toEqual([50, 51, 52])
  })
})

describe('windowFor', () => {
  it('tegner bare det som er i synsfeltet, pluss litt', () => {
    const w = windowFor({ scrollTop: 0, viewport: 400, rowHeight: 40, count: 10000 })
    expect(w.start).toBe(0)
    expect(w.end).toBeLessThan(40)
    expect(w.padTop).toBe(0)
    // Fyllet under holder rullehøyden riktig, slik at rullefeltet ikke
    // hopper mens man ruller.
    expect(w.padBottom).toBe((10000 - w.end) * 40)
  })

  it('flytter vinduet når man ruller', () => {
    const w = windowFor({ scrollTop: 4000, viewport: 400, rowHeight: 40, count: 10000 })
    expect(w.start).toBe(100 - 6)
    expect(w.padTop).toBe((100 - 6) * 40)
  })

  it('har overskudd i begge ender, så kanten ikke blinker', () => {
    const w = windowFor({ scrollTop: 4000, viewport: 400, rowHeight: 40, count: 10000, overscan: 3 })
    expect(w.start).toBe(97)
  })

  it('takler tom liste og høyde null uten å dele på null', () => {
    expect(windowFor({ scrollTop: 0, viewport: 400, rowHeight: 40, count: 0 }).end).toBe(0)
    expect(windowFor({ scrollTop: 0, viewport: 400, rowHeight: 0, count: 5 }).end).toBe(5)
  })
})

describe('selectionState', () => {
  it('skiller ingen, noen og alle', () => {
    expect(selectionState(new Set(), ['a', 'b'])).toBe('none')
    expect(selectionState(new Set(['a']), ['a', 'b'])).toBe('some')
    expect(selectionState(new Set(['a', 'b']), ['a', 'b'])).toBe('all')
  })

  // Valg på en annen side skal ikke gjøre boksen på denne siden full.
  it('ser bare på radene som vises nå', () => {
    expect(selectionState(new Set(['x', 'y']), ['a', 'b'])).toBe('none')
  })

  it('en tom side er ikke «alle valgt»', () => {
    expect(selectionState(new Set(['a']), [])).toBe('none')
  })
})

describe('nextSort', () => {
  it('en ny kolonne starter stigende', () => {
    expect(nextSort({ sort: 'a', dir: 'desc' }, 'b')).toEqual({ sort: 'b', dir: 'asc' })
  })

  it('samme kolonne snur retningen', () => {
    expect(nextSort({ sort: 'a', dir: 'asc' }, 'a')).toEqual({ sort: 'a', dir: 'desc' })
    expect(nextSort({ sort: 'a', dir: 'desc' }, 'a')).toEqual({ sort: 'a', dir: 'asc' })
  })
})
