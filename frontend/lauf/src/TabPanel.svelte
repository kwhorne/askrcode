<script>
  import { Tabs } from 'bits-ui'
  import { cn } from './utils.js'
  let { value, children, class: klass, ...rest } = $props()
</script>

<Tabs.Content {value} class={cn('text-sm text-fg', klass)} {...rest}>
  {@render children?.()}
</Tabs.Content>
