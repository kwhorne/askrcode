# Askr — arbeidsnotater

Rammeverket, ikke en app. PRD-en er fasit for hva som skal bygges og i hvilken
rekkefølge; denne fila er bare det man må vite for å endre koden her.

## Bygg og test

```sh
./askr test     # dette er porten alt skal gjennom
./askr run
./askr db:up    # Postgres på 5433, kreves av ./askr spike
./askr spike
./askr urd
./askr schema
./askr web        # bygger frontend med npm og starter demoen
./askr cli        # bygger CLI-en fra PRD-en
./askr run:demo   # Rún ende-til-ende mot SQLite
./askr check      # samme som test, med -Cr -Co -Ci
```

`./askr` er byggskriptet for rammeverket. CLI-en fra PRD-en er noe annet: et
Pascal-program i `cli/askr.lpr` som brukes i en *app*, og som trenger en
`askr.toml`. Rammeverket selv er ikke en app.

`fpc` fra PATH brukes når den finnes, eller den `ASKR_FPC` peker på. Ellers
bygges `askr-fpc:bookworm` fra `tools/Dockerfile.fpc`. Det offisielle
`freepascal/fpc`-imaget er musl-basert og linker ikke mot `cthreads` — bruk
ikke det.

Koden bygger og består alle testene på både 3.2.2 og 3.3.1 trunk. Hold det
slik: det er den eneste måten å vite om en grense er borte eller bare flyttet.

`tools/probes/run.sh <fpc>` kjører generics-probene mot en gitt kompilator.
Alle seks feiler fortsatt på trunk.

## .env og konfigurasjon

* `Askr.Core.Env` leser `.env` én gang ved oppstart. **Ekte miljøvariabler
  vinner over fila** — det er slik produksjon setter verdier uten at fila
  finnes, og det er testet.
* Verdier logges aldri. `EnvOrFail` sier hvilken nøkkel som manglet og hvor
  det ble lett, aldri hva noe inneholdt. Den skal være trygg å la stå i et
  stakkspor, og testen sjekker at ingen verdi lekker ut i meldingen.
* Fila leses inn i vårt eget lager, ikke satt med `setenv`. FPCs RTL holder
  sin egen kopi av miljøet fra oppstart, så `setenv` når uansett ikke fram
  til barneprosesser.
* `askr new` lager `.env` og `.env.example`, og legger `.env` i `.gitignore`.
  Appen kaller `LoadEnvUpwards` først i `app.lpr`.
* En `#` uten mellomrom foran er en del av verdien, ikke en kommentar — ellers
  ville et passord med `#` i seg blitt kuttet i to.

## Krypto, CSRF og auth

* **Kryptoen er ren Pascal, uten OpenSSL, og det er ikke en smakssak.**
  Binæren skal starte på en maskin uten OpenSSL. TLS er valgfri — en app bak
  en reverse proxy trenger den aldri — men enhver app med brukere trenger
  passordhashing. Legger du den på libcrypto, er «valgfri avhengighet» ikke
  lenger sant.
* Prisen er **PBKDF2-HMAC-SHA256, ikke Argon2id**. Argon2 finnes i libcrypto
  fra OpenSSL 3.2; bookworm har 3.0, og macOS-maskinen har ingen. Det kunne
  altså ikke kjøres i noe testmiljø, og utestet kode som hasher passord er
  verre enn ingen. Står i både `Askr.Core.Crypto` og LARAVEL.md.
* **SHA-256 er merket `{$push}{$R-}{$Q-}`**, av samme grunn som FNV-hashene:
  algoritmen regner modulo 2^32 og flyter over med vilje. Uten merkingen dør
  hele uniten på `ERangeError` i `./askr check`.
* **Vektorene er dekningen.** En SHA-256 med feil byterekkefølge er stabil,
  konsistent og verdiløs, og ingenting i en app sier fra. `askr_crypto_tests`
  kjører NIST FIPS 180-4, RFC 4231, RFC 6070 og RFC 4648. Rører du en
  algoritme, er det vektorene som avgjør, ikke at det «ser riktig ut».
* **`Login` bytter sesjons-id.** Uten det står session fixation åpent: en
  angriper setter kaka di før du logger inn og er deg etterpå. Det er én
  linje i `Askr.Auth`, og testen feiler hvis den fjernes — det er sjekket
  ved å fjerne den.
* **Rammeverket eier ikke brukermodellen.** Det lagrer en id som tekst;
  appen registrerer en `TUserLoader`. Ikke «forbedre» det til en `TUser` i
  rammeverket — det ville låst skjema og tabell.
* **En gate som ikke finnes svarer nei.** En stavefeil i et gate-navn skal
  stenge døra. Det motsatte ser ut som at alt virker.
* **`TResponse.WithHeader` lar siste verdi vinne; `AddHeader` og
  `WithCookie` gjør ikke det.** Sesjonskaka og XSRF-kaka lever side om side
  i samme svar, og med `WithHeader` slo de hverandre i hjel. Det var en ekte
  feil, og den har en test som teller `Set-Cookie`.
* **Ruteren har etterfiltre (`After`).** Sesjonen må skrives tilbake *etter*
  at handleren har kjørt, og middleware alene har ikke noe sted å stå.
  Filtrene kjører i motsatt rekkefølge av registreringen, og de kjører også
  når middleware kortsluttet requesten — ellers mister en 401 fra en guard
  kaka si.
* **En ny sesjon ingen skrev til, lagres ikke.** `UseSessions` hopper over
  `Commit` når sesjonen er ny og ikke dirty. Uten det fikk hver robot og
  hvert helsesjekk-kall en plass i lageret, som ligger i prosessen — altså
  hukommelse som vokser med trafikk og ikke med brukere. `Sessions.Commit`
  kalt direkte gjør fortsatt som den blir bedt om.
* «Husk meg» er en **signert kake, ikke et token i databasen**, og kan
  derfor ikke trekkes tilbake enkeltvis. Utløpet står inne i det signerte,
  ikke bare i `Max-Age` — en klient som beholder kaka for lenge skal ikke
  komme inn.
* `APP_KEY` kommer fra miljøet. `askr key:generate` skriver en ny ut, men
  setter den **ikke** inn i `.env` selv: en nøkkel som byttes i stillhet
  logger ut alle.
* `askr new` skrur på sesjoner, CSRF og auth. Statiske filer registreres
  **før** dem, slik at de kortslutter uten å røre noe av det.

## Filopplasting

* **Parseren kopierer ingenting.** Kroppen ligger allerede sammenhengende i
  workerens lesebuffer — ikke i arenaen — og hver del blir et `TStr`-utsnitt
  inn i det samme bufferet. Ikke «forbedre» det til å kopiere innholdet inn
  i arenaen: da betaler en opplasting på fem megabyte for seg to ganger.
* **`TMultipartForm` bruker arena-blokker med teller, ikke dynamiske
  arrayer.** Et dynamisk array er et finaliseringspliktig felt, og `TRequest`
  med ett slikt betaler en `Defer`-oppføring på hver eneste request — også
  de uten en fil. Første forsøk gjorde nettopp det, og testen
  «TRequest betaler ingenting for mekanismen» fanget det.
* Taket er `MaxBodyBytes`, 8 MB som standard. Hele opplastingen må få plass
  i minnet. Skal større filer støttes, må kroppen strømmes til disk mens den
  leses, og det er en endring i `TWorker` — ikke i parseren.
* **CRLF-en foran grensen hører til skilletegnet, ikke til innholdet.**
  Bommer man på det, får hver fil to ekstra byte på slutten, og det merkes
  først når noen ikke får åpnet en zip-fil.
