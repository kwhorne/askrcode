<script>
  import { cn } from './utils.js'

  let {
    /** horizontal | vertical */
    orientation = 'horizontal',
    /** Settes når streken skiller noe meningsbærende. Uten den er den pynt,
        og da skal en skjermleser ikke annonsere den. */
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
