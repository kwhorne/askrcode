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
./askr make:check # generatorene: tre databaser, en socket og Chrome
./askr auth:check # en --auth-app over en socket: bekreftelse via mailen
./askr qr:check   # QR-kodene lest tilbake av Chromes egen strekkodeleser
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

**Arkitektur er en tredje akse, og `./askr test:amd64` er porten for den.**
Den bygger og kjører hele suiten for x86_64 i container — `--platform
linux/amd64`, eget `.build-amd64` fordi `.ppu`-filer er bundet til målet.
På Apple Silicon går det gjennom Rosetta og tar 15 sekunder, så det er
ingen grunn til å la være.

Alt her kjørte aarch64 fram til 0.9.1: maskinen, og Docker-imaget på den.
Første x86_64-bygg kompilerte ikke i det hele tatt, og da porten kom
fant den fire steder til. Alle var samme sak: **aldri cast inn i
`Currency`, tilordn.** Tabellen står under «Fallgruver», og den har vært
feil i notatet to ganger.

`./askr check` og `./askr pg`/`mysql` tar `ASKR_ARCH=amd64` på samme måte.

**`./askr mcp:check` er porten for MCP-lagets arkitektoniske innsats.**
Serveren ligger i verktøyet og ikke i appbinæren, motsatt av Laravel Boost,
fordi en app som ikke kompilerer ikke finnes — og det er nettopp da en agent
trenger å få vite hva som er galt. Porten kjører fire scenarier: et prosjekt
som ikke lar seg kompilere, et som gjør det, en `[askr] path` som ikke er en
utsjekking, og ingen prosjekt i det hele tatt.

`McpServe` kjøres **før `FindProject`**. Den skriver til stdout og avslutter
uten askr.toml, og for en klient er det ikke «ingen prosjekt» — det er en
parse-feil på protokollkanalen. Alt under `McpServe` eier stdout; én WriteLn
på feil side, og klienten ser søppel uten noe som sier hvor det kom fra.
Porten sjekker at hver linje er ett JSON-objekt, i alle fire scenariene.

**`Halt` finnes ikke på noen sti et verktøykall kan nå.** `FindCompiler` og
`BuildFlags` skrev meldingen sin til stdout og haltet — riktig i en terminal,
og under `askr mcp` både søppel på kanalen og en server som forsvant midt i
et svar. De kaster nå `ECliFatal`, som terminalen fanger øverst og skriver ut
akkurat som før, og som verktøyet svarer med. Den avgjørende asserten er en
`ping` etter kallet: uten den var to av de tre andre grønne likevel.

**En mislykket bygging er et vellykket kall.** `isError` er sann bare når
verktøyet ikke kunne kjøre — ingen prosjekt, ingen kompilator, en
rammeverkssti som ikke er en utsjekking. Blandes de to, prøver agenten å
rette feil ting. Begge retninger er mutasjonssjekket.

**En omdirigering av stdout inne i prosessen ble prøvd og forkastet.**
`TextRec(Output).Handle := StdErrorHandle` flytter hvor *denne* prosessens
Text skriver, ikke hvor fildeskriptor 1 peker — et barn ville skrevet rett
på kanalen likevel. Og ingenting i porten fanget at den ble fjernet, fordi
ingen sti under et verktøykall skriver til stdout lenger. En vakt ingenting
måler, som dessuten ikke dekker det den ser ut til å dekke, er verre enn
ingen. Trengs den, er det `dup2` på deskriptoren — og et scenario som viser
at den virker. Et verktøy som kjører noe ut, skal fange barnets utdata: det
trenger teksten til svaret uansett.

**`AGENTS.md` fra stillaset sier så lite den kan slippe unna med.** Alt om
rammeverket ligger bak `docs_search` og `docs_read`, som serverer docs for
nøyaktig den versjonen prosjektet pinner. En kopi i `AGENTS.md` ville vært
frosset den dagen prosjektet ble laget, i en fil brukeren eier, og de to
ville vært uenige første gang Askr oppgraderes — uten noe som sier hvem som
har rett. Det som står der er bare det en agent trenger før den vet at den
kan spørre, pluss de få tingene der det å ta feil er stille.

Porten holder det ene som faktisk driver: **hvert registrert verktøy er
nevnt i fila, og fila nevner ikke et verktøy som ikke finnes.** Begge
retninger, for én alene lar halvparten råtne.

**`askr mcp:install` skriver aldri over en fil som finnes.** Den leser den:
enten står det en askr-server der alt, eller så skrives linjene man skal
legge til ut. Filene bærer kommentarer, rekkefølge og formatering som en
parse-og-skriv-om mister, og noen av dem er JSONC, som parseren vår ikke
leser i det hele tatt. Forrige gang dette repoet redigerte en fil brukeren
eier — en `package.json`, ved å finne et kolon — traff det feil, erstattet
hele dependencies-objektet med en streng, og meldte suksess.

**En assert på meldingen er ikke en assert på oppførselen.** «Ukjent klient
avvises» sjekket teksten, og en mutasjon som skrev klagen og så falt tilbake
til standardklienten gikk rett gjennom. Den sjekker nå exitkoden og at ingen
fil ble skrevet.

**Docker Desktops mount-cache gjelder også sletting.** Verten gjorde
`rm -rf`, containeren så fortsatt katalogen, og `askr new` nektet fordi den
var der — porten døde da stille på en echo-linje. Samme feil som
`capture.sh` omgår fra den andre siden, der en skriving på verten leste som
tom inne i containeren. La containeren gjøre begge deler i samme kall.

**Et steg som alt under avhenger av, må ikke stå i `set -e` uten melding.**
Stillaset i porten var `>/dev/null 2>&1` uten `|| true`, og da det feilet
forsvant hele kjøringen uten et ord. Samme regel som den om at en port som
feiler uten å si hvorfor er verre enn ingen.

**Fang mutasjonskjøringer til fil, ikke gjennom en grep-kjede.** Flere av
kjøringene her skrev ingenting fordi utskriften ble spist av rørledningen,
og resultatet så ut som «ikke fanget». `cmd > /tmp/x 2>&1; grep ... /tmp/x`.
Og bekreft at lappen traff før du tror på resultatet — det er samme familie.

**`test`-verktøyet stopper en suite som henger; `askr test` gjør det ikke.**
Forskjellen mellom de to stiene er én ting, og det er ikke logikken — det er
hvem som ser på. Et menneske foran en terminal ser en suite stå stille og
trykker Ctrl-C, og vil ha utskriften mens den kommer. En agent kan ingen av
delene, og et kall som aldri returnerer tar økta med seg. Derfor fanger
verktøyet og sender en frist, kommandoen gjør ingen av delene, og begge går
gjennom én `RunTests`.

Fristen trekker pipa mens den venter i stedet for å vente og så lese: et
barn som fyller pipebufferet blokkerer på skrivingen, og en forelder som
bare ser på `Running` venter da på en prosess som venter på den. Etter
`Terminate` høstes barnet, men med et tak på to sekunder — en prosess som
overser SIGTERM skal ikke gjøre en stoppet heng om til en hengende igjen.

**Fire utfall der exitkoden tilbyr to.** En suite som ikke kompilerer og en
som feiler har begge exitkode ulik null og krever motsatt arbeid.

**Porten har et eget tak på hvert kall.** Uten det hang hele `./askr test`
da fristen ble mutert bort — en port som henger i stedet for å feile er
verre enn ingen, og det er samme feil ett nivå opp. `timeout` når den
finnes; taket er romslig, for det er siste utvei og ikke fristen som testes.

**`build` telte fire feil der det var én.** fpc følger én bom med tre linjer
egen oppsummering, alle på feilnivå. `CountDefects` teller bare diagnostikk
som har en **kolonne** — strukturelt, ikke tekstlig: fpc gir kolonne når den
peker på et token i kilden, og aldri på en oppsummering, uansett om den
bærer et linjenummer. Premisstesten holder det mot alle ni vektorene: tre
defekter i errors.pas, én i syntax.pas, identisk på alle tre verktøykjedene
og enig med fpcs eget tall.

**`FormatDiagnostics` er felles for `build` og `test`.** To formaterere
ville drevet fra hverandre, og da møter en agent samme kompilatorfeil i to
former avhengig av hvilket kall som fant den.

**Et `case` over en enum må dekke alle verdiene på trunk.** `CmdTest` lot to
stå igjen og trunk sa fra — 3.2.2 gjorde ikke det. Skriv ut den umulige
grenen i stedet for en `else`, så blir et sjette utfall en advarsel i stedet
for en stille default. Samme regel som den om død `else`, sett fra andre
siden.

**En port må ikke kappløpe med sin egen forrige prosess.** «Ingen testfil»
slettet katalogen rett etter heng-scenariet, mens containeren fortsatt
avsluttet. Den var grønn på aarch64 og rød på amd64, altså avgjort av
timing. Bruk et prosjekt som aldri hadde tester i stedet for å slette noe.

**Ingen verktøyutskrift inneholder et passord, og porten er en sveip over
hele strømmen.** Et prosjekt med et sentinel-passord i `.env` drives gjennom
hvert eneste verktøy, og det å finne strengen er feilen. Et verktøy som
legges til senere og lekker, fanges av en assert ingen måtte huske å skrive.

Den fant to ekte lekkasjer i driverlaget, begge eldre enn MCP:
`OpenDbConnection` kastet `DSN has no scheme: <dsn>` og MySQL-driveren
`Invalid MySQL DSN: <dsn>`. En DSN som er gal på én måte har fortsatt et
riktig passord i seg.

**`config`-verktøyet viser aldri en verdi, og har ikke noe flagg som gjør
det.** `askr config --values` er for et menneske foran sin egen skjerm.
Ingenting redigeres bort heller, for ingenting leses: en redaktør er en
ordliste, og `LooksSecret` sier selv i kommentaren sin at den ikke kan være
uttømmende. **Målt:** med `DATABASE_URL`, `MAIL_PASSWORD` og
`STRIPE_LIVE_ACCOUNT` i `.env` skjuler `--values` de to første og skriver
den tredje i klartekst.

**`routes` og `schema` fanger barnets utdata, de arver den ikke.** Det er de
første verktøyene som starter en prosess, altså akkurat det Mcp-overskriften
sa at et verktøy må gjøre. Mutasjonssjekket: bytter man fangsten mot arv,
feiler fire asserter — inkludert at stdout er ren JSON.

