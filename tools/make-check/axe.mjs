// axe, contrast included, over the pages `askr make resource` wrote:
// light and dark, 1280 and 390 px, and none of them may scroll sideways.
// jsdom cannot measure contrast, which is why this is in a real Chrome.
//
//   BASE=http://localhost:8353 CDP=http://127.0.0.1:9224 node axe.mjs
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
const here = dirname(fileURLToPath(import.meta.url))
const axe = readFileSync(join(here, '../../frontend/lauf/node_modules/axe-core/axe.min.js'), 'utf8')
const BASE = process.env.BASE ?? 'http://localhost:8080'
const CDP = process.env.CDP ?? 'http://127.0.0.1:9223'
const list = await (await fetch(`${CDP}/json/list`)).json()
const ws = new WebSocket(list.find((t) => t.type === 'page').webSocketDebuggerUrl)
await new Promise((r) => (ws.onopen = r))
let n = 0; const p = new Map()
ws.onmessage = (e) => { const m = JSON.parse(e.data); if (p.has(m.id)) { p.get(m.id)(m); p.delete(m.id) } }
const send = (method, params = {}) => new Promise((r) => { const i = ++n; p.set(i, r); ws.send(JSON.stringify({ id: i, method, params })) })
const js = async (expression) => (await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true })).result.result.value
const wait = (ms) => new Promise((r) => setTimeout(r, ms))
await send('Page.enable')
// A row to show: the first gadget and note there are.
const pages = ['/gadgets', '/gadgets/new', '/notes', '/notes/new', '/makers/new', '/tags', '/tags/new']
await send('Page.navigate', { url: BASE + '/gadgets' })
for (let i = 0; i < 100 && !(await js(`!!document.querySelector('main h1')`)); i++) await wait(100)
const g = await js(`document.querySelector('tbody a')?.getAttribute('href')`)
if (g) pages.push(new URL(g).pathname, new URL(g).pathname + '/edit')
// A maker's page, with the rows that point at it.
await send('Page.navigate', { url: BASE + '/makers' })
for (let i = 0; i < 100 && !(await js(`!!document.querySelector('main h1')`)); i++) await wait(100)
const mk = await js(`document.querySelector('tbody a')?.getAttribute('href')`)
if (mk) pages.push(new URL(mk).pathname)
// Run once on empty tables and once with rows: the empty list is where
// the grid lost its tab stop. With AXE_EXPECT_ROWS a missing row is a
// failure, not a smaller run -- the pages of a row would otherwise go
// unchecked in silence.
if (process.env.AXE_EXPECT_ROWS && (!g || !mk)) {
  console.log('  FAIL  there is no gadget or no maker, so their pages are not checked')
  process.exit(1)
}
let bad = 0
for (const [w, h] of [[1280, 1000], [390, 900]])
  for (const scheme of ['light', 'dark']) {
    await send('Emulation.setDeviceMetricsOverride', { width: w, height: h, deviceScaleFactor: 1, mobile: w < 500 })
    await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: scheme }] })
    for (const path of pages) {
      await send('Page.navigate', { url: BASE + path })
      // Until the page has rendered, not for a fixed time: the first load
      // of a fresh Vite optimises its dependencies and took longer than
      // the 900 ms this used to wait, and axe then judged an empty
      // document -- a failure that said nothing about the page.
      let rendered = false
      for (let i = 0; i < 100 && !rendered; i++) {
        await wait(100)
        rendered = await js(`!!document.querySelector('main h1')`)
      }
      if (!rendered) { bad++; console.log(`  FAIL  ${path} ${w} ${scheme}: the page never rendered`); continue }
      await wait(200)
      await js(axe)
      const r = await js(`axe.run(document, { resultTypes: ['violations'] }).then((r) => r.violations.map((v) => v.id + ' (' + v.impact + '): ' + v.nodes.slice(0,2).map((n) => n.target.join(' ')).join(' | ')))`)
      const wide = await js(`document.documentElement.scrollWidth > window.innerWidth`)
      if (r.length || wide) { bad++; console.log(`  FAIL  ${path} ${w} ${scheme}`); for (const v of r) console.log('        ' + v); if (wide) console.log('        the page scrolls sideways') }
      else console.log(`  ok    ${path} ${w} ${scheme}`)
    }
  }
ws.close(); process.exit(bad ? 1 : 0)
