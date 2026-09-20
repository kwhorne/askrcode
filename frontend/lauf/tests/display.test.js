import { describe, it, expect, afterEach } from 'vitest'
import { render, cleanup, fireEvent } from '@testing-library/svelte'
import { createRawSnippet } from 'svelte'
import { violations } from './axe.js'

import Heading from '../src/Heading.svelte'
import Text from '../src/Text.svelte'
import Badge from '../src/Badge.svelte'
import Card from '../src/Card.svelte'
import Separator from '../src/Separator.svelte'
import Pagination from '../src/Pagination.svelte'
import TableDemo from './fixtures/TableDemo.svelte'

afterEach(cleanup)

const text = (s) => createRawSnippet(() => ({ render: () => `<span>${s}</span>` }))

describe('Heading', () => {
  it('velger tag etter nivå', () => {
    for (const level of [1, 2, 3, 4]) {
      const { container } = render(Heading, { level, children: text('Tittel') })
      expect(container.querySelector(`h${level}`)).not.toBeNull()
      cleanup()
    }
  })

  // Nivå er struktur og størrelse er utseende. En side kan trenge en h2 som
  // ser liten ut, og da skal ikke overskriftsrekkefølgen ryke for det.
  it('lar tag og størrelse skilles med as', () => {
    const { container } = render(Heading, { level: 1, as: 'h2', children: text('T') })
    expect(container.querySelector('h2')).not.toBeNull()
    expect(container.querySelector('h1')).toBeNull()
    expect(container.querySelector('h2').className).toContain('text-2xl')
  })
})

describe('Text', () => {
  it('er et avsnitt, og dempes på forespørsel', () => {
    const { container } = render(Text, { muted: true, children: text('Ingress') })
    const p = container.querySelector('p')
    expect(p.className).toContain('text-muted')
  })

  it('kan bli noe annet enn p', () => {
    const { container } = render(Text, { as: 'span', children: text('x') })
    expect(container.querySelector('span')).not.toBeNull()
  })
})

describe('Badge', () => {
  it('har farger som ikke er den eneste informasjonen', () => {
    const { container } = render(Badge, { color: 'danger', children: text('Overdue') })
    // Teksten bærer betydningen; fargen understreker den. Et merke som bare
    // er rødt sier ingenting til den som ikke ser farger.
    expect(container.textContent).toContain('Overdue')
  })
})

describe('Card', () => {
  it('kan bli et semantisk element', () => {
    const { container } = render(Card, { as: 'article', children: text('x') })
    expect(container.querySelector('article')).not.toBeNull()
  })
})

describe('Separator', () => {
  // En strek som bare er pynt skal ikke annonseres. En som skiller to
  // meningsbærende deler skal det, og da må den ha et navn.
  it('er usynlig for skjermlesere uten en etikett', () => {
    const { container } = render(Separator)
    expect(container.firstElementChild.getAttribute('role')).toBe('none')
  })

  it('blir en separator med etikett', () => {
    const { container } = render(Separator, { label: 'Settings' })
    const el = container.firstElementChild
    expect(el.getAttribute('role')).toBe('separator')
    expect(el.getAttribute('aria-label')).toBe('Settings')
    expect(el.getAttribute('aria-orientation')).toBe('horizontal')
  })
})

describe('Table', () => {
  it('ligger i en rulleboks, ikke fritt på siden', () => {
    // En tabell uten den gjør hele siden bredere enn en telefonskjerm.
    const { container } = render(TableDemo, { rows: [] })
    expect(container.querySelector('div.overflow-x-auto table')).not.toBeNull()
  })

  it('har en caption for den som ikke ser tabellen', () => {
    const { container } = render(TableDemo, { rows: [] })
    expect(container.querySelector('caption').textContent).toBe('Customers')
  })

  it('setter scope på kolonneoverskriftene', () => {
    const { container } = render(TableDemo, { rows: [{ name: 'Ada', balance: 10 }] })
    for (const th of container.querySelectorAll('th')) {
      expect(th.getAttribute('scope')).toBe('col')
    }
  })

  it('høyrestiller tall med tabular-nums', () => {
    const { container } = render(TableDemo, { rows: [{ name: 'Ada', balance: 10 }] })
    const celler = container.querySelectorAll('td')
    expect(celler[1].className).toContain('text-right')
    expect(celler[1].className).toContain('tabular-nums')
  })

  it('har ingen axe-brudd', async () => {
    const { container } = render(TableDemo, {
      rows: [{ name: 'Ada', balance: 10 }, { name: 'Grace', balance: 20 }],
    })
    expect(await violations(container)).toEqual([])
  }, 30000)
})

describe('Pagination', () => {
  it('regner ut sider fra total og sidestørrelse', () => {
    const { container } = render(Pagination, { page: 2, perPage: 25, total: 60 })
    expect(container.textContent).toContain('26–50 of 60')
    expect(container.textContent).toContain('2 / 3')
  })

  it('sier fra når det ikke er noe å bla i', () => {
    const { container } = render(Pagination, { page: 1, perPage: 25, total: 0 })
    expect(container.textContent).toContain('No results')
  })

  it('stenger forrige på første side og neste på siste', () => {
    const forste = render(Pagination, { page: 1, perPage: 10, total: 30 })
    let knapper = forste.container.querySelectorAll('button')
    expect(knapper[0].disabled).toBe(true)
    expect(knapper[1].disabled).toBe(false)
    cleanup()

    const siste = render(Pagination, { page: 3, perPage: 10, total: 30 })
    knapper = siste.container.querySelectorAll('button')
    expect(knapper[0].disabled).toBe(false)
    expect(knapper[1].disabled).toBe(true)
  })

  it('klemmer et sidetall utenfor området inn i det', () => {
    const { container } = render(Pagination, { page: 99, perPage: 10, total: 30 })
    expect(container.textContent).toContain('3 / 3')
  })

  // Med href blir hver side en ekte lenke, som kan åpnes i ny fane.
  it('blir lenker når href er gitt', () => {
    const { container } = render(Pagination, {
      page: 2,
      perPage: 10,
      total: 30,
      href: (n) => `/customers?page=${n}`,
    })
    const lenker = container.querySelectorAll('a')
    expect(lenker).toHaveLength(2)
    expect(lenker[0].getAttribute('href')).toBe('/customers?page=1')
    expect(lenker[1].getAttribute('href')).toBe('/customers?page=3')
  })

  it('kaller onnavigate uten href', async () => {
    const gikk = []
    const { container } = render(Pagination, {
      page: 2,
      perPage: 10,
      total: 30,
      onnavigate: (n) => gikk.push(n),
    })
    const knapper = container.querySelectorAll('button')
    await fireEvent.click(knapper[1])
    expect(gikk).toEqual([3])
  })

  it('har et navn, så flere pagineringer kan skilles', () => {
    const { container } = render(Pagination, { total: 30, label: 'Customers pages' })
    expect(container.querySelector('nav').getAttribute('aria-label')).toBe(
      'Customers pages'
    )
  })

  it('har ingen axe-brudd', async () => {
    const { container } = render(Pagination, { page: 2, perPage: 10, total: 30 })
    expect(await violations(container)).toEqual([])
  }, 30000)
})
