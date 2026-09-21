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

// The undo stack in <Lauf.Editor>.
//
// This is the one property of the editor jsdom cannot measure at all:
// jsdom has no document.execCommand, so the test suite runs through the
// fallback and proves nothing about undo. And undo is exactly why the
// code uses execCommand instead of assigning textarea.value: assigning
// it directly throws away the whole history, and Cmd+Z after clicking
// Bold takes you back to before everything you typed.
//
// So the check is: type something, embolden it, undo — and expect the
// text to still be there as it was, rather than gone.
async function checkEditor(send, js) {
  const problems = []
  const sel = '[data-lauf="editor"] textarea'

  await send('Page.navigate', { url: URL_BASE })
  await wait(1500)

  const present = await js(`!!document.querySelector('${sel}')`)
  if (!present) return ['found no editor on the playground']

  // That execCommand works here at all is a precondition, not a detail.
  // If it stops working we want to know immediately.
  const supported = await js(`
    (() => {
      const t = document.querySelector('${sel}')
      t.focus(); t.setSelectionRange(0, 0)
      return document.queryCommandSupported && document.queryCommandSupported('insertText')
    })()`)
  if (!supported) problems.push('execCommand("insertText") is no longer supported — undo is lost')

  // Clear the field and type for real, so there is a history to undo.
  await js(`(() => { const t = document.querySelector('${sel}'); t.focus(); t.select(); return true })()`)
  await send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Delete', code: 'Delete',
    windowsVirtualKeyCode: 46, nativeVirtualKeyCode: 46 })
  await send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Delete', code: 'Delete',
    windowsVirtualKeyCode: 46, nativeVirtualKeyCode: 46 })
  await send('Input.insertText', { text: 'hello world' })
  await wait(120)

  const before = await js(`document.querySelector('${sel}').value`)
  if (before !== 'hello world') problems.push(`typing gave "${before}", not "hello world"`)

  // Select "world" and hit bold.
  await js(`
    (() => {
      const t = document.querySelector('${sel}')
      t.focus(); t.setSelectionRange(6, 11)
      document.querySelector('[aria-label="Bold"]').click()
      return true
    })()`)
  await wait(150)
  const after = await js(`document.querySelector('${sel}').value`)
  if (after !== 'hello **world**') problems.push(`bold gave "${after}", not "hello **world**"`)

  // At 390 px the source and the preview must stack rather than sit side
  // by side. If they do not, the editor is wider than the screen and the
  // whole page scrolls sideways — and axe says nothing about that.
  await send('Emulation.setDeviceMetricsOverride', {
    width: 390, height: 900, deviceScaleFactor: 2, mobile: true,
  })
  await wait(300)
  const narrow = await js(`
    (() => {
      const e = document.querySelector('[data-lauf="editor"]')
      const t = e.querySelector('textarea')
      const p = e.querySelector('[aria-label="Preview"]')
      return JSON.stringify({
        overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth,
        stacked: p ? Math.round(p.getBoundingClientRect().top) >=
                     Math.round(t.getBoundingClientRect().bottom) : null,
      })
    })()`)
  const { overflow, stacked } = JSON.parse(narrow)
  if (overflow > 0) problems.push(`the page scrolls ${overflow} px sideways at 390 px`)
  if (stacked === false) problems.push('source and preview sit side by side at 390 px')
  await send('Emulation.setDeviceMetricsOverride', {
    width: 1280, height: 1000, deviceScaleFactor: 2, mobile: false,
  })
  await wait(200)

  // Cmd+Z. commands: ['undo'] is CDP's own way into the editing commands
  // and is the closest we get to a real keypress.
  await js(`document.querySelector('${sel}').focus(); true`)
  await send('Input.dispatchKeyEvent', {
    type: 'rawKeyDown', key: 'z', code: 'KeyZ', windowsVirtualKeyCode: 90,
    nativeVirtualKeyCode: 90, modifiers: 4, commands: ['undo'],
  })
  await send('Input.dispatchKeyEvent', {
    type: 'keyUp', key: 'z', code: 'KeyZ', windowsVirtualKeyCode: 90,
    nativeVirtualKeyCode: 90, modifiers: 4,
  })
  await wait(200)

  const undone = await js(`document.querySelector('${sel}').value`)
  if (undone !== 'hello world') {
    problems.push(
      `undo gave "${undone}", not "hello world". ` +
      'That means the edit went around the browser history — ' +
      'see write() in Editor.svelte.'
    )
  }

  return problems
}

