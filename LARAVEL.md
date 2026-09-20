# Askr målt mot Laravel

Arbeidsnotat, ikke markedsføring. Hensikten er å vite hva som faktisk mangler
før noen bygger på det, og å si fra der det å kopiere Laravel ville vært feil.

Én ting må sies med én gang: **«all funksjonalitet Laravel har» er ikke en
oppgave, det er et program.** Laravel er femten år og flere hundre bidragsytere.
Lista under er sortert etter om du kan sette noe i produksjon uten den, ikke
etter hvor morsom den er å skrive.

## Det som allerede står

Verifisert i koden, ikke husket.

| Laravel | Askr | Hvor |
|---|---|---|
| Routing med parametre | ja | `Askr.Http.Router` |
| Navngitte ruter | ja | `AsName` |
| Middleware | ja, men bare globalt | `TMiddleware`, `R.Use` |
| Controllers | ja | brukerkode |
| Eloquent-modeller | ja | `Askr.Urd.Model` |
| Query builder | ja, typet ved kompilering | `Askr.Urd.Query` |
| Relasjoner + eager loading | HasMany, BelongsTo | `Preload` |
| Validering | ja, på modellen | `TValidator` |
| Soft deletes | ja | `S.SoftDeletes` |
| Tidsstempler på modellen | ja, i UTC | `S.Timestamps` |
| Modellhendelser | ja, virtuelle metoder | `BeforeSave`, `AfterDelete`, … |
| Query scopes | ja — en funksjon som gir en query | brukerkode |
| Migrasjoner + schema builder | ja | `Askr.Norn` |
| Flere databaser | Postgres, MySQL, SQLite | `Askr.Urd.*` |
| Prepared statements med cache | ja, alle tre | — |
| Paginering | ja | `TQuery.Paginate` |
| Transaksjoner | ja | driverne |
| Kø | ja, i prosessen eller i databasen | `Askr.Queue`, `Askr.Queue.Db` |
| Cache | ja, sharded LRU i prosessen | `Askr.Cache` |
| Scheduler | ja | `Askr.Scheduler` |
| Sesjoner med flash | ja | `Askr.Session` |
| Mail | ja, SMTP med STARTTLS | `Askr.Mail` |
| Testing | ja, eget rammeverk | `Askr.Testing` |
| CSRF-beskyttelse | ja, på som standard i nye prosjekter | `Askr.Csrf` |
| Passordhashing | ja, PBKDF2-HMAC-SHA256 | `Askr.Core.Crypto` |
| Autentisering | ja, med «husk meg» | `Askr.Auth` |
| Autorisasjon | gates (ikke policies) | `Askr.Auth` |
| Auth-stillas (Breeze) | ja, ren HTML: login, register, reset | `askr new --auth`, `askr make auth` |
| `.env` | ja | `Askr.Core.Env` |
| Flere `Set-Cookie` | ja | `TResponse.WithCookie` |
| Filopplasting | ja, `multipart/form-data` | `Askr.Http.Multipart` |
| Konfigurasjon | ja, fire lag | `Askr.Core.Config` |
| HTTP-klient | ja, med TLS-verifisering og strømming | `Askr.Http.Client` |
| AI | tekst, strømming, verktøy, strukturert | `Askr.Ai` |
| Logging | ja, nivåer og JSON | `Askr.Core.Log` |
| Artisan | 22 kommandoer, se README | `cli/askr.lpr`, `Askr.Console` |
| migrate:status/rollback/fresh/refresh/reset | ja | `Askr.Console` |
| db:seed, db:show, db:table, db:wipe | ja | `Askr.Console` |
| queue:work, schedule:list/run, cache:clear | ja | `Askr.Console` |
| down / up (vedlikehold) | ja, 503 med Retry-After | `UseMaintenance` |
| make:seeder, make:job, make:middleware | ja | `askr make` |
| Inertia | ja, versjon 3 | `Askr.Inertia` |
| HTTPS | ja | `Askr.Tls` |

Og to ting Laravel ikke har: **én binær uten sidecars**, og **arena per
request** med målt flat hukommelse.

## Det som mangler, og som stopper produksjon

Dette er ikke en ønskeliste. Uten disse er rammeverket enten utrygt eller
ubrukelig til vanlige oppgaver.

Med **varig kø** er tabellen tom. Alt som stoppet produksjon er på plass.

`Askr.Queue.Db` legger jobbene i databasen appen allerede har — ingen Redis,
ingen supervisor. `TQueue` og workerne er uendret; det eneste som byttes er
hvor jobbene ligger, og det er med vilje: et eget løp for varige jobber
ville gitt to sett regler for backoff og forsøkstelling.

Det som er verdt å vite:

