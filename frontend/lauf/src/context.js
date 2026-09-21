// The context keys. Symbols rather than strings, so an app cannot hit
// them by accident.
//
// FORM is set by <Form> and read by Field (errors), Input and its
// relatives (the value) and Button (the spinner). FIELD is set by <Field>
// and read by the control inside it, which is where id, aria-invalid and
// aria-describedby get wired together.
//
// Both are optional. A control outside a Field works, and a Field outside
// a Form works — then you pass `error` as a prop and bind the value
// yourself. That is the route for an app using Inertia's useForm
// directly.

export const FORM = Symbol('lauf.form')
export const FIELD = Symbol('lauf.field')

let n = 0

/** A stable id per component instance. */
export function uid(prefix) {
  n += 1
  return `${prefix}-${n}`
}
