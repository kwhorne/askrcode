// Delt mellom Input, Textarea og Select: den ene tingen en kontroll må vite
// for å oppføre seg riktig inne i et Field og et Form.
//
// Verdien leses fra <Form> når kontrollen står i et navngitt <Field>, og
// fra `bind:value` ellers. Det er én kodevei, ikke to — en if rundt selve
// <input>-elementet ville gitt to steder å holde attributtene like.

export const controlClasses =
  'w-full rounded-control border bg-transparent text-fg text-sm px-3 py-2 ' +
  'placeholder:text-muted/70 transition-colors ' +
  'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent ' +
  'disabled:opacity-50 disabled:cursor-not-allowed ' +
  'aria-invalid:border-danger aria-invalid:focus-visible:outline-danger'

export const heights = { sm: 'h-8 py-1', base: 'h-9', lg: 'h-11 text-base' }
