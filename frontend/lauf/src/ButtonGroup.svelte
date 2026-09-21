<!-- Buttons that belong together. The seams between them are removed
     with a negative margin rather than by asking each button to know
     where in the row it sits. -->
<script>
  import { cn } from './utils.js'
  let { children, class: klass, ...rest } = $props()
</script>

<div
  class={cn(
    'inline-flex isolate',
    '[&>*]:rounded-none [&>*:first-child]:rounded-l-control [&>*:last-child]:rounded-r-control',
    '[&>*:not(:first-child)]:-ml-px hover:[&>*]:z-10 focus-within:[&>*:focus-visible]:z-10',
    klass
  )}
  data-lauf="button-group"
  {...rest}
>
  {@render children?.()}
</div>
