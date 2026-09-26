// Drives the pages `askr make resource` wrote, in a real Chrome, through
// the app and Vite -- what compiling the pages cannot show: that a form
// saves, that a date survives an edit, that an error lands on the field it
// belongs to, that a delete deletes.
//
// It found two things the rest of make:check did not. Every POST from an
// Inertia page answered 419, because nothing on the page made the CSRF
// token and so no XSRF-TOKEN cookie was ever set. And the number columns
// asked DataGrid for align 'end', which it does not know. It also holds a
// fix that was found by reading: a datetime-local input sends no seconds
// when they are zero, and FillInto used to drop the value without a word.
//
//   BASE=http://localhost:8353 CDP=http://127.0.0.1:9224 node browser.mjs
const BASE = process.env.BASE ?? 'http://localhost:8080'
const CDP = process.env.CDP ?? 'http://127.0.0.1:9223'

const list = await (await fetch(`${CDP}/json/list`)).json()
const target = list.find((t) => t.type === 'page')
const ws = new WebSocket(target.webSocketDebuggerUrl)
let seq = 0
const pending = new Map()
const errors = []
ws.onmessage = (e) => {
  const m = JSON.parse(e.data)
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id) }
  if (m.method === 'Runtime.exceptionThrown')
    errors.push('exception: ' + JSON.stringify(m.params.exceptionDetails).slice(0, 300))
  if (m.method === 'Runtime.consoleAPICalled' && ['error', 'warning'].includes(m.params.type))
    errors.push(m.params.type + ': ' + m.params.args.map((a) => a.value ?? a.description).join(' ').slice(0, 300))
  if (m.method === 'Page.javascriptDialogOpening')
    send('Page.handleJavaScriptDialog', { accept: true })
  if (m.method === 'Network.responseReceived' && m.params.response.status >= 500)
    errors.push('HTTP ' + m.params.response.status + ' ' + m.params.response.url)
}
await new Promise((r) => (ws.onopen = r))
function send(method, params = {}) {
  return new Promise((res) => {
    const n = ++seq
    pending.set(n, res)
    ws.send(JSON.stringify({ id: n, method, params }))
  })
}
async function js(expression) {
  const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true })
  if (r.result?.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails).slice(0, 400))
  return r.result?.result?.value
}
const wait = (ms) => new Promise((r) => setTimeout(r, ms))
async function until(expr, what, ms = 8000) {
  const end = Date.now() + ms
  while (Date.now() < end) {
    if (await js(expr).catch(() => false)) return true
    await wait(100)
  }
  throw new Error('timed out waiting for: ' + what)
}

let fails = 0
function check(cond, what, got) {
  if (cond) console.log('  ok    ' + what)
  else { console.log('  FAIL  ' + what + (got !== undefined ? '\n        got: ' + JSON.stringify(got) : '')); fails++ }
}

await send('Page.enable')
await send('Runtime.enable')
await send('Network.enable')
await send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 1000, deviceScaleFactor: 1, mobile: false })

async function go(path) {
  await send('Page.navigate', { url: BASE + path })
  await until(`document.readyState === 'complete' && !!document.querySelector('main')`, 'page ' + path)
  await wait(300)
}

// A control by its label text, as a person finds it.
const control = (label) => `(() => {
  const l = [...document.querySelectorAll('label')].find((l) => l.textContent.trim().replace(/\\s*\\*$/, '') === ${JSON.stringify(label)})
  if (!l) return null
  return l.htmlFor ? document.getElementById(l.htmlFor) : l.querySelector('input,select,textarea')
})()`

async function fill(label, value) {
  const ok = await js(`(() => {
    const el = ${control(label)}
    if (!el) return false
    const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype
      : el.tagName === 'SELECT' ? HTMLSelectElement.prototype : HTMLInputElement.prototype
    Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, ${JSON.stringify(value)})
    el.dispatchEvent(new Event(el.tagName === 'SELECT' ? 'change' : 'input', { bubbles: true }))
    return true
  })()`)
  if (!ok) throw new Error('no control labelled ' + label)
}
const valueOf = (label) => js(`(${control(label)})?.value`)
const text = () => js('document.querySelector("main").innerText')
const rowLinks = (id) => js(`document.querySelectorAll('tbody a[href$="/gadgets/${id}"]').length`)
async function submit() {
  await js(`document.querySelector('button[type=submit]').click()`)
}

// ---- a maker ----
console.log('- makers')
await go('/makers/new')
await fill('Name', 'Acme Works')
const before = await js('location.pathname')
await submit()
await until(`/^\\/makers\\/\\d+$/.test(location.pathname)`, 'the maker page')
check(/^\/makers\/\d+$/.test(await js('location.pathname')), 'a new maker lands on its page', before)
check((await text()).includes('Acme Works'), 'which shows it')

