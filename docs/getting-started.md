# Getting started

## The toolchain

Askr needs Free Pascal. It builds and passes its full test suite on **3.2.2**
and **3.3.1 trunk** — keeping both green is how the project finds out
whether a compiler limitation is gone or has only moved.

```sh
# Debian, Ubuntu
apt install fpc

# macOS
brew install fpc
```

If `fpc` is on `PATH` it is used. Otherwise the framework's own build script
builds and uses the Docker image in `tools/Dockerfile.fpc`. Point
`ASKR_FPC` at a specific compiler to override both.

> The official `freepascal/fpc` image is musl-based and does not link
> against `cthreads`. Do not use it.

Optional, per feature:

| Library | Needed for |
|---|---|
| `libpq` | Postgres |
| `libmariadb3` / `mariadb-connector-c` | MySQL — this is the binding, not `libmysqlclient` |
| `libsqlite3` | SQLite |
| `libssl` / `libcrypto` (OpenSSL 3) | HTTPS, STARTTLS, the HTTP client over TLS |
| GTK3 + WebKitGTK | The Linux desktop shell |

All of them are loaded with `dlopen` at first use. The binary starts on a
machine that has none of them; you only pay for what you touch.

> **On macOS you must install OpenSSL yourself** (`brew install openssl@3`).
> The system `libssl` is LibreSSL, and Apple blocks `dlopen` against it from
> third-party binaries — the process dies with "loading libcrypto in an
> unsafe way". There is no way around it.

## Build the CLI

From a checkout of the framework:

```sh
./askr cli
```

> **Two things are called `askr`.** `./askr` in a checkout of the framework
> is the framework's own build script — it builds and tests Askr itself, and
> has commands like `./askr test`, `./askr check` and `./askr tls:certs`.
> `askr` on your `PATH` is the CLI you use in a project. This documentation
> writes `./askr` for the first and plain `askr` for the second.

That builds `.build/bin/askr`. Put it on your `PATH` and tell it where the
framework lives:

```sh
export PATH="/path/to/askrcode/.build/bin:$PATH"
export ASKR_HOME="/path/to/askrcode"
```

## A new project

```sh
askr new shop
cd shop
askr serve
```

`askr new` asks whether the project needs sign-in. Say yes and you get
`/login`, `/register` and `/reset-password` wired up — see
[Authentication](auth.md). `--auth` and `--no-auth` answer for a script.

`askr serve` builds the app and starts it behind a dev server that watches
your source and rebuilds on change. The loop is measured at **247 ms** on
the reference machine, against a 300 ms budget.

Open `http://127.0.0.1:8080`. You get a welcome page that ships with the
framework: no npm, no network, no files beside the binary. It shows the
arena for the worker that served it, which is the shortest possible
demonstration of what makes Askr different.

## What you got

```
shop/
  askr.toml                  project settings; the app reads them too
  .env                       secrets; never committed
  .env.example               the list of what a new developer must fill in
  app.lpr                    the program: wiring, routes, server
  app/
    Http/
      App.Http.HomeController.pas
  database/
    App.Migrations.pas       generated index; do not edit
    App.Seeders.pas          generated index; do not edit
  frontend/                  Vite + Svelte 5 + Inertia
```

A new project has **sessions, CSRF protection and authentication wired in
from the first request**. A POST without a valid token answers 419 before
it reaches your handler. That is not something you switch on; it is the
default, and turning it off is the deliberate act.

## Your first route

`app.lpr` holds the wiring. Routes are registered there:

```pascal
R.Get('/', Home.Index);
R.Get('/demo', Home.Demo);
```

The handler lives in a controller:

```pascal
function THomeController.Index(Req: TRequest): TResponse;
begin
  Result := RespondText('hello');
end;
```

Add a route, save, and the dev server rebuilds. See [Routing](routing.md).

## Your first table

```sh
askr make model Post --migration
```

That writes a model in `app/Models/` and a migration in `database/`. Set a
database in `.env`:

```
DATABASE_URL=sqlite:shop.db
```

Then:

```sh
askr migrate
askr db:table posts
```

`askr migrate` cannot be run by the tool. Migrations are Pascal code
compiled into your binary, so the tool asks the binary to run them. That is
why you must `askr build` (or `askr serve`) before a migration is visible.

See [Migrations](migrations.md) and [Models](models.md).

## The frontend

Inertia and Svelte 5 are set up but not installed:

```sh
cd frontend && npm install
```

Restart with `askr serve` and `/demo` becomes a Svelte page. You can also
ignore all of it: Askr serves HTML, JSON and files without a frontend build
step. See [Inertia and Svelte](inertia.md).

## Where to go next

- [The arena](arena.md) — read this before you write code that outlives a
  request. It is the one rule that is not like other frameworks.
- [The CLI](cli.md) — every command.
- [Configuration](configuration.md) — where values come from and which
  source wins.
