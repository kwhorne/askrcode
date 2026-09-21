// Shared between Input, Textarea and Select: the one thing a control has
// to know to behave correctly inside a Field and a Form.
//
// The value is read from <Form> when the control sits in a named <Field>,
// and from `bind:value` otherwise. That is one code path, not two — an if
// around the <input> element itself would give two places to keep the
// attributes in step.

export const controlClasses =
  'w-full rounded-control border bg-transparent text-fg text-sm px-3 py-2 ' +
  'placeholder:text-muted/70 transition-colors ' +
  'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent ' +
  'disabled:opacity-50 disabled:cursor-not-allowed ' +
  'aria-invalid:border-danger aria-invalid:focus-visible:outline-danger'

export const heights = { sm: 'h-8 py-1', base: 'h-9', lg: 'h-11 text-base' }
