import { describe, it, expect, afterEach } from 'vitest'
import { render, cleanup, fireEvent } from '@testing-library/svelte'
import { violations } from './axe.js'

import TabsFull from './fixtures/TabsFull.svelte'

afterEach(cleanup)

const tab = (c, name) => [...c.querySelectorAll('[role="tab"]')]
  .find((t) => t.textContent.trim().startsWith(name))

describe('Tabs', () => {
  it('is a real tablist, not buttons that swap content', () => {
    const { container } = render(TabsFull)
    expect(container.querySelector('[role="tablist"]')).toBeTruthy()
    const t = tab(container, 'Profile')
    expect(t.getAttribute('aria-selected')).toBe('true')
    // The link both ways is what makes it a tab rather than a button.
    const panel = container.querySelector(`#${t.getAttribute('aria-controls')}`)
    expect(panel.getAttribute('aria-labelledby')).toBe(t.id)
  })

  it('an icon renders and is hidden from the screen reader', () => {
    const { container } = render(TabsFull)
    const svg = tab(container, 'Profile').querySelector('svg')
    expect(svg).toBeTruthy()
    // The label is right there in the text; a name on the icon would be
    // read twice.
    expect(svg.getAttribute('aria-hidden')).toBe('true')
  })

  // The count has to be part of the tab's name, not a separate stop.
  // "Orders 12" is what a sighted reader gets, so it is what a screen
  // reader should get.
  it('a badge is part of the accessible name', () => {
    const { container } = render(TabsFull)
    const t = tab(container, 'Orders')
    expect(t.textContent.replace(/\s+/g, ' ').trim()).toBe('Orders 12')
    expect(t.querySelector('[aria-hidden="true"]')?.textContent).not.toBe('12')
  })

  it('a disabled tab cannot be selected', async () => {
    const { container } = render(TabsFull)
    const t = tab(container, 'Billing')
    expect(t.disabled).toBe(true)
    await fireEvent.click(t)
    expect(t.getAttribute('aria-selected')).toBe('false')
    expect(tab(container, 'Profile').getAttribute('aria-selected')).toBe('true')
  })

  it('clicking switches the panel', async () => {
    const { container } = render(TabsFull)
    await fireEvent.click(tab(container, 'Orders'))
    expect(tab(container, 'Orders').getAttribute('aria-selected')).toBe('true')
    const shown = [...container.querySelectorAll('[role="tabpanel"]')]
      .filter((p) => !p.hasAttribute('hidden'))
    expect(shown).toHaveLength(1)
    expect(shown[0].textContent).toContain('orders panel')
  })
})

describe('Tabs — variants', () => {
  // The list and the trigger are styled as a pair: an underline tab needs
  // a border on the list to sit against, a segmented one needs a track.
  // These assert the pair, not the exact classes.
  it('underline puts the rule on the list', () => {
    const { container } = render(TabsFull, { variant: 'underline' })
    expect(container.querySelector('[role="tablist"]').className).toContain('border-b')
    expect(tab(container, 'Profile').className).toContain('border-b-2')
  })

  it('segmented gives the list a track', () => {
    const { container } = render(TabsFull, { variant: 'segmented' })
    const list = container.querySelector('[role="tablist"]').className
    expect(list).toContain('rounded-control')
    expect(list).not.toContain('border-b ')
    expect(tab(container, 'Profile').className).toContain('data-[state=active]:bg-raised')
  })

  it('pills fill the active tab with the accent', () => {
    const { container } = render(TabsFull, { variant: 'pills' })
    expect(tab(container, 'Profile').className).toContain('rounded-full')
    expect(tab(container, 'Profile').className).toContain('data-[state=active]:bg-accent')
  })

  // A typo in the variant should cost the look, not the page.
  it('an unknown variant falls back to underline', () => {
    const { container } = render(TabsFull, { variant: 'fluff' })
    expect(container.querySelector('[role="tablist"]').className).toContain('border-b')
  })

  it('size sm is smaller than base', () => {
    const a = render(TabsFull, { size: 'sm' })
    const small = tab(a.container, 'Profile').className
    cleanup()
    const b = render(TabsFull, { size: 'base' })
    const base = tab(b.container, 'Profile').className
    expect(small).toContain('text-xs')
    expect(base).toContain('text-sm')
  })

  it('scrollable hides the scrollbar and fades the trailing edge', () => {
    const { container } = render(TabsFull, { scrollable: true })
    expect(container.querySelector('[role="tablist"]').className).toContain('overflow-x-auto')
    const fade = container.querySelector('[aria-hidden="true"].pointer-events-none')
    expect(fade).toBeTruthy()
    // It sits on top of the tabs; if it caught clicks the last tab would
    // stop working and nothing would say why.
    expect(fade.className).toContain('pointer-events-none')
  })

  it('no fade without scrollable', () => {
    const { container } = render(TabsFull)
    expect(container.querySelector('.pointer-events-none.absolute')).toBeNull()
  })
})