* **Payloaden er tekst**, i praksis JSON. Rå bytes avvises ved `Push` i
  stedet for å bli stille ødelagt av en TEXT-kolonne.
* **En jobb som gir opp flyttes til `askr_failed_jobs`**, den slettes ikke.
  Den er det eneste sporet av at noe skulle ha skjedd og ikke gjorde det.
  `RetryFailed` legger dem tilbake. Det samme gjelder en jobb uten
  registrert handler — i minnekøen forsvinner den.
* **En forlatt reservasjon slippes etter fem minutter.** Dør prosessen midt
  i en jobb, blir den ellers liggende reservert for alltid.
* `FOR UPDATE SKIP LOCKED` i Postgres og MySQL, umiddelbar transaksjon i
  SQLite. Testet med 200 jobber og seks workere mot begge serverne: ingen
  jobb kjørte to ganger, ingen ble hoppet over.

Det som **ikke** ble kopiert: Horizon. Et statusendepunkt i appen gir det
samme uten en app til å drifte, og «ingen sidecars» er et PRD-prinsipp.

**Konfigurasjon og logging** er krysset av.

* `Askr.Core.Config` legger fire lag over hverandre: miljø, `.env`,
  `askr.toml`, standardverdi. `app.port` slås opp som `APP_PORT`, og
  miljøet vinner alltid. `askr config` viser hva som faktisk gjelder og
  hvorfra — uten verdier med mindre noen ber om dem, og aldri for nøkler
  som ser ut som hemmeligheter.
* `Askr.Core.Log` har nivåer, felter og to formater: tekst i et
  terminalvindu, JSON-linjer i produksjon. Tall står usitert i JSON, fordi
  `"ms":"12"` ikke lar seg aggregere. Rammeverkets egne stderr-skrivinger
  går nå gjennom den.
* Det som **ikke** ble kopiert fra Laravel: et `config/`-katalog med filer
  per emne. Askr-units tar allerede typede options-records
  (`TServerOptions`, `TSessionStore.Create`), og en strengnøklet
  `config('mail.from')` ville vært et steg ned fra noe kompilatoren
  sjekker. Konfiglaget er til verdier som kommer utenfra, ikke til å
  erstatte parametre.

**Filopplasting** er krysset av. `Askr.Http.Multipart` deler kroppen uten å
kopiere noe: hver del er et `TStr`-utsnitt inn i lesebufferet som uansett
måtte lese bytene. To ting som er valg:

* **Taket er `MaxBodyBytes`**, 8 MB som standard. Hele opplastingen må få
  plass i minnet på én gang. Det holder for vedlegg, profilbilder og
  CSV-import; det holder ikke for video. Å laste opp noe som ikke får plass
  i minnet krever at kroppen strømmes til disk mens den leses, og det er en
  annen form enn «kroppen er ett utsnitt».
* **Klientens filnavn når aldri filsystemet.** `StoreIn` lagrer under et
  tilfeldig navn med den sanerte endelsen; det opprinnelige navnet ligger i
  `ClientName` hvis appen vil ta vare på det. `SaveAs` skriver dit du sier,
  og da er stien appens ansvar. Verifisert med en ekte curl-opplasting av
  `../../onde navn.BIN`.

Tabellen for de tre foregående postene — **CSRF**, **passordhashing**,
**autentisering** og **autorisasjon** — henger sammen, og de ble gjort
samlet. Det som ble bygget, og det som bevisst ikke ble det:

* **Passordhashen er PBKDF2-HMAC-SHA256, ikke Argon2id.** Ren Pascal, ingen
  OpenSSL — binæren skal starte på en maskin uten den. OWASP regner PBKDF2
  med 600 000 iterasjoner som forsvarlig, men Argon2id er det anbefalte i
  2026 fordi det også koster minne. libcrypto har Argon2 fra 3.2; Debian
  bookworm har 3.0, og på denne maskinen finnes ikke OpenSSL i det hele
  tatt. Argon2id ville altså ikke kunne kjøres i noen av testmiljøene, og
  utestet kode som hasher passord er verre enn ingen.
* **Alt er målt mot offisielle vektorer.** NIST FIPS 180-4 for SHA-256,
  RFC 4231 for HMAC, RFC 6070 for PBKDF2, RFC 4648 for base64. En SHA-256
  med feil byterekkefølge er stabil, konsistent og verdiløs, og ingenting i
  en app ville sagt fra.
* **Innlogging bytter sesjons-id.** Uten det er session fixation åpen. Det
  er én linje, og det finnes en test som feiler hvis noen fjerner den.
* **«Husk meg» er en signert kake, ikke et token i databasen.** Den kan
  derfor ikke trekkes tilbake enkeltvis. Å kunne det krever en kolonne per
  bruker, og rammeverket kan ikke vite hvilken tabell den skulle ligge i.
