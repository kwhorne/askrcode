# Lauf — UI-komponenter for Askr

Arbeidsnotat. **Alle fire bolkene er bygget** og ligger i `frontend/lauf/`.
`examples/inertia` bruker dem, og `./askr lauf:play` viser resten i en ekte
nettleser. Én komponent fra bolk 3 ble bevisst ikke bygget — se under.
Ingenting i `src/` avhenger av noe her, og det skal det aldri gjøre.

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

**Lauf er frontendlaget i Askr**, slik Urd er datalaget. `askr new` setter
det opp, og demosiden i et nytt prosjekt er skrevet i det. Det er ikke en
valgfri pakke ved siden av.

Lauf er likevel **ikke en del av rammeverksbinæren**, og det er forskjellen
som må holdes fast. Askrs løfte er én binærfil uten sidevogn. Det løftet
handler om serveren. Nettleseren har alltid hatt npm, Vite og Svelte i denne
stakken, og Lauf gjør ikke den situasjonen verre. Men grensen må stå
skrevet, for den er lett å viske ut:

* **Ingenting i `src/` får avhenge av Lauf.** Samme regel som for `Askr.Run`.
* **Velkomstsiden og auth-stillaset blir liggende som ren HTML.** De virker
  uten npm, uten nett og uten filer ved siden av binæren, og det er en testet
  egenskap, ikke en tilfeldighet. Et nytt prosjekt skal svare på `/` og kunne
  logge inn før `npm install` er kjørt. Prøvd på nytt etter at Lauf ble
  frontendlaget: `askr new` + `askr build`, ingen npm, `/` svarer 200 uten en
  eneste ekstern ressurs.
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
  import { ArrowDownTray } from '@askrcode/lauf/icons/micro';
</script>

<Button variant="primary" icon={ArrowDownTray}>Export</Button>

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
* **`icon` tar en komponent, ikke et navn.** Flux skriver
  `icon="arrow-down-tray"`, og det var også det denne fila skrev først.
  Bolk 0 avgjorde det motsatt, og begrunnelsen står under.
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

**Avgjort i bolk 0: `Icon` tar en komponent, ikke et navn.** Et navn må slås
opp i et kart, og et kart holder hele settet i bunten uansett hvor få appen
bruker. En import er den eneste formen en bundler kan følge. Tallene, målt
minifisert uten gzip:

| | |
|---|---|
| Svelte-runtime alene | 34,5 kB |
| `cn()` (clsx 0,4 + tailwind-merge 27,5) | 27,9 kB |
| ett ikon via barrel-fila | 29,5 kB (mest runtime) |
| hele micro-settet, 316 ikoner | 225,9 kB |

Ergonomien er dårligere enn Flux', og det er prisen. Premisstesten
`tests/tree-shaking.test.js` bygger en app som bruker ett ikon og slår fast
at naboen i den samme barrel-fila ikke er med i utdataet.

**De genererte ikonene sjekkes ikke inn.** Det er et avvik fra Norn, som
sjekker generert kode inn, og avviket har en grunn: Norns filer er typet
Pascal som må kompilere sammen med appen, mens dette er en mekanisk kopi av
en MIT-avhengighet som allerede ligger i `node_modules`. 1288 filer i git
ville gjort enhver diff uleselig. `npm run icons` kjøres av `prepare`, og
`./askr lauf` lager dem hvis de mangler.

**`cn()` koster 28 kB i enhver app**, nesten alt `tailwind-merge`. Det er
prisen for at `class` virker slik man tror, og den skal stå skrevet i stedet
for å oppdages.

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

### Bolk 0 — infrastruktur — **ferdig**

Pakken, tokenene, `cn()`, `Icon` med generering fra SVG, testoppsettet og
`./askr lauf`. Ingen synlige komponenter.

Dette er en egen bolk fordi man ikke kan skrive `Button` før `cn()` og
tokennavnene er bestemt — gjør man det motsatt, skrives `Button` to ganger.

