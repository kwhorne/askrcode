import { describe, it, expect, afterEach } from 'vitest'
import { render, cleanup } from '@testing-library/svelte'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import StringsProbe from './fixtures/StringsProbe.svelte'
import { laufDefaults } from '../src/index.js'

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
    }
    expect(Object.keys(laufDefaults)).toHaveLength(49)
  })
})