**Det ble ikke lagt til `--json` i `Askr.Console`, og planen tok feil om at
det trengtes.** Verktøyene sender appens egen utskrift gjennom uendret, så
en agent leser nøyaktig det en utvikler leser, og det finnes ikke et annet
format å holde i takt. Et verktøy som måtte *parse* utskriften ville trengt
det; ingen av disse gjør det. `schema` er derfor `db:show` uten argument og
`db:table` med — to kall i stedet for ett, og det er dessuten
rekkefølgen man leser et skjema i.

**`check_id` i porten sjekker ett svar, ikke strømmen.** To asserter var
grønne av feil grunn før den kom: «the tables are listed» traff en
feilmelding som inneholdt tabellnavnet, og «with no error» traff et helt
annet svar. Sveip over strømmen er riktig for det som *er* en egenskap ved
strømmen — at hver linje er JSON, at passordet ikke er noe sted — og galt
for alt annet.

**Mutasjonssjekk: bekreft at lappen traff før du tror på resultatet.** En
`str.replace` som ikke finner ankeret skriver fila uendret, porten blir
grønn, og mutasjonen ser ut til å være fanget av ingenting. Det skjedde her
med `schema`-verktøyets table-argument. `assert old in s` først.

**Docs-verktøyene leser prosjektets pin, ikke verktøyets eget tre.**
`DocsDirFor` går gjennom `ResolveFramework` — samme kall som byggstien — så
docs og kompilatoren kommer alltid fra ett tre. `askr mcp` kjøres før
`FindProject` og delegerer aldri, så binæren som svarer kan godt være en
annen utgivelse enn den prosjektet bygger med. Porten beviser det med et
fabrikkert rammeverkstre som har sin egen versjon og sin egen ene side:
verktøyet melder den versjonen og ser ikke dette repoets docs i det hele
tatt.

**Søket er eksakt delstreng, aldri fuzzy, og det er hele poenget.**
`Back.WithErrors` er feil navn for `BackWithErrors` — en feil som faktisk
ble gjort her, i første utkast av docs/. Et søk som strøk tegnsetting ville
matchet det mot det ekte navnet og levert en side som leses som
bekreftelse. Testen sier egenskapen direkte: **hvert treff må inneholde det
som ble spurt om.** Formulert slik holder den også når docs selv begynner å
omtale det gale navnet — og det var nettopp det som skjedde: første utkast
til `docs/cli.md` skrev «et søk på `Back.WithErrors` gir ingen treff», og
gjorde dermed sida til et treff selv. Literalen er ute av docs igjen.

**Et sidenavn bygger aldri en sti.** Det matches mot lista over hva som
faktisk ligger i katalogen, og bare et navn som kom tilbake derfra åpnes.
Å sette sammen en sti fra inndata og så lete etter `..` er den varianten
som har en feil i seg.

**`cmd_mcp_check` i `./askr` er skrevet på engelsk.** Resten av byggskriptet
er norsk fra før og blir stående; ny kode skrives ut engelsk, også her.

`tools/probes/run.sh <fpc>` kjører generics-probene mot en gitt kompilator.
Det er sju filer — seks grenser (p1–p6) og kallstedet (p7) som avhenger av
p2 — og **alle sju feiler fortsatt**, på 3.2.2 og på trunk. Probene er
engelske nå, og filnavnene fulgte med: `p2_generic_function_in_unit.pas`
og så videre. `run.sh` globber `p*`, så ingenting peker på de gamle navnene.

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

## WebAuthn

* **Attestasjon verifiseres ikke, og det er et valg.** Uttalelsen sier
  hvilken autentikator nøkkelen kom fra. Vanlig innlogging trenger ikke
  vite det, og å kreve det låser ute utstyr man ikke har tenkt på. Det
  står i unitens egen overskrift, i docs og i changeloggen, slik at
  ingen tror det er gjort.
* **Origin sammenlignes eksakt.** `https://example.com.evil.example`
  starter med riktig origin, så en prefikssjekk ville sluppet den
  gjennom. Mutasjonstesten avslørte at vektorene ikke fanget det — alle
  de gale origin-ene mine startet med noe annet. Fire varianter som
  *starter* med den rette står nå i fixturen nettopp for det.
* **Signaturen er over `authData ‖ SHA-256(clientDataJSON)`**, i den
  rekkefølgen. Byttes de om, feiler alle seks gyldige innlogginger —
  mutasjonssjekket.
* **ES256-signaturen kommer DER-kodet, ikke som rå r‖s.** DER skriver
  heltall med fortegn, så en komponent med høyeste bit satt får en
  ledende nullbyte, og små verdier er kortere enn 32 byte. Å kopiere
  rått inn i et 32-bytes felt gjør at noen signaturer verifiserer og
  andre ikke, tilsynelatende tilfeldig.
* **CBOR-leseren avviser ubestemt lengde, tagger og flyttall.** CTAP2s
  kanoniske form forbyr det første, så ingen ekte autentikator sender
  det. Å godta det ville lagt til en tilstandsmaskin i kode som leser
  data fra en angriper.
* **Lengder fra CBOR sjekkes mot det som er igjen av bufferet** før de
  brukes. En kartlengde på fire milliarder i en melding på hundre byte
  er ellers en løkke som ikke stopper.
* Telleren som skal avsløre kopierte nøkler er **et varsel, ikke en
  dom**: de fleste plattformautentikatorer teller ikke i det hele tatt
  og sender alltid null. Å nekte innlogging på det ville stengt ute det
  vanligste utstyret.
* **Stillaset wirer det opp fra 0.6.3.** Tabell, modell, fem ruter og
  rundt tretti linjer JS. Fire feil på veien, alle funnet ved å kjøre en
  virtuell autentikator over CDP — ingen av dem synlige ved lesing:
  - **Versjonskollisjon.** `SkrivMigrasjoner` bruker selv T og T+1, så
    min `+1` ga credentials samme versjon som password_resets.
    Migratoren hoppet over den som alt kjørt, tabellen ble aldri laget,
    og sikkerhetssida svarte 500.
  - **`Label` er et reservert ord**, så propertyen het `Label_` — og Urd
    snake_caser property-navnet, så kolonnen ble `label_` mens
    migrasjonen sa `label`. Heter nå `Nickname`.
  - **`/\\//g` i emittert JavaScript.** Pascal tolker ikke `\\`, så
    `\\/` kom ut som to tegn, den andre skråstreken lukket regexen, og
    `g` ble lest som en variabel. Feilmeldingen var «g is not defined»,
    som peker ingen vei.
  - **En IP kan ikke være RP ID.** `localhost` er gyldig, `127.0.0.1`
    ikke. Nettleseren sier bare «This is an invalid domain». Serveren
    sjekker det nå og sier hva man skal gjøre.

## Bilder

* **`SetExceptionMask` må settes før første libvips-kall.** Nøyaktig
  samme felle som Cocoa og GTK: Free Pascal slår på flyttallsunntak, og
  GLib — som libvips bygger på — regner rutinemessig med verdier som
  utløser dem. Uten masken dør prosessen med `EInvalidOp` inne i
  `vips_init`, og stakksporet peker på libvips. Funnet ved at prosessen
  døde, ikke ved lesing.
* **Askr.Image er ren Pascal, Askr.Image.Vips er ikke.** Skillet er ikke
  vilkårlig: kryptoen må være ren fordi enhver app med brukere trenger
  passordhashing, mens bildebehandling ikke er universell. Derfor
  `dlopen`, som TLS og driverne.
* **Opsjoner til libvips går i formatstrengen**, ikke som varargs:
  `.jpg[Q=80,strip=true]` er én peker over en variadisk grense. Det som
  gjenstår er erklært med FPCs `varargs`, så kompilatoren bruker
  plattformens konvensjon — å telle argumenter for hånd på arm64 er det
  `objc_msgSend` allerede har lært oss.
* **`Pointer(vips_init)` i Delphi-modus KALLER variabelen.** Adressen
  tas med en utypet `var`-parameter. Samme felle venter på enhver ny
  dlopen-binding.
* **Sniffing er en sikkerhetsfunksjon, ikke en bekvemmelighet.** Både
  filnavnet og `Content-Type` er tekst klienten skriver. En `.jpg` som
  er HTML er en lagret XSS hvis den serveres tilbake.
* Å lese dimensjoner uten å dekode er også **forsvaret mot
  dekompresjonsbomber**: en PNG på hundre kilobyte kan bli gigabyte.
* **Oppskalering gjøres aldri.** Et større, uskarpere bilde er aldri
  det noen ba om.
* Bildetestene kjøres i containeren, der libvips finnes, og hopper over
  seg selv på macOS med begrunnelse — som TLS-suiten.

## Kryptering av kolonner og TOTP

* **ChaCha20-Poly1305, ikke en egen konstruksjon.** HMAC i tellermodus med
  en MAC etter hadde virket, og hadde ikke hatt noe å holdes mot. RFC 8439
  har vektorer, Appendix A.3 treffer de vanskelige menteoverføringene i
  Poly1305, og `tools/vectors/aead.py` skriver 150 til fra
  python-cryptography. Generatoren ligger i repoet, i motsetning til den
  for ECDSA-vektorene.
* **Vektorene sjekkes før de skrives inn.** Et RFC-tilfelle jeg skrev en
  byte for langt ga et gyldig tag — Python regner jo ut hva man gir den —
  men ikke RFC-ens. Sammenlign med tallet i RFC-en, ikke bare med Python.
* **Poly1305 i fem 26-bits lemmer**, som poly1305-donna: produktet av to
  lemmer og summen av fem får plass i 64 bit. Valget mellom h og h − p
  gjøres med en maske, ikke en gren.
* **Formålet er associated data** i `SealText`, så en TOTP-hemmelighet
  kopiert til en annen kolonne ikke åpner der. Nøkkelen er `APP_KEY`
  gjennom HMAC med egen etikett.
* **HMAC-SHA1 finnes bare for TOTP.** Autentikator-appene regner SHA-1 og
  seks siffer uansett hva oppsettet ber om.
* **To sjekker i `VerifyTotp` var døde**: sifre og lengde. En kode som ikke
  er seks sifre kan aldri bli lik en, og sammenligningen sier det. Tatt ut;
  testene står.

## QR-koder

