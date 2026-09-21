<!-- A radio button only means anything inside a group, and the group is
     a <Field as="fieldset">. The name comes from there, so two buttons
     cannot end up in separate groups because of a typo. -->
<script>
  import { getContext } from 'svelte'
  import { cn } from './utils.js'
  import { FORM, FIELD, uid } from './context.js'

  let {
    /** The value this button stands for. */
    value,
    /** Overstyrer gruppens navn. */
    name,
    label,
    description,
    disabled = false,
    group = $bindable(),
    class: klass,
    ...rest
  } = $props()

  const field = getContext(FIELD)
  const form = getContext(FORM)
  const key = $derived(name ?? field?.name)
  const bound = $derived(!!form && key != null)
  const current = $derived(bound ? form.get(key) : group)

  const id = uid('lauf-radio')
  const descId = `${id}-desc`

  function onChange() {
    if (bound) form.set(key, value)
    else group = value
  }
</script>

<div class={cn('flex items-start gap-2', klass)} data-lauf="radio">
  <input
    {id}
    type="radio"
    name={key}
    {value}
    {disabled}
    checked={current === value}
    onchange={onChange}
    aria-describedby={description ? descId : undefined}
    class={cn(
      'mt-0.5 size-4 shrink-0 border border-line accent-accent',
      'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent',
      'disabled:opacity-50'
    )}
    {...rest}
  />
  {#if label || description}
    <div class="flex flex-col gap-0.5">
      {#if label}
        <label for={id} class="text-sm text-fg leading-tight">{label}</label>
      {/if}
      {#if description}
        <p id={descId} class="text-xs text-muted">{description}</p>
      {/if}
    </div>
  {/if}
</div>