* **Klientens filnavn er en tekst en angriper skriver.** `StoreIn` bruker
  den ikke i det hele tatt — tilfeldig navn, sanert endelse. `SaveAs`
  skriver dit kalleren sier, og da er stien kallerens ansvar. `SafeName`
  fjerner katalogdeler (både `/`, `\` og `:`), ledende punktum og alt som
  ikke er `[A-Za-z0-9._-]`.
* `Req.Form` leser **både** urlencoded og multipart. Uten det ville et
  skjema med en fil i gjort alle de andre feltene utilgjengelige — og
  CSRF-tokenet ligger i ett av dem.
* Lesebufferet nedskaleres etter en stor request, men **bare når det ikke
  ligger noe igjen i det**. Uten den betingelsen forkastes en pipelinet
  request som kom rett etter en stor kropp.

## Logg og konfigurasjon

* **`Askr.Core.Log` er den eneste loggen.** Serveren skrev før
  `WriteLn(StdErr, ...)` tre steder; de går nå alle gjennom `LogInfo` og
  `LogException`. Skriver du en ny linje til stderr i `src/`, er det
  sannsynligvis feil sted.
* En upåaktet exception fra en handler **logges alltid**, uavhengig av
  `LogRequests`. Det er ikke en request-linje, det er en feil, og en 500
  uten spor er en 500 ingen kan feilsøke.
* Formatet følger `APP_ENV` når `LOG_FORMAT` ikke er satt: tekst lokalt,
  JSON i produksjon. Det er det eneste stedet i Askr der miljøet endrer
  oppførsel av seg selv, og grunnen er at feil standard merkes med en gang.
* **Tall og boolske står usitert i JSON.** `"ms":"12"` kan ingen regne på.
  Og `FloatToStr` følger locale — på en norsk maskin blir desimalskilletegnet
  komma, og da er linja ikke lenger JSON. `FloatMedPunktum` finnes for det.
  Samme felle som `FormatFloat` i velkomstsiden.
* Feltene er par i et `array of const`. `VerdiTekst` må ha en gren for hver
  `TVarRec`-type som kan komme inn: en logglinje som kaster fordi noen
  sendte en peker er verre enn linja den erstattet.
* **`Askr.Core.Config` eier rekkefølgen:** ekte miljøvariabler, så `.env`,
  så `askr.toml`, så standardverdien. Nøkkelen `app.port` slås opp som
  `APP_PORT` i miljøet. Miljøet vinner alltid — en utrulling skal kunne
  sette noe uten at en fil i repoet endres.
* **TOML-parseren står i `Askr.Core.Config`, og CLI-en bruker den samme.**
  `askr.toml` skal ikke kunne bety én ting for CLI-en og noe annet for
  appen den bygger.
* **En `[seksjon]` i askr.toml gjelder alt under seg.** `[app]` står derfor
  sist i det `askr new` skriver. Midt i fila ville den gjort `units` til
  `app.units`, og byggingen ville sluttet å finne rammeverket. Det skjedde.
* `askr config` viser **ikke** verdier uten `--values`, og selv da er nøkler
  som ser ut som hemmeligheter skjult. Utskriften skal være trygg å lime
  inn i en feilrapport.
* **`setenv` fra libc er synlig for `GetEnvironmentVariable` på Darwin, men
  ikke på Linux.** FPCs RTL leser `envp` fra oppstart der. Det finnes ingen
  bærbar måte å sette en miljøvariabel en test kan lese tilbake — bruk en
  som allerede står der, som `HOME`, slik `.env`- og config-testene gjør.

## Varig kø

* **`TQueue` har ett worker-løp, og det gjelder begge lagrene.** Forskjellen
  på minne og database er `TJobStore`, ikke en egen tråd. Et eget løp for
  varige jobber ville gitt to sett regler for backoff, forsøkstelling og
  arena-levetid, og de to ville drevet fra hverandre. Samme grunn som at
  scheduleren dytter til køen i stedet for å kjøre selv.
* De to kopiene består: `Push` kopierer ut av kallerens arena (i lageret),
  og workeren kopierer inn i sin egen. `TDbJobStore.Reserve` kopierer
  payloaden til heapen, ikke til arenaen den selv bruker — den arenaen dør
  når Reserve returnerer.
* **Nøyaktig én av `Complete`, `Retry`, `Fail` og `Drop` skal kalles** etter
  en vellykket `Reserve`. Det er der minnet slippes.
* **Tidspunktene i tabellen er unix-millisekunder, ikke TIMESTAMP.** Flere
  prosesser deler tabellen, og et heltall betyr det samme uansett hvilken
  tidssone den enkelte serveren tror den står i. Minnelageret bruker
  `MonotonicMs`; det er derfor lageret eier tidsregningen og ikke `TQueue`.
* **Forsøkstelleren står i raden.** Dør prosessen midt i en jobb, skal den
  ikke starte på null igjen.
* **`EnsureSchema` spør introspeksjonen først.** `CREATE TABLE IF NOT
  EXISTS` finnes i alle tre, men `CREATE INDEX IF NOT EXISTS` finnes ikke i
  MySQL — andre oppstart feilet på indeksen. Å svelge «already exists»
  ville skjult ekte feil.
* **Payloaden lagres som tekst, og en nullbyte avvises ved `Push`.** En
  TEXT-kolonne tar den ikke i noen av de tre. Å la den gå videre ville gitt
  enten en stille ødelagt jobb eller en driverfeil langt unna kallstedet.
* En jobb uten registrert handler havner i **feiltabellen**, ikke i intet.
  I minnekøen forsvinner den; det er en reell forskjell mellom de to.
* `FOR UPDATE SKIP LOCKED` brukes i Postgres og MySQL, ikke i SQLite, som
  har én skriver. Vakten `AND reserved_at IS NULL` på UPDATE-en er ikke
  overflødig ved siden av den — uten begge kjørte seks av to hundre jobber
  dobbelt da vinduet mellom SELECT og UPDATE ble utvidet med 5 ms.
  Samtidighetstesten alene fanger det ikke; det står i `queue_db_conc.inc`.
* Standard poll er **250 ms**, ikke 20. Fire workere som spør en tom tabell
  hvert 20. millisekund er 200 spørringer i sekundet for ingenting.

## Modell-livskvalitet

* **En `TDateTime` på null skrives som NULL, ikke som 1899-12-30.** Pascal
  har ingen null, og 0 er en ekte dato ingen mener. Før denne endringen ble
  en nullbar datokolonne aldri NULL, og soft deletes ville ikke virket i det
  hele tatt.

  Dette er en oppførselsendring, og den ene formen som kan ryke er: en
  modell med en published `TDateTime` mot en **NOT NULL**-kolonne, uten at
  verdien settes. Før gikk den gjennom med 1899-12-30; nå gir den en
  constraint-feil. Det er den riktige veien å feile — en stille gal dato er
  verre — og rettelsen er `S.Timestamps` eller å sette verdien.
  `TTableBuilder.Timestamps` lager nettopp NOT NULL-kolonner, så en modell
  som mapper dem uten `S.Timestamps` er tilfellet å se etter.
* **Tidsstemplene settes av modellen, ikke av databasens DEFAULT.** En
  DEFAULT setter created_at ved INSERT og rører aldri updated_at igjen; en
  rad oppdatert ti ganger så like fersk ut som da den ble laget.
  `S.Timestamps` krever at kolonnene finnes som published TDateTime — uten
  sjekken ville de stille latt være å bli satt.
* En `created_at` som allerede er satt overskrives ikke. En import som
  bevarer opprinnelige tidspunkter skal ikke miste dem.
* **`VarNy` leses før SQL-en kjører.** INSERT setter `FPersisted`, og
  etterpå ser alt ut som en oppdatering — `AfterInsert` ville aldri kjørt.
* **Hendelsene er virtuelle metoder, ikke observers registrert i runtime.**
  Kompilatoren ser dem, og det finnes ingen refleksjon å gå gjennom. For å
  avbryte: kast. En Save som stille lot være å lagre ville vært verre.
* **`Delete` sletter mykt når modellen har SoftDeletes, og `DeleteAll` gjør
  det samme.** At én slettet mykt og den andre hardt er den slags forskjell
  ingen husker før en tabell er tom. `ForceDelete`/`ForceDeleteAll` sletter
  uansett; `Restore`/`RestoreAll` tar tilbake.
* Etter en myk sletting står `Persisted` fortsatt. Raden finnes, og en
  påfølgende `Save` skal oppdatere den, ikke sette inn en ny.
* Soft-delete-leddet er **kvalifisert med tabellnavnet**, slik at det også
  holder når spørringen får en join.
* **Query scopes krever ingenting av rammeverket.** En scope er en
  frittstående funksjon som returnerer `TQuery<M>`; den er typet og kan
  kjedes. Den kan ikke være en klassemetode på modellen — da ville
  returtypen fremoverreferert klassens egen type, samme grense som
  `TModelList<M>`.
* SQL-tidsstempler har sekundoppløsning. En test som sorterer på created_at
  må sette verdiene selv; to rader laget i samme sekund har ingen definert
  rekkefølge.

## HTTP-klienten

* **`SSL_VERIFY_PEER` sjekker kjeden, ikke vertsnavnet.** Uten
  `SSL_set1_host` ville et ekte sertifikat for et hvilket som helst domene
  passert — hele man-in-the-middle-angrepet. SNI sier hvilket sertifikat vi
  vil ha; `SSL_set1_host` sier at det vi fikk gjelder verten. Begge må med,
  og begge settes i `TTlsConn.Create` for klientrollen.
* **En `False` fra strømme-callbacken må stoppe lesingen overalt.** Første
  utgave ignorerte svaret fra den aller første biten — den som allerede lå
  i bufferet etter hodet — og leste videre. For en SSE-strøm betyr det at
  lytteren aldri slutter å lytte. Testen fanget det.
* `FillChar` over `THttpResponse` er feil: den har både strenger og et
  dynamisk array. Samme felle som i `Askr.Run` og `TRunStats`.
* **`Delete` som metodenavn skygger for `System.Delete` inne i klassen.**
  Kall `System.Delete(Buf, …)` eksplisitt. HTTP-verbet skal hete `Delete`,
  så det er skyggen som må håndteres, ikke navnet.
* `in [301, 302, …]` går ikke — et Pascal-sett rommer 0..255. Statuskoder
  sammenlignes enkeltvis.
* **Klienten ber om `identity`, ikke gzip.** Uten zlib kan den ikke pakke
  ut, og en klient som ber om noe den ikke kan lese er en feil som venter.
  Å binde zlib for båndbredde på et API-kall er feil bytte.
* 307 og 308 beholder metoden og kroppen; 301, 302 og 303 blir GET. Det er
  hele grunnen til at 307 og 308 finnes.
* **HTTPS testes mot Askrs egen TLS-server, ikke mot et nettsted.** Den
  prøven er hermetisk og tester selve sikkerhetsegenskapen: serverens
  sertifikat er selvsignert og **skal** avvises. Går det gjennom, er
  verifiseringen en tom prosedyre.
* **Navneoppslag går gjennom `getaddrinfo` fra libc, ikke FPCs netdb.**
  netdb har sin egen DNS-implementasjon som leser `/etc/resolv.conf` og
  snakker UDP selv, og den bommer der systemet klarer seg: i containeren
  ga den opp helt mens `getent hosts` svarte. `getaddrinfo` går veien
  systemet går — nsswitch, `/etc/hosts`, DNS, mDNS. netdb er reserve.
  Med den endringen virker ekte DNS og HTTPS mot internett, og begge
  badssl-avvisningene (feil vertsnavn, utløpt sertifikat) er prøvd.
* Chunked testes mot en liten rå socket-server i suiten. Askrs egen server
  setter alltid Content-Length, så uten den er hele chunked-stien udekket —
  og det er den stien enhver server bruker når den ikke vet lengden.

## AI

* **Tenkning sendes som `{"type":"adaptive"}`, aldri med `budget_tokens`.**
  Den gamle formen er avviklet på 4.6-modellene og blir **avvist med 400**
  på Opus 5, Sonnet 5 og Fable 5. Den er en felle nettopp fordi den er den
  formen man husker. Det finnes en test som slår ned på at `budget_tokens`
  i det hele tatt forekommer i requesten.
* Headeren er **`x-api-key`**, ikke `Authorization: Bearer`. En Bearer-token
  her gir 401 uten forklaring.
* **`Structured` må sende `tool_choice`.** Første utgave registrerte
  verktøyet og glemte å tvinge det, og da kunne modellen svare med prosa —
  «strukturert» ble et håp. Testen fanget det.
* **Avbrytelsen i SSE-strømmen må sjekkes inne i linjeløkka.** En hel strøm
  kan komme i én bit, og da rekker et stopp etter første delta ikke å virke
  før alle de andre er levert. Også dette fanget testen.
* Et verktøyresultat er en **`tool_result`-blokk i en `user`-melding**, ikke
  en egen rolle. Det er den vanligste feilen når man bygger løkka selv.
* Verktøyets argumenter gis videre som **JSON-tekst**. Bare verktøyet vet
  hvilke felter det har; rammeverket skal ikke gjette.
* Et verktøy som kaster, og et verktøy modellen finner på, blir begge en
  beskjed *til modellen* — ikke en exception ut av løkka. Løkka har
  dessuten et tak, fordi en modell kan gå i ring.
* `EAiError.Kind` er typen slik API-et skriver den, uten pynt:
  `overloaded_error` for å prøve igjen, `invalid_request_error` for å la
  være. Parentesene hører til meldingsteksten.
* **`eager_input_streaming` er ikke slått på.** Det ville gjort klienten
  ansvarlig for å validere verktøyargumenter mot skjemaet, og Askr har
  ingen JSON Schema-validator. Å slå det på uten den er å bytte en kjent
  begrensning mot en stille.

### Hva som ikke er prøvd

**Ingen kall med en gyldig nøkkel er gjort fra dette repoet.** Det er det
samme forbeholdet som på Windows-skallet, og det skal stå til noen har
kjørt det.

Det som **er** prøvd mot `api.anthropic.com`: et ekte kall uten gyldig
nøkkel, som kom tilbake som 401 med Anthropics egen feil-JSON, riktig
parset til `EAiError` med status og type. Det beviser DNS, TLS,
requestformen og feilhåndteringen — ikke at et svar med innhold kommer
tilbake. Alt annet er testet mot `TFakeAiTransport`, som holder JSON-en
som sendes opp mot det den skal være.

## Kommandolinja

* **`Askr.Console` ligger i rammeverket, ikke i den genererte app.lpr.**
  Kommandoene må kjøres av appbinæren — migrasjonene, rutene, jobbene og
  planen er kompilert inn der, og verktøyet vet ikke hva som står i dem.
  `askr <noe>` kjører `app --noe`, og `RunConsole` tar imot i den andre
  enden. Et prosjekt laget i fjor får nye kommandoer ved å bygge på nytt.
* **Kompilatoren slås opp i `FinnKompilator`, ikke ved å håpe på PATH.**
  Rekkefølgen er `compiler` i askr.toml, så `ASKR_FPC`, så PATH — og
  ASKR_FPC gjelder bare når prosjektet ikke har pekt ut noe selv. Før dette
  døde app-CLI-en med `EProcess: Executable not found: "fpc"` og seks linjer
  heksadesimale adresser, som ser ut som en krasj i verktøyet og ikke som
  noe man kan gjøre noe med. Alle fire feilstiene sier nå hva den lette
  etter, hvor, og hva man skal gjøre.
* **Argumentene må videresendes.** `KjorApp` sendte bare flagget, og
  `askr db:table posts` kom fram uten `posts`. Alt etter kommandoen sendes
  nå med.
* **En migrasjonsfil må hete det uniten heter.** Fpc finner ingen unit som
  heter noe annet enn fila si, så tidsstempelet kan ikke stå i filnavnet —
  rekkefølgen kommer fra `Version`. Og en unit ingen refererer blir aldri
  linket inn, så `App.Migrations` og `App.Seeders` genereres som indekser
  som bare «uses» dem. Indeksene leses av katalogen, ikke av en liste.
* `database` må stå i `units` i askr.toml. Uten det er migrasjonene ikke på
  søkestien i det hele tatt.
* **`askr down` var et halvt løfte til `UseMaintenance` kom.** Kommandoen
  skrev fila, og ingenting leste den. Middlewaren svarer 503 med
  `Retry-After`, og den står etter de statiske filene slik at en
  vedlikeholdsside med css fortsatt kan serveres.
* Migrasjonstabellens egen DDL brukte `now()`, som ikke finnes i SQLite.
  Den hadde aldri vært kjørt mot SQLite, fordi Norn-testene går mot
  Postgres og MySQL. Nå `CURRENT_TIMESTAMP`, som de tre andre stedene.
* **SQLite erklærer `DATETIME`, ikke `TEXT`.** SQLite lagrer tekst
  uansett, men den *erklærte* typen er det introspeksjonen leser — med
  TEXT typet `askr schema` created_at som `string` mot SQLite og som
  `TDateTime` mot Postgres, av samme migrasjon. DATETIME gir
  NUMERIC-affinitet, og en ISO-tekst lar seg ikke konvertere tapsfritt til
  et tall, så lagringen er uendret.
* `db:wipe` nekter når `APP_ENV=production` uten `--force`. Den ene
  kommandoen som sletter alt skal ikke kunne kjøres ved et uhell.

## Dokumentasjonen i docs/

* **`docs/` og README.md er produkt og er på engelsk.** Det er det en
  bruker av rammeverket leser, og faller derfor inn under regelen under.
  README-en er inngangsdøra til et offentlig repo; CLAUDE.md, LAUF.md og
  LARAVEL.md er arbeidsnotater og blir værende norske.
* **Signaturene skal verifiseres, ikke huskes.** Første utkast hadde
  `Back.WithErrors` (heter `BackWithErrors`), `Mail.Send(tekst, emne)`
  (tar en `TMailMessage`), tre valideringsregler som ikke finnes
  (`In_`, `Matches`, `Confirmed` — de heter `OneOf`, `SameAs`, og den
  tredje finnes ikke), og `askr tls:certs` som om det var app-CLI-en.
  Alle fire ble funnet ved å lese kilden, ikke ved å lese teksten.
* **To ting heter `askr`.** `./askr` er rammeverkets byggskript;
  `askr` på PATH er CLI-en i et prosjekt. Dokumentasjonen skiller dem med
  `./`, og sier det eksplisitt i getting-started og cli.
* Hver side sier også hva som **ikke** finnes, og hvorfor. Det er den
  delen som gjør dokumentasjonen til noe annet enn markedsføring, og den
  skal ikke fjernes når noe blir bygget — den skal oppdateres.

## Språk mot brukeren

**Alt en bruker av rammeverket ser, er engelsk.** Det gjelder unntaksmeldinger,
valideringsmeldinger, CLI-utskrift, velkomstsiden og alt `askr new` genererer.
Askr er et internasjonalt rammeverk, og en norsk feilmelding er ubrukelig for
de fleste som treffer den.

**Kommentarer og arbeidsnotatene er norske** — CLAUDE.md, LAUF.md og
LARAVEL.md. De er ikke produkt. Skriver du en ny melding som kan nå en
bruker, skriv den på engelsk — skriver du en kommentar om hvorfor koden er
som den er, skriv den på norsk.

**README.md er unntaket som flyttet.** Den var et arbeidsnotat på norsk til
repoet ble offentlig. Nå er den det første noen ser på GitHub, altså
produkt, og den er engelsk og kort. Statustabellene som lå der er borte;
det som må holdes oppdatert er de to forbeholdene — Windows og AI-laget
uten en ekte nøkkel — og de står fortsatt der.

Valideringsmeldingene er de mest synlige av alle: de havner i skjemaer.
`' is required'`, `'%s must be at least %d characters'`, og så videre.

**Eksempeldomenet er også engelsk** — `customers`, `orders`, `name`, `email`,
`balance`, `active`. Tester og eksempler er det andre leser for å lære
rammeverket, og et norsk domene der gjør dem vanskeligere å lese enn de
trenger å være. Norske tegn i testdata er noe annet: `Blåbærsyltetøy 🫐`
står der fordi den tester utf8mb4 og firebyte-tegn, og skal bli stående.

## Språkvalg

Alle units er `{$mode Delphi}{$H+}`. Grunnen er generics: PRD-ens egen
eksempelkode skriver `Req.Arena.New<TCustomer>` og `Query<TCustomer>.Where(…)`.
I objfpc-modus blir det `specialize` overalt, og ergonomien er produktet.
Pascal-arven beholdes der den koster noe — deklarasjonsseksjoner, `begin/end`,
navngitte parametre.

`{$POINTERMATH ON}` står i de unitene som indekserer sammenhengende tabeller i
arenaen (`Askr.Http.Request`, `Askr.Http.Response`). Ikke skru den på uten
grunn; den slår av en reell typesjekk.

## Arena-regler i koden

* Alt som skal leve ut requesten arver `TArenaObject` og lages med `Create`
  inne i en `UseArena`-blokk. Verten setter arenaen; brukerkode rører den ikke.
* Ikke kall `Free` på arena-objekter. Det er en no-op, men det signaliserer at
  forfatteren tror på feil modell.
* Destructoren kjører aldri på et arena-objekt. **Men `string`, dynamiske
  arrayer og interface-felt ryddes likevel:** `NewInstance` sjekker
  `ClassNeedsFinalization` og registrerer `CleanupInstance` som `Defer`.
  `TSession`, `TQuery` og `TErrors` er avhengige av det. Et felt som peker på
  et objekt — `TStringList`, `TList` — lekker derimot, for det ryddes bare av
  en destructor som aldri kjører. Foretrekk `TStr` uansett: hvert
  finaliseringspliktige felt koster en `Defer`-oppføring per objekt per
  request.
* Lesebufferet i `TWorker` ligger med vilje **ikke** i arenaen: det må overleve
  `Reset` for at keep-alive og pipelining skal virke.
* Hodet kopieres inn i arenaen før parsing, slik at lesebufferet kan vokse når
  kroppen kommer uten at utsnittene i `TRequest` blir hengende. Ikke fjern den
  kopien uten å løse det problemet på en annen måte.

## Arena

* `Arena.New<T>` er inngangen PRD-en skriver: constructoren kjører, VMT-en er
  på plass, og objektet havner i den arenaen selv om en annen er omgivende.
  Typeparameteren er bundet til `TArenaObject` med vilje — en vilkårlig
  `TObject` ville havnet på heapen uten at kallstedet merket det.
* `Arena.Owns(P)` sier om en peker faktisk ligger i arenaens minne. Bruk den i
  tester i stedet for å anta.
* `ClassNeedsFinalization` går opp hele arvekjeden. Free Pascal legger én
  init-tabell per klasse som bare dekker klassens egne felter, så en
  underklasse som arver et `string`-felt har tom egen tabell. Sjekker man bare
  klassen selv, lekker hver slik modell én streng per request.

## Datalaget

* `Arena.Defer` er svaret på at destructorer aldri kjører på arena-objekter.
  Opprydningen kjøres i motsatt rekkefølge ved `Reset`, `Rewind` og `Destroy`.
  En funksjon som kaster blir svelget med vilje — en halvferdig `Reset` er
  verre enn en tapt feilmelding.
* `TDbResult` eier ingenting fra libpq. Alt kopieres inn i arenaen, og
  `PQclear` skjer før `Exec` returnerer. Ikke bytt til utsatt `PQclear` uten å
  ta hele levetidsdiskusjonen på nytt.
* `TPgConnection` er ikke et arena-objekt og skal aldri bli det. Den lever på
  heapen på tvers av requests, jf. PRD-ens første regel.
* Tekstparametre til libpq må være nullterminerte. `ExecParams` kopierer derfor
  hver `TStr` med terminator, og spoler arenaen tilbake til et merke etterpå
  slik at parametrene ikke blir liggende.
* Allokér parametre FØR `Arena.Mark` når koden spoler tilbake etterpå. Ligger
  de etter merket, skriver de neste allokeringene over verdiene mens de leses.
  Det traff `LoadRelation` og ga en feil som ikke syntes i testene.
* `TModel` er erklært med `{$M+}`. Uten det får ikke modellene lov til å ha en
  published-seksjon, og hele mappingen ville krevd kodegenerering.
* Et published felt må stå før properties i samme seksjon, og en
  forward-deklarert klasse kan ikke brukes som typeargument til
  `TModelList<M>`. Derfor må barnemodellen deklareres ferdig før foreldren.
* Driverne skal dele grensesnitt med MySQL og SQLite. Placeholdere er `$1` i
  Postgres og `?` i de to andre, og `RETURNING` finnes ikke i MySQL. La
  «sett inn og gi meg id-en» være én driveroperasjon.

## Prepared statements

* **`PQprepare` er ikke SQL-setningen `PREPARE`.** Den sender `Parse` i den
  utvidede protokollen, og slike statements hører til sesjonen, ikke til
  transaksjonen — de overlever rollback. SQL-`PREPARE` gjør det ikke. Ikke
  bygg om cachen for å «håndtere» transaksjoner; den trenger det ikke.
* Cachen kan likevel bli utdatert, for eksempel hvis noe kjører
  `DEALLOCATE ALL`. Da svarer serveren `26000`, og driveren forbereder på
  nytt og kjører om igjen. Den stien har en egen test som kjører
  `DEALLOCATE ALL` bak ryggen på cachen.
* Statementnavn (`askr_N`) gjenbrukes aldri. Et statement driveren har
  mistet oversikten over kan da ikke kollidere med et nytt, og feilstien
  slipper å kjøre `DEALLOCATE` i en kanskje avbrutt transaksjon.
* **SQLite må både `sqlite3_reset` og `sqlite3_clear_bindings` ved gjenbruk.**
  Uten reset holder en ferdig-stepped SELECT på lesesperren sin til noen
  kjører den igjen; uten clear_bindings kan verdier fra forrige kjøring henge
  igjen. Gjenbruk er trygt fordi `Run` alltid tømmer statementet til
  SQLITE_DONE før den returnerer — leverte den rader dovent, ville den samme
  spørringen inne i sin egen løkke ha nullstilt seg selv.
* `sqlite3_prepare_v2` håndterer skjemaendringer selv, så et cachet statement
  overlever `ALTER TABLE`. Der MySQL må kaste statementet ut av cachen ved
  feil, trenger SQLite det ikke.
* Cachede statements må frigjøres før `sqlite3_close_v2`. Den tåler at de
  henger igjen — den utsetter lukkingen — men da ville fila stått åpen på
  ubestemt tid, og «lukket» ville betydd noe annet enn det ser ut som.
* **Et ucachet statement eies av kallet og må lukkes.** I MySQL-driveren
  lekket `CacheLimit := 0` ett statement per spørring, både i klienten og på
  serveren, fordi bare den cachede veien lukket noe. `Prepared` sier nå fra
  om statementet ble cachet.
* **`DropCached` lukker selv.** Lukkes statementet så én gang til i `finally`,
  er det en dobbeltfrigjøring — og den viste seg som en access violation i
  unik-brudd-testen, ikke som noe som lignet årsaken. Skill «er cachet» fra
  «må lukkes».
* Cachetellerne i driveren er ikke bevis. `pg_prepared_statements` i Postgres,
  `SHOW GLOBAL STATUS LIKE 'Prepared_stmt_count'` i MySQL og
  `TSqliteConnection.OpenStatements` (over `sqlite3_next_stmt`) er kildens
  eget syn, og det var MySQL-varianten som avslørte lekkasjen.

## Norn

* Codegen leser **databasen**, ikke migrasjonene. Det er med vilje: en kolonne
  lagt til for hånd eller en migrasjon som feilet halvveis skal ikke bli
  usynlig.
* Hver tabell-unit bærer avtrykket til sin egen tabell, manifestet til hele
  skjemaet. Ellers ville en endring i én tabell fått alle filene til å se
  endret ut, og driftmeldingen blitt ubrukelig.
* `WriteSources` rører ikke filer som er uendret, slik at tidsstempler og
  inkrementell kompilering ikke forstyrres.
* Generert kode som skal kompilere: `uses` hører rett etter `implementation`,
  ikke nederst. Det er lett å bomme på når man bygger kildekode som tekst.
* Migrasjoner kjører i transaksjon der dialekten tillater det. MySQL committer
  implisitt ved DDL — si det, ikke lat som noe annet.

## Scheduler, sesjoner, mail, testing

* Scheduleren dytter til køen og utfører aldri noe selv. Ikke «forenkle» det
  til at den kjører jobben direkte — da blir det to utførelsesveier med hver
  sine levetidsregler.
* Neste kjøringstidspunkt regnes i UTC. Lokaltid ville gitt to kjøringer
  eller null ved sommertidsskifte.
* Sesjonens flash er **to** kart: det som kan leses nå, og det som skrives
  for neste request. Ett kart gir enten en flash som aldri forsvinner eller
  en som ikke kan leses.
* `TResponse.WithHeader` lar siste verdi vinne per navn. Flere cookies i
  samme svar går gjennom `AddHeader`/`WithCookie`, som legger til i stedet.
* SMTP krever STARTTLS som standard; klartekst må velges med `smtpPlain`.
  Et oppsett som stille faller tilbake til klartekst er verre enn et som
  stopper og sier fra.
* `AssertArenaStable` varmer opp først. De første rundene vokser alltid; det
  er etter oppvarmingen tallet betyr noe.

## TLS

* OpenSSL lastes med `dlopen`, ikke lenkes inn. Binæren skal starte på en
  maskin uten OpenSSL; en app bak en reverse proxy trenger den aldri.
* **På macOS må OpenSSL installeres selv** (`brew install openssl@3`).
  Systemets libssl er LibreSSL, og Apple blokkerer `dlopen` mot den fra
  tredjeparts binærer — prosessen dør med «loading libcrypto in an unsafe
  way». Det er ikke noe som kan omgås, og feilmeldingen sier det rett ut i
  stedet for å liste stier uten forklaring.
* Derfor: **TLS-testene kjøres i containeren.** Natively på macOS hopper
  suiten over seg selv. Et hopp som ikke sier hvorfor er verre enn en feil.
* Sertifikatet leses i `Start`, ikke ved første håndtrykk, og
  `SSL_CTX_check_private_key` kjøres samme sted. En feilstavet sti eller en
  nøkkel som ikke hører til skal stoppe oppstarten, ikke hver request.
* Håndtrykket skjer i `TWorker.Execute`, før `ServeConnection`. En klient som
  ikke får det til skal koste én lukket socket — ikke en arena og ikke en
  logglinje per request.
* Minsteversjon TLS 1.2, satt med `SSL_CTX_ctrl`. `SSL_CTX_set_min_proto_version`
  er en makro i C og finnes ikke som symbol å binde mot.
* `TTlsConn.Read`/`Write` løkker på `WANT_READ`/`WANT_WRITE` selv om socketen
  er blokkerende: renegotiering kan gi dem likevel.
* Navneoppslag i `Askr.Mail` bruker **begge** funksjonene i `netdb`:
  `GetHostByName` leser `/etc/hosts` og gir adressen i vertens byteorden,
  `ResolveHostByName` gjør DNS og gir den i nettets. Å bomme på det gir en
  adresse som ser gyldig ut og peker feil vei.
* `fpc_run` i `./askr` avbryter ved kompileringsfeil. Uten det kjører neste
  steg videre på forrige binær, og en suite melder grønt på kode som ikke
  kompilerer. Det skjedde, og det kostet en feilsøking av en bug som ikke
  fantes.
* `runtime` må stå i `AskrUnits` i `cli/askr.lpr`. Den manglet fra fase 2 ble
  skrevet til TLS kom, og da `Askr.Http.Server` begynte å bruke `Askr.Tls`,
  sluttet enhver generert app å bygge.

## Kø og cache

* **Tre grenser, alle i rammeverket:** `Cache.Put` og `Queue.Push` kopierer
  ut av kallerens arena; køworkeren kopierer inn i sin egen. Ingen av dem kan
  hoppes over. Rører du dem, kjør arena-testene — de nullstiller arenaen og
  skriver den full av søppel før de leser tilbake.
* `Cache.Get` kopierer **ut** i kallerens arena. Ikke «optimaliser» det til å
  returnere en peker inn i cachen: da kan en eviction etterlate en dinglende
  peker, og verdien ville overlevd requesten.
* Cachen er sharded. Høye hash-bit velger shard, lave velger bøtte — ellers
  havner alt i samme bøtte innenfor sharden.
* En prosedyrevariabel kan ikke castes til `TObject` i Delphi-modus;
  kompilatoren tolker den som et kall. Derfor er handler-tabellen i køen en
  vanlig record-array med lineært søk.

## Desktop

* **`SetExceptionMask` må settes før første Cocoa- *og* GTK-kall.** Free Pascal slår på
  flyttallsunntak; Cocoa og CoreGraphics regner rutinemessig med NaN og
  utløser dem. Det samme gjelder Cairo, GLib og WebKit på Linux. Uten masken
  dør prosessen med `EInvalidOp` i det første vinduet opprettes, og
  stakksporet peker på biblioteker man ikke har skrevet — det ser ut som en
  feil i nettmotoren, ikke som et valg i vår egen runtime. Ikke valgfritt,
  på noen av plattformene.
* **Bruk `gtk_init_check`, aldri `gtk_init`.** `gtk_init` kaller `exit()` når
  det ikke finnes en skjerm, og da forsvinner prosessen uten et ord midt i
  `DesktopApp.Run`. `gtk_init_check` returnerer FALSE, og da kan vi si hva
  som er galt.
* GTK, WebKitGTK, GObject og GLib lastes alle med `dlopen`. Uniten skal
  kompilere på en maskin uten GTK, og en ren webtjeneste skal ikke arve
  avhengigheten. webkit2gtk 4.0 og 4.1 har de samme symbolene vi bruker —
  begge står i kandidatlisten.
* `AutoCloseMs` finnes bare for testene, og bare på Linux (`g_timeout_add`).
  På macOS ville det krevd en NSTimer med en Objective-C-klasse laget i
  runtime — mye maskineri for noe ingen ekte app skal bruke. Derfor hopper
  `askr_desktop_tests` over seg selv på macOS i stedet for å henge på et
  vindu som venter på et klikk.
* `g_signal_connect` er en makro i C. Fra Pascal bindes `g_signal_connect_data`
  direkte. Uten `destroy`-signalet koblet til `gtk_main_quit` henger
  prosessen etter at vinduet er lukket.
* **Windows-skallet er skrevet, men aldri kjørt, og er parkert.** Det er det
  eneste stedet i Askr der det er sant sammen med AI-laget, og det skal stå
  i README — ikke gjemmes bak at koden finnes. Et forsøk på å bygge en win64-kryss-kompilator fra
  Debians FPC-kilder strandet: `crossall` finnes ikke som mål, og `fpcmake`
  genererer ikke `rtl/Makefile` der. Har noen en Windows-maskin, er det den
  neste testen.
* **WebView2s vtable-er telles ikke for hånd.** Metodene deklareres som
  Pascal-interface i `WebView2.h`-rekkefølge, inkludert metoder vi aldri
  kaller, og kompilatoren legger ut vtablen. Kaller man metode 24 i stedet
  for 25, får man en peker som ser gyldig ut — det er den ene feilen som
  ikke sier fra. `tools/probes/webview2_vtable.lpr` sjekker at
  callback-klassene faktisk oppfyller interfacene; den kopien må følge
  originalen når den endres.
* **Les FPCs egne deklarasjoner før du binder Windows-API.** `rtl/win` ligger
  i containeren under `/usr/share/fpcsrc`. Det fanget at `GetMessageW` tar
  meldingen som `var`-parameter, ikke som peker — `@Msg` ville ikke
  kompilert, og det ville ikke vist seg før noen bygde for Windows.
* GTK-imaget (`tools/Dockerfile.gtk`) er separat. WebKitGTK drar inn noen
  hundre megabyte, og `./askr test` skal ikke betale for det — suiten hopper
  over seg selv der biblioteket mangler, og `./askr desktop:linux` kjører det
  ekte.
* Objektet heter `DesktopApp`, ikke `App`. `App.` er navnerommet brukerkoden
  ligger i, og kompilatoren leser `App.UseDatabase` som unit-kvalifikasjon.
* `objc_msgSend` er variadisk i C. Fra Pascal deklareres den flere ganger med
  hver sin signatur mot samme symbol — det er slik ABI-en virker, og det
  eneste som er trygt på arm64.
* `NSRect` er fire doubles og går i SIMD-registre etter AAPCS64. En record av
  fire `Double` treffer riktig; ikke bytt til noe annet.
* Skriver man diagnostikk før `[NSApp run]`, må `Flush(Output)` med. Løkka
  under tømmer aldri bufferet.

## MySQL

* Bindingen går mot **MariaDB Connector/C**, ikke libmysqlclient. Den er
  ABI-kompatibel, finnes i Debian som `libmariadb3` og på Homebrew som
  `mariadb-connector-c`, og snakker med begge serverne. Verifisert mot MySQL
  8.4 med `caching_sha2_password`.
* `TMysqlBind` er **112 bytes**, og layouten er verifisert med `offsetof` mot
  headeren — ikke husket. MariaDB pakker `row_ptr` i en union og kaller
  `param_number` for `flags`; binært er det likevel samme form som MySQLs.
  Assert-en i `initialization` står der for at en endring skal smelle med én
  gang i stedet for i en tilfeldig kolonne.
* **Resultatkolonner må bindes med et ekte buffer, ikke et tomt.** Fristelsen
  er å la `Lens` fortelle lengden i første runde og hente verdien etterpå.
  Det virker for alt serveren sender som tekst — VARCHAR, TEXT, DECIMAL,
  heltall — men en DOUBLE kommer binært over prepared-protokollen, og uten et
  buffer å konvertere inn i settes lengden til null. Resultatet er tomme
  verdier for hver flyttallskolonne, uten en feil noe sted. 192 bytes fast,
  og andre runde bare for det som ikke fikk plass.
* **Les feilkoden fra et statement FØR noe lukker det.** `mysql_stmt_close`
  frigjør errno og sqlstate. Med kallene i motsatt rekkefølge ble hvert
  eneste unik-brudd rapportert som SQLSTATE `00000` — «ingen feil».
* MySQLs SQLSTATE er `23000` for både unik-brudd og fremmednøkkelbrudd.
  Errno skiller dem: 1062 mot 1451/1452. Driveren oversetter til `23505` og
  `23503` slik at resten av Urd ser det samme på tvers av dialekter.
* `mysql_thread_init` kalles én gang per tråd, via en threadvar. Biblioteket
  har tilstand per tråd, og poolen kan gi en forbindelse til en annen tråd
  enn den som åpnet den. `mysql_thread_end` kalles aldri — det finnes ingen
  bærbar måte å henge seg på at en tråd avslutter.
* `CLIENT_FOUND_ROWS` er på. Uten den melder en oppdatering uten faktisk
  endring 0 rader, og kallende kode tror raden er borte.
* **InnoDB overser `REFERENCES` på kolonnen i stillhet.** Skjemabyggeren må
  legge `FOREIGN KEY` på tabellnivå for MySQL — både i `CREATE TABLE` og som
  egen `ALTER TABLE ... ADD` etter `ADD COLUMN`. Tabellen blir opprettet
  uansett, så feilen viser seg først når noe sletter en rad det pekes på.
* Introspeksjonen leser `column_type`, ikke `data_type`. Det er den som
  skiller `tinyint(1)` fra `tinyint(4)`, altså boolsk fra heltall. `datetime`
  måtte inn i `ColAliasFor` eksplisitt — den starter ikke med «time» og falt
  gjennom til tekst.
* Statement-cachen ligger på forbindelsen. Et prepared statement er serverens
  tilstand for én sesjon; en delt cache ville pekt på håndtak i feil sesjon.
  Et statement som feiler kastes ut, fordi det kan være forberedt mot en
  tabell som siden er endret.
* Tegnsettet er `utf8mb4`. MySQLs «utf8» er ikke UTF-8.

## SQLite

* `Timestamps` genererer `CURRENT_TIMESTAMP`, ikke `now()`. `now()` finnes i
  Postgres og MySQL, men ikke i SQLite.
* WAL og `busy_timeout` settes ved oppkobling. Uten dem gir en pool med flere
  workere `SQLITE_BUSY` i stedet for å vente.
* Fremmednøkler håndheves bare med `PRAGMA foreign_keys = ON`.
* `SQLITE_TRANSIENT` (-1) ved binding: uten det måtte parameterbufferet
  overleve til `finalize`, og arenaen spoles ofte før.
* SQLite oppgir ikke radantall på forhånd. Radene samles i en kjede i arenaen
  og `TDbResult` allokeres når tallet er kjent.

## Dev-serveren

* Løkka er målt til 247 ms i snitt. Rører du noe her, mål på nytt — tallet er
  hele grunnlaget for PRD-ens første suksesskriterium.
* Veggklokka for målingen må leses **før** den gamle prosessen drepes. Leses
  den etterpå, havner nedstengingen i tallet selv om ingen venter på den.
* `UnixNow` har sekundoppløsning og duger ikke til å måle løkka. `UnixNowMs`
  finnes, og er samme klokke som filsystemets mtime.
* Filovervåkingen bruker `fpStat` for nanosekund-mtime. `TSearchRec.TimeStamp`
  og `FileAge` har bare sekunder, og to lagringer i samme sekund er vanlig.
* `FSeen` i overvåkeren er sortert for O(log n)-oppslag. `Values` og
  `ValueFromIndex` er ikke lov på en sortert liste — stempelet ligger derfor
  som en hash i `Objects`.
* FPCs RTL holder sin egen kopi av miljøet fra oppstart, så `setenv` når ikke
  barneprosessen. Kompilatorkonfigurasjonen sendes med som `-n @sti/fpc.cfg`.

## Ruting og validering

* Ruter sorteres etter spesifisitet, ikke rekkefølge. Rører du `CompareRoutes`,
  sjekk at `/customers/new` fortsatt slår `/customers/:id`.
* `TRouter.Handle` heter ikke `Dispatch` — det skygger for `TObject.Dispatch`.
* Validering ligger i `Askr.Urd.Model`, ikke i en egen unit. `TModel.Rules`
  trenger `TValidator`, og `TValidator` trenger `TModel`: sirkulært mellom
  units, og Pascal tillater det ikke. Sammenslåingen er prisen.
* Feil nøkles på **kolonnenavnet**, regler skrives med **property-navnet**.
* `Req.FillInto` er en class helper i `Askr.Urd.Bind`. Uten den måtte
  `Askr.Http` kjenne `Askr.Urd`, og det ville bundet desktop-skallet og rene
  JSON-tjenester til datalaget.
* Primærnøkkelen fylles aldri fra en request. Ikke «forbedre» det.
* JSON-kroppen caches per tråd, men cachen kan ikke nøkles på
  request-pekeren alene: arenaen gjenbruker adresser, så neste request lander
  ofte akkurat der forrige lå. `Arena.Defer` rydder den ved `Reset`.

## Inertia

* Versjonen er **Inertia 3**. Payloaden ligger i et script-element, ikke i et
  data-page-attributt. Klienten i 3 leter bare etter script-elementet.
* Inni script-elementet er det JSON-escaping som gjelder: `<` til `\u003c` og
  `/` til `\/`. `HtmlAttrEscape` er feil verktøy der og ville sluppet gjennom
  et `</script>` i en propverdi.
* En relasjon som ikke er lastet **utelates**, ikke settes til null. Frontend
  må kunne skille «ingen ordre» fra «ikke spurt om».
* En omdirigering etter PUT, PATCH eller DELETE må være 303. Med 302 gjentar
  nettleseren metoden mot den nye adressen.
* `Vary: X-Inertia` må med på både HTML- og JSON-svar, ellers cacher
  mellomledd feil svar til feil klient.
* Flash er trådlokal og gjelder **det svaret som bygges nå**. Den overlever
  ikke en omdirigering: de to requestene kan havne på hver sin worker, og
  uten sesjoner finnes det ingen felles lagring. Rendre siden direkte i
  stedet for å omdirigere til den.
* **Vakten foran `flash`-objektet må spørre om det samme som
  `WriteFlashInto` skriver.** Den spurte etter én hardkodet nøkkel —
  `Sess.HasFlash('suksess')` — mens skrivingen tar alle nøkler unntatt
  `_errors`. Alt annet enn den ene nøkkelen ble stille forkastet, og
  `Session.Flash('error', …)` fra auth-stillaset var nettopp et slikt
  tilfelle. `TSession.HasAnyFlash` svarer nå på det samme utvalget. To feil i
  én linje: en norsk nøkkel i rammeverkskode, og en vakt som var smalere enn
  det den voktet. Testen er mutasjonssjekket — settes den gamle vakten
  tilbake, feiler den.

## Fallgruver som allerede er truffet

* `TObject.MethodName` skygger for `Askr.Http.Types.MethodName` inne i
  klasser. Kvalifiser med unit-navn.
* `TObject.Dispatch` skygger på samme vis — derfor heter den
  `TAskrServer.CallHandler`.
* `StrToNetAddr` i FPC returnerer `in_addr` og melder feil med 0.0.0.0, som
  også er en gyldig lytteadresse.
* `clock_gettime` og `sysconf` finnes ikke i FPCs Unix-units. De deklareres
  mot libc, med konstanter som er ulike på Linux og Darwin.
* Identifikatorer må være ASCII. `GLagretLås` kompilerer ikke.
* Klammeparenteser i en Pascal-kommentar åpner en nøstet kommentar. `{{page}}`
  og `{component, props}` i doc-kommentarer må skrives med stjerneform.
* Nøstet spesialisering som typeargument lar seg ikke skrive:
  `A.New<TModelList<TOrder>>` leses som en skiftoperator. Lag et alias.
* `TSchemaBuilder.Create(tabell)` overlaster constructoren. Det virker fordi
  signaturene er ulike, og det er formen PRD-en skriver.
* libpq skriver NOTICE rett til stderr med mindre man setter en egen
  behandler. `SetPgNoticeHandler` finnes; standard er å forkaste dem.
* `TArena.New<T>` skygger for standardprosedyren `New` inne i klassen. 3.2.2
  lot `New(Result)` passere, 3.3.1 gjør det ikke — skriv `System.New`.
* Trunk oppdager at `else` i et `case` over en enum er død når alle verdiene
  er dekket. La være å skrive den: da blir en ny enum-verdi en advarsel om
  uinitialisert resultat i stedet for en stille default.
* FPC leter etter `fpc.cfg` i `~/.fpc.cfg` og `/etc/fpc.cfg` på Unix, ikke ved
  siden av binaeren. fpcupdeluxe legger den ved binaeren — sett
  `PPC_CONFIG_PATH`.
* `TStr.SplitAt` kan ikke ta `Self` som ut-parameter — `Left` skrives før
  `Right` beregnes.
* `SIGPIPE` må ignoreres før serveren starter, ellers dreper en klient som
  lukker tidlig hele prosessen.
* `DownTo` er et reservert ord og kan ikke brukes som parameternavn.
* `IfThen` uten `StrUtils` eller `Math` i uses treffer en generisk deklarasjon
  og gir «Generics without specialization», ikke «unknown identifier».
* **`TStringList.Values[Key] := ''` sletter oppføringen på 3.3.1, men ikke
  på 3.2.2.** Det traff `.env`: en linje som `API_KEY=` forsvant på trunk og
  ble liggende på 3.2.2. Skriv `Key + '=' + Verdi` med `Add` eller direkte
  indeks i stedet. Getteren `ValueFromIndex` er trygg.
* **`Currency(I) * <heltallsliteral>` gir ulikt svar på 3.2.2 og 3.3.1.**
  Med `I = 7` gir `Currency(I) * 100` **700,00 på 3.2.2 og 0,07 på trunk** —
  trunk regner i Currency sin skalerte int64-representasjon og reintepreterer
  resultatet. Dette er penger, og det er stille: ingen advarsel, ingen feil.
  Formene som er like på begge, og som koden skal bruke, er
  `Currency(I * 100)`, `Currency(I) * 100.0` og tilordning til en
  Currency-variabel først. Addisjon og divisjon er upåvirket. Premisstesten
  i SQLite-delen av `askr_tests` holder dette fast.

## Aritmetikk og kontroller

* `./askr check` kjører alle suitene med `-Cr -Co -Ci`. Kjør den når du har
  rørt aritmetikk eller indeksering — den finner ting `./askr test` ikke ser.
* **De fire FNV-hashene er merket `{$push}{$R-}{$Q-}`** (`Askr.Cache`,
  `Askr.Norn.Codegen`, `Askr.Cli.Watch`). FNV-1a er tuftet på at
  multiplikasjonen flyter over; uten merkingen krasjer cachen med
  `ERangeError` i enhver bygging med overflytkontroll — og i en vanlig
  bygging regner den bare videre uten å si fra. Skriver du en ny hash, merk
  den på samme måte.
* Suitene er grønne under `-Cr -Co -Ci`. Slutter de å være det, er det et
  funn, ikke en grunn til å skru av flaggene.

## Testene

`tests/askr_tests.lpr` dekker arena, tekst, HTTP-typer, request-parsing,
respons-serialisering, dato og en ende-til-ende-del over ekte sockets. Den
siste starter serveren på port 0 og leser porten tilbake, så testene kan kjøre
parallelt uten å krangle om porter.

To av testene er premisstester og skal ikke mykes opp: `BytesReserved` skal
flate ut etter oppvarming, både i arenaen alene og over 500 requests gjennom
serveren. Slutter de å holde, er det arena-modellen som svikter, ikke testen.

## Velkomstsiden

* `Askr.Http.Welcome` er det første noen ser av rammeverket. Den skal virke
  **uten npm, uten nett og uten filer ved siden av binæren** — derfor
  systemfonter, inline CSS, ingen skript og ingen eksterne ressurser. Testen
  i `askr_runtime_tests` sjekker nettopp det, inkludert at `http://` ikke
  forekommer i svaret.
* Grunnen til at den finnes: `/` gikk gjennom Inertia, så et nytt prosjekt
  svarte blankt til frontend var installert. Inertia-demoen ligger nå på
  `/demo`.
* Prosjektnavnet er brukerkontrollert og escapes. Det er testet med
  `<script>alert(1)</script>` som prosjektnavn.
* Avlesningen leser `Req.Arena` — `BytesLive`, `HighWaterMark`,
  `BytesReserved`, `ResetCount`. Tallene tas midt i requesten, så etiketten
  sier «så langt i denne requesten», ikke «på denne siden». Ikke gjør den
  påstanden større enn målingen.
* Avlesningen er en `<dl>` med fleksrader, ikke en `<table>`. En tabell har
  en minstebredde som presser hele siden bredere enn en telefonskjerm, og
  det er uansett etikett og verdi, ikke tabelldata.
* Headless Chrome klemmer viewporten til rundt 500 px, så smalere skjermer
  kan ikke skjermdumpes direkte. Legg siden i en `<iframe width="390">` i en
  lokal fil og skjermdump den i stedet.

## Fase 3 og Rún

* **Alle fem portene foran fase 3 er prøvd, og alle fem gikk mot fase 3.**
  Bevisregnskapet ligger i Rún-dokumentet, ikke her.
* **Rún er ute av `spikes/`.** Transpileren er `Askr.Run` i `src/run/`, med
  `Transpile` og `UnitNameFor` som hele det offentlige API-et. `askr build`
  kaller den for hver `*.run` under prosjektets unit-stier og legger
  resultatet i `.build/run/`. `tests/askr_run_tests.lpr` er dekningen og går
  i `./askr test`; `./askr run:demo` kjører kjeden hel i dette repoet.
* **Rún er et tilbud, ikke standardveien.** Urd og Norn er fortsatt datalaget
  en ny app får, og kostnadstallet nedenfor er grunnen. Ingenting ellers i
  `src/` skal avhenge av `Askr.Run`.
* **Som unit må global tilstand nullstilles.** Transpileren var et
  engangsprogram, og prosessen ryddet opp ved å dø. Nå kalles `Transpile` én
  gang per fil i samme prosess, og `Nullstill` kjøres først. Uten den arver
  fil nummer to modellene fra fil nummer én.
* `TRunStats` og `TToken` har strengfelter. `FillChar` over dem er feil
  verktøy — den etterlater en referanse ingen slipper. Sett feltene.
* **Generics er hele poenget.** `query<M> ById(...) -> M for Customer, Order`
  monomorfiseres til `CustomerById` og `OrderById`. Det er svaret på funn 1:
  vi skriver ut de konkrete variantene i stedet for å be FPC om en generisk
  metode den nekter å ta imot.
* **Relasjoner erklæres ikke.** `with orders` slås opp i fremmednøklene fra
  introspeksjonen. Peker `orders.customer_id` på `customers.id`, finnes
  relasjonen. Det er comptime-argumentet i sin reneste form.
* **Radtypene må skrives ut i avhengighetsrekkefølge.** En record kan ikke
  fremoverreferere en annen record i Pascal, så `TOrderRow` må komme før
  `TCustomerRow` når den sistnevnte har et `Orders`-felt. `SorterModeller`
  gjør en dybdeførst-sortering og sier fra ved syklus i stedet for å skjule
  den.
* Eager loading gjør **én** ekstra spørring per relasjon, ikke én per rad.
  Det er forskjellen på `with` og en løkke, og grunnen til at det er verdt
  et eget nøkkelord.
* Det avgjørende tallet: comptime-introspeksjon koster 1–4 ms mot SQLite, men
  **70 ms mot Postgres med 61 tabeller** — mer enn de 53 ms utviklerløkka har
  å gå på. Varianten som passer cacher skjemaet, og et cachet skjema med
  typet utskrift er Norn-codegen.
* Transpileren bruker `Askr.Norn.Introspect`, altså samme kode som Norn. Det
  er med vilje: forskjellen som måles er ikke hvordan skjemaet leses, men når.
* Generert kode skal kompilere uten advarsler. Skriv til en lokal variabel og
  tilordn `Result` til slutt — fpc advarer ellers om uinitialisert resultat
  både for records med strengfelt og for dynamiske arrayer ved `SetLength`.
* Feilfixturene i `tests/run/` skriver DSN-en som `@DB@`. De er fixturer, ikke
  kjørbare filer, og testen setter inn stien til den databasen den nettopp
  bygde. En hardkodet sti her ville knyttet fixturene til et byggkatalognavn.

## Stillaset

* **`askr new` spør om innlogging bare når `IsATTY(Input)` sier at det er en
  terminal.** `--auth` og `--no-auth` svarer for et skript. Uten terminal og
  uten flagg er svaret nei — en kommando som venter på svar fra et rør henger
  for alltid, og et stillas som gjør det, gjør det i CI.
* `askr make auth` gjør det samme i et prosjekt som finnes. `InstallerRuter`
  syr det inn i `app.lpr` ved to markører. Finner den dem ikke — fordi noen
  har endret fila, som de skal kunne — skriver den filene og skriver ut
  linjene som må inn. Å gjette på hvor kode skal inn i en fil noen har
  skrevet selv, er verre enn å spørre.
* Auth-sidene er ren HTML, ikke Inertia. Et nytt prosjekt har Inertia satt
  opp, men ikke installert; å kreve `npm install` før man kan logge inn ville
  gjort innloggingen ubrukelig akkurat i det vinduet der den trengs. Samme
  regel som for velkomstsiden: ingen npm, ingen nett, ingen filer ved siden
  av binæren.
* Malene for lange filer bygges med en lokal `procedure A(const S: string)`
  som legger til i en `TStringList`, ikke med `+ #10 +` i én kjede.
  Pascal-sitering av Pascal-kode som inneholder apostrofer er der feilene
  ligger, og `A('...')` gjør hver linje til én ting å lese.
* `storage/` lages av stillaset (`.gitkeep`, og `storage/*` i `.gitignore`).
  `TLogTransport` og reset-mailen i utvikling skriver dit, og de feiler hvis
  katalogen ikke finnes.

## Forbindelser i en generert app

* **En generert `app.lpr` må sette en forbindelse selv.** Det gjorde den ikke
  før auth-stillaset kom: `CurrentDb` var nil, og alt som rørte databasen i
  en request feilet. Nå lager den en `TDbPool` og låner én per request.
* **Bruk `Acquire`/`Release`, ikke `Lease`, i en middleware.**
  `Pool.Lease(A)` leverer forbindelsen tilbake via `A.Defer`, og workerens
  arena nullstilles **først når neste request kommer inn på den workeren** —
  den blokkerer i `Fill` på keep-alive-socketen i mellomtiden, med
  forbindelsen i hånda. Med flere workere enn forbindelser i poolen låser det
  seg, og feilen er `EDbPoolError: No free database connection` et helt annet
  sted enn årsaken. `Lease` er riktig inne i en handler som kjører ferdig;
  den er feil som livssyklus for requesten.
* Derfor `R.Use(@LeaseDb)` og `R.After(@ReleaseDb)` i malen. `ReleaseDb`
  tåler at `CurrentDb` er nil — en request som aldri nådde `LeaseDb` skal
  ikke krasje på vei ut.

## Lauf

Frontend-biblioteket i `frontend/lauf/`. Konseptet og rekkefølgen står i
`LAUF.md`; her er bare det man må vite for å endre koden.

* **Lauf er frontendlaget, ikke et tillegg.** `askr new` setter det opp:
  package.json, Tailwind, `app.css` med tokens og `@source`, en Layout med
  `<Flash />`, og en Home-side skrevet i Lauf.
* **Ingenting i `src/` får likevel avhenge av Lauf.** Samme regel som for
  `Askr.Run`, og den er uendret. Velkomstsiden og auth-stillaset skal
  fortsette å virke uten npm, uten nett og uten filer ved siden av binæren —
  det er testet, og det er ikke en tilfeldighet. «Frontendlaget» handler om
  sidene appen bygger, ikke om at binæren slutter å svare alene.
* **`askr new` skriver `file:`-stien til rammeverket**, fordi `@askrcode/lauf`
  ikke er publisert. Den kommer fra samme `Rammeverk` som askr.toml bruker.
  Når pakken publiseres, er det én linje i `Askr.Cli.Scaffold` som endres.
* **En `file:`-avhengighet krever `resolve.dedupe`** på `svelte`,
  `@inertiajs/svelte` og `@inertiajs/core` i den genererte vite.config.
  Uten den får appen og Lauf hver sin kopi. Malen har den.
* **Askr er MIT.** `LICENSE` i rota, og en kopi i `frontend/lauf` fordi npm
  forventer den i pakka. Ikonene under `src/icons/` er kopier av
  Heroicons-grafikk og ligger inne i tarballen, så Heroicons' opphavsvarsel
  må reise med dem — det står i `frontend/lauf/NOTICE.md`, som er med i
  `files`. Legger du inn noe annet som *kopieres* inn i pakka, hører varselet
  hjemme der.
* **`publishConfig.access` må være `public`.** Et scopet navn er
  «restricted» som standard, og en restricted pakke krever betalt konto —
  første publish feiler med 402 uten den.
* **Laufs ikoner er ikke i git.** Et rammeverk som er sjekket ut på nytt må
  kjøre `npm install` i `frontend/lauf` én gang, ellers feiler en generert
  app på at `@askrcode/lauf/icons/micro` ikke finnes. `askr new` sier fra når
  katalogen mangler.
* Porten er `./askr lauf`, ikke `./askr test`. Den hopper over seg selv når
  `node` mangler, på samme måte som desktop-suiten uten GTK. `./askr test`
  skal ikke kreve npm.
* **Ingen komponent skriver `dark:`.** Tokenene i `src/theme.css` er
  semantiske, og mørk modus redefinerer dem ett sted. Tre tilstander, ikke
  to: media-blokka er vernet med `:root:not([data-theme="light"])`, og
  `[data-theme="dark"]` gjentas etterpå slik at en bryter vinner begge veier.
  En farge som bare finnes inne i én av blokkene, finnes ikke i den tredje
  tilstanden.
* **Alt som tar imot `class` må gjennom `cn()`, med kallerens klasse sist.**
  Tailwind-klasser har lik spesifisitet, så rekkefølgen i stilarket avgjør,
  ikke rekkefølgen i attributtet. Uten den kan ingen app overstyre noe, og
  symptomet er at `class` «ikke virker».
* **Ikoner er komponenter, ikke navn.** Et navn må slås opp i et kart, og et
  kart holder alle 1288 i bunten. `tests/tree-shaking.test.js` er en
  premisstest på nettopp det og skal ikke mykes opp.
* De genererte ikonene sjekkes **ikke** inn — avvik fra Norn, med vilje:
  1288 filer ville gjort enhver diff uleselig, og de er en mekanisk kopi av
  noe som allerede ligger i `node_modules`.
* **`vite.build()` laster `vite.config.js` av seg selv.** Sender man i
  tillegg inn `plugins: [svelte()]`, kjører pluginen to ganger, og den andre
  runden får kompilert JS der den venter Svelte-kilde. Feilen er
  «Expected token }» i en komponent som varierer mellom kjøringer, og peker
  ingen vei. `configFile: false`.
