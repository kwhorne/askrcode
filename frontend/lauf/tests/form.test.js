import { describe, it, expect, afterEach, vi, beforeEach } from 'vitest'
import { render, cleanup, fireEvent, waitFor } from '@testing-library/svelte'
import { violations } from './axe.js'

// Inertias router er det eneste <Form> snakker med utenfor Lauf. Den byttes
// ut her, slik at testen måler vår kobling og ikke nettverket.
const sendt = []
let besvar = () => {}

// Metodene bruker `this` med vilje. Inertias egne gjør det — router.post
// kaller this.visit() — så en mock med frie funksjoner ville godtatt
// `const f = router.post; f(...)`, som feiler i en nettleser med «Cannot
// read properties of undefined (reading 'visit')». Den feilen slapp
// gjennom denne suiten én gang; nå gjør den ikke det.
vi.mock('@inertiajs/svelte', () => ({
  router: {
    _kall(verb, url, data, opts) {
      this.sendt.push({ verb, url, data, opts })
      besvar(opts)
    },
    sendt,
    post(url, data, opts) {
      this._kall('post', url, data, opts)
    },
    put(url, data, opts) {
      this._kall('put', url, data, opts)
    },
  },
}))

const FormPage = (await import('./fixtures/FormPage.svelte')).default

beforeEach(() => {
  sendt.length = 0
  besvar = () => {}
})
afterEach(cleanup)

describe('Form', () => {
  it('sender feltene på submit, uten å navigere selv', async () => {
    const { container } = render(FormPage)
    const [name, email] = container.querySelectorAll('input[type="text"], input[type="email"]')

    await fireEvent.input(name, { target: { value: 'Ada' } })
    await fireEvent.input(email, { target: { value: 'ada@example.com' } })
    await fireEvent.submit(container.querySelector('form'))

    expect(sendt).toHaveLength(1)
    expect(sendt[0].verb).toBe('post')
    expect(sendt[0].url).toBe('/customers')
    expect(sendt[0].data.name).toBe('Ada')
    expect(sendt[0].data.email).toBe('ada@example.com')
  })

  it('tar med avkrysningsbokser som boolske, ikke som tekst', async () => {
    const { container } = render(FormPage)
    await fireEvent.click(container.querySelector('input[type="checkbox"]'))
    await fireEvent.submit(container.querySelector('form'))
    expect(sendt[0].data.active).toBe(true)
  })

  // Dette er koblingen Flux får fra Livewire og vi får fra Inertia: ingen
  // skal måtte huske disabled={$form.processing} på hver knapp.
  it('viser spinner på submit-knappen mens requesten står på', async () => {
    besvar = () => {} // svarer aldri — requesten henger
    const { container } = render(FormPage)
    const knapp = container.querySelector('button[type="submit"]')

    expect(knapp.disabled).toBe(false)
    await fireEvent.submit(container.querySelector('form'))
    await waitFor(() => expect(knapp.getAttribute('aria-busy')).toBe('true'))
    expect(knapp.disabled).toBe(true)
    expect(container.querySelector('svg.animate-spin')).not.toBeNull()
  })

  it('sender ikke på nytt mens en request står på', async () => {
    besvar = () => {}
    const { container } = render(FormPage)
    const form = container.querySelector('form')
    await fireEvent.submit(form)
    await fireEvent.submit(form)
    await fireEvent.submit(form)
    expect(sendt).toHaveLength(1)
  })

  it('slipper knappen igjen når svaret kommer', async () => {
    besvar = (opts) => {
      opts.onSuccess?.({})
      opts.onFinish?.()
    }
    const { container } = render(FormPage)
    const knapp = container.querySelector('button[type="submit"]')
    await fireEvent.submit(container.querySelector('form'))
    await waitFor(() => expect(knapp.disabled).toBe(false))
  })

  // Hele poenget med <Field name>: feilen finner feltet sitt selv.
  it('plasserer serverens feil på riktig felt', async () => {
    const { container } = render(FormPage, {
      errors: { email: 'must be a valid email' },
    })

    const varsler = container.querySelectorAll('[role="alert"]')
    expect(varsler).toHaveLength(1)
    expect(varsler[0].textContent).toContain('must be a valid email')

    const epost = container.querySelector('input[type="email"]')
    expect(epost.getAttribute('aria-invalid')).toBe('true')
    expect(epost.getAttribute('aria-describedby')).toBe(varsler[0].id)

    // Og navnefeltet er urørt.
    const navn = container.querySelector('input[type="text"]')
    expect(navn.hasAttribute('aria-invalid')).toBe(false)
  })

  it('bytter serverens feil ut med svaret på innsendingen', async () => {
    besvar = (opts) => {
      opts.onError?.({ name: 'is required' })
      opts.onFinish?.()
    }
    const { container } = render(FormPage, { errors: { email: 'gammel feil' } })
    await fireEvent.submit(container.querySelector('form'))

    await waitFor(() => {
      const tekst = [...container.querySelectorAll('[role="alert"]')]
        .map((e) => e.textContent)
        .join(' ')
      expect(tekst).toContain('is required')
      // To kilder til feil uten en regel gir meldinger som blir stående
      // etter at de er rettet. Svaret på innsendingen vinner.
      expect(tekst).not.toContain('gammel feil')
    })
  })

  it('tømmer feilene når innsendingen går bra', async () => {
    besvar = (opts) => {
      opts.onSuccess?.({})
      opts.onFinish?.()
    }
    const { container } = render(FormPage, { errors: { email: 'must be valid' } })
    expect(container.querySelectorAll('[role="alert"]')).toHaveLength(1)
    await fireEvent.submit(container.querySelector('form'))
    await waitFor(() =>
      expect(container.querySelectorAll('[role="alert"]')).toHaveLength(0)
    )
  })

  it('står som et ekte skjema med action og method', () => {
    const { container } = render(FormPage)
    const form = container.querySelector('form')
    expect(form.getAttribute('action')).toBe('/customers')
    expect(form.getAttribute('method')).toBe('post')
  })

  it('har ingen axe-brudd, med og uten feil', async () => {
    const rent = render(FormPage)
    expect(await violations(rent.container)).toEqual([])
    cleanup()

    const feil = render(FormPage, { errors: { email: 'must be a valid email' } })
    expect(await violations(feil.container)).toEqual([])
  }, 60000)
})
