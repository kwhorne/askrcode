<!-- En navngitt gruppe valg i menyen.
     Overskriften må ligge inne i gruppa den navngir — Bits krever det, og
     det er riktig: en overskrift som ikke er koblet til noe er bare tekst
     midt i en meny, og en skjermleser sier ikke hvilke valg den gjelder. -->
<script>
  import { DropdownMenu } from 'bits-ui'
  import { cn } from './utils.js'
  let { label, children, class: klass, ...rest } = $props()
</script>

<DropdownMenu.Group class={cn(klass)} {...rest}>
  {#if label}
    <DropdownMenu.GroupHeading
      class="px-2 py-1.5 text-xs font-semibold uppercase tracking-wide text-muted"
    >
      {label}
    </DropdownMenu.GroupHeading>
  {/if}
  {@render children?.()}
</DropdownMenu.Group>
