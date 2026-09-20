<!-- Engangskode.
     Én <input> under, delt opp i ruter visuelt. Det er Bits' modell, og den
     er riktig: en rute per siffer som egne felt gir en tabbfelle, ødelegger
     innliming og gjør autofyll fra SMS umulig. -->
<script>
  import { PinInput } from 'bits-ui'
  import { cn } from './utils.js'
  import { getContext } from 'svelte'
  import { FORM, FIELD } from './context.js'

  let {
    value = $bindable(''),
    /** Antall siffer. */
    length = 6,
    /** Kalles når alle rutene er fylt. */
    oncomplete,
    disabled = false,
    class: klass,
    ...rest
  } = $props()

  const field = getContext(FIELD)
  const form = getContext(FORM)
  const bound = $derived(!!form && field?.name != null)
  const current = $derived(bound ? (form.get(field.name) ?? '') : value)

  function endre(v) {
    if (bound) form.set(field.name, v)
    else value = v
  }
</script>

<PinInput.Root
  value={current}
  onValueChange={endre}
  onComplete={oncomplete}
  maxlength={length}
  {disabled}
  class={cn('flex gap-2', klass)}
  data-lauf="otp"
  {...rest}
>
  {#snippet children({ cells })}
    {#each cells as cell (cell)}
      <PinInput.Cell
        {cell}
        class={cn(
          'flex h-11 w-9 items-center justify-center rounded-control border border-line',
          'text-base tabular-nums text-fg',
          'data-[active]:border-accent data-[active]:outline-2 data-[active]:outline-accent'
        )}
      >
        {#if cell.char !== null}{cell.char}{/if}
      </PinInput.Cell>
    {/each}
  {/snippet}
</PinInput.Root>