Ligger i `frontend/lauf/`. 15 tester: `cn()`, `Icon` med axe i begge
tilstander, og premisstesten på bunten. Porten er `./askr lauf`, som hopper
over seg selv når `node` mangler — samme form som desktop-suiten uten GTK, og
grunnen er den samme: `./askr test` skal ikke kreve npm for å være grønn.

Avgjørelsene bolken måtte ta, og som resten bygger på: semantiske tokens uten
`dark:` i komponentene, `cn()` på alt, ikoner som komponenter, og pakken
publisert som kildekode slik at konsumentens Vite kompilerer den. Det siste
sparer et byggsteg og gjør tree-shaking lettere å resonnere om.

**Én felle er verdt å huske:** `vite.build()` laster `vite.config.js` av seg
selv. Bygger man noe programmatisk fra en test og også sender inn
`plugins: [svelte()]`, kjører pluginen to ganger, og den andre runden får
kompilert JS inn der den venter Svelte-kilde. Feilen kommer ut som
«Expected token }» i en tilfeldig komponent som varierer mellom kjøringer, og
peker ingen vei. `configFile: false`.

### Bolk 1 — gjør en CRUD-app mulig — **ferdig**

`Button`, `Input`, `Textarea`, `Select`, `Checkbox`, `Radio`, `Switch`,
`Field`, `Form`, `Heading`, `Text`, `Badge`, `Card`, `Separator`, `Table`,
`Pagination`.

Seksten komponenter, og de er alle enkle. `Select` ble en stylet `<select>`
— den innebygde er den eneste som virker med tastatur, skjermleser og
berøring uten at vi skriver den selv, og en egen liste hører hjemme i bolk 2
med Bits UI under seg.

Målet var at **`examples/inertia` skrives om i Lauf**, og at `New.svelte`
blir kortere enn tjue linjer uten at noe forsvinner. Den er nå **19 linjer,
fra 66**, og `<style>`-blokka på 22 linjer er borte helt — tokenene gjør den
jobben. Feilmeldingene, `aria-invalid` og spinneren er der fortsatt, og er
verifisert i en ekte nettleser: POST går ut, serveren svarer
«name is required», meldingen dukker opp som `role="alert"`, navnefeltet får
`aria-invalid="true"` og `aria-describedby` som peker på den, e-postfeltet
er urørt og beholder verdien sin, og knappen slippes igjen.

78 tester i `./askr lauf`.

**`Form` ligger bak `@askrcode/lauf/inertia`**, ikke i hovedinngangen. Den er
den eneste komponenten som importerer Inertia, og ESM løser den importen ved
bygging — lå den i `index.js`, måtte enhver app som vil ha en knapp også ha
Inertia installert.

**`Form` er et lag over `router`, ikke over `useForm`.** Det er et avvik fra
det denne fila skrev først, og grunnen er reaktivitet: verdiene må kunne
leses og skrives fra en annen komponent gjennom konteksten, og da er `$state`
noe vi kontrollerer mens en store fra adapteren er noe vi håper på.
`useForm` står fortsatt åpen — `Notes/Index.svelte` i demoen bruker den, med
`error` som prop og `bind:value`, nettopp for at den veien skal være dekket.

Tre feller fra denne bolken, alle skrevet ned i CLAUDE.md:

* **`router[verb](...)`, ikke `const f = router[verb]; f(...)`.** Inertias
  metoder kaller `this.visit()`, så en løsrevet referanse gir
  «Cannot read properties of undefined (reading 'visit')» — en feilmelding
  som ikke nevner mottakeren med et ord. Enhetstesten slapp den gjennom
  fordi mocken var frie funksjoner; den bruker nå `this`, og er
  mutasjonssjekket mot nettopp denne feilen.
