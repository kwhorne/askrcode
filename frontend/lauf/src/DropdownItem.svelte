<script>
  import { DropdownMenu } from 'bits-ui'
  import { cn } from './utils.js'
  import { menuItem } from './overlay.js'
  import Icon from './Icon.svelte'

  let {
    icon,
    /** neutral | danger */
    variant = 'neutral',
    disabled = false,
    /** Lenke i stedet for handling. Da blir raden en <a>. */
    href,
    children,
    class: klass,
    ...rest
  } = $props()
</script>

<DropdownMenu.Item {disabled} {...rest}>
  {#snippet child({ props })}
    {#if href}
      <a {href} {...props} class={cn(menuItem, variant === 'danger' && 'text-danger', klass)}>
        {#if icon}<Icon {icon} size="sm" />{/if}
        {@render children?.()}
      </a>
    {:else}
      <div {...props} class={cn(menuItem, variant === 'danger' && 'text-danger', klass)}>
        {#if icon}<Icon {icon} size="sm" />{/if}
        {@render children?.()}
      </div>
    {/if}
  {/snippet}
</DropdownMenu.Item>
