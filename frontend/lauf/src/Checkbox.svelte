<!-- A checkbox with its own label.
     The label lives in the component rather than in Field, because a
     checkbox has its text to the right of it while an ordinary field has
     it above. A Field around a group of boxes uses as="fieldset" and
     gives the group the heading. -->
<script>
  import { getContext } from 'svelte'
  import { cn } from './utils.js'
  import { FORM, FIELD, uid } from './context.js'

  let {
    checked = $bindable(),
    /** "Some, but not all." A third state that exists only as a DOM
        property — there is no attribute for it, so it has to be set on
        the element. aria-checked="mixed" is what a screen reader reads.
        Without it the box looks empty while twelve rows are selected. */
    indeterminate = false,
    /** Navnet i <Form>. Faller tilbake til feltets navn. */
    name,
    /** For a group: boxes that share a name, each with a value of its own.
        The form then holds the ticked values as a list rather than one
        true or false -- tag_ids: ['1', '3'] -- which is what a
        many-to-many sends, and what an HTML form with the same name on
        several boxes means too. */
    value,
    label,
    description,
    disabled = false,
    class: klass,
    ...rest
  } = $props()

  const field = getContext(FIELD)
  const form = getContext(FORM)
  const key = $derived(name ?? field?.name)
  const bound = $derived(!!form && key != null)
  const grouped = $derived(bound && value !== undefined)
  const current = $derived(
    grouped ? listOf(form.get(key)).includes(value) : bound ? !!form.get(key) : !!checked
  )

  // A list, whatever the form started with: a missing key is no boxes
  // ticked, not a crash on the first click.
  function listOf(v) {
    return Array.isArray(v) ? v : []
  }

  const own = uid('lauf-checkbox')
  const id = $derived(field && !name ? field.id : own)
  const descId = `${own}-desc`

  let el = $state(null)

  // indeterminate exists only as a property, not as an attribute. It has
  // to be set after the element is in the DOM, and set again every time
  // it changes.
  $effect(() => {
    if (el) el.indeterminate = !!indeterminate
  })

  function onChange(e) {
    const v = e.currentTarget.checked
    if (grouped) {
      const rest = listOf(form.get(key)).filter((x) => x !== value)
      form.set(key, v ? [...rest, value] : rest)
    } else if (bound) form.set(key, v)
    else checked = v
  }
</script>

<div class={cn('flex items-start gap-2', klass)} data-lauf="checkbox">
  <input
    {id}
    type="checkbox"
    bind:this={el}
    checked={current}
    {value}
    aria-checked={indeterminate ? 'mixed' : undefined}
    {disabled}
    onchange={onChange}
    aria-invalid={field?.invalid ? 'true' : undefined}
    aria-describedby={description ? descId : field?.describedBy}
    class={cn(
      'mt-0.5 size-4 shrink-0 rounded-sm border border-line accent-accent',
      'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent',
      'disabled:opacity-50'
    )}
    {...rest}
  />
  {#if (label && label !== '') || description}
    <div class="flex flex-col gap-0.5">
      {#if label}
        <label for={id} class="text-sm text-fg leading-tight">{label}</label>
      {/if}
      {#if description}
        <p id={descId} class="text-xs text-muted">{description}</p>
      {/if}
    </div>
  {/if}
</div>