* Testfila som bygger med Vite må ha `// @vitest-environment node`. esbuild
  nekter å starte i jsdom, fordi jsdoms `TextEncoder` ikke gir en ekte
  `Uint8Array` tilbake.
* **`vite.config.js` sin `resolve.conditions` erstatter standardlista, den
  legger ikke til.** Bare `['browser']` gjør at vanlige pakker ikke lar seg
  løse i det hele tatt, og feilen er «No known conditions for "." specifier».
  `['svelte', 'browser', 'import', 'module', 'default']`.
* **`router[verb](...)`, aldri `const f = router[verb]; f(...)`.** Inertias
  routermetoder kaller `this.visit()`, så en løsrevet referanse feiler med
  «Cannot read properties of undefined (reading 'visit')» — en melding som
  ikke nevner mottakeren. Mocken i `tests/form.test.js` bruker `this` med
  vilje, nettopp for å kunne fange det; med frie funksjoner slapp den
  gjennom.
* **En app som bruker Lauf fra en symlink (`file:`, `npm link`) må dedupe**
  `svelte`, `@inertiajs/svelte` og `@inertiajs/core` i sin vite.config.
  Ellers har appen og Lauf hver sin kopi, `createInertiaApp` setter opp en
  annen router enn den `<Form>` importerer, og ingenting sier fra. Det kuttet
  dessuten demoens bunt fra 300 til 218 kB. Fra npm skjer det ikke.
