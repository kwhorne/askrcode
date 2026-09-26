<!-- The separator between crumbs is CSS, not text. A "/" in the markup
     is read out as "slash" between every crumb, and that helps nobody.
     The last crumb is not a link — you do not navigate to where you
     already are — but it carries aria-current="page". -->
<script>
  import { cn } from './utils.js'

  import { strings } from './strings.js'
  const word = strings()

  let {
    /** [{ label, href }] — siste uten href. */
    items = [],
    label = word('breadcrumb'),
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