describe('Tabs — findable', () => {
  it('an inactive panel is plain hidden by default', () => {
    const { container } = render(TabsFull)
    const hidden = [...container.querySelectorAll('[role="tabpanel"]')]
      .filter((p) => p.hasAttribute('hidden'))
    expect(hidden.length).toBeGreaterThan(0)
    for (const p of hidden) expect(p.getAttribute('hidden')).not.toBe('until-found')
  })

  // hidden="until-found" is what lets the browser search a panel that is
  // not open. Plain `hidden` keeps it out of find-in-page entirely, which
  // makes a page-wide search box a lie.
  it('findable marks inactive panels until-found', () => {
    const { container } = render(TabsFull, { findable: true })
    const hidden = [...container.querySelectorAll('[role="tabpanel"]')]
      .filter((p) => p.hasAttribute('hidden'))
    expect(hidden.length).toBe(3)
    for (const p of hidden) expect(p.getAttribute('hidden')).toBe('until-found')
  })

  it('the active panel is not hidden at all', () => {
    const { container } = render(TabsFull, { findable: true })
    const shown = [...container.querySelectorAll('[role="tabpanel"]')]
      .filter((p) => !p.hasAttribute('hidden'))
    expect(shown).toHaveLength(1)
    expect(shown[0].textContent).toContain('profile')
  })

  // The browser fires beforematch, scrolls to the match and reveals the
  // element. Revealing it alone would leave the tab unselected and the
  // content hanging out of a container the tablist thinks is closed, so
  // we select the owning tab instead.
  it('beforematch selects the tab that owns the panel', async () => {
    const { container } = render(TabsFull, { findable: true })
    const orders = [...container.querySelectorAll('[role="tabpanel"]')]
      .find((p) => p.textContent.includes('orders panel'))
    expect(orders.hasAttribute('hidden')).toBe(true)

    orders.dispatchEvent(new Event('beforematch', { bubbles: true }))
    await Promise.resolve()

    expect(tab(container, 'Orders').getAttribute('aria-selected')).toBe('true')
    expect(orders.hasAttribute('hidden')).toBe(false)
  })

  // jsdom has no find-in-page, so what is measured here is the attribute
  // and the handler — not that a browser actually searches the panel.
  // That part is the platform's, and it is noted in the docs.
  it('the attribute survives switching tabs', async () => {
    const { container } = render(TabsFull, { findable: true })
    await fireEvent.click(tab(container, 'Orders'))
    const profile = [...container.querySelectorAll('[role="tabpanel"]')]
      .find((p) => p.textContent.includes('profile'))
    expect(profile.getAttribute('hidden')).toBe('until-found')
  })
})

describe('Tabs — axe', () => {
  for (const variant of ['underline', 'segmented', 'pills']) {
    it(`no violations, ${variant}`, async () => {
      const { container } = render(TabsFull, { variant })
      expect(await violations(container)).toEqual([])
    })
  }

  it('no violations with findable panels', async () => {
    const { container } = render(TabsFull, { findable: true })
    expect(await violations(container)).toEqual([])
  })
})