* **`<Form>` ligger i `@askrcode/lauf/inertia`, ikke i hovedinngangen.** Den
  er den eneste komponenten som importerer Inertia, og ESM løser importen
  ved bygging — lå den i `index.js`, måtte en ren JSON-tjeneste installere
  Inertia for å få en knapp.
* Tailwind v4 ser ikke inn i `node_modules`. En app må ha
  `@source '../node_modules/@askrcode/lauf/src'`, ellers kommer komponentene
  ut uten styling og ingenting sier hvorfor.
* **axe kan ikke måle kontrast i jsdom.** Regelen er slått av i
  `tests/axe.js` med begrunnelse, ikke i stillhet. Kontrast må sjekkes i en
  ekte nettleser.
* **`Object.assign` på modulnivå må merkes `/*#__PURE__*/`.** Det er slik
  `Button.Group` og `Table.Cell` henges på, og en bundler kan ikke bevise at
  et kall som muterer sitt første argument er trygt å fjerne. Uten merkingen
  holder barrel-fila hele biblioteket i live: en enkelt `<Button>` kostet
  221 kB i stedet for 74 da Bits UI kom inn under sju komponenter.
  `"sideEffects"` i package.json er den andre halvdelen.
* **Alt som åpner og lukker seg ligger på Bits UI**, og Bits skal aldri
  lekke ut i Laufs offentlige API. Ingen app importerer fra `bits-ui`.
