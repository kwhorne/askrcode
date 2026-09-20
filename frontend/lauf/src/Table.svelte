<!-- Tabellen ligger i en egen rulleboks.
     En tabell har en minstebredde som følger av innholdet, og uten boksen
     er det hele siden som blir bredere enn en telefonskjerm i stedet for
     tabellen. Det er den samme grunnen til at avlesningen på velkomstsiden
     er en <dl> og ikke en <table>. -->
<script>
  import { cn } from './utils.js'
  let { caption, children, class: klass, ...rest } = $props()
</script>

<div class="w-full overflow-x-auto">
  <table class={cn('w-full border-collapse text-sm', klass)} data-lauf="table" {...rest}>
    {#if caption}
      <caption class="sr-only">{caption}</caption>
    {/if}
    {@render children?.()}
  </table>
</div>
