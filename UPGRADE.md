# Upgrading Askr

`askr update` prints the sections between the version you are on and the
one you are moving to, **before** it changes anything in your project.
That is the point of this file: an upgrade you have not read is an
upgrade you debug afterwards.

One heading per release, newest first. Only things that can break your
code belong here — everything else is in the commit log.

## 0.10.0

Nothing can break. Everything in this release is additive: an MCP server
for coding agents, and the tools it serves.

**Worth knowing if you use a coding agent.** `askr mcp` is a server your
agent can talk to over stdio — it compiles, runs the tests, and answers
questions about the routes, the database and the documentation of the Askr
version *this project* pins. Wire it in with `askr mcp:install`. New
projects also get an `AGENTS.md`; an existing project can copy one from a
scaffolded project, or write its own.

**Two error paths stopped printing your DSN.** `DSN has no scheme: <dsn>`
and `Invalid MySQL DSN: <dsn>` put the whole connection string, password
included, into the message — and that message is the one that ends up in a
log or an issue. They now say what was expected instead. If anything of
yours matched on that text, it has changed.

**`LARAVEL.md` is gone** from the repository. Nothing in `docs/` pointed at
it any more.

## 0.9.2

Nothing can break. Documentation, the test suites, one example, and a new
build-script target.

**Worth reading if you store money.** The rule for `Currency` in the docs
was wrong, and it was wrong in a direction that is silent. A typecast from
an integer reinterprets the scaled Int64 instead of converting it, and
whether it does so depends on the compiler *and* the architecture:
`Currency(I * 100)` is 0.07 on x86_64 and 700 on aarch64. The framework's
own uses were fixed in 0.9.1; if your app writes `Currency(something)`
anywhere, that line is worth looking at. Assign into a `Currency`
variable instead. See [Money](docs/database.md#money).

## 0.9.1

Nothing can break. One compile fix, needed only on x86_64 — where 0.9.0
does not build at all.

## 0.9.0

One thing can break, and only if you use the CBOR reader directly:
**`TCborReader.Ferdig` is now `TCborReader.FullyConsumed`.** Nothing in
Askr called it — `Askr.WebAuthn` uses `AtEnd` — so this is very unlikely
to be you. Every other renamed identifier in this release was private or
local.

Two things are worth knowing but cannot break an existing project:

**The code `askr new --auth` generates uses English names now.** `Epost`
is `Email`, `Passord` is `Password`, `Meg` is `CurrentUser`, and so on.
Your already-generated `App.Http.AuthController.pas` is yours and is not
touched; only newly scaffolded projects differ. If you rerun
`askr make auth --force`, the file is rewritten and your own edits to it
go with it — that has always been true of `--force`.

**`Lauf.Tabs` gained props and changed no defaults.** `variant` defaults
to `underline` and `size` to `base`, which is what the old component
rendered. Tabs that overflow now wrap instead of pushing the page wider;
if you want the old single line, pass `scrollable`.

## 0.8.1

Nothing can break. Documentation only.

## 0.8.0

Nothing can break in the framework. One new unit, and `Askr.Mail` only
gained members.

Two things are worth knowing if you touch mail:

**`askr make auth --force` now writes a different mail line.** It becomes
`SetMail(TMailer.Create(MailFromConfig))` and adds `Askr.Mail.Resend` to
`uses`. If you rerun the scaffold, set `MAIL_TRANSPORT` in `.env` —
without it the default is `log`, which sends nothing. Projects that do
not rerun it are unaffected.

**`MailFromConfig` reads `MAIL_HOST`, not `SMTP_HOST`.** The old
generated code called `CfgOrFail('smtp.host')` directly and still does;
only the new function uses the `mail.*` names. Nothing renames itself
under you.

## 0.7.0

Nothing can break. Two new units; none changed.

Resizing needs libvips, which is optional and loaded at first use. If
you do not call `Askr.Image.Vips`, nothing about your app changes.

## 0.6.4

Nothing can break. Run `askr install` once to pick up the new Lauf path;
until you do, the absolute one in `frontend/package.json` keeps working.

## 0.6.3

**`askr make auth --force` now writes a third migration** and a
`TCredential` model. On an existing project, rerunning the scaffold adds
`App.Migrations.CreateCredentials` and you need `askr migrate` after it.

Nothing else changes. Projects that do not rerun the scaffold are
unaffected.

## 0.6.2

Nothing in this release can break your code. It adds units; it changes
none. The sign-in scaffold's Passkeys section changed wording, because
it used to say Askr had no WebAuthn and that is no longer true.

## 0.6.1

**Test output is English.** If anything of yours greps `askr test`, it
breaks here. The summary line changed from
`%d tester, %d påstander, %d feil` to
`%d tests, %d assertions, %d failures`, and a failing test prints `FAIL`
instead of `FEIL`.

Nothing else in 0.6.1 can affect your code: the rest is output strings
in commands you read rather than parse.

## 0.6.0

First release with a version number, so there is nothing to upgrade
*from* yet. What changed is how a project says which framework it wants.

**`askr.toml` gained an `[askr]` section.**

```toml
[askr]
version = "0.6.0"
# path = "/path/to/askrcode"
```

`version` pins a release, which `askr install` fetches into
`~/.askr/pkg`. `path` overrides it with a local checkout, which is what
you want when you are working on the framework itself.

The old top-level form still works:

```toml
askr = "/path/to/askrcode"
```

It is read exactly as `[askr] path` would be, so **projects created
before versioning existed keep building with no changes**. There is no
deprecation warning and no removal date; when the two forms disagree,
`[askr] path` wins.

**`askr.lock` is new, and belongs in git.**

It records the exact commit behind the version, and the
`@askrcode/lauf` version that goes with it. A release spans two
ecosystems — the Pascal source and the npm package — and they are not
allowed to drift apart. `askr install` writes the matching Lauf version
into `frontend/package.json` for you.

If `askr install` refuses because the lock and the cache disagree, the
tag has been moved under you. Delete the cached copy and let it refetch;
the message tells you the path.

**The tool may rebuild itself once.**

`askr` is built *from* the framework, so the list of unit directories is
compiled into it. When your project pins a version that is not the tool
you invoked, `askr` builds that version's tool once into the cache and
re-runs your command with it — the same idea as `bundle exec`. You see
one line about it, and only the first time.

A local `path` is exempt: if you are working on the framework, you are
meant to run the tool you just built.