* **Bits setter ikke `aria-controls` på trekkspill**, bare på faner.
  `AccordionItem` lager id-en selv og kobler begge veier. Der Bits er
  ufullstendig, er det lag 3 som fyller ut — det er hele grunnen til at
  laget finnes.
* En menyoverskrift må ligge inne i `DropdownMenu.Group`; Bits kaster ellers
  «Context not found». Derfor `Dropdown.Group label=…` og ingen løs
  `Dropdown.Heading`.
* **Fokusfelle, rullelås, flytende plassering og «Escape gir fokus tilbake»
  kan ikke testes i jsdom.** Det finnes ingen layout der. De sjekkes ved å
  drive en ekte Chrome over CDP mot demoen og mot lekegrinda
  (`./askr lauf:play`) — tolv Tab-trykk i en åpen modal skal ikke slippe
  fokus ut.
* **`tests/setup.js` må vernes med `typeof Element !== 'undefined'`.**
  Setup-fila kjører også for premisstesten, som går i node-miljø fordi
  esbuild nekter å starte i jsdom. Uten vakten feiler hele den fila på en
  ReferenceError som ikke nevner miljøet med et ord.
* **`./askr lauf:check` er den eneste som måler kontrast.** Hele axe kjøres
  i en ekte Chrome, i seks kombinasjoner: lys, mørk via
  `prefers-color-scheme` og mørk via `data-theme`, hver på 390 og 1280 px.
  Den sjekker også at bakgrunnen faktisk endrer seg mellom temaene — uten
  den kontrollen kunne alle tre vært like og kontrasten likevel grønn.
