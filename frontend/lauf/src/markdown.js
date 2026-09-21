// Markdown to HTML — exactly enough, and nothing more.
//
// Lauf has no markdown dependency and is not going to get one. `marked` is
// 40 kB and does far more than an editor preview needs; an app that only
// uses a button should not pay that, and neither should <Lauf.Editor>.
//
// The scope is therefore locked to what the toolbar can actually produce:
// headings, bold, italic, strikethrough, code, links, lists, quotes,
// rules and paragraphs.
//
// RAW HTML NEVER PASSES THROUGH. That is not a simplification, it is the
// whole security answer. Markdown allows HTML in the source, and that is
// exactly where an editor becomes a stored XSS: the text comes from
// whoever is typing, and the preview runs in the reader's browser on the
// app's own domain. Everything is escaped first, and there is no way past
// it.

const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }

/** Escapes anything that could become markup. Runs BEFORE any rule sees the text. */
export function escapeHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ESC[c])
}

// Schemes a link may use. Anything else becomes '#' rather than nothing:
// a link that vanished would look like a typo, while one that goes
// nowhere is visible to whoever wrote it.
//
// javascript: is the obvious attack. data: is the less obvious one —
// data:text/html runs just as well.
const SAFE_SCHEMES = /^(?:https?:|mailto:|tel:)/i
const HAS_SCHEME = /^[a-z][a-z0-9+.-]*:/i

function safeUrl(raw) {
  const u = String(raw ?? '').trim()
  if (u === '') return '#'
  // Relative addresses and fragments have no scheme to be dangerous with.
  if (!HAS_SCHEME.test(u)) return u
  return SAFE_SCHEMES.test(u) ? u : '#'
}

// Code spans are lifted out before the other inline rules run. Without
// that, `**not bold**` inside backticks would come out bold — and the
// whole point of code is that it is not interpreted.
function inline(src) {
  const spans = []
  let s = escapeHtml(src).replace(/`([^`]+)`/g, (_, code) => {
    spans.push(code)
    return `\u0000${spans.length - 1}\u0000`
  })

  // Balanced parentheses one level deep, on purpose: .../Foo_(bar) is a
  // common address, and javascript:alert(1) is the other one. Without
  // them the pattern stops at the first ), and half the address is left
  // sitting after the link as text.
  s = s.replace(/\[([^\]]*)\]\(((?:[^()\s]|\([^()\s]*\))*)\)/g, (_, text, url) => {
    // The url is already escaped. The scheme is checked against the
    // decoded form — otherwise &#106;avascript: would slip past — but
    // what goes into the attribute is the escaped one. Escaping again
    // would turn & into &amp;amp; in every address with a query in it.
    const decoded = url
      .replace(/&lt;/g, '<').replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"').replace(/&#39;/g, "'")
      .replace(/&amp;/g, '&')
    const href = safeUrl(decoded) === '#' ? '#' : url
    return `<a href="${href}">${text || href}</a>`
  })

  s = s
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/__([^_]+)__/g, '<strong>$1</strong>')
    .replace(/~~([^~]+)~~/g, '<del>$1</del>')
    .replace(/(^|[^*\w])\*([^*\s][^*]*)\*/g, '$1<em>$2</em>')
    .replace(/(^|[^_\w])_([^_\s][^_]*)_/g, '$1<em>$2</em>')

  return s.replace(/\u0000(\d+)\u0000/g, (_, i) => `<code>${spans[Number(i)]}</code>`)
}

/**
 * Markdown to HTML. The result carries no classes — whoever displays it
 * decides how it looks, the way <Lauf.Editor> does with arbitrary
 * variants on the preview pane.
 */
export function renderMarkdown(src) {
  const lines = String(src ?? '').replace(/\r\n?/g, '\n').split('\n')
  const out = []
  let para = []
  let listKind = null // 'ul' | 'ol'
  let items = []
  let quote = []

  const closePara = () => {
    if (para.length) out.push(`<p>${inline(para.join(' '))}</p>`)
    para = []
  }
  const closeList = () => {
    if (listKind) {
      out.push(
        `<${listKind}>${items.map((i) => `<li>${inline(i)}</li>`).join('')}</${listKind}>`
      )
      listKind = null
      items = []
    }
  }
  const closeQuote = () => {
    if (quote.length) out.push(`<blockquote><p>${inline(quote.join(' '))}</p></blockquote>`)
    quote = []
  }
  const closeAll = () => {
    closePara()
    closeList()
    closeQuote()
  }

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i]

    // Fenced code. Everything between the fences is taken verbatim,
    // including lines that would otherwise be headings or list items.
    const fence = line.match(/^\s*```+\s*([a-z0-9+#-]*)\s*$/i)
    if (fence) {
      closeAll()
      const body = []
      i += 1
      while (i < lines.length && !/^\s*```+\s*$/.test(lines[i])) {
        body.push(lines[i])
        i += 1
      }
      const lang = fence[1] ? ` class="language-${escapeHtml(fence[1])}"` : ''
      out.push(`<pre><code${lang}>${escapeHtml(body.join('\n'))}</code></pre>`)
      continue
    }

    if (line.trim() === '') {
      closeAll()
      continue
    }

    const heading = line.match(/^(#{1,6})\s+(.*?)\s*#*\s*$/)
    if (heading) {
      closeAll()
      out.push(`<h${heading[1].length}>${inline(heading[2])}</h${heading[1].length}>`)
      continue
    }

    if (/^\s*(?:-{3,}|\*{3,}|_{3,})\s*$/.test(line)) {
      closeAll()
      out.push('<hr>')
      continue
    }

    const quoted = line.match(/^\s*>\s?(.*)$/)
    if (quoted) {
      closePara()
      closeList()
      quote.push(quoted[1])
      continue
    }
    closeQuote()

    const bullet = line.match(/^\s*[-*+]\s+(.*)$/)
    if (bullet) {
      closePara()
      if (listKind !== 'ul') closeList()
      listKind = 'ul'
      items.push(bullet[1])
      continue
    }

    const numbered = line.match(/^\s*\d+[.)]\s+(.*)$/)
    if (numbered) {
      closePara()
      if (listKind !== 'ol') closeList()
      listKind = 'ol'
      items.push(numbered[1])
      continue
    }

    closeList()
    para.push(line.trim())
  }

  closeAll()
  return out.join('\n')
}
