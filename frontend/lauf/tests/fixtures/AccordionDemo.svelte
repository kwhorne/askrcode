<script>
  import { Accordion } from '../../src/index.js'
  let { value = $bindable() } = $props()
</script>

<Accordion bind:value>
  <Accordion.Item value="a" title="First">Body of first</Accordion.Item>
  <Accordion.Item value="b" title="Second">Body of second</Accordion.Item>
</Accordion>