// ---- tags: the rows a gadget ticks boxes for ----
console.log('- tags')
for (const name of ['Red', 'Blue']) {
  await go('/tags/new')
  await fill('Name', name)
  await submit()
  await until(`/^\\/tags\\/\\d+$/.test(location.pathname)`, 'the tag page for ' + name)
}
check(/^\/tags\/\d+$/.test(await js('location.pathname')), 'two tags are made through their own pages')
const ticked = (label) => js(`(${control(label)})?.checked`)
const tick = (label) => js(`(${control(label)}).click()`)

// ---- a gadget with every type ----
console.log('- gadgets')
await go('/gadgets/new')
const options = await js(`[...(${control('Maker')}).options].map((o) => o.textContent)`)
check(options.includes('Acme Works'), 'the maker is a choice in the select', options)
await fill('Name', 'Sprocket')
await fill('Notes', 'Two lines\nof notes')
await fill('Qty', '3')
await fill('Big', '9000000000')
await js(`document.querySelector('input[type=checkbox]').click()`)
await fill('Price', '12.50')
await fill('Ratio', '0.25')
await fill('Seen at', '2026-01-02T03:04')
await fill('Born', '2026-02-03')
await fill('Meta', '{"k":1}')
await fill('Tag', '123e4567-e89b-12d3-a456-426614174000')
const makerId = await js(`[...(${control('Maker')}).options].find((o) => o.textContent === 'Acme Works').value`)
await fill('Maker', makerId)
check((await ticked('Red')) === false && (await ticked('Blue')) === false,
  'a new gadget starts with no tag ticked')
await tick('Red')
await submit()
await until(`/^\\/gadgets\\/\\d+$/.test(location.pathname)`, 'the gadget page')
const gid = (await js('location.pathname')).split('/').pop()
let t = await text()
check(t.includes('Sprocket'), 'the gadget is saved and shown')
check(t.includes('9000000000'), 'a bigint larger than 32 bits survives', t)
check(t.includes('2026-01-02 03:04:00'), 'a datetime sent without seconds is saved', t)
check(t.includes('2026-02-03'), 'and the date', t)
check(t.includes('Acme Works'), 'the maker is shown by its name, not its id', t)
check(/Active\s*Yes/.test(t), 'the checkbox saved', t)
check(t.includes('{"k":1}') || t.includes('{"k": 1}'), 'the JSON', t)
check((await js('document.body.innerText')).includes('Gadget created.'), 'and the flash says so')
check(/Tags\s*Red/.test(t) && !t.includes('Blue'), 'the ticked tag is saved, and only that one', t)
check(await js(`[...document.querySelectorAll('main a')].some((a) => a.textContent.trim() === 'Red' && /\\/tags\\/\\d+$/.test(a.getAttribute('href')))`),
  'and links to its own page')

// ---- the maker's page lists what points at it ----
await go(`/makers/${makerId}`)
check(await js(`[...document.querySelectorAll('main a')].some((a) => a.textContent.trim() === 'Sprocket' && a.getAttribute('href').endsWith('/gadgets/${gid}'))`),
  'the maker\'s page lists its gadget, linked to the gadget\'s page')

// And a maker with none: its page lists nothing, not every gadget there is.
await go('/makers/new')
await fill('Name', 'Empty Co')
await submit()
await until(`/^\\/makers\\/\\d+$/.test(location.pathname) && location.pathname !== '/makers/${makerId}'`, 'the second maker')
t = await text()
check(t.includes('None yet') && !t.includes('Sprocket'),
  'a maker with no gadgets lists none, not another maker\'s', t.slice(0, 300))

// ---- the edit form starts from the row ----
await go(`/gadgets/${gid}/edit`)
check((await valueOf('Name')) === 'Sprocket', 'the edit form has the name')
check((await valueOf('Seen at'))?.startsWith('2026-01-02T03:04'), 'and the datetime, in the form the input takes', await valueOf('Seen at'))
check((await valueOf('Born')) === '2026-02-03', 'and the date', await valueOf('Born'))
check((await valueOf('Maker')) === makerId, 'and the maker is selected', await valueOf('Maker'))
check(await js(`document.querySelector('input[type=checkbox]').checked`), 'and the checkbox is ticked')
check((await ticked('Red')) === true && (await ticked('Blue')) === false,
  'and the tag it has is ticked, and only that one')
