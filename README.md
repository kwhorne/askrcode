# Askr

Applikasjonsrammeverk i Pascal-tradisjonen som gir Rails- og Laravel-ergonomi
på en kompilert stakk. Én binærfil, ingen sidevogn, og lav ressursbruk som noe
man får gratis mens man jobber like raskt som i PHP eller Ruby.

Dette repoet er rammeverket. Se PRD-en for hele bildet.

## Status

**Fase 1 og fase 2 er ferdige** på macOS og Linux.

Desktop-skallet er verifisert ved å kjøre det begge steder.
**Windows er parkert:** bindingen er skrevet og typesjekket, men ingen har
startet den på en Windows-maskin, og den regnes ikke som ferdig før noen har
gjort det. Se forbeholdet under Desktop.

TLS dekker både HTTPS i web-skallet og STARTTLS i e-posten, men forutsetter
OpenSSL på maskinen; på macOS må den installeres selv.

| Steg | Innhold | Status |
|---|---|---|
| 1 | Arena og HTTP-vert | ferdig |
| 2 | Query builder — Postgres, MySQL, SQLite | ferdig, alle tre |
| 2 | Prepared statements med cache | ferdig, alle tre |
| 3 | Migrasjoner og Norn-codegen | ferdig, alle tre |
| 4 | Inertia-responser og Svelte-adapter | ferdig |
| 5 | Ruting, kontrollere, validering | ferdig |
| 6 | `askr new` og dev-server med hot reload | ferdig |

| Fase 2 | Innhold | Status |
|---|---|---|
| | SQLite-adapter | ferdig, med introspeksjon |
| | MySQL-adapter (utenfor PRD-en) | ferdig, med introspeksjon |
| | Webview-vert — macOS (WKWebView) | ferdig |
| | Webview-vert — Linux (WebKitGTK) | ferdig |
| | Webview-vert — Windows (WebView2) | parkert — venter på en maskin |
| | Delt build (`--target web\|desktop`) | ferdig |
| | Kø og cache | ferdig |
| | Scheduler | ferdig |
| | Sesjoner med flash | ferdig |
| | Mail (med STARTTLS) | ferdig |
| | TLS — HTTPS og STARTTLS | ferdig |
| | Testrammeverk (`Askr.Testing`) | ferdig |

Og et lag som ikke står i PRD-en i det hele tatt. Det kom av å måle Askr mot
Laravel (`LARAVEL.md`), og hører hjemme i en egen tabell nettopp derfor:

| Utenfor PRD-en | Innhold | Status |
|---|---|---|
| | `.env` (`Askr.Core.Env`) | ferdig |
| | Krypto: SHA-256, HMAC, PBKDF2, signering | ferdig, mot offisielle vektorer |
| | CSRF | ferdig, på som standard i `askr new` |
| | Innlogging, «husk meg», gates | ferdig |
| | Filopplasting (`multipart/form-data`) | ferdig, uten kopier |
| | Konfigurasjon (`Askr.Core.Config`) | ferdig, fire lag |
| | Logging (`Askr.Core.Log`) | ferdig, tekst og JSON |
| | Varig kø (`Askr.Queue.Db`) | ferdig, alle tre dialekter |
| | Modell-livskvalitet | ferdig |
| | HTTP-klient (`Askr.Http.Client`) | ferdig |
| | AI (`Askr.Ai`) | ferdig, men aldri kjørt med en nøkkel |
| | Kommandolinja (`Askr.Console`) | ferdig, 22 kommandoer |
| | Auth-stillas (`askr new --auth`, `askr make auth`) | ferdig |

Lista fra `LARAVEL.md` er dermed gjennomgått. To ting i tabellene over er
**skrevet, men aldri kjørt**, og de skal stå slik til noen har gjort det:
Windows-webviewen, og AI-laget med en gyldig API-nøkkel.

| Fase 3 | Innhold | Status |
|---|---|---|
| | Fem porter foran språkvalget | prøvd, alle fem gikk mot eget språk |
| | Rún v0.1 — transpiler i `Askr.Run` | ferdig, bygget inn i `askr build` |
| | Rún som standard datalag | **nei** — se kostnaden under Fase 3 |

| Frontend | Innhold | Status |
|---|---|---|
| | Lauf — UI-komponenter i Svelte 5 | ferdig, 36 komponenter — se `LAUF.md` |

Fire ting står ikke der en fersk leser ville lett etter dem, og det er med
vilje:

* **Prepared statements med cache hører til steg 2**, ikke til fase 2. Det er
  datalaget PRD-en beskriver i steg 2, og det er der raden står — men den ble
  stående igjen til etter at hele fase 2 var ferdig. Postgres kom sist, fordi
  libpq krever `PQprepare` med et eget navnerom for statementene.
* **MySQL står ikke i PRD-en.** Den kom inn etterpå, og er merket slik at
  tabellen ikke gir inntrykk av at PRD-en ba om den.
* **Krypto, CSRF og auth står ikke i PRD-en heller.** De kom av
  Laravel-sammenligningen, og de ble gjort samlet fordi
  CSRF trenger konstanttidssammenligning og innlogging trenger
  passordhashing — bygde man dem hver for seg, ville primitivene blitt
  skrevet to ganger.
* **Rún er ferdig som v0.1, ikke som datalag.** Transpileren er inne i
  rammeverket og i testporten, men Urd og Norn er fortsatt det en ny app får.
  Grunnen er målt og står i sin helhet under Fase 3.

## Dokumentasjon

Utviklerdokumentasjonen ligger i [`docs/`](docs/README.md) og er på engelsk,
som alt annet en bruker av rammeverket ser. Den dekker arenaen, ruting,
datalaget, migrasjoner, sikkerhet, kø, AI og resten — én side per emne.

Denne fila og `CLAUDE.md` er arbeidsnotater og blir værende på norsk.

## Kom i gang

Verktøykjeden er Free Pascal. Alt bygger og består testene på både 3.2.2 og
3.3.1 trunk. Finnes `fpc` på PATH brukes den; ellers bygges og brukes
docker-imaget i `tools/Dockerfile.fpc` automatisk.

Peker `ASKR_FPC` på en bestemt kompilator, brukes den i stedet:

```sh
export ASKR_FPC=~/fpcupdeluxe/fpc/bin/aarch64-darwin/fpc
```

En fpcupdeluxe-installasjon legger `fpc.cfg` ved siden av binaeren, og der
leter ikke FPC selv på Unix — skriptet setter derfor `PPC_CONFIG_PATH`.

```sh
./askr test          # bygg og kjør testsuiten
./askr run           # start eksempelappen på http://127.0.0.1:8080
./askr run 9000      # ... på en annen port
./askr db:up         # Postgres for utvikling, port 5433
./askr spike         # libpq-spiken mot den databasen
./askr urd           # Urd ende-til-ende: modeller, pool, spørringer
./askr schema        # migrer, introspiser, generer typede kolonner, bruk dem
./askr web           # bygg Svelte-frontend og start Inertia-demoen
./askr db:down
./askr build
./askr clean
```

`db:up` starter en egen Postgres på 5433 uten volum, så den kolliderer ikke
med andre databaser på maskinen og tar ingen data med seg videre.

Eksempelappen svarer på `/`, `/hello?navn=…`, `POST /echo` og `/stats`.
`/stats` viser arenaens tilstand — først i den workeren som tok akkurat den
requesten, så summert over hele serveren. Det er den raskeste måten å se at
minnebruken flater ut på.

```sh
curl 'http://127.0.0.1:8080/hello?navn=Knut'
curl -X POST --data 'hallo' http://127.0.0.1:8080/echo
curl http://127.0.0.1:8080/stats
```

## Målt på steg 1

Eksempelappen, Debian bookworm på aarch64, FPC 3.2.2, `-O2`:

| | |
|---|---|
| RSS ved oppstart | 2,9 MB |
| RSS etter 5000 requests | 3,9 MB |
| Arena per request (`/hello`) | 640 bytes, én blokk på 64 kB |
| Binærstørrelse | 2,1 MB, ingen avhengigheter utover libc |

PRD-ens grense er 50 MB RSS for en moderat CRUD-app. Tallene over er for en
app uten database, så de sier bare at verten og arenaen ikke er problemet —
ikke at kriteriet er innfridd. Det avgjøres når Urd lander i steg 2.

Kravet om under 300 ms fra lagret fil til oppdatert nettleser er ikke målt
ennå. Det hører til dev-serveren i steg 6.

## Struktur

