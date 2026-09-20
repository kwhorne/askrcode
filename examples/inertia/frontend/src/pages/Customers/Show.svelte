<script>
  import { Link } from '@inertiajs/svelte'

  let { customer = null } = $props()

  const penger = (v) =>
    new Intl.NumberFormat('nb-NO', { style: 'currency', currency: 'NOK' }).format(v)
</script>

<main>
  <nav>
    <Link href="/">Forside</Link>
    <Link href="/customers">Customers</Link>
  </nav>

  {#if customer}
    <h1>{customer.name}</h1>
    <p class="lead">{customer.email ?? 'ingen e-post'} · balance {penger(customer.balance)}</p>

    <table>
      <thead>
        <tr><th>Order</th><th>Status</th><th class="num">Beløp</th></tr>
      </thead>
      <tbody>
        {#each customer.orders ?? [] as o (o.id)}
          <tr>
            <td>#{o.id}</td>
            <td><span class="pill">{o.status}</span></td>
            <td class="num">{penger(o.total)}</td>
          </tr>
        {/each}
      </tbody>
    </table>
  {:else}
    <h1>Fant ikke customer</h1>
  {/if}
</main>
