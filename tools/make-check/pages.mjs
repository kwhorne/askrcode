// The pages `askr make resource` wrote, checked as far as can be without a
// browser: each one compiles, with no warning -- Svelte's accessibility
// checks are warnings -- and every name it imports exists where it says.
//
//   node tools/make-check/pages.mjs <pages dir>
//
// The compiler is the one in frontend/lauf/node_modules, the same Svelte
// Lauf is built and tested with.
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs'
import { join, dirname, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const lauf = resolve(here, '../../frontend/lauf')
const { compile } = await import(
  pathToFileURL(join(lauf, 'node_modules/svelte/src/compiler/index.js')).href)

// What a module exports, read from its text: `export { default as X }`,
// `export { a, b }`, `export const X`, `export function X`.
function exportsOf(file) {
  const src = readFileSync(file, 'utf8')
  const names = new Set()
  for (const m of src.matchAll(/export\s*\{([^}]*)\}/g))
    for (const part of m[1].split(','))
      if (part.trim()) names.add(part.trim().split(/\s+as\s+/).pop().trim())
  for (const m of src.matchAll(/export\s+(?:const|let|function)\s+([A-Za-z_$][\w$]*)/g))
    names.add(m[1])
  return names
}

const packages = {
  '@askrcode/lauf': exportsOf(join(lauf, 'src/index.js')),
  '@askrcode/lauf/inertia': exportsOf(join(lauf, 'src/inertia/index.js')),
}

function pages(dir) {
  return readdirSync(dir).flatMap((f) => {
    const p = join(dir, f)
    return statSync(p).isDirectory() ? pages(p) : p.endsWith('.svelte') ? [p] : []
  })
}

let fails = 0
const bad = (file, what) => {
  console.log(`  FAIL  ${file}: ${what}`)
  fails++
}

for (const file of pages(process.argv[2])) {
  const src = readFileSync(file, 'utf8')
  try {
    const out = compile(src, { filename: file, generate: 'client' })
    for (const w of out.warnings) bad(file, `${w.code}: ${w.message}`)
  } catch (e) {
    bad(file, e.message)
    continue
  }
  for (const m of src.matchAll(/import\s+([^'"]+?)\s+from\s+'([^']+)'/g)) {
    const [, what, from] = m
    const named = (what.match(/\{([^}]*)\}/)?.[1] ?? '')
      .split(',').map((s) => s.trim()).filter(Boolean)
    if (from.startsWith('.')) {
      const target = resolve(dirname(file), from)
      if (!existsSync(target)) { bad(file, `${from} is not there`); continue }
      const own = exportsOf(target)
      for (const n of named) if (!own.has(n)) bad(file, `${from} exports no ${n}`)
    } else if (packages[from]) {
      for (const n of named) if (!packages[from].has(n)) bad(file, `${from} exports no ${n}`)
    } else if (from !== '@inertiajs/svelte' && !from.startsWith('@askrcode/lauf/icons')) {
      bad(file, `imports ${from}, which a new project does not have`)
    }
  }
  if (fails === 0) console.log(`  ok    ${file}`)
}
process.exit(fails ? 1 : 0)
