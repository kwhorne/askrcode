<script>
  import { provideLocale, numbers, dates } from '../../src/index.js'
  let { locale = undefined, number = undefined, numberOptions = undefined,
        date = undefined, dateOptions = undefined } = $props()
  if (locale !== undefined) provideLocale(() => locale)
  const n = numbers()
  const d = dates()
</script>

<output data-number>{n(number, numberOptions)}</output>
<output data-date>{dateOptions ? d(date, dateOptions) : d(date)}</output>