```
src/core/     Askr.Core.Arena    bump-allokator med levetid lik én request
              Askr.Core.Text     TStr og TStrBuilder — strenger i arenaen
              Askr.Core.Clock    UTC og RFC 9110-dato
src/http/     Askr.Http.Types    metoder, statuskoder, URL-koding
              Askr.Http.Request  parsing av HTTP/1.1 inn i arenaen
              Askr.Http.Response responsobjekt og serialisering
              Askr.Http.Server   vert med én arena per worker
src/core/     Askr.Core.Json     JSON inn og ut, i arenaen
src/cli/      Askr.Cli.Watch     filovervåking med nanosekund-mtime
              Askr.Cli.Proxy     proxy som holder requests under bytte
              Askr.Cli.Serve     dev-serveren og målingen
              Askr.Cli.Project   askr.toml
              Askr.Cli.Scaffold  askr new og askr make
              Askr.Cli.Auth      stillaset for innlogging
cli/          askr.lpr           CLI-binæren
src/http/     Askr.Http.Router   rutingstabell, delt av web og desktop
src/http/     Askr.Http.Multipart skjemaer med filer, uten kopier
src/core/     Askr.Core.Config   miljø, .env og askr.toml i ett oppslag
              Askr.Core.Log      nivåer, felter, tekst eller JSON
src/runtime/  Askr.Queue.Db      varig kø i databasen appen har
              Askr.Http.Client   HTTP ut: TLS, omdirigering, chunked, SSE
              Askr.Ai            Claude over Messages API
src/http/     Askr.Http.Static   statiske filer, med stisikring
src/urd/      Askr.Urd.Bind      request til modell, som class helper
src/inertia/  Askr.Inertia       Inertia 3-protokollen
src/urd/      Askr.Urd.Json      modeller til JSON via RTTI
src/norn/     Askr.Norn.Schema     migrasjoner beskrevet i Pascal
              Askr.Norn.Migration  kjøring, versjonstabell, rollback
              Askr.Norn.Introspect leser faktisk skjema fra databasen
              Askr.Norn.Codegen    genererer typede kolonner og manifest
src/run/      Askr.Run           Rún-transpiler: *.run til typet Pascal,
                                 med skjemaet lest ved comptime
src/core/     Askr.Core.Crypto   SHA-256, HMAC, PBKDF2, tilfeldighet,
                                 signering — ren Pascal, ingen OpenSSL
src/runtime/  Askr.Csrf          token i sesjonen, middleware
              Askr.Auth          innlogging, «husk meg», gates
src/urd/      Askr.Urd.Driver    grensesnittet alle dialekter ligger bak
              Askr.Urd.Pg        Postgres over libpq, lastet med dlopen
              Askr.Urd.Pool      forbindelser som leveres tilbake ved Reset
              Askr.Urd.Model     modeller, skjema og RTTI-mapping
              Askr.Urd.Query     typede spørringer og eager loading
examples/     hello              minste kjørende app
              pgspike            libpq-spiken: C-ABI, typer, feil, arena
              urddemo            hele datalaget mot en ekte database
              norndemo           migrasjoner, codegen, driftsjekk, og et
                                 program som bruker det genererte
              inertia/           Askr + Inertia 3 + Svelte 5, med Vite
              run/               Rún ende-til-ende: shop.run, transpiler,
                                 og et program som bruker det genererte
tests/        askr_tests         testsuite, exit-kode 1 ved feil
              askr_runtime_tests kø, scheduler, sesjoner, CSRF, auth, mail
              askr_crypto_tests  krypto mot NIST- og RFC-vektorer
              askr_run_tests     Rún mot en ekte SQLite-database
              run/               feilfixturer comptime skal fange
tools/        Dockerfile.fpc     verktøykjede for bygg og CI
              docker-compose.yml databaser å utvikle mot
              probes/            generics-grenser, kjørbare mot en hvilken
                                 som helst fpc
```

## Minnemodellen

En worker eier én arena og kaller `Reset` før hver request. Alt som allokeres
underveis frigjøres i én operasjon. Ingen per-objekt opprydding, ingen
refcounting, ingen GC.

```pascal
type
  TGreeting = class(TArenaObject)   // arver arena-allokering
  ...

G := TGreeting.Create(Req.Query('navn'));   // i arenaen, constructor kjører
// ingen try/finally, ingen Free
```

Fire regler følger av modellen, og de håndheves av API-et, ikke av
dokumentasjonen:

1. Verdier som skal overleve requesten — cache, sesjon, connection pool — må
   ikke ligge i request-arenaen. Slike API-er tar sin egen allokator.
2. Bakgrunnsjobber låner aldri requestens arena, de får en egen.
3. Pascals `string` er refcountet av kompilatoren og ligger på heapen. Den er
   trygg, men frigjøres ikke av `Reset`. Bruk `TStr` for strenger som skal leve
   i arenaen.
4. Destructorer kalles aldri på arena-objekter. Alt som eier en ekstern
   ressurs må håndteres eksplisitt.

`TArenaObject` faller tilbake til heapen når det ikke finnes en omgivende
arena, slik at den samme klassen kan brukes i tester og oppstartskode. Da
gjelder vanlige regler, og `Free` må kalles.

## Datalaget

To valg i `Askr.Urd.Pg` er verdt å kjenne til, fordi de følger av PRD-ens egne
prinsipper og ikke er frie å endre senere:

**libpq lastes med `dlopen` ved første bruk, ikke på byggetid.** Ellers ville
binæren nektet å starte på en maskin uten Postgres installert, og både «kopier
én binærfil til serveren» og en desktop-variant med bare SQLite hadde vært
umulig. Prisen er at en manglende libpq oppdages ved første spørring, så
feilmeldingen sier hvilke filnavn og stier som ble forsøkt.

**Resultatet kopieres inn i arenaen, og `PGresult` frigjøres før `Exec`
returnerer.** Alternativet var å utsette `PQclear` til `Arena.Reset` gjennom
den nye `Defer`-mekanismen, men da ville radene pekt inn i minne libpq eier,
og hver regel om levetid måtte forklares to ganger. Én memcpy per resultatsett
er billig ved siden av nettverket.

`Arena.Defer` finnes likevel, fordi PRD-en har rett i at noe må håndtere
eksterne ressurser når destructorer aldri kjører. Den kjører opprydning i
motsatt rekkefølge ved `Reset`, og er det connection-poolen kommer til å bruke
for å levere tilbake en lånt forbindelse ved slutten av en request.

Målt mot Postgres 17: 1000 parametriserte spørringer uten at arenaen vokser,
topp 1360 bytes per spørring, én blokk på 64 kB.

## Typede spørringer

```pascal
TQuery<TCustomer>.New
  .Where(Customers.Balance, GT, 0)
  .Where(Customers.Email, Like, '%@gets.no')
  .OrderBy(Customers.Balance, Desc)
  .Preload(['Orders'])
  .Limit(50)
  .Get;
```

`.Where(Customers.Balance, GT, 'abc')` gir kompileringsfeil. Mekanikken er at
`TCol<T>` er en generisk record, spesialiseringer av den er distinkte typer,
og `Where` er overlastet på hver av dem med verditypen som følger.

To avvik fra PRD-en, begge tvunget fram av Free Pascal 3.2.2:

| PRD | Askr i dag | Hvorfor |
|---|---|---|
| `Query<TCustomer>` | `TQuery<TCustomer>.New` | Generiske frittstående funksjoner kan ikke eksporteres fra en unit i 3.2.2 |
| `.With([...])` | `.Preload([...])` | `with` er et reservert ord |

Begge er navnebytter hvis en nyere kompilator fjerner grensene.

### Grenser i Free Pascal som er truffet

Konkret liste til den avgjørelsen PRD-en utsetter til fase 3. **Alle seks er
verifisert på både 3.2.2 og 3.3.1 trunk — alle står.** Det eneste som er
endret er at trunk ikke lenger krasjer der 3.2.2 falt om; grensene er design,
ikke feil, og forsvinner ikke ved å vente.

Probene ligger i `tools/probes/` og kjøres om igjen med:

```sh
tools/probes/run.sh                      # fpc fra PATH
tools/probes/run.sh /sti/til/fpc
```

Én forskjell mellom kompilatorene er ikke en generics-grense, men verre, fordi
den gjelder penger og er stille: **`Currency(I) * <heltallsliteral>` gir ulikt
svar.** Med `I = 7` gir `Currency(I) * 100` 700,00 på 3.2.2 og **0,07 på
trunk** — trunk regner i Currency sin skalerte `int64`-representasjon og
reintepreterer resultatet. Ingen advarsel, ingen feil. Formene som er like på
begge er `Currency(I * 100)`, `Currency(I) * 100.0`, og tilordning til en
Currency-variabel først; addisjon og divisjon er upåvirket. En premisstest i
suiten holder det fast.


* Generisk metode inne i en generisk klasse: *Declaration of generic inside
  another generic is not allowed*.
* Generisk frittstående funksjon eksportert fra en unit: deklarasjon og
  implementasjon får ulike navn på typeparameteren. Varianter av det samme
  får kompilatoren til å krasje med *unhandled exception*.
* Generisk klassemetode på en ikke-generisk klasse: samme, også med krasj.
* Generisk metode i en generisk klasse kan ikke referere symboler som bare
  finnes i implementation-seksjonen.
* Generisk funksjon med standardparameter: signaturene matcher ikke.
* `for var I := ...` finnes ikke.

Målt kompileringstid for hele treet:

| | 3.2.2 | 3.3.1 trunk, nativt |
|---|---|---|
| Kald full bygging | 227 ms | 460 ms |
| Full rebuild | 155–163 ms | 284–290 ms |
| Én unit endret | 141 ms | 155–158 ms |
| Ingenting endret | 113 ms | 123 ms |

## Prepared statements

Alle tre driverne sender parametre som parametre, ikke som tekst limt inn i
spørringen, og alle tre cacher det forberedte statementet per forbindelse.
Cachen ligger der fordi det er der statementet lever: det er serverens
tilstand for akkurat denne sesjonen, og en cache delt mellom forbindelser
ville pekt på håndtak i feil sesjon.

```pascal
{ Ingenting å slå på. Dette er veien ExecParams går. }
R := C.ExecParams(A, 'SELECT name FROM customers WHERE email = $1',
  [DbParam(A, Epost)]);

C.CacheLimit := 0;     { av, hvis man vil måle forskjellen }
C.FlushStatementCache; { etter DDL som endrer en tabell cachen rører }
```

Målt med 2000 spørringer over samme forbindelse:

| | uten cache | med cache |
|---|---|---|
| SQLite | 6–8 ms | 1–2 ms |
| Postgres 17 | 50–52 ms | 24–33 ms |
| MySQL 8.4 | 142–152 ms | 109–115 ms |

SQLite vinner mest relativt, fordi det ikke finnes et nettverk å gjemme
parsingen bak — der er `sqlite3_prepare_v2` hele kostnaden. Postgres sparer
en full parse per kall, siden alternativet er `PQexecParams`. MySQL forbereder
uansett; der er gevinsten bare den ene ekstra rundturen.

### SQLite: gjenbruk krever opprydning

Et gjenbrukt statement må nullstilles med `sqlite3_reset` **og** få
bindingene ryddet med `sqlite3_clear_bindings`. Uten det første holder en
ferdig-stepped SELECT på lesesperren sin til noen kjører den igjen; uten det
andre kan verdier fra forrige kjøring henge igjen.

