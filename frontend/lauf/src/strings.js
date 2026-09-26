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
