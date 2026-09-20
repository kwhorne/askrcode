<script>
  import { Heading, Text, Table, Badge } from '@askrcode/lauf'
  import Layout from '../../Layout.svelte'

  let { customer = null } = $props()

  const money = (v) =>
    new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(v)
</script>

<Layout>
  {#if customer}
    <Heading level={1}>{customer.name}</Heading>
    <Text muted class="mb-6">
      {customer.email ?? 'no email'} · balance {money(customer.balance)}
    </Text>

    <Table caption="Orders">
      <Table.Head>
        <Table.Row>
          <Table.Header>Order</Table.Header>
          <Table.Header>Status</Table.Header>
          <Table.Header align="right">Total</Table.Header>
        </Table.Row>
      </Table.Head>
      <Table.Body>
        {#each customer.orders ?? [] as o (o.id)}
          <Table.Row>
            <Table.Cell>#{o.id}</Table.Cell>
            <Table.Cell><Badge>{o.status}</Badge></Table.Cell>
            <Table.Cell align="right">{money(o.total)}</Table.Cell>
          </Table.Row>
        {/each}
      </Table.Body>
    </Table>
  {:else}
    <Heading level={1}>Customer not found</Heading>
  {/if}
</Layout>