* **`<label for>` binder bare mot «labelable» elementer** — input, select,
  textarea og noen få til. En `<span role="slider">` er ikke en av dem, og
  trenger `aria-labelledby` mot etikettens id. Derfor eksponerer
  `Field`-konteksten `labelId`. Det var ett av tre brudd nettleserporten
  fant og jsdom-suiten ikke så.
* **Ikke skriv pure-annotasjonen i klartekst i en linjekommentar.** Rollup
  leser den som en ekte annotasjon på feil plass og advarer om at den
  fjernes — en advarsel som ser ut som at merkingen din er ødelagt.
* **En stub er ikke en måling.** `ResizeObserver`, `matchMedia`,
  pekerfangst og `scrollIntoView` stubbes fordi jsdom mangler dem, og da
  kan koden kjøre — men ingenting som avhenger av faktiske størrelser er
  dekket. Det hører hjemme i nettleseren.
* **Nøkler i `{#each}` må være unike, og datoer gjentar seg.** Smale
  ukedagsnavn er «S M T W T F S», og «MM/DD/YYYY» har to segmenter med
  `part === 'literal'`. Nøkle på indeks der.
* **`bind:value` mot `undefined` er en feil** når mottakeren har en egen
  fallback — Bits' `Command` har det. Bruk `value` og `onValueChange`.
