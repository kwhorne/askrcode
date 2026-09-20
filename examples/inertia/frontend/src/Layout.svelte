<!-- Navigasjonen for Inertia-demoen. Notes/Index bruker den med vilje
     ikke: den siden serveres av desktop-demoen, som har helt andre ruter. -->
<script>
  import { Link } from '@inertiajs/svelte'
  let { children } = $props()
</script>

<main class="mx-auto max-w-3xl px-4 pt-10 pb-16">
  <nav class="mb-8 flex gap-4 text-sm">
    <Link href="/" class="text-accent hover:underline">Home</Link>
    <Link href="/customers" class="text-accent hover:underline">Customers</Link>
  </nav>
  {@render children?.()}
</main>
