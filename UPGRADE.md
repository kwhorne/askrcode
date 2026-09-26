# Upgrading Askr

`askr update` prints the sections between the version you are on and the
one you are moving to, **before** it changes anything in your project.
That is the point of this file: an upgrade you have not read is an
upgrade you debug afterwards.

One heading per release, newest first. Only things that can break your
code belong here — everything else is in the commit log.

## Unreleased

**`askr <word>` for a word nothing answers exits 64, not 1.** A script
that checked for exit 1 after an unknown command will see 64.

**`Preload` leaves soft-deleted children out of a `HasMany` and a
`HasOne`.** Before, a trashed child was loaded along with the rest, unlike
a query for the same rows. A page that listed a parent's children with
`Preload` stops showing the deleted ones; one that relied on seeing them
queries them with `WithTrashed` instead. A `BelongsTo` still loads a
trashed parent.

**A Lauf `<Checkbox>` with a `value`, inside a `<Form>`, sends a list.**
Boxes that share a name and each carry a value are a group now, and the
form holds the ticked values as an array. A single box that happened to
have a `value` attribute sent `true` or `false` before; it sends `["yes"]`
or `[]` now. Take the `value` off to keep the boolean.

**A number in a validation message is written as the locale writes it.**
In English that means grouping: `MinLen(1500)` says "at least 1,500
characters", not "1500". A test that compared the message will see the
comma. The same goes for Lauf's pagination, which says `of 9,000`.

**Inertia pages carry a `locale` prop.** An app that shares a prop of its
own called `locale` still wins -- it is written after -- but it is what
Lauf will format numbers with, so it should be a locale tag.

**A root template of your own gets no `lang` by itself.** The default one
has `<html lang="{{lang}}">`; put `{{lang}}` in yours to have the request's
locale there.

## 0.13.1

**`FillInto` no longer fills `created_at`, `updated_at` or `deleted_at`**
on a model that has `S.Timestamps` or `S.SoftDeletes`. If a handler
relied on a request to set one of them -- restoring a soft-deleted row by
sending `deleted_at: null`, say -- set it in code instead, or call
`Restore`. `FillInto(M, ['deleted_at'])` now raises rather than filling it.

## 0.13.0

**Worth reading if you have after-filters of your own, a frontend that
reads dates, a SQLite schema with booleans, or a session store you size by
signed-in users.** Most of what follows is something that was wrong being
right, and each of them changes something an app could have been built
around.

**`askr make` no longer writes over a file that is there.** A script that
ran `askr make model X` to refresh a stub now stops and names the file.
Pass `--force` to get the old behaviour.

**`askr schema` removes a generated file whose table is gone.** Only files
carrying Norn's header, and it says which. If you kept one on purpose --
you should not have, since it describes a table that is not there -- it is
in git.

**The migrator refuses two migrations with the same version**, before it
runs anything. If you have two, `askr migrate` will say which and stop;
change the `Version` of one of them. It used to run one of them and fail
to record it.

**A new SQLite boolean column is a `TColBool`.** `askr schema` reads what
a table was declared with, and a SQLite migration declares `BOOLEAN` now
instead of `INTEGER`. A table made from now on types its booleans as
`Boolean` on SQLite as on the other two; code that treated one as an
`Int64` on SQLite only will stop compiling, which is where it should.
Tables that exist are not touched.

**An unset date is `null` in JSON**, not `"1899-12-30 00:00:00"`. A
frontend that tested for that string, or that assumed a date is always a
string, needs to handle `null`. The OpenAPI document says
`["string", "null"]` for every date, so a generated client changes too.

**When `UseCsrf` is on, an Inertia page creates the session.** Every
visitor who sees a page gets a session cookie and a slot in the session
store. It is what lets a form on that page be sent at all; if you counted
on sessions only for signed-in users, that is no longer true for pages.

**`askr make model` writes `S.ZeroIsNull` for a reference.** Nothing to do
for a model that exists; a new one gets the line.

**After-filters now run when a handler raises.** Before, an exception
skipped them. A filter of yours that assumed it only ever saw the
handler's own response will now also see the 403, 404 or 500 the request
ended with. A test that expected `EForbidden` to come out of
`TTestClient` gets a 403 response instead.

## 0.12.0

**Worth reading if anything but a browser calls your app.** The framework
now answers a client that asked for JSON differently from one that asked
for a page, on the routes it answers for you and in `BackWithErrors`.

`BackWithErrors` returns **422** with an `application/problem+json` body
when the caller's `Accept` names `application/json` before `text/html`,
instead of a 302 with the errors in a session flash:

```json
{ "type": "about:blank", "title": "Unprocessable Content", "status": 422,
  "detail": "The request body did not validate.",
  "errors": { "email": "email is not a valid email address" } }
```

Browsers and Inertia clients are unchanged — an Inertia request is never
treated as a JSON one, whatever its `Accept` header says. The break is for
a client of your own that posted with `Accept: application/json` and was
relying on the redirect. It was almost certainly relying on it badly: the
errors went into a flash it never read.

