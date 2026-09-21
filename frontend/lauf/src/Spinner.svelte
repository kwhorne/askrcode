<!-- Used by Button while a submit is in flight. Its own file because it
     should also be able to stand alone later (Skeleton, Table while
     loading). -->
<script>
  import { cn } from './utils.js'
  let { class: klass, ...rest } = $props()
</script>

<svg
  class={cn('size-4 shrink-0 animate-spin', klass)}
  viewBox="0 0 24 24"
  fill="none"
  aria-hidden="true"
  {...rest}
>
  <circle cx="12" cy="12" r="10" stroke="currentColor" stroke-width="3" opacity="0.25" />
  <path
    d="M12 2a10 10 0 0 1 10 10"
    stroke="currentColor"
    stroke-width="3"
    stroke-linecap="round"
  />
</svg>