* **Tre ting holder koderen**: python-qrcode modul for modul ved fast
  maske (hver modul er da gitt av standarden), qrcodegen for masken
  straffepoengene velger, og Chromes `BarcodeDetector` i `qr:check`, som er
  det en telefon gjør. `tools/vectors/qr.py` skriver vektorene; den
  trenger `pip install qrcode qrcodegen`.
* **python-qrcode er ingen referanse for maskevalget.** Den regner
  straffepoeng med formatbitene lyse (`makeImpl(True, i)`), så 34 av 60
  valg var ulike før jeg leste koden dens. qrcodegen regner på det ferdige
  symbolet og leser regel 3 som 1:1:3:1:1 i hvilken som helst bredde, med
  stillesonen som lys — portert rett over, og 64 av 64 valg er like.
* **`BarcodeDetector` finnes bare i en sikker kontekst.** `about:blank` er
  ikke det; første prøve spurte Chromes egen omnibox-side, som har den, og
  så ut til å virke. Porten serverer kodene fra localhost.
* **Terminatoren var død i byte-modus.** Modus, lengde og hele byte gir
  alltid fire bit over, og avrundingen til hel byte legger dem til.
* **Én mutasjon overlever, og det er et svar**: gulv i stedet for
  tak-minus-én i balansen i regel 4. De er ulike bare når mørk andel er et
  helt antall femprosent fra halvparten, og med odde størrelser er det
  bare mulig ved nøyaktig 40 eller 60 prosent mørkt. Maskerte koder ligger
  rundt 50. Et søk etter et slikt tilfelle ble stoppet da regnestykket
  viste at det ikke finnes i praksis; formelen er qrcodegens.
* **`wait` på en drept prosess gir 143**, og under `set -e` avsluttet det
  `qr:check` etter at alle kodene hadde bestått. `|| true`.

## Elliptiske kurver

* **Lemmene i `Askr.Core.BigInt` er 32 bit, ikke 64.** Et 32x32-produkt
  pluss to bærere får akkurat plass i `UInt64`, så ingenting flyter over
  og uniten trenger ingen avskrudd overflytkontroll. Med 64-bits lemmer
  måtte produktet vært 128 bit, og den typen finnes ikke i FPC. Prisen er
  omtrent dobbelt så mange operasjoner. `./askr check` er beviset på at
  valget holder.
* **Reduksjon modulo p må være Solinas, ikke langdivisjon.** En
  verifisering er rundt 8000 feltmultiplikasjoner; den generiske veien
  ville gitt over hundre millioner operasjoner. Modulo n er generisk,
  fordi den brukes to-tre ganger per verifisering.
* **Barrett ble prøvd og forkastet.** `q1 * mu` blir 545 bit, så en
  avkortet 512-bits multiplikasjon kaster nettopp leddet man trenger. Det
  ville krevd en 1024-bits type for to operasjoner.
* **Verifisering trenger ikke være konstant-tid.** Den regner bare på
  offentlige verdier. Signering ville krevd det, og denne koden duger
  ikke til det.
* **`EcDouble`, `EcAdd` og `EcMul` må tåle at R er samme variabel som
  inndata.** Den første utgaven kalte `EcSetInfinity(R)` med én gang, og
  da var punktet borte før første runde leste det. Fiksen er at
  akkumulatoren er lokal og R skrives først til slutt. Testen
  «20G + G = 21G» fanget det.
* **Doblingsgrenen i `EcAdd` nås aldri av tilfeldige signaturer.** To
  uavhengige punkter har praktisk talt aldri samme x, så uten `EcAdd(G,G)`
  og `G + (-G)` som egne tester er den udekket — og en feil der ville
  dukket opp sjelden og uforklarlig. Begge er mutasjonssjekket.
* **To sjekker er dybdeforsvar og kan ikke bevises av vektorene:** at
  r og s ligger i [1, n-1], og at nøkkelen er på kurven. Med r = 0 blir
  u2 null og signaturen avvises uansett av regnestykket; et punkt utenfor
  kurven gir bare feil svar. Mutasjonstesten viste at begge overlever at
  sjekken fjernes. De står likevel.
* Vektorene er **generert med python-cryptography (OpenSSL)**, ikke
  hentet fra NIST. Det viser at Askr er enig med OpenSSL, ikke at begge
  følger standarden. Sies rett ut i suiten og i docs.

## Krypto, CSRF og auth

* **Kryptoen er ren Pascal, uten OpenSSL, og det er ikke en smakssak.**
  Binæren skal starte på en maskin uten OpenSSL. TLS er valgfri — en app bak
  en reverse proxy trenger den aldri — men enhver app med brukere trenger
  passordhashing. Legger du den på libcrypto, er «valgfri avhengighet» ikke
  lenger sant.
* Prisen er **PBKDF2-HMAC-SHA256, ikke Argon2id**. Argon2 finnes i libcrypto
  fra OpenSSL 3.2; bookworm har 3.0, og macOS-maskinen har ingen. Det kunne
  altså ikke kjøres i noe testmiljø, og utestet kode som hasher passord er
  verre enn ingen. Står i `Askr.Core.Crypto`.
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
* **Threadvar-en for sesjonen ryddes FØRST i `Commit`, ikke sist.**
  Sesjonen lever i request-arenaen og forsvinner ved `Reset`; threadvar-en
  gjør ikke det. Sto oppryddingen nederst, slapp to utganger forbi den — og
  den ene er helt vanlig: en anonym besøkende som starter en sesjon uten å
  skrive til den. Neste request på den workeren fikk da en peker inn i
  minne arenaen hadde gjenbrukt.

  **Den krasjet bare noen ganger, og det er det verste ved den.** Feilen
  viste seg som `EAccessViolation` da en nettleser hentet en css-fil rett
  etter en side på samme tilkobling. Bare css-en: 39 kB fikk plass i
  arenablokka som alt var i bruk og skrev oppå det gamle sesjonsobjektet,
  mens js-en på 330 kB fikk en ny blokk — det gamle minnet lå urørt, og
  samme bruk-etter-frigjøring gikk stille forbi. Funnet ved å kjøre et ekte
  nettsted på rammeverket, ikke av en test. Testen finnes nå, går gjennom
  ruteren, og er mutasjonssjekket.
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

## Sesjoner i databasen

* **`TSessionStore` eier kaka, id-en, flash-rotasjonen og fixation;
  `TSessionBackend` eier bare lagringen.** Fem metoder, og ingen av dem
  vet noe om cookies. Et lager to steder ville hatt to regler for når en
  flash forsvinner, og de ville drevet fra hverandre — samme grunn som at
  køen har ett worker-løp for begge lagrene.
* **`TDbSessions` ligger i `Askr.Session.Db`**, som `Askr.Queue.Db`, så
  `Askr.Session` ikke trenger å kjenne datalaget. `SessionsFromConfig` står
  der også, fordi den må kunne lage en `TDbSessions`.
* **Id-en lagres ikke, SHA-256 av den gjør.** En tabell med id-er er en
  tabell med innlogginger. Gaten sjekker begge veier — hashen er der,
  id-en er ikke — for en sveip etter noe fraværende beviser ingenting
  alene.
* **Forespørselens egen forbindelse brukes når lageret er bygget på appens
  pool.** En andre `Acquire` fra samme pool låser seg når alle workerne
  holder én og vil ha én til. Testen med en pool på én forbindelse er
  beviset: muteres delingen bort, venter den fem sekunder og kaster
  `EDbPoolError`. Bygget med `Create(Dsn)` rører den aldri
  forespørselens forbindelse, for den kan gå til en annen database.
* **Tabellen lages ved første bruk, ikke ved oppstart.** Appen skal starte
  med databasen nede — samme regel som `api_tokens`.
* **Utløpet sjekkes ved hver lesing, ikke bare av sveipen.** Sveipen går
  på omtrent én av 64 requester; en utløpt rad skal ikke være en sesjon i
  mellomtiden. Mutasjonssjekket.
* **Upserten er UPDATE og så INSERT**, fordi de tre dialektene staver
  upsert på tre måter. Taper INSERT-en på unik-indeksen — to requester fra
  samme nettleser med hver sin nye sesjon — gjøres UPDATE-en på nytt.
  Vinduet mellom de to setningene lar seg ikke treffe med timing, så
  `BeforeInsert` er en krok bare testen setter: den legger den andre
  requestens INSERT inn i vinduet hver gang. `tests/session_db.inc`
  kjøres på alle tre, fordi grenen hviler på at hver driver melder
  unik-brudd likt. Mutasjonssjekket begge veier: kaster den, feiler
  testen; svelges feilen uten UPDATE, har raden den andres data.
* **`./askr session:check` er porten.** To app-prosesser i én container mot
  samme base, på alle tre: logg inn på A, kjent på B, logg ut på B, og
  kaka fra *før* utloggingen avvises på A. Minne kjøres som kontroll og
  skal feile samme scenario — uten den kunne en grønn kjøring vært en port
  som ikke ser forskjell. Begge prosessene i én container, så en
  SQLite-fil ligger på én kjerne.


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

### Hva som er prøvd, og hva det avslørte

**Laget er kjørt mot `api.anthropic.com` med en gyldig nøkkel**, og alle
fire tingene virker: tekst, strømming, verktøykall og strukturert utdata,
pluss adaptiv tenkning. `examples/ai/aiprobe.lpr` er den kjøringen. Den er
et *eksempel* og ikke en test, fordi en suite som bare kan kjøres av folk
med en legitimasjon er en suite de fleste ikke kan kjøre.

**Den kjøringen fant en feil ingen fake kunne finne.** Verktøyløkka sendte
assistentens *tekst* tilbake uten `tool_use`-blokkene den hadde spurt med,
og API-et avviser da resultatene som følger:

> each `tool_result` block must have a corresponding `tool_use` block in
> the previous message

Kommentaren i koden sa troen rett ut: «The text is enough». Suiten var
grønn hele tiden, fordi den sjekket formen jeg trodde på — ikke den
API-et krever. **Det er hele grensen for en fake: den holder JSON-en opp
mot din egen forestilling.**

Den andre halvdelen av samme feil: hvert resultat lå i sin egen melding.
Bare det første er da i meldingen rett etter assistentens tur, så resten
avvises. Fake-testen hadde bare ett verktøykall per tur og kunne ikke se
det — en mutasjon som droppet alle resultater unntatt det første gikk rett
gjennom. Testen har nå en runde med to parallelle verktøykall, og begge
halvdelene er mutasjonssjekket.