await fill('Name', 'Sprocket II')
await tick('Red')
await tick('Blue')
await submit()
await until(`location.pathname === '/gadgets/${gid}'`, 'back on the gadget page')
t = await text()
check(t.includes('Sprocket II'), 'the edit is saved')
check(t.includes('2026-01-02 03:04:00'), 'and the datetime nobody touched is still there', t)
check(t.includes('Acme Works'), 'and the maker', t)
check(/Tags\s*Blue/.test(t) && !t.includes('Red'), 'the untick and the tick are both saved', t)
await go(`/gadgets/${gid}/edit`)
await tick('Blue')
await submit()
await until(`location.pathname === '/gadgets/${gid}'`, 'back after unticking')
t = await text()
check(!t.includes('Blue') && !t.includes('Red'), 'every box unticked is no tags, not the same tags', t)

// ---- what the rules refuse ----
await go('/gadgets/new')
await fill('Notes', 'kept')
check((await js("document.querySelector('form').checkValidity()")) === false,
  'the browser itself refuses an empty required field')
// And past the browser: the server's answer has to land on the fields too,
// for whatever the browser does not check.
await js("document.querySelector('form').noValidate = true")
await submit()
await until(`document.querySelector('[aria-invalid=true]')`, 'an error on a field')
check((await js('location.pathname')) === '/gadgets/new', 'a refused form stays on the form')
const invalid = await js(`[...document.querySelectorAll('[aria-invalid=true]')].map((e) => e.id)`)
check(invalid.length >= 3, 'the required fields are marked invalid', invalid)
t = await text()
check(/is required/.test(t), 'with a message a person can read', t.slice(0, 400))
check((await valueOf('Notes')) === 'kept', 'and what was typed is still there', await valueOf('Notes'))

// ---- the list ----
await go('/gadgets')
t = await text()
check(t.includes('Sprocket II'), 'the list has it')
const rows = await js(`document.querySelectorAll('tbody tr').length`)
check(rows >= 1, 'as a row', rows)
check(await js(`[...document.querySelectorAll('tbody td')].some((td) => td.textContent.trim() === '9000000000' && td.classList.contains('text-right'))`),
  'a number column is aligned to the right')
check((await rowLinks(gid)) === 1, 'its row links to its page')
await js(`(() => { const i = document.querySelector('input[type=search]'); if (!i) return false;
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(i, 'nothing-matches-this');
  i.dispatchEvent(new Event('input', { bubbles: true })); return true })()`)
await until(`location.search.includes('q=nothing-matches-this')`, 'the search in the URL')
await wait(400)
check(!(await text()).includes('Sprocket II'), 'a search the server answers hides it')
await go('/gadgets')
await js(`[...document.querySelectorAll('th button')].find((b) => b.textContent.includes('Qty'))?.click()`)
await until(`location.search.includes('sort=qty')`, 'sort in the URL')
check((await js('location.search')).includes('sort=qty'), 'a header sorts, on the server')

// ---- delete ----
await go(`/gadgets/${gid}`)
await js(`[...document.querySelectorAll('button')].find((b) => b.textContent.trim() === 'Delete').click()`)
await until(`location.pathname === '/gadgets'`, 'the list after a delete')
await wait(300)
check((await rowLinks(gid)) === 0, 'a delete removes that row from the list')
check((await js('document.body.innerText')).includes('Gadget deleted.'), 'and the flash says so')

// ---- a table the model was written for ----
console.log('- notes')
await go('/notes/new')
check((await valueOf('Status')) === 'draft', 'a default from the database fills the form', await valueOf('Status'))
check((await js(`document.querySelector('input[type=checkbox]').checked`)) === false, 'and a false default leaves the box empty')
check(!(await text()).toLowerCase().includes('api token'), 'the secret is not in the form')
await fill('Title', 'First note')
await fill('Type', 'memo')
await submit()
await until(`/^\\/notes\\/\\d+$/.test(location.pathname)`, 'the note page')
t = await text()
check(t.includes('First note') && t.includes('memo'), 'a keyword column saves through its mapped property', t)
check(t.includes('draft'), 'and the default was sent and kept', t)
check(!t.toLowerCase().includes('api token'), 'and the secret is not on the page either')

// One left behind, for axe to check a list with a row in it, and the
// page and the form of that row.
await go('/gadgets/new')
await fill('Name', 'Kept')
await fill('Born', '2026-03-04')
await fill('Maker', makerId)
await submit()
await until(`/^\\/gadgets\\/\\d+$/.test(location.pathname)`, 'the kept gadget')

console.log()
if (errors.length) {
  console.log('Browser errors:')
  for (const e of errors) console.log('  ' + e)
}
check(errors.length === 0, 'no exception, console error or 5xx on the way', errors.length)
ws.close()
process.exit(fails ? 1 : 0)
