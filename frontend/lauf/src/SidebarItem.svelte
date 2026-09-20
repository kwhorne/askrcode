<script>
  import { cn } from './utils.js'
  import Icon from './Icon.svelte'

  let { href, icon, active = false, children, class: klass, ...rest } = $props()
</script>

<a
  {href}
  aria-current={active ? 'page' : undefined}
  class={cn(
    'flex items-center gap-2 rounded-control px-2 py-1.5 text-muted',
    'hover:bg-line/50 hover:text-fg',
    'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent',
    active && 'bg-line/60 text-fg font-medium',
    klass
  )}
  {...rest}
>
  {#if icon}<Icon {icon} size="sm" />{/if}
  {@render children?.()}
</a>
