import { describe, it, expect, afterEach } from 'vitest'
import { render, cleanup } from '@testing-library/svelte'
import { violations } from './axe.js'

import FieldInput from './fixtures/FieldInput.svelte'
import RadioField from './fixtures/RadioField.svelte'

afterEach(cleanup)

describe('Field', () => {
  // Dette er koblingen hele komponenten finnes for. Ryker den, står
  // etiketten der og ser riktig ut, og en skjermleser sier «edit text,
  // blank» — som er ingenting.
  it('kobler etiketten til kontrollen', () => {
    const { container } = render(FieldInput, { label: 'Email', name: 'email' })
    const label = container.querySelector('label')
    const input = container.querySelector('input')
    expect(label.getAttribute('for')).toBe(input.id)
    expect(input.id).toBeTruthy()
  })

  it('gir hvert felt sin egen id', () => {
    const a = render(FieldInput, { label: 'A', name: 'a' })
    const b = render(FieldInput, { label: 'B', name: 'b' })
    expect(a.container.querySelector('input').id).not.toBe(
      b.container.querySelector('input').id
    )
  })

  it('peker aria-describedby på hjelpeteksten', () => {
    const { container } = render(FieldInput, {
      label: 'Email',
      description: 'We never share it.',
    })
    const input = container.querySelector('input')
    const desc = container.querySelector('p')
    expect(input.getAttribute('aria-describedby')).toBe(desc.id)
  })

  it('markerer feil og peker på meldingen', () => {
    const { container } = render(FieldInput, {
      label: 'Email',
      error: 'is required',
    })
    const input = container.querySelector('input')
    const msg = container.querySelector('[role="alert"]')
    expect(input.getAttribute('aria-invalid')).toBe('true')
    expect(msg.textContent).toContain('is required')
    expect(input.getAttribute('aria-describedby')).toBe(msg.id)
  })

  it('tar med både hjelpetekst og feil, i den rekkefølgen', () => {
    const { container } = render(FieldInput, {
      label: 'Email',
      description: 'Work address.',
      error: 'is required',
    })
    const ids = container.querySelector('input').getAttribute('aria-describedby').split(' ')
    expect(ids).toHaveLength(2)
    // Feilen sist: det er den man skal handle på, og en skjermleser leser
    // dem i den rekkefølgen de står her.
    expect(document.getElementById(ids[1]).getAttribute('role')).toBe('alert')
  })

  it('er ikke ugyldig når det ikke er noen feil', () => {
    const { container } = render(FieldInput, { label: 'Email' })
    const input = container.querySelector('input')
    expect(input.hasAttribute('aria-invalid')).toBe(false)
    expect(input.hasAttribute('aria-describedby')).toBe(false)
  })

  it('merker påkrevde felter både for maskin og menneske', () => {
    const { container } = render(FieldInput, { label: 'Email', required: true })
    expect(container.querySelector('input').required).toBe(true)
    // Stjerna er pynt og skal ikke leses opp — «Email star» er ikke et navn.
    expect(container.querySelector('label span').getAttribute('aria-hidden')).toBe('true')
  })

  it('virker for textarea og select også', () => {
    const t = render(FieldInput, { control: 'textarea', label: 'Notes', error: 'too long' })
    const ta = t.container.querySelector('textarea')
    expect(ta.id).toBe(t.container.querySelector('label').getAttribute('for'))
    expect(ta.getAttribute('aria-invalid')).toBe('true')
    cleanup()

    const s = render(FieldInput, { control: 'select', label: 'Size' })
    const sel = s.container.querySelector('select')
    expect(sel.id).toBe(s.container.querySelector('label').getAttribute('for'))
    expect(sel.querySelector('option').disabled).toBe(true)
  })

  // En gruppe valg har en overskrift, ikke en etikett. <legend> er det
  // eneste en skjermleser leser opp foran hver knapp i gruppa.
  it('bruker fieldset og legend for en gruppe', () => {
    const { container } = render(RadioField, { label: 'Size', name: 'size' })
    expect(container.querySelector('fieldset')).not.toBeNull()
    expect(container.querySelector('legend').textContent).toContain('Size')
    expect(container.querySelector('label')).not.toBeNull()
    const radios = container.querySelectorAll('input[type="radio"]')
    expect(radios).toHaveLength(2)
    // Samme navn, ellers er det ikke én gruppe.
    expect(radios[0].name).toBe('size')
    expect(radios[1].name).toBe('size')
  })

  it('har ingen axe-brudd i noen av tilstandene', async () => {
    for (const props of [
      { label: 'Email' },
      { label: 'Email', description: 'Work address.' },
      { label: 'Email', error: 'is required' },
      { label: 'Email', required: true, description: 'a', error: 'b' },
      { control: 'textarea', label: 'Notes' },
      { control: 'select', label: 'Size' },
    ]) {
      const { container } = render(FieldInput, props)
      expect(await violations(container), JSON.stringify(props)).toEqual([])
      cleanup()
    }

    const { container } = render(RadioField, { label: 'Size', name: 'size' })
    expect(await violations(container)).toEqual([])
  }, 60000)
})
