// @vitest-environment node
//
// Every theme, measured as written. The files are parsed here, not the
// generator's own numbers read back: what an app imports is what is held to
// the contrast. Every gray with every accent, light and dark -- the default
// "askr" theme too.

import { describe, it, expect } from 'vitest'
import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import { execFileSync } from 'node:child_process'
import { contrast, over } from '../src/color.js'

const ROOT = join(import.meta.dirname, '..')
const THEMES = join(ROOT, 'src', 'themes')
const TEXT = 4.5
const NON_TEXT = 3

// The three blocks of a theme file, each as token -> value.
function blocks(css) {
  const grab = (re) => {
    const m = css.match(re)
    if (!m) return null
    return Object.fromEntries([...m[1].matchAll(/--color-([a-z-]+):\s*([^;]+);/g)].map((x) => [x[1], x[2].trim()]))
  }
  return {
    light: grab(/^:root\s*\{([^}]*)\}/m),
    systemDark: grab(/@media \(prefers-color-scheme: dark\)\s*\{\s*:root:not\(\[data-theme='light'\]\)\s*\{([^}]*)\}/),
    chosenDark: grab(/:root\[data-theme='dark'\]\s*\{([^}]*)\}/),
  }
}

// Lauf's own theme.css: its light values are in @theme, not :root.
function askrBlocks() {
  const css = readFileSync(join(ROOT, 'src', 'theme.css'), 'utf8')
  const b = blocks(css.replace('@theme {', ':root {'))
  return b
}

const grays = Object.fromEntries(
  readdirSync(THEMES).filter((f) => f.endsWith('.css')).map((f) => [f.slice(0, -4), blocks(readFileSync(join(THEMES, f), 'utf8'))]))
const accents = Object.fromEntries(
  readdirSync(join(THEMES, 'accent')).map((f) => [f.slice(0, -4), blocks(readFileSync(join(THEMES, 'accent', f), 'utf8'))]))

// A value that names another token -- the base accent does -- is that token.
function resolve(tokens, v) {
  const m = v.match(/^var\(--color-([a-z-]+)\)$/)
  return m ? resolve(tokens, tokens[m[1]]) : v
}

// Everything a page reads, for one gray and one accent in one mode.
function problems(t) {
  const bad = []
  const need = (what, a, b, min) => {
    const r = contrast(resolve(t, t[a]), resolve(t, t[b]))
    if (r < min) bad.push(`${what}: ${a} on ${b} is ${r.toFixed(2)}, needs ${min}`)
  }
  const tint = (what, fgToken, bgToken) => {
    const fg = resolve(t, t[fgToken])
    const bg = over(resolve(t, t[bgToken]), 0.15, resolve(t, t.surface))
    const r = contrast(fg, bg)
    if (r < TEXT) bad.push(`${what}: ${fgToken} on a 15% ${bgToken} tint is ${r.toFixed(2)}`)
  }
  for (const s of ['surface', 'raised']) {
    need('text', 'fg', s, TEXT)
    need('muted text', 'muted', s, TEXT)
    need('danger text', 'danger', s, TEXT)
    need('accent text', 'accent-content', s, TEXT)
    need('the accent fill and focus ring', 'accent', s, NON_TEXT)
  }
  // Muted text on the tints components lay under it: a tab's count.
  for (const s of ['surface', 'raised']) {
    for (const [tok, alpha] of [['line', 0.7], ['fg', 0.1]]) {
      const bg = over(resolve(t, t[tok]), alpha, resolve(t, t[s]))
      const r = contrast(resolve(t, t.muted), bg)
      if (r < TEXT) bad.push(`muted text on ${tok} at ${alpha * 100}% over ${s} is ${r.toFixed(2)}`)
    }
  }
  need('a primary button', 'accent-fg', 'accent', TEXT)
  need('a danger button', 'danger-fg', 'danger', TEXT)
  tint('an accent badge', 'accent-content', 'accent')
  tint('a danger badge', 'danger', 'danger')
  return bad
}

describe('themes', () => {
  it('are what scripts/themes.mjs writes', () => {
    execFileSync('node', [join(ROOT, 'scripts', 'themes.mjs'), '--check'], { stdio: 'pipe' })
  })

  it('has the grays and accents it names, and the manifest agrees', () => {
    const m = JSON.parse(readFileSync(join(THEMES, 'themes.json'), 'utf8'))
    expect(Object.keys(grays).sort()).toEqual(Object.keys(m.grays).sort())
    expect(Object.keys(accents).sort()).toEqual(Object.keys(m.accents).sort())
    expect(Object.keys(grays)).toHaveLength(9)
    expect(Object.keys(accents)).toHaveLength(18)
  })

  it('every file has the three states, with the same tokens in each', () => {
    for (const [name, b] of [...Object.entries(grays), ...Object.entries(accents).map(([n, x]) => [`accent/${n}`, x])]) {
      expect(b.light, name).not.toBeNull()
      expect(b.systemDark, name).not.toBeNull()
      expect(b.chosenDark, name).toEqual(b.systemDark)
      expect(Object.keys(b.systemDark).sort(), name).toEqual(Object.keys(b.light).sort())
    }
  })

  it('every gray with every accent reads, light and dark', () => {
    const bad = []
    for (const [g, gb] of Object.entries(grays)) {
      for (const [a, ab] of Object.entries(accents)) {
        for (const mode of ['light', 'systemDark']) {
          for (const p of problems({ ...gb[mode], ...ab[mode] })) bad.push(`${g} + ${a}, ${mode}: ${p}`)
        }
      }
    }
    expect(bad).toEqual([])
  })

  it('and the default theme, askr, reads too', () => {
    const b = askrBlocks()
    expect(b.systemDark).toEqual(b.chosenDark)
    expect([...problems(b.light), ...problems(b.systemDark)]).toEqual([])
  })

  it('an accent file is the accent and nothing else, so any gray can go under it', () => {
    for (const [a, b] of Object.entries(accents)) {
      expect(Object.keys(b.light).sort(), a).toEqual(['accent', 'accent-content', 'accent-fg'])
    }
  })
})
