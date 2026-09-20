<!--
  Vertsområdet for toasts. Settes én gang, øverst i appen.

  **Live-området må stå i DOM-en før meldingen kommer.** Legger man både
  området og teksten inn samtidig, rekker ikke en skjermleser å se at noe
  endret seg, og meldingen leses ikke opp i det hele tatt. Derfor rendres
  <div aria-live> alltid, tom eller ikke.

  polite for det vanlige, assertive for feil: en bekreftelse skal ikke
  avbryte det som leses, men noe som gikk galt skal.
-->
<script>
  import { cn } from './utils.js'
  import { toasts, dismiss } from './toast.svelte.js'
  import Button from './Button.svelte'
  import Icon from './Icon.svelte'
  import { XMark } from './icons/micro/index.js'

  let { class: klass, ...rest } = $props()

  const liste = $derived(toasts())

  const variants = {
    info: 'border-line bg-raised text-fg',
    success: 'border-accent/40 bg-accent text-accent-fg',
    warning: 'border-accent/50 bg-accent/15 text-fg',
    danger: 'border-danger/50 bg-danger text-danger-fg',
  }
</script>

<div
  class={cn('pointer-events-none fixed inset-x-0 bottom-4 z-50 flex flex-col items-center gap-2 px-4', klass)}
  data-lauf="toaster"
  {...rest}
>
  <div aria-live="polite" aria-atomic="false" class="contents">
    {#each liste.filter((t) => t.variant !== 'danger') as t (t.id)}
      <div
        class={cn('pointer-events-auto flex max-w-md items-center gap-3 rounded-full border px-4 py-2 text-sm shadow-lg', variants[t.variant] ?? variants.info)}
      >
        <span>{t.message}</span>
        <Button variant="ghost" size="sm" icon={XMark} label="Dismiss"
                class="-mr-2 text-current" onclick={() => dismiss(t.id)} />
      </div>
    {/each}
  </div>

  <div aria-live="assertive" aria-atomic="false" class="contents">
    {#each liste.filter((t) => t.variant === 'danger') as t (t.id)}
      <div
        class={cn('pointer-events-auto flex max-w-md items-center gap-3 rounded-full border px-4 py-2 text-sm shadow-lg', variants.danger)}
      >
        <span>{t.message}</span>
        <Button variant="ghost" size="sm" icon={XMark} label="Dismiss"
                class="-mr-2 text-current" onclick={() => dismiss(t.id)} />
      </div>
    {/each}
  </div>
</div>
