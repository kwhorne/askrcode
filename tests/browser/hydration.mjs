// Does the client replace the server's fallback, or leave it beside the app?
//
// This cannot be read off the source. Svelte 5 mounts by appending, so the
// answer depends on one line in main.js that empties the target first, and
// jsdom runs neither Inertia's mount nor the bundle. So: a real Chrome, and
// count what is actually in the document afterwards.
//
// Measured both ways when it was written. With the line, the sentinel is
// gone and #app has 2 children; without it, the sentinel is still in the
// visible text and #app has 4 -- the reader sees the page twice.
//
// Run by: ./askr seo:check
const CDP = process.env.ASKR_CDP ?? 'http://127.0.0.1:9223'
const URL_ = process.env.ASKR_URL ?? 'http://127.0.0.1:8132/'

let list
try {
  list = await (await fetch(`${CDP}/json/list`)).json()
} catch (e) {
  // A stack trace is not a reason. Say which of the two things is missing.
  console.log(`  FEIL: ingen Chrome på ${CDP} (${e.cause?.code ?? e.message})`)
  process.exit(1)
}
const page = list.find((t) => t.type === 'page')
if (!page) {
  console.log(`  FEIL: Chrome på ${CDP} har ingen side å styre`)
  process.exit(1)
}
const ws = new WebSocket(page.webSocketDebuggerUrl)
await new Promise((r) => (ws.onopen = r))

let id = 0
const pending = new Map()
ws.onmessage = (e) => {
  const m = JSON.parse(e.data)
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id) }
}
const send = (method, params = {}) =>
  new Promise((res) => { const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method, params })) })

const evaluate = async (expr) => {
  const r = await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true })
  return r.result?.result?.value
}

await send('Page.enable')
await send('Runtime.enable')
await send('Page.navigate', { url: URL_ })
// Give the bundle time to load and mount.
await new Promise((r) => setTimeout(r, 2500))

const out = await evaluate(`(() => {
  const html = document.documentElement.outerHTML
  const text = document.body.innerText
  return {
    sentinelInHtml: (html.match(/FALLBACK-SENTINEL/g) || []).length,
    sentinelInText: (text.match(/FALLBACK-SENTINEL/g) || []).length,
    mountChildren: document.getElementById('app')?.children.length ?? -1,
    bodyTextLength: text.trim().length,
    sample: text.trim().slice(0, 70).replace(/\\s+/g, ' '),
  }
})()`)

console.log('  etter hydrering:')
console.log('    FALLBACK-SENTINEL i DOM-en :', out.sentinelInHtml)
console.log('    ... i synlig tekst         :', out.sentinelInText)
console.log('    barn i #app                :', out.mountChildren)
console.log('    synlig tekst               :', out.sample)
ws.close()

// Absence is true on a page that never loaded. The first version of this
// reported ok against Chrome's own "could not connect" screen: no sentinel
// there either. So the page has to be shown to be there before its absence
// means anything.
if (out.mountChildren < 1) {
  console.log('\n  FEIL: appen monterte ikke i det hele tatt (#app har',
    out.mountChildren, 'barn) — sjekken sier ingenting om hydrering')
  process.exit(1)
}
if (out.bodyTextLength < 20) {
  console.log('\n  FEIL: siden har nesten ingen tekst — lastet den?')
  process.exit(1)
}
if (out.sentinelInText !== 0) {
  console.log('\n  FEIL: fallbacket står igjen ved siden av appen')
  process.exit(1)
}
console.log('\n  ok: appen monterte, og erstattet fallbacket')
