<script>
  import { Link } from '@inertiajs/svelte'
  import { Heading, Text, Table, Badge, Button } from '@askrcode/lauf'
  import Layout from '../../Layout.svelte'

  let { customers = [], total = 0, generert = '' } = $props()

  const money = (v) =>
    new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(v)
</script>

<Layout>
  <div class="mb-6 flex items-end justify-between gap-4">
    <div>
      <Heading level={1}>Customers</Heading>
      <Text muted>{total} rows, served by Askr and rendered by Svelte {generert}</Text>
    </div>
    <Button href="/customers/new" variant="primary">New customer</Button>
  </div>

  <Table caption="Customers">
    <Table.Head>
      <Table.Row>
        <Table.Header>Name</Table.Header>
        <Table.Header>Email</Table.Header>
        <Table.Header align="right">Balance</Table.Header>
        <Table.Header align="right">Orders</Table.Header>
        <Table.Header>Status</Table.Header>
      </Table.Row>
    </Table.Head>
    <Table.Body>
      {#each customers as c (c.id)}
        <Table.Row>
          <Table.Cell>
            <Link href={`/customers/${c.id}`} class="text-accent hover:underline">{c.name}</Link>
          </Table.Cell>
          <Table.Cell>{c.email ?? '—'}</Table.Cell>
          <Table.Cell align="right">{money(c.balance)}</Table.Cell>
          <Table.Cell align="right">{c.orders ? c.orders.length : '—'}</Table.Cell>
          <Table.Cell>
            <Badge color={c.active ? 'accent' : 'neutral'}>
              {c.active ? 'active' : 'inactive'}
            </Badge>
          </Table.Cell>
        </Table.Row>
      {/each}
    </Table.Body>
  </Table>
</Layout>
