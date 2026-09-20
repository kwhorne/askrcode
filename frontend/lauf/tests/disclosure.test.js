import { describe, it, expect, afterEach } from 'vitest'
import { render, cleanup, fireEvent, waitFor } from '@testing-library/svelte'
import { violations } from './axe.js'

import TabsDemo from './fixtures/TabsDemo.svelte'
import AccordionDemo from './fixtures/AccordionDemo.svelte'

afterEach(cleanup)

describe('Tabs', () => {
  // Uten aria-controls og aria-labelledby er faner bare knapper som bytter
  // innhold, og en skjermleser sier ikke at de hører sammen.
  it('kobler hver fane til panelet sitt', () => {
    const { container } = render(TabsDemo)
    const faner = container.querySelectorAll('[role="tab"]')
    expect(faner).toHaveLength(2)
    expect(container.querySelector('[role="tablist"]')).not.toBeNull()

    const panelId = faner[0].getAttribute('aria-controls')
    const panel = document.getElementById(panelId)
    expect(panel.getAttribute('role')).toBe('tabpanel')
    expect(panel.getAttribute('aria-labelledby')).toBe(faner[0].id)
  })

  it('skjuler panelet som ikke er valgt', () => {
    const { container } = render(TabsDemo)
    const paneler = container.querySelectorAll('[role="tabpanel"]')
    // Begge står i DOM-en — det er `hidden` som avgjør, og det er riktig:
    // innholdet skal være der for søk i siden og for at bytte skal være
    // umiddelbart. Skjult er noe annet enn borte.
    expect(paneler[0].hasAttribute('hidden')).toBe(false)
    expect(paneler[1].hasAttribute('hidden')).toBe(true)
    expect(paneler[0].textContent).toContain('First panel')
  })

  // Roving tabindex: én fane i tabbrekkefølgen, pilene flytter mellom dem.
  // Er alle fanene tabbare, må man tabbe forbi hele raden for å nå
  // innholdet.
  it('har bare én fane i tabbrekkefølgen', () => {
    const { container } = render(TabsDemo)
    const faner = [...container.querySelectorAll('[role="tab"]')]
    expect(faner.filter((f) => f.tabIndex === 0)).toHaveLength(1)
  })

  it('bytter fane med piltast', async () => {
    const { container } = render(TabsDemo)
    const faner = container.querySelectorAll('[role="tab"]')
    faner[0].focus()
    await fireEvent.keyDown(faner[0], { key: 'ArrowRight' })
    await waitFor(() => expect(faner[1].getAttribute('aria-selected')).toBe('true'))
    expect(container.textContent).toContain('Second panel')
  })

  it('går til første og siste med Home og End', async () => {
    const { container } = render(TabsDemo)
    const faner = container.querySelectorAll('[role="tab"]')
    faner[0].focus()
    await fireEvent.keyDown(faner[0], { key: 'End' })
    await waitFor(() => expect(faner[1].getAttribute('aria-selected')).toBe('true'))
    await fireEvent.keyDown(faner[1], { key: 'Home' })
    await waitFor(() => expect(faner[0].getAttribute('aria-selected')).toBe('true'))
  })

  it('har ingen axe-brudd', async () => {
    const { container } = render(TabsDemo)
    expect(await violations(container)).toEqual([])
  }, 30000)
})

describe('Accordion', () => {
  // Overskriften må være en ekte overskrift med knappen inni, ikke en knapp
  // som ser ut som en overskrift. Det er den som lar en skjermleser hoppe
  // mellom seksjonene.
  it('har en ekte overskrift rundt hver knapp', () => {
    const { container } = render(AccordionDemo)
    const h = container.querySelectorAll('h3')
    expect(h).toHaveLength(2)
    expect(h[0].querySelector('button')).not.toBeNull()
  })

  it('melder om åpen og lukket, og kobler knapp til innhold', async () => {
    const { container } = render(AccordionDemo)
    const knapp = container.querySelector('button')
    expect(knapp.getAttribute('aria-expanded')).toBe('false')

    await fireEvent.click(knapp)
    await waitFor(() => expect(knapp.getAttribute('aria-expanded')).toBe('true'))

    const innholdId = knapp.getAttribute('aria-controls')
    expect(document.getElementById(innholdId).textContent).toContain('Body of first')
  })

  it('lukker den forrige når type er single', async () => {
    const { container } = render(AccordionDemo)
    const [a, b] = container.querySelectorAll('button')
    await fireEvent.click(a)
    await waitFor(() => expect(a.getAttribute('aria-expanded')).toBe('true'))
    await fireEvent.click(b)
    await waitFor(() => expect(b.getAttribute('aria-expanded')).toBe('true'))
    expect(a.getAttribute('aria-expanded')).toBe('false')
  })

  it('har ingen axe-brudd, åpen og lukket', async () => {
    const { container } = render(AccordionDemo)
    expect(await violations(container)).toEqual([])
    await fireEvent.click(container.querySelector('button'))
    await waitFor(() =>
      expect(container.querySelector('button').getAttribute('aria-expanded')).toBe('true')
    )
    expect(await violations(container)).toEqual([])
  }, 30000)
})
