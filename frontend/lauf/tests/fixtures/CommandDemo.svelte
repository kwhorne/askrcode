<script>
  import { Command } from '../../src/index.js'
</script>

<Command label="Commands" placeholder="Search…">
  <Command.Group label="Customers">
    <Command.Item value="new-customer" label="New customer" />
    <Command.Item value="list-customers" label="All customers" />
  </Command.Group>
</Command>