Til gjengjeld slipper SQLite noe de to andre må gjøre: `sqlite3_prepare_v2`
håndterer skjemaendringer selv, så et cachet statement overlever
`ALTER TABLE` uten å kastes ut av cachen. Det er testet.

### Postgres: `PQprepare` er ikke `PREPARE`

SQL-setningen `PREPARE` er transaksjonell — forberedes den inne i en
transaksjon som rulles tilbake, forsvinner den. `PQprepare` er noe annet:
den sender en `Parse`-melding i den utvidede protokollen, og slike
statements hører til **sesjonen**, ikke til transaksjonen. De overlever
rollback.

Det er verdt å vite, for det avgjør om cachen trenger å bry seg om
transaksjoner. Den gjør ikke det. Utdatert kan den likevel bli — noe annet i
appen kan ha kjørt `DEALLOCATE ALL`. Da svarer serveren `26000`, og driveren
forbereder på nytt og kjører om igjen i stedet for å melde feil. Begge
tilfellene er dekket av tester.

Statementene heter `askr_N` og navnene gjenbrukes aldri, slik at et statement
driveren har mistet oversikten over ikke kan kollidere med et nytt. Går
cachen over grensen, kjøres `DEALLOCATE ALL`.

## Norn

En migrasjon skrives for hånd og registrerer seg selv:

```pascal
procedure TCreateCustomers.Up(S: TSchemaBuilder);
begin
  with S.Create('customers') do
  begin
    Id;
    Text('name', 120);
    Text('email', 255).Unique;
    Money('balance').Default(0);
    Timestamps;
    Index(['created_at']);
  end;
end;
```

Etter kjøring leser Norn det **faktiske** skjemaet ut av databasen — ikke
migrasjonene — og genererer én unit per tabell:

```pascal
unit App.Schema.Customers;   { AUTOGENERERT AV NORN — IKKE REDIGER }

type
  TCustomersColumns = record
    const Id        : TColInt64    = (Name: 'id';         Table: 'customers');
    const Name      : TColStr      = (Name: 'name';       Table: 'customers');
    const Balance   : TColCurrency = (Name: 'balance';    Table: 'customers');
    const CreatedAt : TColDateTime = (Name: 'created_at'; Table: 'customers');
  end;
```

Det er disse som gjør PRD-ens løfte konkret. Verifisert ved å kompilere:

| Feil | Resultat |
|---|---|
| `Customers.Balanse` | `Error: Identifier idents no member "Balanse"` |
| `.Where(Customers.Balance, GT, 'mye')` | `Error: Incompatible type for arg no. 3` |

I tillegg genereres `App.Schema.Manifest` med indekser, fremmednøkler og
kardinalitet.

### Hvor langt codegen rekker

PRD-en lover at fire klasser feil flyttes til kompilering. Status etter steg 3:

| Lovet | Status |
|---|---|
| Feil felttype i en `Where` | **Ja** — overlasting på `TCol<T>` |
| Ukjent kolonne | **Ja** — mot sist genererte skjema |
| `.Where` mot kolonne uten indeks | Nei — manifestet vet det, men bare ved kjøring |
| N+1 i en løkke | Nei — krever dataflytanalyse |

Det viktige forbeholdet står i den andre raden: garantien gjelder mot **sist
genererte** skjema, ikke mot databasen slik den er nå. Endrer noen databasen
uten å regenerere, kompilerer koden fortsatt.