* **Laufs datoer er ISO-strenger utad.** `@internationalized/date` skal
  ikke lekke ut i API-et, like lite som resten av Bits. `DateTimeToSql` i
  Pascal gir `YYYY-MM-DD`, og det er formen som skal gå rett inn og rett ut.
* Bits' `Command` filtrerer på `value` og `keywords`, ikke på teksten i
  elementet. `CommandItem` legger derfor `label` i `keywords` selv.

## DataGrid

* **Serversiden er `Askr.Urd.Grid`, ikke Lauf.** Sortering, søk og
  paginering skjer i databasen. Klientmodus finnes for noen tusen rader og
  er ikke standarden.
* **`Sortable` er hvitelisten, og typene håndhever den.** `OrderBy` tar en
  `TCol`, ikke en streng, så `'ORDER BY ' + parameter` lar seg ikke skrive.
  En ukjent kolonne faller tilbake til standarden i stillhet — en gammel
  bokmerket URL skal ikke velte siden.
* **`Count` må kjøres før siden hentes.** Den bygger sin egen
  `SELECT count(*)` og ser bort fra limit og offset, men gjør man det
  motsatt, teller man raden på siden.
* **Det klienten ber om holdes for seg fra standarden.** `PerPage` etter
  `Read` overskrev `per` fra URL-en, altså endret kallrekkefølgen
  oppførselen i stillhet. `EffectivePer` slår dem sammen først når siden
  hentes.
