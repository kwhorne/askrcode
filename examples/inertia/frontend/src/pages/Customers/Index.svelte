<script>
  import { Link } from '@inertiajs/svelte'

  // Svelte 5 runes. Props kommer fra Inertia-payloaden.
  let { customers = [], total = 0, generert = '', flash = null } = $props()

  const penger = (v) =>
    new Intl.NumberFormat('nb-NO', { style: 'currency', currency: 'NOK' }).format(v)
</script>

<main>
  <nav>
    <Link href="/">Forside</Link>
    <Link href="/customers">Customers</Link>
  </nav>

  <h1>Customers</h1>
  <p class="lead">
    {total} rader, servert av Askr og rendret av Svelte {generert}
    · <Link href="/customers/new">Ny customer</Link>
  </p>

  <table>
    <thead>
      <tr>
        <th>Name</th>
        <th>E-post</th>
        <th class="num">Balance</th>
        <th class="num">Order</th>
        <th>Status</th>
      </tr>
    </thead>
    <tbody>
      {#each customers as c (c.id)}
        <tr>
          <td><Link href={`/customers/${c.id}`}>{c.name}</Link></td>
          <td>{c.email ?? '—'}</td>
          <td class="num">{penger(c.balance)}</td>
          <td class="num">{c.orders ? c.orders.length : '—'}</td>
          <td><span class="pill">{c.active ? 'active' : 'passiv'}</span></td>
        </tr>
      {/each}
    </tbody>
  </table>
</main>
