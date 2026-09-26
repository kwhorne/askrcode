// Reads the codes qrwrite made with Chrome's own barcode reader -- the
// shape detection API, which on macOS is the system's -- and compares each
// with the text it was made from. An encoder that agrees with another
// encoder can still be wrong in the same way; a reader is the phone.
import { readFileSync } from 'node:fs'

const dir = process.env.DIR
const list = await (await fetch(process.env.CDP + '/json/list')).json()
const page = list.find((t) => t.type === 'page')
const ws = new WebSocket(page.webSocketDebuggerUrl)
await new Promise((r) => (ws.onopen = r))
let id = 0
const send = (method, params = {}) =>
  new Promise((res) => {
    const i = ++id
    ws.addEventListener('message', function h(e) {
      const m = JSON.parse(e.data)
      if (m.id === i) { ws.removeEventListener('message', h); res(m) }
    })
    ws.send(JSON.stringify({ id: i, method, params }))
  })
// BarcodeDetector is only there in a secure context, and about:blank is
// not one -- the first try asked Chrome's own omnibox page, which has it,
// and looked as if it worked. So the codes are served from localhost and
// loaded from the same origin, which also keeps the canvas readable.
await send('Page.enable')
await send('Page.navigate', { url: process.env.PAGE })
await new Promise((r) => setTimeout(r, 800))
const js = async (expression) => {
  const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true })
  if (r.result.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails))
  return r.result.result.value
}

const supported = await js(`(async () => typeof BarcodeDetector !== 'undefined' &&
  (await BarcodeDetector.getSupportedFormats()).includes('qr_code'))()`)
if (!supported) {
  console.log('SKIP  this Chrome has no QR reader in BarcodeDetector (it is there on macOS, on a secure page)')
  process.exit(2)
}

let fails = 0
const cases = readFileSync(dir + '/cases.txt', 'utf8').trim().split('\n')
for (const line of cases) {
  const [n, level, version, hex] = line.split('|')
  const want = Buffer.from(hex, 'hex').toString('utf8')
  const got = await js(`(async () => {
    const img = new Image()
    img.src = ${JSON.stringify(n + '.svg')}
    await img.decode()
    const side = img.naturalWidth || 200
    const scale = Math.max(4, Math.ceil(800 / side))
    const c = document.createElement('canvas')
    c.width = c.height = side * scale
    const g = c.getContext('2d')
    g.imageSmoothingEnabled = false
    g.drawImage(img, 0, 0, c.width, c.height)
    const found = await new BarcodeDetector({ formats: ['qr_code'] }).detect(c)
    return found.length ? found[0].rawValue : null
  })()`)
  if (got === want) console.log(`  ok    level ${level}, version ${version}, ${Buffer.byteLength(want)} bytes`)
  else {
    fails++
    console.log(`  FAIL  level ${level}, version ${version}, ${Buffer.byteLength(want)} bytes: ` +
      (got === null ? 'not read at all' : 'read as something else'))
  }
}
ws.close()
process.exit(fails ? 1 : 0)
