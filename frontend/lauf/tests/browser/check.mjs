// Nettlesersjekken: kontrast og skjermdump, lys og mørk, smal og bred.
//
// Dette er det jsdom ikke kan gjøre. Det legger ikke ut noe og regner ikke
// ut farger, så axe' kontrastregel er slått av i tests/axe.js. Her kjøres
// hele axe — kontrast inkludert — i en ekte Chrome, mot lekegrinda.
//
// Fire kombinasjoner per side: lys og mørk, 390 px og 1280 px. Mørk modus
// testes begge veier — gjennom prefers-color-scheme og gjennom
// data-theme — fordi tokenene håndterer tre tilstander og ikke to, og en
// av dem kan ryke uten at den andre gjør det.
//
// Kjøres med: ./askr lauf:check

import { readFileSync, mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const axeSource = readFileSync(
  join(here, '..', '..', 'node_modules', 'axe-core', 'axe.min.js'),
  'utf8'
)

const URL_BASE = process.env.LAUF_URL ?? 'http://127.0.0.1:4173/'
const SHOTS = process.env.LAUF_SHOTS ?? join(here, '..', '..', '.shots')
const CDP = process.env.LAUF_CDP ?? 'http://127.0.0.1:9222'

const SIZES = [
  { name: '390', width: 390, height: 900, mobile: true },
  { name: '1280', width: 1280, height: 1000, mobile: false },
]

// tema: hvordan mørk modus slås på. 'system' er den vanligste — brukeren
// har ikke valgt, og da er prefers-color-scheme det eneste som skiller.
const THEMES = [
  { name: 'light', scheme: 'light', attr: null },
  { name: 'dark-system', scheme: 'dark', attr: null },
  { name: 'dark-attr', scheme: 'light', attr: 'dark' },
]

async function connect() {
  const list = await (await fetch(`${CDP}/json/list`)).json()
  const page = list.find((t) => t.type === 'page')
  if (!page) throw new Error('fant ingen side i Chrome')
  const ws = new WebSocket(page.webSocketDebuggerUrl)
  let id = 0
  const pending = new Map()
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data)
    if (m.id && pending.has(m.id)) {
      pending.get(m.id)(m)
      pending.delete(m.id)
    }
  }
  await new Promise((r) => (ws.onopen = r))
  const send = (method, params = {}) =>
    new Promise((res) => {
      const n = ++id
      pending.set(n, res)
      ws.send(JSON.stringify({ id: n, method, params }))
    })
  const js = async (expression) => {
    const r = await send('Runtime.evaluate', {
      expression,
      awaitPromise: true,
      returnByValue: true,
    })
    if (r.result?.exceptionDetails) {
      throw new Error(JSON.stringify(r.result.exceptionDetails).slice(0, 400))
    }
    return r.result?.result?.value
  }
  return { ws, send, js }
}

const wait = (ms) => new Promise((r) => setTimeout(r, ms))

async function main() {
  mkdirSync(SHOTS, { recursive: true })
  const { ws, send, js } = await connect()
  await send('Page.enable')
  await send('Runtime.enable')
  await send('Emulation.setEmulatedMedia', { media: 'screen' })

  let brudd = 0
  const rader = []

  for (const theme of THEMES) {
    for (const size of SIZES) {
      await send('Emulation.setDeviceMetricsOverride', {
        width: size.width,
        height: size.height,
        deviceScaleFactor: 2,
        mobile: size.mobile,
      })
      await send('Emulation.setEmulatedMedia', {
        features: [{ name: 'prefers-color-scheme', value: theme.scheme }],
      })
      await send('Page.navigate', { url: URL_BASE })
      await wait(1500)

      if (theme.attr) {
        await js(`document.documentElement.setAttribute('data-theme', '${theme.attr}'); true`)
        await wait(200)
      }

      // Sanity: bakgrunnen må faktisk endre seg mellom lys og mørk. Uten
      // denne kunne alle tre temaene vært like og kontrasten likevel grønn.
      const bg = await js(`getComputedStyle(document.body).backgroundColor`)

      await js(axeSource + '; true')
      const res = await js(`axe.run(document, {
        resultTypes: ['violations'],
        rules: { region: { enabled: false } }
      }).then(r => JSON.stringify(r.violations.map(v => ({
        id: v.id,
        impact: v.impact,
        nodes: v.nodes.slice(0, 3).map(n => ({
          target: n.target.join(' '),
          summary: (n.failureSummary || '').split('\\n').slice(0, 3).join(' ')
        }))
      }))))`)
      const violations = JSON.parse(res)

      const navn = `${theme.name}-${size.name}`
      const shot = await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true })
      writeFileSync(join(SHOTS, `${navn}.png`), Buffer.from(shot.result.data, 'base64'))

      rader.push({ navn, bg, brudd: violations.length })
      if (violations.length) {
        brudd += violations.length
        console.log(`\nFEIL  ${navn}  (bakgrunn ${bg})`)
        for (const v of violations) {
          console.log(`  ${v.id} [${v.impact}]`)
          for (const n of v.nodes) console.log(`    ${n.target}\n      ${n.summary}`)
        }
      }
    }
  }

  console.log('')
  for (const r of rader) {
    console.log(`  ${r.brudd === 0 ? 'ok  ' : 'FEIL'} ${r.navn.padEnd(16)} bakgrunn ${r.bg.padEnd(22)} ${r.brudd} brudd`)
  }
  console.log(`\nSkjermdumper i ${SHOTS}`)
  ws.close()
  if (brudd > 0) {
    console.log(`\n${brudd} brudd totalt.`)
    process.exit(1)
  }
  console.log('\nIngen brudd, kontrast inkludert.')
}

main().catch((e) => {
  console.error('lauf: nettlesersjekken feilet —', e.message)
  process.exit(1)
})
