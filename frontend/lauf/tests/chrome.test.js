import { describe, it, expect, afterEach } from 'vitest'
import { render, cleanup } from '@testing-library/svelte'
import { createRawSnippet } from 'svelte'
import { violations } from './axe.js'

import Callout from '../src/Callout.svelte'
import Breadcrumbs from '../src/Breadcrumbs.svelte'
import Skeleton from '../src/Skeleton.svelte'
import Avatar from '../src/Avatar.svelte'
import Navbar from '../src/Navbar.svelte'
import SidebarDemo from './fixtures/SidebarDemo.svelte'

afterEach(cleanup)

const text = (s) => createRawSnippet(() => ({ render: () => `<span>${s}</span>` }))

describe('Callout', () => {
  it('har et ikon per variant, ikke bare en farge', () => {
    // Fargen alene sier ingenting til den som ikke ser farger.
    const sett = new Set()
    for (const variant of ['info', 'success', 'warning', 'danger']) {
      const { container } = render(Callout, { variant, children: text('x') })
      sett.add(container.querySelector('path')?.getAttribute('d'))
      cleanup()
    }
    expect(sett.size).toBe(4)
  })

  // En melding som dukker opp og sier at noe gikk galt må leses opp. En som
  // bare forklarer noe skal ikke avbryte.
  it('varsler bare når noe er galt', () => {
    for (const [variant, live] of [
      ['info', false],
      ['success', false],
      ['warning', true],
      ['danger', true],
    ]) {
      const { container } = render(Callout, { variant, children: text('x') })
      expect(container.firstElementChild.getAttribute('role') === 'alert', variant).toBe(live)
      cleanup()
    }
  })

  it('har ingen axe-brudd i noen variant', async () => {
    for (const variant of ['info', 'success', 'warning', 'danger']) {
      const { container } = render(Callout, { variant, title: 'Heads up', children: text('x') })
      expect(await violations(container), variant).toEqual([])
      cleanup()
    }
  }, 30000)
})

describe('Breadcrumbs', () => {
  const items = [
    { label: 'Home', href: '/' },
    { label: 'Customers', href: '/customers' },
    { label: 'Ada' },
  ]

  it('er en navigasjon med et navn og en ordnet liste', () => {
    const { container } = render(Breadcrumbs, { items })
    const nav = container.querySelector('nav')
    expect(nav.getAttribute('aria-label')).toBe('Breadcrumb')
    expect(container.querySelectorAll('ol > li')).toHaveLength(3)
  })

  it('merker siste ledd som der man er, og lenker det ikke', () => {
    const { container } = render(Breadcrumbs, { items })
    const lenker = container.querySelectorAll('a')
    expect(lenker).toHaveLength(2)
    const nå = container.querySelector('[aria-current="page"]')
    expect(nå.textContent).toBe('Ada')
    expect(nå.tagName).toBe('SPAN')
  })

  // «/» mellom leddene leses opp som «skråstrek» hvis den er tekst.
  it('skjuler skilletegnene for skjermlesere', () => {
    const { container } = render(Breadcrumbs, { items })
    const skille = container.querySelectorAll('[aria-hidden="true"]')
    expect(skille).toHaveLength(2)
  })

  it('har ingen axe-brudd', async () => {
    const { container } = render(Breadcrumbs, { items })
    expect(await violations(container)).toEqual([])
  }, 30000)
})

describe('Skeleton', () => {
  // En plassholder er ikke innhold. Leses den opp, hører man på tomrom.
  it('er usynlig for skjermlesere', () => {
    const { container } = render(Skeleton)
    expect(container.firstElementChild.getAttribute('aria-hidden')).toBe('true')
  })

  it('kan ha ulike former', () => {
    const { container } = render(Skeleton, { shape: 'circle' })
    expect(container.firstElementChild.className).toContain('rounded-full')
  })
})

describe('Avatar', () => {
  it('lager initialer av navnet', async () => {
    const { container } = render(Avatar, { name: 'Ada Lovelace' })
    // Uten bilde er fallbacken det som vises, og den bærer navnet — ellers
    // er avataren en tom sirkel for den som ikke ser den.
    await new Promise((r) => setTimeout(r, 0))
    expect(container.textContent.trim()).toBe('AL')
    expect(container.querySelector('[aria-label="Ada Lovelace"]')).not.toBeNull()
  })

  it('takler et navn som mangler', async () => {
    const { container } = render(Avatar, { name: '' })
    await new Promise((r) => setTimeout(r, 0))
    expect(container.textContent.trim()).toBe('?')
  })
})

describe('Navbar og Sidebar', () => {
  it('Navbar er et header-landemerke med en navngitt nav inni', () => {
    const { container } = render(Navbar, { label: 'Main', children: text('x') })
    expect(container.querySelector('header')).not.toBeNull()
    expect(container.querySelector('nav').getAttribute('aria-label')).toBe('Main')
  })

  it('Sidebar er sitt eget navngitte landemerke', () => {
    const { container } = render(SidebarDemo)
    expect(container.querySelector('nav').getAttribute('aria-label')).toBe('Settings')
  })

  it('Sidebar merker siden man står på', () => {
    const { container } = render(SidebarDemo)
    const aktiv = container.querySelector('[aria-current="page"]')
    expect(aktiv.textContent.trim()).toBe('Profile')
  })

  it('har ingen axe-brudd', async () => {
    const n = render(Navbar, { children: text('x') })
    expect(await violations(n.container)).toEqual([])
    cleanup()
    const s = render(SidebarDemo)
    expect(await violations(s.container)).toEqual([])
  }, 30000)
})
