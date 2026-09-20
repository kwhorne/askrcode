<!--
  Field — etikett, kontroll, hjelpetekst og feilmelding koblet sammen.

  Dette er komponenten biblioteket tjener seg inn på. Uten den skriver man
  `for`/`id` som må stemme, `aria-describedby` som må peke på både
  hjelpeteksten og feilen, og `aria-invalid` som må settes og fjernes igjen
  — per felt, hver gang. Det er fire ting å glemme, og ingen av dem merkes
  av den som bygger.

  Inne i et <Form> henter den feilmeldingen selv, på navnet. Utenfor tar den
  `error` som prop, slik at en app som bruker Inertias useForm direkte får
  det samme.

  En radiogruppe er ikke en etikett og en kontroll, men en gruppe kontroller
  med en overskrift. Derfor `as="fieldset"`: da blir etiketten en <legend>,
  som er det eneste en skjermleser leser opp foran hver knapp i gruppa.
-->
<script>
  import { getContext, setContext } from 'svelte'
  import { cn } from './utils.js'
  import { FORM, FIELD, uid } from './context.js'

  let {
    name,
    label,
    /** Hjelpetekst under kontrollen. Leses opp sammen med etiketten. */
    description,
    /** Overstyrer feilen fra <Form>. */
    error,
    required = false,
    /** div | fieldset — fieldset for grupper av valg. */
    as = 'div',
    children,
    class: klass,
    ...rest
  } = $props()

  const form = getContext(FORM)
  const base = uid('lauf-field')
  const controlId = `${base}-control`
  // Brukes av kontroller som ikke er «labelable» — <label for> virker bare
  // mot input, select, textarea og noen få til. En slider er en <span
  // role="slider">, og den må peke på etiketten med aria-labelledby i
  // stedet. Uten det har den ingen tilgjengelig navn i det hele tatt.
  const labelId = `${base}-label`
  const descId = `${base}-desc`
  const errId = `${base}-error`

  const message = $derived(error ?? (name && form ? form.errors?.[name] : undefined))

  // Rekkefølgen betyr noe: en skjermleser leser dem i den rekkefølgen de
  // står her, og feilen skal komme sist — det er den man skal handle på.
  const describedBy = $derived(
    [description ? descId : null, message ? errId : null].filter(Boolean).join(' ') ||
      undefined
  )

  setContext(FIELD, {
    get id() {
      return controlId
    },
    get name() {
      return name
    },
    get invalid() {
      return !!message
    },
    get describedBy() {
      return describedBy
    },
    get required() {
      return required
    },
    get labelId() {
      return label ? labelId : undefined
    },
  })
</script>

<svelte:element
  this={as}
  class={cn('flex flex-col gap-1.5', as === 'fieldset' && 'border-0 p-0 m-0', klass)}
  data-lauf="field"
  {...rest}
>
  {#if label}
    {#if as === 'fieldset'}
      <legend id={labelId} class="text-sm font-medium text-fg p-0">
        {label}{#if required}<span class="text-danger" aria-hidden="true">&nbsp;*</span>{/if}
      </legend>
    {:else}
      <label id={labelId} for={controlId} class="text-sm font-medium text-fg">
        {label}{#if required}<span class="text-danger" aria-hidden="true">&nbsp;*</span>{/if}
      </label>
    {/if}
  {/if}

  {@render children?.()}

  {#if description}
    <p id={descId} class="text-xs text-muted">{description}</p>
  {/if}

  {#if message}
    <!-- Meldingen kommer etter en rundtur til serveren, altså etter at
         fokus står et annet sted. Uten et live-område er det ingenting som
         sier fra til den som ikke ser den dukke opp. -->
    <p id={errId} class="text-xs text-danger" role="alert">{message}</p>
  {/if}
</svelte:element>
