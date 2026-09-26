<script>
  import { provideStrings } from '../../src/index.js'
  import Pagination from '../../src/Pagination.svelte'
  let { words = undefined } = $props()
  if (words !== undefined) provideStrings(() => words)
</script>

<Pagination page={2} perPage={10} total={35} />