The same negotiation applies to 404, 405, 419 and 401, and to the 500
after an unhandled exception. A JSON client gets a problem document; every
other client gets the byte-for-byte body it got before.

Nothing needs changing in your code. If you want the old behaviour on one
route, branch on `Req.AcceptsJson` yourself.

**`Authorize` raises `EUnauthenticated` rather than `EForbidden` when
nobody is signed in**, and the server answers 401 instead of 403. Both
still descend from `EAuthError`, so `on E: EAuthError` catches either. It
can break you only if something was catching `EForbidden` specifically
and relying on it to cover the anonymous case, or was asserting on a 403
that should have been a 401.

**A new project gets a rate limit.** `askr new` writes
`RateLimit.PerMinute(600)` into `app.lpr`. Nothing changes for a project
that already exists -- the limiter is off until it is configured -- but a
new one refuses a caller past 600 requests a minute with a `429`. The
number is a starting point, not a measurement; change it in `app.lpr`, or
delete the two lines.

CORS is closed in a new project and in an existing one: `UseCors(R)`
allows nothing until an origin is named.

**`Paginate` adds the primary key to the end of the `ORDER BY`.** Without
it a page is not reproducible: two rows the sort cannot tell apart may
come back either way round on each query, so a row appears on two pages
and another on none. If you were reading the SQL, or counting the terms
in an `ORDER BY`, it has one more. Nothing about the rows you get changes
except that they stop moving. `Limit` and `Offset` used directly are
untouched.

**A list with nothing in it now serialises as `[]` rather than `null`.**
This reaches Inertia props and relations as well as API payloads. Code
that tested a prop for `null` to mean "empty" has to test for length
instead; code that iterated it stops needing a guard.

**Middleware now runs in the order you registered it.** It used to run
every method before every plain procedure, whichever order they were
written in. If you have both kinds on one router and were relying --
knowingly or not -- on the old grouping, the order changes. The new order
is the one the call site reads as. After-filters are likewise one list in
reverse registration order.

**`EForbidden` is now a 403 rather than a 500.** `Authorize` and the new
`AuthorizeScope` raise it, and the server answers with the status the
exception names. This was always what the code said it did; nothing
translated it until now. It can break you only if something was counting
on gates producing a 500, or was catching `EForbidden` and would rather
the server did not answer for it -- catch it in the handler as before,
and nothing reaches the server.

`EAuthError` now descends from `EHttpError` rather than `Exception`
directly. `Exception` is still an ancestor, so `on E: Exception` is
unaffected.

## 0.11.2

Nothing can break. Documentation, and one example.

The Resend transport has been run against the real API with a real key,
so the caveat that said otherwise is gone from every page that carried it.
`examples/mail/resendprobe.lpr` is that run. Only the Windows shell is
still on the never-run list.

## 0.11.1

**Worth reading if you use the AI layer's tool loop.** It was sending the
assistant turn back without the `tool_use` blocks it had asked with, and
Anthropic's API refuses the results that follow — so `RunTools` failed with
a 400 the moment a model actually called a tool. It works now. Nothing you
wrote needs changing for that.

**`TAiMessage` changed shape**, and this can break code that builds one by
hand. `ToolUseId`, `IsToolResult` and `IsError` are gone; there are
`ToolCalls` and `ToolResults` arrays instead, because one turn can ask for
several tools and all the answers have to travel in one message.
`ToolResultMsg(Id, Text)` still works and makes a one-element version. If
you only ever used `UserMsg`, `AssistantMsg` and `ToolResultMsg`, nothing
changes.

## 0.11.0

Two things can break, and both only if you already have a frontend.

**A custom root template needs a `{{fallback}}` placeholder** — but only
once a page starts using `TInertia.PageFallback`. Until then nothing
changes. When one does, put it inside the mount element:

```html
<div id="{{root}}">{{fallback}}</div>
```

A page that sets a fallback against a template with nowhere to put it
raises, rather than dropping it quietly.

**Your `main.js` needs one line**, for the same feature. Svelte 5 mounts by
appending, so without it the reader sees the page twice:

```js
setup({ el, App, props }) {
  el.innerHTML = ''
  mount(App, { target: el, props })
}
```

`askr new` writes both. Everything else in this release is additive:
`app.url` and absolute URLs, conditional GET with ETags, `robots.txt`,
`sitemap.xml`, and per-page head metadata. See
[the changelog](CHANGELOG.md).

**One behaviour changed without a flag.** Static files now carry an `ETag`
and answer `304` to a matching `If-None-Match`. If something of yours
compares response bodies byte for byte across requests, it will now
sometimes get an empty one with a 304 instead.

## 0.10.1

Nothing can break. Documentation, and one error message.

**Worth reading if you use `WhereAnyLike`, or thought you could not.**
`docs/queries.md` said "`OR` groups are not in the builder". That was
wrong: `TQuery.WhereAnyLike` is one, it is the only one, and the data grid
uses it for every search box. It is documented now — signature, the
parenthesis around the group, and what `CaseSensitive` does on each
dialect. No code changed.

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
