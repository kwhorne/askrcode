# Lauf — UI-komponenter for Askr

Arbeidsnotat. Dette er konseptet, ikke kode som finnes. Ingenting i `src/`
avhenger av noe her, og ingenting her er bygget ennå.

Askr har i dag et komplett serverlag og en Svelte-demo på fem sider der hvert
skjema er skrevet for hånd. `examples/inertia/frontend/src/pages/Customers/New.svelte`
er 66 linjer for tre felter, fordi etiketten, `for`/`id`-paret, `{#if errors.x}`
og `disabled={$form.processing}` skrives på nytt for hvert felt. Det er det
Lauf skal fjerne.

Målet er komponentdekning på nivå med [Flux UI](https://fluxui.dev/components),
bygget for Svelte 5 og Inertia, med den delen Flux ikke kan ha: felt som
kjenner skjemaet.

## Navnet

**Lauf** — løv. Urd er røttene, Askr er stammen, Norn skriver. Løvet er det
man faktisk ser. Pakken heter `@askrcode/lauf`.

Navneprinsippet i Askr er at norrønt brukes der folk sier ting høyt — `askr`,
`urd`, `norn`, `run`. «Lauf» er to stavelser og uttales likt på norsk og
engelsk.

Navnet **må** være scopet. Sjekket mot npm: det bare navnet `lauf` er opptatt
(en migrasjonskjører for TypeScript, v1.0.2), og `askr` er også opptatt.
`@askrcode/lauf` finnes ikke, og scopet `@askrcode` har null publiserte
pakker — men et tomt scope er ikke det samme som et ledig scope, så det må
registreres og bekreftes før navnet brukes noe sted.

## Hva Lauf er, og hva det ikke er

Lauf er **et komponentbibliotek for frontend**, distribuert over npm, som en
Askr-app installerer på samme måte som den installerer `@inertiajs/svelte`.

Lauf er **ikke** en del av rammeverksbinæren, og det er det viktigste å holde
fast ved. Askrs løfte er én binærfil uten sidevogn. Det løftet handler om
serveren. Nettleseren har alltid hatt npm, Vite og Svelte i denne stakken, og
Lauf gjør ikke den situasjonen verre. Men grensen må stå skrevet, for den er
lett å viske ut:

* **Ingenting i `src/` får avhenge av Lauf.** Samme regel som for `Askr.Run`.
* **Velkomstsiden og auth-stillaset blir liggende som ren HTML.** De virker i
  dag uten npm, uten nett og uten filer ved siden av binæren, og det er en
  testet egenskap, ikke en tilfeldighet. Et nytt prosjekt skal kunne logge inn
  før `npm install` er kjørt.
* En app som ikke bruker Inertia skal ikke merke at Lauf finnes.

Senere kan `askr make auth --lauf` generere Inertia-sider i stedet for HTML.
Det er et tillegg, ikke en erstatning.

## Forholdet til Flux

Flux er **et kommersielt produkt**. Prissiden oppgir tre betalte nivåer —
149, 299 og 799 dollar — og snakker om «23+ Pro components». Det finnes altså
et gratis sett og et betalt sett, men hvilke komponenter som ligger hvor, sto
ikke på den siden, og det bør sjekkes før noen skriver noe om det utad.

Det praktiske: **vi tar formen, ikke koden.**

Vi ser på Flux for å bestemme *hvilke* komponenter som trengs og *hvordan
API-et bør føles* — at `variant`, `size` og `icon` er props, at
`Button.Group` finnes, at `Field` binder etikett, input og feilmelding
sammen. Det er produktbeslutninger, og de er verdt å låne.

Vi kopierer **ikke** Flux' kildekode, markup eller CSS, og ingen som jobber
på Lauf skal åpne betalt Flux-kildekode og skrive av. Det er ikke en gråsone
å balansere i; det er en linje å holde seg på riktig side av. Alt i Lauf
skrives fra bunnen mot Bits UI og Tailwind.

Vi kaller det heller ikke «en Flux-klone» utad. Det er både juridisk uklokt
og faktisk feil — Form- og Field-delen er en annen ting enn Flux' versjon,
fordi den henger på Inertia og Norn.

## Tre lag

Dette er den arkitekturbeslutningen som avgjør om prosjektet blir ferdig. De
fleste komponentbibliotek stopper på at de femten vanskeligste komponentene
aldri blir gode nok, og grunnen er alltid den samme: de ble bygget som femti
likestilte komponenter i stedet for som tre lag.

### Lag 1 — tokens

Tailwind v4 `@theme`. Farge, radius, avstand, skygge, typografi. Alt annet
konsumerer disse, og ingen komponent skriver en farge direkte.

**Tokenene er semantiske, ikke bokstavelige.** `--color-surface`,
`--color-fg`, `--color-muted`, `--color-line`, `--color-accent` — ikke
`--color-zinc-800`. Det er samme form som `examples/inertia/frontend/src/app.css`
allerede bruker, og grunnen er mørk modus:

```css
@import "tailwindcss";

@theme {
  --color-surface:  #fbfaf8;
  --color-fg:       #23201c;
  --color-muted:    #6f675d;
  --color-line:     #e6e0d8;
  --color-accent:   #7a5c3e;
  --radius-control: 0.375rem;
}

/* Mørk modus i tre tilstander. Nettleserens valg gjelder når brukeren ikke
   har valgt selv; et eksplisitt valg slår operativsystemet begge veier. */
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --color-surface: #17150f;
    --color-fg:      #ece5da;
    --color-muted:   #a39887;
    --color-line:    #2f2a21;
    --color-accent:  #c9a274;
  }
}
:root[data-theme="dark"] {
  --color-surface: #17150f;
  /* … samme sett … */
}
```

**Komponentene skriver aldri `dark:`.** Det er en beslutning som går mot
hvordan Flux selv gjør det, og den er bevisst. Skriver hver komponent
`bg-white dark:bg-zinc-900`, ligger mørk modus spredt over femti filer, og en
app som vil ha sitt eget fargesett må endre alle sammen. Ligger den i
tokenene, er hele temaet ett `@theme`-blokk å bytte, og en komponent har ett
sett klasser i stedet for to.

Prisen er at en komponent som trenger *strukturelt* forskjellig behandling i
mørk modus — en skygge som blir til en kantlinje, for eksempel — må uttrykke
det som et eget token. Det er den riktige prisen å betale, og det er få
tilfeller.

### Lag 2 — oppførsel

**Bits UI.** MIT, Svelte 5 (`peerDependencies: svelte ^5.33.0`), 45+
headless primitiver. Verifisert mot npm: versjon 2.19.2.

Dette er stedet å ta en avhengighet, og det bør gjøres uten dårlig samvittighet.
De femten vanskeligste komponentene er vanskelige av grunner som ikke har noe
med Askr å gjøre:

fokusfelle og fokusgjenoppretting, roving tabindex, `aria-activedescendant`,
typeahead i lister, lag som lukkes i riktig rekkefølge, flytende posisjonering
med kollisjonsdeteksjon, rullelås som ikke hopper på iOS, portaler, høyre-mot-
venstre-tekst, berøring mot mus, og skjermleseroppførsel som bare kan
verifiseres ved å faktisk kjøre en skjermleser.

Å skrive det selv er et flerårig tilgjengelighetsprosjekt, og å skrive det
dårlig er verre enn å la være — en modal som ikke holder på fokus ser riktig
ut for den som bygde den og er ubrukelig for den som trenger den.

Bits UI er dessuten *headless*: den styler ingenting. Den løser altså akkurat
den delen vi ikke vil eie, og legger ingen føringer på den delen vi vil eie.

Det som må stå klart: **avhengigheten er reell.** Blir Bits UI forlatt, er det
Lauf som må ta over. Det som demper risikoen er at den er MIT, at den er
headless — så en erstatning kan byttes inn under Lag 3 uten at
app-koden merker det — og at Lag 3 skal være skrevet slik at Bits UI aldri
lekker ut i det offentlige API-et. Ingen app skal importere fra `bits-ui`.

En detalj: Bits UI har `@internationalized/date` (Apache-2.0) som peer
dependency. Den trengs bare for dato- og kalenderkomponentene, altså bolk 3.
Bolk 1 og 2 slipper unna med `bits-ui` alene.

Uten Lag 2 bygger man femti komponenter der de femten vanskeligste aldri blir
ferdige. Det er hele grunnen til at laget finnes.

### Lag 3 — Lauf

Våre stylede komponenter oppå Lag 2. Det er her API-et blir til.

## API-oversettelsen

Flux er Blade og bruker punktnotasjon: `<flux:button.group>`. Svelte 5 har
ikke det, men sammensatt eksport gir samme følelse:

```svelte
<script>
  import { Button } from '@askrcode/lauf';
</script>

<Button variant="primary" icon="arrow-down-tray">Export</Button>

<Button.Group>
  <Button>Oldest</Button>
  <Button>Newest</Button>
</Button.Group>
```

Selve komponenten:

```svelte
<script lang="ts">
  import { cn } from '../utils';
  import Icon from '../Icon.svelte';
  import type { ButtonProps } from './types';

  let {
    variant = 'outline',
    size = 'base',
    icon,
    iconTrailing,
    square = false,
    loading = false,
    href,
    children,
    class: klass,
    ...rest
  }: ButtonProps = $props();

  const tag = $derived(href ? 'a' : 'button');
  const isSquare = $derived(square || (!!icon && !children));
</script>

<svelte:element this={tag} {href}
  class={cn(base, variants[variant], sizes[size], isSquare && 'aspect-square', klass)}
  disabled={tag === 'button' && loading}
  aria-busy={loading || undefined}
  data-lauf-button
  {...rest}>
  {#if icon}<Icon name={icon} variant="micro" />{/if}
  {@render children?.()}
  {#if iconTrailing}<Icon name={iconTrailing} variant="micro" />{/if}
</svelte:element>
```

Fire ting å merke seg, og de gjelder hele biblioteket:

* Flux skriver `icon:trailing`. Kolon er ulovlig i JS-props, så det blir
  `iconTrailing`. Den slags oversettelser skal gjøres én gang og skrives ned,
  ikke oppfinnes per komponent.
* Slots er snippets i Svelte 5. `{@render children?.()}`, ikke `<slot />`.
* **`cn()` er ikke valgfri.** Den er `clsx` + `tailwind-merge` (begge MIT), og
  uten den vinner ikke brukerens `class="w-full"` over komponentens egen
  `w-auto` — Tailwind-klasser har lik spesifisitet, så det er
  rekkefølgen i stilarket som avgjør, ikke rekkefølgen i attributtet. Det er
  den enkeltfeilen som gjør et Tailwind-komponentbibliotek ubrukelig, og den
  ser ut som en tilfeldighet når man treffer den.
* `{...rest}` sist, slik at en app kan sende `data-testid`, `aria-label` og
  `onclick` uten at komponenten trenger å kjenne dem.

## Det bare Askr kan gjøre

Flux' loading-magi kommer av at Livewire vet når en request pågår. Askr vet
det samme gjennom Inertia — og kan gå lenger, fordi Norn allerede leser
skjemaet.

### Form og Field

```svelte
<Form action="/customers" method="post">
  <Field name="email" label="Email">
    <Input type="email" />
  </Field>

  <Button type="submit" variant="primary">Save</Button>
</Form>
```

Tre ting skjer uten at noe kobles opp for hånd: `Field` henter feilmeldingen
for `email` fra Inertias `errors`-prop gjennom context, `Input` får riktig
`id`, `aria-describedby` og `aria-invalid`, og `Button type="submit"` viser
spinner så lenge `processing` er sant.

Dette er der biblioteket tjener seg inn. Sammenlign med `New.svelte` i dag:
tre felter, tre `{#if errors.x}`, tre `<label for>` som må stemme med tre
`id`, og én `disabled={$form.processing}` som er lett å glemme på den fjerde
knappen noen legger til.

`Form` er et tynt lag over `useForm` fra `@inertiajs/svelte`, ikke en
erstatning for den. En app som vil ha `$form` direkte skal kunne få den.

### Norn → TypeScript

`Askr.Norn.Codegen` sier dette i dag, i sitt eget filhode:

> PRD-en peker på manifestet som grunnlaget for tre analyser: advarsel ved
> Where mot kolonne uten indeks, N+1 i en løkke, og **Inertia-felt som ikke
> finnes**. Ingen av dem kan håndheves ved kompilering i Free Pascal, fordi
> språket ikke har comptime.

Den tredje er ikke lenger sann hvis feltet sjekkes i frontend. Pascal kan ikke
håndheve det, men `tsc` kan — og Vite kjører allerede i utviklerløkka.

Introspeksjonen har alt som trengs: `TDbColumn` bærer `Name`, `SqlType`,
`Nullable`, `MaxLength` og `IsPrimaryKey`, og `TDbTable` har fremmednøkler og
indekser. `GenerateSources` bygger i dag Pascal-kilde i minnet og
`WriteSources` skriver bare det som er endret. Et ekstra utdataformat er en
ny funksjon ved siden av dem, ikke en omskriving:

```ts
// frontend/src/schema.d.ts — generert av askr schema. Rediger ikke.
export interface CustomerRow {
  id: number
  name: string
  email: string
  balance: number
  active: boolean
  created_at: string
  deleted_at: string | null
}
export type CustomerField = keyof CustomerRow
```

```svelte
<Field name="epost">   <!-- Type error: 'epost' is not a CustomerField -->
```

Det er samme idé som typede spørringer, ført ut i UI-laget, og den er
begrunnet i PRD-en fra før.

Tre ting som må være riktige, og som er lette å ta feil av:

* **Generikk flyter ikke gjennom context i Svelte.** `<Form>` kan ikke gi
  `<Field>` sin typeparameter via `setContext`. Den formen som faktisk
  typesjekker er en fabrikk: `const { Form, Field } = formFor<CustomerRow>()`.
  Litt mindre pent enn Flux' punktnotasjon, men det er forskjellen på at det
  virker og at det ser ut som det virker.
* **`bigint` blir `number`.** Askr skriver Int64 som JSON-tall, og JS mister
  presisjon over 2^53. Det er greit for id-er til ni billiarder, og det skal
  stå i generert fil at det er valget som er tatt.
* **Penger er allerede et tall.** `TJsonWriter.Money` formaterer Currency for
  hånd til et usitert JSON-tall, nettopp for at et norsk desimalkomma ikke
  skal havne i JSON. Så `balance: number`, og `Table` formaterer med
  `Intl.NumberFormat` ved visning.

### Det vi **ikke** genererer

**Ikke valideringsreglene.** Urd-validatoren kjenner `Required`, `MinLen`,
`OneOf`, `SameAs` og resten, og fristelsen er åpenbar: send dem til klienten
og valider før requesten går.

La være. Serveren er fasit, og den må validere uansett — en klientvalidering
i tillegg er den samme regelen skrevet to steder, og de to driver fra
hverandre i det øyeblikket noen legger til en regel som ikke lar seg uttrykke
i JavaScript. Inertia-rundturen er dessuten rask nok. Det vi *kan* projisere
uten å duplisere logikk, er kolonnedefinisjonen: `required` og `maxlength` som
HTML-attributter fra `Nullable` og `MaxLength`. Det er ikke en regel skrevet
på nytt, det er den samme opplysningen brukt to steder.

## Ikoner

Flux bruker Heroicons i fire varianter. Det kan vi også — Heroicons er MIT
(verifisert: `heroicons` 2.2.0). Flux anbefaler selv Lucide når Heroicons
blir for lite, og Lucide er ISC (`lucide-static` 1.47.0).

**Generer Svelte-komponenter fra SVG-kilden ved bygging, én fil per ikon.**
Hele settet lastet på én gang er 300+ kB, og en `<Icon name="...">` som slår
opp i et kart holder hele kartet i bunten uansett hva som brukes. Én fil per
ikon er det som gjør at tree-shaking faktisk virker.

`<Icon name="arrow-down-tray">` med dynamisk navn kan da ikke slå opp i et
kart. Løsningen er at `Icon` tar en importert komponent når man vil ha
tree-shaking, og at navnevarianten finnes for det som er kjent på forhånd.
Det er en avveining som må avgjøres når `Icon` skrives, ikke her — men den må
avgjøres bevisst, for den avgjør buntstørrelsen for hele biblioteket.

En `askr lauf:icon <navn>`-kommando som henter ett Lucide-ikon inn i
prosjektet er samme grep som Flux' egen artisan-kommando, og den er billig å
lage.

## Hvor koden bor

**I dette repoet**, under `frontend/lauf/`, publisert til npm derfra.

Grunnen er at TypeScript-genereringen lever i `Askr.Norn.Codegen`, og de to
må følge hverandre. Ligger de i hvert sitt repo, får vi en versjonsmatrise
mellom Pascal-siden og npm-siden, og den typen matrise er alltid feil i minst
én rute.

Prisen er at `./askr test` da møter et npm-prosjekt. Det løses som
GTK-testene allerede løses: **Lauf-suiten hopper over seg selv når `node`
ikke finnes**, og `./askr lauf` kjører den ekte. Et hopp som sier hvorfor,
ikke et hopp i stillhet.

## Byggerekkefølge

Flux har rundt femti komponenter. Man trenger ikke alle for å ha noe brukbart.

### Bolk 0 — infrastruktur

Pakken, tokenene, `cn()`, `Icon` med generering fra SVG, testoppsettet og
`./askr lauf`. Ingen synlige komponenter.

Dette er en egen bolk fordi man ikke kan skrive `Button` før `cn()` og
tokennavnene er bestemt — gjør man det motsatt, skrives `Button` to ganger.

### Bolk 1 — gjør en CRUD-app mulig

`Button`, `Input`, `Textarea`, `Select`, `Checkbox`, `Radio`, `Switch`,
`Field`, `Form`, `Heading`, `Text`, `Badge`, `Card`, `Separator`, `Table`,
`Pagination`.

Seksten komponenter, og de er alle enkle. `Select` er den eneste som strengt
tatt trenger Bits UI, og den kan starte som en stylet `<select>`.

Målet på at bolken er ferdig: **`examples/inertia` skrives om i Lauf**, og
`New.svelte` blir kortere enn tjue linjer uten at noe forsvinner —
feilmeldinger, `aria-invalid` og spinner skal fortsatt være der.

### Bolk 2 — gjør appen behagelig

`Modal`, `Dropdown`, `Tooltip`, `Toast`, `Tabs`, `Avatar`, `Callout`,
`Breadcrumbs`, `Navbar`, `Sidebar`, `Skeleton`, `Accordion`, `Popover`.

Her tjener Bits UI seg inn. Dette er også bolken der
tilgjengelighetsgaten under må være på plass før noe kalles ferdig.

### Bolk 3 — de dyre

`Command`, `Autocomplete`, `Date picker`, `Calendar`, `Slider`, `File upload`,
`OTP input`, `Progress`, `Color picker`.

Her er det riktig å spørre om det er verdt det, komponent for komponent.
`File upload` er den som har mest støtte i Askr fra før — multipart-parseren
er på plass, og `StoreIn` gjør det trygge valget — så den er billigere enn
den ser ut.

## Hva vi ikke bygger

* **Editor.** En rik-tekst-editor er et eget produkt. Om noen trenger en, er
  svaret TipTap eller ProseMirror, ikke vår egen.
* **Kanban.** Samme sak, pluss dra-og-slipp med tastaturstøtte, som er like
  vanskelig som hele bolk 2 til sammen.
* **Chart.** Det finnes gode biblioteker, og et diagram er ikke en
  UI-komponent på samme måte som en knapp er det.
* **Klientvalidering.** Begrunnet over.
* **Et temabygger-verktøy.** Tokenene er ett CSS-blokk. Et verktøy for å
  redigere ett CSS-blokk er seremoni.

Det skal stå i dokumentasjonen hva som ikke finnes og hvorfor, slik hver
`docs/`-side allerede gjør. Den delen skal oppdateres når noe blir bygget,
ikke slettes.

## Hva som må være sant før noe kalles ferdig

Halvparten av disse komponentene har tilgjengelighet som selve leveransen. Da
må det finnes en port, ikke en god intensjon.

* **`axe-core` mot hver komponent i hver tilstand.** Vitest og
  `@testing-library/svelte`. En `Field` uten kobling mellom label og input er
  en feil, ikke en detalj.
* **Tastaturgjennomgang for alt i bolk 2.** Åpne, navigere, lukke, og fokus
  tilbake dit det kom fra — uten mus. Skrives som test, ikke som sjekkliste.
* **Premisstest på bunten:** en side som importerer `Button` og ett ikon skal
  gi en bunt med ett ikon i, ikke tre hundre. Tallet måles og holdes, på samme
  måte som `BytesReserved` holdes flat i arena-testene. Ryker den, er
  tree-shaking brutt, og det merkes ellers ikke før noen klager på
  lastetiden.
* **Skjermdump i lys og mørk modus, på 390 px og på skrivebord.** Headless
  Chrome klemmer viewporten til rundt 500 px, så den smale varianten må inn i
  en `<iframe width="390">` — samme knep som velkomstsiden allerede bruker.

## Åpne spørsmål

1. **npm-scopet `@askrcode` må registreres.** Ingen pakker er publisert under
   det i dag, men det er ikke bevis på at det er ledig.
2. **Fri eller betalt?** Flux tar 149–799 dollar. Lauf kan være MIT som
   resten av Askr, og det er det svaret som passer et rammeverk som vil bli
   brukt. Men det bør være et valg noen tar bevisst, ikke noe som skjer.
3. **`Icon` med navn kontra importert komponent.** Avgjør buntstørrelsen for
   hele biblioteket. Må bestemmes i bolk 0.
4. **Skal `askr new` installere Lauf som standard?** Argumentet for er at et
   nytt prosjekt da ser bra ut med én gang. Argumentet mot er at malene i
   `askr new` med vilje er små, og at et stillas som genererer femten filer
   man ikke forstår er verre enn ingen stillas.

## En feil som ble rettet på veien

`src/inertia/Askr.Inertia.pas` lukket ut flash-meldinger:

```pascal
if (Length(GFlashKeys) > 0) or
   ((Sess <> nil) and (Sess.HasFlash('suksess') or Sess.HasErrors)) then
```

`WriteFlashInto` skriver *alle* flash-nøkler unntatt `_errors`, men vakten
over åpnet bare `flash`-objektet når sesjonen hadde en nøkkel som het
bokstavelig talt `suksess`. En app som gjorde `Session.Flash('error', …)` —
slik den genererte auth-kontrolleren gjør — fikk meldingen stille forkastet
fra Inertia-payloaden.

`TSession` har nå `HasAnyFlash`, som svarer på det samme utvalget
`WriteFlashInto` skriver, og vakten bruker den. Det måtte være på plass før
`Toast` og `Callout` i bolk 2 gir mening, for det er nettopp den propen de
leser.