* **En app som bruker Lauf fra en symlink må dedupe** `svelte`,
  `@inertiajs/svelte` og `@inertiajs/core`. Uten det får appen og Lauf hver
  sin kopi, og `createInertiaApp` setter opp en annen router enn den `Form`
  importerer. Dedupe kuttet dessuten demoens bunt fra 300 kB til 218 kB.
* **`<Input type="email">` gjør at nettleseren nekter å sende i det hele
  tatt** ved en ugyldig adresse, så serverens e-postregel aldri kjører. Det
  er riktig HTML-oppførsel, men det er verdt å vite at de to
  valideringene ikke er enige om når de gjelder.

### Bolk 2 — gjør appen behagelig — **ferdig**

`Modal`, `Dropdown`, `Tooltip`, `Toast`, `Tabs`, `Avatar`, `Callout`,
`Breadcrumbs`, `Navbar`, `Sidebar`, `Skeleton`, `Accordion`, `Popover`.

Her tjente Bits UI seg inn, og den gjorde det med en gang. Fokusfelle,
fokus tilbake til utløseren, roving tabindex, typeahead, rekkefølgen lag
lukkes i, flytende plassering med kollisjonsdeteksjon og rullelås virket
fra første forsøk. 124 tester i `./askr lauf`.

**Verifisert i en ekte nettleser**, fordi jsdom ikke legger ut noe og
derfor ikke kan bevise noe av det: meny åpnet med Enter, fokus inn i
menyen, ArrowDown uthever, Escape lukker og gir fokus tilbake til
utløseren. Modal åpnet med fokus inni, `overflow: hidden` på body, **tolv
Tab-trykk uten at fokus forlot dialogen én eneste gang**, Escape lukker og
rullelåsen løftes. Og hele flash-kjeden: `InertiaFlash('success', …)` i
Pascal, gjennom Inertias event, til en toast i det høflige live-området.

**Bits setter ikke `aria-controls` på trekkspill**, selv om den gjør det på
faner. Det er en luke mot WAI-ARIAs eget mønster, og `AccordionItem` lager
id-en selv og kobler begge veier. Det er nettopp det lag 3 er til for: Bits
eier oppførselen, vi eier at den er komplett.

**Overskriften i en meny må ligge inne i gruppa den navngir.** Bits kaster
hvis den ikke gjør det, og den har rett — en overskrift som ikke er koblet
til noe er bare tekst midt i en meny. API-et ble `Dropdown.Group label=…`
i stedet for en løs `Dropdown.Heading`.

