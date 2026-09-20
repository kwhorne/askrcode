import { createInertiaApp, router } from '@inertiajs/svelte'
import { mount } from 'svelte'
import './app.css'

// Svelte 5 monteres med mount(), ikke med new App().
// Inertia 3 har flash som eget felt på page-objektet og fyrer et event.
router.on('flash', (event) => {
  const melding = event.detail?.flash?.success
  if (melding) {
    const el = document.createElement('div')
    // Klassene står her og ikke i app.css fordi Tailwind skanner denne fila
    // også — og fordi en toast på fire linjer ikke trenger et eget stilark.
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
    if (!page) throw new Error(`Fant ikke siden ${name}`)
    return page
  },
  setup({ el, App, props }) {
    mount(App, { target: el, props })
  },
})
