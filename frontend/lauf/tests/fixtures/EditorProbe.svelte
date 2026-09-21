<script>
  // The value is mirrored into the DOM so tests can read the bound value
  // rather than textarea.value. The fallback path in write() assigns
  // textarea.value directly, so reading that would pass even if the
  // binding never propagated.
  import { Editor } from '../../src/index.js'
  let { value = $bindable(''), ...rest } = $props()
</script>

<Editor bind:value {...rest} />
<output data-testid="out">{value}</output>
