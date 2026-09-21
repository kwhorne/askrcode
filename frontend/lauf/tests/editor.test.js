import { describe, it, expect, afterEach } from 'vitest'
import { render, cleanup, fireEvent } from '@testing-library/svelte'
import { violations } from './axe.js'

import EditorProbe from './fixtures/EditorProbe.svelte'
import EditorField from './fixtures/EditorField.svelte'

afterEach(cleanup)

// jsdom has no document.execCommand, so these tests run through the
// fallback path in write(): direct assignment. That is worth saying out
// loud, because it means the undo stack — the entire reason execCommand
// is used at all — is NOT covered here. It is exercised in real Chrome,
// in tests/browser/check.mjs. A stub is not a measurement.

function setup(props = {}) {
  const r = render(EditorProbe, props)
  const area = r.container.querySelector('textarea')
  // The bound value, read out of the DOM — not textarea.value.
  const value = () => r.container.querySelector('[data-testid="out"]').textContent
  return { ...r, area, value }
}

/** Selects a range and clicks a toolbar button. */
async function use(container, area, label, start = area.selectionStart, end = area.selectionEnd) {
  area.setSelectionRange(start, end)
  const button = container.querySelector(`[aria-label="${label}"]`)
  await fireEvent.click(button)
  return button
}

describe('Editor', () => {
  it('is a textarea holding markdown, not a contenteditable', () => {
    const { area, container } = setup({ value: '# Hello' })
    expect(area).toBeTruthy()
    expect(area.value).toBe('# Hello')
    expect(container.querySelector('[contenteditable]')).toBeNull()
  })

  it('typing updates the value', async () => {
    const { area, value } = setup({ value: '' })
    await fireEvent.input(area, { target: { value: 'hello' } })
    expect(value()).toBe('hello')
  })

  it('bold wraps the selection', async () => {
    const { area, container, value } = setup({ value: 'hello world' })
    await use(container, area, 'Bold', 6, 11)
    expect(value()).toBe('hello **world**')
  })

  // A toggle, not just a wrap. Without this a second click would give
  // ****world****, and the only way out was deleting by hand.
  it('bold on something already bold takes it off', async () => {
    const { area, container, value } = setup({ value: 'hello **world**' })
    await use(container, area, 'Bold', 6, 15)
    expect(value()).toBe('hello world')
  })

  it('bold also takes it off when the markers sit outside the selection', async () => {
    const { area, container, value } = setup({ value: 'hello **world**' })
    await use(container, area, 'Bold', 8, 13)
    expect(value()).toBe('hello world')
  })

  // An empty selection should give you something to type over, not two
  // pairs of markers with a caret between them that looks like nothing
  // happened.
  it('with no selection a placeholder is inserted', async () => {
    const { area, container, value } = setup({ value: '' })
    await use(container, area, 'Bold', 0, 0)
    expect(value()).toBe('**bold text**')
  })

  it('a heading prefixes the whole line, not the selection', async () => {
    const { area, container, value } = setup({ value: 'a title' })
    await use(container, area, 'Heading 1', 2, 5)
    expect(value()).toBe('# a title')
  })

  it('a different heading level switches rather than stacking', async () => {
    const { area, container, value } = setup({
      value: 'x',
      toolbar: 'heading h2 h3',
    })
    await use(container, area, 'Heading 1', 0, 1)
    expect(value()).toBe('# x')
    await use(container, area, 'Heading 2', 0, 3)
    expect(value()).toBe('## x')
  })

  it('the same heading twice takes it off', async () => {
    const { area, container, value } = setup({ value: '# x' })
    await use(container, area, 'Heading 1', 0, 3)
    expect(value()).toBe('x')
  })

  it('a list touches every line the selection reaches', async () => {
    const { area, container, value } = setup({ value: 'one\ntwo\nthree' })
    await use(container, area, 'Bulleted list', 1, 6)
    expect(value()).toBe('- one\n- two\nthree')
  })

  it('a numbered list counts, it does not repeat 1.', async () => {
    const { area, container, value } = setup({ value: 'one\ntwo\nthree' })
    await use(container, area, 'Numbered list', 0, 13)
    expect(value()).toBe('1. one\n2. two\n3. three')
  })

  // A bullet and a number occupy the same place on the line. Switching
  // should replace one with the other, not stand in front of it.
  it('switching list type replaces rather than stacks', async () => {
    const { area, container, value } = setup({ value: '- one' })
    await use(container, area, 'Numbered list', 0, 5)
    expect(value()).toBe('1. one')
  })

  it('quote and code', async () => {
    const a = setup({ value: 'said' })
    await use(a.container, a.area, 'Quote', 0, 4)
    expect(a.value()).toBe('> said')

    cleanup()
    const b = setup({ value: 'x := 1' })
    await use(b.container, b.area, 'Code', 0, 6)
    expect(b.value()).toBe('`x := 1`')
  })

  // A link has two holes and only one of them is empty. Which one
  // depends on what was selected, and guessing wrong means moving the
  // caret by hand every time.
  it('link: selected text becomes the label', async () => {
    const { area, container, value } = setup({ value: 'Askr' })
    await use(container, area, 'Link', 0, 4)
    expect(value()).toBe('[Askr](url)')
  })

  it('link: a selected address becomes the address', async () => {
    const { area, container, value } = setup({ value: 'https://askr.dev' })
    await use(container, area, 'Link', 0, 16)
    expect(value()).toBe('[](https://askr.dev)')
  })

  it('Cmd+B does what the button does', async () => {
    const { area, value } = setup({ value: 'hey' })
    area.setSelectionRange(0, 3)
    await fireEvent.keyDown(area, { key: 'b', metaKey: true })
    expect(value()).toBe('**hey**')
  })

  it('B without Cmd is just a b', async () => {
    const { area, value } = setup({ value: 'hey' })
    area.setSelectionRange(0, 3)
    await fireEvent.keyDown(area, { key: 'b' })
    expect(value()).toBe('hey')
  })
})

