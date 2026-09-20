# Routing

```pascal
uses Askr.Http.Router;

R := TRouter.Create;
R.Get('/', Home.Index);
R.Get('/customers', Customers.Index);
R.Get('/customers/new', Customers.New_);
R.Get('/customers/:id', Customers.Show);
R.Post('/customers', Customers.Store);
R.Put('/customers/:id', Customers.Update);
R.Delete('/customers/:id', Customers.Destroy_);

Server.SetHandler(R.Handle);
```

`Get`, `Post`, `Put`, `Patch`, `Delete` and `Any` each take a pattern and a
handler. A handler is:

```pascal
TRouteHandler = function(Req: TRequest): TResponse of object;   { a method }
TRouteHandlerProc = function(Req: TRequest): TResponse;         { free-standing }
```

Both forms exist because a controller method and a plain function are both
reasonable, and Pascal distinguishes them at the type level.

> The dispatch method is `Handle`, not `Dispatch` — `Dispatch` would shadow
> `TObject.Dispatch`.

## Parameters

`:name` captures a segment, `*rest` captures everything remaining.

```pascal
R.Get('/customers/:id/orders/:order', Orders.Show);
R.Get('/files/*path', Files.Serve);
```

```pascal
Id := Req.IntParam('id');        { 0 if absent or not a number }
Path := Req.Param('path');       { TStr }
```

## Specificity, not registration order

Routes are sorted by **specificity**, not by the order you wrote them. A
static segment beats a parameter, which beats a wildcard. So this works
regardless of order:

```pascal
R.Get('/customers/:id', Customers.Show);
R.Get('/customers/new', Customers.New_);   { still wins for /customers/new }
```

If you change `CompareRoutes`, check that `/customers/new` still beats
`/customers/:id`.

## Named routes

```pascal
R.Get('/customers/:id', Customers.Show);
R.AsName('customers.show');
```

`AsName` names the route registered last. `askr routes` lists them.

## 404 and 405

A path that matches no route gives **404**. A path that matches but with the
wrong method gives **405** — the router checks for that case explicitly,
because "the URL is wrong" and "the verb is wrong" are different problems.

```pascal
R.SetNotFound(Errors.NotFound);
```

## Middleware

Middleware runs before routing. Return `nil` to let the request through, or
a response to short-circuit it.

```pascal
function RequireJson(Req: TRequest): TResponse;
begin
  if Req.IsJson then
    Result := nil
  else
    Result := RespondText('Expected JSON', 415);
end;

R.Use(@RequireJson);
```

`askr make middleware <Name>` writes the skeleton.

Middleware is **global** today. Per-route and per-group middleware is a real
gap, listed in `LARAVEL.md`, and not yet built.

## Response filters

Middleware alone is not enough. The session must be written back and the
cookie set **after** the handler has run, and there is nowhere to hang that
when the only hook is "before".

```pascal
TResponseFilter = function(Req: TRequest; Res: TResponse): TResponse of object;

R.After(@AddSecurityHeaders);
```

Filters run in **reverse** registration order, so a `Use`/`After` pair
brackets as you would expect:

```
Use(A); After(A'); Use(B); After(B')
  ->  A, B, handler, B', A'
```

They also run when middleware short-circuited the request. Otherwise a 401
from a guard would lose its session cookie.

## The standard stack

A project from `askr new` wires this, in this order:

```pascal
R.Use(Statisk.Serve);   { static files: no session, no CSRF, short-circuits }
UseMaintenance(R);      { askr down / askr up }

SetSessions(TSessionStore.Create);
UseSessions(R);         { Start before, Commit after }
UseCsrf(R);             { rejects unsafe methods without a token }
UseAuth(R);             { restores login from the "remember me" cookie }
```

**The order is not optional.** The CSRF token lives in the session, and
"remember me" writes to it. Static files are registered first so they never
pay for any of it.

`UseSessions`, `UseCsrf` and `UseAuth` are plain procedures, not class
helpers — Pascal allows only one active class helper per type in scope, and
`Req.FillInto` already uses that slot on `TRequest`.

## Inspecting

```sh
askr routes
```

```pascal
R.Describe(Lines);   { one line per route, sorted }
R.Count;
```

## Testing without a socket

```pascal
uses Askr.Testing;

K := TTestClient.Create(R);
Res := K.Get('/customers/7');
AssertEqual(Res.StatusCode, 200, 'found');
```

`TTestClient` drives the router directly — no port, no socket, no waiting.
See [Testing](testing.md).
