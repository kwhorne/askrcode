<script>
  import { cn } from './utils.js'
  let { align = 'left', children, class: klass, ...rest } = $props()
</script>

<td
  class={cn(
    'px-2 py-2 text-fg align-top',
    align === 'right' ? 'text-right tabular-nums' : 'text-left',
    klass
  )}
  {...rest}
>
  {@render children?.()}
</td>