**Adaptiv tenkning finnes ikke på alle modeller.** Haiku 4.5 svarer 400
med «adaptive thinking is not supported on this model» — som er feilstien
som virker. Probe-en bytter til Sonnet 5 for det ene steget.

## Tall og datoer i leserens format

* **Dataene er generert fra ICU, ikke skrevet for hånd.**
  `tools/lang/formats.mjs` leser node sin ICU (78.3, CLDR 48) og skriver
  `Askr.Core.LangData` og `tests/vectors/formats.txt` — 59 locales og
  2065 vektorer. Mønstrene trekkes ut med `formatToParts`, så ingenting
  gjettes fra en ferdig streng. Rører du `Askr.Core.Format`, er det
  vektorene som avgjør.
* **V8s `format()` bytter U+202F mot et vanlig mellomrom, `formatToParts`
  gjør det ikke.** Første kjøring ga 194 avvik av det alene. Literalene
  normaliseres i generatoren.
* **Minus er hele prefikset foran første siffer**, ikke ett tegn. Arabisk
  har et LRM-merke foran minustegnet, og norsk bruker U+2212.
* **Dagsperiodene er én per time, 24 stykker.** zh-TW har flere enn to
  (凌晨, 上午, 中午 …), så am/pm er for smalt. `am`/`pm` i en lang-fil
  fyller tabellen for de to halvdelene.
* **En måned er tall bare hvis den bare er sifre.** Koreansk «1월» og
  vietnamesisk «thg 1» begynner med et siffer, men er navn.
* **Ingen locale her skriver andre sifre enn 0–9, og generatoren nekter
  en som gjør det.** Det fantes en sifferavbildning i Pascal, men ingen
  locale nådde den — altså utestet. Den er tatt ut; kommer persisk, må
  den inn igjen med en test.
* **`-0,00` finnes ikke i FPC.** `FloatToStrF(-0.001, ffFixed, 18, 2)`
  gir `0.00` på begge arkitekturer. En vakt mot det overlevde
  mutasjonssjekken og er borte; testen holder premisset.
* **`Trans` formaterer ikke tall selv, og skal ikke.** Et årstall er også
  et tall, og nb grupperer fra fire sifre: «2 026». Kalleren formaterer
  det som skal formateres — valideringsgrensene gjør det, med
  `LocaleNumber` og `LocaleCurrency`. Samme regel i Lauf: `numbers()` er
  eksplisitt, ikke noe `strings()` gjør med plassholderne.
* **`<html lang>` må oppdateres i klienten.** Serveren setter den ved
  første last, men et Inertia-besøk bytter ikke dokumentet. Layouten fra
  stillaset har en `$effect` for det, og `make:check` sjekker at den
  følger med uten omlasting.
* **`dates()` bygger datoen av delene, den parser ikke teksten.**
  `new Date('2026-02-03')` er midnatt UTC, altså 2. februar vest for
  Greenwich. Testen setter `process.env.TZ` til Los Angeles selv, for
  porten kjører i Oslo, der mutasjonen som parser teksten ellers går rett
  gjennom.
* **Genererte sider formaterer penger, desimaltall og datoer, ikke
  heltall.** Et årstall er et heltall, og «2,026» er ikke et år. Skjemaene
  beholder rå form, for det er den en input tar.
* **DataGrid skrev «selected» og «pages» rett i markupen.** Sveipen etter
  engelske literaler i `strings.test.js` så bare etter strenger i
  anførselstegn og mellom tagger, ikke etter et ord bak en interpolasjon.
  Den ser etter det også nå.

## Changelog

* **CHANGELOG.md og UPGRADE.md er ikke det samme.** Changeloggen er hele
  regnskapet — added, changed, fixed. UPGRADE.md er den korte: bare det
  som kan brekke koden din, og det er den `askr update` skriver ut.
  Blander man dem, blir enten oppgraderingsnotatene uleselige eller
  changeloggen ufullstendig.
* Nettstedet leser CHANGELOG.md gjennom `content/build.mjs` og lagrer
  **én rad per versjon**, ikke én klump. Det gir hver utgivelse sitt eget
  anker og lar søket treffe en enkelt versjon.
* En tom `## Unreleased` hoppes over i byggingen. En utgivelsesside som
  åpner med «Nothing yet» er støy.

## Versjoner og pakkelaget

* **En utgivelse er ett tall over to økosystemer.** Pascal-kilden og
  `@askrcode/lauf` på npm må si det samme. De *hadde* allerede drevet fra
  hverandre — CLI-en sto på 0.6.0, package.json på 0.1.0 — og ingenting
  sa fra. `Askr.Core.Version` eier tallet nå, og en test i
  `askr_runtime_tests` leser package.json og feiler hvis de er ulike.
  Driver de, får du en `DataGrid.svelte` som ikke passer `Askr.Urd.Grid`,
  og det merkes først når en kolonne slutter å sortere.
* **Kilden er artefakten.** 2,2 MB som kompilerer på 1,43 s, så det
  distribueres ingen binærer. `.ppu`-filer er dessuten bundet til
  nøyaktig FPC-versjon, så en delt cache av dem ville vært en felle, ikke
  en optimalisering.
* **`path` i askr.toml vinner over `version`**, samme rolle som `replace`
  i go.mod. Den gamle toppnivåformen `askr = "..."` leses fortsatt som
  `[askr] path`, slik at prosjekter fra før versjonering bygger urørt.
* **`[askr]` må stå sist i det stillaset skriver**, sammen med `[app]`.
  En seksjon gjelder alt under seg — samme grunn som at `[app]` allerede
  sto sist.
* **Integritetssjekken sammenlignet verdien med seg selv.** `CmdInstall`
  falt tilbake til `L.Commit` når cachen alt var full, og da kunne en
  tuklet lock aldri oppdages — altså i det vanlige tilfellet. `CommitOf`
  leser commit-en ut av utsjekkingen i stedet. Mutasjonssjekket: riktig
  commit gir 0, tuklet gir 1.
* **Bare verdien byttes i package.json.** Første utgave tok
  `Pos(':', Linje)` — den *første* kolonen på linja — og på en kompakt
  package.json tilhører den `"dependencies"`, ikke `"@askrcode/lauf"`.
  Hele dependencies-objektet ble da erstattet av én streng:
  `@inertiajs/svelte` forsvant og JSON-en ble ugyldig. Den skrev altså
  over en fil brukeren eier, uten å si fra. Nå finnes kolonen etter
  nøkkelen, og det sjekkes at første tegn etter den er et anførselstegn
  — ellers avvises linja i stedet for å gjettes på. Prøvd mot tre
  former: kompakt, stillasets, og en verdi som selv er et objekt.
* **Urd serialiserer en modell med KOLONNENAVNET, ikke property-navnet.**
  `ReleasedOn` i Pascal kommer ut som `released_on` i Inertia-payloaden.
  Det merkes ikke på ettordsfelter, som er alt doc_pages har, og det er
  derfor det sto uoppdaget: `Components/Index.svelte` leste `needsBits`
  mens serveren sendte `needs_bits`, så «Bits UI»-merket hadde **aldri**
  vist seg på komponentoversikten. Tretten komponenter skal ha det.
* **`FrontendDir` er allerede absolutt.** Å legge `Root` foran ga en sti
  som aldri fantes, og funksjonen som pinner Lauf gjorde da ingenting og
  meldte suksess. «Fant ikke fila» skal ikke bety «alt i orden».
* **Delegering løser at `AskrUnits` er kompilert inn i verktøyet.** Et
  0.6.0-verktøy som bygger mot 0.7.0 ville ikke lagt en ny unit-katalog
  på søkestien, og feilen hadde vært «unit not found» langt fra årsaken.
  `askr` bygger derfor den pinnede versjonens CLI én gang og kjører den
  — `ASKR_DELEGATED=1` hindrer ring. `install`, `update`, `outdated` og
  `new` delegerer aldri; de styrer pinnen. En lokal `path` delegerer
  heller ikke, ellers kunne man ikke teste en endring i CLI-en.
* Byggingen av delegaten **fanges og vises bare ved feil**. Byggskriptet
  `./askr` er et arbeidsverktøy og skriver norsk; det skal ikke havne
  foran en som bare ville kjøre `askr build`.
* **En nøyaktig pin gjør at `update` aldri flytter seg.** Det er riktig,
  men uten forklaring motsier det `askr outdated`, som nettopp sa at noe
  nyere finnes. Kommandoen sier hva den fant og hva man skriver.
* Versjonsområder skrives som i package.json — `^`, `~`, `*` — med
  vilje. `^0.6.0` følger npm-regelen for nullmajor og slipper ikke
  `0.7.0` gjennom.

## Generatorene

* **`Askr.Cli.Plan` leser en tabell til det en resource trenger, og skriver
  ingenting.** Den lager en `TFieldSpec` per kolonne — samme record som
  `make model` parser fra kommandolinja — og regel, type og
  `EmptyIsNull`-linje kommer fra de samme funksjonene. Porten i
  `./askr make:check` er nettopp det: spesifikasjon, migrer, les tilbake,
  og planen skal gi **linjene make model skrev i fila**, begge veier. Å
  telle linjer var første utkast, og det ville gått grønt med én linje
  byttet mot en annen.
* **Lengden leses ut av den deklarerte typen i planen, ikke i
  introspeksjonen.** SQLite oppgir bare teksten `VARCHAR(60)`. `MaxLength`
  er med i avtrykket, så å fylle den der ville fått hver SQLite-tabell til
  å se endret ut for `schema:check` etter en oppgradering.
* **SQLite deklarerer `BOOLEAN`, `JSON TEXT` og `UUID` for nye tabeller.**
  Affiniteten avgjøres av den deklarerte typen, og `JSON TEXT` inneholder
  `TEXT` og beholder derfor TEXT-affinitet. Eksisterende tabeller er urørt.
  `docs/migrations.md` hadde sagt `TINYINT(1)` for en SQLite-boolsk; det
  var `INTEGER`.
* **MySQLs uuid er CHAR(36) og leses tilbake som string(36)**, fordi det er
  det den er. Det er det ene unntaket porten har, og det den sjekker der er
  at planen sier det i et notat — ikke at den gjetter.
