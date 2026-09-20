<script>
  import { Accordion as B } from 'bits-ui'
  import { cn } from './utils.js'

  let {
    /** single | multiple */
    type = 'single',
    value = $bindable(),
    children,
    class: klass,
    ...rest
  } = $props()
</script>

<B.Root {type} bind:value class={cn('divide-y divide-line border-y border-line', klass)} {...rest}>
  {@render children?.()}
</B.Root>
