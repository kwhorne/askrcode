# Changelog

Everything that changed in each release: what was added, what changed,
what was fixed.

This is the full record. [`UPGRADE.md`](UPGRADE.md) is the short one — it
carries **only what can break your code**, and `askr update` prints the
relevant part of it before it touches your project. If you want to know
what is new, read this. If you want to know what will bite, read that.

Dates are release dates. Versions follow [semver](https://semver.org),
with the zero-major caveat that minor releases may break things until
1.0 — which is exactly why `^0.6.0` does not allow `0.7.0`.

## Unreleased

### Added

- **Mail attachments.** `Attach(path)` reads a file when it is called, so a
  missing one is an error where the message is built; `AttachData(name,
  bytes)` takes bytes made in memory. The type follows the name from the
  same table the static file server uses. SMTP sends them as
  `multipart/mixed`, Resend as base64 with their type, and the log
  transport as a line saying what each was. A name outside ASCII goes as
  RFC 2231, in continuations when it is long; the test reads the message
  back with Python's own `email` package, byte for byte.
- **Mail templates.** `Template('welcome', ['name', U.Name])` fills
  `mail/welcome.html` and `mail/welcome.txt` next to `askr.toml`, escaping
  in the html, with `{{{rows}}}` for html built in Pascal. A template per
  language — `welcome.nb.html` — is taken first, and `mail/layout.html`
  wraps every body at `{{content}}`. A placeholder nothing fills stops the
  mail and names it.
- **Email verification.** `askr new --auth` and `askr make auth` send a new
  account a link to confirm its address, and `/dashboard` sends anyone
  without one to `/verify-email`: the address, a button to send it again
  once a minute, and the way to fix a mistyped one. The link carries a hash
  of the address, so changing it retires the old links, and a new address
  is not confirmed by the old one having been. The mails — this one and the
  password reset — are templates under `mail/`. In the framework:
  `SetVerifiedCheck`, `IsVerified`, and `RequireVerified`, which answers a
  browser, an Inertia visit and a JSON client each its own way and says no
  when no check is registered. `./askr auth:check` drives it over a socket.
- **WebSockets.** `AcceptWebSocket(Req, Handler, Channels, UserId)` answers
  the handshake and hands the connection to a thread of its own, with any
  bytes sent behind the handshake; a `TWsHandler` gets `Opened`, `Text`,
  `Binary` and `Closed`, one message at a time with an arena per message.
  A handshake from another origin is refused, since the browser sends the
  user's cookies with it. `Broadcast` reaches websockets on its channel as
  well as streams. `./askr ws:check` runs the Autobahn test suite against
  it: 247 cases, 240 OK, three informational and four non-strict.
- **Server-sent events.** A route returns `StreamEvents(['orders'])` and
  `Broadcast('orders', 'placed', Json)` from anywhere reaches every open
  stream on that channel. The worker hands the connection to a thread of
  the stream's own, so a stream does not hold a worker: the test runs one
  worker and has a request answered with a stream open. Events have ids
  and a reconnecting `EventSource` gets what it missed; a comment line
  every fifteen seconds keeps proxies from closing a quiet stream and
  closes one whose browser has gone. `SetMaxStreams` caps them with a 503.
- **Factories and fakes for tests.** `TFactory<TOrder>` in `Askr.Factory`
  fills every column a row needs from the model's mapping, different for
  every model so a unique column holds, makes the parents a `BelongsTo`
  needs, and validates before it inserts; `Values` and `State` say the
  rest. `Queue.Fake` records pushes and `RunPushed` runs them through the
  real handlers; `FakeMail` keeps every message and refuses one a real
  transport would; `FakeEvents` records instead of delivering.
- **Events and listeners.** `Askr.Events`: an event is a class with
  published properties, `Listen` runs a listener in the dispatching code,
  and `ListenQueued` runs it in the queue, with the event rebuilt in the
  worker as the class that was dispatched and every field as it was sent.
  A listener that fails fails `DispatchEvent`; a class with a property that
  cannot cross the queue is refused, naming it.
- **Two-factor sign-in in the scaffold.** `/settings/security` sets it up
  with a QR code and the key, turns it on when a code from the app has been
  typed, and shows eight recovery codes once. A correct password then leads
  to `/two-factor-challenge`, not into a session — and so does a password
  reset, which used to sign in straight away. A code works once, wrong codes
  are counted like wrong passwords, the secret is sealed under `APP_KEY` and
  the recovery codes are hashed; new codes and turning it off need the
  password. `./askr auth:check` drives all of it over a socket.
- **Encrypting a column.** `SealText` and `OpenText` in `Askr.Core.Aead`
  keep a secret the app reads back — a TOTP secret — under `APP_KEY`, with
  ChaCha20-Poly1305 from RFC 8439 in Pascal and the purpose bound in, so a
  sealed value moved to another column does not open. Held to RFC 8439,
  its Appendix A.3 and 150 vectors from python-cryptography.
- **QR codes.** `QrEncode` and `QrSvg` in `Askr.Qr` draw a code as an
  inline SVG, for the page where two-factor sign-in is set up: byte mode,
  four levels, forty versions, the mask by the standard's penalty score.
  Held to python-qrcode module for module, to Nayuki's qrcodegen for the
  mask, and to Chrome's own barcode reader in `./askr qr:check`.
- **TOTP.** `Askr.Totp`: secrets, codes by RFC 6238, a check that takes
  the step before and after and refuses a code already used, the
  `otpauth://` URI, and recovery codes kept as hashes. Under it,
  `Sha1`, `HmacSha1`, `Base32Encode` and `Base32Decode`, against FIPS 180,
  RFC 2202 and RFC 4648.
- **Signed links.** `SignedUrl` and `SignedPath` in `Askr.Signed` sign a
  path, its query and an expiry under `APP_KEY`; `CheckSignature` tells a
  valid link from an expired one and from one that was changed. Nothing is
  stored.
- **File storage.** `Askr.Storage` puts, reads, finds and deletes files on
  a disk the app does not have to know: `TLocalDisk`, a directory, or
  `TS3Disk`, S3 and anything that speaks it, chosen by `storage.disk`.
  `PutUpload` stores an upload under a random name, never the client's. A
  path that is empty, absolute, or climbs with `..` is refused before a
  disk is touched. `TemporaryUrl` hands out a private file: a presigned
  URL on S3, and on the local disk a signed link that `UseStoredFiles`
  serves after checking it. S3 is signed with Signature V4 in Pascal, no
  SDK, held to botocore's signatures and run against an S3 gateway that
  checks every one (`./askr storage:check`). **No request has gone to AWS
  itself.**

### Changed

- The static file server sends `.pdf`, `.csv`, `.xml`, `.zip`, `.ics`,
  `.md` and the Office formats with their own types, where they were
  `application/octet-stream`. A PDF opens in the browser rather than
  downloading.

### Fixed

- **A `HEAD` request through the HTTP client waited for a body.** The
  answer to a `HEAD` carries the length the `GET` would have had, and no
  body; the client read for one, and against a server that kept the
  connection open it waited until the server gave up. A `HEAD`, a `204`,
  a `304` and a `1xx` now have no body, whatever their headers say.
  `THttpClient.Head` is new.
- **A mail's subject and names outside ASCII went out raw.** A header is
  ASCII; they are RFC 2047 encoded words now, cut so no word ends halfway
  through a character.
- **A line break in a subject or a header value started a new header.** A
  subject from a contact form could add a `Bcc:` of the visitor's choosing.
  It is a space now.
- **An address with a line break in it went into `RCPT TO` as it was**, and
  could add commands of its own to the SMTP conversation. An address with a
  line break, a space or an angle bracket is refused where it is added.
- **SMTP sent a text body's line breaks as bare LF**, which servers since
  the SMTP smuggling fixes refuse, and doubled only a line that was a full
  stop by itself, so a line starting `.hidden` arrived as `hidden`. Every
  line break is CRLF now, and every leading full stop is doubled.

## 0.14.0 — 2026-09-26

Languages, and what an app with more than one process needs. The
framework's messages, Lauf's own words, plurals, and numbers and dates
are in the reader's language and format. Sessions can live in the
database, so a login on one process is a login on all of them. Many rows
relate to many through a pivot, from the model to the generated form. And
an app can register commands of its own.

A few changes can be felt in an app that exists -- an unknown command's
exit code, `Preload` and soft deletes, a Lauf checkbox with a value, and
numbers in messages. See UPGRADE.md.

### Added

- **Commands of an app's own.** `RegisterCommand('invoices:send', 'send
  what is due', @SendInvoices)` before `RunConsole`, and `askr
  invoices:send` runs it: with its words and flags in a `TConsoleArgs`,
  an arena, the app's database as the ambient connection unless it says
  it needs none, and its return value as the exit code. A command that
  raises says why in a line and exits 1; `askr list` shows it.

  The tool routes by one list of its own words, beside the list every app
  has, and a word on neither goes to the app. A name that is on either,
  registered twice or not a plain word stops the app at start-up with a
  sentence rather than never running. A word nothing answers is exit 64
  now, from the tool and the app alike, so a script can tell it from a
  command that failed.
- **Sessions in the database.** `SESSION_DRIVER=database` keeps them in
  the app's own database, in `askr_sessions`, so a login on one process
  is a login on all of them and a deploy signs nobody out. The id is
  stored as its SHA-256, never as itself; the table is made on first use,
  not at startup; the request's own connection is used, so a small pool
  cannot deadlock on a second one; and `Regenerate` deletes the old row,
  so fixation protection holds across processes. Memory stays the
  default. `SessionsFromConfig` reads the driver and `SESSION_LIFETIME`
  and refuses a driver it does not know rather than falling back.

  Under it, `TSessionStore` now sits on a `TSessionBackend` — `Load`,
  `Save`, `Delete`, `Count`, `Sweep` — with `TMemorySessions` and
  `TDbSessions` as the two there are. `TSessionStore.Create(Lifetime)`
  is memory, as before. `./askr session:check` runs two app processes on
  one database, on SQLite, Postgres and MySQL, with memory as the
  control that must fail the same scenario.

- **Many to many.** `S.BelongsToMany('Tags', TTag)` is posts to tags
  through `post_tag`, with the pivot and both keys named by convention or
  by hand. `Preload(['Tags'])` loads it for a whole list in one query --
  the target joined to its pivot -- and leaves a soft-deleted target out.
  `Attach`, `Detach`, `DetachAll`, `Sync` and `RelatedIds` change and read
  the pivot on a saved model. Attaching one that is there is not an error,
  `Detach([])` removes nothing, and `Sync` is all or nothing in a
  transaction of its own unless the caller already opened one. The same
  tests run against SQLite, Postgres and MySQL.

  `Req.InputIds('tag_ids', Ids, Errors)` reads the ids a request sent, as
  a JSON array or repeated `tag_ids[]` form fields, and says whether the
  key was sent at all -- so a PATCH that leaves the tags alone is not a
  form with every box unticked. `IdsExist` checks a list in one query and
  names every id that is not a row, on the field.

  `askr make pivot Post Tag` writes the migration for `post_tag`: both
  keys cascade, the pair is unique, and the second key is indexed on its
  own. It prints the lines for the model rather than editing it, and
  refuses a model related to itself, whose keys need names a convention
  cannot choose.

  `askr make resource` reads a pivot -- two foreign keys to two tables and
  nothing of its own -- as a box to tick per row of the other table. The
  edit form starts with the attached ones ticked, the page and the API
  show them, and Store and Update check the ids in one query and save the
  row with its pivot in one transaction. A request that leaves `tag_ids`
  out leaves them alone; an empty list takes them all off. The pivot
  itself is refused as a resource, saying what it is. When the boxes
  cannot be there -- no model for the other table, a model here without
  the relation, or two units that would use each other -- it says which,
  and what to do. `./askr make:check` makes a pivot, adds the relation
  exactly as `make pivot` printed it, and drives the API over a socket and
  the boxes in Chrome.

  The OpenAPI document describes a `BelongsToMany`: its ids coming in
  (`tag_ids`, write-only) and its rows going out (`tags`, read-only, there
  when loaded). `IdsInputName` is the one rule both use. `JsonIds` makes a
  list of ids an Inertia prop.

  Lauf's `<Checkbox>` takes a `value`: boxes that share a name in a
  `<Form>` then hold the ticked values as a list, as an HTML form with the
  same name on several boxes means.

- **Languages.** The framework's messages are keys -- `validation.required`
  and the rest -- read from `lang/<locale>.toml` next to `askr.toml`, with
  `validation.attributes.<column>` for a field's name in them. A key is
  looked up in the request's locale, then `app.fallback_locale`, then the
  English the framework is compiled with, so an app with no lang
  directory says exactly what it said before. `UseLocales(R)` chooses the
  locale from the visitor's choice in the session, then `Accept-Language`,
  then `app.locale`, and says which in `Content-Language`; `SetLocale`
  keeps a choice. `Trans('app.welcome', ['name', N])` is the app's own
  words. `askr new` writes `LoadLang`, `UseLocales` and an empty
  `lang/en.toml`.

  Lauf's own words -- a close button, an empty list, the editor's buttons
  -- are keys too, under `[lauf]`. Askr sends them in a `lauf` prop when
  the request's locale says something other than English, and
  `laufContext` in the `main.js` `askr new` writes hands them to Lauf. The
  keys and the English are one list in two places, held equal by a test.

  Plurals are a form per CLDR category -- `[app.items] one = ...`,
  `other = ...` -- and `TransCount('app.items', N)` picks the one the
  language uses, with CLDR's rules for whole numbers in some thirty
  languages. `validation.min_length` and `max_length` are plurals, so
  `MinLen(1)` says "at least 1 character".

  `askr lang:check` holds every locale against the base both ways: the
  keys it lacks, the keys it has that nothing looks up, and placeholders
  nothing passes. It exits 1 when there is something to fix.
- **Numbers and dates in the reader's format.** `LocaleNumber`,
  `LocaleDecimal`, `LocaleCurrency`, `LocaleDate`, `LocaleTime` and
  `LocaleDateTime` in `Askr.Core.Format` write a value as the request's
  locale does: `1,234.5` in English, `1 234,5` in Norwegian, `1.234,5` in
  German; `Jan 5, 2026` and `5. jan. 2026`; `2:07 PM` and `14:07`. The
  data for 59 locales is generated from ICU by `tools/lang/formats.mjs`,
  and 2065 vectors from the same ICU hold the Pascal side to it. A locale
  without data uses its language's, then English's, and a lang file can
  say any of it differently under `[format]` -- separators, patterns,
  month names, am and pm. `askr lang:check` knows those keys and reports
  one it does not.

  A limit in a validation message is written the same way, so `Min(1234.5)`
  says "1 234,5" to a Norwegian reader. Inertia sends the locale in a
  `locale` prop and puts it in `<html lang>`, and Lauf writes its own
  numbers -- the pagination's range and page, the grid's row numbers, a
  file's size -- and gives the date picker its month names by it.
  `laufContext` gives Lauf both at the root, in the `main.js` `askr new`
  writes, so a page's own script sees them too; the layout keeps
  `<html lang>` right after a visit that did not load the page. `numbers()` and `dates()` are the same for an app's
  own; `dates()` reads the text Askr sends a date as and keeps its
  wall-clock time. The pages `make resource` writes use them for money,
  decimals and dates.

### Changed

- A database error from SQLite or Postgres ends in `— in: <the SQL>`, not
  `— i: `, which was Norwegian.
- `Preload` leaves soft-deleted children out of a `HasMany` and a
  `HasOne`, as a query for them does and as a `BelongsToMany` does. A
  `BelongsTo` still loads a trashed parent: the key points at it.
- `Sessions.Count` counts the sessions that have not expired, rather than
  every entry the last sweep left.
- An Inertia page's `<html lang>` is the request's locale rather than a
  fixed `en`, and the page carries a `locale` prop.
- Lauf's pagination writes its numbers as the locale does: `26–50 of
  9,000` in English, where it said `9000`.

### Fixed

- **The data grid said "selected" and "pages" in English whatever the
  language.** Both were written into the markup rather than taken from the
  words Lauf translates; they are `selected_count` and `pages_of` under
  `[lauf]` now.
- **The tests `make resource` writes could collide with each other.** Each
  test unit counted its unique samples from the millisecond it started,
  and one unit's parent rows are another unit's rows: the gadgets' test
  made more makers than milliseconds passed before the makers' test began,
  and a unique name came round twice. Seen on MySQL. The ranges are a
  thousand apart per millisecond now, and a unique sample takes the end of
  the number rather than the start, which was the same for every row of a
  run in a short column.
- **Two models that each belong to the other could not be described.**
  `BelongsTo` without the owner's key asked the other model for its
  primary key inside `Describe`, which built that model's meta, which
  asked back, until the stack ran out. The key is looked up when the
  relation is loaded now.
- **A unique number column made the generated tests fail on Postgres and
  MySQL.** Its sample was the whole running count, far past a 32-bit
  `INTEGER` and past money's `NUMERIC(12,2)`; SQLite's `INTEGER` is 64
  bits, so nothing said so there. The sample is now the end of the count,
  as much as the column's type holds -- all of it only in a `BIGINT`.
- **`askr new --auth` wrote an app that did not compile**, from 0.12.0 to
  0.13.1. The installer matched the scaffold's uses line exactly, the API
  tokens changed that line, and the match missed without a word: app.lpr
  called `SetCache` and `SetMail` with no unit declaring them, and the
  tool said it had edited it. Every place the installer writes to is now
  found before anything is written, and a missing one leaves the whole
  edit to the person, with the lines printed. Found by the first gate that
  built an `--auth` app at all.

## 0.13.1 — 2026-09-26

What the generators left open. A form now refuses a duplicate and a key
to nothing before the database does, a resource's page lists the rows
that point at it, and a request can no longer set the columns a model
owns -- which the OpenAPI document now says too.

One change can be felt in an app that exists: `FillInto` no longer fills
`created_at`, `updated_at` or `deleted_at`. See UPGRADE.md.

### Added

- **`Exists(table)` and `Unique`, two validation rules.** `Exists` says a
  reference points at a row that is there, and passes a blank so a
  nullable one is checked only when set; `Unique` is `UniqueIn` on the
  model's own table. A key to nothing and a duplicate both failed in the
  database, as a 500, instead of on the form.

- **`:unique` in a `make model` spec** -- `email:string(120):unique` -- for
  a unique index in the migration and `Unique` in the rules. Refused on
  text, json and bool.

- **`make model` and `make resource` write `Exists` for every reference,**
  and `make resource` reads single-column unique indexes into `Unique`. A
  unique index on two columns becomes a note. The tests `make resource`
  writes give a unique column a new value for every row, so three rows,
  or a test database that keeps its rows between runs, do not collide.

- **A resource's page lists the rows that point at it.** The page of a
  maker lists its gadgets: labelled by their first string column, linked
  to their pages when those exist, fifty at most and saying so. Asked
  with the typed columns -- `Where(Gadgets.MakerId, Eq, M.Id)` -- so a
  dropped foreign key is a compile error.

### Changed

- **`FillInto` never fills the columns a model sets itself.** The key it
  never did; now also `created_at` and `updated_at` on a model with
  `S.Timestamps`, and `deleted_at` on one with `S.SoftDeletes`. A client
  that added `created_at` to a body set it, through the one-argument form
  most handlers call. Naming one in `FillInto(M, [...])` raises.

- **The OpenAPI document says the same.** A request body leaves those
  columns out, and a response marks them `readOnly`. One rule,
  `TModelMeta.IsManaged`, is asked in both places, so the document cannot
  say a request sets something `FillInto` does not.

## 0.13.0 — 2026-09-23

Askr writes applications as well as serving them. This release is the
generators: `askr make model` turns a spec into a model and its
migration, and `askr make resource` turns a table that exists into the
pages over it, a JSON API with its OpenAPI description, and tests for
both -- on the typed columns, so a column that goes away later is a
compile error rather than a 500.

`./askr make:check` is the gate: three databases, a socket and Chrome.
Driving what the generators wrote as a user would found bugs that were
never in the generators -- in the router, in CSRF for Inertia, in the data
grid -- and every app using those parts had them. They are under Fixed,
and three of them change behaviour you may rely on; see UPGRADE.md.

### Added

- **`docs/generators.md`**: `make model` and `make resource` on one page --
  the order, what each writes and refuses, the tests it generates, how
  `./askr make:check` checks it, and what is not there yet. `docs/cli.md`
  points to it rather than carrying a second copy.

- **`askr make resource <Name> --api`**: the same table as JSON under
  `/api`, scoped `<table>:read` and `<table>:write` -- the list envelope,
  `RespondModel`, problem documents, 201 with a `Location`, `PATCH` for a
  change and 204 for a delete -- with its OpenAPI description in the same
  unit as its routes, `AppApiDoc` and `UseOpenApi` wired the first time,
  and a test that issues real tokens. `--web --api` writes both.

  `./askr make:check` runs `askr openapi --check` straight after
  generating, puts the document through a real OpenAPI validator, and then
  drives the API over a socket with tokens from `askr token:issue` and
  curl.

- **`TApiOp.NoContent`**: a 204 with no body, for a delete.

- **`askr make resource <Name>`**: the seven actions over a table that
  exists, read from the database -- a controller on the typed columns
  from `askr schema`, its routes in one procedure `app.lpr` and the test
  both call, `Index`, `Show`, `Add` and `Edit` pages in Lauf, a model when
  there is none, and a test that drives every action through the router
  on `TEST_DATABASE_URL`, or `sqlite::memory:` without one.

  What the table says, the resource does: NOT NULL without a default is
  required, a default fills a new form, `VARCHAR(n)` is a length, a
  foreign key to a table with a model is a select of its rows, a column
  named like a secret is hidden everywhere a client looks, and
  `deleted_at` makes the delete soft. It never writes over a file.

  `./askr make:check` builds three of them, runs their tests on SQLite,
  Postgres and MySQL, and then drives the pages in Chrome -- create,
  show, edit, a refused form, the list, search, sort and delete -- with
  axe, contrast included, over every page light and dark at 1280 and
  390 px, empty and with rows.

- **`Req.FillInto(M, [columns])`** fills only the columns named. The
  one-argument form fills every mapped column the body carries, so a
  client could set `created_at` or a hidden column by adding it. A name
  the model does not map raises.

- **`TSchema.ZeroIsNull('Prop')`** for an integer that refers to a row: 0
  goes in as NULL and out as `null`. Without it a nullable reference could
  never be NULL. `askr make model` writes it for every `references`
  column.

- **`askr schema:check`**: whether the typed columns still describe the
  database, in both directions, and non-zero when they do not.

  It was named in the header of every file `askr schema` has ever
  written, and it did not exist. The fingerprint it needed was in each
  file too, and nothing read it.

  It tells five things apart. A table with no file, a file for a table
  that has changed, a file for a table that is gone, and the same table
  typed differently by this version all fail. The same declarations with
  their comments worded differently -- what an upgrade leaves behind --
  pass with a note. The comparison is on tokens with comments removed,
  because the first real project it ran against came back "retyped"
  over a translated comment in the manifest.

- **`askr make model <Name> name:type ...`**: the model and its migration
  from one spec, so they start out agreeing. `string(n)`, `text`, `int`,
  `bigint`, `bool`, `money`, `float`, `datetime`, `date`, `json`, `uuid`
  and `thing:references`; a trailing `?` for nullable; timestamps on by
  default in both files together. `Rules` gets what the spec states --
  `Required` for NOT NULL text, dates and references, `MaxLen` for a
  length -- and nothing inferred from a name.

  It refuses a type that is not on the list, a Pascal keyword, and a
  name the model would not map back to with Urd's own `SnakeCase` --
  the `Label_` bug from the passkey scaffold, both halves. It does not
  migrate; it prints the next step.

  `./askr make:check` is the gate: a scaffolded project, a model with
  every type, built, migrated and round-tripped through the generated
  model on **SQLite, Postgres and MySQL**, 31 checks each, including
  that the nullable ones are NULL in the database and not `''`. Then the
  other direction: the table read back from each database must give the
  exact `Describe` and `Rules` lines make model wrote -- the reader
  `askr make resource` will be built on.

- **`TSchema.EmptyIsNull('Prop')`**: an empty string in that property is
  written as NULL. Pascal has no null string, so a nullable text column
  set from a model was never NULL -- and for `json` and `uuid`, `''` is
  not a value at all: Postgres and MySQL refuse the save. Found by the
  round trip on those two. `askr make model` asks for it on every column
  marked `?`.

### Changed

- **`askr make` never writes over a file that is there.** It used to
  overwrite without asking. Any file a command would write that already
  exists stops the whole command, and is named; `--force` replaces it.
  Half a set -- a model written and its migration refused -- is worse
  than none, so every path is checked before any is written.

- **A failing console command prints its message, not a stack.** An
  exception nobody caught came out as "An unhandled exception occurred
  at $00000000004DF4AC" and a column of addresses, which reads as the
  tool breaking. It is one line now: the class and the message.

- The migrator says `up` and `down`, not `opp` and `ned`.

- **SQLite migrations declare `BOOLEAN`, `JSON TEXT` and `UUID`**, not
  `INTEGER` and `TEXT`. The same migration used to give a `TColBool` on
  Postgres and a `TColInt64` on SQLite, and a UUID read back as any other
  text. Storage is unchanged: the declared type only picks SQLite's
  affinity, and `JSON TEXT` keeps TEXT's. Tables already made keep their
  declarations. `docs/migrations.md` said `TINYINT(1)` for a SQLite
  boolean; it was `INTEGER`.

### Fixed

- **When a handler raised, the after-filters did not run.** `ReleaseDb`
  is one, so every 403 from `AuthorizeScope` and every 500 kept its pooled
  connection, until the pool had none left and every request failed; the
  session was not written either, and a 401 went out without the
  `WWW-Authenticate` RFC 9110 requires. The router now answers an
  `EHttpError` below 500 itself and runs the filters on it, and runs them
  on the way out of any other exception before raising it again. Found by
  driving a generated API over a socket; `make:check` sends forty refusals
  and then asks for the list.

- **`TTestClient` could not test a 401 or a 403 a handler raised** -- it
  came out of the test as an exception. It is the router's answer now, so
  the test sees what the server sends.

- **Every POST from an Inertia page in a new app answered 419.** The
  Inertia client sends only what the `XSRF-TOKEN` cookie holds, and the
  cookie was set only once a token existed -- which nothing on an Inertia
  page made. The client meets 419 by reloading, so the form could never
  be sent. An Inertia page makes the token now when `UseCsrf` is on.
  Found by driving a generated resource in Chrome.

- **An unset date went out in JSON as `1899-12-30 00:00:00`.** It is
  `null`, and the OpenAPI document allows it.

- **A date and time without seconds was not a date.** `<input
  type="datetime-local">` leaves the seconds out when they are zero, and
  `FillInto` dropped the value and kept the old one without a word.
  `YYYY-MM-DDTHH:MM` is read now.

- **An empty DataGrid could not be reached from the keyboard.** The one
  cell in the tab order was on the first row, so with no rows -- an empty
  table, a search with no hits -- nothing was, sort buttons included.
  Found by axe in Chrome, on a generated list with nothing in it.

- `docs/requests.md` said `FillInto` matches property names. It matches
  column names.

- **`askr schema` escaped 41 Pascal keywords, and Delphi mode reserves
  67.** A column called `until`, `with`, `on`, `out`, `string`, `try`,
  `property` or any of nineteen more gave a schema unit that did not
  compile. There is one list now, the whole one, and `askr make model`
  uses it too instead of a longer copy of its own.

- **Two `askr make model` in the same second made two migrations with one
  version.** The version was the time to the second. The migrator ran
  the second one's DDL and then failed to record it -- the table made,
  nothing to say so, and on MySQL nothing to roll back. A new version is
  now one past the highest in `database/` when the clock has not moved
  on. Found by `make:check`, which makes two models in a row.

  **And the migrator refuses two migrations with one version before
  running anything**, naming both. That covers one written by hand too.

- **A dropped table left its typed columns behind**, and code using them
  went on compiling against a table that was gone. `askr schema` now
  removes a generated file whose table no longer exists and says so;
  only files with Norn's own header are touched.

- **`api_tokens` got typed columns in every app that had issued a
  token.** It was left off the list of framework-owned tables in 0.12.0,
  so `App.Schema.ApiTokens` appeared in an application that never queries
  the table -- the exact appear-and-disappear that list exists to stop.

## 0.12.0 — 2026-09-22

Askr serves programs as well as pages. This release is the API layer: an
error shape a machine can read, bearer tokens with scopes, a list
envelope, CORS, a rate limit, and an OpenAPI document generated from the
models and checked against the routes in both directions.

`./askr api:check` is the gate for all of it, end to end against a real
app. It found two of the bugs listed under Fixed.

### Added

- **An error has a shape a program can read.** Errors are now RFC 9457
  problem documents — `application/problem+json` with `type`, `title`,
  `status` and an optional `detail` — whenever the caller asked for JSON.
  `Problem(Status, Detail)` builds one; `BeginProblem`/`ProblemFrom` open
  and close one so an application can add extension members of its own.

- **`TRequest.AcceptsJson`** decides who asked. `Accept` naming
  `application/json` before `text/html` is a program; a browser's header
  names the page type first; no `Accept` at all means no preference, and
  a page is the safer thing to hand somebody who did not say. An Inertia
  request is never one of these — it carries its own header and gets its
  own payload.

- **`ValidationProblem(E: TErrors)`** in `Askr.Urd.Bind`: a 422 with the
  errors keyed on the column name, the same object Inertia gets as
  `props.errors`. `BackWithErrors` calls it for you.

- **`EHttpError`**: an exception that says which status it should become.
  Raising is the only way out of the middle of a function, and not every
  failure is a fault. The server answers with `HttpStatus` instead of
  500, does not log it as a failure below 500, and does not close the
  connection over it. `PublicDetail` is empty by default, for the same
  reason `detail` in a problem document is.

- **API tokens.** `Authorization: Bearer askr_...` resolves to a user id
  and signs the request in for that request only -- no session, no
  cookie. `Check`, `Id`, `User` and every gate then answer for a token
  caller exactly as they do for a browser, so authorisation is written
  once.

      UseSessions(R);
      UseTokenAuth(R);   { before UseCsrf }
      UseCsrf(R);
      UseAuth(R);

  `askr token:issue <user-id> <name> --scopes=a,b [--days=N]`,
  `askr token:list`, `askr token:revoke`. `--scopes` is required and has
  no default: the one command that mints a credential should make you say
  what it may do.

  **The token is never stored.** The row holds `sha256(token)` as hex and
  the plaintext is shown once. The gate is a sweep of the database file
  for the token that was just issued -- and it also requires the hash to
  be present, because a sweep for something absent passes on an empty
  file. The hash is bare, with no salt and no key, and the reasons for
  both are in `docs/api.md`.

  **Nothing keeps a fragment of a live token.** There is no prefix
  column: matching a token found in a log back to a row is done by
  hashing the string you found, which needs nothing stored, and telling
  two tokens apart in a list is what `name` is for.

  Scopes are exact strings with `*` as the only wildcard. A token issued
  with no scopes allows nothing. A session is not scoped, so a scope
  check passes for a browser and fails for anyone not signed in at all.

  **Never from the query string**, and there is a test that says so -- it
  passes trivially today, which is the point: it fails the day somebody
  adds the convenience.

- **A list envelope for an API.** `TGrid<M>.ListResponse(Rows)` writes
  `data`, `meta` and `links`:

      {"data": [...],
       "meta": {"page":1,"per":25,"total":137,"pages":6,
                "sort":"name","dir":"asc","q":""},
       "links": {"prev":null,"next":"/customers?status=open&page=2"}}

  It is the same `TGrid` the data grid component uses -- sorting,
  searching and paging happen in the database either way, and the only
  difference is how the result is written out. `WriteJson` gives the
  component its prop, `ListResponse` gives an API caller the envelope,
  `WriteListInto` writes it into a document of your own.

  `total` comes from `Rows`, which counts the filtered set before
  fetching the page; building the payload without calling `Rows` raises
  rather than reporting a total nobody measured. `pages` is at least 1,
  including for an empty result.

  The links are relative and carry the whole query string forward with
  only `page` replaced, so `?status=open` is still there on page two.

- **`RespondModel(M, Status)`** in `Askr.Urd.Json`: one model as a whole
  reply, with the same serialisation as everywhere else.
  `TGrid.ListResponse` was already the same thing for a page of them.

- **CORS**, closed until somebody names an origin. `Cors.AllowOrigin`,
  `AllowMethods`, `AllowHeaders`, `ExposeHeaders`, `AllowCredentials`,
  `MaxAge`, and `UseCors(R)` registered first.

  Origins match **exactly**: `https://app.example.evil.example` starts
  with `https://app.example`, and Askr.WebAuthn was caught by a mutation
  test on that same shape. A trailing slash is refused rather than
  quietly kept, because a browser never sends one.

  **`*` and credentials refuse each other at configuration time.** A
  browser rejects that pair, so a server sending both reads as "anyone,
  with cookies" and behaves as "nobody" -- generous-looking and broken.

  `Vary: Origin` goes on every reply, including the ones from an origin
  that was not allowed, or a cache hands one origin the headers meant
  for another. Same mistake as `Vary: X-Inertia`, and it shows up the
  same way: only behind a cache, and only sometimes.

- **Rate limiting**: a token bucket per caller, `429` with `Retry-After`
  and `X-RateLimit-*` headers. `RateLimit.PerMinute(600)`, optionally
  `Burst(N)`, and `KeyBy` to say what a caller is.

  `Askr.Auth.Token.TokenRateKey` keys on the token when there is one and
  the address otherwise -- a limit per credential rather than per office
  -- and on the token's **id**, because a limiter has no business holding
  a credential in a process-wide table for the life of the process.

  A bucket rather than a fixed window: a window lets somebody spend the
  whole allowance in its last second and the whole of the next in the
  first second of the next.

  **`X-Forwarded-For` is not read.** It is a header the client writes,
  and trusting it means anybody can pick a new key on every request and
  never be limited -- a limiter you can opt out of is worse than none,
  because it is believed.

  The table has a fixed number of slots, so memory does not grow with
  traffic. **Taking a slot over never hands out a fresh allowance**: the
  hash is a pure function of the key, so anybody can work out eight keys
  that collide with their own, and a refilled slot would be a way round
  the limiter that costs eight requests. The new key inherits the bucket
  instead.

- **An OpenAPI 3.1 document**, generated from what is already true.
  `UseOpenApi(R, @AppApiDoc)` serves it at `/openapi.json`, `askr
  openapi` prints it, and the `openapi` MCP tool hands it to an agent.

      D.Get('/api/customers').Summary('Every customer')
       .ReturnsList(TCustomer).Secured('customers:read');

  The application declares what the framework cannot know -- which paths
  are the API, what an operation is for, what it takes and returns --
  and the framework fills in the rest from the route table and the
  models' own metadata. The schemas come from the same `TModelMeta` that
  `WriteModel` serialises from, so a column hidden with `HideFromJson`
  is not in the document either, and a renamed column is renamed in
  both.

  It describes what is actually sent: a `TDateTime` goes out as
  `2026-09-22 13:00:00`, which is not RFC 3339, so it is **not**
  declared `format: date-time` -- a generated client told otherwise
  would build a parser that fails on every row.

  **`askr openapi --check` is the drift gate, and it runs both ways**: a
  path described that is not a route, and a route under the API that
  nothing describes. One direction alone lets the other half rot, which
  is the same argument the AGENTS.md check needed. It exits non-zero, so
  it belongs in CI.

- **`./askr api:check`**, the gate for the whole layer. It builds
  `examples/api/apidemo.lpr`, runs the document through a **real**
  OpenAPI validator against the published meta-schema -- and confirms
  that validator refuses a document with its version removed, so "valid"
  means something -- then drives the running app over a socket: a token
  per scope, the list envelope, a hidden column staying hidden, 403 for
  the wrong scope, 422 with the errors keyed on the column, a preflight
  and a near-miss origin, and the rate limit biting with `Retry-After`.

- **Six documentation pages for the layer**, indexed under APIs:
  `api.md` for who is asking and what an error looks like, then
  `tokens.md`, `lists.md`, `cors.md`, `rate-limiting.md` and
  `openapi.md`. Each ends with what it deliberately does not do.

  A test in `askr_runtime_tests` follows every link inside `docs/` and
  fails on one that points at a page or a section that is not there. The
  API layer alone is six pages that only make sense together, and a
  reference that rots reads as an answer and ends in a 404.

### Changed

- **`BackWithErrors` answers 422 to a client that asked for JSON**,
  instead of a 302 with the errors in a flash. A redirect with a flash is
  a browser mechanism end to end: it needs somewhere to keep the errors
  between two requests and a client that follows the redirect and then
  reads the page it lands on. An API client did neither, so a failed
  validation arrived as a 200 with a sign-up form in it. Browsers and
  Inertia clients are unchanged.

- **404, 405, 419, 401 and the 500 after an unhandled exception** are
  problem documents for a JSON client and the same plain text body as
  before for everybody else. The 401 matters most: a `302` to an HTML
  sign-in page is useless to a program, which follows it and gets a `200`
  with a login form — the failure disguised as success.

### Fixed

- **An anonymous caller was told 403 where it should have been 401.**
  `Authorize` and `AuthorizeScope` refused with `EForbidden` whether or
  not anybody was signed in -- and 401 and 403 are not two words for the
  same refusal. 401 says the request carried no credential and the
  caller should send one; 403 says they did and it is not enough. A
  client told the second does not know to authenticate, and stops there.

  There is an `EUnauthenticated` now, and the 401 carries
  `WWW-Authenticate: Bearer` where a bearer scheme is wired up, which
  RFC 9110 asks for and is the only way a client learns which scheme to
  use.

  Found by `./askr api:check` driving a real app -- and the test written
  alongside the bug asserted the wrong status, so nothing else could
  have found it.

- **A page could show the same row twice and never show another.**
  `Paginate` cuts a slice out of an order, and where the order does not
  decide between two rows the database may put them either way round on
  each query -- so page one shows a row that page two shows again, and
  something else is never shown at all. It is every sort over a column
  with repeats, which is most of them, and nothing says a word when it
  happens. `Paginate` now puts the primary key last in the `ORDER BY`,
  which is unique by definition, so the order is total without changing
  what was asked for. `Limit` and `Offset` on their own are untouched.

- **A list serialised as `null` when there was nothing in it.**
  `WriteModelList` wrote `null` for a nil list, so a list endpoint that
  matched nothing handed its caller something to crash on. It is `[]`
  now. "You did not ask for this" is said by leaving the key out, which
  was already the rule for a relation that was never loaded.

- **Middleware did not run in the order it was registered.** The router
  kept one list for methods and one for plain procedures and ran every
  method before every procedure, so which of the two a piece of
  middleware happened to be decided when it ran -- and nothing at the
  call site said so. It is one list now, in registration order, and the
  after-filters are one list in reverse.

  It cost a real bug, found by running a generated app rather than by the
  suite: `R.Use(@LeaseDb)` is a procedure and `UseTokenAuth` registers a
  class method, so the token middleware asked for the database connection
  before it had been leased, and every request carrying a token was a
  500. A test that registers one kind cannot see it; the new one
  alternates.

- **`EForbidden` was a 500.** `Askr.Auth` said "the host translates it
  into a 403" and nothing did -- so `Authorize` worked, refused exactly
  as it was meant to, and looked like a broken server both in the log and
  to the caller. It is a 403 now, through `EHttpError`. The same half
  promise `askr down` was before `UseMaintenance` existed.

- **A POST with a valid API token would have been a 419.** `UseCsrf`
  now exempts a request that authenticated with a header it carried
  itself. CSRF defends against a browser being made to send a request
  with the cookie it carries everywhere; no other site can set an
  `Authorization` header on a request to your server, and asking an API
  client for a CSRF token asks it for something it cannot obtain.

- **`askr token:revoke --user=<id>` reported a revocation that had not
  happened.** One function took a string and decided from its shape: a
  number meant a token id, anything else a user id. User ids are primary
  keys, so they are numbers -- `--user=7` revoked token 7, which did not
  exist, and printed "Token 7 is revoked." The flag had already said
  which of the two it was. There are two entry points now and no
  guessing, and `RevokeToken` says whether it revoked anything so the
  command can fail instead of claiming success.

- **The body of a 500 never carries the exception message.** It never
  did in Askr, and now there is a test that says so: `/boom` raises with
  a path and a password in its message, and the reply is checked for
  both, for a JSON client and a plain one. A database error carries the
  SQL, a configuration error the value, a file error the path — a
  framework that returns `E.Message` has published a reconnaissance
  endpoint on every route that can throw. The exception goes to the log
  in full, as before.

- **A model's every column went into JSON, including the ones that must
  not.** `WriteModel` writes each mapped column — right for a query,
  wrong for anything leaving the process. A model with a `PasswordHash`
  property put the hash into any JSON response, Inertia prop, list or
  relation carrying it, and `askr new --auth` generates exactly that
  model. Measured before it was fixed, not feared.

  `TModel.HideFromJson` declares what never leaves, once, on the model.
  The argument is the typed constant from `askr schema`, so a column
  renamed later stops compiling instead of quietly starting to leak; the
  generated user hides its hash from now on.

  The gate is a sentinel sweep across all four paths a model reaches JSON
  by — the same shape as the sweep that found two DSN leaks. Removing the
  check fails eight assertions.

  **An existing project keeps its behaviour until it says otherwise.**
  Nothing is hidden by default, because the framework cannot know which of
  your columns are secrets. Add `HideFromJson` to any model that has one —
  the generated `TUser` is the obvious first.

## 0.11.2 — 2026-09-22

### Added

- **`examples/mail/resendprobe.lpr`** — the Resend transport against the
  real API, with a real key: a message accepted with an id, the same
  idempotency key giving the same id rather than a second message, and an
  unverified sender refused as `EResendError` with its status and name.

  It sends to Resend's own test address, so it proves a message is
  **accepted** — not that one arrived in an inbox, which no API call can
  prove. It reads `mail.from` when there is one, so the run exercises the
  domain an application will actually send from, which is where a 403
  lives if it was never verified.

  **The Resend transport is out of the "never run in earnest" list.** Only
  the Windows shell is still in it. That run found nothing wrong, unlike
  the AI one — and a list of what has not been tried is worth nothing if
  only the things expected to work get tried.

## 0.11.1 — 2026-09-22

### Fixed

- **The tool loop sent an assistant turn without the `tool_use` blocks it
  asked with**, and the API refuses the results that follow:
  `each tool_result block must have a corresponding tool_use block in the
  previous message`. The comment above the line said the belief out loud —
  "the text is enough" — and it is not.

  The other half of the same bug: every result was in its own message.
  Only the first is then in the message after the assistant turn, so the
  rest are refused. Results for one turn now go in one user message.

  **Found by a real call, not by reading.** The suite was green the whole
  time, because it checked the shape the author believed in rather than
  the one the API requires — the limit of any fake. It now asserts that
  the assistant turn carries the `tool_use` block, that it comes *before*
  the result answering it, and, in a round with two parallel tool calls,
  that both results are in one message. A single-tool round could not see
  the second half: a mutation dropping all but the first result went
  straight through it.

  `TAiMessage` now carries `ToolCalls` and `ToolResults` instead of a
  single `ToolUseId`/`IsToolResult`/`IsError`. `ToolResultMsg` still works
  and makes a one-element version.

### Added

- **`examples/ai/aiprobe.lpr`** — the AI layer against the real API, with
  a real key. Text, streaming, tool calls, structured output and adaptive
  thinking, in that order. An example rather than a test: a suite that
  only runs for people holding a credential is one most people cannot run.

  **The AI layer is out of the "never run in earnest" list.** Windows and
  the Resend transport are still in it.

## 0.11.0 — 2026-09-22

### Added

- **`Askr.Core.Url` — the address the application answers on.** `AppUrl`,
  `AbsoluteUrl`, and `AbsoluteUrlOrFail` for where a missing origin is the
  bug. `app.url` in configuration, `APP_URL` in the environment.

  **It is never taken from the request, and cannot be.** `Host` is a header
  the client writes: a canonical link built from it tells a search engine
  the page lives on the attacker's domain, and a reset link built from it
  sends the token there. These functions have no request parameter at all —
  the property is structural rather than remembered. The end-to-end test
  drives a real socket with `Host: evil.example`, and with
  `Host: example.com.evil.example` so it is not passing merely because the
  forgery looked obviously wrong.

  An origin is a scheme, a host and an optional port. A trailing slash is
  normalised; scheme and host are lowercased, because a URL differing only
  in case is a second URL to a crawler. A path is refused with a reason
  rather than dropped or kept.

- **`TInertia.PageFallback` — what a reader without JavaScript gets.** An
  Inertia page answers a crawler with a payload in a script element and an
  empty div: strip the scripts and the body has **zero characters**. The
  fallback is markup placed inside the mount element, which the client
  empties before mounting.

  **That last part needed a browser to settle.** Svelte 5 mounts by
  appending, so without `el.innerHTML = ''` the reader sees the page twice
  — measured in a real Chrome, both ways: with the line the sentinel is
  gone and the mount element has 2 children, without it the sentinel is in
  the visible text and it has 4. `askr new` writes the line; an application
  from before this needs it added, and a custom root template needs a
  `{{fallback}}` placeholder.

  A page that sets a fallback against a template with nowhere to put it
  raises rather than dropping it. That fired the first time the demo ran,
  which is how a custom template was found to need updating.

  **This is not server-side rendering.** Inertia's SSR needs a Node process
  beside the binary, and one binary with no sidecars is the point.

- **`./askr seo:check`** — the two halves of that, measured: characters in
  the body without JavaScript, and hydration in a real Chrome. It skips
  itself with a reason when node or Chrome is missing.

- **The head of a page: `TInertia.PageTitle`, `PageDescription`,
  `PageCanonical`, `PageOg` and `PageJsonLd`.** `SetTitle` stays the site's
  default; these are this page's, and they are **per thread** for the same
  reason the flash is — a global would let one worker put its description
  on another's page. They are cleared when the response is built, and
  mutation-checked against inheriting.

  **Two escapings, and which applies depends on where the value lands.** An
  attribute takes HTML escaping; the JSON-LD lands inside a script element,
  where the browser decodes no entities — `&quot;` would arrive as six
  characters and break the JSON, while an unescaped `</script>` would close
  the element. Both directions are mutation-checked, including HTML-escaping
  the JSON-LD, which is the mistake that looks safest.

  `PageCanonical` makes a path absolute against `app.url` and leaves the
  link out when there is none: a canonical pointing at the wrong place is
  worse than no canonical.

- **`Askr.Http.Sitemap` — `UseSitemap(R, Source)`.** The application
  declares which paths exist; the framework writes the XML, makes the URLs
  absolute against `app.url`, formats `lastmod` as W3C datetime, and
  enforces the protocol's limits.

  **Askr knows the routes but not which are public**, and cannot expand
  `/docs/:slug` into the pages that exist. A sitemap generated from the
  route table would be a list of patterns with every admin route in it.

  **50 000 URLs and 50 MB are hard limits**, not guidance: over either, a
  crawler rejects the whole document. The entries are split into parts with
  an index in front. Mutation-checked by never splitting, which fails at
  50 001.

  **Escaping is checked by a real XML parser**, not by a pattern — a `&` in
  one URL makes the whole document malformed, and a regular expression is
  what one imagines XML to be. Mutation-checked by removing the escaping,
  which the parser then refuses to read.

  `askr new` registers it with a source listing `/`, to show the shape.

- **`Askr.Http.Robots` — `UseRobots(R)`, and a default that is closed.**
  The body follows `APP_ENV`: production allows everything and adds a
  `Sitemap:` line when `app.url` is set; anything else answers
  `Disallow: /`, including a server with nothing configured at all.

  A missing robots.txt means "index everything" — that is what a crawler
  assumes on a 404 — so the dangerous state is not a wrong file but no
  file, on a staging site nobody thought about. Mutation-checked by making
  it always open.

  It names no crawler. Whether GPTBot or ClaudeBot may read a site is a
  decision about that site, and a default with an opinion in it would make
  that decision for every application, silently. `askr new` registers it
  after the static files, so your own `public/robots.txt` wins.

- **Conditional GET.** `TResponse.WithETag`, and a comparison in the server
  so that no handler has to do it: a `GET` or `HEAD` whose `If-None-Match`
  matches answers **304 with no body**. Static files get an ETag from
  modification time and size.

  **A response that sets a cookie never answers 304, and loses its ETag.**
  A body that comes with a cookie is made for one client; a page with a
  CSRF token, served from cache on a later 304, is a form whose token has
  been rotated — a rejected submit nobody can reproduce. Mutation-checked
  by removing the guard, which fails six assertions.

  Only `GET` and `HEAD`: turning a `POST` into a 304 would answer a write
  with "your copy is current" and drop it. That test first passed for the
  wrong reason — it posted to a route with no ETag, so the method check was
  never in play — and now posts to one that has one, with a `GET` of the
  same route beside it to show the difference is the method.

### Changed

- **The reset link in `askr make auth` is built with `AbsoluteUrlOrFail`**
  rather than by concatenating `Cfg('app.url', ...)`. It never used the
  request, so nothing was exposed — but a trailing slash in `app.url` gave
  `//reset-password`, and an unset one silently fell back to a localhost
  link in an email that had already been sent.

## 0.10.1 — 2026-09-21

### Fixed

- **Lauf's icon generator failed in Norwegian, and said only what broke.**
  `lauf: ikongenereringen feilet` is a message a user of the framework sees
  during `npm install`, and everything a user sees is English. The failure
  it passes on is `Cannot find module 'heroicons/package.json'`, pointing at
  a path inside the package cache, which explains nothing on its own.

  It now names the directory to run `npm install` in. This is the error
  anyone hits on the first build after moving the framework pin: the icons
  are generated from heroicons and are not in git, so a freshly fetched
  release has neither the icons nor the package to make them from.

- **`TQuery.WhereAnyLike` was not in the documentation at all**, and
  `docs/queries.md` said the opposite of the truth: "`OR` groups are not in
  the builder". They are — that one method is the only `OR` in the query
  builder, `Askr.Urd.Grid` uses it for every search box, and a reader was
  being told to drop to raw SQL for something already there.

  It is now written up with its signature, the parenthesis around the group,
  what `CaseSensitive` does per dialect, and that empty text adds no clause.
  `docs/lauf.md` links `Searchable` to it.

  Found by asking the MCP server. `docs_search` answered "no match", which
  was the correct answer and the useful one: the name really was absent.

## 0.10.0 — 2026-09-21

### Added

- **`askr mcp` — an MCP server for AI agents, over stdio.** JSON-RPC 2.0
  with `initialize`, `tools/list`, `tools/call` and `ping`.

  **It runs in the tool, not in the app**, for a reason specific to a
  compiled framework: if the app does not compile there is no app to ask,
  and that is exactly when
  an agent most needs to be told what is wrong. `askr` is built from the
  pinned release and does not depend on the project compiling.

  `./askr mcp:check` is the gate for that. It writes a project that cannot
  compile, pipes real frames through the server, and requires the handshake
  anyway — then does it again with a project that does compile, with a
  framework path that is not a checkout, and with no project at all. It runs
  as part of `./askr test`.

- **`askr mcp:install`**, wiring `askr mcp` into Claude Code, Cursor or
  VS Code. Without an argument it writes `.mcp.json` and names the others.

  **A file that already exists is never rewritten.** It is read; either an
  `askr` server is already configured, or the lines to add are printed.
  These files carry comments, ordering and formatting that a
  parse-and-rewrite loses, and some are JSONC, which Askr's JSON parser
  does not read. The last time this repository edited a file a user owns —
  a `package.json`, by finding a colon — it matched the wrong one, replaced
  the whole dependencies object with a string, and reported success.

- **`askr new` writes an `AGENTS.md`.** What a coding agent reads before it
  starts: the MCP tools, and the handful of facts where being wrong is
  quiet rather than loud.

  **It says as little as it can.** Everything about the framework is behind
  `docs_search` and `docs_read`, which serve the documentation of the exact
  version the project pins. A copy in `AGENTS.md` would be frozen at the
  day the project was created, in a file the user owns, and the two would
  disagree the first time Askr is upgraded with nothing to say which was
  right. A gate holds the one thing that does drift: every registered tool
  is named in the file, and the file names no tool that does not exist.

- **The `test` tool.** Builds and runs the project's suite and returns what
  it said.

  **It stops a suite that hangs**, after 120 seconds by default and 600 at
  most. A person at a terminal sees a suite stall and presses Ctrl-C; an
  agent cannot, and a call that never returns takes the session with it.
  What the suite printed before it was stopped comes back with the answer,
  because that is usually where the hang is. `askr test` itself passes no
  deadline and captures nothing — the difference between the two paths is
  who is watching, and nothing else; both go through one `RunTests`.

  **Four outcomes, where the exit code offers two.** A suite that did not
  compile and a suite that failed both exit non-zero and need opposite
  work, so they are reported as different things. A failing suite is a
  successful call, as a failing build is; `isError` is true only when there
  is no project and no test file.

- **The `routes`, `schema` and `config` tools.** What an agent cannot get
  by reading files: the routing table in the order requests actually match,
  what the database actually contains, and which layer each configuration
  key resolved from.

  **`config` never shows a value, and there is no flag that does.** `askr
  config --values` is for a person at their own terminal; this output goes
  into an agent's context and on to whatever model is behind it. Nothing is
  redacted either, because nothing is read: a redactor is a list of words,
  and `LooksSecret` says in its own comment that it cannot be definitive.
  Measured against three secrets in `.env` — `--values` hides
  `DATABASE_URL` and `MAIL_PASSWORD`, and prints `STRIPE_LIVE_ACCOUNT` in
  full.

  **`routes` and `schema` capture the app's output rather than inheriting
  it.** They are the first tools that start a child process, which is the
  hazard the MCP unit header names: an inherited stdout writes the app's
  text straight onto the protocol channel. Mutation-checked by making the
  capture an inherit, which fails four assertions.

  No `--json` was added to the console commands, and the tools do not need
  one: the app's own output is passed through unchanged, so an agent reads
  exactly what a developer reads and there is no second format to keep in
  step. A tool that had to parse it would need one; none of these do.

- **The `docs_search` and `docs_read` tools.** The documentation an agent
  reads, over the same protocol as the build tool.

  **The docs come from the version the project pins**, resolved through the
  same `ResolveFramework` the compiler path uses — not from the `askr` on
  your PATH. `askr mcp` runs before the project is found and never
  delegates, so the binary answering may be a different release entirely.
  An agent reading current docs for a project pinned two releases back
  would be confidently wrong, and nothing would say so. The gate proves it
  with a fabricated framework tree carrying its own version and its own
  single page: the tool reports that version and cannot see this
  repository's own docs.

  **The search is an exact substring and never fuzzy.** Ask for a name that
  does not exist and the answer is that there is no such name — not the
  nearest one that does. Askr's API names are easy to guess wrong by a dot
  or a capital, and a forgiving search would hand back a page reading as
  confirmation. The test asserts the property itself: every hit contains
  what was asked for. Mutation-checked by making the search ignore
  punctuation, which is exactly the failure it exists to prevent.

  **A page name never builds a path.** It is matched against the listing of
  what is in the directory, and only a name that came back from the listing
  is opened. `../../etc/passwd` does not equal any entry.

  `docs_read` with no page lists the pages; an unknown page or section is
  refused with what there is instead.

- **The `build` tool.** Runs the Rún transpiler and the compiler over the
  project and answers with `file:line:column  Severity: message` — the shape
  every editor and every agent already follows — after a first line saying
  whether a binary came out and how many warnings it cost.

  **A failed build is a successful call that reports bad news**, not a tool
  error. `isError` is true only when the tool could not run at all: no
  project, no compiler, a framework path that is not a checkout. Conflating
  the two makes an agent retry the wrong thing, and the gate checks both
  directions.

  `askr build` and the tool share one `CompileProject`. Two paths to the
  compiler would drift, and then the agent and the developer would be
  looking at different errors.

- **`Askr.Cli.Diag` — compiler diagnostics as structure.** The first step
  towards `askr mcp`: fpc's output parsed into file, line, column and
  severity, so a tool can hand an agent something it can act on rather than
  a wall of text.

  It parses the **format**, never the message text. The wording varies
  between compilers — 3.2.2 writes `function header doesn't match` where
  trunk writes `Function header doesn't match` — while the shape does not.

  A premise test holds that down against real captured output from three
  toolchains: 3.2.2 on aarch64, 3.2.2 on x86_64 and 3.3.1 trunk. The
  positioned lines are byte-identical from all three, and
  `tests/vectors/fpcdiag/capture.sh` regenerates the vectors.

  Three properties are mutation-checked: the `(24) Fatal:` form with a line
  and no column; that the severity is a known set rather than "whatever
  stands before the colon", so `Target OS: Darwin for AArch64` is not a
  diagnostic; and that warnings and notes do **not** stop a build — the
  distinction an exit code cannot make.

### Fixed

- **`build` counted four errors where there was one.** fpc follows a single
  mistake with three lines of its own summary — `There were 1 errors
  compiling module`, `Compilation aborted`, `ppca64 returned an error
  exitcode` — and all three are error-level. An agent told `4 errors` for
  one mistake goes looking for three that are not there.

  `CountDefects` counts only diagnostics that carry a **column**. That is
  structural, not textual: fpc gives a column when it is pointing at a
  token in the source, and never on a summary, whether the summary carries
  a line or no position at all. Counting by message text is what
  `Askr.Cli.Diag` exists not to do. The premise test holds it against all
  nine captured vectors — three defects in `errors.pas`, one in
  `syntax.pas`, identical on 3.2.2/aarch64, 3.2.2/x86_64 and 3.3.1 trunk,
  and agreeing with fpc's own tally.

- **Two error paths printed the whole DSN, password included.**
  `OpenDbConnection` raised `DSN has no scheme: <dsn>`, and the MySQL
  driver raised `Invalid MySQL DSN: <dsn>`. A DSN that is wrong in some
  other way still carries a password that is right, and these are exactly
  the messages that end up in a log, a terminal or an issue. Both now say
  what was expected instead — the registered schemes, and the URI shape.

  Found by building a gate that drives every MCP tool against a project
  whose `.env` carries a sentinel password, and requires it to appear
  nowhere in the output. `askr config --values` and `askr db:show` were
  already careful; these two were not, and nothing had ever looked.

- **A build failure in the tool no longer kills the MCP server.** A missing
  compiler, an `ASKR_FPC` that points at nothing, or an `[askr] path` that
  is not a checkout used to print to stdout and `Halt`. Under `askr mcp`
  that wrote a human sentence onto the protocol channel and then ended the
  process halfway through a reply: the client saw the pipe close with
  nothing to say why.

  Those four failures are now raised as `ECliFatal` and carried to whoever
  asked. A terminal prints the same text and exits non-zero, exactly as
  before; a tool call answers with it and the server stays up. Found by
  `./askr mcp:check`, not by reading — and mutation-checked by putting the
  `Halt` back, which fails three assertions including that a `ping` after
  the call still gets a reply.

### Changed

- **`tests/` is English.** Comments, test names, fixture data and
  identifiers across all eight suites — around 1,240 comment lines and
  some 900 assertion names. The example domain went with it: the AI tool
  fixture is a `weather` tool taking a `place`, not `vaer` taking `sted`.

  Non-ASCII test data stays: `Blåbærsyltetøy 🫐` is there because it tests
  utf8mb4 and four-byte characters, `/a/b/æ` because it tests percent
  decoding, and `æøå — 日本` because it tests UTF-8 through JSON.

  The suites caught the translation repeatedly — a renamed input with an
  unchanged expectation fails loudly, which is what they are for. One
  genuine find: the desktop suite asserted that the no-display error
  mentions `webtjeneste`, and `Askr.Desktop` has said `serving over HTTP`
  since `src/` was translated. It would have failed the moment anybody ran
  the suite without a display, and nobody had, because it skips on macOS
  and wherever GTK is missing.

## 0.9.2 — 2026-09-21

An architecture in the gate, and the money rule corrected — 0.9.1 fixed
the framework's three sites, and the gate then found five more.


### Added

- **`./askr test:amd64` — the whole suite built and run for x86_64.**
  Architecture is a third axis beside the two compiler versions, and it
  was not covered: every build and every test run of this framework had
  been aarch64, including the Docker image, because Docker on Apple
  Silicon runs arm64 by default.

  It is a container with `--platform linux/amd64` and its own
  `.build-amd64`, since `.ppu` files are bound to the target. On Apple
  Silicon it goes through Rosetta and takes 15 seconds. `check`, `pg` and
  `mysql` take `ASKR_ARCH=amd64` the same way.

### Fixed

- **The rule for `Currency` was wrong in the docs, and the tests were
  written to the wrong rule.** 0.9.1 fixed the framework's own three
  sites; the new gate then found four more in the suites and one in
  `examples/run`.

  A typecast from an integer into `Currency` reinterprets the scaled
  Int64 instead of converting, and whether it does so depends on the
  compiler *and* the architecture. Measured with `I = 7`:

  | form | x86_64 | aarch64 3.2.2 | aarch64 trunk |
  |---|---|---|---|
  | `Currency(I)` | does not compile | 7.0000 | 7.0000 |
  | `Currency(I * 100)` | **0.0700** | 700.0000 | 700.0000 |
  | `Currency(10)` | **0.0010** | 10.0000 | 10.0000 |
  | `Currency(I) * 100` | — | 700.00 | **0.07** |
  | `Currency(1234.50)` | 1234.5000 | 1234.5000 | 1234.5000 |

  The docs had called `Currency(I * 100)` one of the safe forms. It was
  safe on aarch64, which is all anyone had ever run. There is one rule
  now and it has no exceptions: **assign, never cast.**

  `examples/run/setupdb.lpr` was inserting 0.07 where it meant 700 on
  x86_64. `./askr run:demo` prints the balances, and they are right on
  both architectures now.

- **`./askr run:demo` could not run without a local compiler.** It passed
  an absolute host path to a binary running with `/work` as its working
  directory, so in container mode it never got further than `Can't find
  unit Shop.Gen`.

### Changed

- **The install instructions no longer say `apt install fpc`.** That
  metapackage is 326 packages on Ubuntu 24.04, against 11 for
  `fp-compiler fp-units-rtl fp-units-fcl fp-units-net` — it drags in the
  GTK2, multimedia and graphics unit packages with libvlc, Mesa and X11
  headers behind them. Measured, not guessed, while setting up a real
  deployment.

- **`docs/deployment.md` has a systemd section and a Caddy block**, both
  taken from a deployment that is running rather than from memory, plus
  the note that `ReadWritePaths` is what makes `ProtectSystem=strict`
  survivable: SQLite writes `-wal` and `-shm` next to the database even
  for a site that only reads.

- **`tools/` is English.** The two Dockerfiles, the compose file, the
  generics probes and the WebView2 probe — comments, identifiers and
  output. The probe files were renamed with their unit names, since fpc
  requires the two to match: `p2_generisk_funksjon_i_unit.pas` is
  `p2_generic_function_in_unit.pas`. `run.sh` globs `p*`, so nothing
  pointed at the old names.

  Running them is unchanged: all seven still fail, with the same errors,
  on 3.2.2 and on trunk. The working notes said six; there are seven
  files — six limits and the call site that depends on the second.

## 0.9.1 — 2026-09-21

### Fixed

- **Askr did not compile for x86_64.** `Currency(GetFloatProp(...))` is an
  illegal typecast there: `Extended` is 80 bits and a type of its own, and
  the compiler refuses it. On aarch64 `Extended` is an alias for `Double`
  and the same line compiles, which is why three sites in `Askr.Urd.Model`
  and `Askr.Urd.Json` stood untouched — **every build and every test run
  of this framework had been on aarch64.**

  Found by building it on an x86_64 server for the first time, not by
  reading. The fix is `PropAsCurrency`, which assigns rather than casts:
  assignment is a defined conversion on both, and a typecast into
  `Currency` reinterprets the scaled int64 instead of converting the
  value — the same trap the multiplication note already warns about.

### Notes

The test suite still runs on aarch64 only. That an architecture is a real
axis — like the two compiler versions already are — is now written down in
the working notes, and covering it is the next step, not a claim made here.

## 0.9.0 — 2026-09-21

A markdown editor, tabs that do what Flux's do, and the last of the
Norwegian out of the framework's own source.

### Added

- **`Lauf.Editor`** — a markdown editor: a `<textarea>` with a toolbar and
  a live preview, written from scratch in Svelte 5 with no new dependency.

  The value is markdown, in and out. Not HTML — markdown is what belongs
  in a database: readable in a SQL console, it diffs, and it cannot carry
  a script.

  **It is not WYSIWYG, and that is the design.** Flux does not build its
  own either; it sits on ProseMirror and loads it outside the main bundle.
  With a textarea, selection, paste, IME, mobile keyboards and undo all
  stay the browser's. A click on *Bold* goes onto the browser's own undo
  stack, so `⌘Z` steps back through formatting and typing together —
  verified in a real Chrome, because jsdom has no `document.execCommand`
  to verify it with.

  The toolbar is a string, as in Flux: `"heading | bold italic ~ preview"`.
  An unknown name is skipped — a typo should cost a button, not the page.

- **`renderMarkdown`** — the editor's own renderer, exported for pages
  that display stored markdown. It covers what the toolbar can produce and
  nothing else, and **raw HTML never passes through**: that is where an
  editor becomes a stored XSS, since the text comes from whoever is typing
  and the preview runs in the reader's browser on your domain. Link
  schemes are limited to `http`, `https`, `mailto`, `tel` and relative
  addresses.

- **`import * as Lauf` is a supported style**, so components can be
  written `<Lauf.Button>` and `<Lauf.Editor>` — the shape Blade users
  expect. It costs nothing: Rollup follows namespace member access, and a
  premise test now builds both forms and requires the same bytes out.

- **`Lauf.Tabs` brought up to what Flux's tabs do**: three variants
  (`underline`, `segmented`, `pills`), two sizes, per-tab icons, trailing
  icons, badges and `disabled`, and `scrollable` for when the tabs do not
  fit. The existing `tabs={[...]}` API is unchanged, so nothing breaks.

  The tabs stay data rather than becoming child components. Flux writes
  `<flux:tab name="profile">Profile</flux:tab>` because Blade has no good
  way to hand over a list of objects; Svelte does, the tabs in an Askr app
  usually come from the server, and Lauf's icons are components already.
  One list, one code path.

  A badge is part of the tab's accessible name — a screen reader reads
  "Orders 12", which is what a sighted reader gets too.

  Tabs that do not fit wrap by default and scroll with `scrollable`;
  either way they no longer widen the page. Without `min-w-0` they pushed
  past their own container and made the playground scroll 27 px sideways
  at 390 px — found by the browser check, which measures scrollWidth,
  because axe says nothing about it.

- **`Lauf.Tabs.Panel findable`** — find-in-page reaches a panel that is not
  open. An inactive panel carries `hidden`, so Ctrl+F cannot see into it,
  and on a settings page split across six tabs that makes the browser's
  own search a lie. `findable` marks inactive panels
  `hidden="until-found"`; the browser searches them anyway and fires
  `beforematch` on a hit, which Lauf uses to select the owning tab.

  Browsers without `until-found` treat any value as plain `hidden`, so the
  panel stays hidden and simply is not findable — the feature degrades,
  not the page.

### Changed

- **All of `src/` is English — comments and identifiers.** The rule in the
  working notes is reversed: code is English, the working notes stay
  Norwegian. This release finishes the sweep for the framework itself:
  every unit under `src/` now carries English comments, and the last
  Norwegian identifiers are gone (about 1100 further occurrences on top of
  the 3164 renamed earlier, all compiler-verified on 3.2.2 and 3.3.1).

  A comment nobody can read is not a comment, and the reasons written down
  in this code are most of its value.

- **The code `askr new --auth` generates is English too.** That is the part
  a user actually reads: the sign-in controller, the user and credential
  models, the migrations and `app.lpr`. It had Norwegian identifiers —
  `Epost`, `Passord`, `Meg`, `Plassholder`, `BremseNokkel` — in a file the
  scaffolding hands you and tells you to edit. They are now `Email`,
  `Password`, `CurrentUser`, `Placeholder`, `ThrottleKey`.

  Verified by scaffolding an app and building it, not by reading: nothing
  in `./askr test` compiles the generated output.

- `TCborReader.Ferdig` is now `TCborReader.FullyConsumed`. It is the one
  renamed identifier that was public; see [UPGRADE.md](UPGRADE.md).

### Fixed

- **`Lauf.Tabs.Panel findable` threw on every unmount.** The effect's
  teardown read `el` again, and `bind:this` has already set it back to
  null by then, so `removeEventListener` ran on null. The node is captured
  now.

  It threw on every single unmount and nothing failed — vitest reported it
  as an unhandled rejection beside a green run. The test that holds it
  closed asserts the listener was actually removed, and was mutation-checked
  by putting the old line back.

### Notes

`Editor` measures 95 kB mounted and minified, against a 73 kB floor for a
bare `<Button>`. An app that does not use it pays none of that, and the
tree-shaking test checks exactly that.

**The sweep stops at `src/`.** `tests/`, `examples/` and `tools/` still
carry Norwegian comments — around 440 lines. They are converted as files
are touched, the same way `src/` was, and nothing in them is read by
someone using the framework.

## 0.8.1 — 2026-09-21

Documentation only.

### Fixed

- The docs index described the mail page as "SMTP with STARTTLS", which
  stopped being the whole story in 0.8.0.
- The "written but never run" list in `docs/README.md` had two entries
  and needed three: the Resend transport carries exactly the same
  evidence and the same gap as the AI layer.
- `docs/README.md` had said "This documentation describes Askr 0.6.0"
  since 0.6.0.

### Notes

The docs fix was briefly committed on top of the `v0.8.0` tag and the tag
was moved. That was wrong — `askr install` verifies that a pinned version
resolves to one commit, and a tag that moves breaks exactly that promise.
`v0.8.0` was restored to `097b70b`, and this release carries the change
instead.

## 0.8.0 — 2026-09-21

A mail provider. Resend over its HTTP API, and the transport is now
chosen by configuration rather than by code.

### Added

- **`Askr.Mail.Resend`** — `TResendTransport`, sending through
  `api.resend.com`. Set `MAIL_TRANSPORT=resend` and `RESEND_API_KEY` and
  that is the whole setup.

  It is a separate unit on purpose: it needs the HTTP client, and an app
  that sends over SMTP or writes to a file should not link that. Same
  rule as `Askr.Image.Vips`.

  Why the HTTP API rather than SMTP to the same provider: the response
  carries a message id you can look up later, the errors are machine
  readable instead of a three-digit code with free text, and there is an
  idempotency key.

- **`TMailMessage.Idempotency`** — a key that makes it safe to send the
  same message twice. This is the one that matters in a queue: a job
  that fails *after* the provider accepted the message gets retried, and
  without a key that survives the retry the recipient gets two copies.
  `TSmtpTransport` ignores it.

- **`EResendError`** carries `Status`, `Name_` (the provider's own error
  type, unchanged) and `Retryable`. The distinction that matters is
  inside the 429s: a rate limit is worth retrying, a daily quota is not
  — it will not clear within any backoff a queue has, so it belongs in
  the failed-jobs table where a person sees it.

- **`MailFromConfig`** picks the transport from `MAIL_TRANSPORT`: `log`
  (the default), `resend`, `smtp` or `null`. Moving from a log file in
  development to a real provider is now a config change.

  **An unknown name is an error, not a fallback.** `MAIL_TRANSPORT=resnd`
  stops the app at startup and lists what it does know. Quietly writing
  production mail to a log file nobody reads looks exactly like
  everything working.

- **`RegisterMailTransport`** — how a transport in another unit makes its
  name available to `MailFromConfig`. `Askr.Mail.Resend` registers
  `resend` in its `initialization`.

- **SMTP authentication.** `TSmtpTransport.Credentials` with AUTH PLAIN
  and AUTH LOGIN. It was missing entirely, which meant `TSmtpTransport`
  could not talk to any hosted relay.

  **The password is never sent over an unencrypted connection.** PLAIN
  and LOGIN both put it on the wire in base64, which is not encryption.
  Plaintext plus a username is refused unless `AllowPlainAuth` says
  otherwise.

- `TMailMessage` now exposes `ToList`, `CcList`, `BccList`,
  `SubjectLine`, `TextBody`, `HtmlBody` and `ExtraHeaders`, so a
  transport can build its own format instead of parsing the RFC 5322
  text. `FormatMailAddress` is exported for the same reason — the
  quoting rule lives in one place.

### Changed

- `askr new --auth` writes `SetMail(TMailer.Create(MailFromConfig))` and
  links `Askr.Mail.Resend`, in place of the hardcoded
  `if IsProduction then TSmtpTransport…`. Existing projects keep working;
  their own `app.lpr` is unchanged.

- `.env` and `.env.example` from `askr new` now carry `MAIL_TRANSPORT`,
  `MAIL_FROM`, `RESEND_API_KEY` and the SMTP keys.

### Fixed

- `TMailMessage.Header(name, '')` behaved differently on FPC 3.2.2 and
  3.3.1 — `TStringList.Values[Key] := ''` deletes the entry on trunk and
  keeps it on 3.2.2. It now means the same on both.

### Notes

One real call was made to `api.resend.com` **without a valid key**: it
came back 401 with Resend's own error JSON, parsed into `EResendError`
with status and type. That
proves DNS, TLS, the request shape and the error handling — not that a
message is delivered. Everything else is tested against
`TFakeResendHttp`, plus one test that reads the actual bytes off a
socket to check that `Authorization` and `Idempotency-Key` are really on
the wire.

**No mail has been sent with a valid Resend key from this repository.**
That is the same caveat the AI layer carries, and it stands until
someone has done it.

## 0.7.0 — 2026-09-21

Images. Two units, and the split between them is the point.

### Added

- **`Askr.Image`** — what a file *is*, without decoding a pixel. No
  dependency, always available. Format from magic bytes, dimensions from
  the header, EXIF stripped by rewriting segments.

  It is mostly a security unit. A file named `avatar.jpg` that is
  actually HTML is a stored XSS: serve it back with the wrong
  `Content-Type` and it runs under your domain. The filename is an
  attacker's string and so is `Content-Type`; `SniffFormat` measures
  instead. Reading dimensions without decoding is also how you refuse a
  decompression bomb before it costs you gigabytes.

  EXIF matters for a second reason: a photo from a phone usually carries
  GPS. Someone uploading a profile picture is uploading their home
  address unless something removes it.

- **`Askr.Image.Vips`** — resize, crop and convert, by loading libvips
  with `dlopen`. Same pattern as OpenSSL, libpq, libmariadb and sqlite3:
  the binary starts without it, and an app that never resizes an image
  pays nothing. When it is missing, the error names the package to
  install for Debian, macOS and Alpine.

  It never scales up: an image already smaller than the box comes back
  at its own size.

- `SniffFormat`, `ReadImageInfo` and `ExtensionMatches` take a `TStr`,
  so they work straight on `TUploadedFile.Content` without copying the
  upload.

- [`docs/images.md`](docs/images.md), which also says why video is not
  here: transcoding is minutes of CPU on a request that has to answer in
  milliseconds, and belongs on the durable queue behind `ffmpeg`.

### Notes

The image tests run in the container, where libvips is installed, and
skip on macOS saying why — the same arrangement as the TLS suite.

## 0.6.4 — 2026-09-21

### Changed

- **`askr install` writes a machine-independent path for Lauf.** It used
  to put an absolute path into your own `~/.askr/pkg` in
  `frontend/package.json`, which made that file produce a diff that
  followed whoever last ran `install`. It now creates a gitignored
  symlink at `frontend/.askr/lauf` and writes:

  ```json
  "@askrcode/lauf": "file:./.askr/lauf"
  ```

  The scaffold's `.gitignore` covers `frontend/.askr/`. On a system
  without symlinks it falls back to the absolute path, which works the
  same locally.

- **Lauf will not be published to npm, and the docs now say so as a
  decision rather than a gap.** It ships inside the framework release,
  so the version lives in exactly one place: the tag. A registry would
  add a second one that can lag behind it or be built from a different
  commit — which is the failure the release-wide version test exists to
  catch, and a registry is where that test cannot see.

  The cost is real and narrow: you cannot `npm install @askrcode/lauf`
  into a project that is not an Askr project.

## 0.6.3 — 2026-09-21

`askr make auth` wires passkeys up. 0.6.2 could verify them; this one
gives you the table, the routes and the browser half, so a generated
project can register a passkey and sign in with it out of the box.

### Added

- **A `credentials` table**, a `TCredential` model, and five routes:
  a challenge and a registration under `/settings/passkeys`, a delete,
  and a challenge plus a sign-in under `/login/passkey`.
- **`/settings/security` lists your passkeys**, with a button to add one
  and a link to remove each. `/login` gained *Sign in with a passkey*.
- **About thirty lines of inline JavaScript** for both ceremonies. Inline
  for the same reason the rest of the auth scaffold is plain HTML: signing
  in has to work before `npm install` has been run.
- RP ID and origin default to the request, so `askr serve` works with no
  configuration — WebAuthn treats localhost as a secure context. Override
  them in production:

  ```toml
  [webauthn]
  rp_id  = "example.com"
  origin = "https://example.com"
  ```

- Sign-in refuses to say whether a credential exists. Unknown credential
  and bad signature give the same answer, because anything else tells an
  attacker which keys are registered here.

## 0.6.2 — 2026-09-20

Passkeys, from the arithmetic up.

### Added

- **WebAuthn verification.** `Askr.WebAuthn` verifies both ceremonies —
  registering a credential and signing in with one — on top of a CBOR
  reader (`Askr.Core.Cbor`), COSE key parsing, and the ECDSA below.
  [`docs/webauthn.md`](docs/webauthn.md) has the detail.

  Checked: the ceremony type, the challenge, the origin (**exact**
  string equality), the RP ID hash, user presence, that the key is
  ES256 on P-256 and on the curve, and the signature over
  `authData ‖ SHA-256(clientDataJSON)`.

  Not checked: **attestation**. The statement saying which authenticator
  the key came from is read past. Ordinary sign-in does not need it, and
  requiring it locks out hardware you did not plan for. The unit says so
  in its own header so nobody assumes otherwise.

- **ECDSA P-256 verification, in pure Pascal.** `Askr.Core.BigInt` is
  256-bit arithmetic and `Askr.Core.Ec` is the curve; together they are
  the floor WebAuthn needs. Verification runs in about 5 ms and is
  checked against 91 vectors — 40 valid signatures and 51 that must be
  rejected. Nothing else in the framework depends on OpenSSL, and this
  does not either.

  It verifies; it does not sign. That is what WebAuthn needs, and it
  means the code operates only on public values and does not have to be
  constant-time.

- **`askr make auth` scaffolds the pages after sign-in too.** Signing in
  lands on `/dashboard` rather than `/`, and there is a `/settings/profile`
  for name and email and a `/settings/security` for changing a password.
  They are plain HTML like the rest of the auth scaffold, so a new project
  can sign in and look around before `npm install` has been run.
- `/settings/security` has a **Passkeys** section that says it is not
  available yet, and why. WebAuthn needs ECDSA P-256 verification, a CBOR
  decoder and COSE key parsing written in Pascal first, because the crypto
  here does not depend on OpenSSL. A section that explains itself beats a
  button that does nothing.

## 0.6.1 — 2026-09-20

A patch release, tagged because 0.6.0 shipped without this file and
without a consistent language in the output a user sees.

### Added

- **This file.** `CHANGELOG.md` is the full record; `UPGRADE.md` stays
  the short one and carries only what can break your code, which is what
  `askr update` prints before it touches your project.

### Changed

- **28 user-facing strings across 14 files are English.** They were
  Norwegian, against the framework's own rule that everything a user sees
  is English. The ones worth naming:
  - Norn's generated file header, which is written into every schema unit
    in every project.
  - `askr migrate` and its rollback, which printed `ingenting å gjøre`.
  - `Askr.Testing`'s own output — `FEIL`, and the
    `%d tester, %d påstander, %d feil` summary — which every app sees
    from `askr test`.
  - `askr schedule:list`, which described a schedule in Norwegian.
  - `askr serve` and `askr new`, and the line a generated app prints when
    it starts.
  - Exception messages in Urd, Mail, Json and Inertia.

  **If you grep the output of `askr test` in CI, this will break it.**
  The summary is now `%d tests, %d assertions, %d failures` and a failing
  test prints `FAIL` rather than `FEIL`.

## 0.6.0 — 2026-09-20

The first tagged release. Everything before this has no version: the
framework was developed in one repository without releases, and
reconstructing tags after the fact would invent a history that did not
happen.

What 0.6.0 contains is the framework as a whole — HTTP server, routing,
sessions, CSRF, TLS; Urd and Norn across Postgres, MySQL and SQLite;
queue, scheduler, cache, mail, logging and configuration; pure-Pascal
crypto and authentication; the desktop shell on macOS and Linux; Rún;
and the CLI. The entries below are what changed in the run-up to
tagging it.

### Added

**Versioning.** A project pins a release in `askr.toml` and the exact
commit in `askr.lock`:

```toml
[askr]
version = "0.6.0"
```

- `askr install` fetches it into `~/.askr/pkg`, shared across projects.
  `ASKR_CACHE` moves that directory.
- `askr outdated` lists what is published against what you have.
- `askr update` moves, after printing the relevant part of `UPGRADE.md`.
  `askr update <version>` moves the pin in `askr.toml` too.
- `askr version` says what the project actually builds against, not just
  what the tool is.
- `path` in `[askr]` overrides the version with a local checkout, the
  way `replace` does in a `go.mod`.
- The tool rebuilds itself once when the pinned version is not the one
  you invoked, because the list of unit directories is compiled into it.
- `Askr.Core.Version` holds the version, and a test fails if
  `frontend/lauf/package.json` disagrees with it. A release is one number
  across two ecosystems.
- `UPGRADE.md` and [`docs/versions.md`](docs/versions.md).

**Lauf — the frontend layer.** 34 Svelte 5 components on Tailwind v4 and
Bits UI, set up by `askr new` rather than offered as an optional package.

- Semantic tokens, with dark mode defined in one place and three states
  rather than two.
- `Form` and `Field` over Inertia: a field finds its own validation
  error by name and wires up `aria-describedby` and `aria-invalid`.
- `Flash` turns flashed keys into toasts, in two live regions.
- Icons are components generated from Heroicons, not names in a map, so
  a single `<Button>` does not drag 1288 icons into the bundle.
- `./askr lauf`, `./askr lauf:play` and `./askr lauf:check` — the last
  runs the full axe suite in a real browser, because contrast and layout
  cannot be measured in jsdom.

**DataGrid, with its server half in Pascal.** `Askr.Urd.Grid` sorts,
searches and pages **in the database**. `Sortable` is an allowlist that
the type system enforces: `OrderBy` takes a typed column, so
`'ORDER BY ' + parameter` is not an expression you can write.

- `TQuery.WhereAnyLike` — the only `OR` in the data layer, deliberately
  narrow, with the parenthesis around the group that stops an existing
  `Where` from binding to just the first term.
- `TJsonWritable` in `Askr.Core.Json`, so an app can hand Inertia its own
  types without Inertia learning about each one.

**A title on every Inertia page.** `TInertia.SetTitle`, and `askr new`
fills in the project name. The shell had no `<title>` at all and was
marked `lang="no"`, which made a screen reader pronounce English with
Norwegian phonemes — in a framework meant to be international. Found by
running axe against a real site, not by reading the code.

**MIT licence**, and Lauf packaged for npm.

### Changed

- `askr new` wires Lauf into the generated frontend: `app.css` with the
  theme tokens and the `@source` line Tailwind needs to see the library,
  a layout with `<Flash />`, and a home page written in Lauf.
- `askr.toml` gained `[askr]`. The old top-level `askr = "/path"` is read
  as `[askr] path`, so projects made before versioning keep building
  untouched.
- The README is written for a public repository rather than as a working
  note.
- Five CLI messages that reached users in Norwegian are English.

### Fixed

- **A use-after-free in sessions.** The session threadvar was cleared
  last instead of first in `Commit`, so two exit paths skipped it — one
  of them completely ordinary: an anonymous visitor who starts a session
  without writing to it. The next request on that worker got a pointer
  into memory the arena had reused. It surfaced only as an intermittent
  `EAccessViolation` on a small CSS file fetched right after a page on
  the same keep-alive connection, because a large file got a fresh arena
  block and the same bug passed silently. Found by running a real site on
  the framework.
- **Flash dropped every key but one.** The guard in front of the flash
  object asked for a single hardcoded key while the writer took all of
  them, so anything else was discarded in silence — including the
  `error` key the sign-in scaffold uses.
- **`askr` crashed when Free Pascal was not on PATH**, with `EProcess`
  and six lines of hex addresses. It now says what it looked for, where,
  and what to do about it.
- **`askr install` could corrupt `package.json`.** It replaced from the
  first colon on the line, which in compact JSON belongs to
  `"dependencies"` rather than to `"@askrcode/lauf"` — taking the rest of
  the dependency list with it.