* **Hemmeligheter skjules, lukket til noen åpner.** En kolonne som ser ut
  som et passord, token eller hash skjules fra JSON og holdes ute av skjema
  og liste. Feilen i den retningen merkes; en lekket hash gjør ikke det.
* **`make:check` sier bare det den viste.** Den teller ok, feil og hoppet
  over, og uten node eller Chrome er sluttlinja «holds for what ran» — ikke
  påstanden om at sidene virker i en nettleser. En port som melder grønt
  for noe den ikke kjørte, er samme feil som en suite som melder grønt på
  kode som ikke kompilerer.
* **Én nøkkelordliste**, `IsPascalKeyword` i `Askr.Norn.Codegen`. Den gamle
  i Norn hadde 41 av 67, `make model` hadde sin egen lengre, og en kolonne
  som het `until` ga en schema-unit som ikke kompilerte.
* **`make resource` kjører i verktøyet, ikke i app-binæren.** Den trenger
  databasen, og det var grunnen til å tenke app-binær — men verktøyet
  linker alt driverne og introspeksjonen for Rún. Da slipper kommandoen å
  kreve en app som bygger før filene som får den til å bygge finnes, og
  den ligger ved siden av de andre `make`-kommandoene og `RefuseExisting`.
* **`Add` og `Remove`, ikke `Create` og `Destroy`.** Det er konstruktøren
  og destruktoren til `TObject`, og en metode med samme navn skygger.
* **`Req.FillInto(M, [kolonner])` er det genererte kontrollere bruker.**
  Énargumentsformen fyller alt modellen mapper, og en klient som la
  `created_at` i kroppen satte den. Den genererte testen sender en
  forfalsket `created_at` og sjekker at den ikke landet — mutasjonssjekket
  begge veier.
* **Rutene er én prosedyre i kontroller-uniten**, kalt av både `app.lpr`
  og testen. To lister over de samme sju rutene ville vært to lister.
* **Testen kjører på `TEST_DATABASE_URL`, og `sqlite::memory:` uten**, med
  migrasjonene først. Den kan ikke skrive i databasen man utvikler mot.
* **Svelte-sidene er ikke typet mot noe.** Det er det ene stedet kjeden
  ikke er lukket, og sidene sier det øverst. `pages.mjs` sjekker at de
  kompilerer uten advarsel og at hver import finnes — ikke at de virker.
* **Det gjør nettleserdelen av `make:check`.** Appen i containeren, Vite
  på verten, Chrome over CDP: opprett, vis, rediger, avvist skjema, liste,
  søk, sortering og sletting, og axe med kontrast over hver side, lys og
  mørk, 1280 og 390 px, **både tom og med rader**. Den fant tre ting ingen
  annen del av porten så:
  - **Hver POST fra en Inertia-side ga 419.** XSRF-kaka settes bare når
    tokenet finnes, og ingenting på en Inertia-side laget det. Klienten
    svarer 419 med å laste på nytt, så skjemaet kunne aldri sendes — i
    enhver ny app, ikke bare en generert. En Inertia-side lager tokenet nå.
  - **`align: 'end'`** på tallkolonnene. DataGrid kjenner bare `'right'`.
  - **En tom DataGrid hadde ingen tabstopp.** Den ene cellen i
    tabrekkefølgen sto på første rad, så uten rader var tabellen,
    sorteringsknappene med, utenfor rekkevidde for tastatur. axe så det
    bare på den tomme lista; første kjøring hadde en rad liggende igjen og
    var grønn. Derfor to axe-runder, og den andre feiler hvis raden mangler.
* **`--api` fant det verste av alt, over en socket.** Når en handler
  kastet, kjørte ikke etterfiltrene — og `ReleaseDb` er ett. Hver 403 fra
  `AuthorizeScope` og hver 500 beholdt forbindelsen sin fra poolen til den
  var tom. Symptomet som fant det var mindre: en 401 uten
  `WWW-Authenticate`, fordi token-filteret som legger den på heller ikke
  kjørte. `TTestClient` driver ruteren og så det aldri — der kom 403 ut
  som et unntak, så ingen test kunne se den. Ruteren svarer nå et
  `EHttpError` under 500 selv og kjører filtrene; alt annet får filtrene
  kjørt med en 500 i hånda og kastes videre. Porten sender førti
  avvisninger og ber så om lista, og mutasjonen som tar det bort feiler.
* **Beskrivelsen av et API står ved siden av rutene**, i samme unit, og
  `askr openapi --check` kjøres rett etter genereringen. En generator som
  drev fra seg selv første gang ville vært en løgn i sin egen port.
* **`PATCH`, ikke `PUT`.** `FillInto` lar det som ikke sendes stå, og det
  er det `PATCH` betyr. En `PUT` ville lovet å erstatte hele raden.
* **Tre feil ble funnet ved å lese, før nettleseren:** en tom dato ble
  `1899-12-30` i JSON; `datetime-local` sender ikke sekunder når de er
  null — `SqlToDateTime` avviste det, og `FillInto` beholdt den gamle
  verdien uten et ord; og en nullbar referanse kunne aldri bli NULL, fordi
  0 er det Pascal har. `ZeroIsNull` er svaret, og `make model` skriver den
  for hver referanse.
* **En fjerde «feil» var ingen, og mutasjonssjekken sa det.** Jeg trodde
  `Required` på en dato ikke kunne feile, fordi validatorens `AsStr` gjør
  0 om til `1899-12-30`, og rettet den. Mutasjonen som fjernet rettelsen
  overlevde: `Required` spør `IsBlank`, som alltid har lest en dato og et
  tall på 0 som tomme. Rettelsen er tatt ut igjen, og changeloggen sier
  ikke noe om den. En mutasjon som overlever er et svar, ikke bare et hull.

## Mange-til-mange

* **`BelongsToMany` slår aldri opp målets meta i `Describe`.** Pivot og
  nøkler utledes av klassenavnene. To modeller som nevner hverandre ville
  ellers bygget hverandres meta mens deres egen var halvferdig. `BelongsTo`
  hadde den fella uten oppgitt eiernøkkel; nå slås nøkkelen opp av
  `OwnerKeyOf` når relasjonen lastes. Mutasjonen som leser målets meta i
  `Describe` igjen, ender i exitkode 139 — stakken går tom.
* **`LoadManyToMany` står i interface-delen av `Askr.Urd.Query`.** En
  generisk metode kan ikke kalle en rutine uniten holder for seg selv:
  `TQuery<M>` spesialiseres i kallerens unit, og derfra må kallet løses.
* **Kolonnene selekteres som seg selv — `"tags"."name" AS "name"`** — og
  pivotens nøkkel under et navn ingen modell kan ha. Da finner `Hydrate`
  dem uansett hva driveren kaller en kvalifisert kolonne.
* **`Detach([])` fjerner ingenting; `DetachAll` er det som tømmer.** En
  tom liste som tilfeldigvis var tom skal ikke kunne slette alt. `Sync([])`
  tømmer derimot, fordi det er det som ble bedt om.
* **`Sync` har egen transaksjon bare når kalleren ikke har en.** Testen
  ruller tilbake en ytre transaksjon og krever at synken forsvinner med
  den — mutasjonen som alltid åpner egen, dør på «cannot start a
  transaction within a transaction».
* **Testene er én fil, `tests/pivot.inc`, i alle tre suitene**, slik
  `queue_db_conc.inc` er det. Hver suite definerer `PivotStart` og
  `PivotOk` før include-en. Anonyme prosedyrer finnes ikke i 3.2.2, så
  unntak testes med try/except, ikke med en lambda.
* **`InputIds` sier om nøkkelen ble sendt, ikke bare hva den inneholdt.**
  Det er hele forskjellen på en PATCH som lar taggene være og et skjema der
  alle boksene er avkrysset bort. Et HTML-skjema sender ingenting for null
  bokser, derfor en skjult tom `tag_ids[]`: tom verdi hoppes over uten
  klage, og nøkkelen er der.
* **Én regel for navnet: pivotens nøkkel til den andre tabellen, i
  flertall** (`IdsInputName`, `tag_id` → `tag_ids`). Kontrollerne,
  OpenAPI-dokumentet og skjemaet spør alle den, så de kan ikke kalle det
  noe forskjellig.
* **En pivot er to fremmednøkler til to ulike tabeller og ingenting
  annet enn en id og tidsstempler.** Én kolonne til er data om koblingen,
  og da er tabellen en ressurs med to `BelongsTo`. `PivotOf` returnerer
  sidene sortert på tabellnavn: SQLite lister fremmednøkler baklengs, og
  en melding som navnga sidene forskjellig på hver database ville lest som
  to ting. Funnet av enhetstesten, ikke ved lesing.
* **`TModelList` bor i `Askr.Urd.Query`, ikke i `Askr.Urd.Model`.** Første
  kjøring av `make:check` bygde ikke: modellen fikk list-typen uten
  uniten. En modell som også skjuler kolonner har `Askr.Urd.Query` i
  implementation-delen fra før, og en unit nevnt to ganger kompilerer
  ikke — `ModelUnitText` ser etter det.
* **Rundgangen mellom to units spørres før linjene å legge til.** Ellers
  ville `make resource Tag` bedt noen skrive nettopp den syklusen.
  `make:check` kjører Tag etter at Gadget har relasjonen, og krever
  meldingen.
* **Linjene `make pivot` skriver ut, er de porten legger inn i modellen.**
  Porten sjekker at de står i loggen og setter dem inn der de sier. De
  samme linjene kommer fra `ManyToManyModelLines`, som `make resource`
  også bruker — to kopier ville sagt forskjellige ting første gang én av
  dem ble endret.
* **Redigering etter PUT svarer 303, også når den avvises.** Den
  genererte testen ventet 302 og feilet i porten på alle tre databasene;
  koden var riktig, testen tok feil.
* **`Seq` i de genererte testene startet på millisekundet, og testunits
  deler tabeller.** Gadgets-testen lager makers som foreldre, Makers-testen
  lager makers, og da Gadgets-testen fikk flere rader enn det gikk
  millisekunder før Makers-testen startet, kom et unikt navn igjen. Bare
  MySQL var rask nok til å vise det, og bare fordi tag-testen la til rader
  — feilen var eldre enn den. Nå tusen fra hverandre per millisekund. Og et
  unikt eksempel tar **slutten** av tallet (`SeqTail`), ikke starten: med
  `Copy(..., 1, n)` var en kort kolonne lik for hver rad i en kjøring.
