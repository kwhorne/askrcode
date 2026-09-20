<script>
  import { cn } from './utils.js'
  let { children, class: klass, ...rest } = $props()
</script>

<tbody class={cn(klass)} {...rest}>{@render children?.()}</tbody>
