// Inngangen som kjenner Inertia.
//
// Den ligger for seg selv fordi @inertiajs/svelte er en avhengighet ESM
// løser ved bygging: lå Form i hovedinngangen, måtte enhver app som
// importerer en knapp også ha Inertia installert. En ren JSON-tjeneste
// eller et desktop-skall uten Inertia skal slippe.

export { default as Form } from './Form.svelte'
