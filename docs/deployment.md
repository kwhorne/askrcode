# Deployment

```sh
askr build
```

One binary. Copy it, and the files it reads at runtime, to the server.

```
app                   the binary
askr.toml             settings the app reads
public/               static files, including the Vite build
storage/              whatever you write at runtime
```

`.env` belongs to the machine, not to the artifact. In production, prefer
real environment variables — they win over the file, which is exactly why
that rule exists.

## What it needs at runtime

Nothing, unless you use it. Every client library is loaded with `dlopen` on
first use.

| If you use | Install |
|---|---|
| Postgres | `libpq5` |
| MySQL | `libmariadb3` |
| SQLite | `libsqlite3-0` |
| HTTPS, STARTTLS, the HTTP client over TLS | `libssl3` |

No PHP-FPM, no Redis, no supervisor, no Composer, no node at runtime.

## Behind a proxy

The usual shape: nginx or Caddy terminates TLS and forwards to the app on
localhost.

```pascal
Opts.TlsCertFile := '';     { the app speaks HTTP }
```

Then set `Sessions.Secure := True` so the session cookie is marked `Secure`
even though the app itself did not do the TLS.

## TLS in the app

```
ASKR_TLS_CERT=/etc/ssl/shop/fullchain.pem
ASKR_TLS_KEY=/etc/ssl/shop/privkey.pem
```

One server, one protocol: there is no second port and no redirect. If you
want both, run two servers. See [TLS](tls.md).

## Tuning

```pascal
Opts.Workers := 0;                  { one per core }
Opts.MaxBodyBytes := 8 * 1024 * 1024;
Opts.KeepAliveTimeoutMs := 5000;
Opts.RequestTimeoutMs := 30000;
Opts.MaxRequestsPerConnection := 0; { unlimited }
Opts.ReadBufferSize := 16 * 1024;
Opts.ArenaBlockSize := 64 * 1024;
Opts.LogRequests := True;
```

`ArenaBlockSize` is the one worth thinking about. A worker reserves one
block and reuses it; if your requests routinely need more, it grows once and
stays there. Watch `BytesReserved` and `HighWaterMark`.

The read buffer shrinks back after a large request, but **only when nothing
is left in it** — a pipelined request arriving right after a big body must
not be discarded.

## Building on a clean machine

A build host has no `~/.askr/pkg` the first time, so the framework has
to be fetched before anything compiles:

```sh
askr install
(cd frontend && npm install)
askr build
```

`askr install` reads `askr.lock`, so the build is the version that file
names and not whatever is newest. Point `ASKR_CACHE` at a cached
directory and CI stops refetching on every run:

```sh
export ASKR_CACHE=/cache/askr
```

(`ASKR_HOME` is a different thing — it names a framework checkout, which
a deploy host does not have.)

It needs `git` and network for a version it has never seen, and neither
afterwards. See [Versions](versions.md).

## Migrations on deploy

```sh
askr build
askr migrate
```

A framework upgrade can add columns to the tables Askr owns, so a deploy
that moves the version runs migrations like any other.

`askr migrate:status` before and after is the cheap check.
`askr db:wipe` refuses to run with `APP_ENV=production` unless you pass
`--force`.

## Logging

```
APP_ENV=production
LOG_LEVEL=info
```

JSON lines by default in production, so a collector can read them. See
[Logging](logging.md).

## Maintenance mode

```sh
askr down     # 503 with Retry-After, immediately, without a restart
askr up
```

## Processes

The queue, the scheduler and the cache run **in the app process**. That is
the point — no sidecars. If you want to scale them separately, the same
binary does it:

```sh
./app --queue:work
```

The cache and the in-process queue are **per process**. Several app
processes behind a load balancer each have their own. For the queue, use the
[durable store](queue.md); for sessions, note that there is no shared store
and you need sticky sessions. Both are real limits, written down rather than
discovered.

## Health

```sh
askr about
```

Environment, config files, database driver, route count, queue and schedule
status. A route of your own that returns 200 and touches the database is
still worth having.

## Cross-compiling

Not solved. Build on the platform you deploy to, or in a container that
matches it — `tools/Dockerfile.fpc` is what the framework itself uses.