* **Et unikt tall fikk hele `Seq` som eksempel**, og det er langt forbi en
  32-bits `INTEGER` på Postgres og MySQL og forbi money sin
  `NUMERIC(12,2)`. SQLites `INTEGER` er 64 bit, så ingenting sa fra — og
  porten hadde ingen unik tallkolonne. Nå `Seq mod` det typen tåler, og
  hele bare i `BIGINT`. `notes` i `make:check` har `rank` og `fee` for det;
  mutasjonen tilbake til `Seq` gir «out of range» på begge serverne.
* **Lauf `<Checkbox value>` er en gruppe.** Bokser med samme navn og hver
  sin verdi holder de avkryssede som en liste i `<Form>`. Det er en
  oppførselsendring for en enkelt boks med `value` — den står i UPGRADE.md.

## Språk

* **Rammeverkets engelsk er kompilert inn, ikke kopiert inn i appen.**
  `lang/en.toml` fra stillaset er tom. En kopi av alle meldingene ville
  vært frosset den dagen prosjektet ble laget — samme grunn som at
  `AGENTS.md` er kort. Oppslaget går lokalet, fallback, innebygd engelsk,
  nøkkelen selv.
* **Uten lang-katalog er hver melding nøyaktig som før.** Det er testet
  ord for ord; den innebygde teksten er den gamle, og `:attribute` er
  kolonnen når ingen fil sier noe annet.
* **Plassholdere erstattes lengste navn først**, så `:min` ikke tar
  starten av `:minimum`. Mutasjonssjekket.
* **Lokalet er per tråd, og `Start` setter det på hver request.** At neste
  request begynner på standarden, skyldes `Start`, ikke oppryddingen i
  `Finish` — mutasjonen som fjernet oppryddingen overlevde først, og det
  var testen som tok feil. Det `Finish` beskytter, er kode på samme tråd
  etter requesten; den har nå sin egen assert.
* **`Vary` legges til, den settes ikke.** `WithHeader` lar siste verdi
  vinne, og Inertias `Vary: X-Inertia` står der allerede.
* **Lang-filene har egen leser, ikke `ParseTomlInto`.** Den dekoder `\"`,
  `\\`, `\n` og `\t`, og en linje som ikke er noe er et problem med
  linjenummer. Å endre hvordan `askr.toml` leses for å få det, ville vært
  å flytte en risiko inn i konfigurasjonen.
* **Laufs ord er én liste på to steder**: `frontend/lauf/src/strings.js`
  og `lauf.*` i `Askr.Core.Lang`. En test i `askr_runtime_tests` leser
  JS-fila og krever samme nøkler og samme engelsk begge veier — samme
  grep som versjonstesten. Plassholderne er `:navn` også i Lauf, så en
  oversettelse går fra lang-fila til knappen uendret.
* **`lauf`-propen sendes bare når lokalet sier noe annet enn engelsk.** En
  side på engelsk bærer ingenting av det. `laufContext` tar funksjoner,
  så et språkbytte vises på neste side uten omlasting.
* **Konteksten gis ved `mount`, ikke i layouten.** En Inertia-side pakker
  seg selv i `<Layout>`, så siden er layoutens forelder, og det layouten
  gir med `provideLocale` finnes ikke for sidens eget skript. `make:check`
  fant det: den genererte lista skrev datoene på engelsk mens søkefeltet i
  samme grid — opprettet inne i layouten — sa «Søk». `laufContext` i
  `main.js` legger begge ved roten.
* **Porten beviser hele kjeden, ikke endene**: `[lauf] search = "Søk"` i
  nb.toml, Accept-Language nb i Chrome, og søkefeltet i det genererte
  gridet skal si «Søk». Hvert ledd — lang-fil, Inertia-prop, `main.js`
  stillaset skrev, DataGrid — må holde for at det skal skje.
* **Inertia 3s `page` er et `$state`-objekt, ikke en store.** Første
  utkast av layouten skrev `$page.props.lauf`, og Svelte kastet
  `store_invalid_shape` — men bare på sider der en Lauf-komponent spurte
  om et ord med én gang. Skjemaene virket; listene med DataGrid og toasten
  etter en lagring gjorde det ikke. `pages.mjs` så ingenting, for det
  kompilerer; det var nettleserdelen av `make:check` som fant det.
* **Flertall er CLDR-kategorier som underøkler**, `app.items.one` og
  `app.items.other`, og `PluralCategory` er det ene stedet reglene står.
  `PluralCategories` finner kategoriene ved å spørre reglene over tallene
  0–1100 og en million, i stedet for en liste til som kunne drevet fra.
  Oppslaget i et lokale: kategorien, så `other`, så nøkkelen alene — det
  siste er for språk med én form. Reglene er holdt mot CLDRs egne
  eksempeltall, og hver språkgren er mutasjonssjekket.
* **`lang:check` holder flertall mot språkets egne regler, ikke mot
  basens nøkler.** Ellers ville en polsk `few` vært en skrivefeil, og en
  norsk `few` — som norsk aldri velger — sett ut som en oversettelse.
  Basen holdes mot sine egne regler bare for flertallene den skriver selv:
  rammeverkets former er kompilert inn.
* **`askr lang:check` sjekker begge veier**, som porten for MCP-verktøyene:
  nøkler et lokale mangler, og nøkler det har som ingenting slår opp —
  én retning alene slipper en fil full av skrivefeil gjennom.

## Mail og providere

* **`TMailTransport` er hele grensesnittet: `Send` og `Describe`.** En
  provider er en klasse til, ikke et lag til. `Askr.Mail.Resend` er det
  ferdige eksempelet; Postmark eller SES har samme form.
* **Resend ligger i en egen unit fordi den trenger HTTP-klienten.** En app
  som sender over SMTP eller skriver til fil skal ikke linke den. Samme
  regel som `Askr.Image.Vips` og `Askr.Run`: ingenting ellers i `src/` får
  avhenge av den.
* **HTTP og ikke SMTP mot samme provider, av tre grunner**, og bare den
  tredje er viktig: en id tilbake med én gang, maskinlesbare feil, og en
  idempotensnøkkel. Uten den siste gir et gjenforsøk i køen to eposter.
* **`Idempotency` settes av kalleren, og fallbacken er ikke god nok
  alene.** Uten egen nøkkel brukes Message-ID-en, som er stabil for
  *samme objekt* — men en kø bygger meldingen på nytt, og da er den ny.
  Fallbacken dekker et gjenforsøk i samme prosess; det er den eksplisitte
  nøkkelen som dekker tilfellet som faktisk skjer. Testen som holder dette
  fast sender samme melding to ganger og krever samme nøkkel.
* **`Retryable` skiller innenfor 429.** `rate_limit_exceeded` går over av
  seg selv; `daily_quota_exceeded` gjør det ikke innenfor noen backoff en
  kø har. Å behandle dem likt betyr enten at kvotefeilen brenner opp alle
  forsøkene, eller at et rate limit havner i feiltabellen med én gang.
* **Feilfeltet har hatt flere navn.** Det ekte 401-svaret bruker `name`;
  Resends egen dokumentasjon sier `error_type`. Begge leses, og `type` i
  tillegg. En feil vi ikke klarer å navngi skal fortsatt komme fram med
  status og tekst — en HTML-feilside fra et mellomledd er ikke JSON.
* **Reply-To løftes ut av `headers`.** Resend har et eget felt og avviser
  det som fritt hode. Står det begge steder, er det tilfeldig hvilket som
  vinner.
* **`MailFromConfig` kaster på et ukjent navn.** Ikke fall tilbake til
  log: en stavefeil i produksjon ville da sett ut som at posten gikk ut,
  og den eneste som visste noe annet var en fil ingen leser. Samme regel
  som «en gate som ikke finnes svarer nei». Registeret er en record-array
  med lineært søk, fordi en prosedyrevariabel ikke kan castes til
  `TObject` i Delphi-modus.
* **SMTP hadde ingen AUTH i det hele tatt** før dette. `mail.username` ville
  vært en konfignøkkel som ikke gjorde noe — samme halve løfte som
  `askr down` var før `UseMaintenance`.
* **Passordet sendes aldri over en ukryptert forbindelse.** PLAIN og LOGIN
  legger det på lufta i base64, som ikke er kryptering. `AllowPlainAuth`
  må settes eksplisitt, og da mot loopback. Mekanismene matches som hele
  ord på AUTH-linja — `XOAUTH2-LOGIN` inneholder «LOGIN» som delstreng, og
  et rått søk ville sendt AUTH LOGIN til en server som ikke har den.
* **Fake-laget dekker ikke det laget som setter headerne.** En mutasjon som
  slettet `Idempotency-Key` gikk gjennom hele suiten. Derfor går én test
  mot en rå socket og leser byte-ene som faktisk ble sendt. Samme grunn som
  chunked-serveren i HTTP-klienttestene.
* **Ett ekte kall er gjort mot `api.resend.com`, uten gyldig nøkkel.** Det
  kom tilbake som 401 med Resends egen feil-JSON, riktig parset. Det
  beviser DNS, TLS, requestformen og feilhåndteringen — ikke at en melding
  blir levert. **Ingen epost er sendt med en gyldig Resend-nøkkel herfra**,
  og det skal stå til noen har gjort det.
* En melding uten `text` og uten `html` avvises før nettverket. Resend gir
  422 på den, og den feilen er lettere å forstå her.

## Vedlegg og maler i mail

* **Python leser meldingen tilbake, ikke `Pos`.** Testen gir hele
  meldingen til Pythons `email`-pakke og sammenligner hver byte i filene,
  navnene og emnet. Det var den som fant at en `filename=`-reserve ved
  siden av `filename*` blir lest i stedet — understreker der bokstavene
  var. Derfor bare én form i disposisjonen.
* **Python tilgir det en annen leser ikke gjør.** Den slår sammen
  nabo-kodeord og RFC 2231-biter før den dekoder, så et tegn kuttet i to
  går rett gjennom. To mutasjoner overlevde av den grunn, og testen sjekker
  nå hver bit for seg — med et emne av bare tobytesbokstaver, for det
  første emnet traff tilfeldigvis aldri et kutt.
