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
