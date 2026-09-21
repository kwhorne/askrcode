import { describe, it, expect } from 'vitest'
import { renderMarkdown, escapeHtml } from '../src/markdown.js'

describe('renderMarkdown', () => {
  it('headings, paragraphs and rules', () => {
    expect(renderMarkdown('# Title')).toBe('<h1>Title</h1>')
    expect(renderMarkdown('###### Six')).toBe('<h6>Six</h6>')
    expect(renderMarkdown('####### Seven')).toBe('<p>####### Seven</p>')
    expect(renderMarkdown('---')).toBe('<hr>')
  })

  it('lines join into a paragraph, a blank line separates', () => {
    expect(renderMarkdown('one\ntwo\n\nthree')).toBe('<p>one two</p>\n<p>three</p>')
  })

  it('bold, italic, strikethrough and code', () => {
    expect(renderMarkdown('**a**')).toBe('<p><strong>a</strong></p>')
    expect(renderMarkdown('__a__')).toBe('<p><strong>a</strong></p>')
    expect(renderMarkdown('*a*')).toBe('<p><em>a</em></p>')
    expect(renderMarkdown('~~a~~')).toBe('<p><del>a</del></p>')
    expect(renderMarkdown('`a`')).toBe('<p><code>a</code></p>')
  })

  // An underscore inside a word is not italic. snake_case is far more
  // common in developer text than italics around two words, and Askr's
  // own columns are named exactly that way.
  it('an underscore inside a word is not italic', () => {
    expect(renderMarkdown('the released_on column')).toBe('<p>the released_on column</p>')
  })

  // What makes code code: the contents are not interpreted.
  it('markdown inside code is left alone', () => {
    expect(renderMarkdown('`**not bold**`')).toBe('<p><code>**not bold**</code></p>')
  })

  it('lists', () => {
    expect(renderMarkdown('- one\n- two')).toBe('<ul><li>one</li><li>two</li></ul>')
    expect(renderMarkdown('1. one\n2. two')).toBe('<ol><li>one</li><li>two</li></ol>')
    // Switching list type ends the previous one rather than mixing them.
    expect(renderMarkdown('- one\n1. two')).toBe('<ul><li>one</li></ul>\n<ol><li>two</li></ol>')
  })

  it('a quote becomes one block, not one per line', () => {
    expect(renderMarkdown('> one\n> two')).toBe('<blockquote><p>one two</p></blockquote>')
  })

  it('a fenced block takes its contents verbatim', () => {
    const out = renderMarkdown('```pascal\n# not a heading\n- not a list\n```')
    expect(out).toBe(
      '<pre><code class="language-pascal"># not a heading\n- not a list</code></pre>'
    )
  })

  it('an unclosed fence takes the rest, without hanging', () => {
    expect(renderMarkdown('```\na\nb')).toBe('<pre><code>a\nb</code></pre>')
  })

  it('links', () => {
    expect(renderMarkdown('[Askr](https://askr.dev)')).toBe(
      '<p><a href="https://askr.dev">Askr</a></p>'
    )
    // Empty text: the address is the text. Otherwise the link is invisible.
    expect(renderMarkdown('[](https://askr.dev)')).toBe(
      '<p><a href="https://askr.dev">https://askr.dev</a></p>'
    )
    expect(renderMarkdown('[up](/docs/mail)')).toBe('<p><a href="/docs/mail">up</a></p>')
  })
})

// This is the part that decides whether the component is safe. The text
// comes from whoever is typing, and the preview runs in the reader's
// browser on the app's own domain. Let any of this through and the editor
// is a stored XSS with nothing in the app to say so.
describe('renderMarkdown — nothing executes', () => {
  it('raw HTML is escaped, not interpreted', () => {
    expect(renderMarkdown('<script>alert(1)</script>')).toBe(
      '<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>'
    )
    expect(renderMarkdown('<img src=x onerror=alert(1)>')).toBe(
      '<p>&lt;img src=x onerror=alert(1)&gt;</p>'
    )
  })

  it('HTML inside a fenced block is escaped too', () => {
    expect(renderMarkdown('```\n<script>alert(1)</script>\n```')).toBe(
      '<pre><code>&lt;script&gt;alert(1)&lt;/script&gt;</code></pre>'
    )
  })

  it('javascript: and data: in a link become #', () => {
    for (const u of [
      'javascript:alert(1)',
      'JavaScript:alert(1)',
      'jAvAsCrIpT:alert(1)',
      'data:text/html,<script>alert(1)</script>',
      'vbscript:msgbox(1)',
    ]) {
      const out = renderMarkdown(`[click](${u})`)
      expect(out, u).toBe('<p><a href="#">click</a></p>')
    }
  })

  it('http, mailto, tel and relative addresses pass', () => {
    for (const u of ['https://a.example', 'http://a.example', 'mailto:a@b.no',
                     'tel:+4712345678', '/docs', '#anchor', 'page.html']) {
      expect(renderMarkdown(`[k](${u})`), u).toContain(`href="${u}"`)
    }
  })

  // A quote in the address would otherwise close the href attribute and
  // open a new one — the classic way out of a string.
  it('a quote in the address does not break out of the attribute', () => {
    const out = renderMarkdown('[k](https://a.example/")')
    expect(out).toBe('<p><a href="https://a.example/&quot;">k</a></p>')
  })

  // With a space in it, it is not a link at all, and the text stays text
  // — escaped.
  it('an address with a space does not become a link', () => {
    const out = renderMarkdown('[k](https://a.example" onmouseover="alert(1))')
    expect(out).not.toContain('<a ')
    expect(out).toContain('&quot;')
  })

  // The final check, and the only one that counts: what the browser's own
  // parser does with the output. A regex assertion about the text is my
  // idea of HTML; `a.protocol` is HTML.
  //
  // java&#115;cript: is the case that is otherwise easy to get wrong. Raw
  // in an attribute, the parser decodes &#115; to s and the address runs.
  // Here the & has already become &amp;, so the parser yields the literal
  // text and there is no scheme at all.
  it('no address turns into an executable scheme in the DOM', () => {
    const dangerous = [
      'javascript:alert(1)',
      'JAVASCRIPT:alert(1)',
      '  javascript:alert(1)',
      'java&#115;cript:alert(1)',
      'data:text/html,<script>alert(1)</script>',
      'vbscript:msgbox(1)',
      'jav\tascript:alert(1)',
    ]
    for (const u of dangerous) {
      const d = document.createElement('div')
      d.innerHTML = renderMarkdown(`[k](${u})`)
      const a = d.querySelector('a')
      const protocol = a ? a.protocol : '(no link)'
      expect(['javascript:', 'data:', 'vbscript:'], `${u} -> ${protocol}`)
        .not.toContain(protocol)
    }
  })

  // Balanced parentheses belong to the address, not to the text after it.
  it('parentheses in the address are kept', () => {
    expect(renderMarkdown('[k](https://e.org/wiki/Foo_(bar))')).toBe(
      '<p><a href="https://e.org/wiki/Foo_(bar)">k</a></p>'
    )
  })

  // A query string with & in it must not become &amp;amp;.
  it('the address is escaped once, not twice', () => {
    expect(renderMarkdown('[k](https://a.example/?a=1&b=2)')).toBe(
      '<p><a href="https://a.example/?a=1&amp;b=2">k</a></p>'
    )
  })

  it('escapeHtml covers all five characters', () => {
    expect(escapeHtml(`&<>"'`)).toBe('&amp;&lt;&gt;&quot;&#39;')
  })
})