* **Kodeord på 39 byte, ikke 45.** 45 ga en første linje på 81 tegn etter
  `Subject: `. Linjer over 998 avvises av SMTP; 78 er det testen holder.
* **En linjeskift i emne eller header blir et mellomrom.** Et emne fra et
  kontaktskjema er tekst en besøkende skrev, og et linjeskift der var en
  `Bcc:` etter eget valg. Testen bruker bare LF — en mutasjon som bare
  vasket CRLF overlevde første utgave av testen.
* **Maler fylles i ett pass.** En verdi som selv inneholder `{{x}}` leses
  aldri på nytt. `{{{rows}}}` skriver html bygget i Pascal urørt; et hull
  uten verdi kaster, for en mail med `{{name}}` i er en mail en kunde leser.
* **Innholdstypene er én tabell**, `Askr.Core.Mime`, for både statiske filer
  og vedlegg. `Askr.Http.Static.ContentTypeForExt` delegerer dit.

## E-postbekreftelse og signerte lenker

* **Lenka er signert, ikke lagret.** `Askr.Signed` signerer sti, spørring
  og utløp under `APP_KEY`, med et eget formål foran så en signatur fra
  husk-meg-kaka aldri er en lenkes. Verten signeres ikke — bak en proxy
  ser appen ikke nødvendigvis verten lenka ble laget for.
* **En sjekk på at signaturen er siste parameter var død.** Alt etter den
  leses som en del av den og stemmer ikke lenger. Mutasjonen som tok den
  bort overlevde, så den er tatt ut; testen står.
* **`RequireVerified` er et kall i handleren, ikke en middleware.** En
  ruters middleware dekker alle ruter, og profilen der man retter en
  feilstavet adresse kan ikke kreve en bekreftet. Uten registrert sjekk
  svarer den nei.
* **Adressens hash står i stien**, så en ny adresse gjør de gamle lenkene
  til «for en tidligere adresse» i stedet for å bekrefte en adresse de
  aldri nådde.
* **`auth:check` fant tre feil i SMTP som var eldre enn alt dette.** En
  tekstkropp gikk som bare LF, som Postfix avviser siden smuggle-fiksene;
  bare en linje som *var* et punktum ble doblet, så `.hidden` kom fram som
  `hidden`; og en adresse gikk rett inn i `RCPT TO`, der et linjeskift var
  en kommando etter avsenderens valg. Ekkoserveren i testen kastet hver CR
  og kunne ikke se den første — den har en rå logg nå.
* **`session:check` spør profilen, ikke dashbordet.** Dashbordet vil ha en
  bekreftet adresse, og det porten sjekker er at innloggingen deles.

## Fabrikker og falske tjenester

* **En fabrikk uten arena rundt seg lager sin egen.** Første utgave la
  modellene på heapen og frigjorde dem selv; `Validate` krever arena og
  sa nei. Nå lever radene så lenge arenaen de ble laget i.
* **Nøkkelen til en forelder telles ikke opp.** `Make` satte først et
  løpenummer i `maker_id`, som pekte på en rad som ikke fantes. `Insert`
  lager forelderen; `Make` lar nøkkelen stå.
* **En sjekk på om nøkkelen var gitt med `Values` var død**: den er da
  satt og ikke null, og det spørres om uansett. Mutasjonen overlevde.
* **Nummeret er felles for alle fabrikker i prosessen**, så to fabrikker i
  samme test ikke lager samme unike navn.
* **Falsk mail rendrer meldingen først.** En falsk transport som tok imot
  det en ekte avviser, er en test som er grønn på mail som aldri går.
* **`Queue.Fake` og `FakeEvents` ligger i sine egne units**, fordi de må
  nå `HandlerFor` og lytterlista. `RunPushed` kjører gjennom de ekte
  handlerne.

## Hendelser

* **En lytter som feiler, feiler `DispatchEvent`.** En velkomstmail som
  stille aldri gikk ut er verre. Det som skal tåle feil, går i køen, med
  køens forsøk og feiltabell.
* **Jobben bærer klassen som ble sendt, ikke den lytteren ba om.** Første
  utgave bygde lytterens klasse igjen i workeren, og en underklasses egne
  felt forsvant. Klassen finnes igjen ved navn; en workerprosess som aldri
  sendte den, trenger `RegisterEvent`, og en ukjent klasse feiler jobben.
* **`FloatToStrF(ffGeneral, 17)` stopper på 15 siffer på aarch64**, der
  `Extended` er `Double`: 0.30000000000000004 kom tilbake som 0.3.
  `System.Str` skriver alle sifrene på begge arkitekturer — og må
  kvalifiseres, for `Askr.Core.Text.Str` skygger for den.
* **Testen sammenligner flyttallet eksakt, mot en `Double`-variabel.**
  `FloatToStr` viser 15 siffer og kunne ikke se feilen; og på x86_64 er
  konstanten `0.1 + 0.2` en 80-bits `Extended` som en `Double` aldri er lik.
* **`V = nil` foran `JsonIsNull(V)` var død** — `JsonIsNull` tar nil som
  null. Mutasjonen overlevde; sjekken er borte.
* **`DispatchEvent`, ikke `Dispatch`**: inne i en klasse er det
  `TObject.Dispatch`.

## Tofaktor i stillaset

* **`BeginSignIn` er den ene veien inn etter et passord.** Både innlogging
  og tilbakestilling går dit. Tilbakestillingen logget inn direkte, og med
  tofaktor på ville en lenke i noen andres innboks gått rundt koden. En
  passkey går ikke dit — den er to faktorer i seg selv.
* **Porten regner koden i Python**, ikke i Pascal-en den sjekker.
* **En kode er brukt når den er brukt.** Etter at steget etter nå er tatt,
  godtas ingen kode før klokka har gått videre — derfor bruker porten
  gjenopprettingskoder for resten. Første utgave brukte en TOTP-kode der og
  var grønn på «trenger passordet for å slå av» uten at noen var logget inn.
  Samme familie: en `post_form` som postet til forrige `$target`.
* **En flash lever én request.** Porten leste dashbordet før
  utfordringssiden, og dashbordet tok meldingen.
* **Ti-minuttersgrensen for en halvferdig innlogging er ikke testet.** En
  port som venter ti minutter er ikke en noen kjører.

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
* **Appens egne kommandoer rutes av én liste.** `ToolCommands` i
  `Askr.Console.Commands` er ordene verktøyet svarer på selv; et ord som
  verken står der eller blant `ConsoleCommands` sendes til appen, som
  kjører en registrert kommando eller svarer 64. Legger noen til en
  verktøykommando uten å føre den opp, havner den hos appen og virker
  ikke — det merkes første gang. Motsatt ville en apps kommando med samme
  navn blitt skygget i stillhet.
* **En registrering som nektes, kastes ikke.** `RegisterCommand` kalles
  gjerne fra en `initialization`, og et unntak der er et ufanget unntak
  med en kolonne adresser. Problemet lagres, og `RunConsole` sier det og
  stopper appen — også når den startes som server.
* **`out=$(cmd); code=$?` under `set -e` dreper porten** når `cmd` gir
  noe annet enn 0, og det er nettopp exitkodene porten skal måle. Skriv
  `code=0; out=$(cmd) || code=$?`. Samme felle som `grep -c` på en
  telling som blir 0.

## Dokumentasjonen i docs/

* **`docs/` og README.md er produkt og er på engelsk.** Det er det en
  bruker av rammeverket leser, og faller derfor inn under regelen under.
  README-en er inngangsdøra til et offentlig repo; CLAUDE.md, LAUF.md og
  LAUF.md er arbeidsnotater og blir værende norske.
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

**Commit-meldinger er engelske.** Historikken før 2026-09-20 er norsk og
blir stående; alt nytt skrives på engelsk. Det samme gjelder alle
`.md`-filer i repoet utenom de tre arbeidsnotatene: CHANGELOG.md,
UPGRADE.md, README.md og docs/.

**Kode er engelsk. Alt i kode.** Identifikatorer, kommentarer, testnavn,
doc-kommentarer på props. Det gjelder `.pas`, `.svelte`, `.js`, `.mjs` og
alt annet som kompileres eller kjøres. Grunnen er den samme som for
produktet: Askr er internasjonalt, og en kommentar ingen kan lese er
ingen kommentar.

Dette snudde 2026-09-21. **Koden som fantes før den datoen er fortsatt
norsk**, og er ikke skrevet om — det er tusenvis av linjer på tvers av
Pascal og JavaScript, og en masseomdøping er sin egen jobb med sin egen
risiko. Skriver du ny kode, eller skriver du om en fil helt, skal den ut
engelsk. Ikke bland i samme funksjon.

**Arbeidsnotatene er fortsatt norske** — CLAUDE.md og LAUF.md. De er ikke
kode og ikke produkt; de er notater til oss.

**Sveipen er ferdig.** `src/`, `tools/`, `tests/` og `examples/` er
engelske. Ikke-ASCII testdata er bevisst beholdt: `Blåbærsyltetøy 🫐`
tester utf8mb4, `/a/b/æ` tester prosentdekoding og `æøå — 日本` tester UTF-8
gjennom JSON. De er data, ikke tekst noen leser.

