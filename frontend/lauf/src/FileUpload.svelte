<!--
  Filopplasting.

  Bits har ingen primitiv for dette, så den er skrevet her — men
  serversiden finnes fra før: Askrs multipart-parser kopierer ingenting, og
  `StoreIn` lagrer under et tilfeldig navn i stedet for klientens. Det er
  grunnen til at denne var billigere enn den ser ut.

  Den bygger på en ekte <input type="file">. Alternativet — en div med
  onclick og en skjult input — mister tastatur, autofyll og at nettleseren
  selv sier «ingen fil valgt». Inputen er visuelt skjult, ikke `hidden`:
  et skjult felt kan ikke få fokus, og da er komponenten utilgjengelig.

  Dra-og-slipp er et tillegg oppå, aldri den eneste veien inn. Den som ikke
  kan dra skal komme like langt.
-->
<script>
  import { getContext } from 'svelte'
  import { cn } from './utils.js'
  import { FORM, FIELD, uid } from './context.js'
  import Icon from './Icon.svelte'
  import Button from './Button.svelte'
  import { ArrowUpTray, XMark, Document } from './icons/micro/index.js'

  import { strings, numbers } from './strings.js'
  const word = strings()
  const num = numbers()
  const oneDecimal = { minimumFractionDigits: 1, maximumFractionDigits: 1 }

  let {
    /** File eller File[] — settes i <Form> når komponenten står i et Field. */
    files = $bindable([]),
    multiple = false,
    /** accept-attributtet, f.eks. "image/*,.pdf" */
    accept,
    /** Maks per fil, i byte. Askrs MaxBodyBytes er 8 MB som standard. */
    maxSize,
    disabled = false,
    class: klass,
    ...rest
  } = $props()

  const field = getContext(FIELD)
  const form = getContext(FORM)
  const bound = $derived(!!form && field?.name != null)
  const own = uid('lauf-file')
  const id = $derived(field ? field.id : own)

  let dragOver = $state(false)
  let avvist = $state([])

  const liste = $derived.by(() => {
    const v = bound ? form.get(field.name) : files
    if (!v) return []
    return Array.isArray(v) ? v : [v]
  })

  function sett(neste) {
    const v = multiple ? neste : (neste[0] ?? null)
    if (bound) form.set(field.name, v)
    else files = v
  }

  function taImot(fileList) {
    const inn = [...fileList]
    const forStore = maxSize ? inn.filter((f) => f.size > maxSize) : []
    avvist = forStore.map((f) => f.name)
    const ok = maxSize ? inn.filter((f) => f.size <= maxSize) : inn
    sett(multiple ? [...liste, ...ok] : ok)
  }

  function fjern(i) {
    const neste = liste.filter((_, n) => n !== i)
    sett(neste)
  }

  function bytes(n) {
    if (n < 1024) return `${num(n)} B`
    if (n < 1024 * 1024) return `${num(n / 1024, oneDecimal)} kB`
    return `${num(n / (1024 * 1024), oneDecimal)} MB`
  }
</script>

<div class={cn('flex flex-col gap-2', klass)} data-lauf="file-upload">
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    class={cn(
      'flex flex-col items-center gap-2 rounded-surface border border-dashed p-6 text-center',
      dragOver ? 'border-accent bg-accent/5' : 'border-line',
      disabled && 'opacity-50'
    )}
    ondragover={(e) => {
      e.preventDefault()
      if (!disabled) dragOver = true
    }}
    ondragleave={() => (dragOver = false)}
    ondrop={(e) => {
      e.preventDefault()
      dragOver = false
      if (!disabled) taImot(e.dataTransfer.files)
    }}
  >
    <Icon icon={ArrowUpTray} size="lg" class="text-muted" />
    <!-- Etiketten er knappen. En <label for> åpner filvelgeren ved klikk
         og ved Enter på inputen, uten at vi skriver noe av det. -->
    <label
      for={id}
      class={cn(
        'cursor-pointer rounded-control border border-line px-3 py-1.5 text-sm text-fg',
        'hover:bg-line/40',
        'focus-within:outline-2 focus-within:outline-offset-1 focus-within:outline-accent'
      )}
    >
      {multiple ? word('choose_files') : word('choose_file')}
      <input
        {id}
        type="file"
        {multiple}
        {accept}
        {disabled}
        onchange={(e) => taImot(e.currentTarget.files)}
        aria-invalid={field?.invalid ? 'true' : undefined}
        aria-describedby={field?.describedBy}
        class="sr-only"
      />
    </label>
    <p class="text-xs text-muted">{word('or_drag')}</p>
  </div>

  {#if avvist.length}
    <p role="alert" class="text-xs text-danger">
      {word('too_large', { names: avvist.join(', ') })}
    </p>
  {/if}

  {#if liste.length}
    <ul class="flex flex-col gap-1">
      {#each liste as f, i (f.name + f.size)}
        <li class="flex items-center gap-2 rounded-control border border-line px-2 py-1.5 text-sm">
          <Icon icon={Document} size="sm" class="text-muted" />
          <span class="flex-1 truncate">{f.name}</span>
          <span class="text-xs text-muted tabular-nums">{bytes(f.size)}</span>
          <Button
            size="sm"
            variant="ghost"
            icon={XMark}
            label={word('remove_file', { name: f.name })}
            onclick={() => fjern(i)}
          />
        </li>
      {/each}
    </ul>
  {/if}
</div>
