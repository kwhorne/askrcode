<!-- A progress indicator has to have a name and a value that can be
     read. `value = null` means indeterminate: something is happening, but
     nobody knows for how long. Then aria-valuenow must *not* be set — a
     number that means nothing is worse than no number. -->
<script>
  import { Progress as B } from 'bits-ui'
  import { cn } from './utils.js'

  let {
    /** 0–max, eller null for ubestemt. */
    value = 0,
    max = 100,
    /** The name of what is going on. Required. */
    label,
    /** Viser prosenten ved siden av. */
    showValue = false,
    class: klass,
    ...rest
  } = $props()

  const pct = $derived(value == null ? null : Math.round((value / max) * 100))
</script>

<div class={cn('flex flex-col gap-1', klass)} data-lauf="progress">
  {#if showValue}
    <div class="flex justify-between text-xs text-muted">
      <span>{label}</span>
      <span class="tabular-nums">{pct == null ? '' : `${pct}%`}</span>
    </div>
  {/if}
  <B.Root
    {value}
    {max}
    aria-label={label}
    class="relative h-2 w-full overflow-hidden rounded-full bg-line/60"
    {...rest}
  >
    <div
      class={cn(
        'h-full bg-accent transition-[width]',
        'motion-reduce:transition-none',
        value == null && 'w-1/3 animate-pulse motion-reduce:animate-none'
      )}
      style={value == null ? undefined : `width: ${pct}%`}
    ></div>
  </B.Root>
</div>
