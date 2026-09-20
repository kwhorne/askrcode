<!-- Faner, over Bits UI.
     Bits eier pilnavigering, Home/End, roving tabindex og koblingen mellom
     tab og panel (aria-controls / aria-labelledby). Uten den er faner bare
     knapper som bytter innhold, og en skjermleser sier ingenting om at de
     hører sammen. -->
<script>
  import { Tabs as B } from 'bits-ui'
  import { cn } from './utils.js'

  let {
    value = $bindable(),
    /** [{ value, label }] */
    tabs = [],
    children,
    class: klass,
    ...rest
  } = $props()
</script>

<B.Root bind:value class={cn('flex flex-col gap-4', klass)} {...rest}>
  <B.List class="flex gap-1 border-b border-line">
    {#each tabs as t (t.value)}
      <B.Trigger
        value={t.value}
        class={cn(
          '-mb-px border-b-2 border-transparent px-3 py-2 text-sm text-muted',
          'data-[state=active]:border-accent data-[state=active]:text-fg',
          'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent'
        )}
      >
        {t.label}
      </B.Trigger>
    {/each}
  </B.List>
  {@render children?.()}
</B.Root>
