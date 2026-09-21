<!-- The navigation for the Inertia demo. Notes/Index deliberately does not
     use it: that page is served by the desktop demo, which has entirely
     different routes. -->
<script>
  import { Link } from '@inertiajs/svelte'
  import { Flash } from '@askrcode/lauf/inertia'
  let { children } = $props()
</script>

<!-- Flash sets up the live regions once and turns Askr's flash into
     toasts. It has to sit outside the pages, or the region is swapped out
     on every navigation and the message is not read out. -->
<Flash />

<main class="mx-auto max-w-3xl px-4 pt-10 pb-16">
  <nav class="mb-8 flex gap-4 text-sm">
    <Link href="/" class="text-accent hover:underline">Home</Link>
    <Link href="/customers" class="text-accent hover:underline">Customers</Link>
  </nav>
  {@render children?.()}
</main>
