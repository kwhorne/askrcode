<!--
  Pagination.

  Tar `page`, `perPage` og `total`, ikke et ferdig sideobjekt. Askrs
  `TQuery.Paginate` returnerer bare radene — den teller ikke — så et
  sideobjekt her ville lovet noe datalaget ikke leverer. Appen vet totalen
  fra sin egen `Count`, og sender den inn.

  `href` er en funksjon fra sidetall til adresse. Da blir hver side en ekte
  lenke som kan åpnes i ny fane og kopieres. Uten `href` blir knappene
  knapper, og `onnavigate` kalles i stedet.
-->
<script>
  import { cn } from './utils.js'
  import Button from './Button.svelte'
  import { ChevronLeft, ChevronRight } from './icons/micro/index.js'

  import { strings, numbers } from './strings.js'
  const word = strings()
  const n = numbers()

  let {
    page = 1,
    perPage = 25,
    total = 0,
    /** (n) => string */
    href,
    /** (n) => void, brukes når href mangler */
    onnavigate,
    /** Aria-etikett på navigasjonen. Flere pagineringer på samme side må
        skilles fra hverandre for den som hopper mellom landemerker. */
    label = word('pagination'),
    class: klass,
    ...rest
  } = $props()

  const pages = $derived(Math.max(1, Math.ceil(total / Math.max(1, perPage))))
  const current = $derived(Math.min(Math.max(1, page), pages))
  const from = $derived(total === 0 ? 0 : (current - 1) * perPage + 1)
  const to = $derived(Math.min(current * perPage, total))

  function go(n) {
    if (n < 1 || n > pages || n === current) return
    if (!href && onnavigate) onnavigate(n)
  }
</script>

<nav
  aria-label={label}
  class={cn('flex items-center justify-between gap-4 flex-wrap', klass)}
  data-lauf="pagination"
  {...rest}
>
  <p class="text-xs text-muted tabular-nums">
    {#if total === 0}
      {word('no_results')}
    {:else}
      {word('range_of', { from: n(from), to: n(to), total: n(total) })}
    {/if}
  </p>

  <div class="flex items-center gap-2">
    <Button
      size="sm"
      icon={ChevronLeft}
      label={word('previous_page')}
      href={href && current > 1 ? href(current - 1) : undefined}
      disabled={current <= 1}
      onclick={href ? undefined : () => go(current - 1)}
    />
    <!-- Sidetallet er en tekst og ikke en liste med lenker. En liste over
         femti sider er femti tabulatorstopp for å komme forbi den, og
         ingen leter etter side 37. -->
    <span class="text-xs text-muted tabular-nums" aria-current="page">
      {n(current)} / {n(pages)}
    </span>
    <Button
      size="sm"
      icon={ChevronRight}
      label={word('next_page')}
      href={href && current < pages ? href(current + 1) : undefined}
      disabled={current >= pages}
      onclick={href ? undefined : () => go(current + 1)}
    />
  </div>
</nav>
