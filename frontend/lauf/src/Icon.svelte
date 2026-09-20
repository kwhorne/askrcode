<!--
  Icon — størrelse, farge og tilgjengelighet ett sted.

  Ikonet sendes inn som komponent, ikke som navn:

      import { ArrowDownTray } from '@askrcode/lauf/icons/micro'
      <Icon icon={ArrowDownTray} />

  Det er stygt sammenlignet med icon="arrow-down-tray", og det er likevel
  riktig. Et navn må slås opp i et kart, og et kart holder hele settet — 1288
  ikoner — i bunten uansett hvor få appen bruker. En import er den eneste
  formen en bundler kan følge. Premisstesten i tests/tree-shaking.test.js
  måler at den faktisk gjør det.

  Tilgjengelighet er hele grunnen til at denne komponenten finnes i stedet
  for at hvert ikon brukes direkte: et ikon uten tekst ved siden av seg må ha
  et navn, og et ikon ved siden av tekst må være usynlig for skjermleseren.
  Begge deler er lette å glemme, og ingen av dem merkes av den som bygger.
-->
<script>
  import { cn } from './utils.js'

  let {
    /** Ikonkomponenten, importert fra @askrcode/lauf/icons/<variant>. */
    icon: Glyph,
    /** sm | base | lg */
    size = 'base',
    /** Settes når ikonet står alene og må ha et navn. */
    label,
    class: klass,
    ...rest
  } = $props()

  const sizes = {
    sm: 'size-4',
    base: 'size-5',
    lg: 'size-6',
  }

  const a11y = $derived(
    label
      ? { role: 'img', 'aria-label': label, 'aria-hidden': undefined }
      : { 'aria-hidden': 'true' }
  )
</script>

{#if Glyph}
  <Glyph
    class={cn('shrink-0', sizes[size] ?? sizes.base, klass)}
    {...a11y}
    {...rest}
  />
{/if}
