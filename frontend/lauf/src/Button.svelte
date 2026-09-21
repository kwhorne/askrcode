<!--
  Button.

  Blir en <a> når href er satt, og beholder utseendet. Det er verdt en
  svelte:element fordi alternativet — en knapp som navigerer med JavaScript
  — ikke kan åpnes i ny fane, ikke kan kopieres, og sier ikke hvor den går.

  Spinneren kommer av seg selv. En knapp med type="submit" inne i et <Form>
  leser `processing` fra konteksten, så ingen trenger å koble den opp. Det
  er den koblingen som er lettest å glemme på knapp nummer to.
-->
<script>
  import { getContext } from 'svelte'
  import { cn } from './utils.js'
  import { FORM } from './context.js'
  import Icon from './Icon.svelte'
  import Spinner from './Spinner.svelte'

  let {
    /** primary | filled | outline | subtle | ghost | danger */
    variant = 'outline',
    /** sm | base | lg */
    size = 'base',
    icon,
    iconTrailing,
    /** Tvinger kvadratisk form. Settes av seg selv for et ikon uten tekst. */
    square = false,
    /** Overrides the spinner. Without it the button follows <Form>. */
    loading,
    /** Names the icon when the button is square — there is no text then. */
    label,
    type = 'button',
    href,
    disabled = false,
    children,
    class: klass,
    ...rest
  } = $props()

  const form = getContext(FORM)

  const busy = $derived(
    loading ?? (type === 'submit' && form ? form.processing : false)
  )
  const isSquare = $derived(square || (!!icon && !children))
  const tag = $derived(href ? 'a' : 'button')

  const variants = {
    primary: 'bg-accent text-accent-fg border-accent hover:opacity-90',
    filled: 'bg-fg text-surface border-fg hover:opacity-90',
    outline: 'bg-transparent text-fg border-line hover:bg-line/40',
    subtle: 'bg-line/40 text-fg border-transparent hover:bg-line/70',
    ghost: 'bg-transparent text-muted border-transparent hover:text-fg hover:bg-line/40',
    danger: 'bg-danger text-danger-fg border-danger hover:opacity-90',
  }

  const sizes = {
    sm: 'h-8 px-3 text-sm gap-1.5',
    base: 'h-9 px-4 text-sm gap-2',
    lg: 'h-11 px-5 text-base gap-2',
  }

  const squares = { sm: 'h-8 w-8 px-0', base: 'h-9 w-9 px-0', lg: 'h-11 w-11 px-0' }

  const classes = $derived(
    cn(
      'inline-flex items-center justify-center whitespace-nowrap border font-medium',
      'rounded-control transition-opacity select-none',
      'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent',
      'disabled:opacity-50 disabled:pointer-events-none aria-disabled:opacity-50',
      variants[variant] ?? variants.outline,
      isSquare ? squares[size] ?? squares.base : sizes[size] ?? sizes.base,
      klass
    )
  )
</script>

<svelte:element
  this={tag}
  {href}
  type={tag === 'button' ? type : undefined}
  class={classes}
  disabled={tag === 'button' ? disabled || busy : undefined}
  aria-disabled={tag === 'a' && (disabled || busy) ? 'true' : undefined}
  aria-busy={busy ? 'true' : undefined}
  aria-label={isSquare ? label : undefined}
  data-lauf="button"
  {...rest}
>
  {#if busy}
    <Spinner />
  {:else if icon}
    <Icon {icon} size={size === 'lg' ? 'base' : 'sm'} />
  {/if}
  {@render children?.()}
  {#if iconTrailing && !busy}
    <Icon icon={iconTrailing} size={size === 'lg' ? 'base' : 'sm'} />
  {/if}
</svelte:element>
