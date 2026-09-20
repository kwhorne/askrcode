<script>
  import { cn } from './utils.js'

  let {
    /** neutral | accent | danger */
    color = 'neutral',
    /** sm | base */
    size = 'base',
    children,
    class: klass,
    ...rest
  } = $props()

  const colors = {
    neutral: 'bg-line/50 text-muted border-line',
    accent: 'bg-accent/15 text-accent border-accent/30',
    danger: 'bg-danger/15 text-danger border-danger/30',
  }

  const sizes = { sm: 'text-[0.6875rem] px-1.5 py-0', base: 'text-xs px-2 py-0.5' }
</script>

<span
  class={cn(
    'inline-flex items-center gap-1 rounded-full border font-medium whitespace-nowrap',
    colors[color] ?? colors.neutral,
    sizes[size] ?? sizes.base,
    klass
  )}
  data-lauf="badge"
  {...rest}
>
  {@render children?.()}
</span>
