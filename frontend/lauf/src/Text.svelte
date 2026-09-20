<script>
  import { cn } from './utils.js'

  let {
    /** sm | base | lg */
    size = 'base',
    /** Dempet tekst — ingressen, hjelpeteksten, kolonneetiketten. */
    muted = false,
    as = 'p',
    children,
    class: klass,
    ...rest
  } = $props()

  const sizes = { sm: 'text-xs', base: 'text-sm', lg: 'text-base' }
</script>

<svelte:element
  this={as}
  class={cn(muted ? 'text-muted' : 'text-fg', sizes[size] ?? sizes.base, klass)}
  data-lauf="text"
  {...rest}
>
  {@render children?.()}
</svelte:element>
