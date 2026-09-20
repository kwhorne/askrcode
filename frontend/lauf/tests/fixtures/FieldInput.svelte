<script>
  import { Field, Input, Textarea, Select } from '../../src/index.js'
  let { control = 'input', ...field } = $props()
</script>

<Field {...field}>
  {#if control === 'textarea'}
    <Textarea />
  {:else if control === 'select'}
    <Select placeholder="Pick one">
      <option value="a">A</option>
      <option value="b">B</option>
    </Select>
  {:else}
    <Input />
  {/if}
</Field>
