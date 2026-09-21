# The CLI

```
askr <command> [arguments] [--flags]
```

> Not to be confused with `./askr` in a checkout of the framework, which is
> the framework's own build script. This page is about the `askr` on your
> `PATH`.

Every command reads `askr.toml` from the project root, or from the nearest
directory above it.

## Two kinds of command

Some commands the tool runs itself. Others it **asks your binary to run**,
because only the binary knows the answer:

> Migrations are Pascal code compiled into your app. So are the routes, the
> jobs, the schedule and the models. The tool cannot read them. `askr migrate`
> runs `app --migrate`, and `Askr.Console` inside your binary answers.

The practical consequence: **build before you migrate.** A migration you
have written but not compiled does not exist.

```sh
askr build && askr migrate
```

It also means a project created a year ago gets new commands by rebuilding,
not by re-scaffolding — the commands live in the framework, not in the
generated `app.lpr`.

Run `askr list` to see what your binary answers to.

## Project

| Command | What it does
|---|---|
| `askr new <name> [--auth\|--no-auth]` | Create a project; asks about sign-in when run from a terminal |
| `askr build [--target web\|desktop]` | Compile it |
| `askr serve [port]` | Dev server with hot reload |
| `askr test` | Build and run the app's test suite |
| `askr version` | The tool's version, and the framework this project builds against |

### Versions

| Command | What it does
|---|---|
| `askr install` | Fetch the release `askr.toml` pins into `~/.askr/pkg` |
| `askr outdated` | What is published, and what this project has |
| `askr update` | Move to a newer release, showing what changes first |
| `askr update <version>` | Take that release, and move the pin to match |

A fresh clone needs `askr install` before it will build: the lock names
a version, and the source for it is not in the repository. The full
procedure, including what to do when a step refuses, is in
[Versions](versions.md).

These four never run through the delegated tool — they are what manages
the pin, so they run as the `askr` you invoked.

### Which compiler

`askr build`, `askr serve` and `askr test` shell out to Free Pascal. They
look for it in this order:

1. `compiler` in `askr.toml`, if you set it — the project's own choice wins
2. `ASKR_FPC`, for pointing at a compiler on your machine without editing
   the project file
3. `fpc` on `PATH`

If none of them resolves, the command says what it looked for, where, and
what to do about it. It does not stack-trace at you.

```
askr: cannot find the Pascal compiler.

  looked for   fpc   on PATH
  ASKR_FPC     not set

Askr builds your app with Free Pascal. Install it, then either put it
on PATH or point at it:

  export ASKR_FPC=/path/to/fpc

or set it for this project only, in askr.toml:

  compiler = "/path/to/fpc"
```

> **A key in `askr.toml` must come before `[app]`.** Everything after a
> section header belongs to it, so `compiler` written at the bottom becomes
> `app.compiler` and is silently ignored.

## Scaffolding

| Command | Writes |
|---|---|
| `askr make model <Name> [--migration]` | `app/Models/App.Models.<Name>.pas` |
| `askr make controller <Name>` | `app/Http/App.Http.<Name>Controller.pas` |
| `askr make migration <Name>` | `database/App.Migrations.<Name>.pas` |
| `askr make seeder <Name>` | `database/App.Seeders.<Name>.pas` |
| `askr make job <Name>` | `app/Jobs/App.Jobs.<Name>.pas` |
| `askr make middleware <Name>` | `app/Http/App.Http.<Name>.pas` |
| `askr make auth [--force]` | The whole sign-in stack — see [Authentication](auth.md) |

Migrations and seeders register themselves in their own `initialization`
section. A unit nothing references is never linked in, so `make` also
regenerates `database/App.Migrations.pas` and `database/App.Seeders.pas` —
index units that exist only to `uses` them. Those two are generated; do not
edit them.

The index is read from the directory, not from a list. A file added by hand
or deleted cannot become invisible.

## Migrations

