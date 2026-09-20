<!-- Tooltip.
     Den er bare for mus og tastaturfokus — aldri for berøring, og aldri
     for informasjon som ikke finnes andre steder. Står det bare i en
     tooltip, finnes det ikke på en telefon. Bruk `description` på et Field
     til det som må leses. -->
<script>
  import { Tooltip as B } from 'bits-ui'
  import { cn } from './utils.js'

  let {
    /** Teksten som vises. */
    text,
    trigger,
    side = 'top',
    /** Millisekunder før den dukker opp. */
    delay = 300,
    class: klass,
    ...rest
  } = $props()
</script>

<B.Provider delayDuration={delay}>
  <B.Root {...rest}>
    <B.Trigger>
      {#snippet child({ props })}
        {@render trigger?.(props)}
      {/snippet}
    </B.Trigger>
    <B.Portal>
      <B.Content
        {side}
        sideOffset={6}
        class={cn(
          'z-50 rounded-control bg-fg px-2 py-1 text-xs text-surface shadow-md',
          klass
        )}
      >
        {text}
      </B.Content>
    </B.Portal>
  </B.Root>
</B.Provider>
