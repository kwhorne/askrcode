<!-- En bryter er en avkrysningsboks som ser annerledes ut, og skal være det
     også for en skjermleser: role="switch" med aria-checked. En <div> med
     en onclick ville ikke vært noen av delene.

     Den bygges på en ekte <input type="checkbox"> med role="switch", slik at
     tastatur, skjema-innsending og «hopp til neste kontroll» virker uten at
     vi skriver det selv. -->
<script>
  import { getContext } from 'svelte'
  import { cn } from './utils.js'
  import { FORM, FIELD, uid } from './context.js'

  let {
    checked = $bindable(),
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

  const own = uid('lauf-switch')
  const id = $derived(field && !name ? field.id : own)
  const descId = `${own}-desc`

  function onChange(e) {
    const v = e.currentTarget.checked
    if (bound) form.set(key, v)
    else checked = v
  }
</script>

<div class={cn('flex items-start gap-3', klass)} data-lauf="switch">
  <span class="relative inline-flex shrink-0 mt-0.5">
    <input
      {id}
      type="checkbox"
      role="switch"
      checked={current}
      aria-checked={current ? 'true' : 'false'}
      {disabled}
      onchange={onChange}
      aria-describedby={description ? descId : field?.describedBy}
      class={cn(
        'peer appearance-none h-5 w-9 rounded-full border border-line bg-line/60',
        'transition-colors cursor-pointer',
        'checked:bg-accent checked:border-accent',
        'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent',
        'disabled:opacity-50 disabled:cursor-not-allowed'
      )}
      {...rest}
    />
    <span
      class={cn(
        'pointer-events-none absolute top-0.5 left-0.5 size-4 rounded-full bg-surface',
        'transition-transform peer-checked:translate-x-4'
      )}
      aria-hidden="true"
    ></span>
  </span>
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