* **`TQuery.WhereAnyLike` er den eneste OR-en i datalaget**, og den er
  smal med vilje: én operator, én gruppe, ingen nøsting. Parentesen rundt
  gruppa er det som betyr noe — uten den binder et `Where` som står fra
  før seg til bare første ledd, og søket lekker rader.
* **`ILike` oversettes til `LIKE` utenfor Postgres.** SQLite har ingen
  ILIKE i det hele tatt. `LIKE` er ufølsom der fra før, men bare for
  ASCII — «é» og «É» er fortsatt forskjellige.
* **`TJsonWritable` i `Askr.Core.Json` er festet for egne props.** Inertia
  skal ikke lære seg hver type som kan være en prop; lista der skal ikke
  vokse.
* **`aria-rowindex` er radens plass i hele settet**, ikke i siden eller i
  det virtualiserte vinduet. Det er hele grunnen til at attributtet finnes.
* Svelte-lintern advarer om `tabindex` på `td` og `span`, fordi den ikke
  ser `role="grid"`. Der er det mønsteret som krever det. Advarselen er
  slått av på hvert enkelt sted med begrunnelsen ved siden av.

## Neste steg

Fase 1 og fase 2 er ferdige på macOS og Linux. Fase 3 er **avgjort på
bevisene, og påbegynt**: alle fem portene er prøvd, alle fem gikk mot å bygge
et eget språk, og Rún v0.1 er nå en del av verktøykjeden med `Askr.Run`,
`askr build` og en egen suite i porten. Språket er fortsatt v0.1 — det dekker
select med filtre, sortering, grenser og eager loading, og ingenting mer.

**Windows er parkert.** Bindingen er skrevet og typesjekket, men ingen har
startet den på en Windows-maskin, og den regnes ikke som ferdig før noen har
gjort det. Ikke bygg videre på den i mellomtiden — det neste steget der er en
kjøring, ikke mer kode. `tools/probes/webview2_vtable.lpr` kjøres av
`./askr test` nettopp for at den parkerte koden skal fortsette å kompilere;
parkert kode som ikke bygges, råtner.

**Laget utenfor PRD-en**, som kom av `LARAVEL.md`, er gjennomgått i sin
helhet: `.env`, krypto, CSRF, auth, filopplasting, konfigurasjon, logging,
varig kø, modell-livskvalitet, HTTP-klient, AI, kommandolinja og
auth-stillaset. Ingenting i «stopper produksjon»-tabellen står åpent.

**To ting er skrevet og aldri kjørt**, og begge skal stå slik til noen har
gjort det: Windows-webviewen, og AI-laget med en gyldig API-nøkkel. Det er
de eneste to stedene i Askr der det er sant.

Rekkefølgen videre og begrunnelsene står i LARAVEL.md, ikke her.

Datalaget er komplett for alle tre dialektene: drivere, introspeksjon,
migrasjoner og prepared statements med cache. Cachen hører til **steg 2** i
PRD-en, ikke til fase 2 — den ble bare stående igjen til etter at fase 2 var
ferdig. MySQL står ikke i PRD-en i det hele tatt; den kom inn etterpå.