**`./askr` selv skriver fortsatt norsk**, og skal gjøre det: det er
byggverktøyet vårt, ikke produktet.

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
* **Skallet har en `<title>` og `lang="en"`.** Begge manglet, og begge ble
  funnet ved å kjøre axe mot et nettsted bygget med rammeverket — ikke ved
  å lese koden. En side uten tittel er et alvorlig brudd, og det gjaldt hver
  eneste Inertia-side i hver eneste Askr-app. `lang="no"` fikk en skjermleser
  til å uttale engelsk tekst med norske fonemer, i et rammeverk som skal
  være internasjonalt. `TInertia.SetTitle` setter den; `askr new` fyller inn
  appens navn. Tittelen er brukerkontrollert og escapes.
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
* **Aldri cast inn i `Currency`. Tilordn.** Regelen har ingen unntak, og
  den har vært feil her to ganger.

  `Currency` er en Int64 skalert med 10000. En typecast fra et heltall
  reintepreterer de bitene i stedet for å konvertere verdien — og hvorvidt
  den gjør det avhenger av både kompilator og arkitektur. Målt med `I = 7`:

  | form | x86_64 | aarch64 3.2.2 | aarch64 trunk |
  |---|---|---|---|
  | `Currency(I)` | kompilerer ikke | 7,0000 | 7,0000 |
  | `Currency(I * 100)` | **0,0700** | 700,0000 | 700,0000 |
  | `Currency(10)` | **0,0010** | 10,0000 | 10,0000 |
  | `Currency(I) * 100` | — | 700,00 | **0,07** |
  | `Currency(1234.50)` | 1234,5000 | 1234,5000 | 1234,5000 |

  Notatet sa tidligere at `Currency(I * 100)` og `Currency(I) * 100.0` var
  de trygge formene. Det gjaldt bare på aarch64, og ingen visste det, fordi
  ingenting her hadde vært bygget for noe annet. Bare tilordning er riktig
  overalt:

      Money := I * 100;    { 700,00 på alt }

  `PropAsCurrency` i `Askr.Urd.Model` finnes for at rammeverkets egen
  lesing av en published property skal gjøre det samme. Premisstesten i
  SQLite-delen av `askr_tests` holder tabellen over fast, og
  `./askr test:amd64` er det som fanger den andre kolonnen.

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
* **`askr new --auth` bygde ikke fra 0.12.0 til 0.13.1, og ingenting sa
  fra.** Installeren matchet uses-linja eksakt, API-tokenene endret den,
  og matchen bommet i stillhet etter at resten allerede var satt inn —
  app.lpr kalte `SetCache` og `SetMail` uten unitene, og verktøyet meldte
  «edited app.lpr». Ingen port bygde en `--auth`-app; `make:check` bruker
  `--no-auth`. `session:check` var den første, og fant det før den kom til
  sesjonene. Nå finnes **alle** stedene før noe skrives, i riktig
  rekkefølge, og mangler ett, skrives ingenting. Samme regel som
  mutasjonssjekkens `assert old in s`: en redigering som ikke finner
  ankeret sitt skal si fra, ikke fortsette.
* **Stillaset lager også sidene ETTER innlogging.** `/dashboard`,
  `/settings/profile` og `/settings/security`. Grunnen er den samme som at
  innloggingen finnes: `askr new shop --auth` skal gi noe man kan logge
  inn i og se seg om i, ikke et skjema som dumper deg på velkomstsida.
  De er ment å byttes ut — `/dashboard` pekes på appens eget når den
  finnes.
* **Passkeys står oppført som «ikke tilgjengelig ennå», med begrunnelsen.**
  En knapp som ikke gjør noe er verre enn en setning som sier hvorfor.
  WebAuthn krever ECDSA P-256-verifisering, en CBOR-dekoder og
  COSE-nøkkelparsing skrevet i Pascal, fordi kryptoen her ikke skal
  avhenge av OpenSSL. Ingenting av det finnes i dag.
* **Lenker i app-skallet må ha farge.** En `<a>` uten `color` arver
  nettleserens `#0000ee`, som gir 2,01:1 mot mørk bakgrunn. `main a
  {color:inherit}` — ikke `--accent`, som er grønn og faller under kravet
  mot hvitt i lyst tema. Funnet av axe mot de genererte sidene, ikke ved
  lesing.
* **Kortene på dashbordet bruker `h2`, ikke `h3`.** `h1` etterfulgt av
  `h3` hopper over et nivå, og axe felte det.
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
* **Lauf skal IKKE på npm, og det er et valg.** Den ligger inne i
  utgivelsen, så versjonen bor ett sted: taggen. Et register ville vært
  et andre sted, som kan ligge bak eller være bygget fra feil commit —
  nøyaktig den feilen testen `lauf har samme versjon som rammeverket`
  finnes for, og et register er der den testen ikke ser.
* **`askr install` lager en symlink, ikke en absolutt sti.**
  `frontend/.askr/lauf` peker inn i cachen og er gitignorert; i
  `package.json` står `file:./.askr/lauf`, som er lik på alle maskiner.
  Før dette ga fila en diff som fulgte den som sist kjørte `install`.
  Uten symlinker faller den tilbake til den absolutte stien.
* **`askr new` skriver `file:`-stien direkte når den finner en lokal
  utsjekking.** Det er rammeverksutvikling, og da er stien
  maskinspesifikk uansett.
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

## Editor

* **`Lauf.Editor` er markdown-kilde, ikke WYSIWYG, og det er svaret på at
  vi ikke bygger en rik-tekst-editor selv.** Feltet er en `<textarea>`, så
  markering, innliming, IME, mobiltastatur og angre er nettleserens. En
  editor på `contenteditable` eier alt det selv, og det er der de går for
  å dø. Flux bygger heller ikke sin egen: den ligger på TipTap og lastes
  utenom hovedbunten.
* **`execCommand('insertText')` er grunnen til at koden ser rar ut.**
  Setter man `textarea.value` direkte, kaster nettleseren angrehistorikken,
  og Cmd+Z etter et klikk på «fet» tar deg tilbake til før alt du har
  skrevet. Metoden er merket utdatert og har ingen erstatning for akkurat
  dette; reserveveien under setter verdien direkte og mister angre.
* **jsdom har ingen `document.execCommand`.** Hele komponentsuiten kjører
  altså gjennom reserveveien og beviser ingenting om angre. Den prøves i
  `tests/browser/check.mjs`, mot lekegrinda i ekte Chrome, og
  mutasjonssjekken der gir nøyaktig feilmeldingen designet finnes for.
  Samme regel som ellers: en stub er ikke en måling.
* **Avslåingen sammenlignes med det knappen ville laget, ikke med
  mønsteret.** Første utgave spurte `av.test(linje)`, og da fjernet
  «Heading 2» overskriften på `# x` i stedet for å bytte nivå — og
  «nummerert liste» tømte en punktliste. Mønsteret sier hva som skal bort
  først, ikke om vi er framme.
* **`aria-controls` skal ikke peke på noe som ikke finnes.** Øyeknappen
  pekte på forhåndsvisningen også når den var lukket, altså på en id som
  ikke var i DOM-en. Funnet av axe i Field-testen, ikke ved lesing. Nå
  `aria-expanded` alltid, `aria-controls` bare når ruta er der.
* **Verktøylinja har rovende tabindex.** Uten den står det tolv tabstopp
  mellom forrige felt og selve teksten. Svelte-lintern vil ha `tabindex`
  på beholderen også; det er feil for dette mønsteret, og advarselen er
  slått av på stedet med begrunnelsen ved siden av.
* **Editoren er den første fila som er skrevet på engelsk hele veien** —
  identifikatorer, kommentarer og testnavn. Se språkregelen: den snudde
  mens denne ble skrevet, og resten av repoet er ikke rørt.
* **Markdown-gjengiveren er vår egen fordi Lauf ikke skal ha en
  markdown-avhengighet.** `marked` er 40 kB og kan mye mer enn en
  forhåndsvisning trenger. Omfanget er låst til det verktøylinja kan lage.
* **Rå HTML slipper aldri gjennom, og det er ikke en forenkling.** Markdown
  tillater HTML i kilden, og det er nettopp der en editor blir en lagret
  XSS. Alt escapes først. Lenkeskjemaer er hvitelistet; `javascript:` og
  `data:` blir `#`.
* **Sikkerhetspåstanden måles gjennom nettleserens egen parser.** Testen
  setter utskriften som `innerHTML` og leser `a.protocol`. En regex mot
  teksten er min forestilling om HTML; `a.protocol` er HTML. Det var den
  omskrivingen som viste at `java&#115;cript:` allerede var ufarlig av en
  annen grunn enn jeg trodde — `&` er escapet, så parseren ser aldri `s`.
* **`import * as Lauf` rister like godt som en navngitt import.** Det er
  ikke innlysende: et navneromsobjekt ser ut som noe en bundler må beholde
  helt. Rollup følger medlemsoppslagene. Premisstesten bygger begge former
  og krever at de er like store — en mutasjon som dro `Editor` inn i
  `Button`-navnerommet uten pure-merking ble fanget.
* **Byggstørrelse avhenger av harness.** De samme to fixturene måler 73 kB
  fra et frittstående skript og 88 kB under vitest. Sammenligningen mellom
  to bygg i samme harness er påstanden; det absolutte tallet er det ikke.

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

**Laget utenfor PRD-en** er gjennomgått i sin helhet: `.env`, krypto, CSRF, auth, filopplasting, konfigurasjon, logging,
varig kø, modell-livskvalitet, HTTP-klient, AI, kommandolinja og
auth-stillaset. Ingenting i «stopper produksjon»-tabellen står åpent.

**Én ting står uten en kjøring med ekte legitimasjon**, og den skal stå
slik til noen har gjort det: Windows-webviewen.

**AI-laget og Resend er ute av den lista**, begge kjørt med en gyldig
nøkkel. AI-kjøringen fant en ekte feil i verktøyløkka; Resend-kjøringen
fant ingenting. Begge utfallene er verdt å ha — en liste over hva som ikke
er prøvd er verdiløs hvis man bare kjører de tingene man tror virker.

`examples/mail/resendprobe.lpr` sender til Resends egne testadresser, så
den beviser at en melding **aksepteres** med en id tilbake — ikke at noe
havnet i en innboks. Det siste kan ikke bevises av et API-kall, og
formuleringen skal ikke skli.

**Probe-en gikk selv i idempotensfella første gang.** Nøkkelen var fast i
kilden, og Resend binder den til kroppen i 24 timer — så andre kjøring med
en annen avsender fikk 409 «used with a different body». Det er
funksjonen som virker. Nøkkelen er unik per kjøring nå, og stabil inne i
den, som er det idempotens betyr.

**LARAVEL.md er slettet.** Den var et arbeidsnotat som målte Askr mot
Laravel punkt for punkt, og den hadde gjort jobben sin: alt i «stopper
produksjon»-tabellen er bygget. Å la den ligge ville holdt et annet
rammeverk som målestokk for et som nå har sine egne begrunnelser, og docs
peker ikke lenger på den. Det som fortsatt gjelder — hva som bevisst ikke
finnes, og hvorfor — står på den siden i `docs/` der det hører hjemme.

Datalaget er komplett for alle tre dialektene: drivere, introspeksjon,
migrasjoner og prepared statements med cache. Cachen hører til **steg 2** i
PRD-en, ikke til fase 2 — den ble bare stående igjen til etter at fase 2 var
ferdig. MySQL står ikke i PRD-en i det hele tatt; den kom inn etterpå.
