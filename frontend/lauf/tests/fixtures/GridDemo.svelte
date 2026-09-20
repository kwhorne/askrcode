<script>
  import { DataGrid } from '../../src/index.js'

  let { rows = [], grid = null, onstate, selectable = false,
        selected = $bindable(new Set()), virtual = false, loading = false,
        perPage = 25 } = $props()

  const columns = [
    { key: 'name', label: 'Name', sortable: true },
    { key: 'email', label: 'Email' },
    { key: 'balance', label: 'Balance', align: 'right', sortable: true,
      format: (v) => (v == null ? '—' : `$${v}`) },
  ]
</script>

<DataGrid
  caption="Customers"
  {rows} {columns} {grid} {onstate} {selectable} {virtual} {loading} {perPage}
  bind:selected
  rowHeight={40}
  height={200}
/>
