<script>
  import { Table } from '../../src/index.js'
  let { rows = [] } = $props()
</script>

<Table caption="Customers">
  <Table.Head>
    <Table.Row>
      <Table.Header>Name</Table.Header>
      <Table.Header align="right">Balance</Table.Header>
    </Table.Row>
  </Table.Head>
  <Table.Body>
    {#each rows as r (r.name)}
      <Table.Row>
        <Table.Cell>{r.name}</Table.Cell>
        <Table.Cell align="right">{r.balance}</Table.Cell>
      </Table.Row>
    {/each}
  </Table.Body>
</Table>
