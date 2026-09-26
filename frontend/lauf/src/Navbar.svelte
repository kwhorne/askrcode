<!-- <header> med en <nav> inni, ikke en div med lenker. Landemerkene er
     det den som navigerer med skjermleser hopper mellom. -->
<script>
  import { cn } from './utils.js'
  import { strings } from './strings.js'
  const word = strings()

  let { label = word('main_navigation'), brand, children, class: klass, ...rest } = $props()
</script>

<header
  class={cn('border-b border-line bg-raised', klass)}
  data-lauf="navbar"
  {...rest}
>
  <div class="mx-auto flex max-w-5xl items-center gap-6 px-4 py-3">
    {#if brand}<div class="font-semibold text-fg">{@render brand()}</div>{/if}
    <nav aria-label={label} class="flex flex-1 items-center gap-4 text-sm">
      {@render children?.()}
    </nav>
  </div>
</header>
