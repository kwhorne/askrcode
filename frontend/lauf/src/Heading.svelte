<script>
  import { cn } from './utils.js'

  let {
    /** 1-4. Drives both the tag and the size, unless `as` says otherwise. */
    level = 2,
    /** Overrides the tag without changing how it looks. Level is
        structure, size is appearance, and a page may need an h2 that
        looks small. */
    as,
    children,
    class: klass,
    ...rest
  } = $props()

  const sizes = {
    1: 'text-2xl font-semibold tracking-tight',
    2: 'text-xl font-semibold tracking-tight',
    3: 'text-base font-semibold',
    4: 'text-sm font-semibold',
  }
</script>

<svelte:element
  this={as ?? `h${level}`}
  class={cn('text-fg text-balance', sizes[level] ?? sizes[2], klass)}
  data-lauf="heading"
  {...rest}
>
  {@render children?.()}
</svelte:element>
