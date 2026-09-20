<script>
  import { Tabs } from '../../src/index.js'
  let { value = $bindable('one') } = $props()
</script>

<Tabs bind:value tabs={[{ value: 'one', label: 'One' }, { value: 'two', label: 'Two' }]}>
  <Tabs.Panel value="one">First panel</Tabs.Panel>
  <Tabs.Panel value="two">Second panel</Tabs.Panel>
</Tabs>