Driftsjekken finnes og virker — hver generert fil bærer et avtrykk av tabellen
sin, og en endring utenom migrasjonene blir oppdaget. Men den er en kommando
noen må huske å kjøre, eller som CI må kjøre. Det er forskjellen mellom
codegen og comptime, og den er hele saken i Rún-dokumentet — se
[Fase 3](#fase-3-rún) under, der forskjellen nå er målt.

## Inertia og Svelte

```pascal
function TAppController.Handle(Req: TRequest): TResponse;
begin
  Result := Inertia('Customers/Index',
    ['customers', MakeCustomers(Req.Arena, True),
     'total', Int64(6)]);
end;
```

Askr finner ikke opp noe eget. Kontrakten er den Inertia allerede
definerer — `component`, `props`, `url`, `version` — så de offisielle
adapterne virker uendret. Modeller og modellister serialiseres via den samme
RTTI-en Urd mapper med: kolonnenavn i snake_case, relasjoner nøstet under
samme navn, og en relasjon som ikke er lastet utelates helt i stedet for å
settes til null.

**Versjonen er Inertia 3.** Den viktigste forskjellen fra 2 er at payloaden
er flyttet fra et `data-page`-attributt på rot-diven til et eget
script-element:

```html
<script data-page="app" type="application/json">{"component":"Home",...}</script>
<div id="app"></div>
```

Klienten i 3 leter bare etter script-elementet, så attributtformen booter
ikke i det hele tatt. Inni et script-element er det JSON-escaping som gjelder,
ikke HTML-escaping: `<` blir `\u003c` og `/` blir `\/`, slik at en propverdi
som inneholder `</script>` ikke kan bryte ut. Det finnes en test som prøver
akkurat det.

Implementert av protokollen: HTML-skall og JSON-svar, versjonssjekk med 409 og
`X-Inertia-Location`, delvise oppdateringer med `X-Inertia-Partial-Data` og
`-Except`, `X-Inertia-Except-Once-Props`, utsatte props via `deferredProps`,
`clearHistory` og `encryptHistory`, og 303 i stedet for 302 etter PUT, PATCH
og DELETE.

Ikke implementert, og bevisst utelatt fra fase 1: sammenslåing av props for
uendelig rulling (`mergeProps`, `deepMergeProps`, `matchPropsOn`,
`X-Inertia-Reset`).

### Frontend

`examples/inertia/frontend` er et vanlig Vite-prosjekt med Svelte 5 og
`@inertiajs/svelte` 3.7. Bygget legges i `public/build`, og Pascal-siden leser
Vites `manifest.json` med Askrs egen JSON-parser for å finne filnavnene med
hash — som samtidig blir Inertia-versjonsstrengen.

PRD-en flagget at adapterens runes-støtte måtte verifiseres. Det er avklart:
Inertia 3 har `svelte: ^5.0.0` som eneste peer-avhengighet. Svelte 4 støttes
ikke lenger, så runes er ikke et valg men utgangspunktet. Bunten er 154 kB,
51 kB gzippet.

Målt: 2,5 kB arena for en Inertia-request som serialiserer seks modeller med
nøstede relasjoner.

## Ruting, kontrollere og validering

```pascal
R.Use(Statisk.Handle);
R.Get('/customers', Ctrl.Index);          R.AsName('customers.index');
R.Get('/customers/new', Ctrl.NyttSkjema); R.AsName('customers.create');
R.Get('/customers/:id', Ctrl.Show);       R.AsName('customers.show');
R.Post('/customers', Ctrl.Store);         R.AsName('customers.store');
```

Mønstrene har tre slags segmenter: faste, `:navn` som fanger ett, og `*navn`
som fanger resten. Ingen regulære uttrykk.

**Rutene sorteres etter spesifisitet, ikke registreringsrekkefølge.** Et fast
segment slår en parameter, og en parameter slår en wildcard. Uten det ville
`/customers/new` blitt slukt av `/customers/:id` avhengig av hvilken
rekkefølge noen tilfeldigvis skrev dem i. Kjent sti med ukjent metode gir
405, ikke 404.

Middleware er en funksjon som returnerer `nil` for å slippe requesten videre,
eller en respons for å stoppe den. Eksplisitt framfor en `Next`-kjede: uten
closures blir den kjeden vanskeligere å lese enn den er verdt.

### Validering

```pascal
procedure TCustomer.Rules(V: TValidator);
begin
  V.Field('Name').Required.MaxLen(120);
  V.Field('Email').Required.Email.UniqueIn('customers');
  V.Field('Balance').Min(0);
end;
```

Feltnavnet i `Rules` er property-navnet, fordi det er det man ser i Pascal.
Feilene kommer ut med kolonnenavnet, fordi det er det frontend sendte inn.
Oversettelsen går gjennom den samme RTTI-mappingen Urd bruker ellers. Bare
første feil per felt rapporteres.

### Kontrolleren

```pascal
function TAppController.Store(Req: TRequest): TResponse;
var
  K: TCustomer;
begin
  K := Req.Arena.New<TCustomer>;
  Req.FillInto(K);

  if not K.Validate then
    Exit(Inertia('Customers/New', ['errors', K.Errors, 'sendt', K]));

  SaveCustomer(K.Name, K.Email, K.Balance);
  InertiaFlash('success', 'Customer ' + K.Name + ' created');
  Result := Index(Req);
end;
```

`Req.FillInto` er en class helper, slik at HTTP-laget slipper å kjenne Urd —
desktop-skallet og en ren JSON-tjeneste bruker `TRequest` uten datalag i det
hele tatt. Den leser JSON-kropp, skjemakropp og query, i den rekkefølgen, og
rører bare felter som faktisk er sendt.

**Primærnøkkelen fylles aldri fra en request.** Det er ikke en manglende
bekvemmelighet: uten den regelen kan en klient overskrive hvilken rad som
helst ved å sende med en id.

### To avvik fra PRD-en, begge fordi sesjoner hører til fase 2

PRD-en skriver `Exit(Back.WithErrors(C.Errors))` og
`Redirect('/customers').With('flash', ...)`. Begge forutsetter at noe
overlever en omdirigering, altså sesjoner.

Inertia 3 leser `props.errors` fra **hvilket som helst** svar, ikke bare fra
et sesjonsbåret omdirigeringssvar. Derfor rendrer en validering som feiler
siden på nytt med feilene som prop, og resultatet i frontend er identisk.
`flash` er tilsvarende et felt på svaret som faktisk rendrer siden.

`Back` finnes og følger `Referer`, men den bærer ingen data. Når sesjoner
lander i fase 2, kan begge mønstrene skrives om til PRD-ens form.

## Desktop

PRD-ens milepæl for fase 2 er at samme kodebase kjører som webtjeneste og som
skrivebordsbinær. `examples/desktop` viser det målbart:

| Fil | Linjer | Rolle |
|---|---|---|
| `App.Routes.pas` | 204 | modeller, kontroller, ruter — appen |
| `webmain.lpr` | 86 | web-skallet |
| `desktopmain.lpr` | 49 | desktop-skallet |

```pascal
DesktopApp.UseDatabase('sqlite:notes.db');
DesktopApp.RegisterRoutes(@RegisterAppRoutes);
DesktopApp.Window('Notater', 1100, 780);
DesktopApp.Run;
```

Begge binærene bygges fra samme kilde med `askr build --target web` og
`--target desktop`, og begge er ~2,5 MB.

**Det er ingen egen GUI-verktøykasse, og det skal det ikke bli.** macOS går
rett på Objective-C-runtimen — `objc_getClass`, `sel_registerName`,
`objc_msgSend` — mot AppKit og WebKit. Linux går samme vei mot GTK3 og
WebKitGTK. Ingen av dem har et mellomliggende C-bibliotek som måtte bygges og
vedlikeholdes, og begge lastes med `dlopen`: uniten kompilerer på en maskin
uten GTK i det hele tatt, og en app som bare skal kjøre som webtjeneste drar
ikke med seg en avhengighet den aldri bruker.

Windows går gjennom WebView2, som er COM.

### Windows — parkert

**Denne er lagt på is til noen har en Windows-maskin å kjøre den på.** Koden
blir liggende og kompilerer med resten, men den regnes ikke som ferdig, og
statustabellen sier «parkert» framfor «ferdig».

Det er det ene stedet i Askr der koden ikke er verifisert ved å kjøre den.
Det er verdt å si rett ut, framfor å la tabellen antyde noe annet.

WebView2 er COM, og oppstarten er asynkron: `CreateCoreWebView2Environment`
`WithOptions` returnerer med én gang, og callbacken kommer først når
meldingsløkka kjører. Derfor lages Win32-vinduet først, så startes løkka, og
navigeringen skjer inne i den andre callbacken.

Vtable-ene skrives ikke for hånd. Metodene deklareres som Pascal-interface i
nøyaktig den rekkefølgen `WebView2.h` har dem, og kompilatoren legger ut
vtablen — også for metoder Askr aldri kaller, som bare står der for å holde
rekkefølgen. Å telle indekser selv er den ene feilen som ikke sier fra:
kaller man metode 24 i stedet for 25, får man en peker som ser gyldig ut.

**Hva som faktisk er verifisert:**

* Windows-API-signaturene er lest mot FPCs egne deklarasjoner i `rtl/win`.
  Det fanget én reell feil: `GetMessageW` tar meldingen som `var`-parameter,
  ikke som peker, så `@Msg` ville ikke kompilert.
* `tools/probes/webview2_vtable.lpr` kompilerer og kjører COM-deklarasjonene
  med Windows-API-et stubbet ut. Det viser at interfacene lar seg deklarere i
  riktig rekkefølge, og — viktigst — at callback-klassene **faktisk oppfyller**
  interfacene sine, siden kompilatoren sammenligner signaturene. Det er en av
  få feil som ellers først ville vist seg som et krasj hos en bruker.

**Hva som ikke er verifisert:** at det virker. Ingen har startet binæren på
Windows. Et forsøk på å bygge en win64-kryss-kompilator fra Debians FPC-kilder
strandet på manglende Makefiler, så selv en kompileringssjekk mot den ekte
Windows-RTL-en mangler.

Proben kjøres som en del av `./askr test`. Det er med vilje: parkert kode som
ikke bygges, råtner, og da er den verre enn ingen kode når noen en dag tar den
opp igjen.

`WebView2Loader.dll` må ligge ved siden av binæren. Kjøretiden er med fra før
på Windows 11; på eldre installeres den fra Microsofts WebView2-side.

### Linux

```
apt install libgtk-3-0 libwebkit2gtk-4.1-0
```

webkit2gtk 4.0 og 4.1 skiller seg bare i hvilken libsoup de bruker, og
symbolene Askr bruker er de samme — begge står i kandidatlisten, så både
Debian 12, Ubuntu 22.04 og nyere virker.

Finnes ikke biblioteket, sier `WebviewError` hva som må installeres.
Finnes det, men ingen skjerm — i en container, over ssh uten X11 — så
returnerer `gtk_init_check` en feil i stedet for at `gtk_init` kaller
`exit()`, og appen sier fra at den kjører som webtjeneste likevel i stedet
for å forsvinne uten et ord.

Kjeden er testet på ordentlig, ikke bare kompilert:

```
./askr desktop:linux
```

Den bygger et eget image med GTK3 og WebKitGTK, starter Xvfb, åpner et ekte
vindu, lar WebKitGTK hente siden fra den innebygde serveren — og sjekker at
JavaScript på siden rekker et nytt kall tilbake. Blir begge kallene
registrert, har hele kjeden virket: vindu, nettmotor, lokal HTTP-server og
ruter. GTK-imaget holdes utenfor hovedimaget fordi WebKitGTK drar inn noen
hundre megabyte, og `./askr test` skal ikke betale for det.

Ett avvik fra PRD-en: objektet heter `DesktopApp`, ikke `App`. PRD-en gir
også brukerkoden navnerommet `App.Models.*`, `App.Http.*` og `App.Schema.*`,
og da leser kompilatoren `App.UseDatabase` som en unit-kvalifikasjon.
Navnerommet er mer bærende — det står i generert kode fra Norn — så det er
variabelen som viker.

## SQLite

```pascal
C := OpenDbConnection('sqlite:local.db');
C := OpenDbConnection('sqlite::memory:');
```

Samme `TDbConnection` som Postgres, så modeller, query builder, validering og
eager loading er bit for bit den samme koden. Driveren håndterer de tre
forskjellene som ellers ville lekket oppover: `?` i stedet for `$1`,
`last_insert_rowid` i stedet for `RETURNING`, og WAL med `busy_timeout` slik
at en pool med flere workere venter i stedet for å få `SQLITE_BUSY`.
`SQLITE_CONSTRAINT` oversettes til SQLSTATE `23505`, slik at
`IsUniqueViolation` virker likt på tvers av dialekter.

Norn introspiserer SQLite gjennom pragmaer, så `askr schema` genererer typede
kolonner for en desktop-app på samme måte som for Postgres.

**Sidegevinst:** hele datalaget testes nå uten databaseserver. 27 av testene
kjører mot `sqlite::memory:` — migrasjoner, Save, typede spørringer, eager
loading, validering med `UniqueIn`, transaksjoner og arenaens flathet.

## MySQL

```pascal
C := OpenDbConnection('mysql://askr:askr@127.0.0.1:3306/askr_dev');
C := OpenDbConnection('mysql:host=db;user=askr;password=askr;db=shop');
```

Bindingen går mot **MariaDB Connector/C** (`libmariadb`). Den er
ABI-kompatibel med `libmysqlclient`, ligger i Debian som `libmariadb3` og på
Homebrew som `mariadb-connector-c`, og snakker med både MySQL og MariaDB.
Én binding, to servere — verifisert mot MySQL 8.4 med `caching_sha2_password`.

Tegnsettet er `utf8mb4` med mindre `charset=` sier noe annet. MySQLs «utf8»
er ikke UTF-8, og standarden her skal ikke være en felle.

### Tekst eller prepared

`Exec` uten parametre går over tekstprotokollen. Migrasjoner og DDL havner
der, og MySQL lar seg ikke prepare på alt av det. `ExecParams` går over
prepared statements med cache — se [Prepared statements](#prepared-statements)
for grensen på 64 og hva det er verdt.

### Det dialekten krever

* **`RETURNING` finnes ikke.** `InsertGetId` bruker `LAST_INSERT_ID()` på
  samme forbindelse, som er trygt så lenge ingen deler en forbindelse — og
  det gjør poolen aldri.
* **SQLSTATE duger ikke til å skille feil.** MySQL sier `23000` om både
  unik-brudd og fremmednøkkelbrudd. Driveren oversetter fra errno i stedet,
  slik at `IsUniqueViolation` og `IsForeignKeyViolation` virker likt på tvers
  av de tre dialektene.
* **`CLIENT_FOUND_ROWS` er på.** Uten den melder en oppdatering som ikke
  endret noe 0 rader, og kallende kode tror raden er borte.
* **InnoDB overser `REFERENCES` skrevet på kolonnen.** Setningen parses uten
  feil, tabellen opprettes, og fremmednøkkelen finnes ikke. Skjemabyggeren
  legger derfor `FOREIGN KEY`-klausulen på tabellnivå for MySQL. Det er
  verdt å vite om, for skjemaet ser riktig ut helt til noe sletter en rad
  det pekes på.

Norn introspiserer MySQL gjennom `information_schema`, og leser `column_type`
framfor `data_type` — det er den som skiller `tinyint(1)` fra `tinyint(4)`,
altså boolsk fra heltall.

Testene kjøres slik:

```
./askr db:up     # Postgres på 5433, MySQL på 3308
./askr mysql     # 80 påstander mot en ekte server
```

De dekker innsetting og id, NULL, `utf8mb4` med firebyte-tegn, anførselstegn
som data framfor SQL, flyttall og regnede kolonner, berørte rader,
feiloversettelse, transaksjoner, statement-cachen, 500 rader i én spørring,
hele Norn-løkka med migrasjon og introspeksjon og tilbakerulling, og fire
tråder som deler en pool på tre forbindelser.

## Kø og cache

Begge ligger i samme prosess. Ingen Redis, ingen Horizon, ingen supervisor
ved siden av — det er hele poenget med én binær.

```pascal
Cache.Put('customers:' + IntToStr(Id), Payload, 300);
if Cache.Get(Req.Arena, 'customers:42', Verdi) then ...

Queue.Push('send-email', Payload);
Queue.Push('rydd-opp', Payload, 3600);   { om en time }
```

Cachen er delt i shards med hver sin lås — én lås for hele cachen ville
serialisert workerne mot hverandre, og da er en cache verre enn ingen.
LRU-utkasting per shard, TTL per post. Køen har forsinkelse, retry med
eksponentiell backoff og et tak på antall forsøk.

### Der minnemodellen møter veggen

Dette er første gang noe skal overleve en request **og** deles mellom tråder,
og det er derfor PRD-en setter kø og cache som prøven på arena-modellen.

Det viser seg å være nøyaktig **tre grenser**, alle inne i rammeverket:

| Grense | Hvor | Hva som skjer |
|---|---|---|
| request-arena → heap | `Cache.Put` | bytene kopieres inn i cachens eget minne |
| request-arena → heap | `Queue.Push` | payloaden kopieres mens kalleren fortsatt eier den |
| heap → worker-arena | i køworkeren | jobben får payloaden med samme levetid som alt annet den rører |

PRD-en skriver `Cache.Put(Key, Value.CloneTo(App.Heap))` — kopieringen som
noe kalleren gjør. Det er snudd her: **API-et kopierer, ikke kalleren.** En
kopi man må huske er en kopi noen kommer til å glemme, og feilen viser seg
som en annen brukers data i cachen.

Den ikke-opplagte halvdelen er at `Get` kopierer **ut** i kallerens arena.
To ting følger, og begge er gratis:

* Cachen kan kaste ut en post når som helst uten at noen sitter med en peker
  inn i minnet som forsvant.
* Verdien kalleren får dør med requesten. Den kan ikke ved et uhell bli
  liggende.

Det er testet direkte, ikke antatt: verdien legges inn fra en arena, arenaen
nullstilles og skrives full av `X`, og verdien leses tilbake. Det samme for
køen, med `Z`. Uten kopiene ville begge testene lest søppel.

## Scheduler, sesjoner, mail

Alt i samme prosess. Ingen crontab, ingen Redis, ingen sidevogn.

```pascal
Schedule.EveryMinutes(5, 'rydd-opp');
Schedule.DailyAt(3, 30, 'nattjobb');
Schedule.WeeklyAt(dowMonday, 8, 0, 'ukesrapport');
```

Scheduleren **utfører aldri noe selv** — den dytter til køen. En scheduler som
også kjører jobbene blir en andre utførelsesvei med egne levetidsregler, og
da må alt som kan kjøres skrives for to verdener. `SkipWhenPending` hindrer
at en treg jobb stables oppå seg selv.

### Sesjoner lukker avviket fra steg 5

I steg 5 måtte jeg avvike fra PRD-en: `Back.WithErrors(C.Errors)` og
`.With('flash', ...)` forutsetter at noe overlever en omdirigering, og uten
sesjoner gjorde det ikke det.

Nå gjør det det:

```pascal
if not K.Validate then
  Exit(BackWithErrors(K.Errors));
```

Feilene legges i sesjonens flash og er `props.errors` i neste request.
Inertia-laget plukker dem opp uten at kontrolleren gjør noe. Flash har den
klassiske semantikken — skrives i én request, lesbar i den neste, borte
etter det — og det er testet i alle tre leddene.

Lageret ligger i prosessen. Det er en bevisst begrensning: én binær, ingen
sidevogn. Skaleres appen til flere noder må lageret byttes, og grensesnittet
er skilt ut slik at det er én klasse.

### Mail, med ett tydelig hull

```pascal
Mail.Send(Mail.Message_
  .AddTo('kh@gets.no', 'Knut W. Hørne')
  .Subject('Kvittering')
  .Text('Takk for bestillingen.'));
```

Transporten byttes: `TLogTransport` i utvikling, `TNullTransport` i tester,
`TSmtpTransport` i produksjon.

SMTP krever STARTTLS som standard:

```pascal
{ Krever STARTTLS; avbryter hvis serveren ikke tilbyr det. }
SetMail(TMailer.Create(TSmtpTransport.Create('smtp.example.com', 587)));

{ TLS fra første byte, uten klartekstfase. }
SetMail(TMailer.Create(
  TSmtpTransport.Create('smtp.example.com', 465, smtpTlsDirect)));

{ Klartekst mot en relé på loopback. Må sies eksplisitt. }
SetMail(TMailer.Create(
  TSmtpTransport.Create('127.0.0.1', 1025, smtpPlain)));
```

Standarden er den veien rundt med vilje. Et oppsett som stille faller
tilbake til klartekst når serveren ikke tilbyr kryptering, er verre enn et
som stopper og sier fra — derfor må klartekst velges, ikke arves.

Verten kan være et navn: oppslaget går gjennom `/etc/hosts` først og så DNS,
i den rekkefølgen systemet selv bruker. Er verten et navn og ikke en
IP-adresse, sendes den med som SNI.

`VerifyPeer` er på. Slå den av bare mot selvsignerte sertifikater i test — en
klient som ikke verifiserer har kryptering, men ingen visshet om hvem den
snakker med.

## TLS

OpenSSL lastes med `dlopen`, som libpq og libsqlite3, og av samme grunn:
binæren skal starte på en maskin uten OpenSSL. En app bak en reverse proxy
som avslutter TLS selv trenger den aldri, og skal ikke kreve den.

HTTPS er to felter i serveroppsettet:

```pascal
Opts := DefaultServerOptions;
Opts.TlsCertFile := '/etc/ssl/app/fullchain.pem';
Opts.TlsKeyFile  := '/etc/ssl/app/privkey.pem';
```

Sertifikatet leses når serveren starter, ikke ved første håndtrykk: en
feilstavet sti skal gi en feilmelding ved oppstart, ikke en port som tar imot
og så avviser alt. At nøkkelen faktisk hører til sertifikatet sjekkes samme
sted.

Det er ingen egen HTTP-port ved siden av og ingen omdirigering. Én server, én
protokoll. Vil man ha begge deler, kjører man to servere.

Minsteversjon er TLS 1.2. En klient som spør om 1.0 eller 1.1 blir avvist med
`protocol version`; å tillate dem er å tilby et nedgraderingsmål ingen har
bruk for.

En app laget med `askr new` leser stiene fra miljøet:

```
ASKR_TLS_CERT=/etc/ssl/app/fullchain.pem \
ASKR_TLS_KEY=/etc/ssl/app/privkey.pem ./app
```

Sertifikatstier hører til utrullingen, ikke til kildekoden. Uten dem snakker
appen HTTP.

### macOS trenger en OpenSSL du installerer selv

Systemets `libssl` på macOS er LibreSSL, og Apple blokkerer `dlopen` mot den
fra tredjeparts binærer — forsøket gir «loading libcrypto in an unsafe way»
og prosessen dør. Det er ikke noe Askr kan omgå:

```
brew install openssl@3
```

Uten den kaster `TTlsContext.Create` en `ETlsUnavailable` som lister stiene
som ble forsøkt, og TLS-testsuiten hopper over seg selv og sier hvorfor i
stedet for å melde grønt på noe den ikke har prøvd. Linux virker rett ut av
boksen.

Testene kjøres slik:

```
./askr tls:certs     # selvsignerte sertifikater i .build/tls
./askr test          # TLS-suiten er en del av den
```

De 23 påstandene dekker håndtrykk begge veier, at et selvsignert sertifikat
faktisk avvises når verifisering er på, at klartekst mot en TLS-port ikke gir
et HTTP-svar, at en server som ikke tilbyr STARTTLS gir avbrudd i stedet for
nedgradering, og at en mislykket klient ikke tar ned en worker. Verifisert i
tillegg med `curl` og `openssl s_client`: TLS 1.3, X25519,
`ssl_verify_result=0`.

## Testrammeverket

`Askr.Testing` finnes ikke fordi Askr trengte enda et assert-bibliotek. Tre
ting gjør det verdt en egen unit:

**Ruteren testes uten socket.** `TTestClient` bygger en `TRequest` i minnet og
kaller ruteren direkte — gjennom middleware, ruting, kontroller og respons.
Ingen porter, ingen ventetid, ingen flakete tester.

**Databasen er `sqlite::memory:`.** `UseTestDatabase` gir en ny database per
kall. Ingen server, ingen opprydding å glemme.

**Arenaen kan hevdes om.** `AssertArenaStable` kjører noe hundre ganger og
krever at arenaen slutter å vokse. Det er påstanden hele prosjektet hviler
på, og apper bør kunne teste den — ikke bare rammeverket.

```pascal
Test('arenaen flater ut', @EnRequest);
AssertArenaStable(Klient.Arena, @EnRequest, 300);
```

Kjøretidstestene i `tests/askr_runtime_tests.lpr` er skrevet med det:
14 tester, 47 påstander, **1 ms**.

## Utviklerløkka

Dette er PRD-ens første suksesskriterium, og det som avgjør om premisset
holder: **under 300 ms fra lagret fil til oppdatert nettleser.**

Målt på M-serie Mac, FPC 3.3.1 nativt, Inertia-demoen med rammeverket i
søkestien:

| | |
|---|---|
| Snitt over 13 rebuilds | **247 ms** |
| Raskeste | 238 ms |
| Tregeste | 284 ms |

Fordelingen er den interessante delen:

| Fase | Tid |
|---|---|
| Oppdage endringen | 0–25 ms (polling hvert 25.) |
| Inkrementell kompilering | ~170 ms |
| Ny prosess opp og svarende | ~70 ms |

**Kravet er innfridd, med 15–60 ms margin.** Men marginen er tynn, og
kompileringen er 69 % av budsjettet. En kompilator som er dobbelt så rask
sparer 85 ms; en som er tregere sprenger budsjettet umiddelbart.

### Hvordan det virker

Appen er en kompilert binær — den byttes i sin helhet, ikke lappes. Det som
gjør at det likevel oppleves som hot reload er proxyen:

```
endring oppdaget  ->  proxy pauses
                  ->  inkrementell rebuild
                  ->  ny prosess startes på den andre porten
                  ->  vent til den svarer
                  ->  proxy bytter port og slippes
                  ->  gammel prosess drepes (utenfor målingen)
```

To detaljer er verdt å nevne, fordi begge ble funnet ved å måle:

**Ny prosess startes før den gamle drepes.** Nedstenging tar 44 ms målt, og
den trenger ikke ligge i den kritiske stien. Byttet mellom to porter fjernet
den helt.

**Requests holdes, ikke avvises.** Under en rebuild holder proxyen
tilkoblingen i stedet for å koble til en port ingen lytter på. Verifisert med
fem requests avfyrt 40 ms etter lagring: alle fikk 200, lengste ventetid
202 ms. Det er dette PRD-en mener med at dev-serveren køer i stedet for å
vise feilside. En ekte kompileringsfeil vises derimot, som en side med
kompilatorens utdata.

Frontend går ikke gjennom løkka i det hele tatt. Vite kjører ved siden av og
gjør HMR selv; en endring i en `.svelte`-fil utløser ingen rebuild av
Pascal-siden.

## CLI-en

```sh
askr new minapp          # nytt prosjekt
askr serve               # dev-server, Vite inkludert
askr build
askr routes
askr make model Customer --migration
askr make controller Customer
askr migrate
```

Én binær, samme navn som prosjektet — konvensjonen cargo, go, deno og bun har
etablert. Den leser `askr.toml` i prosjektrota.

`askr new` lager et prosjekt som kjører med én gang: `app.lpr`, en
kontroller, en Svelte-side, Vite-oppsett og `askr.toml`. Malene er små med
vilje — et stillas som genererer femten filer man ikke forstår er verre enn
ingen stillas.

### Innlogging som stillas

`askr new` spør om prosjektet trenger innlogging. Svarer man ja — eller
skriver `--auth` — kommer `/login`, `/register`, `/logout`,
`/forgot-password` og `/reset-password/:token` med, sammen med en
`User`-modell og to migrasjoner. `askr make auth` gjør det samme i et
prosjekt som allerede finnes.

Spørsmålet stilles bare når kommandoen kjøres fra en terminal
(`IsATTY(Input)`). Uten terminal og uten flagg er svaret nei — en kommando
som venter på svar fra et rør henger for alltid, og et stillas som gjør det,
gjør det i CI.

Sidene er ren HTML, ikke Inertia. Et nytt prosjekt har Inertia satt opp, men
ikke installert, og `npm install` er noe man gjør etterpå; å kreve det før
man kan logge inn ville gjort innloggingen ubrukelig akkurat i det vinduet
der man trenger den. Alt havner i prosjektet, for det er hele poenget med et
stillas — man skal kunne endre innloggingssiden.

Valgene i den genererte koden som ikke er tilfeldige: samme svar på «finnes
ikke» og «feil passord», en brems på fem forsøk per e-post per kvarter over
cachen, reset-tokens lagret som hash og gyldige i én time, alle tokens for
adressen slettet ved bruk, og ny sesjon etter et passordbytte. Begrunnelsene
står i `docs/auth.md`.

### Velkomstsiden

Bygg og start, og `/` svarer med en gang — før `npm install`, før Vite, uten
nett og uten filer ved siden av binæren. Det var ikke tilfelle før:
`/` gikk gjennom Inertia, så et helt nytt prosjekt svarte med en blank side
til frontend var installert. Serveren virket hele tiden, men ingenting viste
det.

Siden viser arenaen som gjengir den — hvor mange bytes requesten har brukt så
langt, toppforbruket, hva som er reservert fra systemet, og hvor mange
requests akkurat den workeren har fullført. Laster du på nytt, hopper tallene,
fordi du treffer en annen worker med sin egen arena. Det er billigere enn en
logo og sier mer om hva rammeverket er.

Resten er fire steg med filstien først: hvor ruta står, hvor svaret lages,
hva som mangler før `/demo` er en Svelte-side, og hvordan man lager en modell.
Kommandoen som ikke er kjørt ennå er markert; de andre er ikke.

Siden ligger i `Askr.Http.Welcome`, ikke i prosjektet. Kontrolleren kaller den
på én linje, og du blir kvitt den ved å skrive noe eget der:

```pascal
function THomeController.Index(Req: TRequest): TResponse;
begin
  Result := WelcomePage(Req, 'shop');
end;
```

Inertia-demoen flyttet til `/demo`, der den kan kreve et byggesteg uten at
det første inntrykket blir en blank side.

Bygg CLI-en fra dette repoet med `./askr cli`. `repl` er ikke implementert:
den krever en tolk for Pascal-uttrykk, og er ikke verdt det før språkvalget i
fase 3 er tatt.

## Fase 3: Rún

PRD-en utsetter språkvalget til fase 3, og setter en port foran det: fem ting
måtte prøves før det var forsvarlig å begynne på et eget språk.

**Alle fem er nå prøvd, og alle fem gikk mot fase 3.** Bevisregnskapet ligger
i Rún-dokumentet; her står den siste porten og det som ble bygget på den,
fordi begge deler ligger i dette repoet.

### Rún v0.1

Rún er ute av `spikes/` og inn i rammeverket. Transpileren er `Askr.Run` i
`src/run/`, `askr build` kjører den over hver `*.run`-fil i prosjektet, og
`./askr test` kjører suiten som dekker den. Det som ikke endret seg, er
kostnadsregnskapet lenger ned — flyttingen gjorde koden til en del av
verktøykjeden, ikke til standardveien for datatilgang.

Språket har det Pascal ikke kan gi, og det er hele grunnen til at det finnes.

**Generics.** Én erklæring blir konkrete, typede funksjoner:

```
query<M> ById(id: int) -> M for Customer, Order
```

gir `CustomerById` og `OrderById`, hver med sin egen radtype. I Pascal ville
dette krevd to nesten like funksjoner — en generisk metode blir avvist av
kompilatoren, og det er funnet fase 3 hviler på.

**`with` for eager loading.** `with` er et reservert ord i Pascal og kan ikke
brukes som navn der. Her kan det, og relasjonen **erklæres ikke** — den leses
av fremmednøkkelen i skjemaet:

```
query ActiveCustomers(minBalance: money) -> [Customer]:
  from Customer
  where balance >= minBalance and active == true
  with orders
  order by balance desc, name
  limit 10
```

`TCustomerRow` får feltet `Orders: TOrderRowArray` fordi `orders.customer_id`
peker på `customers.id`. Ordrene hentes med **én** ekstra spørring, ikke én
per rad.

Resten av v0.1: `is null` / `is not null`, `like`, `offset`, flere
sorteringsnøkler, og `-> M` for én rad med `out Found`.

I en app er det ingen kommandoer å huske. `*.run`-filene ligger under `app/`,
og `askr build` oversetter dem til `.build/run/App.<Navn>.pas` før `fpc`
kjøres. En comptime-feil stopper byggingen med fil, linje og hva skjemaet
faktisk sier.

```
./askr run:demo
```

kjører kjeden hel i dette repoet: `.run`-kilde → introspeksjon av en ekte
database → typesjekk mot skjemaet → Pascal → `fpc` → binær som spør den
samme databasen. Selve transpileren er dekket av `tests/askr_run_tests.lpr`,
som går mot en ekte SQLite-database og holder fast at hver av de seks
comptime-feilene fortsatt sier det den skal.

Comptime-transpilering gir tre ting Norn-codegen ikke gir:

* **Typene kommer fra skjemaet.** `NUMERIC(12,2)` blir `Currency`,
  `TINYINT(1)` blir `Boolean`, `customer_id` blir `CustomerId: Int64`. Rún-kilden
  nevner ingen av dem, og den genererte koden har verken modellklasse,
  `published`-seksjon eller RTTI.
* **Feil fanges før `fpc` får se koden**, med skjemaet i meldingen:
  `table "customers" has no column "emial". Did you mean "email"?` og
  `"balance" is money in table customers, but is compared with text.`
* **Dialekten er en comptime-avgjørelse.** DSN-en i kilden avgjør
  plassholderform og siteringstegn; spørringene nevner ingen av delene.

**Og så kostnaden.** Comptime leser databasen på hver eneste bygging, altså
inne i utviklerløkka:

| Skjema | Comptime-introspeksjon |
|---|---|
| SQLite, 2 tabeller | 1 ms |
| SQLite, 32 tabeller | 2 ms |
| SQLite, 62 tabeller | 4 ms |
| Postgres, 1 tabell | 11 ms |
| Postgres, 21 tabeller | 21 ms |
| Postgres, 61 tabeller | 70 ms |

Utviklerløkka er målt til 247 ms av et krav på 300. Det er **53 ms å gå på**.
Mot SQLite er comptime gratis. Mot Postgres med 61 tabeller koster den
**70 ms — mer enn hele slingringsmonnet, alene**, og det er over et
containernettverk uten latens.

Varianten som passer, cacher skjemaet mellom byggingene og leser på nytt bare
når det er endret; parsing og utskrift uten introspeksjonen er 1–2 ms. Men å
cache skjemaet og skrive ut typet kode fra det, med en sjekk på om det har
endret seg, **er Norn-codegen**. Det som står igjen av forskjellen er hvor
fila ligger og om den sjekkes inn.

Derfor er Rún **et tilbud, ikke standardveien**: Urd og Norn er fortsatt
datalaget en ny app får. Rún er verdt å ha inne i rammeverket likevel, fordi
typesjekk mot et levende skjema gir feilmeldinger Norn ikke gir i dag — og
fordi den nå er i porten, og derfor ikke råtner. Mot SQLite, og mot Postgres
i mindre skjemaer, er den gratis å bruke i dag.

## Namespace

```
Askr.Core        arena, tekst, klokke, .env, config, logg, krypto
Askr.Http        server, request, response, ruting
Askr.Urd         modeller, query builder, connections
Askr.Urd.Pg      Postgres-driver
Askr.Urd.MySql   MySQL-driver
Askr.Urd.Sqlite  SQLite-driver
Askr.Norn        migrasjoner, introspeksjon, codegen
Askr.Run         Rún-transpiler (*.run -> Pascal)
Askr.Http.Client HTTP ut, med TLS-verifisering og strømming
Askr.Ai          Claude: tekst, strømming, verktøy, struktur
Askr.Console     kommandoene appen svarer på selv
Askr.Queue.Db    jobber som overlever omstart
Askr.Csrf        CSRF-token og middleware
Askr.Auth        innlogging og gates
Askr.Inertia     payload-bygging
Askr.Desktop     webview-vert
Askr.Testing     testrammeverk

App.Models.*     brukerens kode
App.Http.*
App.Schema.*     generert av Norn
```

## Sikkerhet

Et nytt prosjekt fra `askr new` er beskyttet mot CSRF fra første request.
Det er ikke noe man skrur på — `UseSessions`, `UseCsrf` og `UseAuth` står i
`app.lpr`, og en POST uten gyldig token svarer 419 før den når handleren din.

```pascal
{ Innlogging. Rammeverket ser aldri passordet — appen verifiserer selv og
  kaller Login med en id. }
if VerifyPassword(Req.Form('password').ToString, Bruker.PasswordHash) then
  Login(IntToStr(Bruker.Id), Req.Form('remember').ToString <> '');

{ Autorisasjon. En gate er en funksjon med et navn. }
DefineGate('edit-post', KanRedigere);
if Denies('edit-post', Post_) then
  Exit(RespondText('Forbidden', 403));
```

Tre ting som er verdt å vite fordi de er valg, ikke tilfeldigheter:

* **Kryptoen er ren Pascal.** Binæren skal starte på en maskin uten OpenSSL.
  TLS er valgfri; passordhashing er det ikke. Prisen er at hashen er
  PBKDF2-HMAC-SHA256 med 600 000 iterasjoner (målt til 573 ms på en M-serie
  Mac), ikke Argon2id — som er det anbefalte i 2026, men som bare finnes i
  libcrypto fra 3.2 og derfor ikke kunne kjøres i noe av testmiljøet.
  Utestet kode som hasher passord er verre enn ingen.
* **Alt er målt mot offisielle vektorer**: NIST FIPS 180-4 for SHA-256,
  RFC 4231 for HMAC, RFC 6070 for PBKDF2, RFC 4648 for base64. En SHA-256
  med feil byterekkefølge er stabil, konsistent og fullstendig verdiløs, og
  ingenting i en app ville sagt fra.
* **Rammeverket eier ikke brukermodellen din.** Det lagrer én ting —
  brukerens id, som tekst — og appen registrerer en loader som slår opp
  resten. En `TUser` fra rammeverket ville tvunget fram et bestemt skjema,
  og det første enhver ekte app trenger er en kolonne til.

«Husk meg» er en signert kake med utløpet inne i signaturen, ikke et token i
databasen. Den kan derfor ikke trekkes tilbake enkeltvis — det krever en
kolonne per bruker, og rammeverket kan ikke vite hvilken tabell den skulle
ligge i. Det står her fordi det er en reell begrensning.

`APP_KEY` i `.env` signerer den kaka. `askr key:generate` lager en ny, men
setter den ikke inn i fila selv: en nøkkel som byttes i stillhet logger ut
alle.

## Filopplasting

```pascal
function TFiler.Motta(Req: TRequest): TResponse;
var
  F: TUploadedFile;
  Sti: string;
begin
  if not Req.Multipart.Ok then
    Exit(RespondText(Req.Multipart.ErrorText, 400));

  F := Req.Upload('vedlegg');
  if F.IsEmpty then
    Exit(RespondText('No file', 422));

  { Klientens navn når aldri filsystemet: tilfeldig navn, sanert endelse.
    Det opprinnelige står i F.ClientName hvis du vil lagre det ved siden av. }
  Sti := F.StoreIn('storage/uploads');
  Result := RespondText(Format('%d bytes -> %s', [F.Size, Sti]));
end;
```

`Req.Form` leser både urlencoded og multipart, så de andre feltene i skjemaet
— og CSRF-tokenet — virker som før. `Req.Uploads(navn)` gir alle filene under
samme navn, som fra `<input type="file" multiple>`.

Parseren kopierer ingenting. Kroppen ligger sammenhengende i workerens
lesebuffer, og hver del er et utsnitt inn i det samme bufferet: en opplasting
på fem megabyte koster fem megabyte én gang, i bufferet som uansett måtte
lese dem.

To grenser, begge med vilje:

* **Taket er `MaxBodyBytes`**, 8 MB som standard. Hele opplastingen må få
  plass i minnet på én gang. Det holder for vedlegg, profilbilder og
  CSV-import, og det holder ikke for video. Å ta imot noe som ikke får plass
  i minnet krever at kroppen strømmes til disk mens den leses, og det er en
  annen form enn «kroppen er ett utsnitt».
* **Filnavnet fra klienten er ikke til å stole på.** Det er en tekst en
  angriper skriver. `StoreIn` bruker den ikke; `SafeName` rydder den hvis du
  vil vise den. Verifisert med en ekte opplasting av `../../onde navn.BIN`,
  som havnet i katalogen den skulle, under et tilfeldig navn.

## Kommandolinja

```
askr new <name>            askr about
askr serve  askr build     askr routes
askr test   askr config    askr list

askr make model|controller|migration|seeder|job|middleware <Name>
askr make auth [--force]

askr migrate               askr db:seed       askr queue:work
askr migrate:status        askr db:show       askr queue:status
askr migrate:rollback      askr db:table <t>  askr schedule:list
askr migrate:reset         askr db:wipe       askr schedule:run
askr migrate:fresh         askr schema        askr cache:clear
askr migrate:refresh       askr key:generate  askr down  askr up
```

**Migrasjonene kan ikke kjøres av verktøyet.** De er Pascal-kode som er
kompilert inn i appbinæren, og det samme gjelder rutene, jobbene og planen.
Derfor kjører `askr migrate` i praksis `app --migrate`, og `Askr.Console` i
rammeverket tar imot i den andre enden. Det betyr også at et prosjekt laget
i fjor får nye kommandoer ved å bygge på nytt, ikke ved å scaffolde om.

```
$ askr migrate:status
Version            State      Title
20260920144652     applied    Create posts

$ askr db:table posts
Column                   Type                 Null     Pascal
id                       INTEGER              yes  (pk) Int64
name                     VARCHAR(120)         no       string
created_at               DATETIME             no       TDateTime
```

`askr down` og `askr up` er ikke bare en beskjed: `UseMaintenance` i
ruteren svarer 503 med `Retry-After` mens fila ligger der, uten at serveren
startes på nytt. `db:wipe` nekter i produksjon uten `--force`.

### Det som med vilje ikke finnes

Laravel har `optimize`, `config:cache`, `route:cache`, `view:cache` og
`clear-compiled`. De finnes fordi PHP tolker kildekoden på nytt ved hver
request. I Askr **er** binæren cachen, og de kommandoene ville vært
seremoni uten virkning. `vendor:publish`, `package:discover` og `install:*`
hører til Composer. `make:cast`, `make:trait`, `make:provider` er
PHP-språkkonstruksjoner og service-containeren, som Askr har sagt nei til
med begrunnelse i `LARAVEL.md`. `tinker` krever en tolk for Pascal-uttrykk.

## Konfigurasjon og logg

Fire lag, i denne rekkefølgen: **ekte miljøvariabler**, `.env`, `askr.toml`,
standardverdien. Nøkkelen skrives med punktum og slås opp med understrek i
miljøet, så `app.port` er `APP_PORT`.

```pascal
LoadConfig;                        { .env og askr.toml, funnet oppover }
ConfigureLogFromEnv;               { LOG_LEVEL, LOG_FORMAT, LOG_FILE }

Opts.Port := Word(CfgInt('app.port', 8080));
Dsn := CfgOrFail('database.url');  { sier hvilken nøkkel og hvor det ble lett }
```

Miljøet vinner alltid. En utrulling skal kunne sette noe uten at en fil i
repoet endres, og `askr config` sier hvem som faktisk vant:

```
askr.toml  /srv/shop/askr.toml
.env       /srv/shop/.env
APP_ENV    production

APP_ENV           .env
DATABASE_URL      environment
app.port          askr.toml
```

Uten `--values` står bare nøkkel og kilde — utskriften er trygg å lime inn i
en feilrapport. Med `--values` vises verdiene, men nøkler som ser ut som
hemmeligheter er fortsatt skjult.

Loggen har nivåer og felter, og to formater:

```pascal
LogInfo('order placed', ['id', Ordre.Id, 'total', Ordre.Total]);
```

```
2026-09-20T10:52:54.226Z INFO  request method=GET path=/ status=200 ms=0
{"ts":"2026-09-20T10:52:55.633Z","level":"info","msg":"request","status":200}
```

Tekst i et terminalvindu, JSON-linjer i produksjon. Valget følger `APP_ENV`
når `LOG_FORMAT` ikke er satt — det eneste stedet i Askr der miljøet endrer
oppførsel av seg selv, og grunnen er at feil standard merkes med en gang:
enten er terminalen full av JSON, eller så er logginnsamleren full av tekst
den ikke forstår.

Tall og boolske står **usitert** i JSON. `"ms":"12"` lar seg ikke aggregere.

Rammeverkets egne linjer går samme vei: request-loggen, og hver upåaktet
exception fra en handler — den siste uansett om `LogRequests` er på, fordi
en 500 uten spor er en 500 ingen kan feilsøke.

## Soft deletes, tidsstempler og hendelser

```pascal
class procedure TPost.Describe(S: TSchema);
begin
  S.Table('posts');
  S.Timestamps;     { created_at ved INSERT, updated_at ved begge }
  S.SoftDeletes;    { Delete setter deleted_at i stedet for å slette }
end;

{ Hendelser er virtuelle metoder. Kompilatoren ser dem, og det finnes
  ingen observer å registrere. }
procedure TPost.BeforeSave;
begin
  if FSlug = '' then
    FSlug := Sluggify(FTitle);
end;
```

Rekkefølgen er `BeforeSave`, `BeforeInsert`/`BeforeUpdate`, SQL,
`AfterInsert`/`AfterUpdate`, `AfterSave`. For å avbryte: kast — en `Save`
som stille lot være å lagre ville vært verre enn en exception.

Tidsstemplene settes i **UTC**, av modellen og ikke av databasens `DEFAULT`.
En DEFAULT setter `created_at` ved INSERT og rører aldri `updated_at` igjen,
og da ser en rad som er oppdatert ti ganger like fersk ut som da den ble
laget. En `created_at` som allerede er satt overskrives ikke, slik at en
import kan bevare opprinnelige tidspunkter.

Med `SoftDeletes` utelater alle spørringer de slettede radene:

```pascal
TQuery<TPost>.New.Count;                { uten de slettede }
TQuery<TPost>.New.WithTrashed.Count;    { med }
TQuery<TPost>.New.OnlyTrashed.Count;    { bare de slettede }

Post.Delete;       { setter deleted_at }
Post.Restore;      { tar den tilbake }
Post.ForceDelete;  { sletter for godt }
```

`DeleteAll` sletter mykt når modellen har soft deletes, akkurat som
`Model.Delete` — at den ene slettet mykt og den andre hardt er den slags
forskjell ingen husker før en tabell er tom. `ForceDeleteAll` og
`RestoreAll` finnes for de to andre tilfellene.

**Query scopes krever ingenting av rammeverket.** En scope er en funksjon
som returnerer en spørring, typet og kjedbar:

```pascal
function NyestePoster(Antall: Integer): TQuery<TPost>;
begin
  Result := TQuery<TPost>.New
    .OrderBy(Posts.CreatedAt, Desc)
    .Limit(Antall);
end;

Liste := NyestePoster(10).WithTrashed.Get;
```

Den kan ikke være en klassemetode på modellen — returtypen ville
fremoverreferert klassens egen type, som er den samme grensen som gjelder
`TModelList<M>`.

## HTTP ut

```pascal
K := THttpClient.Create;
try
  K.WithBearer(CfgOrFail('anthropic.api.key'));
  R := K.Post('https://api.anthropic.com/v1/messages', Payload);
  if R.Ok then
    Behandle(R.Body);
finally
  K.Free;
end;
```

**Sertifikatet sjekkes, både kjeden og vertsnavnet.** Det siste er ikke en
detalj: `SSL_VERIFY_PEER` alene godtar et ekte sertifikat for et hvilket som
helst domene, og da er det ingenting igjen av beskyttelsen. `Insecure` finnes
for et selvsignert sertifikat i utvikling, og logger en advarsel hver gang
den brukes.

Strømming for SSE, som AI-svar kommer som:

```pascal
function TLytter.Bit(const Chunk: string): Boolean;
begin
  Skriv(Chunk);
  Result := not Avbrutt;   { False stopper lesingen }
end;

K.Stream('POST', Url, Payload, 'application/json', Lytter.Bit);
```

Omdirigeringer følges (307 og 308 beholder metoden, de andre blir GET),
chunked settes sammen igjen, og både tidsavbrudd, omdirigeringsdybde og
svarstørrelse har tak. Det siste er en sperre, ikke en optimalisering: et
svar uten Content-Length kan i prinsippet vare evig.

Klienten ber om `identity`, ikke gzip. Uten zlib kan den ikke pakke ut, og
å binde zlib for å spare båndbredde på et API-kall er feil bytte — Askr skal
starte på en maskin uten den.

Det som **ikke** er der: HTTP/2, proxy, cookie-jar, automatisk retry.

## AI

```pascal
K := TAiClient.Create;          { nøkkelen fra ANTHROPIC_API_KEY }
try
  WriteLn(K.Ask('Oppsummer denne ordren i én setning.'));
finally
  K.Free;
end;
```

Standardmodellen er **`claude-opus-5`**. Ikke fordi den er billigst, men
fordi modellvalg er appens avgjørelse; `K.Model` bytter den.

Strømming, verktøy og strukturert utdata:

```pascal
{ Svaret bit for bit. False fra callbacken stopper strømmen. }
K.Stream('Skriv en kort historie.', @SkrivUt);

{ Et verktøy er en Pascal-funksjon. RunTools kjører løkka: send, utfør
  det modellen ba om, send resultatet tilbake, gjenta. }
K.AddTool('vaer', 'Slår opp været på et sted',
  '{"type":"object","properties":{"sted":{"type":"string"}}}', @Vaer);
R := K.RunTools('Hvordan er været i Oslo?');

{ Strukturert utdata går gjennom et verktøy modellen tvinges til å bruke.
  Den formen virker på tvers av modeller og kan ikke svare med prosa ved
  siden av. }
Json := K.Structured('Hvem er hun?',
  '{"type":"object","properties":{"navn":{"type":"string"}}}');
```

Tenkning slås på med `K.Thinking := atAdaptive`, som sender
`{"type":"adaptive"}`. Den gamle formen med `budget_tokens` er avviklet og
blir **avvist med 400** av modellene her — det finnes en test som slår ned
på at den i det hele tatt forekommer i requesten.

Feil fra API-et blir `EAiError` med `Status` og `Kind`, der `Kind` er
Anthropics egen feiltype: `overloaded_error` for å prøve igjen,
`invalid_request_error` for å la være.

`TFakeAiTransport` tar imot requestene og gir svar som er lagt inn på
forhånd, slik at en app kan testes uten nett og uten nøkkel.

**Forbeholdet.** Ingen kall med en gyldig nøkkel er gjort fra dette repoet.
Det som *er* prøvd mot `api.anthropic.com` er et ekte kall uten nøkkel, som
kom tilbake som 401 med Anthropics egen feil-JSON, riktig parset — det
beviser DNS, TLS, requestformen og feilhåndteringen, ikke at et svar med
innhold kommer tilbake. Det er samme forbehold som på Windows-skallet, og
det står til noen har kjørt det.

## Varig kø

Køen ligger i prosessen som standard: ingen Redis, ingen supervisor. Det
koster at jobbene forsvinner ved en omstart — og en velkomst-e-post som
aldri ble sendt fordi noen rullet ut en ny versjon er ikke en
ytelsesdetalj.

`Askr.Queue.Db` legger dem i databasen appen allerede har:

```pascal
Lager := TDbJobStore.Create(Cfg('database.url'));
Lager.EnsureSchema;                  { askr_jobs og askr_failed_jobs }
SetQueue(TQueue.Create(Lager, 4));   { fire workere }
Queue.Handle('send-welcome', @SendWelcome);
Queue.Start;
```

Handlerne er uendret. `TQueue` og workerne er det også — det eneste som
byttes er hvor jobbene ligger, og det er med vilje: et eget worker-løp for
varige jobber ville gitt to sett regler for backoff, forsøkstelling og
arena-levetid, og de to ville drevet fra hverandre.

De to kopiene består. `Push` kopierer ut av kallerens arena mens kalleren
fortsatt eier bytene; workeren kopierer inn i sin egen før handleren kalles.
Ingen av dem kan hoppes over, og de gjelder begge lagrene.

Fire ting er valg, ikke tilfeldigheter:

* **Payloaden er tekst**, i praksis JSON. En nullbyte avvises ved `Push` i
  stedet for å bli stille ødelagt på vei inn i en TEXT-kolonne.
* **En jobb som gir opp flyttes til `askr_failed_jobs`**, den slettes ikke.
  Den er det eneste sporet av at noe skulle ha skjedd og ikke gjorde det.
  `RetryFailed` legger dem tilbake når det som var galt er rettet. Det
  samme gjelder en jobb uten registrert handler.
* **En forlatt reservasjon slippes etter fem minutter.** Dør prosessen midt
  i en jobb, blir den ellers liggende reservert for alltid.
* **Forsøkstelleren står i raden**, ikke i minnet, slik at en omstart midt i
  ikke setter den tilbake til null.

Uttaket bruker `FOR UPDATE SKIP LOCKED` der dialekten har det, og en
umiddelbar transaksjon i SQLite, som uansett har én skriver. Målt med 200
jobber og seks workere mot både Postgres og MySQL: ingen jobb kjørte to
ganger, ingen ble hoppet over.

## Alle tre dialektene

Grensesnittet ble tegnet med alle tre i tankene, og det holdt: Postgres
bruker `$1`, MySQL og SQLite bruker `?`, og `RETURNING id` finnes ikke i
MySQL. Derfor er «sett inn og gi meg id-en» én operasjon på driveren —
`InsertGetId` — og ikke noe query builderen setter sammen selv. Modeller,
query builder, validering og eager loading er bit for bit den samme koden
mot alle tre.

Datalaget er komplett for alle tre: drivere, introspeksjon, migrasjoner og
prepared statements med cache.

Målt mot Postgres 17: 5,8 kB arena for en request som henter fem rader med
eager loading av femten barn, og ingen vekst over 1000 slike requests.

## Hva steg 1 bevisst ikke gjør

* Ingen ruting. Handleren matcher stien for hånd til steg 5 lander.
* Ingen chunked transfer-encoding. Requester med `Transfer-Encoding` avvises
  med 501 i stedet for å tolkes feil.
* Ingen `Set-Cookie` med flere verdier. Responsen lar siste verdi vinne per
  headernavn; cookies får eget API i fase 2.
* Kun IPv4. IPv6 krever en annen adressefamilie enn `TInetSockAddr`.

## Lisens

Ikke bestemt.
