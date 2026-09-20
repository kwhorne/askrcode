import { describe, it, expect, afterEach } from 'vitest'
import { render, cleanup, fireEvent, waitFor } from '@testing-library/svelte'
import { violations } from './axe.js'

import Progress from '../src/Progress.svelte'
import Slider from '../src/Slider.svelte'
import OtpInput from '../src/OtpInput.svelte'
import AutocompleteField from './fixtures/AutocompleteField.svelte'
import FileField from './fixtures/FileField.svelte'
import CommandDemo from './fixtures/CommandDemo.svelte'
import DateField from './fixtures/DateField.svelte'

afterEach(cleanup)

const items = [
  { value: '1', label: 'Ada Lovelace' },
  { value: '2', label: 'Grace Hopper' },
]

describe('Progress', () => {
  it('melder verdien sin', () => {
    const { container } = render(Progress, { value: 40, label: 'Uploading' })
    const bar = container.querySelector('[role="progressbar"]')
    expect(bar.getAttribute('aria-valuenow')).toBe('40')
    expect(bar.getAttribute('aria-valuemax')).toBe('100')
    expect(bar.getAttribute('aria-label')).toBe('Uploading')
  })

  // Et tall som ikke betyr noe er verre enn ingen tall: «47 %» på noe som
  // ikke vet hvor langt det er kommet er en løgn.
  it('setter ingen verdi når fremdriften er ukjent', () => {
    const { container } = render(Progress, { value: null, label: 'Working' })
    expect(container.querySelector('[role="progressbar"]').hasAttribute('aria-valuenow')).toBe(false)
  })

  it('har ingen axe-brudd', async () => {
    const { container } = render(Progress, { value: 40, label: 'Uploading', showValue: true })
    expect(await violations(container)).toEqual([])
  }, 30000)
})

describe('Slider', () => {
  it('er en ekte slider med verdi og grenser', () => {
    const { container } = render(Slider, { value: 30, min: 0, max: 100 })
    const t = container.querySelector('[role="slider"]')
    expect(t.getAttribute('aria-valuenow')).toBe('30')
    expect(t.getAttribute('aria-valuemin')).toBe('0')
    expect(t.getAttribute('aria-valuemax')).toBe('100')
  })

  it('flyttes med piltast', async () => {
    const { container } = render(Slider, { value: 30, step: 5 })
    const t = container.querySelector('[role="slider"]')
    t.focus()
    await fireEvent.keyDown(t, { key: 'ArrowRight' })
    await waitFor(() => expect(t.getAttribute('aria-valuenow')).toBe('35'))
  })
})

describe('OtpInput', () => {
  // Én input under, ruter over. Én input per siffer gir en tabbfelle,
  // ødelegger innliming og gjør SMS-autofyll umulig.
  it('er ett felt, ikke seks', () => {
    const { container } = render(OtpInput, { length: 6 })
    expect(container.querySelectorAll('input')).toHaveLength(1)
    expect(container.querySelectorAll('[data-pin-input-cell]')).toHaveLength(6)
  })

  it('tar imot en kode og sier fra når den er full', async () => {
    let ferdig = null
    const { container } = render(OtpInput, {
      length: 4,
      oncomplete: (v) => (ferdig = v),
    })
    const input = container.querySelector('input')
    await fireEvent.input(input, { target: { value: '1234' } })
    await waitFor(() => expect(ferdig).toBe('1234'))
  })
})

describe('Autocomplete', () => {
  it('er et tekstfelt med forslag, koblet til etiketten', () => {
    const { container } = render(AutocompleteField, { items, label: 'Customer' })
    const input = container.querySelector('input')
    expect(container.querySelector('label').getAttribute('for')).toBe(input.id)
    // Bits gir combobox-semantikken; uten den er dette bare et tekstfelt
    // med en liste ved siden av, og en skjermleser sier ingenting om at de
    // hører sammen.
    expect(input.getAttribute('role')).toBe('combobox')
    expect(input.getAttribute('aria-expanded')).toBe('false')
  })

  it('markerer feil som alle andre felt', () => {
    const { container } = render(AutocompleteField, {
      items,
      label: 'Customer',
      error: 'is required',
    })
    const input = container.querySelector('input')
    expect(input.getAttribute('aria-invalid')).toBe('true')
    expect(input.getAttribute('aria-describedby')).toBe(
      container.querySelector('[role="alert"]').id
    )
  })

  it('har ingen axe-brudd', async () => {
    const { container } = render(AutocompleteField, { items, label: 'Customer' })
    expect(await violations(container)).toEqual([])
  }, 30000)
})

