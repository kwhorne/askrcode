// The words Lauf says itself: the label on a close button, the text of an
// empty list, the names of the editor's buttons.
//
// English unless an app says otherwise, once, near the root:
//
//   provideStrings(() => page.props.lauf)
//
// Askr's Inertia sends `lauf` from the app's lang files -- the [lauf]
// section of lang/<locale>.toml -- when the request's locale says something
// other than this, and leaves it out when it does not. A function rather
// than an object, so a change of language on the next page is seen without
// a reload.
//
// A placeholder is :name, as in the lang files, so a translation goes from
// the server to here as written. The keys and the English are held equal
// to the framework's by a test in askr_runtime_tests: two lists of the same
// words would drift, and the first sign would be one untranslated button.

import { getContext, setContext } from 'svelte'

const STRINGS = Symbol('lauf.strings')
const LOCALE = Symbol('lauf.locale')

export const defaults = {
  close: 'Close',
  dismiss: 'Dismiss',
  breadcrumb: 'Breadcrumb',
  main_navigation: 'Main',
  sidebar: 'Sidebar',
  pagination: 'Pagination',
  previous_page: 'Previous page',
  next_page: 'Next page',
  no_results: 'No results',
  range_of: ':from–:to of :total',
  show_suggestions: 'Show suggestions',
  type_a_command: 'Type a command…',
  commands: 'Commands',
  choose_date: 'Choose date',
  previous_month: 'Previous month',
  next_month: 'Next month',
  nothing_here: 'Nothing here',
  search: 'Search',
  search_in: 'Search :caption',
  columns: 'Columns',
  select_all_rows: 'Select all rows on this page',
  select_row: 'Select row :n',
  selected_count: ':count selected',
  pages_of: ':caption pages',
  formatting: 'Formatting',
  heading_1: 'Heading 1',
  heading_2: 'Heading 2',
  heading_3: 'Heading 3',
  bold: 'Bold',
  italic: 'Italic',
  strikethrough: 'Strikethrough',
  code: 'Code',
  quote: 'Quote',
  bulleted_list: 'Bulleted list',
  numbered_list: 'Numbered list',
  link: 'Link',
  undo: 'Undo',
  redo: 'Redo',
  show_preview: 'Show preview',
  hide_preview: 'Hide preview',
  preview: 'Preview',
  nothing_to_preview: 'Nothing to preview yet.',
  bold_text: 'bold text',
  italic_text: 'italic text',
  struck_text: 'struck out',
  code_text: 'code',
  choose_file: 'Choose a file',
  choose_files: 'Choose files',
  or_drag: 'or drag them here',
  too_large: 'Too large, not added: :names',
  remove_file: 'Remove :name',
}

/** Words for every component below: an object, or a function returning
    one, read each time a word is asked for. A key it leaves out is the
    English. Call it while a component is being set up -- a layout's
    script -- as with any context. */
export function provideStrings(source) {
  setContext(STRINGS, typeof source === 'function' ? source : () => source)
}

/** The lookup a component uses: t('close'), t('select_row', { n: 3 }).
    Longest placeholder first, so :min never takes the front off :minimum;
    one that is not given is left in the text, where it is seen. */
export function strings() {
  const source = getContext(STRINGS)
  return (key, vars) => {
    const own = source?.()
    let text = own?.[key] ?? defaults[key] ?? key
    if (vars) {
      for (const name of Object.keys(vars).sort((a, b) => b.length - a.length))
        text = text.split(':' + name).join(String(vars[name]))
    }
    return text
  }
}

// The reader's locale, for the numbers and dates Lauf writes: "1,234" in
// English is "1 234" in Norwegian, and a month has a name in each.
//
//   provideLocale(() => page.props.locale)
//
// Askr's Inertia sends `locale` on every page -- the one the request was
// answered in. Without it, English.

/** The locale for every component below: a BCP 47 tag, or a function
    returning one. As provideStrings, and next to it. */
export function provideLocale(source) {
  setContext(LOCALE, typeof source === 'function' ? source : () => source)
}

/** The locale now, as a function, for what takes a tag -- Intl, a date
    picker. Call it during setup; call what it returns when rendering. */
export function locale() {
  const source = getContext(LOCALE)
  return () => source?.() || 'en'
}

/** Both at once, for mount() at the root of the app:

      mount(App, { target: el, props, context: laufContext({
        strings: () => page.props.lauf,
        locale: () => page.props.locale,
      }) })

    The root is the place, not a layout. An Inertia page wraps itself in
    its layout, so the page is the layout's parent, and what the layout
    provides is not there for the page's own script -- a numbers() there
    would write English on a Norwegian page, while the grid inside the
    layout wrote Norwegian beside it. */
export function laufContext({ strings: words, locale: tag } = {}) {
  const context = new Map()
  if (words !== undefined) context.set(STRINGS, typeof words === 'function' ? words : () => words)
  if (tag !== undefined) context.set(LOCALE, typeof tag === 'function' ? tag : () => tag)
  return context
}

const blank = (v) => v === null || v === undefined || v === ''

/** A number as the reader writes it: n(1234) is "1,234" or "1 234".
    Options are Intl.NumberFormat's. Explicit, not applied to every
    placeholder: a year is a number too, and "2,026" is not a year. No
    number is '', not 0 -- a price nobody set is not free. */
export function numbers() {
  const current = locale()
  return (n, options) => (blank(n) ? '' : new Intl.NumberFormat(current(), options).format(n))
}

// Askr writes a date as DateTimeToSql does: 'YYYY-MM-DD HH:MM:SS', the
// wall-clock time with no zone. Built with the Date constructor from its
// parts and formatted in the browser's own zone, it comes out as the same
// wall-clock time; parsed as a string, 'YYYY-MM-DD' alone is taken as UTC
// and is the day before west of Greenwich.
const SQL_DATE = /^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2})(?::(\d{2}))?)?/

/** A date as the reader writes it, from the text Askr sends:
    d('2026-01-05 14:07:00') is "Jan 5, 2026" or "5. jan. 2026". Options
    are Intl.DateTimeFormat's, { dateStyle: 'medium' } unless given. No
    date is ''; text that is not a date comes back as it was, where it is
    seen. */
export function dates() {
  const current = locale()
  return (v, options = { dateStyle: 'medium' }) => {
    if (blank(v)) return ''
    const m = SQL_DATE.exec(String(v))
    if (!m) return String(v)
    const [, y, mo, d, h = '0', mi = '0', sec = '0'] = m
    const at = new Date(+y, +mo - 1, +d, +h, +mi, +sec)
    return new Intl.DateTimeFormat(current(), options).format(at)
  }
}
