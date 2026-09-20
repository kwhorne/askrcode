<!-- En stylet <select>, ikke en egen nedtrekksliste.
     Den innebygde er den eneste som virker med tastatur, skjermleser og
     berøring uten at vi skriver den selv, og en egen liste hører hjemme i
     bolk 2 med Bits UI under seg. -->
<script>
  import { getContext } from 'svelte'
  import { cn } from './utils.js'
  import { FORM, FIELD } from './context.js'
  import { controlClasses, heights } from './control.js'

  let {
    value = $bindable(),
    /** Vises som første, ikke-valgbare rad når ingenting er valgt. */
    placeholder,
    size = 'base',
    children,
    class: klass,
    ...rest
  } = $props()

  const field = getContext(FIELD)
  const form = getContext(FORM)
  const bound = $derived(!!form && field?.name != null)
  const current = $derived(bound ? (form.get(field.name) ?? '') : (value ?? ''))

  function onChange(e) {
    const v = e.currentTarget.value
    if (bound) form.set(field.name, v)
    else value = v
  }
</script>

<select
  id={field?.id}
  value={current}
  onchange={onChange}
  aria-invalid={field?.invalid ? 'true' : undefined}
  aria-describedby={field?.describedBy}
  required={field?.required || undefined}
  class={cn(controlClasses, heights[size] ?? heights.base, 'border-line pr-8', klass)}
  data-lauf="select"
  {...rest}
>
  {#if placeholder}
    <option value="" disabled>{placeholder}</option>
  {/if}
  {@render children?.()}
</select>
