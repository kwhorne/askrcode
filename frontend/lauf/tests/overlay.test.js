import { describe, it, expect, afterEach } from 'vitest'
import { render, cleanup, fireEvent, waitFor } from '@testing-library/svelte'
import { violations } from './axe.js'

import ModalDemo from './fixtures/ModalDemo.svelte'
import DropdownDemo from './fixtures/DropdownDemo.svelte'

afterEach(cleanup)

// Portalene legger innholdet på document.body, ikke i container, så disse
// leter i hele dokumentet.
const dialog = () => document.querySelector('[role="dialog"]')
const menu = () => document.querySelector('[role="menu"]')

describe('Modal', () => {
  it('er ikke i DOM-en før den åpnes', () => {
    render(ModalDemo)
    expect(dialog()).toBeNull()
  })

  it('åpner, og har et navn og en beskrivelse', async () => {
    render(ModalDemo, { open: true })
    await waitFor(() => expect(dialog()).not.toBeNull())

    const d = dialog()
    // En dialog uten navn annonseres bare som «dialog». Navnet er hele
    // forskjellen på at den er forståelig og ikke.
    const labelId = d.getAttribute('aria-labelledby')
    expect(labelId).toBeTruthy()
    expect(document.getElementById(labelId).textContent).toContain('Delete customer')

    const descId = d.getAttribute('aria-describedby')
    expect(document.getElementById(descId).textContent).toContain('cannot be undone')
  })

  it('er modal, slik at resten av siden ikke kan nås', async () => {
    render(ModalDemo, { open: true })
    await waitFor(() => expect(dialog()).not.toBeNull())
    expect(dialog().getAttribute('aria-modal')).toBe('true')
  })

  // Escape er den ene tasten alle prøver. Uten den er en modal en felle.
  it('lukkes med Escape', async () => {
    render(ModalDemo, { open: true })
    await waitFor(() => expect(dialog()).not.toBeNull())
    await fireEvent.keyDown(document.activeElement ?? document.body, { key: 'Escape' })
    await waitFor(() => expect(dialog()).toBeNull())
  })

  it('har en lukkeknapp med navn', async () => {
    render(ModalDemo, { open: true })
    await waitFor(() => expect(dialog()).not.toBeNull())
    const lukk = [...dialog().querySelectorAll('button')].find(
      (b) => b.getAttribute('aria-label') === 'Close'
    )
    expect(lukk).toBeTruthy()
    await fireEvent.click(lukk)
    await waitFor(() => expect(dialog()).toBeNull())
  })

  it('flytter fokus inn i dialogen når den åpnes', async () => {
    render(ModalDemo, { open: true })
    await waitFor(() => expect(dialog()).not.toBeNull())
    // Uten dette står fokus igjen bak overlegget, og den som bruker
    // tastatur tabber rundt i en side hen ikke kan se.
    await waitFor(() => expect(dialog().contains(document.activeElement)).toBe(true))
  })

  it('har ingen axe-brudd når den er åpen', async () => {
    render(ModalDemo, { open: true })
    await waitFor(() => expect(dialog()).not.toBeNull())
    expect(await violations(document.body)).toEqual([])
  }, 30000)
})

describe('Dropdown', () => {
  it('er lukket til noen ber om den', () => {
    render(DropdownDemo)
    expect(menu()).toBeNull()
  })

  it('utløseren sier at den styrer en meny', () => {
    const { container } = render(DropdownDemo)
    const knapp = container.querySelector('button')
    expect(knapp.getAttribute('aria-haspopup')).toBe('menu')
    expect(knapp.getAttribute('aria-expanded')).toBe('false')
  })

  it('åpnes med tastatur og melder fra om det', async () => {
    const { container } = render(DropdownDemo)
    const knapp = container.querySelector('button')
    await fireEvent.keyDown(knapp, { key: 'Enter' })
    await waitFor(() => expect(menu()).not.toBeNull())
    expect(knapp.getAttribute('aria-expanded')).toBe('true')
  })

  it('radene er menyvalg, ikke bare lenker', async () => {
    render(DropdownDemo, { open: true })
    await waitFor(() => expect(menu()).not.toBeNull())
    const valg = menu().querySelectorAll('[role="menuitem"]')
    expect(valg.length).toBe(2)
    expect([...valg].map((v) => v.textContent.trim())).toEqual(['Edit', 'Delete'])
  })

  it('lukkes med Escape', async () => {
    render(DropdownDemo, { open: true })
    await waitFor(() => expect(menu()).not.toBeNull())
    await fireEvent.keyDown(document.activeElement ?? document.body, { key: 'Escape' })
    await waitFor(() => expect(menu()).toBeNull())
  })

  it('har ingen axe-brudd når den er åpen', async () => {
    render(DropdownDemo, { open: true })
    await waitFor(() => expect(menu()).not.toBeNull())
    expect(await violations(document.body)).toEqual([])
  }, 30000)
})
