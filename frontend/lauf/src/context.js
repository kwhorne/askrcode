// Kontekstnøklene. Symboler, ikke strenger, slik at en app ikke kan treffe
// dem ved et uhell.
//
// FORM settes av <Form> og leses av Field (feil), Input og slekten (verdi)
// og Button (spinner). FIELD settes av <Field> og leses av kontrollen inni
// den, som er stedet id, aria-invalid og aria-describedby blir koblet.
//
// Begge er valgfrie. En kontroll utenfor et Field virker, og et Field
// utenfor et Form virker — da tar man `error` som prop og binder verdien
// selv. Det er den veien en app som vil bruke Inertias useForm direkte går.

export const FORM = Symbol('lauf.form')
export const FIELD = Symbol('lauf.field')

let n = 0

/** Stabil id per komponentinstans. */
export function uid(prefix) {
  n += 1
  return `${prefix}-${n}`
}
