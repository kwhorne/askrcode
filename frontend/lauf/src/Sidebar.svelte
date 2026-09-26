<!-- Et eget landemerke med sitt eget navn, slik at «hovedinnhold» og
     «sidemeny» kan skilles av den som hopper mellom dem. -->
<script>
  import { cn } from './utils.js'
  import { strings } from './strings.js'
  const word = strings()

  let { label = word('sidebar'), children, class: klass, ...rest } = $props()
</script>

<nav
  aria-label={label}
  class={cn(
    'flex w-56 shrink-0 flex-col gap-1 border-r border-line p-3 text-sm',
    klass
  )}
  data-lauf="sidebar"
  {...rest}
>
  {@render children?.()}
</nav>