* **Gates, ikke policies.** Policies er Laravels konvensjon over
  refleksjon — klassenavn som slås opp i runtime. En gate er en funksjon
  med et navn, og kompilatoren kan se den.
* **Askr eier ikke brukermodellen.** Rammeverket lagrer en id som tekst;
  appen registrerer en loader. En `TUser` fra rammeverket ville tvunget
  fram et skjema, og det første enhver ekte app trenger er en kolonne til.

## Det som mangler, og som er ekte savn

| Mangler | Notat |
|---|---|
| Middleware per rute og gruppe | Finnes bare globalt i dag. Etterfiltre (`TRouter.After`) kom med sesjonene og er også globale. |
| Rutegrupper med prefiks | Må skrives ut for hånd. |
| Rate limiting | Bygger på cachen, som finnes. |
| Casts og accessors | Typene er allerede statiske; behovet er mindre enn i Laravel. |
| Seeders og factories | Testene bygger data for hånd i dag. |
| Hendelser og lyttere | — |
| Varsler | Bygger på mail og kø, begge finnes. |
| Filsystem-abstraksjon | Lokal og S3. HTTP-klienten finnes nå; det som mangler er signeringen (AWS SigV4). |
| Signerte URL-er | Halvveis: `Sign`/`Unsign` finnes i `Askr.Core.Crypto`, men ingen URL-hjelper bruker dem ennå. |
| Kryptering | `Crypt::encrypt` har ingen motpart. Appnøkkelen finnes, men det er bare signering — ingen AES. |
| Lokalisering | Ironisk nok, rett etter at alt ble engelsk. |
| Serverside-maler | Inertia dekker sider; e-post bygges med strengkonkatenering. |
| Websockets og broadcasting | Stort. Krever oppgradering i HTTP-serveren. |

## Det som ikke bør kopieres

Dette er den viktigste delen av notatet. En sammenligning som bare teller
funksjoner ender med å kopiere PHP-idiomer inn i et kompilert språk der de
koster mer enn de gir.

* **Service container og facades.** Laravels container lever av dynamisk
  oppslag og autowiring gjennom refleksjon. I Pascal blir det seremoni uten
  gevinst: du må registrere alt for hånd, og kompilatoren kan allerede si fra
  om en avhengighet mangler. Bruk vanlige parametre og de omgivende verdiene
  (`UseDb`, `UseArena`) som allerede finnes.
* **Eloquents magi.** Dynamiske attributter og `__get` er umulig og uønsket.
  Askrs typede kolonner fanger `Where(Customers.Email, Eq, 42)` ved
  kompilering — det er bedre enn det Laravel kan gi, ikke dårligere.
* **Tinker.** Krever en tolk for Pascal-uttrykk. Allerede utsatt, med vilje.
* **Horizon og Telescope som egne apper.** «Ingen sidecars» er et
  PRD-prinsipp. Innebygde endepunkter for kø- og requeststatus gir det samme
  uten en app til å drifte.
* **Blade.** Inertia er valgt. En liten maltolk for e-post er et reelt behov,
  men en full templating-motor til sider er det ikke.

## AI som del av rammeverket

Laravel har siden 2026 en førsteparts AI SDK (`composer require laravel/ai`):
tekstgenerering med streaming, strukturert utdata, agenter med verktøykall og
minne, bilder, lyd, transkripsjon, embeddings, reranking og vektorlager for
RAG — pluss fakes til testing av alt sammen.

Det er mye. Det som faktisk bærer for Askr, i denne rekkefølgen:

| Del | Status |
|---|---|
| ~~**HTTP-klient**~~ | **Ferdig.** `Askr.Http.Client`, med sertifikatsjekk, omdirigering, chunked og strømming. |
| ~~**Tekstgenerering**~~ | **Ferdig.** `Ask` og `Send` mot `POST /v1/messages`. |
| ~~**Streaming**~~ | **Ferdig.** SSE, med en callback som kan si stopp. |
| ~~**Verktøykall**~~ | **Ferdig.** Pascal-funksjoner som verktøy, med løkka rundt. |
| ~~**Strukturert utdata**~~ | **Ferdig** — gjennom et verktøy med `tool_choice`, ikke `output_config`. Den formen virker på tvers av modeller og kan ikke svare med prosa ved siden av. |
| ~~**Fakes til test**~~ | **Ferdig.** `TFakeAiTransport` holder requestene og gir svar som er lagt inn på forhånd. |
| **Embeddings og vektorsøk** | Ikke gjort. Postgres har `pgvector`, SQLite har ikke — det blir det første stedet datalaget må si «bare Postgres». |

To valg som må tas bevisst:

* **Ingen offisiell SDK for Pascal.** Bindingen blir rå HTTP mot
  `POST /v1/messages`. Det er dokumentert og stabilt, men det betyr at vi
  eier serialiseringen selv — `Askr.Core.Json` finnes og duger.
