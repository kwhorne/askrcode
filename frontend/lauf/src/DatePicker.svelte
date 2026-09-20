<!--
  Datovelger, over Bits UI.

  **Verdien inn og ut er en ISO-streng, ikke et DateValue.** Bits bygger på
  @internationalized/date, og den typen skal ikke lekke ut i Laufs API —
  samme regel som for resten av Bits. Askr sender datoer som `YYYY-MM-DD`
  fra `DateTimeToSql`, og det er den formen en app skal kunne sende rett
  inn og få rett ut. Konverteringen ligger her.

  Bits eier kalenderen: piltaster mellom dager, PageUp/PageDown mellom
  måneder, at rutenettet er et ekte grid med ukedager som kolonneoverskrifter,
  og at den valgte dagen annonseres. Det er mye mer enn det ser ut som.
-->
<script>
  import { DatePicker as B } from 'bits-ui'
  import { parseDate } from '@internationalized/date'
  import { getContext } from 'svelte'
  import { cn } from './utils.js'
  import { surface } from './overlay.js'
  import { FORM, FIELD } from './context.js'
  import { controlClasses, heights } from './control.js'
  import Icon from './Icon.svelte'
  import { CalendarDays, ChevronLeft, ChevronRight } from './icons/micro/index.js'

  let {
    /** ISO-dato, 'YYYY-MM-DD', eller '' for tom. */
    value = $bindable(''),
    /** Tidligste og seneste valgbare dato, også som ISO. */
    min,
    max,
    disabled = false,
    /** Brukes til ukedagsnavn og månedsnavn. */
    locale = 'en-US',
    class: klass,
    ...rest
  } = $props()

  const field = getContext(FIELD)
  const form = getContext(FORM)
  const bound = $derived(!!form && field?.name != null)
  const iso = $derived(bound ? (form.get(field.name) ?? '') : (value ?? ''))

  // parseDate kaster på noe som ikke er en gyldig ISO-dato. En tom eller
  // ødelagt verdi skal gi en tom velger, ikke en hvit side.
  function tilDato(s) {
    if (!s) return undefined
    try {
      return parseDate(String(s).slice(0, 10))
    } catch {
      return undefined
    }
  }

  function endre(v) {
    const s = v ? v.toString() : ''
    if (bound) form.set(field.name, s)
    else value = s
  }
</script>

<B.Root
  value={tilDato(iso)}
  onValueChange={endre}
  minValue={tilDato(min)}
  maxValue={tilDato(max)}
  {disabled}
  {locale}
  data-lauf="datepicker"
  {...rest}
>
  <div class="relative flex items-center">
    <B.Input
      id={field?.id}
      aria-invalid={field?.invalid ? 'true' : undefined}
      aria-describedby={field?.describedBy}
      class={cn(controlClasses, heights.base, 'flex items-center border-line pr-9', klass)}
    >
      {#snippet children({ segments })}
        <!-- Nøkkel på indeks: skilletegnene har alle part === 'literal',
             så «MM/DD/YYYY» gir to like nøkler. -->
        {#each segments as { part, value: seg }, i (i)}
          <B.Segment {part} class="rounded-sm px-0.5 data-[segment=literal]:text-muted focus:bg-accent/20 focus:outline-none">
            {seg}
          </B.Segment>
        {/each}
      {/snippet}
    </B.Input>
    <B.Trigger class="absolute right-2 text-muted">
      {#snippet child({ props })}
        <button {...props} type="button" aria-label="Choose date">
          <Icon icon={CalendarDays} size="sm" />
        </button>
      {/snippet}
    </B.Trigger>
  </div>

  <B.Content sideOffset={6} class={cn(surface, 'p-3')}>
    <B.Calendar>
      {#snippet children({ months, weekdays })}
        <B.Header class="mb-2 flex items-center justify-between">
          <B.PrevButton class="rounded-control p-1 hover:bg-line/50">
            <Icon icon={ChevronLeft} size="sm" label="Previous month" />
          </B.PrevButton>
          <B.Heading class="text-sm font-medium text-fg" />
          <B.NextButton class="rounded-control p-1 hover:bg-line/50">
            <Icon icon={ChevronRight} size="sm" label="Next month" />
          </B.NextButton>
        </B.Header>
        {#each months as month (month.value)}
          <B.Grid class="w-full border-collapse">
            <B.GridHead>
              <B.GridRow class="flex">
                <!-- Nøkkel på indeks, ikke på navnet: smale ukedagsnavn gjentar seg
                     («S M T W T F S»), og to like nøkler er en feil i Svelte. -->
                {#each weekdays as day, i (i)}
                  <B.HeadCell class="w-9 text-xs font-normal text-muted">{day}</B.HeadCell>
                {/each}
              </B.GridRow>
            </B.GridHead>
            <B.GridBody>
              {#each month.weeks as week, wi (wi)}
                <B.GridRow class="flex">
                  {#each week as date (date.toString())}
                    <B.Cell {date} month={month.value} class="p-0">
                      <B.Day
                        class={cn(
                          'flex size-9 items-center justify-center rounded-control text-sm',
                          'hover:bg-line/50',
                          'data-[selected]:bg-accent data-[selected]:text-accent-fg',
                          'data-[outside-month]:text-muted/50',
                          'data-[disabled]:opacity-40 data-[disabled]:pointer-events-none',
                          'data-[today]:font-semibold'
                        )}
                      />
                    </B.Cell>
                  {/each}
                </B.GridRow>
              {/each}
            </B.GridBody>
          </B.Grid>
        {/each}
      {/snippet}
    </B.Calendar>
  </B.Content>
</B.Root>
