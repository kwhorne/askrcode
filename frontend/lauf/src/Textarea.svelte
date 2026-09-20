<script>
  import { getContext } from 'svelte'
  import { cn } from './utils.js'
  import { FORM, FIELD } from './context.js'
  import { controlClasses } from './control.js'

  let { value = $bindable(), rows = 4, class: klass, ...rest } = $props()

  const field = getContext(FIELD)
  const form = getContext(FORM)
  const bound = $derived(!!form && field?.name != null)
  const current = $derived(bound ? (form.get(field.name) ?? '') : (value ?? ''))

  function onInput(e) {
    const v = e.currentTarget.value
    if (bound) form.set(field.name, v)
    else value = v
  }
</script>

<textarea
  id={field?.id}
  {rows}
  value={current}
  oninput={onInput}
  aria-invalid={field?.invalid ? 'true' : undefined}
  aria-describedby={field?.describedBy}
  required={field?.required || undefined}
  class={cn(controlClasses, 'border-line resize-y', klass)}
  data-lauf="textarea"
  {...rest}
></textarea>