// hidden="until-found" in a real browser.
//
// jsdom can be told the attribute is there, but it cannot say whether the
// platform means anything by it: there is no find-in-page and no
// enumerated `hidden` IDL. Chrome reflects el.hidden as the string
// "until-found" when it supports the value and as a plain boolean when it
// does not, so reading it back is the difference between "we wrote an
// attribute" and "the feature is live".
//
// The search itself cannot be driven — CDP has no find-in-page — so what
// is checked here is the platform's acceptance and the reveal path, not
// that Ctrl+F finds the text. That gap is stated in the docs.
async function checkFindable(send, js) {
  const problems = []
  await send('Page.navigate', { url: URL_BASE })
  await wait(1500)

  const state = await js(`
    (() => {
      const panels = [...document.querySelectorAll('[role="tabpanel"]')]
      const hidden = panels.filter((p) => p.hasAttribute('hidden'))
      return JSON.stringify({
        panels: panels.length,
        hidden: hidden.length,
        attr: hidden.map((p) => p.getAttribute('hidden')),
        idl: hidden.map((p) => String(p.hidden)),
        rendered: hidden.filter((p) => p.getBoundingClientRect().height > 0).length,
        cv: hidden.map((p) => getComputedStyle(p).contentVisibility),
        cvis: hidden.map((p) => p.checkVisibility()),
      })
    })()`)
  const s = JSON.parse(state)

  if (!s.panels) return ['found no tab panels on the playground']
  if (!s.hidden) problems.push('no inactive panel was hidden at all')
  for (const a of s.attr)
    if (a !== 'until-found') problems.push(`hidden attribute was "${a}", not "until-found"`)
  for (const v of s.idl)
    if (v !== 'until-found')
      problems.push(`this Chrome reflects hidden as "${v}" — it does not support until-found`)
  // Measured, not assumed: Chrome reports content-visibility: hidden on
  // an until-found panel, and getBoundingClientRect().height is 0. Note
  // that checkVisibility() returns TRUE for these — it does not account
  // for content-visibility — so it is the wrong thing to assert on, and
  // asserting on it was a bug in an earlier version of this check.
  if (s.rendered) problems.push(`${s.rendered} until-found panel(s) had layout; they must stay hidden`)
  for (const cv of s.cv)
    if (cv !== 'hidden')
      problems.push(`content-visibility was "${cv}"; until-found is not taking effect`)

  // beforematch is what the browser fires on a match. Dispatching it is
  // the closest we get to driving find-in-page, but unlike jsdom this
  // runs against the real event plumbing.
  const revealed = await js(`
    (() => {
      const p = [...document.querySelectorAll('[role="tabpanel"]')]
        .find((x) => x.hasAttribute('hidden') && x.textContent.includes('needle'))
      if (!p) return 'no hidden panel with the needle'
      p.dispatchEvent(new Event('beforematch', { bubbles: true }))
      p.id = p.id || 'askr-probe'
      return p.id
    })()`)
  // Svelte updates on a microtask, so reading the attribute in the same
  // expression is too early — that was a bug in this check, not in the
  // component.
  await wait(300)
  const stillHidden = revealed.startsWith('no ') ? revealed : await js(
    `document.getElementById(${JSON.stringify(revealed)}).hasAttribute('hidden')
       ? 'still hidden after beforematch' : 'ok'`)
  if (stillHidden !== 'ok') problems.push(`beforematch: ${stillHidden}`)

  return problems
}

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

  const editorProblems = await checkEditor(send, js)
  if (editorProblems.length) {
    brudd += editorProblems.length
    console.log('\nFEIL  editor — undo stack')
    for (const f of editorProblems) console.log(`    ${f}`)
  }

  const findableProblems = await checkFindable(send, js)
  if (findableProblems.length) {
    brudd += findableProblems.length
    console.log('\nFEIL  tabs — findable')
    for (const f of findableProblems) console.log(`    ${f}`)
  }

  console.log('')
  console.log(`  ${editorProblems.length === 0 ? 'ok  ' : 'FEIL'} ${'editor undo'.padEnd(16)} Cmd+Z after Bold keeps the text`)
  console.log(`  ${findableProblems.length === 0 ? 'ok  ' : 'FEIL'} ${'tabs findable'.padEnd(16)} Chrome accepts hidden="until-found"`)
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
