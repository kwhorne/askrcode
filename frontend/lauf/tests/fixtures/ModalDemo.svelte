<script>
  import { Modal, Button } from '../../src/index.js'
  let { open = $bindable(false), ...rest } = $props()
</script>

<Button onclick={() => (open = true)}>Open</Button>
<Modal bind:open title="Delete customer" description="This cannot be undone." {...rest}>
  <p>Ada Lovelace will be removed.</p>
  {#snippet footer()}
    <Button onclick={() => (open = false)}>Cancel</Button>
    <Button variant="danger">Delete</Button>
  {/snippet}
</Modal>
