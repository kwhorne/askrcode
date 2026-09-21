<!-- A tab panel.

     `findable` is the one thing Bits does not reach: Ctrl+F in the
     browser cannot find text in a panel that is not the active one,
     because an inactive panel carries `hidden`. That is usually right —
     but on a settings page split into six tabs it means the search box
     for the whole page is a lie.

     `hidden="until-found"` is the platform's answer. The browser searches
     the content anyway, and when it matches it fires `beforematch` on the
     element, scrolls to it and reveals it. We use that event to switch to
     the tab, so the panel is genuinely open rather than a fragment
     hanging out of a hidden container.

     Bits sets `hidden` itself and wins the prop merge, so the panel is
     taken over through its `child` snippet. The attribute is then set on
     the element rather than through Svelte, because `hidden` is a boolean
     attribute to the compiler: hidden={'until-found'} renders hidden="",
     which hides the panel and loses the part that matters.

     Browsers without `until-found` treat any value as plain hidden, so
     the panel stays hidden and simply is not findable. That degrades the
     feature, not the page. -->
<script>
  import { Tabs } from 'bits-ui'
  import { cn } from './utils.js'

  let {
    value,
    /** Let browser find-in-page reach this panel while it is inactive. */
    findable = false,
    children,
    class: klass,
    ...rest
  } = $props()

  let el = $state(null)

  function reveal() {
    // Bits reads the value from the root's context; setting the
    // attribute alone would show the content without the tab following,
    // so we click the trigger that owns this panel. It is the same path
    // a person takes, which means selection, focus and data-state all
    // end up where they would anyway.
    const id = el?.getAttribute('aria-labelledby')
    if (id) document.getElementById(id)?.click()
  }

  $effect(() => {
    if (!el) return
    if (!findable) return
    // The node is captured, not read again in the teardown: `bind:this`
    // has already set `el` back to null by the time cleanup runs, and
    // reading it there throws on every unmount.
    const node = el
    node.addEventListener('beforematch', reveal)
    return () => node.removeEventListener('beforematch', reveal)
  })

  // A MutationObserver rather than an effect, because Bits rewrites
  // `hidden` whenever the active tab changes and an effect has nothing to
  // depend on that would make it run again. The first version used one
  // and the attribute silently fell back to plain `hidden` the moment you
  // switched tabs — the panel was then unsearchable again, with nothing
  // to show for it. A test switches tabs and reads the attribute back.
  //
  // Writing the attribute from inside the observer queues another record,
  // so the guard is what terminates it: the second pass sees
  // 'until-found' already there and does nothing.
  $effect(() => {
    if (!el || !findable) return
    const node = el
    const mark = () => {
      if (node.hasAttribute('hidden') && node.getAttribute('hidden') !== 'until-found')
        node.setAttribute('hidden', 'until-found')
    }
    mark()
    const mo = new MutationObserver(mark)
    mo.observe(node, { attributes: true, attributeFilter: ['hidden'] })
    return () => mo.disconnect()
  })
</script>

{#if findable}
  <Tabs.Content {value} child={panel}>
    {#snippet panel({ props })}
      <div bind:this={el} {...props} class={cn('text-sm text-fg', klass)} {...rest}>
        {@render children?.()}
      </div>
    {/snippet}
  </Tabs.Content>
{:else}
  <Tabs.Content {value} class={cn('text-sm text-fg', klass)} {...rest}>
    {@render children?.()}
  </Tabs.Content>
{/if}
