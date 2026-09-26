<!--
  Modal, over Bits UI sin Dialog.

  Det Bits gjør, og som er grunnen til at vi ikke skriver dette selv:
  fokusfelle, fokus tilbake til det som åpnet den, Escape, klikk utenfor,
  rullelås, aria-modal og inertness på resten av siden. Det er et halvt års
  arbeid å få riktig og fem minutter å få nesten riktig.

  `title` er påkrevd. En dialog uten navn annonseres som «dialog», og det er
  alt den som ikke ser skjermen får vite. Er overskriften allerede synlig i
  innholdet, sett `hideTitle` — da blir den skjult visuelt, ikke fjernet.
-->
<script>
  import { Dialog } from 'bits-ui'
  import { cn } from './utils.js'
  import { surface } from './overlay.js'
  import Button from './Button.svelte'
  import { XMark } from './icons/micro/index.js'

  import { strings } from './strings.js'
  const word = strings()

  let {
    open = $bindable(false),
    /** Navnet på dialogen. Påkrevd. */
    title,
    description,
    /** Skjuler overskriften visuelt, men beholder den for skjermlesere. */
    hideTitle = false,
    /** sm | base | lg */
    size = 'base',
    /** Knapperaden nederst. */
    footer,
    children,
    class: klass,
    ...rest
  } = $props()

  const sizes = { sm: 'max-w-sm', base: 'max-w-lg', lg: 'max-w-2xl' }
</script>

<Dialog.Root bind:open {...rest}>
  <Dialog.Portal>
    <Dialog.Overlay class="fixed inset-0 z-40 bg-black/40" />
    <Dialog.Content
      class={cn(
        surface,
        'fixed top-1/2 left-1/2 w-[calc(100vw-2rem)] -translate-x-1/2 -translate-y-1/2',
        'max-h-[calc(100vh-4rem)] overflow-y-auto p-5',
        sizes[size] ?? sizes.base,
        klass
      )}
    >
      <div class="flex items-start justify-between gap-4">
        <div class="flex flex-col gap-1">
          <Dialog.Title
            class={cn('text-base font-semibold text-fg', hideTitle && 'sr-only')}
          >
            {title}
          </Dialog.Title>
          {#if description}
            <Dialog.Description class="text-sm text-muted">
              {description}
            </Dialog.Description>
          {/if}
        </div>
        <Dialog.Close>
          {#snippet child({ props })}
            <Button {...props} variant="ghost" size="sm" icon={XMark} label={word('close')} />
          {/snippet}
        </Dialog.Close>
      </div>

      {#if children}
        <div class="mt-4 text-sm text-fg">{@render children()}</div>
      {/if}

      {#if footer}
        <div class="mt-6 flex justify-end gap-2">{@render footer()}</div>
      {/if}
    </Dialog.Content>
  </Dialog.Portal>
</Dialog.Root>
