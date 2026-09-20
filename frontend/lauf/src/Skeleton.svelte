<!-- En plassholder er ikke innhold, og skal ikke leses opp som om den var
     det. Den er aria-hidden; det er beholderen rundt som eier aria-busy. -->
<script>
  import { cn } from './utils.js'

  let {
    /** text | circle | block */
    shape = 'text',
    class: klass,
    ...rest
  } = $props()

  const shapes = {
    text: 'h-4 w-full rounded-sm',
    circle: 'size-8 rounded-full',
    block: 'h-24 w-full rounded-surface',
  }
</script>

<div
  aria-hidden="true"
  class={cn('animate-pulse bg-line/70 motion-reduce:animate-none', shapes[shape] ?? shapes.text, klass)}
  data-lauf="skeleton"
  {...rest}
></div>