describe('Command', () => {
  it('er en navngitt liste med valg', async () => {
    const { container } = render(CommandDemo)
    await waitFor(() => expect(container.querySelector('[cmdk-list],[data-command-list]')).not.toBeNull())
    const input = container.querySelector('input')
    expect(input.getAttribute('role')).toBe('combobox')
    expect(container.textContent).toContain('New customer')
  })

  it('filtrerer på det man skriver', async () => {
    const { container } = render(CommandDemo)
    const input = container.querySelector('input')
    await fireEvent.input(input, { target: { value: 'all' } })
    await waitFor(() => {
      expect(container.textContent).toContain('All customers')
      expect(container.textContent).not.toContain('New customer')
    })
  })

  it('sier fra når ingenting passer', async () => {
    const { container } = render(CommandDemo)
    await fireEvent.input(container.querySelector('input'), {
      target: { value: 'zzzzz' },
    })
    await waitFor(() => expect(container.textContent).toContain('No results'))
  })
})

describe('DatePicker', () => {
  // Bits bygger på @internationalized/date. Den typen skal ikke lekke ut:
  // Askr sender datoer som YYYY-MM-DD, og det er formen en app skal kunne
  // sende rett inn og få rett ut.
  it('tar imot og gir fra seg ISO-strenger', () => {
    const { container } = render(DateField, { value: '2026-09-20', label: 'Due' })
    const segmenter = [...container.querySelectorAll('[data-segment]')]
      .map((s) => s.textContent.trim())
      .join('')
    expect(segmenter).toContain('2026')
    expect(segmenter).toContain('20')
  })

  it('takler tom og ødelagt verdi uten å velte', () => {
    expect(() => render(DateField, { value: '', label: 'Due' })).not.toThrow()
    cleanup()
    expect(() => render(DateField, { value: 'i går', label: 'Due' })).not.toThrow()
  })

  it('har en knapp med navn for å åpne kalenderen', () => {
    const { container } = render(DateField, { value: '2026-09-20', label: 'Due' })
    const knapp = [...container.querySelectorAll('button')].find(
      (b) => b.getAttribute('aria-label') === 'Choose date'
    )
    expect(knapp).toBeTruthy()
  })

  it('har ingen axe-brudd', async () => {
    const { container } = render(DateField, { value: '2026-09-20', label: 'Due' })
    expect(await violations(container)).toEqual([])
  }, 30000)
})

describe('FileUpload', () => {
  // En div med onclick og en skjult input mister tastatur og autofyll. Og
  // `hidden` på inputen gjør den ufokuserbar — den må være visuelt skjult,
  // ikke skjult.
  it('bygger på en ekte filinput som kan få fokus', () => {
    const { container } = render(FileField, { label: 'Attachment' })
    const input = container.querySelector('input[type="file"]')
    expect(input).not.toBeNull()
    expect(input.hasAttribute('hidden')).toBe(false)
    expect(input.className).toContain('sr-only')
    expect(container.querySelector('label').getAttribute('for')).toBe(input.id)
  })

  it('viser filene som er valgt, med størrelse', async () => {
    const { container } = render(FileField, { label: 'Attachment' })
    const input = container.querySelector('input[type="file"]')
    const fil = new File(['x'.repeat(2048)], 'rapport.pdf', { type: 'application/pdf' })
    Object.defineProperty(input, 'files', { value: [fil] })
    await fireEvent.change(input)
    await waitFor(() => {
      expect(container.textContent).toContain('rapport.pdf')
      expect(container.textContent).toContain('2.0 kB')
    })
  })

  it('avviser det som er for stort, og sier hvilken fil', async () => {
    const { container } = render(FileField, { label: 'Attachment', maxSize: 1024 })
    const input = container.querySelector('input[type="file"]')
    const stor = new File(['x'.repeat(4096)], 'stor.bin')
    Object.defineProperty(input, 'files', { value: [stor] })
    await fireEvent.change(input)
    await waitFor(() => {
      const varsel = container.querySelector('[role="alert"]')
      expect(varsel.textContent).toContain('stor.bin')
    })
    expect(container.querySelectorAll('li')).toHaveLength(0)
  })

  it('lar en fil fjernes igjen', async () => {
    const { container } = render(FileField, { label: 'Attachment' })
    const input = container.querySelector('input[type="file"]')
    Object.defineProperty(input, 'files', { value: [new File(['x'], 'a.txt')] })
    await fireEvent.change(input)
    await waitFor(() => expect(container.textContent).toContain('a.txt'))

    const fjern = [...container.querySelectorAll('button')].find((b) =>
      b.getAttribute('aria-label')?.startsWith('Remove')
    )
    await fireEvent.click(fjern)
    await waitFor(() => expect(container.textContent).not.toContain('a.txt'))
  })

  it('har ingen axe-brudd, tom og med filer', async () => {
    const { container } = render(FileField, { label: 'Attachment' })
    expect(await violations(container)).toEqual([])

    const input = container.querySelector('input[type="file"]')
    Object.defineProperty(input, 'files', { value: [new File(['x'], 'a.txt')] })
    await fireEvent.change(input)
    await waitFor(() => expect(container.textContent).toContain('a.txt'))
    expect(await violations(container)).toEqual([])
  }, 30000)
})
