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

| Command | |
|---|---|
| `askr new <name> [--auth\|--no-auth]` | Create a project; asks about sign-in when run from a terminal |
| `askr build [--target web\|desktop]` | Compile it |
| `askr serve [port]` | Dev server with hot reload |
| `askr test` | Build and run the app's test suite |
| `askr version` | |

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

| Command | |
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

| Command | |
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

| Command | |
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

| Command | |
|---|---|
| `askr down` | Maintenance mode on |
| `askr up` | Maintenance mode off |

`down` writes a file, and `UseMaintenance` in your router answers **503 with
`Retry-After`** while it exists. A file and not a flag in memory, because
`askr down` is a different process from the server, and because the mode
should survive a restart. The running server picks it up immediately; no
restart needed.

## Inspection

| Command | |
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

## What is deliberately missing

Laravel has `optimize`, `config:cache`, `route:cache`, `view:cache` and
`clear-compiled`. Those exist because PHP re-parses source on every request,
and the cache is what saves it. **In Askr the binary is the cache.** Those
commands would be ceremony with no effect.

`vendor:publish`, `package:discover` and `install:*` belong to Composer.
`make:cast`, `make:trait`, `make:interface` and `make:provider` are PHP
language constructs and the service container, which Askr has declined with
reasons in `LARAVEL.md`. `tinker` needs an interpreter for Pascal
expressions and is deferred on purpose.
