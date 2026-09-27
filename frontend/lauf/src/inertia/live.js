// Props gone stale, heard from Askr.
//
// Askr's LiveOn gives a page a signed stream URL as the askrLive prop, and
// PropsChanged sends `askr.stale` down it with the names of the props that
// changed. This opens the stream and asks for exactly those props again --
// an Inertia partial reload, so the page keeps its scroll, its input and
// its open menus.
//
// Events that arrive close together are one reload: a job that touches
// three rows sends three events, and the page should not ask three times.
// The event carries names only; the values come from the page's own
// handler, under the viewer's own authorisation.

export const staleEvent = 'askr.stale'

/**
 * Opens the stream at `url` and calls `reload(props)` with the names of
 * the props gone stale. Returns the function that closes it. With no URL,
 * or no EventSource, nothing is opened.
 */
export function liveStream(url, reload, { EventSource: Source = globalThis.EventSource, delayMs = 50 } = {}) {
  if (!url || typeof Source !== 'function') return () => {}
  const source = new Source(url)
  const stale = new Set()
  let timer = null

  function flush() {
    timer = null
    const only = [...stale]
    stale.clear()
    if (only.length > 0) reload(only)
  }

  function onStale(event) {
    let props
    try {
      props = JSON.parse(event.data).props
    } catch {
      return
    }
    if (!Array.isArray(props)) return
    for (const name of props) if (typeof name === 'string' && name !== '') stale.add(name)
    if (timer === null && stale.size > 0) timer = setTimeout(flush, delayMs)
  }

  source.addEventListener(staleEvent, onStale)
  return () => {
    if (timer !== null) clearTimeout(timer)
    source.removeEventListener(staleEvent, onStale)
    source.close()
  }
}
