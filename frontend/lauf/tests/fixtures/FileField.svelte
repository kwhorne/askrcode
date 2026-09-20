<script>
  import { Field, FileUpload } from '../../src/index.js'
  let { multiple = false, maxSize, ...field } = $props()
</script>

<Field {...field}>
  <FileUpload {multiple} {maxSize} />
</Field>
