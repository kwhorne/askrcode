// Toast-køen.
//
// Fila heter .svelte.js fordi den bruker runes. Arrayet eksporteres ikke
// direkte: en `$state`-variabel som tilordnes på nytt kan ikke eksporteres
// fra en modul i Svelte 5. Et arrayet som muteres kan, og det er det som
// gjør at <Toaster> ser endringene.

const items = $state([])
let neste = 0

/** Listen <Toaster> rendrer. Ikke muter den utenfra. */
export function toasts() {
  return items
}

export function dismiss(id) {
  const i = items.findIndex((t) => t.id === id)
  if (i >= 0) items.splice(i, 1)
}

/**
 * Legger en melding i køen.
 *
 * `duration: 0` betyr at den blir stående til noen lukker den. Det er
 * riktig for noe som krever handling — en feil man må lese — og feil for
 * en bekreftelse.
 */
export function toast(message, { variant = 'info', duration = 4000 } = {}) {
  const id = ++neste
  items.push({ id, message, variant })
  if (duration > 0) setTimeout(() => dismiss(id), duration)
  return id
}

toast.success = (m, o) => toast(m, { ...o, variant: 'success' })
toast.error = (m, o) => toast(m, { variant: 'danger', duration: 0, ...o })
toast.warning = (m, o) => toast(m, { ...o, variant: 'warning' })