| Command | What it does
|---|---|
| `askr migrate` | Run everything pending |
| `askr migrate --step=N` | Run the next N only |
| `askr migrate:status` | What has run, what has not, what is missing |
| `askr migrate:rollback [--step=N]` | Roll back the last N (default 1) |
| `askr migrate:reset` | Roll back everything |
| `askr migrate:fresh [--seed]` | Drop every table, then migrate |
| `askr migrate:refresh [--seed]` | Reset, then migrate |

`migrate:status` has three states. `applied` and `pending` are obvious;
**`MISSING`** means a migration ran against this database but its source
file is gone. That is a state you want to know about.

```
Version            State      Title
20260920144652     applied    Create posts
20260921090300     pending    Add slug to posts
```

## Database

| Command | What it does
|---|---|
| `askr db:seed [Name]` | Run the seeders, or one of them |
| `askr db:show` | Tables, with column and index counts |
| `askr db:table <name>` | Columns, types, nullability, indexes, foreign keys |
| `askr db:wipe [--force]` | Drop every table |
| `askr schema` | Generate typed columns from the live database |

`db:table` shows the Pascal type each column maps to, which is the fastest
way to find out why a generated column is not the type you expected:

```
Column                   Type                 Null     Pascal
id                       INTEGER              yes  (pk) Int64
name                     VARCHAR(120)         no       string
created_at               DATETIME             no       TDateTime
```

`db:wipe` **refuses to run when `APP_ENV=production`** unless you pass
`--force`. It is the one command that destroys everything, and it should
not be possible to run it by accident.

## Runtime

| Command | What it does
|---|---|
| `askr queue:work` | Run the queue until interrupted |
| `askr queue:status` | Counters: pending, processed, retried, failed |
| `askr schedule:list` | The schedule |
| `askr schedule:run` | Dispatch what is due, once |
| `askr cache:clear` | Empty the cache |

`queue:work` exists for running the queue as its own process. You do not
need it — the app process can serve HTTP and run the queue at the same
time, which is the point of having no sidecars. It is there for when you
want to scale them separately.

## Maintenance

| Command | What it does
|---|---|
| `askr down` | Maintenance mode on |
| `askr up` | Maintenance mode off |

`down` writes a file, and `UseMaintenance` in your router answers **503 with
`Retry-After`** while it exists. A file and not a flag in memory, because
`askr down` is a different process from the server, and because the mode
should survive a restart. The running server picks it up immediately; no
restart needed.

## Inspection

| Command | What it does
|---|---|
| `askr about` | Environment, config files, database, routes, queue, schedule |
| `askr routes` | The routing table, sorted by specificity |
| `askr config [--values]` | Every key, and which layer it came from |
| `askr env` | The current `APP_ENV` |
| `askr list` | The commands this binary answers to |
| `askr key:generate` | A new `APP_KEY` |

`askr config` shows **no values** without `--values` — the output is safe to
paste into a bug report. With `--values`, keys that look like secrets are
still hidden:

```
APP_ENV           .env          local
APP_KEY           .env          (hidden)
DATABASE_URL      environment   (hidden)
app.port          askr.toml     8080
```

`key:generate` prints a key; it does **not** write it into `.env`. A key
swapped silently logs everyone out.

## An MCP server for agents

```sh
askr mcp
```

JSON-RPC 2.0 over stdio, for coding agents. Point a client at the command;
it takes no arguments and needs no port.

```sh
askr mcp:install            # Claude Code, into .mcp.json
askr mcp:install cursor     # .cursor/mcp.json
askr mcp:install vscode     # .vscode/mcp.json
```

**A configuration file that already exists is never rewritten.** It is read;
either an `askr` server is already there, or the lines to add are printed
and you add them. These files carry comments, ordering and formatting that
a parse-and-rewrite loses, and some of them are JSONC, which Askr's parser
does not read at all. Four lines to paste cannot destroy anything.

