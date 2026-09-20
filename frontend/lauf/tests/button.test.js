import { describe, it, expect, afterEach } from 'vitest'
import { render, cleanup } from '@testing-library/svelte'
import { createRawSnippet } from 'svelte'
import { violations } from './axe.js'

import Button from '../src/Button.svelte'
import ButtonGroupDemo from './fixtures/ButtonGroupDemo.svelte'
import { ArrowDownTray } from '../src/icons/micro/index.js'

afterEach(cleanup)

const text = (s) => createRawSnippet(() => ({ render: () => `<span>${s}</span>` }))

describe('Button', () => {
  it('er en knapp, og en lenke når href er satt', () => {
    const b = render(Button, { children: text('Save') })
    expect(b.container.querySelector('button')).not.toBeNull()
    expect(b.container.querySelector('button').type).toBe('button')
    cleanup()

    // En knapp som navigerer med JavaScript kan ikke åpnes i ny fane og
    // sier ikke hvor den går. Har den et mål, skal den være en lenke.
    const a = render(Button, { href: '/customers', children: text('Customers') })
    expect(a.container.querySelector('a').getAttribute('href')).toBe('/customers')
    expect(a.container.querySelector('button')).toBeNull()
  })

  it('en lenke får ikke disabled-attributtet', () => {
    // <a disabled> betyr ingenting. aria-disabled er det som sier fra.
    const { container } = render(Button, {
      href: '/x',
      disabled: true,
      children: text('Nope'),
    })
    const a = container.querySelector('a')
    expect(a.hasAttribute('disabled')).toBe(false)
    expect(a.getAttribute('aria-disabled')).toBe('true')
  })

  it('viser spinner og er utilgjengelig mens den laster', () => {
    const { container } = render(Button, { loading: true, children: text('Save') })
    const btn = container.querySelector('button')
    expect(btn.disabled).toBe(true)
    expect(btn.getAttribute('aria-busy')).toBe('true')
    expect(container.querySelector('svg.animate-spin')).not.toBeNull()
  })

  it('bytter ikonet ut med spinneren, ikke legger den ved siden av', () => {
    const { container } = render(Button, {
      icon: ArrowDownTray,
      loading: true,
      children: text('Export'),
    })
    expect(container.querySelectorAll('svg')).toHaveLength(1)
  })

  it('blir kvadratisk av et ikon uten tekst', () => {
    const { container } = render(Button, { icon: ArrowDownTray, label: 'Download' })
    const btn = container.querySelector('button')
    expect(btn.className).toContain('w-9')
    // Uten tekst er ikonet hele knappen, og da må knappen ha et navn.
    expect(btn.getAttribute('aria-label')).toBe('Download')
  })

  it('gir ikke en knapp med tekst et overflødig navn', () => {
    const { container } = render(Button, { children: text('Save'), label: 'Save' })
    expect(container.querySelector('button').hasAttribute('aria-label')).toBe(false)
  })

  it('lar appens klasse vinne over variantens', () => {
    const { container } = render(Button, {
      variant: 'primary',
      class: 'bg-danger',
      children: text('Delete'),
    })
    const cls = container.querySelector('button').className
    expect(cls).toContain('bg-danger')
    expect(cls).not.toContain('bg-accent')
  })

  it('sender ukjente attributter videre', () => {
    const { container } = render(Button, {
      children: text('Save'),
      'data-testid': 'lagre',
    })
    expect(container.querySelector('button').getAttribute('data-testid')).toBe('lagre')
  })

  it('Button.Group setter knappene sammen', () => {
    const { container } = render(ButtonGroupDemo)
    expect(container.querySelectorAll('button')).toHaveLength(2)
    expect(container.querySelector('[data-lauf="button-group"]')).not.toBeNull()
  })

  it('har ingen axe-brudd i noen variant eller tilstand', async () => {
    for (const variant of ['primary', 'filled', 'outline', 'subtle', 'ghost', 'danger']) {
      const { container } = render(Button, { variant, children: text('Save') })
      expect(await violations(container), variant).toEqual([])
      cleanup()
    }
    for (const props of [
      { loading: true, children: text('Save') },
      { disabled: true, children: text('Save') },
      { icon: ArrowDownTray, label: 'Download' },
      { href: '/x', children: text('Go') },
    ]) {
      const { container } = render(Button, props)
      expect(await violations(container)).toEqual([])
      cleanup()
    }
  }, 60000)
})
