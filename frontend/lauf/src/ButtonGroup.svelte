<!-- Knapper som hører sammen. Sømmene mellom dem fjernes med negativ margin
     i stedet for å be hver knapp om å vite hvor i rekka den står. -->
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
