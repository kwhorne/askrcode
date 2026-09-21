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

Nothing yet.

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
