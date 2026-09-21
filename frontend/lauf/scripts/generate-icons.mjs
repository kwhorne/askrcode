// Genererer én Svelte-komponent per ikon fra heroicons' SVG-kilde.
//
// Hvorfor én fil per ikon: et kart fra navn til markup holder hele settet i
// bunten uansett hvor få ikoner appen bruker, og settet er 1288 filer. Én
// modul per ikon er det som gjør at tree-shaking faktisk virker, og
// premisstesten i tests/tree-shaking.test.js holder det fast.
//
// Hvorfor markupen tas ordrett og ikke parses til path-data: heroicons er
// nesten bare <path>, men ett ikon er en <rect>, og et sett som endrer seg
// skal ikke kunne gi oss et halvt ikon uten at noe sier fra. Å kopiere
// innholdet er både enklere og mer robust enn å plukke det fra hverandre.
//
// Filene sjekkes ikke inn. Norn sjekker generert kode inn fordi det er typet
// Pascal som må kompilere sammen med appen; dette er en mekanisk kopi av en
// avhengighet som allerede ligger i node_modules, og 1288 filer ville gjort
// enhver diff uleselig. `npm run icons` kjøres av `prepare`.

import { readdir, readFile, writeFile, mkdir, rm } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const out = join(here, '..', 'src', 'icons')
const require = createRequire(import.meta.url)

// Flux' fire varianter, oversatt til heroicons' egen katalogstruktur.
const VARIANTS = [
  { name: 'outline', dir: ['24', 'outline'] },
  { name: 'solid', dir: ['24', 'solid'] },
  { name: 'mini', dir: ['20', 'solid'] },
  { name: 'micro', dir: ['16', 'solid'] },
]

function pascal(slug) {
  const s = slug.split('-').map((p) => p.charAt(0).toUpperCase() + p.slice(1)).join('')
  // En JS-identifikator kan ikke begynne med et siffer.
  return /^[0-9]/.test(s) ? 'Icon' + s : s
}

// Deler <svg …>innhold</svg> i attributtene og innmaten, uten å tolke noen
// av delene. `data-slot` fjernes — det er heroicons' eget hektepunkt for
// Tailwind, og det hører ikke hjemme i utdataet vårt.
function split(svg) {
  const open = svg.match(/<svg([^>]*)>/)
  if (!open) throw new Error('fant ingen <svg>')
  const attrs = open[1].replace(/\s*data-slot="[^"]*"/, '').trim()
  const inner = svg.slice(open.index + open[0].length, svg.lastIndexOf('</svg>')).trim()
  if (!inner) throw new Error('tomt ikon')
  return { attrs, inner }
}

function component(attrs, inner) {
  return `<!-- Generert fra heroicons (MIT). Rediger ikke; se scripts/generate-icons.mjs. -->
<script>
  let { ...rest } = $props();
</script>

<svg ${attrs} {...rest}>
  ${inner.split('\n').map((l) => l.trim()).join('\n  ')}
</svg>
`
}

async function main() {
  const root = dirname(require.resolve('heroicons/package.json'))
  await rm(out, { recursive: true, force: true })

  let total = 0
  for (const v of VARIANTS) {
    const from = join(root, ...v.dir)
    const to = join(out, v.name)
    await mkdir(to, { recursive: true })

    const files = (await readdir(from)).filter((f) => f.endsWith('.svg')).sort()
    const exports = []

    for (const file of files) {
      const slug = file.slice(0, -4)
      const svg = await readFile(join(from, file), 'utf8')
      let parts
      try {
        parts = split(svg)
      } catch (e) {
        throw new Error(`${v.name}/${file}: ${e.message}`)
      }
      await writeFile(join(to, `${slug}.svelte`), component(parts.attrs, parts.inner))
      exports.push(`export { default as ${pascal(slug)} } from './${slug}.svelte'`)
      total++
    }

    await writeFile(
      join(to, 'index.js'),
      `// Generert. Rediger ikke.\n${exports.join('\n')}\n`
    )
  }

  console.log(`lauf: ${total} icons in ${VARIANTS.length} variants`)
}

main().catch((e) => {
  // What a user of the framework sees, so: English, and it says what to do.
  // The icons are generated from heroicons and are not in git, so a freshly
  // fetched release has neither the icons nor the package to make them from
  // -- and the failure points at a path inside the package cache, which
  // explains nothing on its own.
  console.error('lauf: could not generate the icons --', e.message)
  console.error('')
  console.error('  The icons are generated from heroicons and are not in')
  console.error('  git. A freshly fetched release has to make them once:')
  console.error('')
  console.error('    (cd ' + new URL('..', import.meta.url).pathname +
    ' && npm install)')
  console.error('')
  process.exit(1)
})
