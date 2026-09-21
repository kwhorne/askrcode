<!--
  Editor — markdown with a toolbar and a preview pane.

      <Lauf.Editor bind:value={notes} preview />

  The value is markdown, in and out. Not HTML. That is a choice: markdown
  is what belongs in the database — a person can read it in a SQL console,
  it diffs, and it cannot carry a script.

  THIS IS NOT WYSIWYG, AND THAT IS DELIBERATE. The field is a <textarea>,
  so you see `**bold**` rather than bold. The price is known; so is what
  it buys, and that is a lot: selection, paste, IME, mobile keyboards and
  — most of all — undo and redo belong to the browser, not to us. An
  editor built on contenteditable owns all of that itself, and that is
  where editors go to die. If you want true WYSIWYG the answer is
  ProseMirror, and that is a dependency Lauf does not have.

  THE UNDO STACK IS WHY execCommand IS HERE. Assigning textarea.value
  directly throws away the browser's undo history, so Cmd+Z after
  clicking Bold takes you back to before everything you typed.
  `insertText` through execCommand puts the change on the stack as if it
  had been typed. The method is marked deprecated and has no replacement
  for this particular job; there is a fallback below for the day it goes.
-->
<script>
  import { getContext } from 'svelte'
  import { cn } from './utils.js'
  import { FORM, FIELD, uid } from './context.js'
  import { controlClasses } from './control.js'
  import { renderMarkdown } from './markdown.js'
  import Icon from './Icon.svelte'
  import {
    Bold, Italic, Strikethrough, H1, H2, H3, ListBullet, NumberedList,
    Link as LinkIcon, CodeBracket, ArrowUturnLeft, ArrowUturnRight, Eye, EyeSlash,
  } from './icons/micro/index.js'

  let {
    /** The markdown source. */
    value = $bindable(),
    /**
     * Space-separated list of buttons. `|` is a separator and `~` pushes
     * the rest to the right — the same shape Flux uses, because it reads
     * faster than an array of objects.
     */
    toolbar = 'heading | bold italic strike | quote code | bullet ordered | link ~ undo redo preview',
    placeholder = '',
    rows = 12,
    disabled = false,
    /** Whether the preview pane is open. Bindable. */
    preview = $bindable(false),
    class: klass,
    ...rest
  } = $props()

  const field = getContext(FIELD)
  const form = getContext(FORM)
  const bound = $derived(!!form && field?.name != null)
  const current = $derived(bound ? (form.get(field.name) ?? '') : (value ?? ''))
  const html = $derived(renderMarkdown(current))

  const previewId = uid('lauf-editor-preview')
  let area = $state(null)
  let focused = $state(0) // roving tabindex across the toolbar

  function commit(v) {
    if (bound) form.set(field.name, v)
    else value = v
  }

  // Writes over the selection through the browser's own editing, so the
  // undo stack survives. Falls back to direct assignment where
  // execCommand is missing — that loses undo, but not the edit.
  function write(text, start, end) {
    if (!area) return
    area.focus()
    area.setSelectionRange(start, end)
    let ok = false
    try {
      ok = document.execCommand('insertText', false, text)
    } catch {
      ok = false
    }
    if (!ok) {
      const v = area.value
      area.value = v.slice(0, start) + text + v.slice(end)
    }
    commit(area.value)
  }

  /** Wraps the selection, or unwraps it when the markers are already there. */
  function wrap(before, after = before, filler = '') {
    if (!area) return
    const { selectionStart: a, selectionEnd: b, value: v } = area
    const inside = v.slice(a, b)

    // Already wrapped, either inside the selection or around it.
    if (
      inside.startsWith(before) &&
      inside.endsWith(after) &&
      inside.length >= before.length + after.length
    ) {
      const bare = inside.slice(before.length, inside.length - after.length)
      write(bare, a, b)
      queueMicrotask(() => area?.setSelectionRange(a, a + bare.length))
      return
    }
    if (v.slice(a - before.length, a) === before && v.slice(b, b + after.length) === after) {
      write(inside, a - before.length, b + after.length)
      queueMicrotask(() =>
        area?.setSelectionRange(a - before.length, a - before.length + inside.length)
      )
      return
    }

    const text = inside || filler
    write(before + text + after, a, b)
    // Empty selection: caret between the markers, ready to type.
    const caret = a + before.length
    queueMicrotask(() => area?.setSelectionRange(caret, caret + text.length))
  }

  /**
   * Puts a prefix on every line the selection touches, and takes it off
   * again when all of them already have it. Whole lines, not just the
   * selected part — a heading in the middle of a line does not exist.
   */
  function prefixLines(make, strip) {
    if (!area) return
    const v = area.value
    const a = v.lastIndexOf('\n', area.selectionStart - 1) + 1
    let b = v.indexOf('\n', area.selectionEnd)
    if (b === -1) b = v.length

    const lines = v.slice(a, b).split('\n')
    // Only toggles off when the lines are already EXACTLY what this
    // button would produce. Comparing against the pattern instead was
    // wrong: `# x` matches the heading pattern, so "Heading 2" removed
    // the heading rather than changing its level — and "numbered list"
    // emptied a bulleted one. The pattern says what to take off first,
    // not whether we have arrived.
    const already = lines.every((l, i) => make(l.replace(strip, ''), i) === l)
    const next = lines.map((l, i) =>
      already ? l.replace(strip, '') : make(l.replace(strip, ''), i)
    )
    const text = next.join('\n')
    write(text, a, b)
    queueMicrotask(() => area?.setSelectionRange(a, a + text.length))
  }

  function link() {
    if (!area) return
    const { selectionStart: a, selectionEnd: b, value: v } = area
    const inside = v.slice(a, b)
    const isUrl = /^(?:https?:\/\/|mailto:|\/)/i.test(inside.trim())
    const text = isUrl ? `[](${inside.trim()})` : `[${inside}](url)`
    write(text, a, b)
    // Caret where you actually carry on typing: the label when we were
    // handed a url, the address when we were handed a label.
    queueMicrotask(() => {
      if (!area) return
      if (isUrl) area.setSelectionRange(a + 1, a + 1)
      else area.setSelectionRange(a + inside.length + 3, a + inside.length + 6)
    })
  }

  function history(command) {
    area?.focus()
    try {
      document.execCommand(command)
    } catch {
      /* Without execCommand the button does nothing. Cmd+Z still works. */
    }
    if (area) commit(area.value)
  }

  const buttons = {
    heading: { icon: H1, label: 'Heading 1', run: () => prefixLines((l) => `# ${l}`, /^#{1,6}\s+/) },
    h2: { icon: H2, label: 'Heading 2', run: () => prefixLines((l) => `## ${l}`, /^#{1,6}\s+/) },
    h3: { icon: H3, label: 'Heading 3', run: () => prefixLines((l) => `### ${l}`, /^#{1,6}\s+/) },
    bold: { icon: Bold, label: 'Bold', key: '⌘B', run: () => wrap('**', '**', 'bold text') },
    italic: { icon: Italic, label: 'Italic', key: '⌘I', run: () => wrap('*', '*', 'italic text') },
    strike: { icon: Strikethrough, label: 'Strikethrough', run: () => wrap('~~', '~~', 'struck out') },
    code: { icon: CodeBracket, label: 'Code', key: '⌘E', run: () => wrap('`', '`', 'code') },
    quote: { glyph: '”', label: 'Quote', run: () => prefixLines((l) => `> ${l}`, /^>\s?/) },
    bullet: {
      icon: ListBullet, label: 'Bulleted list',
      run: () => prefixLines((l) => `- ${l}`, /^\s*(?:[-*+]|\d+[.)])\s+/),
    },
    ordered: {
      icon: NumberedList, label: 'Numbered list',
      run: () => prefixLines((l, i) => `${i + 1}. ${l}`, /^\s*(?:[-*+]|\d+[.)])\s+/),
    },
    link: { icon: LinkIcon, label: 'Link', key: '⌘K', run: link },
    undo: { icon: ArrowUturnLeft, label: 'Undo', run: () => history('undo') },
    redo: { icon: ArrowUturnRight, label: 'Redo', run: () => history('redo') },
  }

  // The toolbar string is read once. `~` becomes an element that grows,
  // `|` a rule, and an unknown name is skipped quietly — a toolbar that
  // throws on a typo is worse than one missing a button.
  const items = $derived(
    toolbar
      .split(/\s+/)
      .filter(Boolean)
      .map((name) => {
        if (name === '|') return { type: 'sep' }
        if (name === '~') return { type: 'spacer' }
        if (name === 'preview') return { type: 'preview' }
        return buttons[name] ? { type: 'btn', name, ...buttons[name] } : null
      })
      .filter(Boolean)
  )

  // Only buttons can hold focus. Separators and spacers are not stops.
  const stops = $derived(
    items
      .map((e, i) => (e.type === 'btn' || e.type === 'preview' ? i : -1))
      .filter((i) => i >= 0)
  )

  function onToolbarKey(e) {
    const n = stops.length
    if (!n) return
    const at = stops.indexOf(focused)
    let next = null
    if (e.key === 'ArrowRight') next = stops[(at + 1) % n]
    else if (e.key === 'ArrowLeft') next = stops[(at - 1 + n) % n]
    else if (e.key === 'Home') next = stops[0]
    else if (e.key === 'End') next = stops[n - 1]
    if (next === null) return
    e.preventDefault()
    focused = next
    e.currentTarget.querySelector(`[data-i="${next}"]`)?.focus()
  }

  function onKey(e) {
    const meta = e.metaKey || e.ctrlKey
    if (!meta || e.altKey) return
    const k = e.key.toLowerCase()
    const shortcuts = { b: 'bold', i: 'italic', k: 'link', e: 'code' }
    if (!shortcuts[k]) return
    e.preventDefault()
    buttons[shortcuts[k]].run()
  }

  function onInput(e) {
    commit(e.currentTarget.value)
  }

  const buttonClasses =
    'inline-flex size-7 items-center justify-center rounded-control text-muted ' +
    'transition-colors hover:bg-line/50 hover:text-fg ' +
    'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent ' +
    'disabled:opacity-50 disabled:cursor-not-allowed'

  // The preview has no .prose to lean on — Lauf cannot assume the app has
  // the typography plugin. So the styling lives here, on the wrapper, and
  // markdown.js hands back plain semantic HTML with no classes.
  const proseClasses =
    'text-sm text-fg break-words ' +
    '[&_h1]:text-lg [&_h1]:font-semibold [&_h1]:mt-4 [&_h1]:mb-2 first:[&_h1]:mt-0 ' +
    '[&_h2]:text-base [&_h2]:font-semibold [&_h2]:mt-4 [&_h2]:mb-2 first:[&_h2]:mt-0 ' +
    '[&_h3]:text-sm [&_h3]:font-semibold [&_h3]:mt-3 [&_h3]:mb-1.5 ' +
    '[&_h4]:text-sm [&_h4]:font-semibold [&_h5]:text-sm [&_h6]:text-sm ' +
    '[&_p]:my-2 first:[&_p]:mt-0 ' +
    '[&_ul]:my-2 [&_ul]:list-disc [&_ul]:pl-5 ' +
    '[&_ol]:my-2 [&_ol]:list-decimal [&_ol]:pl-5 ' +
    '[&_li]:my-0.5 ' +
    '[&_a]:text-accent [&_a]:underline [&_a]:underline-offset-2 ' +
    '[&_code]:rounded [&_code]:bg-line/50 [&_code]:px-1 [&_code]:py-0.5 [&_code]:text-[0.85em] ' +
    '[&_pre]:my-2 [&_pre]:overflow-x-auto [&_pre]:rounded-control [&_pre]:bg-line/40 [&_pre]:p-3 ' +
    '[&_pre_code]:bg-transparent [&_pre_code]:p-0 [&_pre_code]:text-xs ' +
    '[&_blockquote]:my-2 [&_blockquote]:border-l-2 [&_blockquote]:border-line [&_blockquote]:pl-3 [&_blockquote]:text-muted ' +
    '[&_hr]:my-4 [&_hr]:border-line ' +
    '[&_strong]:font-semibold [&_del]:opacity-70'
</script>

<div
  class={cn(
    controlClasses,
    'border-line flex flex-col gap-0 overflow-hidden p-0',
    'focus-within:outline-2 focus-within:outline-offset-1 focus-within:outline-accent',
    disabled && 'opacity-50',
    klass
  )}
  data-lauf="editor"
>
  <!-- role="toolbar" with a roving tabindex: one tab stop for the whole
       row, arrow keys between the buttons. Without it there are twelve
       tab stops between the previous field and the text itself, and
       anyone using a keyboard gives up before getting past. -->
  <!-- svelte-ignore a11y_interactive_supports_focus
       The linter wants tabindex on the toolbar itself. That is wrong for
       this pattern: with a roving tabindex the buttons carry it, and a
       tab stop on the container as well would give two — one that does
       nothing and one that does. ARIA's own toolbar recipe says the
       same. -->
  <div
    role="toolbar"
    aria-label="Formatting"
    aria-controls={field?.id ?? undefined}
    onkeydown={onToolbarKey}
    class="flex items-center gap-0.5 border-b border-line bg-raised/40 px-1.5 py-1"
  >
    {#each items as item, i (i)}
      {#if item.type === 'sep'}
        <span class="mx-1 h-4 w-px shrink-0 bg-line" aria-hidden="true"></span>
      {:else if item.type === 'spacer'}
        <span class="flex-1" aria-hidden="true"></span>
      {:else if item.type === 'preview'}
        <button
          type="button"
          data-i={i}
          tabindex={focused === i ? 0 : -1}
          {disabled}
          aria-expanded={preview}
          aria-controls={preview ? previewId : undefined}
          aria-label={preview ? 'Hide preview' : 'Show preview'}
          title={preview ? 'Hide preview' : 'Show preview'}
          onclick={() => (preview = !preview)}
          onfocus={() => (focused = i)}
          class={cn(buttonClasses, preview && 'bg-line/60 text-fg')}
        >
          <Icon icon={preview ? EyeSlash : Eye} size="sm" />
        </button>
      {:else}
        <button
          type="button"
          data-i={i}
          tabindex={focused === i ? 0 : -1}
          {disabled}
          aria-label={item.label}
          title={item.key ? `${item.label} (${item.key})` : item.label}
          onclick={item.run}
          onfocus={() => (focused = i)}
          class={buttonClasses}
        >
          {#if item.glyph}
            <span aria-hidden="true" class="text-base leading-none font-serif">{item.glyph}</span>
          {:else}
            <Icon icon={item.icon} size="sm" />
          {/if}
        </button>
      {/if}
    {/each}
  </div>

  <div class="flex min-h-0 flex-col md:flex-row">
    <textarea
      bind:this={area}
      id={field?.id}
      {rows}
      {placeholder}
      {disabled}
      value={current}
      oninput={onInput}
      onkeydown={onKey}
      aria-invalid={field?.invalid ? 'true' : undefined}
      aria-describedby={field?.describedBy}
      required={field?.required || undefined}
      class={cn(
        'w-full flex-1 resize-y bg-transparent px-3 py-2 font-mono text-sm text-fg',
        'placeholder:text-muted/70 focus:outline-none',
        'disabled:cursor-not-allowed',
        preview && 'md:w-1/2 md:resize-none md:border-r md:border-line'
      )}
      {...rest}
    ></textarea>

    {#if preview}
      <!-- Not aria-live. It updates on every keystroke, and a live region
           would read the whole text back for each letter. It has a label
           instead, so it can be navigated to. -->
      <div
        id={previewId}
        aria-label="Preview"
        class={cn(
          'flex-1 overflow-y-auto border-t border-line px-3 py-2 md:w-1/2 md:border-t-0',
          proseClasses
        )}
      >
        {#if current.trim() === ''}
          <p class="text-muted/70">Nothing to preview yet.</p>
        {:else}
          <!-- renderMarkdown escapes everything and never lets raw HTML
               through. That is the precondition for this line. -->
          <!-- eslint-disable-next-line svelte/no-at-html-tags -->
          {@html html}
        {/if}
      </div>
    {/if}
  </div>
</div>
