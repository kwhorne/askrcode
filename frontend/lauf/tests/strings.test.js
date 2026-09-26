import { describe, it, expect, afterEach } from 'vitest'
import { render, cleanup } from '@testing-library/svelte'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import StringsProbe from './fixtures/StringsProbe.svelte'
import LocaleProbe from './fixtures/LocaleProbe.svelte'
import FormatProbe from './fixtures/FormatProbe.svelte'
import PageProbe from './fixtures/PageProbe.svelte'
import { laufDefaults, laufContext } from '../src/index.js'

afterEach(cleanup)

const labels = (c) => [...c.querySelectorAll('[aria-label]')].map((e) => e.getAttribute('aria-label'))

describe('strings', () => {
  it('are English when nothing provides any', () => {
    const { container } = render(StringsProbe)
    expect(container.textContent).toContain('11–20 of 35')
    expect(labels(container)).toContain('Previous page')
  })

  it("are the app's when it provides them, placeholders filled", () => {
    const { container } = render(StringsProbe, {
      words: { range_of: ':from til :to av :total', previous_page: 'Forrige side' },
    })
    expect(container.textContent).toContain('11 til 20 av 35')
    expect(labels(container)).toContain('Forrige side')
  })

  it('fall back to English, word by word', () => {
    const { container } = render(StringsProbe, { words: { previous_page: 'Forrige side' } })
    expect(labels(container)).toContain('Next page')
  })

  it('follow a change without a reload', async () => {
    const { container, rerender } = render(StringsProbe, { words: { next_page: 'Neste side' } })
    expect(labels(container)).toContain('Neste side')
    await rerender({ words: { next_page: 'Nächste Seite' } })
    expect(labels(container)).toContain('Nächste Seite')
  })

  it('replace the longest placeholder first', () => {
    const { container } = render(StringsProbe, { words: { range_of: ':to-:total-:from' } })
    expect(container.textContent).toContain('20-35-11')
  })

  // Every English word in a component comes from the table, so a
  // translation reaches all of them. A literal left in markup would be a
  // button that stays English in every language.
  it('are the only English the components write themselves', () => {
    const literals = ['Close', 'Dismiss', 'Previous page', 'Next page', 'No results',
      'Choose date', 'Nothing to preview yet.', 'or drag them here']
    for (const file of ['Modal', 'Toaster', 'Pagination', 'DatePicker', 'Editor', 'FileUpload', 'Autocomplete', 'Command', 'DataGrid']) {
      const src = readFileSync(join(process.cwd(), 'src', `${file}.svelte`), 'utf8')
      for (const w of literals) {
        expect(src.includes(`"${w}"`) || src.includes(`'${w}'`) || src.includes(`>${w}<`),
          `${file} writes "${w}" itself`).toBe(false)
      }
      // A word after an interpolation, as the grid's footer once wrote.
      expect(src, `${file} writes an English word after a value`).not.toMatch(/\} (selected|pages)\b/)
    }
    expect(Object.keys(laufDefaults)).toHaveLength(51)
  })
})

const segments = (c) => [...c.querySelectorAll('[data-segment]')].map((s) => s.textContent.trim()).join('')

describe('locale', () => {
  it('is English when nothing provides one', () => {
    const { container } = render(LocaleProbe)
    expect(container.textContent).toContain('11–20 of 12,345')
    expect(container.textContent).toContain('2 / 1,235')
    expect(segments(container)).toBe('09/20/2026')
  })

  it("writes the numbers as the reader's locale does", () => {
    const { container } = render(LocaleProbe, { locale: 'nb' })
    expect(container.textContent).toContain('of 12\u00a0345')
    expect(container.textContent).toContain('2 / 1\u00a0235')
  })

  it('and gives the date picker the same locale', () => {
    const { container } = render(LocaleProbe, { locale: 'de' })
    expect(container.textContent).toContain('of 12.345')
    expect(segments(container)).toBe('20.09.2026')
  })

  it('follows a change without a reload', async () => {
    const { container, rerender } = render(LocaleProbe, { locale: 'de' })
    await rerender({ locale: 'en' })
    expect(container.textContent).toContain('of 12,345')
  })
})

const shown = (c, what) => c.querySelector(`[data-${what}]`).textContent

describe('numbers and dates', () => {
  it('write a number, and nothing for none', () => {
    let c = render(FormatProbe, { locale: 'nb', number: 1234.5 }).container
    expect(shown(c, 'number')).toBe('1\u00a0234,5')
    cleanup()
    c = render(FormatProbe, { locale: 'nb', number: null }).container
    expect(shown(c, 'number')).toBe('')
    cleanup()
    c = render(FormatProbe, { number: 12.5, numberOptions: { minimumFractionDigits: 2 } }).container
    expect(shown(c, 'number')).toBe('12.50')
  })

  it("write the date Askr sends in the reader's form", () => {
    let c = render(FormatProbe, { date: '2026-02-03 00:00:00' }).container
    expect(shown(c, 'date')).toBe('Feb 3, 2026')
    cleanup()
    c = render(FormatProbe, { locale: 'nb', date: '2026-02-03 00:00:00' }).container
    expect(shown(c, 'date')).toBe('3. feb. 2026')
  })

  it('keep the wall-clock time, in whatever zone the browser is in', () => {
    const c = render(FormatProbe, {
      locale: 'nb', date: '2026-01-02 03:04:00',
      dateOptions: { dateStyle: 'short', timeStyle: 'short' },
    }).container
    expect(shown(c, 'date')).toBe('02.01.2026, 03:04')
  })

  // West of Greenwich, where parsing the text would give the day before.
  // Node applies a change of TZ at once, to Date and to Intl.
  it('take a date alone as that day, not as midnight in Greenwich', () => {
    const tz = process.env.TZ
    process.env.TZ = 'America/Los_Angeles'
    try {
      const c = render(FormatProbe, { date: '2026-02-03', dateOptions: { day: 'numeric' } }).container
      expect(shown(c, 'date')).toBe('3')
    } finally {
      if (tz === undefined) delete process.env.TZ
      else process.env.TZ = tz
    }
  })

  it('write nothing for no date, and text that is not one as it was', () => {
    let c = render(FormatProbe, { date: null }).container
    expect(shown(c, 'date')).toBe('')
    cleanup()
    c = render(FormatProbe, { date: 'soon' }).container
    expect(shown(c, 'date')).toBe('soon')
  })
})

describe('laufContext', () => {
  it("reaches a page's own script, which a layout's provide does not", () => {
    const { container } = render(PageProbe, {
      context: laufContext({ locale: () => 'nb', strings: () => ({ range_of: ':from–:to av :total' }) }),
    })
    expect(container.querySelector('[data-number]').textContent).toBe('1\u00a0234,5')
    expect(container.textContent).toContain('1–10 av 12\u00a0345')
  })
})