* **Standardmodellen er `claude-opus-5`.** Ikke fordi den er billigst, men
  fordi modellvalg er brukerens avgjørelse, ikke rammeverkets. `claude-sonnet-5`
  og `claude-haiku-4-5` er der for den som vil ned i pris.

Nøkler leses fra miljøet, aldri fra kildekoden — som gjør `.env` til en
forutsetning, ikke en bekvemmelighet.

## .env

Laravel leser `.env` før noe annet og eksponerer det med `env()` og
`config()`. Askr har ingenting: `askr.toml` leses av CLI-en, ikke av appen,
og appene leser miljøvariabler ad hoc med `GetEnvironmentVariable`.

Reglene som gjelder:

* **Ekte miljøvariabler vinner over `.env`.** Det er slik alle andre gjør
  det, og det er det som gjør at produksjon kan sette verdier uten en fil.
* **`.env` sjekkes aldri inn.** `.env.example` gjør det.
* **Verdier logges aldri.** En feilmelding sier hvilken nøkkel som manglet,
  aldri hva den inneholdt.

## Rekkefølgen jeg foreslår

0. ~~**`.env` og konfigurasjon**~~ — `Askr.Core.Env`. **Gjort.**
1. ~~**Kryptografisk grunnmur**~~ — `Askr.Core.Crypto`. **Gjort.**
2. ~~**CSRF**~~ — `Askr.Csrf`, på som standard i `askr new`. **Gjort.**
3. ~~**Autentisering og autorisasjon**~~ — `Askr.Auth`. **Gjort.**
   Stillaset kom etterpå: `askr new --auth` og `askr make auth` genererer
   `/login`, `/register`, `/logout` og passordtilbakestilling inn i
   prosjektet, altså Laravel Breeze uten en pakke. Sidene er ren HTML,
   fordi `npm install` ikke skal stå mellom et nytt prosjekt og det å
   kunne logge inn.
4. ~~**Multipart og filopplasting**~~ — `Askr.Http.Multipart`. **Gjort.**
5. ~~**Konfigurasjon og logging**~~ — `Askr.Core.Config`, `Askr.Core.Log`. **Gjort.**
6. ~~**Varig kø**~~ — `Askr.Queue.Db`. **Gjort.**
7. ~~**Modell-livskvalitet**~~ — soft deletes, tidsstempler, hendelser, scopes. **Gjort.**
8. ~~**HTTP-klient**~~ — `Askr.Http.Client`. **Gjort.**
9. ~~**AI**~~ — `Askr.Ai`. **Gjort**, med ett forbehold: se under.

Punkt 1 til 3 ble gjort samlet, som planlagt: CSRF trenger
konstanttidssammenligning og et tilfeldig token, og innlogging trenger
passordhashing. Bygget man CSRF først, ville primitivene blitt skrevet to
ganger.

**Ingenting stopper produksjon lenger.** Det som står igjen er
livskvalitet og rekkevidde, ikke sperrer.

**Hele lista er gjennomgått.** Det som står igjen er ikke sperrer, og det
er ingen selvfølgelig neste post.

**Forbeholdet på punkt 9:** ingen kall med en gyldig nøkkel er gjort fra
dette repoet. Det som *er* prøvd mot `api.anthropic.com` er et ekte kall
uten nøkkel, som kom tilbake som 401 med Anthropics egen feil-JSON, riktig
parset. Det beviser DNS, TLS, requestformen og feilhåndteringen — ikke at
et svar med innhold kommer tilbake. Resten er testet mot en fake som
holder JSON-en opp mot det den skal være. Det er det samme forbeholdet som
på Windows-skallet.

**Det som ligger nærmest nå**, i den rekkefølgen de er verdt noe:

1. **Kjøre AI-laget med en ekte nøkkel.** Det er en kjøring, ikke mer kode.
2. **Embeddings og vektorsøk**, som er det første stedet datalaget må si
   «bare Postgres».
3. **Middleware per rute og gruppe**, som er den eldste posten i tabellen
   over ekte savn.
4. **Filsystem-abstraksjon mot S3.** HTTP-klienten finnes; det som mangler
   er SigV4-signering, og `HmacSha256` er der.
5. **Windows.** Fortsatt en kjøring, ikke mer kode.

To ting fra punkt 7 ble **ikke** gjort, med vilje:

* **Casts og accessors.** Typene er allerede statiske — en `Currency` er en
  `Currency` hele veien. Laravels casts finnes fordi PHP-verdier fra
  databasen er strenger; det problemet har ikke Askr.
* **Seeders og factories.** Testene bygger data for hånd i dag, og det
  leses greit. Et factory-lag uten refleksjon blir mest seremoni.
