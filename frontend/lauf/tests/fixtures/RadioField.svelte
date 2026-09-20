<script>
  import { Field, Radio } from '../../src/index.js'
  let { ...field } = $props()
</script>

<Field as="fieldset" {...field}>
  <Radio value="small" label="Small" />
  <Radio value="large" label="Large" />
</Field>
