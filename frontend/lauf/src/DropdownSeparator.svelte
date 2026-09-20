<script>
  import { DropdownMenu } from 'bits-ui'
  import { cn } from './utils.js'
  let { class: klass, ...rest } = $props()
</script>

<DropdownMenu.Separator class={cn('my-1 h-px bg-line', klass)} {...rest} />
