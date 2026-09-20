<script>
  import { getContext } from 'svelte'
  import { cn } from './utils.js'
  import { FORM, FIELD } from './context.js'
  import { controlClasses, heights } from './control.js'
  import Icon from './Icon.svelte'

  let {
    value = $bindable(),
    type = 'text',
    /** sm | base | lg */
    size = 'base',
    icon,
    class: klass,
    ...rest
  } = $props()

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

<div class="relative flex items-center">
  {#if icon}
    <span class="absolute left-3 text-muted pointer-events-none">
      <Icon {icon} size="sm" />
    </span>
  {/if}
  <input
    {type}
    id={field?.id}
    value={current}
    oninput={onInput}
    aria-invalid={field?.invalid ? 'true' : undefined}
    aria-describedby={field?.describedBy}
    required={field?.required || undefined}
    class={cn(controlClasses, heights[size] ?? heights.base, icon && 'pl-9', 'border-line', klass)}
    data-lauf="input"
    {...rest}
  />
</div>
