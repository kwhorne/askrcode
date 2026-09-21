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
