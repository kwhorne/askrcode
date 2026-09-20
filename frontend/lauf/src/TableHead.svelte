<script>
  import { cn } from './utils.js'
  let { children, class: klass, ...rest } = $props()
</script>

<thead class={cn(klass)} {...rest}>{@render children?.()}</thead>
