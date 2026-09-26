<script>
  // A page as Inertia has one: it formats in its own script, and its
  // layout is its child, not its parent.
  import { numbers } from '../../src/index.js'
  import Pagination from '../../src/Pagination.svelte'
  const n = numbers()
</script>

<output data-number>{n(1234.5)}</output>
<Pagination page={1} perPage={10} total={12345} />
