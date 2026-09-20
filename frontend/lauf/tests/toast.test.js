import { describe, it, expect, afterEach, vi } from 'vitest'
import { render, cleanup, fireEvent, waitFor } from '@testing-library/svelte'
import { violations } from './axe.js'

import Toaster from '../src/Toaster.svelte'
import { toast, toasts, dismiss } from '../src/toast.svelte.js'

afterEach(() => {
  for (const t of [...toasts()]) dismiss(t.id)
  cleanup()
  vi.useRealTimers()
})

describe('toast', () => {
  it('legger meldinger i køen og tar dem ut igjen', () => {
    const id = toast('Saved')
    expect(toasts()).toHaveLength(1)
    expect(toasts()[0].message).toBe('Saved')
    dismiss(id)
    expect(toasts()).toHaveLength(0)
  })

  it('forsvinner av seg selv etter en tid', () => {
    vi.useFakeTimers()
    toast('Saved', { duration: 1000 })
    expect(toasts()).toHaveLength(1)
    vi.advanceTimersByTime(1001)
    expect(toasts()).toHaveLength(0)
  })

  // En feil man må lese skal ikke rekke å forsvinne mens man leser den.
  it('blir stående når duration er 0, og det er standard for feil', () => {
    vi.useFakeTimers()
    toast.error('Could not save')
    vi.advanceTimersByTime(60000)
    expect(toasts()).toHaveLength(1)
    expect(toasts()[0].variant).toBe('danger')
  })

  it('har snarveier med hver sin variant', () => {
    toast.success('a')
    toast.warning('b')
    expect(toasts().map((t) => t.variant)).toEqual(['success', 'warning'])
  })
})

describe('Toaster', () => {
  // Dette er den ene detaljen som gjør forskjell på at meldingen leses opp
  // og at den ikke gjør det: legger man området og teksten inn samtidig,
  // rekker ikke skjermleseren å se at noe endret seg.
  it('har live-områdene i DOM-en før noe kommer', () => {
    const { container } = render(Toaster)
    expect(container.querySelector('[aria-live="polite"]')).not.toBeNull()
    expect(container.querySelector('[aria-live="assertive"]')).not.toBeNull()
  })

  it('viser en melding, og lar den lukkes', async () => {
    const { container } = render(Toaster)
    toast('Saved')
    await waitFor(() => expect(container.textContent).toContain('Saved'))

    const lukk = [...container.querySelectorAll('button')].find(
      (b) => b.getAttribute('aria-label') === 'Dismiss'
    )
    expect(lukk).toBeTruthy()
    await fireEvent.click(lukk)
    await waitFor(() => expect(container.textContent).not.toContain('Saved'))
  })

  // En bekreftelse skal ikke avbryte det som leses opp; noe som gikk galt
  // skal. Derfor to områder og ikke ett.
  it('setter feil i det påtrengende området og resten i det høflige', async () => {
    const { container } = render(Toaster)
    toast.success('Saved')
    toast.error('Could not save')

    await waitFor(() => {
      const polite = container.querySelector('[aria-live="polite"]')
      const assertive = container.querySelector('[aria-live="assertive"]')
      expect(polite.textContent).toContain('Saved')
      expect(polite.textContent).not.toContain('Could not save')
      expect(assertive.textContent).toContain('Could not save')
    })
  })

  it('har ingen axe-brudd, tom og full', async () => {
    const { container } = render(Toaster)
    expect(await violations(container)).toEqual([])
    toast.success('Saved')
    toast.error('Could not save')
    await waitFor(() => expect(container.textContent).toContain('Saved'))
    expect(await violations(container)).toEqual([])
  }, 30000)
})
