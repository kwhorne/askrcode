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
// Fikseturet under lander på rundt 81 kB. Taket er satt til 100 kB: løst nok
// til at en runtime-oppgradering ikke gjør testen rød uten grunn, stramt nok
// til at et ikonsett på avveie ikke får plass.
//
// Slutter den å holde, er det ikonmodellen som svikter, ikke testen.
describe('tree-shaking', () => {
  it('en app som bruker ett ikon får ett ikon i bunten', async () => {
    const result = await build({
      root: fixture,
      // Uten denne laster Vite pakkas egen vite.config.js, som selv legger
      // til svelte-pluginen. Da kjører den to ganger, og den andre runden
      // får kompilert JS inn der den venter Svelte-kilde. Feilen kommer ut
      // som «Expected token }» i en tilfeldig komponent, og peker ingen vei.
      configFile: false,
      logLevel: 'silent',
      plugins: [svelte()],
      build: {
        write: false,
        minify: true,
        rollupOptions: { input: join(fixture, 'main.js') },
      },
    })

    const chunks = (Array.isArray(result) ? result[0] : result).output
    const code = chunks.filter((c) => c.type === 'chunk').map((c) => c.code).join('')

    // Ikonet som faktisk brukes er med.
    expect(code).toContain('M8.75 2.75a.75.75 0 0 0-1.5 0v5.69')

    // Naboen i samme barrel-fil er det ikke. Den ligger i den samme
    // index.js-en som den vi importerte fra, så dette er selve påstanden.
    expect(code).not.toContain('M7.702 1.368a.75.75 0 0 1 .597 0')

    // Og ingen av de tre andre variantene drar seg med.
    expect(code).not.toContain('M3 16.5v2.25A2.25 2.25 0 0 0 5.25 21')

    const bytes = Buffer.byteLength(code, 'utf8')
    expect(bytes).toBeLessThan(100 * 1024)
  }, 120000)
})
