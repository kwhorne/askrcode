# Sessions

```pascal
uses Askr.Session, Askr.Session.Db;

SetSessions(SessionsFromConfig(DbPool));
UseSessions(R);
```

That is what `askr new` writes. `SessionsFromConfig` reads two keys:

```toml
[session]
driver = "memory"      # or "database"
lifetime = 7200        # seconds
```

or `SESSION_DRIVER` and `SESSION_LIFETIME` in the environment. Memory is
the default. See [Where sessions are kept](#where-sessions-are-kept) for
when to choose the database.

`UseSessions` registers a middleware that starts the session before your
handler and a response filter that writes it back after. Before that
existed, every app had to call `Start`, `UseSession` and `Commit` by hand
around each request — and forgetting `Commit` meant nothing was saved, with
no error anywhere.

## Using it

```pascal
S := CurrentSession;

S.Put('cart', '3');
S.Get('cart');                 { '' if absent }
S.Get('cart', '0');            { with a default }
S.Has('cart');
S.Forget('cart');
S.Clear;
```

`CurrentSession` is the ambient session for this thread, set by the
middleware.

## Flash

Readable in the **next** request, then gone.

```pascal
S.Flash('notice', 'Saved.');
```

```pascal
S.GetFlash('notice');
S.HasFlash('notice');
S.Reflash;                     { keep what came in for one more request }
```

> The flash is **two maps**: what can be read now, and what is being written
> for the next request. One map gives either a flash that never disappears
> or one that cannot be read.

Validation errors ride on the same mechanism:

```pascal
S.FlashErrorsJson(Json);
S.ErrorsJson;
S.HasErrors;
```

## What a session costs

**A new session nobody wrote to is not stored and gets no cookie.** Without
that, every anonymous visitor — every bot, every health check — would get a
slot in the store and a cookie to send back: memory growing with traffic
rather than with users, or with the database driver, a row per robot.

`Sessions.Commit` called directly still does what it is told. Only the
automatic path is reticent.

## The cookie

```pascal
Sessions.CookieName := 'shop_session';
Sessions.Secure := True;        { set this behind HTTPS }
Sessions.Lifetime := 86400;
```

`HttpOnly` and `SameSite=Lax` are always set. The id is 128 random bits from
the kernel's CSPRNG, hex-encoded — a session id that can be guessed is not a
session id.

## Session fixation

```pascal
Sessions.Regenerate(S);
```

**Call this whenever privileges change.** Otherwise an attacker sets your
cookie to an id they know *before* you log in, you log into exactly that
session, and they are logged in as you.

[`Login`](auth.md) does it for you. If you build your own login, it is one
line, and there is a test that fails if it is removed.

## Where sessions are kept

The store handles the cookie, the id, the flash rotation and fixation. Where
the data lives is a **backend** under it, and there are two:

| driver | backend | survives a restart | shared between processes |
|---|---|---|---|
| `memory` | `TMemorySessions` | no | no |
| `database` | `TDbSessions` | yes | yes |

**Memory** is right for one process. It costs nothing and needs nothing,
but a restart signs everybody out, and with two processes behind a load
balancer a login on one is a stranger on the other unless the balancer is
sticky.

**Database** keeps them in the database the app already has, in a table
called `askr_sessions`. Any process can answer any request, and a deploy
keeps people signed in. No Redis, for the same reason the
[durable queue](queue.md) has none.

```sh
SESSION_DRIVER=database
```

What to know about it:

* **The id is not stored; its SHA-256 is.** The id is what proves who a
  request is, so a table of ids is a table of logins — one backup, read
  replica or SQL injection away from someone else. The hash still finds
  the row, and nothing in the table can be sent back as a cookie.
* **The table is made on first use, not at startup.** An app has to start
  whether or not the database is up. Put it in a migration yourself if you
  would rather control when it appears; the store checks before it
  creates anything.
* **It uses the request's own connection.** Built with
  `TDbSessions.Create(Pool)` on the app's pool, the store reads and writes
  through the connection `LeaseDb` already took. Taking a second one from
  the same pool would deadlock the moment every worker held one and wanted
  another. `TDbSessions.Create(Dsn)` gives it a pool of its own instead,
  for sessions in a different database.
* **Expired rows are swept** on roughly one request in 64, with a single
  `DELETE`. An expired row is never read as a session in between — the
  expiry is checked on every load, not left to the sweep.
* **`Regenerate` deletes the old row.** With several processes, fixation
  protection only holds if the old id stops working everywhere at once.

`SessionsFromConfig` refuses rather than guesses. `database` without a
`DATABASE_URL` raises at startup, and so does a driver it does not know —
falling back to memory would look like working until the second process.

A backend of your own is a class with five methods — `Load`, `Save`,
`Delete`, `Count` and `Sweep` — passed to `TSessionStore.Create(Backend)`.
The store owns it from then on.

```pascal
Sessions.Count;
Sessions.Created;  Sessions.Resumed;  Sessions.Expired;
Sessions.Destroy_(Id);
```

### What there is not

There is no Redis or Memcached backend. The database is already there and
already backed up; a second service for sessions would be the first thing
in Askr that needed one.

## Doing it by hand

If you are not using the router — a desktop shell, a custom host:

```pascal
S := Sessions.Start(Req);
UseSession(S);
try
  Res := Handle(Req);
  Sessions.Commit(S, Res);
finally
  UseSession(nil);
end;
```

`UseSession(nil)` at the end matters. The session lives in the request arena
and disappears on `Reset`, but the threadvar does not — left set, the next
request on that worker sees a pointer into reused memory.