**Trekkspillets overskrift er et ekte `<h3>`**, ikke Bits' `<div
role="heading">`. Begge er riktige for en skjermleser, men et element
holder også der ARIA ikke gjør det — lesemodus, utskrift, verktøy som
leser strukturen uten å kjøre JavaScript. `child`-snippeten gjør det mulig.

**Den dyreste feilen var i pakkingen, ikke i koden.** Bolk 2 la Bits under
sju komponenter, og plutselig kostet en enkelt `<Button>` 221 kB i stedet
for 74 — hele Bits fulgte med. Årsaken er `Object.assign` på modulnivå,
som er måten `Button.Group` og `Table.Cell` henges på: en bundler kan ikke
bevise at et kall som muterer sitt første argument er trygt å fjerne, så
barrel-fila holdt hele biblioteket i live. `/*#__PURE__*/` på de
sammensatte eksportene er fiksen, og `"sideEffects"` i package.json er den
andre halvdelen. **Premisstesten fanget det**, og den sjekker nå også at
ingen Bits-kode finnes i en bunt som bare bruker et ikon.

### Bolk 3 — de dyre — **ferdig, minus én**

`Command`, `Autocomplete`, `DatePicker`, `Slider`, `FileUpload`,
`OtpInput`, `Progress`. **Ikke** fargevelger.

Her sa denne fila at man skal spørre om det er verdt det, komponent for
komponent. Svaret ble ja på sju og nei på én.

**Fargevelgeren droppes.** Bits har ingen primitiv, så den måtte skrives
fra bunnen: en flate for kulør og metning som lar seg styre med tastatur,
konvertering mellom fargerom, og kontrastavlesning. Det er et eget prosjekt.
Nesten ingen CRUD-app trenger en, og de som gjør det vil ha en ordentlig.

**Prisen per komponent er målt**, og det er det som gjør at de dyre kunne
bli med i det hele tatt: med tree-shaking bevist er en dyr komponent et
valg appen tar, ikke en avgift alle betaler. Minifisert, montert, uten
gzip — gulvet er Svelte-runtime pluss `cn`:

| | |
|---|---|
| `Button` (gulvet) | 75 kB |
| `Progress` | 81 kB |
| `FileUpload` | 84 kB |
| `OtpInput` | 100 kB |
| `Slider` | 103 kB |
| `Command` | 115 kB |
| `Modal` | 129 kB |
| `Autocomplete` | 188 kB |
| `DatePicker` | 274 kB |

`DatePicker` er den man skal tenke seg om to ganger på: rundt 200 kB over
gulvet. Verdt det på et bestillingsskjema, ikke verdt det på en
registreringsside.

**`FileUpload` var billigst, slik denne fila gjettet.** Bits har ingen
primitiv, men serversiden finnes: multipart-parseren kopierer ingenting, og
`StoreIn` lagrer under tilfeldig navn. 9 kB over gulvet.

**Datoer inn og ut er ISO-strenger.** `@internationalized/date` skal ikke
lekke ut i API-et — samme regel som for resten av Bits. Askr sender
`YYYY-MM-DD` fra `DateTimeToSql`, og det er formen en app skal kunne sende
rett inn og få rett ut. En tom eller ødelagt verdi gir en tom velger, ikke
en hvit side.

**Kommandopaletten søker i det som vises.** Bits filtrerer på `value` og
`keywords`, ikke på innholdet i elementet — så en palett der `value` er
`list-customers` finner ingenting når man skriver «all». Det er ikke det
noen forventer, og ikke noe kalleren skal måtte vite; `Command.Item label`
legges i `keywords` av seg selv.

Tre feller til, alle skrevet ned i CLAUDE.md: nøkler i `{#each}` må være
unike, og både ukedagsnavn («S M T W T F S») og datosegmenter (to
`literal` i `MM/DD/YYYY`) gjentar seg — nøkle på indeks. `bind:value` mot
`undefined` er en feil når mottakeren har en fallback, som Bits' `Command`
har. Og `tests/setup.js` stubber det jsdom mangler, men må vernes med
`typeof Element !== 'undefined'`, fordi setup kjører også for testen som
går i node-miljø.

Verifisert i ekte nettleser gjennom lekegrinda: forslagene åpner med
ArrowDown og `aria-activedescendant` peker på et ekte valg, Enter velger,
slideren går 40 → 45 med piltast, kalenderen åpner med fokus i rutenettet
og ArrowRight + Enter gir `2026-09-21` tilbake som streng, seks tastetrykk
fyller engangskoden, og paletten filtrerer på det som vises.

## DataGrid

Bygget etter bolk 3, på bestilling. Den er den vanskeligste komponenten i
et hvilket som helst bibliotek, og den har **to halvdeler** — det er det
viktigste ved den.

**Serversiden er `Askr.Urd.Grid`**, ikke Lauf. Sortering, søk og
paginering skjer i databasen. En grid som henter hundre tusen rader for å
sortere dem i JavaScript er feil svar for Askr: databasen står der
allerede, har indeksene, og er raskere enn nettverket. Klientmodus finnes
for lister på noen tusen rader, og er ikke standarden.

**`Sortable` er en hviteliste, og det er ikke en sjekk noen har husket å
skrive.** `TQuery.OrderBy` tar en typet `TCol`, ikke en streng, så en
kolonne som ikke er registrert finnes rett og slett ikke å sortere på.
Formen `'ORDER BY ' + parameter` lar seg ikke skrive. Testen kjører
`sort=email); DROP TABLE sq_customers;--` og teller radene etterpå.

**To luker i Urd måtte tettes først**, og begge var ekte feil i datalaget,
ikke i griden:

* **`TQuery` hadde bare AND.** «Finn Ada i navn eller e-post» lot seg ikke
  uttrykke. `WhereAnyLike` gir én OR-gruppe i parentes, slik at et `Where`
  kalleren allerede hadde lagt på fortsatt gjelder. Med vilje smal — én
  operator, ingen nøsting — fordi et generelt grupperingsspråk er et
  større spørsmål enn det en liste trenger.
* **`ILike` ble sendt ordrett til alle tre dialektene**, og SQLite svarte
  «near "ILIKE": syntax error». Den oversettes nå til `LIKE` utenfor
  Postgres, der `LIKE` er ufølsom fra før — i MySQL av kollasjonen, i
  SQLite for ASCII. Det siste er en reell forskjell: SQLite skiller
  fortsatt «é» fra «É», og det står skrevet i stedet for å oppdages.

**`TJsonWritable` er et nytt feste i `Askr.Core.Json`.** Før var lista over
hva som kunne være en Inertia-prop lukket — TModel, TModelList, TErrors —
og alt annet var en feilmelding. Nå kan enhver app sende sine egne objekter.
TGrid er den første som bruker det, men ingenting ved festet er spesielt
for griden.

**Én API-felle ble funnet og fjernet.** `PerPage` etter `Read` overskrev
det klienten hadde bedt om, altså endret kallrekkefølgen oppførselen i
stillhet. Det klienten ber om holdes nå for seg og slås sammen med
standarden og taket først når siden hentes.

**Målt i ekte nettleser, 10 000 rader, klientmodus med virtualisering:**
24 rader i DOM-en, `aria-rowcount` 10001, absolutt radnummer riktig etter
rulling til rad 486, nøyaktig én celle i tabbrekkefølgen, pilene flytter
markøren, to klikk på overskriften sorterer synkende, og «velg alle» tar
de 500 på siden.

**Virtualisering er valgfri, ikke på.** Den koster nettleserens eget
Ctrl+F og utskrift. `aria-rowcount` og `aria-rowindex` settes uansett, og
i tjenermodus er indeksen radens plass i *hele* settet — det er den som
gjør at en skjermleser kan si «rad 4013 av 91000» når tjue rader finnes.

## Hva vi ikke bygger

* **Editor.** En rik-tekst-editor er et eget produkt. Om noen trenger en, er
  svaret TipTap eller ProseMirror, ikke vår egen.
* **Kanban.** Samme sak, pluss dra-og-slipp med tastaturstøtte, som er like
  vanskelig som hele bolk 2 til sammen.
* **Chart.** Det finnes gode biblioteker, og et diagram er ikke en
  UI-komponent på samme måte som en knapp er det.
* **Fargevelger.** Begrunnet over — den eneste fra bolk 3 som ble vurdert
  og forkastet.
* **I griden:** kolonneomstokking og festing ved dragning, gruppering,
  redigering i cellene, uendelig rulling og eksport. Hver av dem er sitt
  eget prosjekt, og dragning med tastaturstøtte er like vanskelig som
  resten til sammen.
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
  en feil, ikke en detalj. På plass for bolk 1.
* **Kontrast kan ikke måles av axe i jsdom** — det legges ikke ut noe, og
  fargene regnes ikke ut. Regelen er slått av i `tests/axe.js`, ikke slått
  av i stillhet. **Gjort:** `./askr lauf:check` kjører hele axe, kontrast
  inkludert, i en ekte Chrome. Ingen brudd i noen av de seks
  kombinasjonene.
* **Tastaturgjennomgang for alt i bolk 2.** Åpne, navigere, lukke, og fokus
  tilbake dit det kom fra — uten mus. Gjort, delvis i jsdom og delvis mot
  en ekte Chrome over CDP, fordi fokusfelle og rullelås ikke finnes i
  jsdom. Skriptet driver demoen, ikke en fiksturside.
* **Premisstest på bunten:** en side som importerer `Button` og ett ikon skal
  gi en bunt med ett ikon i, ikke tre hundre. Tallet måles og holdes, på samme
  måte som `BytesReserved` holdes flat i arena-testene. Ryker den, er
  tree-shaking brutt, og det merkes ellers ikke før noen klager på
  lastetiden.
* **Skjermdump i lys og mørk modus, på 390 px og på skrivebord.** **Gjort**,
  av den samme kommandoen. `Emulation.setDeviceMetricsOverride` over CDP gir
  en ekte 390 px viewport, så iframe-knepet fra velkomstsiden trengs ikke
  her. Seks bilder i `frontend/lauf/.shots`: lys, mørk via
  `prefers-color-scheme` og mørk via `data-theme`, hver på 390 og 1280.
  Mørk sjekkes begge veier fordi tokenene håndterer tre tilstander, og én
  kan ryke uten at den andre gjør det.

  **Kjøringen fant tre brudd som jsdom-suiten hadde sluppet gjennom**, og
  ingen av dem handlet om farge: slider-knotten hadde ikke noe navn
  (`<label for>` binder ikke mot en `<span role="slider">`, så den må ha
  `aria-labelledby`), kommandopalettens input manglet `aria-controls` som
  rollen krever, og engangskodefeltet hadde ingen etikett i det hele tatt.
  Alle tre er rettet: `Field` eksponerer nå id-en til etiketten sin, for
  kontroller som ikke kan merkes på vanlig måte. Det er det beste
  argumentet for at denne porten måtte finnes.

## Åpne spørsmål

1. **npm-scopet `@askrcode` må registreres, og det er et nettlesersteg.**
   `npm org` har bare `set`, `rm` og `ls` — den kan ikke opprette en
   organisasjon. Det må gjøres på <https://www.npmjs.com/org/create>,
   innlogget som den kontoen som skal eie den. Scopet er ledig: null pakker
   publisert under det.

   Alt annet er gjort. Pakka er `0.1.0`, MIT, `publishConfig.access` er
   `public` — et scopet navn er «restricted» som standard, og første
   publish feiler med 402 uten den — og tarballen er verifisert: 1359 filer,
   230 kB, med LICENSE, NOTICE.md, alle 1288 ikonene og `src/inertia/`.

   Til den er publisert skriver `askr new`
   `"@askrcode/lauf": "file:<rammeverkssti>"`. Det virker for et prosjekt på
   samme maskin som rammeverket, og ikke for noen andre.
2. ~~**Fri eller betalt?**~~ Avgjort: **MIT, på hele Askr.** `LICENSE` ligger
   i rota og i pakka. Det er forenlig med alt som er dratt inn — Bits UI,
   Heroicons, clsx og tailwind-merge er MIT, `@internationalized/date` er
   Apache-2.0.

   **Heroicons' varsel måtte følge med.** Ikonene under `src/icons/` er
   kopier av Heroicons-grafikk og ligger *inne i* tarballen, og MIT krever
   at opphavsvarselet reiser med kopiene. `NOTICE.md` bærer det, og er med i
   `files`. Avhengigheter som installeres fra npm er noe annet — de kopieres
   ikke inn, så deres lisenser gjelder der de installeres.
3. ~~**`Icon` med navn kontra importert komponent.**~~ Avgjort i bolk 0:
   komponent. Tallene står over.
4. ~~**Skal `askr new` installere Lauf som standard?**~~ Avgjort: ja. Lauf er
   frontendlaget, ikke et tillegg. Malene er fortsatt små — Home.svelte er
   nitten linjer — og de bruker fire komponenter, ikke femten filer man ikke
   forstår.

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
