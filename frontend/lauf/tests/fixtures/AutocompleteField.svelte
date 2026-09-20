<script>
  import { Field, Autocomplete } from '../../src/index.js'
  let { items = [], ...field } = $props()
</script>

<Field {...field}>
  <Autocomplete {items} placeholder="Search customers" />
</Field>
