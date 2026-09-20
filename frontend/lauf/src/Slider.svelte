<script>
  import { Slider as B } from 'bits-ui'
  import { cn } from './utils.js'
  import { FORM, FIELD } from './context.js'
  import { getContext } from 'svelte'

  let {
    value = $bindable(0),
    min = 0,
    max = 100,
    step = 1,
    disabled = false,
    class: klass,
    ...rest
  } = $props()

  const field = getContext(FIELD)
  const form = getContext(FORM)
  const bound = $derived(!!form && field?.name != null)
  const current = $derived(bound ? Number(form.get(field.name) ?? min) : value)

  function endre(v) {
    if (bound) form.set(field.name, v)
    else value = v
  }
</script>

<B.Root
  type="single"
  value={current}
  onValueChange={endre}
  {min}
  {max}
  {step}
  {disabled}
  class={cn('relative flex h-5 w-full touch-none items-center select-none', klass)}
  data-lauf="slider"
  {...rest}
>
  {#snippet children()}
    <span class="relative h-1.5 w-full grow overflow-hidden rounded-full bg-line/60">
      <B.Range class="absolute h-full bg-accent" />
    </span>
    <!-- Knotten er det fokuserbare elementet, og Bits gir den rollen,
         verdien og piltastene. aria-label settes fra Field-etiketten når
         den står i et, ellers må kalleren sende en. -->
    <B.Thumb
      index={0}
      aria-labelledby={field ? undefined : rest['aria-labelledby']}
      class={cn(
        'block size-4 rounded-full border border-accent bg-surface shadow',
        'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent',
        'disabled:opacity-50'
      )}
    />
  {/snippet}
</B.Root>
