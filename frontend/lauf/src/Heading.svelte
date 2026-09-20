<script>
  import { cn } from './utils.js'

  let {
    /** 1–4. Styrer både taggen og størrelsen, med mindre `as` sier noe annet. */
    level = 2,
    /** Overstyrer taggen uten å endre utseendet. Nivå er struktur, størrelse
        er utseende, og en side kan trenge en h2 som ser liten ut. */
    as,
    children,
    class: klass,
    ...rest
  } = $props()

  const sizes = {
    1: 'text-2xl font-semibold tracking-tight',
    2: 'text-xl font-semibold tracking-tight',
    3: 'text-base font-semibold',
    4: 'text-sm font-semibold',
  }
</script>

<svelte:element
  this={as ?? `h${level}`}
  class={cn('text-fg text-balance', sizes[level] ?? sizes[2], klass)}
  data-lauf="heading"
  {...rest}
>
  {@render children?.()}
</svelte:element>
