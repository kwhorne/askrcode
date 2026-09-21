<script>
  import { cn } from './utils.js'

  let {
    /** horizontal | vertical */
    orientation = 'horizontal',
    /** Set when the rule separates something meaningful. Without it the
        rule is decoration, and a screen reader should not announce
        it. */
    label,
    class: klass,
    ...rest
  } = $props()
</script>

<div
  role={label ? 'separator' : 'none'}
  aria-orientation={label ? orientation : undefined}
  aria-label={label}
  class={cn(
    'bg-line shrink-0',
    orientation === 'vertical' ? 'w-px self-stretch' : 'h-px w-full',
    klass
  )}
  data-lauf="separator"
  {...rest}
></div>