describe('Editor — preview', () => {
  it('is absent until asked for', () => {
    const { container } = setup({ value: '# Hello' })
    expect(container.querySelector('[aria-label="Preview"]')).toBeNull()
  })

  it('shows rendered markdown when it is on', () => {
    const { container } = setup({ value: '# Hello\n\n**bold**', preview: true })
    const p = container.querySelector('[aria-label="Preview"]')
    expect(p.querySelector('h1').textContent).toBe('Hello')
    expect(p.querySelector('strong').textContent).toBe('bold')
  })

  it('the eye toggles it and says which way', async () => {
    const { container } = setup({ value: 'x' })
    const button = container.querySelector('[aria-label="Show preview"]')
    expect(button.getAttribute('aria-expanded')).toBe('false')
    await fireEvent.click(button)
    expect(button.getAttribute('aria-expanded')).toBe('true')
    expect(container.querySelector('[aria-label="Preview"]')).toBeTruthy()
  })

  // aria-controls must point at something that exists. Closed, the pane
  // is not there, and a pointer to a missing id is an axe violation —
  // found by axe in the Field test, not by reading.
  it('aria-controls only points when the pane is there', async () => {
    const { container } = setup({ value: 'x' })
    const button = container.querySelector('[aria-label="Show preview"]')
    expect(button.getAttribute('aria-controls')).toBeNull()
    await fireEvent.click(button)
    const id = container.querySelector('[aria-label="Hide preview"]').getAttribute('aria-controls')
    expect(container.querySelector(`#${id}`)).toBeTruthy()
  })

  // The same claim as in the markdown tests, but through the component:
  // this is where {@html} actually sits, and that is the line that would
  // be the hole.
  it('raw HTML in the source does not run in the preview', () => {
    const { container } = setup({
      value: '<img src=x onerror=alert(1)>\n\n[k](javascript:alert(1))',
      preview: true,
    })
    const p = container.querySelector('[aria-label="Preview"]')
    expect(p.querySelector('img')).toBeNull()
    expect(p.textContent).toContain('<img src=x onerror=alert(1)>')
    expect(p.querySelector('a').protocol).not.toBe('javascript:')
  })

  it('says so when there is nothing to show', () => {
    const { container } = setup({ value: '   ', preview: true })
    expect(container.querySelector('[aria-label="Preview"]').textContent.trim())
      .toBe('Nothing to preview yet.')
  })
})

