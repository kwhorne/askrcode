<!-- A message that belongs to the page rather than to a field.
     Colour is not the only information: each variant has its own icon,
     and a variant that reports something wrong gets role="alert" so it is
     read out when it appears. -->
<script>
  import { cn } from './utils.js'
  import Icon from './Icon.svelte'
  import {
    InformationCircle,
    CheckCircle,
    ExclamationTriangle,
    XCircle,
  } from './icons/micro/index.js'

  let {
    /** info | success | warning | danger */
    variant = 'info',
    title,
    children,
    class: klass,
    ...rest
  } = $props()

  const variants = {
    info: { cls: 'border-line bg-line/30 text-fg', icon: InformationCircle, live: false },
    success: { cls: 'border-accent/40 bg-accent/10 text-fg', icon: CheckCircle, live: false },
    warning: { cls: 'border-accent/50 bg-accent/15 text-fg', icon: ExclamationTriangle, live: true },
    danger: { cls: 'border-danger/40 bg-danger/10 text-fg', icon: XCircle, live: true },
  }

  const v = $derived(variants[variant] ?? variants.info)
</script>

<div
  role={v.live ? 'alert' : undefined}
  class={cn('flex gap-3 rounded-surface border p-3 text-sm', v.cls, klass)}
  data-lauf="callout"
  {...rest}
>
  <Icon icon={v.icon} size="sm" class="mt-0.5 shrink-0" />
  <div class="flex flex-col gap-1">
    {#if title}<p class="font-semibold">{title}</p>{/if}
    {#if children}<div class="text-muted">{@render children()}</div>{/if}
  </div>
</div>
