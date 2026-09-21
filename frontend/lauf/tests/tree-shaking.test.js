// @vitest-environment node
//
// Denne kjører en ekte Vite-bygging, og esbuild nekter å starte i jsdom:
// jsdoms TextEncoder gir ikke en ekte Uint8Array tilbake. Node-miljø her,
// jsdom i resten av suiten.

import { describe, it, expect } from 'vitest'
import { build } from 'vite'
import { svelte } from '@sveltejs/vite-plugin-svelte'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const fixture = join(here, 'fixtures', 'one-icon')
const namespaceFixture = join(here, 'fixtures', 'namespace')

/** Builds a fixture and returns all the code that came out. */
async function buildFixture(root) {
  const result = await build({
    root,
    // Without this Vite loads the package's own vite.config.js, which
    // adds the svelte plugin itself. Then it runs twice, and the second
    // pass gets compiled JS where it expects Svelte source. The error
    // reads "Expected token }" in some random component and points
    // nowhere.
    configFile: false,
    logLevel: 'silent',
    plugins: [svelte()],
    build: {
      write: false,
      minify: true,
      rollupOptions: { input: join(root, 'main.js') },
    },
  })
  const chunks = (Array.isArray(result) ? result[0] : result).output
  return chunks.filter((c) => c.type === 'chunk').map((c) => c.code).join('')
}

// Premisstest.
//
// Hele grunnen til at ikoner er én modul hver, og til at Icon tar imot en
// komponent i stedet for et navn, er at en app som bruker ett ikon skal
// betale for ett ikon. Et navneoppslag i et kart ville holdt hele settet i
// bunten uansett hvor få appen bruker, og ingenting ville sagt fra — det
// merkes først som lastetid.
//
// Målt på denne maskinen, minifisert, uten gzip:
//
//     Svelte-runtime alene            34,5 kB
//     cn()  (clsx 0,4 + tailwind-merge 27,5)   27,9 kB
//     ett ikon via barrel-fila        29,5 kB   (mest runtime)
//     hele micro-settet, 316 ikoner  225,9 kB
//
// Etter bolk 2, gjennom barrel-fila, med et ekte mount:
//
//     Button                          74,7 kB   (uten Bits)
//     Table                           71,3 kB   (uten Bits)
//     Modal                          129,3 kB   (med Bits' Dialog)
//
// Fikseturet under lander på rundt 81 kB. Taket er satt til 100 kB: løst nok
// til at en runtime-oppgradering ikke gjør testen rød uten grunn, stramt nok
// til at et ikonsett på avveie ikke får plass.
//
// Slutter den å holde, er det ikonmodellen som svikter, ikke testen.
describe('tree-shaking', () => {
  it('en app som bruker ett ikon får ett ikon i bunten', async () => {
    const code = await buildFixture(fixture)

    // Ikonet som faktisk brukes er med.
    expect(code).toContain('M8.75 2.75a.75.75 0 0 0-1.5 0v5.69')

    // Naboen i samme barrel-fil er det ikke. Den ligger i den samme
    // index.js-en som den vi importerte fra, så dette er selve påstanden.
    expect(code).not.toContain('M7.702 1.368a.75.75 0 0 1 .597 0')

    // Og ingen av de tre andre variantene drar seg med.
    expect(code).not.toContain('M3 16.5v2.25A2.25 2.25 0 0 0 5.25 21')

    // Bolk 2 la Bits UI under Modal, Dropdown, Tooltip, Popover, Tabs,
    // Accordion og Avatar. En app som bare bruker et ikon skal ikke betale
    // for noe av det. Det gjorde den: Object.assign på modulnivå er et kall
    // en bundler ikke kan bevise er trygt å fjerne, så barrel-fila holdt
    // hele biblioteket i live — 221 kB for en knapp i stedet for 74.
    // /*#__PURE__*/ på de sammensatte eksportene er det som fikser det.
    expect(code).not.toMatch(/bits-ui|accordion-root|dialog-content/i)

    const bytes = Buffer.byteLength(code, 'utf8')
    expect(bytes).toBeLessThan(100 * 1024)
  }, 120000)

  // `import * as Lauf` + <Lauf.Button> is the form apps are meant to
  // write, because it reads like Flux's <flux:button>. That form would be
  // worthless if it dragged the whole library along, and the fact that it
  // does not is not obvious: a namespace object LOOKS like something a
  // bundler has to keep whole. Rollup follows the member lookups, and
  // this test is what holds that down — not an assumption.
  it('dot notation shakes as well as a named import', async () => {
    const named = await buildFixture(join(here, 'fixtures', 'named-button'))
    const dotted = await buildFixture(namespaceFixture)

    expect(dotted).not.toMatch(/bits-ui|accordion-root|dialog-content/i)
    // aria-rowindex is DataGrid's, the heaviest thing in the library.
    expect(dotted).not.toMatch(/aria-rowindex/)
    // The editor drags the markdown renderer with it. Neither has any
    // business in a button-only bundle.
    expect(dotted).not.toMatch(/Nothing to preview|blockquote/)

    // The comparison is the claim, not the number: how big the bundle is
    // depends on which harness builds it — the same two fixtures measure
    // 73 kB from a standalone script and 88 kB here — while the
    // DIFFERENCE between the two forms is what says whether dot notation
    // costs anything. The margin covers the minifier giving identifiers
    // different lengths; if the namespace dragged a component along the
    // gap would be kilobytes, not bytes.
    const diff = Math.abs(Buffer.byteLength(dotted, 'utf8') - Buffer.byteLength(named, 'utf8'))
    expect(diff).toBeLessThan(256)
  }, 120000)
})
