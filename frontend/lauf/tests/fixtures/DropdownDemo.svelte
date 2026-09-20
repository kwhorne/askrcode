<script>
  import { Dropdown, Button } from '../../src/index.js'
  let { open = $bindable(false) } = $props()
</script>

<Dropdown bind:open>
  {#snippet trigger(props)}
    <Button {...props}>Options</Button>
  {/snippet}
  <Dropdown.Group label="Actions">
    <Dropdown.Item href="/edit">Edit</Dropdown.Item>
  </Dropdown.Group>
  <Dropdown.Separator />
  <Dropdown.Item variant="danger">Delete</Dropdown.Item>
</Dropdown>
