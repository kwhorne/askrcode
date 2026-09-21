<!-- The image may be missing or fail to load, and then the initials are
     the answer — not a broken-image icon. Bits holds the loading and
     error state. -->
<script>
  import { Avatar as B } from 'bits-ui'
  import { cn } from './utils.js'

  let {
    src,
    /** The person's name. Used as alt text and for the initials. */
    name = '',
    /** sm | base | lg */
    size = 'base',
    class: klass,
    ...rest
  } = $props()

  const sizes = { sm: 'size-6 text-[0.625rem]', base: 'size-8 text-xs', lg: 'size-12 text-sm' }

  const initials = $derived(
    name
      .split(/\s+/)
      .filter(Boolean)
      .slice(0, 2)
      .map((p) => p[0].toUpperCase())
      .join('')
  )
</script>

<B.Root
  class={cn(
    'inline-flex shrink-0 overflow-hidden rounded-full border border-line bg-line/40',
    sizes[size] ?? sizes.base,
    klass
  )}
  {...rest}
>
  <B.Image {src} alt={name} class="size-full object-cover" />
  <!-- The fallback carries the name, so the avatar has a name even
       without the image. Without that it is an empty circle to anyone who
       cannot see it. -->
  <B.Fallback
    class="flex size-full items-center justify-center font-medium text-muted"
    aria-label={name || undefined}
  >
    {initials || '?'}
  </B.Fallback>
</B.Root>
