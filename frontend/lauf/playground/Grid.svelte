<script>
  import { DataGrid, Heading, Text, Badge } from '../src/index.js'

  // Ti tusen rader, i nettleseren. Nok til at virtualiseringen betyr noe
  // og til at en grid uten den ville kjennes.
  const rader = Array.from({ length: 10000 }, (_, i) => ({
    id: i + 1,
    name: `Customer ${String(i + 1).padStart(5, '0')}`,
    email: `c${i + 1}@example.com`,
    balance: ((i * 37) % 9000) / 10,
    active: i % 3 !== 0,
  }))

  const columns = [
    { key: 'name', label: 'Name', sortable: true },
    { key: 'email', label: 'Email' },
    { key: 'balance', label: 'Balance', align: 'right', sortable: true,
      format: (v) => new Intl.NumberFormat('en-US',
        { style: 'currency', currency: 'USD' }).format(v) },
    { key: 'active', label: 'Status', cell: status },
  ]

  let valgte = $state(new Set())
</script>

{#snippet status(row)}
  <Badge color={row.active ? 'accent' : 'neutral'}>
    {row.active ? 'active' : 'inactive'}
  </Badge>
{/snippet}

<section class="flex flex-col gap-3">
  <Heading level={2}>DataGrid</Heading>
  <Text muted size="sm">
    10 000 rows, client mode, virtualised. Selected: <span id="grid-selected">{valgte.size}</span>
  </Text>

  <DataGrid
    caption="Customers"
    {columns}
    rows={rader}
    perPage={500}
    virtual
    rowHeight={41}
    height={420}
    selectable
    bind:selected={valgte}
  />
</section>
