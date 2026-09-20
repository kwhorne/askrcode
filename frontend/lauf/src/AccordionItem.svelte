<!-- Overskriften er en ekte <h3> med knappen inni, ikke en knapp som ser ut
     som en overskrift. Det er det som gjør at en skjermleser kan hoppe
     mellom seksjonene. -->
<script>
  import { Accordion } from 'bits-ui'
  import { cn } from './utils.js'
  import Icon from './Icon.svelte'
  import { uid } from './context.js'
  import { ChevronDown } from './icons/micro/index.js'

  let { value, title, level = 3, children, class: klass, ...rest } = $props()

  // Bits setter aria-controls på faner, men ikke på trekkspill — det er en
  // luke mot WAI-ARIAs eget mønster, der knappen skal peke på panelet den
  // åpner. Vi lager id-en selv og kobler begge veier. Det er nettopp slikt
  // lag 3 er til for: Bits eier oppførselen, vi eier at den er komplett.
  const contentId = uid('lauf-accordion')
</script>

<Accordion.Item {value} class={cn(klass)} {...rest}>
  <!-- Bits rendrer <div role="heading" aria-level>, som er riktig for en
       skjermleser. Vi bytter det mot et ekte <h3> gjennom child-snippeten:
       et element holder også der ARIA ikke gjør det — lesemodus, utskrift,
       verktøy som leser strukturen uten å kjøre JavaScript. `role` fjernes
       fra props, for det ville vært overflødig på en h3. -->
  <Accordion.Header {level}>
    {#snippet child({ props })}
      {@const { role, ...attrs } = props}
      <svelte:element this={`h${level}`} {...attrs}>
        {@render trigger()}
      </svelte:element>
    {/snippet}
  </Accordion.Header>
  <Accordion.Content id={contentId} class="pb-3 text-sm text-muted">
    {@render children?.()}
  </Accordion.Content>
</Accordion.Item>

{#snippet trigger()}
    <Accordion.Trigger
      aria-controls={contentId}
      class={cn(
        'flex w-full items-center justify-between gap-2 py-3 text-left text-sm font-medium text-fg',
        'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent',
        'group'
      )}
    >
      {title}
      <Icon
        icon={ChevronDown}
        size="sm"
        class="text-muted transition-transform group-data-[state=open]:rotate-180 motion-reduce:transition-none"
      />
    </Accordion.Trigger>
{/snippet}