describe('Editor — the toolbar', () => {
  // This is the one reason the toolbar is a role="toolbar" and not just
  // a row of buttons: without a roving tabindex there are twelve tab
  // stops between the previous field and the text itself.
  it('is one tab stop, not one per button', () => {
    const { container } = setup({ value: '' })
    const buttons = [...container.querySelectorAll('[role="toolbar"] button')]
    expect(buttons.length).toBeGreaterThan(5)
    expect(buttons.filter((b) => b.tabIndex === 0)).toHaveLength(1)
  })

  it('arrow keys move focus between the buttons', async () => {
    const { container } = setup({ value: '' })
    const bar = container.querySelector('[role="toolbar"]')
    const buttons = [...bar.querySelectorAll('button')]
    await fireEvent.keyDown(bar, { key: 'ArrowRight' })
    expect(document.activeElement).toBe(buttons[1])
    await fireEvent.keyDown(bar, { key: 'End' })
    expect(document.activeElement).toBe(buttons[buttons.length - 1])
    await fireEvent.keyDown(bar, { key: 'Home' })
    expect(document.activeElement).toBe(buttons[0])
  })

  it('the toolbar string decides what is shown', () => {
    const { container } = setup({ value: '', toolbar: 'bold italic' })
    const buttons = [...container.querySelectorAll('[role="toolbar"] button')]
    expect(buttons.map((b) => b.getAttribute('aria-label'))).toEqual(['Bold', 'Italic'])
  })

  // A typo in the toolbar string should cost a button, not the page.
  it('an unknown name is skipped rather than thrown', () => {
    const { container } = setup({ value: '', toolbar: 'bold fluff italic' })
    const buttons = [...container.querySelectorAll('[role="toolbar"] button')]
    expect(buttons.map((b) => b.getAttribute('aria-label'))).toEqual(['Bold', 'Italic'])
  })

  it('every button has a name', () => {
    const { container } = setup({ value: '' })
    for (const b of container.querySelectorAll('[role="toolbar"] button'))
      expect(b.getAttribute('aria-label')).toBeTruthy()
  })
})

describe('Editor — inside a Field', () => {
  it('is wired to the label, the error and the description', () => {
    const { container } = render(EditorField, {
      label: 'Release notes',
      description: 'Markdown is fine.',
      error: 'Write something.',
      value: '',
    })
    const area = container.querySelector('textarea')
    const label = container.querySelector('label')
    expect(label.getAttribute('for')).toBe(area.id)
    expect(area.getAttribute('aria-invalid')).toBe('true')
    const describedBy = area.getAttribute('aria-describedby').split(' ')
    expect(describedBy).toHaveLength(2)
    for (const id of describedBy) expect(container.querySelector(`#${id}`)).toBeTruthy()
  })

  it('no axe violations', async () => {
    const { container } = render(EditorField, {
      label: 'Release notes',
      value: '# Hello\n\n- one\n- two',
      preview: true,
    })
    expect(await violations(container)).toEqual([])
  })

  it('no axe violations with an error and a description', async () => {
    const { container } = render(EditorField, {
      label: 'Release notes',
      description: 'Markdown is fine.',
      error: 'Write something.',
      value: '',
    })
    expect(await violations(container)).toEqual([])
  })
})
