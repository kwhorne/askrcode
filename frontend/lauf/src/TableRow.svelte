<script>
  import { cn } from './utils.js'
  let { children, class: klass, ...rest } = $props()
</script>

<tr class={cn('border-b border-line last:border-0', klass)} {...rest}>
  {@render children?.()}
</tr>
