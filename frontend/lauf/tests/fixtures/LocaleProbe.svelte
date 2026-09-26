<script>
  import { provideLocale, Field, DatePicker } from '../../src/index.js'
  import Pagination from '../../src/Pagination.svelte'
  let { locale = undefined, total = 12345 } = $props()
  if (locale !== undefined) provideLocale(() => locale)
</script>

<Pagination page={2} perPage={10} {total} />
<Field label="Due">
  <DatePicker value="2026-09-20" />
</Field>
