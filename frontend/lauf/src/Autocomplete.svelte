<!-- Søkefelt med forslag, over Bits UI sin Combobox.
     Bits eier aria-activedescendant, pilnavigering, at feltet beholder
     fokus mens lista flytter markøren, og at lista lukkes riktig. Det er
     den kombinasjonen som gjør at en egenskrevet autocomplete nesten alltid
     er ubrukelig med skjermleser. -->
<script>
  import { Combobox } from 'bits-ui'
  import { getContext } from 'svelte'
  import { cn } from './utils.js'
  import { surface, menuItem } from './overlay.js'
  import { FORM, FIELD } from './context.js'
  import { controlClasses, heights } from './control.js'
  import Icon from './Icon.svelte'
  import { ChevronUpDown, Check } from './icons/micro/index.js'

  let {
    value = $bindable(''),
    /** [{ value, label }] — filtreres av kalleren, ikke av oss. */
    items = [],
    placeholder,
    /** Vises når items er tom. */
    empty = 'No results',
    /** Kalles når søketeksten endres, slik at appen kan filtrere. */
    onsearch,
    disabled = false,
    class: klass,
    ...rest
  } = $props()

  const field = getContext(FIELD)
  const form = getContext(FORM)
  const bound = $derived(!!form && field?.name != null)
  const current = $derived(bound ? (form.get(field.name) ?? '') : value)

  function endre(v) {
    if (bound) form.set(field.name, v)
    else value = v
  }

  const valgt = $derived(items.find((i) => i.value === current))
</script>

<Combobox.Root
  type="single"
  value={current}
  onValueChange={endre}
  {disabled}
  {...rest}
>
  <div class="relative flex items-center">
    <Combobox.Input
      {placeholder}
      id={field?.id}
      defaultValue={valgt?.label}
      oninput={(e) => onsearch?.(e.currentTarget.value)}
      aria-invalid={field?.invalid ? 'true' : undefined}
      aria-describedby={field?.describedBy}
      class={cn(controlClasses, heights.base, 'border-line pr-9', klass)}
      data-lauf="autocomplete"
    />
    <Combobox.Trigger class="absolute right-2 text-muted">
      {#snippet child({ props })}
        <button {...props} type="button" tabindex="-1" aria-label="Show suggestions">
          <Icon icon={ChevronUpDown} size="sm" />
        </button>
      {/snippet}
    </Combobox.Trigger>
  </div>

  <Combobox.Portal>
    <Combobox.Content sideOffset={6} class={cn(surface, 'max-h-64 w-(--bits-combobox-anchor-width) overflow-y-auto p-1')}>
      {#each items as item (item.value)}
        <Combobox.Item value={item.value} label={item.label} class={menuItem}>
          {#snippet children({ selected })}
            <span class="flex-1">{item.label}</span>
            {#if selected}<Icon icon={Check} size="sm" class="text-accent" />{/if}
          {/snippet}
        </Combobox.Item>
      {:else}
        <p class="px-2 py-1.5 text-sm text-muted">{empty}</p>
      {/each}
    </Combobox.Content>
  </Combobox.Portal>
</Combobox.Root>
