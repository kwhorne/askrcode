<!-- Popover er en meny uten menysemantikk: innhold, ikke valg.
     Bruk Dropdown når radene er handlinger, denne når det er et skjema
     eller en forklaring. Forskjellen er hva en skjermleser sier. -->
<script>
  import { Popover as B } from 'bits-ui'
  import { cn } from './utils.js'
  import { surface } from './overlay.js'

  let {
    open = $bindable(false),
    trigger,
    align = 'center',
    side = 'bottom',
    children,
    class: klass,
    ...rest
  } = $props()
</script>

<B.Root bind:open {...rest}>
  <B.Trigger>
    {#snippet child({ props })}
      {@render trigger?.(props)}
    {/snippet}
  </B.Trigger>
  <B.Portal>
    <B.Content {align} {side} sideOffset={6} class={cn(surface, 'w-72 p-4', klass)}>
      {@render children?.()}
    </B.Content>
  </B.Portal>
</B.Root>
