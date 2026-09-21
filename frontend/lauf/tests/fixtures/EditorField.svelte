<script>
  import { Field, Editor } from '../../src/index.js'
  let { value = $bindable(''), preview = $bindable(false), toolbar, ...field } = $props()
</script>

<Field {...field}>
  <Editor bind:value bind:preview {toolbar} />
</Field>
