<!--
  Kobler Askrs flash til Toaster.

  Askr legger flash i payloaden som et eget felt, og Inertia fyrer et
  `flash`-event. Nøklene er appens egne — `success`, `error`, hva den nå
  bruker — og alle bæres, ikke en fast liste. (Det var en feil i
  Askr.Inertia en gang: vakten spurte etter én hardkodet nøkkel, og alt
  annet ble stille forkastet.)
-->
<script>
  import { onMount } from 'svelte'
  import { router } from '@inertiajs/svelte'
  import { toast } from '../toast.svelte.js'
  import Toaster from '../Toaster.svelte'

  let {
    /** Nøkkel til variant. Ukjente nøkler blir info. */
    map = { success: 'success', error: 'danger', warning: 'warning', info: 'info' },
  } = $props()

  onMount(() =>
    router.on('flash', (event) => {
      const flash = event.detail?.flash
      if (!flash) return
      for (const [key, value] of Object.entries(flash)) {
        if (typeof value === 'string' && value !== '') {
          toast(value, { variant: map[key] ?? 'info' })
        }
      }
    })
  )
</script>

<Toaster />
