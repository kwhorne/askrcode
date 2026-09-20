<script>
  import { cn } from './utils.js'

  let {
    /** left | right — høyre for tall, slik at sifrene står under hverandre. */
    align = 'left',
    /** col | row */
    scope = 'col',
    children,
    class: klass,
    ...rest
  } = $props()
</script>

<th
  {scope}
  class={cn(
    'px-2 py-2 text-xs font-semibold uppercase tracking-wide text-muted',
    align === 'right' ? 'text-right' : 'text-left',
    klass
  )}
  {...rest}
>
  {@render children?.()}
</th>
