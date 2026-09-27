import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, cleanup } from '@testing-library/svelte'
import { flushSync } from 'svelte'
import { liveStream } from '../src/inertia/live.js'

// An EventSource that records what was opened and lets a test send events.
class FakeSource {
  static opened = []
  constructor(url) {
    this.url = url
    this.listeners = {}
    this.closed = false
    FakeSource.opened.push(this)
  }
  addEventListener(name, fn) {
    ;(this.listeners[name] ??= []).push(fn)
  }
  removeEventListener(name, fn) {
    this.listeners[name] = (this.listeners[name] ?? []).filter((f) => f !== fn)
  }
  close() {
    this.closed = true
  }
  send(name, data) {
    for (const fn of this.listeners[name] ?? []) fn({ data })
  }
}

const reloads = []

// The router's methods use `this`, as Inertia's do: a detached
// router.reload would fail here the way it fails in a browser.
vi.mock('@inertiajs/svelte', async () => {
  const { page } = await import('./fixtures/livePage.svelte.js')
  return {
    page,
    router: {
      reloads,
      reload(opts) {
        this.reloads.push(opts)
      },
    },
  }
})

beforeEach(() => {
  FakeSource.opened.length = 0
  reloads.length = 0
  vi.useFakeTimers()
})
afterEach(() => {
  cleanup()
  vi.useRealTimers()
})

describe('liveStream', () => {
  it('reloads the props an event names, once for events close together', () => {
    const asked = []
    liveStream('/_askr/live?x', (only) => asked.push(only), { EventSource: FakeSource })
    const s = FakeSource.opened[0]
    expect(s.url).toBe('/_askr/live?x')
    s.send('askr.stale', '{"props":["gadgets"]}')
    s.send('askr.stale', '{"props":["stats","gadgets"]}')
    expect(asked).toEqual([])
    vi.advanceTimersByTime(60)
    expect(asked).toEqual([['gadgets', 'stats']])
  })

  it('ignores an event it cannot read', () => {
    const asked = []
    liveStream('/u', (only) => asked.push(only), { EventSource: FakeSource })
    FakeSource.opened[0].send('askr.stale', 'not json')
    FakeSource.opened[0].send('askr.stale', '{"props":"gadgets"}')
    vi.advanceTimersByTime(60)
    expect(asked).toEqual([])
  })

  it('closes, and drops a reload that was waiting', () => {
    const asked = []
    const stop = liveStream('/u', (only) => asked.push(only), { EventSource: FakeSource })
    FakeSource.opened[0].send('askr.stale', '{"props":["gadgets"]}')
    stop()
    vi.advanceTimersByTime(60)
    expect(FakeSource.opened[0].closed).toBe(true)
    expect(asked).toEqual([])
  })

  it('opens nothing without a URL', () => {
    liveStream(undefined, () => {}, { EventSource: FakeSource })
    liveStream('', () => {}, { EventSource: FakeSource })
    expect(FakeSource.opened).toEqual([])
  })
})

describe('Live', async () => {
  const { page } = await import('./fixtures/livePage.svelte.js')
  const { Live } = await import('../src/inertia/index.js')

  it('follows the page: opens its stream, keeps it across a reload, closes it on a page without one', () => {
    globalThis.EventSource = FakeSource
    page.props = { askrLive: '/_askr/live?a' }
    render(Live)
    flushSync()
    expect(FakeSource.opened.map((s) => s.url)).toEqual(['/_askr/live?a'])

    FakeSource.opened[0].send('askr.stale', '{"props":["gadgets"]}')
    vi.advanceTimersByTime(60)
    expect(reloads).toEqual([{ only: ['gadgets'] }])

    // A partial reload replaces the props object and keeps the URL.
    page.props = { ...page.props, gadgets: [1] }
    flushSync()
    expect(FakeSource.opened.length).toBe(1)
    expect(FakeSource.opened[0].closed).toBe(false)

    page.props = { other: 1 }
    flushSync()
    expect(FakeSource.opened[0].closed).toBe(true)
    expect(FakeSource.opened.length).toBe(1)
    delete globalThis.EventSource
  })
})
