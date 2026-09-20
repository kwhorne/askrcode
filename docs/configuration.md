# Configuration

Four layers, consulted in this order:

1. **Real environment variables**
2. **`.env`**
3. **`askr.toml`**
4. The default the caller passes

Keys are written with dots and looked up with underscores: `app.port`
becomes `APP_PORT` in the environment. That is the whole rule, and the only
part worth memorising is that **the environment always wins.** A deployment
must be able to set something without editing a file in the repository.

```pascal
uses Askr.Core.Config;

LoadConfig;                              { .env and askr.toml, found upwards }

Port := CfgInt('app.port', 8080);
Dsn  := CfgOrFail('database.url');       { raises if missing }
Debug := CfgBool('app.debug', False);
```

`LoadConfig` is called once, first thing in `app.lpr`. It searches upward
from the current directory for both files, so commands work from a
subdirectory.

## The API

| | |
|---|---|
| `Cfg(Key)` / `Cfg(Key, Default)` | A string |
| `CfgInt(Key, Default)` | An integer, or the default if it does not parse |
| `CfgBool(Key, Default)` | `1/true/yes/on` and `0/false/no/off` |
| `CfgHas(Key)` | Present in any layer, even with an empty value |
| `CfgOrFail(Key)` | Raises `EConfigError` naming the key and where it looked |
| `CfgSource(Key)` | Which layer answered: `csEnvironment`, `csDotEnv`, `csToml`, `csNone` |
| `EnvNameFor(Key)` | `app.port` → `APP_PORT` |
| `ConfigFile` | Path of the `askr.toml` in use |

`CfgOrFail` names the key, the environment variable that would set it, and
the files it looked in — **never a value**:

```
Missing configuration "database.url". Set DATABASE_URL, or add it to
askr.toml. Looked in the environment, /srv/shop/.env, /srv/shop/askr.toml.
```

## `.env`

`.env` is where secrets live. Three rules, and they are not negotiable:

- **Real environment variables win over the file.** That is how production
  sets values without the file existing, and it is how everyone else does it.
- **`.env` is never committed.** `.env.example` is. `askr new` puts `.env`
  in `.gitignore`.
- **Values are never logged.** An error names the key that was missing,
  never what it contained. `EnvOrFail` is written to be safe to leave in a
  stack trace, and a test asserts that no value leaks into the message.

The format is the usual one:

```sh
SIMPLE=hello
export EXPORTED=yes
QUOTED="a b  c"
ESCAPED="line1\nline2"      # \n \t \" \\ are interpreted
LITERAL='raw \n stays'      # nothing is interpreted
TRAILING=value   # a comment
HASHPASS=pa#ssword          # no space before # — part of the value
EMPTY=
```

A `#` without a space in front of it is part of the value, not a comment.
Otherwise a password containing `#` would be cut in half.

The file is read into the framework's own store, **not set with `setenv`**.
FPC's RTL keeps its own copy of the environment from startup, so `setenv`
would not reach a child process anyway, and a store we own is easier to
reason about than one we share with libc.

## `askr.toml`

The smallest thing that looks like TOML: `key = value`, one per line,
sections in brackets. No tables, no arrays beyond comma-separated strings,
no multi-line values. Needing more is a sign that the configuration has
grown past what it should be.

```toml
name = "shop"
main = "app.lpr"
frontend = "frontend"

units = "app,database"
watch = "app,database,frontend/src"
askr = "/path/to/askrcode"

[app]
port = 8080
backend_port = 8081
```

The parser is shared between the CLI and the app — `askr.toml` must not be
able to mean one thing to the tool and something else to the binary it
builds.

> **A `[section]` applies to everything below it.** `[app]` is written last
> in a generated `askr.toml` for that reason. In the middle of the file it
> would turn `units` into `app.units` and the build would stop finding the
> framework. That happened.

The app reads `[app] port` as `app.port`, which `APP_PORT` overrides.

## Environment awareness

```pascal
uses Askr.Core.Env;

AppEnv;         { 'local' unless APP_ENV says otherwise }
IsProduction;   { 'production' or 'prod' }
IsLocal;        { 'local', 'development', 'dev' }
IsTesting;      { 'testing', 'test' }
```

The default is `local`, not `production`. An app that *thinks* it is in
production without being there turns on things nobody asked for; the other
way around is noticed immediately.

`APP_ENV` changes exactly one thing by itself: the default log format is
text locally and JSON in production. See [Logging](logging.md).

## Failing at startup, not on request 47

```pascal
RequireEnv(['DATABASE_URL', 'APP_KEY', 'SMTP_HOST']);
```

Checks all of them and raises **once**, listing every key that is missing —
never a value. One error at a time means as many restarts as there are
missing keys.

The point is the timing. Without it, a missing `DATABASE_URL` is discovered
on the first request that touches the database, possibly in production,
possibly as a 500 for a user.

## Seeing what actually applies

```sh
askr config            # keys and sources, no values — safe to paste
askr config --values   # values too, secrets still hidden
```

```
askr.toml  /srv/shop/askr.toml
.env       /srv/shop/.env
APP_ENV    production

APP_ENV           .env
DATABASE_URL      environment
app.port          askr.toml
```

`LooksSecret` decides what to hide: a key containing `secret`, `password`,
`token`, `key`, `credential`, `dsn` or `url`. It is not a definitive list
and cannot be one — which is why the default is to show no values at all.

## What is not here

Laravel's `config/` directory of PHP files, and `config:cache`. Askr's units
already take typed options records — `TServerOptions`, `TSessionStore.Create`,
`TDbPool.Create` — and a string-keyed `config('mail.from')` would be a step
down from something the compiler checks. The configuration layer is for
values that arrive from outside, not a replacement for parameters.
