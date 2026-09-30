// Writes Lauf's themes from Tailwind's palette:
//
//   src/themes/<gray>.css          the surfaces, text, lines and danger
//   src/themes/accent/<name>.css   the accent, and what sits on it
//   src/themes/themes.json         what was chosen, for the CLI and the site
//
// An app picks one of each after Lauf's own tokens:
//
//   @import '@askrcode/lauf/theme.css';
//   @import '@askrcode/lauf/themes/stone.css';
//   @import '@askrcode/lauf/themes/accent/teal.css';
//
// Every shade is chosen by contrast, measured here, not by a name that
// usually works. A gray's muted text is the lightest that still reads on
// its surfaces; an accent's text colour is white where white reads on it
// and near-black where it does not; and an accent has to stand out from
// every gray's surface by 3:1, because it is also the focus ring and the
// fill of a checked box. A colour that cannot meet all of that in some
// shade stops the script, rather than shipping a theme that is only
// accessible in the screenshot.
//
//   node scripts/themes.mjs          write the files
//   node scripts/themes.mjs --check  exit 1 if they are not what it would write

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { createRequire } from 'node:module'
import { contrast, over } from '../src/color.js'

const require = createRequire(import.meta.url)
const HERE = dirname(new URL(import.meta.url).pathname)
const OUT = join(HERE, '..', 'src', 'themes')

export const GRAYS = ['slate', 'gray', 'zinc', 'neutral', 'stone', 'mauve', 'olive', 'mist', 'taupe']
export const ACCENTS = ['red', 'orange', 'amber', 'yellow', 'lime', 'green', 'emerald', 'teal',
  'cyan', 'sky', 'blue', 'indigo', 'violet', 'purple', 'fuchsia', 'pink', 'rose']

// What WCAG AA asks, with a margin: the arithmetic here clips a wide-gamut
// colour where a browser reduces its chroma, and the two can differ in the
// second decimal.
export const TEXT = 4.6
export const NON_TEXT = 3.1

const WHITE = '#fff'
// Tailwind's neutral-950: text on a light accent, the same on every gray.
const INK = 'oklch(14.5% 0 0)'

function palette() {
  const path = require.resolve('tailwindcss/theme.css')
  const css = readFileSync(path, 'utf8')
  const version = require('tailwindcss/package.json').version
  const colours = {}
  for (const m of css.matchAll(/--color-([a-z]+)-(\d+):\s*(oklch\([^)]*\))/g)) {
    ;(colours[m[1]] ??= {})[m[2]] = m[3]
  }
  return { colours, version }
}

function fail(message) {
  throw new Error('themes: ' + message)
}

// The first candidate that meets every requirement.
function first(candidates, ok, what) {
  for (const c of candidates) if (ok(c)) return c
  fail(`no shade for ${what} meets the contrast it needs`)
}

function grayTheme(P, gray) {
  const g = P[gray]
  const red = P.red
  const light = { surface: g['50'], raised: WHITE, fg: g['900'], line: g['200'] }
  const dark = { surface: g['950'], raised: g['900'], fg: g['100'], line: g['800'] }
  const onBoth = (t, c, min) => contrast(c, t.surface) >= min && contrast(c, t.raised) >= min
  // The lightest muted text that still reads: muted is for what matters
  // less, not for what cannot be read. On the surfaces, and on the tints
  // components lay under it -- a tab's count sits on line at 70% and on fg
  // at 10%. Chrome found that; the surfaces alone passed.
  const mutedOk = (t) => (c) => onBoth(t, c, TEXT) &&
    [t.surface, t.raised].every((b) =>
      contrast(c, over(t.line, 0.7, b)) >= TEXT && contrast(c, over(t.fg, 0.1, b)) >= TEXT)
  light.muted = first(['500', '600', '700'].map((s) => g[s]), mutedOk(light), `${gray} muted, light`)
  dark.muted = first(['400', '300', '200'].map((s) => g[s]), mutedOk(dark), `${gray} muted, dark`)
  // Danger: text on the surfaces, and on its own 15% tint (a badge).
  const dangerOk = (t) => (c) => onBoth(t, c, TEXT) && contrast(c, over(c, 0.15, t.surface)) >= TEXT
  light.danger = first(['600', '700', '800'].map((s) => red[s]), dangerOk(light), `${gray} danger, light`)
  dark.danger = first(['400', '300', '200'].map((s) => red[s]), dangerOk(dark), `${gray} danger, dark`)
  light.dangerFg = first([WHITE, INK], (c) => contrast(c, light.danger) >= TEXT, `${gray} danger text, light`)
  dark.dangerFg = first([g['950'], INK, WHITE], (c) => contrast(c, dark.danger) >= TEXT, `${gray} danger text, dark`)
  return { light, dark }
}