`askr new` also writes an **`AGENTS.md`**, which is what a coding agent
reads before it starts. It is deliberately short: it names the tools and
the few things that are quiet when you get them wrong, and leaves the
framework itself to `docs_search` and `docs_read`. A copy of the
documentation there would be frozen at the day the project was created and
would start lying the first time Askr is upgraded.

| Tool | What it does |
|---|---|
| `build` | Compiles the project and returns `file:line:column` with a severity |
| `routes` | The routing table, in the order requests match |
| `schema` | The tables in the database; with a table, its columns |
| `config` | Every key and the layer it resolved from |
| `docs_search` | Exact substring across the documentation |
| `test` | Builds and runs the test suite, and stops one that hangs |
| `docs_read` | A page, or one section of it; no page lists them all |

`routes` and `schema` read the compiled binary, because that is where the
routes and the database connection are. They say so when the app has not
been built rather than answering emptily.

**The server runs in the tool, not in your app.** The reason is specific to
a compiled framework: if the app does not compile there is no app to ask —
and that is
exactly the moment an agent most needs to be told what is wrong. `askr mcp`
answers the handshake whether or not your project builds, and whether or
not there is a project at all.

**A failed build is a successful call**, and so is a failing test. The
tool reports what happened and sets `isError` to false. `isError` is true
only when the tool could not run: no project, no compiler, an `[askr] path`
that is not a checkout, no test file. Conflating the two makes an agent
retry the wrong thing.

`test` separates a suite that failed from one that did not compile. Both
exit non-zero, and they need opposite work.

**`test` stops a suite that hangs**, after 120 seconds by default and 600
at most. A person at a terminal sees a suite stall and presses Ctrl-C; an
agent cannot, and a call that never returns takes the session with it. What
the suite printed before it was stopped comes back with the answer, because
that is usually where the hang is.

**The docs are your version's docs.** `docs_search` and `docs_read` read
the `docs/` of the framework tree your project resolves to — the pin in
`askr.toml`, not whatever release the `askr` on your PATH happens to be.
An agent reading the current docs for a project pinned two releases back
would be confidently wrong, and nothing would say so.

**`config` never shows a value, and there is no flag here that does.**
`askr config --values` exists for a person at their own terminal, who can
see their own screen. This output goes into an agent's context and on to
whatever model is behind it, and that is not the tool's decision to make.

Nothing is redacted either, because nothing is read. A redactor is a list
of words — `LooksSecret` says in its own comment that it cannot be
definitive — and the word that matters is the one not on the list yet.
Measured, in a project with three secrets in `.env`: `--values` hides
`DATABASE_URL` and `MAIL_PASSWORD`, and prints `STRIPE_LIVE_ACCOUNT` in
full.

The layer each key came from is what answers nearly every question anyone
actually has. "Why is it using SQLite" is answered by `.env`, not by the
value.

**The search is an exact substring, and never fuzzy.** Ask for a name that
does not exist and you get no match — not the nearest one that does. Askr's
API names are easy to guess wrong by a dot or a capital, and a search that
forgave that would hand back a page reading as confirmation; the agent would
then write the wrong call with documentation apparently behind it. No match
means no match, and the tool says so rather than guessing.

### What is not here yet

There are no resources and no prompts — declaring a capability that is not
served is worse than declaring none.

There is no `--json` on the console commands, and the tools do not ask for
one. The tool passes the app's own output through unchanged, so an agent
reads exactly what you read, and there is no second format to keep in step
with the first. A tool that had to *parse* that output would need one; none
of these do.

## What is deliberately missing

Commands that pre-compile configuration, routes or views. They exist in
interpreted stacks because the runtime re-parses source on every request,
and the cache is what saves it. **In Askr the binary is the cache.** Those
commands would be ceremony with no effect.

Commands that publish or discover package assets belong to a package
manager, and Askr's is `askr install`. Generators for casts, traits,
interfaces and service providers are for language constructs Pascal does
not have and for a service container Askr has declined, with reasons on the
pages where they would have applied. A REPL needs an interpreter for Pascal
expressions and is deferred on purpose.
