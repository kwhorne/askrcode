<!-- `label` er både teksten som vises og det det søkes i.
     Bits filtrerer på `value` og `keywords`, ikke på det som står i
     elementet — så en palett der value er «list-customers» finner ingenting
     når man skriver «all». Det er ikke det noen forventer, og det er ikke
     noe kalleren skal måtte vite. Vi legger label i keywords selv. -->
<script>
  import { Command } from 'bits-ui'
  import { cn } from './utils.js'
  import { menuItem } from './overlay.js'
  import Icon from './Icon.svelte'

  let {
    /** Identiteten som kommer tilbake i onSelect. */
    value,
    /** Teksten som vises, og som det søkes i. */
    label,
    /** Flere ord som skal treffe, i tillegg til label. */
    keywords = [],
    icon,
    onSelect,
    children,
    class: klass,
    ...rest
  } = $props()

  const søkeord = $derived(label ? [label, ...keywords] : keywords)
</script>

<Command.Item {value} keywords={søkeord} {onSelect} class={cn(menuItem, klass)} {...rest}>
  {#if icon}<Icon {icon} size="sm" />{/if}
  {#if label}{label}{/if}
  {@render children?.()}
</Command.Item>
