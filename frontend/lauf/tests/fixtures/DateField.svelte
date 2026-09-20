<script>
  import { Field, DatePicker } from '../../src/index.js'
  let { value = $bindable(''), ...field } = $props()
</script>

<Field {...field}>
  <DatePicker bind:value />
</Field>
