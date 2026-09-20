import { describe, it, expect, afterEach } from 'vitest'
import { render, cleanup, fireEvent } from '@testing-library/svelte'
import { violations } from './axe.js'

import Checkbox from '../src/Checkbox.svelte'
import Switch from '../src/Switch.svelte'
import RadioField from './fixtures/RadioField.svelte'

afterEach(cleanup)

describe('Checkbox', () => {
  it('kobler etiketten til boksen', () => {
    const { container } = render(Checkbox, { label: 'Active' })
    const box = container.querySelector('input')
    expect(container.querySelector('label').getAttribute('for')).toBe(box.id)
  })

  it('lar seg krysse av', async () => {
    const { container } = render(Checkbox, { label: 'Active', checked: false })
    const box = container.querySelector('input')
    expect(box.checked).toBe(false)
    await fireEvent.click(box)
    expect(box.checked).toBe(true)
  })

  it('har hjelpetekst koblet med aria-describedby', () => {
    const { container } = render(Checkbox, {
      label: 'Active',
      description: 'Inactive customers are hidden.',
    })
    const box = container.querySelector('input')
    expect(box.getAttribute('aria-describedby')).toBe(container.querySelector('p').id)
  })

  it('har ingen axe-brudd', async () => {
    const { container } = render(Checkbox, { label: 'Active', description: 'Hm.' })
    expect(await violations(container)).toEqual([])
  }, 30000)
})

describe('Switch', () => {
  // En bryter som er en <div> med onclick er ikke en bryter for noen andre
  // enn den som ser den. role="switch" på en ekte avkrysningsboks gir både
  // tastatur, skjema-innsending og riktig opplesning uten at vi skriver
  // noe av det selv.
  it('er en ekte kontroll med role=switch', () => {
    const { container } = render(Switch, { label: 'Notify me' })
    const el = container.querySelector('input')
    expect(el.type).toBe('checkbox')
    expect(el.getAttribute('role')).toBe('switch')
    expect(el.getAttribute('aria-checked')).toBe('false')
  })

  it('oppdaterer aria-checked når den slås på', async () => {
    const { container } = render(Switch, { label: 'Notify me', checked: false })
    const el = container.querySelector('input')
    await fireEvent.click(el)
    expect(el.getAttribute('aria-checked')).toBe('true')
  })

  it('kobler etiketten', () => {
    const { container } = render(Switch, { label: 'Notify me' })
    expect(container.querySelector('label').getAttribute('for')).toBe(
      container.querySelector('input').id
    )
  })

  it('har ingen axe-brudd, av og på', async () => {
    for (const checked of [false, true]) {
      const { container } = render(Switch, { label: 'Notify me', checked })
      expect(await violations(container), String(checked)).toEqual([])
      cleanup()
    }
  }, 30000)
})

describe('Radio', () => {
  it('deler navn innenfor gruppa og velger én om gangen', async () => {
    const { container } = render(RadioField, { label: 'Size', name: 'size' })
    const [small, large] = container.querySelectorAll('input[type="radio"]')
    await fireEvent.click(small)
    expect(small.checked).toBe(true)
    await fireEvent.click(large)
    // Nettleseren sørger for at bare én i en navngitt gruppe er valgt.
    expect(large.checked).toBe(true)
    expect(small.checked).toBe(false)
  })

  it('har en etikett per knapp', () => {
    const { container } = render(RadioField, { label: 'Size', name: 'size' })
    const labels = container.querySelectorAll('label')
    const radios = container.querySelectorAll('input[type="radio"]')
    expect(labels).toHaveLength(2)
    expect(labels[0].getAttribute('for')).toBe(radios[0].id)
    expect(labels[1].getAttribute('for')).toBe(radios[1].id)
  })
})
