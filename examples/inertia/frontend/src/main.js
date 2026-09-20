import { createInertiaApp, router } from '@inertiajs/svelte'
import { mount } from 'svelte'
import './app.css'

// Svelte 5 monteres med mount(), ikke med new App().
// Inertia 3 har flash som eget felt på page-objektet og fyrer et event.
router.on('flash', (event) => {
  const melding = event.detail?.flash?.suksess
  if (melding) {
    const el = document.createElement('div')
    el.className = 'flash'
    el.textContent = melding
    document.body.appendChild(el)
    setTimeout(() => el.remove(), 4000)
  }
})

createInertiaApp({
  resolve: (name) => {
    const pages = import.meta.glob('./pages/**/*.svelte', { eager: true })
    const page = pages[`./pages/${name}.svelte`]
    if (!page) throw new Error(`Fant ikke siden ${name}`)
    return page
  },
  setup({ el, App, props }) {
    mount(App, { target: el, props })
  },
})
