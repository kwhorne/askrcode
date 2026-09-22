// Validates a document against the OpenAPI meta-schema.
//
// A real validator, not a shape we believe in. The document is generated
// by Askr.OpenApi, and the suite checks that the fields it meant to write
// are where it meant to put them -- which is a check against the author's
// own understanding of OpenAPI. This one checks it against OpenAPI.
//
// The meta-schema is bundled with the package, so this runs offline.
import { readFileSync } from 'node:fs'
import { Validator } from '@seriousme/openapi-schema-validator'

const file = process.argv[2]
if (!file) {
  console.error('usage: validate.mjs <document.json>')
  process.exit(2)
}

let doc
try {
  doc = JSON.parse(readFileSync(file, 'utf8'))
} catch (e) {
  console.error(`${file} is not JSON: ${e.message}`)
  process.exit(1)
}

const validator = new Validator()
const res = await validator.validate(doc)

if (!res.valid) {
  console.error(`${file} is not a valid OpenAPI document.`)
  console.error(`version reported: ${validator.version ?? 'none'}`)
  for (const e of res.errors ?? []) {
    console.error(`  ${e.instancePath || '/'}: ${e.message}`)
  }
  process.exit(1)
}

// Resolving every $ref is a separate question from the document being
// shaped right, and it is the one that catches a schema name that was
// written in one place and referred to in another.
const refs = []
const walk = (node, path) => {
  if (node === null || typeof node !== 'object') return
  if (Array.isArray(node)) {
    node.forEach((v, i) => walk(v, `${path}/${i}`))
    return
  }
  for (const [k, v] of Object.entries(node)) {
    if (k === '$ref' && typeof v === 'string') refs.push([path, v])
    else walk(v, `${path}/${k}`)
  }
}
walk(doc, '')

const missing = []
for (const [where, ref] of refs) {
  if (!ref.startsWith('#/')) continue
  let node = doc
  for (const part of ref.slice(2).split('/')) {
    node = node?.[part.replace(/~1/g, '/').replace(/~0/g, '~')]
  }
  if (node === undefined) missing.push(`${where}: ${ref}`)
}
if (missing.length > 0) {
  console.error(`${file} refers to schemas that are not there:`)
  for (const m of missing) console.error(`  ${m}`)
  process.exit(1)
}

console.log(`ok: valid OpenAPI ${validator.version}, ${refs.length} ref(s) resolve`)
