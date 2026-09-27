<!--
  Keeps a page's props fresh when Askr says they have gone stale.

  Put it in the layout once. On a page whose handler called LiveOn, it
  opens the stream in the askrLive prop; on one that did not, it opens
  nothing. When PropsChanged names props, it reloads those and only those.
-->
<script>
  import { page, router } from '@inertiajs/svelte'
  import { liveStream } from './live.js'

  // Derived, so a reload that brings new props but the same URL keeps the
  // stream open: an effect on page.props itself would close and reopen it
  // after every reload, and lose what was sent in between.
  const url = $derived(page.props?.askrLive)

  // router.reload, called on the router: Inertia's methods use `this`.
  $effect(() => liveStream(url, (only) => router.reload({ only })))
</script>