// Every gray's surfaces, in one mode: an accent file is shared by all.
function surfaces(grays, mode) {
  return grays.flatMap((t) => [t[mode].surface, t[mode].raised])
}

function accentTheme(P, name, grays) {
  const a = P[name]
  const pick = (mode, order) => {
    const bgs = surfaces(grays, mode)
    // The fill: stands out from every surface, and has a text colour that
    // reads on it. White in any shade before near-black in any: a teal
    // button with black text is what nobody expects, and a darker teal
    // with white is what they do.
    for (const fg of [WHITE, INK]) {
      for (const s of order) {
        const accent = a[s]
        if (!bgs.every((b) => contrast(accent, b) >= NON_TEXT)) continue
        if (contrast(fg, accent) >= TEXT) return { accent, fg, shade: s }
      }
    }
    fail(`no ${name} shade works as an accent in ${mode} mode`)
  }
  const contentOk = (mode) => (c) =>
    surfaces(grays, mode).every((b) => contrast(c, b) >= TEXT && contrast(c, over(c, 0.15, b)) >= TEXT)
  const light = pick('light', ['600', '500', '700', '800'])
  const dark = pick('dark', ['500', '400', '600', '300'])
  light.content = first(['600', '700', '800', '900'].map((s) => a[s]), contentOk('light'), `${name} text, light`)
  dark.content = first(['400', '300', '200', '100'].map((s) => a[s]), contentOk('dark'), `${name} text, dark`)
  return { light, dark }
}

function block(vars) {
  return Object.entries(vars).map(([k, v]) => `  --color-${k}: ${v};`).join('\n')
}

// The three states Lauf's own theme.css has, so an app's switch works the
// same with any theme: the light values, dark by the system unless light was
// chosen, and dark by choice.
function css(title, version, light, dark) {
  return `/* Lauf theme: ${title}.
 *
 * Written by scripts/themes.mjs from Tailwind ${version}'s palette, with
 * every shade chosen by measured contrast. Do not edit: run the script.
 * Import it after @askrcode/lauf/theme.css. */

:root {
${block(light)}
}

@media (prefers-color-scheme: dark) {
  :root:not([data-theme='light']) {
${block(dark).replace(/^/gm, '  ')}
  }
}

:root[data-theme='dark'] {
${block(dark)}
}
`
}

export function build() {
  const { colours: P, version } = palette()
  for (const n of [...GRAYS, ...ACCENTS]) if (!P[n]) fail(`Tailwind ${version} has no ${n}`)
  const grays = Object.fromEntries(GRAYS.map((g) => [g, grayTheme(P, g)]))
  const accents = Object.fromEntries(ACCENTS.map((n) => [n, accentTheme(P, n, Object.values(grays))]))
  // Base: the gray is the accent. It follows whatever gray is imported,
  // so it is written in the gray's own tokens. First, as a site lists it.
  const base = { accent: 'var(--color-fg)', 'accent-fg': 'var(--color-surface)', 'accent-content': 'var(--color-fg)' }
  const files = {}
  const manifest = { tailwind: version, grays: {}, accents: { base: { light: base, dark: base } } }
  files['accent/base.css'] = css('base, the accent in the gray itself', version, base, base)

  for (const [g, t] of Object.entries(grays)) {
    const map = (m) => ({
      surface: m.surface, raised: m.raised, fg: m.fg, muted: m.muted, line: m.line,
      danger: m.danger, 'danger-fg': m.dangerFg,
    })
    files[`${g}.css`] = css(`${g}, the gray`, version, map(t.light), map(t.dark))
    manifest.grays[g] = { light: map(t.light), dark: map(t.dark) }
  }
  for (const [n, t] of Object.entries(accents)) {
    const map = (m) => ({ accent: m.accent, 'accent-fg': m.fg, 'accent-content': m.content })
    files[`accent/${n}.css`] = css(`${n}, the accent`, version, map(t.light), map(t.dark))
    manifest.accents[n] = { light: map(t.light), dark: map(t.dark) }
  }

  files['themes.json'] = JSON.stringify(manifest, null, 2) + '\n'
  return files
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const files = build()
  const check = process.argv.includes('--check')
  let stale = []
  for (const [name, text] of Object.entries(files)) {
    const path = join(OUT, name)
    if (check) {
      if (!existsSync(path) || readFileSync(path, 'utf8') !== text) stale.push(name)
      continue
    }
    mkdirSync(dirname(path), { recursive: true })
    writeFileSync(path, text)
  }
  if (check && stale.length) {
    console.error(`themes: ${stale.length} file(s) are not what scripts/themes.mjs writes: ${stale.join(', ')}`)
    process.exit(1)
  }
  console.log(check ? 'themes: up to date' : `themes: wrote ${Object.keys(files).length} files`)
}
