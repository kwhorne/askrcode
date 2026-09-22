import { createInertiaApp, router } from '@inertiajs/svelte'
import { mount } from 'svelte'
import './app.css'

// Svelte 5 is mounted with mount(), not with new App().
// Inertia 3 has flash as its own field on the page object and fires an event.
router.on('flash', (event) => {
  const melding = event.detail?.flash?.success
  if (melding) {
    const el = document.createElement('div')
    // The classes are here and not in app.css because Tailwind scans this
    // file too — and because a four-line toast needs no stylesheet.
    el.className =
      'fixed bottom-5 left-1/2 -translate-x-1/2 rounded-full px-4 py-2 ' +
      'text-sm bg-accent text-accent-fg shadow-lg'
    el.setAttribute('role', 'status')
    el.textContent = melding
    document.body.appendChild(el)
    setTimeout(() => el.remove(), 4000)
  }
})

createInertiaApp({
  resolve: (name) => {
    const pages = import.meta.glob('./pages/**/*.svelte', { eager: true })
    const page = pages[`./pages/${name}.svelte`]
    if (!page) throw new Error(`No such page: ${name}`)
    return page
  },
  setup({ el, App, props }) {
    // Empty it first. Svelte 5 mounts by appending, so the fallback the
    // server rendered for readers without JavaScript would stay behind
    // the app instead of being replaced by it.
    el.innerHTML = ''
    mount(App, { target: el, props })
  },
})
