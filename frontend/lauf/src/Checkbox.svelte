<!-- En avkrysningsboks med etiketten sin.
     Etiketten står i komponenten og ikke i Field, fordi en avkrysningsboks
     har teksten til høyre for seg og et vanlig felt har den over. Et Field
     rundt en gruppe bokser bruker as="fieldset" og gir gruppa overskriften. -->
<script>
  import { getContext } from 'svelte'
  import { cn } from './utils.js'
  import { FORM, FIELD, uid } from './context.js'

  let {
    checked = $bindable(),
    /** Navnet i <Form>. Faller tilbake til feltets navn. */
    name,
    label,
    description,
    disabled = false,
    class: klass,
    ...rest
  } = $props()

  const field = getContext(FIELD)
  const form = getContext(FORM)
  const key = $derived(name ?? field?.name)
  const bound = $derived(!!form && key != null)
  const current = $derived(bound ? !!form.get(key) : !!checked)

  const own = uid('lauf-checkbox')
  const id = $derived(field && !name ? field.id : own)
  const descId = `${own}-desc`

  function onChange(e) {
    const v = e.currentTarget.checked
    if (bound) form.set(key, v)
    else checked = v
  }
</script>

<div class={cn('flex items-start gap-2', klass)} data-lauf="checkbox">
  <input
    {id}
    type="checkbox"
    checked={current}
    {disabled}
    onchange={onChange}
    aria-invalid={field?.invalid ? 'true' : undefined}
    aria-describedby={description ? descId : field?.describedBy}
    class={cn(
      'mt-0.5 size-4 shrink-0 rounded-sm border border-line accent-accent',
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
