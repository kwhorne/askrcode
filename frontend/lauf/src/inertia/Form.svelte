<!--
  Form — det Askr har og Flux ikke kan ha.

  Flux' loading-magi kommer av at Livewire vet når en request pågår. Askr vet
  det samme gjennom Inertia, og her er det koblet opp én gang i stedet for
  per felt: <Field> finner feilmeldingen sin på navnet, kontrollen binder seg
  til verdien, og <Button type="submit"> viser spinner. Ingen props å koble.

  Laget ligger over `router`, ikke over `useForm`. Det er et avvik fra det
  LAUF.md skrev først, og grunnen er reaktivitet: verdiene må kunne leses og
  skrives fra en annen komponent gjennom konteksten, og da er $state noe vi
  kontrollerer mens en store fra adapteren er noe vi håper på. `useForm` står
  fortsatt åpen for en app som vil ha den — da dropper man <Form> og gir
  <Field> en `error` og kontrollen en `bind:value`.
-->
<script>
  import { setContext, untrack } from 'svelte'
  import { router } from '@inertiajs/svelte'
  import { cn } from '../utils.js'
  import { FORM } from '../context.js'

  let {
    action,
    /** post | put | patch | delete | get */
    method = 'post',
    /** Startverdiene. Feltnavnene her er de <Field name="..."> viser til. */
    data = {},
    /** Feil fra serveren, typisk `errors`-propen fra Inertia. */
    errors: serverErrors,
    /** Sendes videre til Inertia (preserveScroll, only, …). */
    options = {},
    onsuccess,
    onerror,
    children,
    class: klass,
    ...rest
  } = $props()

  // untrack med vilje: `data` er startverdiene, ikke en kilde skjemaet skal
  // følge. Uten den ville en ny render av siden — for eksempel etter en
  // valideringsfeil — nullstilt det brukeren har skrevet siden sist.
  let values = $state(untrack(() => ({ ...data })))
  let processing = $state(false)

  // null betyr «ingen innsending gjort herfra ennå», og da gjelder det
  // serveren sendte med siden. Etter en innsending gjelder svaret på den.
  // To kilder uten en slik regel gir feil som blir stående etter at de er
  // rettet, eller som forsvinner før de er lest.
  let submitted = $state(null)
  const errors = $derived(submitted ?? serverErrors ?? {})

  setContext(FORM, {
    get errors() {
      return errors
    },
    get processing() {
      return processing
    },
    get values() {
      return values
    },
    get: (name) => values[name],
    set: (name, value) => {
      values[name] = value
    },
  })

  function submit(e) {
    e.preventDefault()
    if (processing) return
    processing = true
    // router[verb](...) og ikke en løsrevet referanse: metodene i Inertias
    // router kaller this.visit(), så en unbundet kopi gir «Cannot read
    // properties of undefined (reading 'visit')» — og det står ingen steder
    // at det er mottakeren som mangler.
    const verb = typeof router[(method ?? 'post').toLowerCase()] === 'function'
      ? (method ?? 'post').toLowerCase()
      : 'post'
    router[verb](action, { ...values }, {
      ...options,
      onError: (errs) => {
        submitted = errs
        onerror?.(errs)
      },
      onSuccess: (page) => {
        submitted = {}
        onsuccess?.(page)
      },
      onFinish: () => {
        processing = false
      },
    })
  }
</script>

<form
  {action}
  method={method === 'get' ? 'get' : 'post'}
  onsubmit={submit}
  class={cn('flex flex-col gap-4', klass)}
  data-lauf="form"
  {...rest}
>
  {@render children?.()}
</form>
