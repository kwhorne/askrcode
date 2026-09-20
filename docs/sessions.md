# Sessions

```pascal
uses Askr.Session;

SetSessions(TSessionStore.Create);    { 7200 s lifetime by default }
UseSessions(R);
```

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
slot in the store and a cookie to send back. The store lives in the process,
so that is memory growing with traffic rather than with users.

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

## The store

In-process, swept periodically for expired entries.

```pascal
Sessions.Count;
Sessions.Created;  Sessions.Resumed;  Sessions.Expired;
Sessions.Destroy_(Id);
```

There is **no database-backed session store**. One process means one store;
several processes behind a load balancer would need sticky sessions or a
shared store, and the second of those is not built. That is a real limit and
it is written down rather than discovered.

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
