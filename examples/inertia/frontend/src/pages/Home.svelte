<script>
  import { Link } from '@inertiajs/svelte'
  import { Heading, Text, Badge, Card } from '@askrcode/lauf'
  import Layout from '../Layout.svelte'

  let { rammeverk = 'Askr', versjon = '', arena = 0, reservert = 0, requests = 0 } = $props()

  const bytes = (n) => (n < 1024 ? `${n} B` : `${(n / 1024).toFixed(1)} kB`)

  const rows = $derived([
    ['Arena used by this request', bytes(arena)],
    ['Arena reserved by the worker', bytes(reservert)],
    ['Requests served', String(requests)],
  ])
</script>

<Layout>
  <Heading level={1}>{rammeverk}</Heading>
  <Text muted class="mb-6 max-w-prose">
    One binary serves this page. No php-fpm, no queue worker, no process
    manager beside it.
  </Text>

  <!-- En <dl> med fleksrader, ikke en tabell. En tabell har en minstebredde
       som presser hele siden bredere enn en telefonskjerm, og dette er
       etikett og verdi — ikke tabelldata. Samme valg som velkomstsiden. -->
  <Card class="max-w-md">
    <dl class="flex flex-col gap-2 text-sm">
      {#each rows as [label, value] (label)}
        <div class="flex items-baseline justify-between gap-4">
          <dt class="text-muted">{label}</dt>
          <dd class="tabular-nums">{value}</dd>
        </div>
      {/each}
      <div class="flex items-baseline justify-between gap-4">
        <dt class="text-muted">Inertia version</dt>
        <dd><Badge>{versjon}</Badge></dd>
      </div>
    </dl>
  </Card>

  <Text muted size="sm" class="mt-8 max-w-prose">
    Click <Link href="/customers" class="text-accent hover:underline">Customers</Link>.
    That is an Inertia navigation: no full page load, just a JSON payload from
    Askr and a new Svelte component.
  </Text>
</Layout>
