<!-- Meny, over Bits UI sin DropdownMenu.
     Bits eier roving tabindex, typeahead, pilnavigering, Escape, klikk
     utenfor, plassering med kollisjonsdeteksjon og fokus tilbake til
     utløseren. Vi eier utseendet. -->
<script>
  import { DropdownMenu } from 'bits-ui'
  import { cn } from './utils.js'
  import { surface } from './overlay.js'

  let {
    open = $bindable(false),
    /** Snippet som får props å spre på sin egen knapp. */
    trigger,
    /** start | center | end */
    align = 'end',
    /** top | right | bottom | left */
    side = 'bottom',
    children,
    class: klass,
    ...rest
  } = $props()
</script>

<DropdownMenu.Root bind:open {...rest}>
  <DropdownMenu.Trigger>
    {#snippet child({ props })}
      {@render trigger?.(props)}
    {/snippet}
  </DropdownMenu.Trigger>
  <DropdownMenu.Portal>
    <DropdownMenu.Content
      {align}
      {side}
      sideOffset={6}
      class={cn(surface, 'min-w-44 p-1', klass)}
    >
      {@render children?.()}
    </DropdownMenu.Content>
  </DropdownMenu.Portal>
</DropdownMenu.Root>
