<script>
  import { Command } from 'bits-ui'
  let { label, children, ...rest } = $props()
</script>

<Command.Group {...rest}>
  {#if label}
    <Command.GroupHeading
      class="px-2 py-1.5 text-xs font-semibold uppercase tracking-wide text-muted"
    >
      {label}
    </Command.GroupHeading>
  {/if}
  <Command.GroupItems>
    {@render children?.()}
  </Command.GroupItems>
</Command.Group>
