<script>
  import { cn } from './utils.js'
  let { as = 'div', children, class: klass, ...rest } = $props()
</script>

<svelte:element
  this={as}
  class={cn('bg-raised border border-line rounded-surface p-4', klass)}
  data-lauf="card"
  {...rest}
>
  {@render children?.()}
</svelte:element>
