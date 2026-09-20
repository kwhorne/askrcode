<!-- Bildet kan mangle eller feile, og da er initialene svaret — ikke et
     ødelagt bildeikon. Bits holder tilstanden for lasting og feil. -->
<script>
  import { Avatar as B } from 'bits-ui'
  import { cn } from './utils.js'

  let {
    src,
    /** Navnet på personen. Brukes som alt-tekst og til initialene. */
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
  <!-- Fallbacken bærer navnet, slik at avataren har et navn også uten
       bildet. Uten det er den en tom sirkel for den som ikke ser den. -->
  <B.Fallback
    class="flex size-full items-center justify-center font-medium text-muted"
    aria-label={name || undefined}
  >
    {initials || '?'}
  </B.Fallback>
</B.Root>
