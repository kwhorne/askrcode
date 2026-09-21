<!-- Tabs, over Bits UI.

     Bits owns arrow-key navigation, Home/End, the roving tabindex and the
     link between a tab and its panel (aria-controls / aria-labelledby).
     Without it, tabs are just buttons that swap content and a screen
     reader says nothing about them belonging together.

     The tabs are passed as data rather than as child components. Flux
     writes <flux:tab name="profile">Profile</flux:tab> because Blade has
     no good way to hand over a list of objects; Svelte does, and in an
     Askr app the tabs usually come from the server anyway. Icons are
     components in Lauf, so they travel in the array like everything
     else. One list, one code path. -->
<script>
  import { Tabs as B } from 'bits-ui'
  import { cn } from './utils.js'
  import Icon from './Icon.svelte'

  let {
    value = $bindable(),
    /** [{ value, label, icon?, iconTrailing?, badge?, disabled? }] */
    tabs = [],
    /** underline | segmented | pills */
    variant = 'underline',
    /** base | sm */
    size = 'base',
    /**
     * Scroll sideways when the tabs do not fit, with a fade at the
     * trailing edge so it is visible that there is more.
     */
    scrollable = false,
    children,
    class: klass,
    ...rest
  } = $props()

  // The list and the trigger are styled together per variant: an active
  // underline tab needs a border on the list to sit against, while a
  // segmented one needs a track. Splitting them into two lookups meant
  // changing two places to change one thing.
  const lists = {
    underline: 'gap-1 border-b border-line',
    segmented: 'gap-0.5 rounded-control border border-line bg-line/30 p-0.5',
    pills: 'gap-1',
  }

  const triggers = {
    underline:
      '-mb-px border-b-2 border-transparent text-muted ' +
      'hover:text-fg ' +
      'data-[state=active]:border-accent data-[state=active]:text-fg',
    segmented:
      'rounded-[calc(var(--radius-control)-3px)] text-muted ' +
      'hover:text-fg ' +
      'data-[state=active]:bg-raised data-[state=active]:text-fg ' +
      'data-[state=active]:shadow-sm',
    pills:
      'rounded-full text-muted ' +
      'hover:bg-line/50 hover:text-fg ' +
      'data-[state=active]:bg-accent data-[state=active]:text-accent-fg',
  }

  const sizes = {
    base: 'px-3 py-2 text-sm gap-2',
    sm: 'px-2.5 py-1.5 text-xs gap-1.5',
  }

  const list = $derived(lists[variant] ?? lists.underline)
  const trigger = $derived(triggers[variant] ?? triggers.underline)
  const pad = $derived(sizes[size] ?? sizes.base)
  // Both sizes use the small icon: at base the tab text is text-sm, and
  // a size-5 glyph next to it reads as an illustration rather than a mark.
</script>

<B.Root bind:value class={cn('flex flex-col gap-4', klass)} {...rest}>
  <!-- min-w-0 is not optional: without it a flex parent lets the list
       push past its own box, and then the tabs widen the whole page
       instead of the container. That was a real bug — four tabs with
       icons made the playground scroll 27 px sideways at 390 px, and axe
       says nothing about it. A component must not be able to do that.

       So the tabs wrap by default, and `scrollable` is the other way of
       containing them: one line that scrolls sideways. Both keep the
       overflow inside the component; the choice is only whether the
       tabs you cannot see are below or beside. -->
  <div class="relative min-w-0">
    <B.List
      class={cn(
        'flex items-center',
        scrollable
          ? 'flex-nowrap overflow-x-auto scroll-smooth [scrollbar-width:none] [&::-webkit-scrollbar]:hidden'
          : 'flex-wrap',
        list
      )}
    >
      {#each tabs as t (t.value)}
        <B.Trigger
          value={t.value}
          disabled={t.disabled || undefined}
          class={cn(
            'inline-flex shrink-0 items-center font-medium transition-colors',
            'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent',
            'disabled:cursor-not-allowed disabled:opacity-50',
            pad,
            trigger
          )}
        >
          {#if t.icon}<Icon icon={t.icon} size="sm" />{/if}
          {t.label}
          {#if t.badge != null}
            <!-- The count is part of the tab's accessible name, not a
                 separate stop: a screen reader reads "Orders 12", which
                 is what a sighted reader gets too. -->
            <span
              class={cn(
                'rounded-full px-1.5 py-0.5 text-[0.7em] leading-none tabular-nums',
                variant === 'pills'
                  ? 'bg-fg/10 data-[state=active]:bg-accent-fg/20'
                  : 'bg-line/70'
              )}
            >{t.badge}</span>
          {/if}
          {#if t.iconTrailing}<Icon icon={t.iconTrailing} size="sm" />{/if}
        </B.Trigger>
      {/each}
    </B.List>

    {#if scrollable}
      <!-- Fade only on the trailing edge, and only as a hint. It is
           pointer-events-none so it cannot swallow a click on the tab
           underneath it. -->
      <div
        aria-hidden="true"
        class="pointer-events-none absolute inset-y-0 right-0 w-8 bg-gradient-to-l from-surface to-transparent"
      ></div>
    {/if}
  </div>

  {@render children?.()}
</B.Root>
