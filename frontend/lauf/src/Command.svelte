<!-- Kommandopalett. Bits eier filtrering, markøren og at lista annonseres
     som en liste med valg. Den lever typisk i en Modal; det er derfor denne
     bare er innmaten. -->
<script>
  import { Command as B } from 'bits-ui'
  import { cn } from './utils.js'
  import { uid } from './context.js'
  import { menuItem } from './overlay.js'

  // Bits gir inputen role="combobox", men setter verken navn eller
  // aria-controls. Begge er påkrevd for rollen, og axe i nettleseren felte
  // den på det. Samme luke som aria-controls på trekkspillet: Bits eier
  // oppførselen, vi eier at den er komplett.
  const listId = uid('lauf-command-list')

  let {
    /** Det uthevede valget. Kontrollert, ikke bundet: Bits har en egen
        fallback på value, og bind:value mot undefined er en feil i Svelte
        5 når mottakeren har det. */
    value = $bindable(undefined),
    placeholder = 'Type a command…',
    empty = 'No results',
    /** Navnet på lista, for den som ikke ser den. */
    label = 'Commands',
    children,
    class: klass,
    ...rest
  } = $props()
</script>

<B.Root value={value} onValueChange={(v) => (value = v)} {label} class={cn('flex flex-col', klass)} data-lauf="command" {...rest}>
  <B.Input
    {placeholder}
    aria-label={label}
    aria-controls={listId}
    class="w-full border-b border-line bg-transparent px-3 py-2.5 text-sm text-fg outline-none placeholder:text-muted/70"
  />
  <B.List id={listId} class="max-h-72 overflow-y-auto p-1">
    <B.Empty class="px-2 py-6 text-center text-sm text-muted">{empty}</B.Empty>
    {@render children?.()}
  </B.List>
</B.Root>
