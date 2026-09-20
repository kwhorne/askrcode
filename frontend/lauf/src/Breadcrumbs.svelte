<!-- Skillet mellom leddene er CSS, ikke tekst. En «/» i markup leses opp
     som «skråstrek» mellom hvert ledd, og det er ingen hjelp.
     Siste ledd er ikke en lenke — man navigerer ikke til der man er — men
     det bærer aria-current="page". -->
<script>
  import { cn } from './utils.js'

  let {
    /** [{ label, href }] — siste uten href. */
    items = [],
    label = 'Breadcrumb',
    class: klass,
    ...rest
  } = $props()
</script>

<nav aria-label={label} class={cn('text-sm', klass)} data-lauf="breadcrumbs" {...rest}>
  <ol class="flex flex-wrap items-center gap-1">
    {#each items as item, i (item.label)}
      <li class="flex items-center gap-1">
        {#if i > 0}
          <span aria-hidden="true" class="text-muted">/</span>
        {/if}
        {#if item.href && i < items.length - 1}
          <a href={item.href} class="text-muted hover:text-fg hover:underline">{item.label}</a>
        {:else}
          <span aria-current="page" class="text-fg">{item.label}</span>
        {/if}
      </li>
    {/each}
  </ol>
</nav>
