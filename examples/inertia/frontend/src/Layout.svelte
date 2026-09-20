<!-- Navigasjonen for Inertia-demoen. Notes/Index bruker den med vilje
     ikke: den siden serveres av desktop-demoen, som har helt andre ruter. -->
<script>
  import { Link } from '@inertiajs/svelte'
  import { Flash } from '@askrcode/lauf/inertia'
  let { children } = $props()
</script>

<!-- Flash setter opp live-områdene én gang og gjør Askrs flash om til
     toasts. Den må stå utenfor sidene, ellers byttes området ut ved hver
     navigering og meldingen leses ikke opp. -->
<Flash />

<main class="mx-auto max-w-3xl px-4 pt-10 pb-16">
  <nav class="mb-8 flex gap-4 text-sm">
    <Link href="/" class="text-accent hover:underline">Home</Link>
    <Link href="/customers" class="text-accent hover:underline">Customers</Link>
  </nav>
  {@render children?.()}
</main>
