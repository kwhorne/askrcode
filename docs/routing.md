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

`AsName` names the route registered last. `askr routes` lists them, and
[verified routes](#verified-routes) name their functions after them.

## Verified routes

A link to a route that is gone is a 404 somebody finds in production. With
verified routes it is a compile error at the line that has the link.

```sh
askr routes:gen      # writes app/App.Routes.pas
askr routes:check    # exits 1 when it no longer matches the routes
```

`App.Routes` has one function per path:

```pascal
uses App.Routes;

Result := InertiaRedirect(GadgetsIdEditPath(M.Id));   { /gadgets/7/edit }
Result := Redirect(DocsShowPath('routing'));           { /docs/routing }
```

Remove the route from `app.lpr` and run `askr routes:gen` again, and the
function goes with it. Every place that used it then fails to build:

```
App.Http.Gadgets.pas(88,31) Error: Identifier not found "GadgetsIdEditPath"
```

The idea is Phoenix's verified routes, done by the Pascal compiler.

- **The function is named after the route's name** when it has one:
  `R.AsName('docs.show')` gives `DocsShowPath`. Otherwise it is named
  after the pattern: `/gadgets/:id/edit` gives `GadgetsIdEditPath`, and
  `/` gives `RootPath`. When two patterns would share a name, the one that
  sorts later gets a number.
- **There is one function per path, not per route.** `GET` and `PATCH` on
  `/gadgets/:id` are the same path.
- **A parameter is a string.** A parameter called `id`, or ending in
  `_id`, also has an `Int64` overload, so `M.Id` goes straight in.
- **Values are percent-encoded**, and the router decodes them back to the
  same parameter. A slash in a parameter is refused, because the path is
  decoded before it is split and the link would reach another route. A
  wildcard (`*path`) keeps its slashes.
- **The file depends on the routes and nothing else**, so generating it
  twice gives the same bytes. Commit it, and run `askr routes:check` in CI:
  a route changed without generating again is what it catches.

`FillRoute('/gadgets/:id/edit', ['7'])` is what the functions call, and it
can be called directly. It checks the number of values and encodes them,
but a pattern written by hand is not checked against anything.

The routes are compiled into the app, so `routes:gen` and `routes:check`
are commands of the app binary. Build before running them.

## 404 and 405

A path that matches no route gives **404**. A path that matches but with the
wrong method gives **405** — the router checks for that case explicitly,
because "the URL is wrong" and "the verb is wrong" are different problems.

```pascal
R.SetNotFound(Errors.NotFound);
```

## Middleware

Middleware runs before the handler. Return `nil` to let the request
through, or a response to short-circuit it.

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

**Middleware runs in the order you registered it**, whether each one is a
method or a plain procedure. That sounds too obvious to state, and it is
stated because it was not true until recently: the router kept one list
per kind and ran every method before every procedure, so the order came
from how a piece of middleware happened to be written rather than from
where it was written. A database lease registered as a procedure ran
*after* an authentication step registered as a class method, and every
request that needed both was a 500.

Middleware on the router covers every request. For middleware that only
some routes need, use a group.

## Groups

A group is a prefix, the middleware its routes need beyond the router's,
and what they do without:

```pascal
var
  Admin, Hooks: TRouteGroup;
begin
  Admin := R.Group('/admin');
  Admin.Use(@RequireAdmin);
  Admin.Get('/', Dashboard.Show);          { /admin }
  Admin.Get('/users', Users.Index);        { /admin/users }

  Hooks := R.Group('/hooks').WithoutCsrf.WithoutRateLimit;
  Hooks.Post('/stripe', Billing.Webhook);  { /hooks/stripe }
end;
```

A group is an object, not a block: anonymous procedures do not exist in
Free Pascal 3.2.2, which Askr builds on. The router owns its groups and
frees them.

**The order is the router's middleware, then the group's**, from the
outermost group in, then the handler. A group inside a group has both
prefixes and both sets of middleware, and does without everything its
parent does without:

```pascal
Reports := Admin.Group('/reports');
Reports.Use(@RequireAccountant);
Reports.Get('/:year', Reports_.Show);      { /admin/reports/:year }
```

**The route is found before any middleware runs**, so middleware can read
the route's parameters -- `Req.Param('year')` above -- and ask about it:
`MatchedRoute` is the route this request matched, and
`RouteExcludes(What)` says whether its group does without something.

| | |
|---|---|
| `R.Group(Prefix)` | A group under Prefix; `''` for none. Starts with `/`, and has no wildcard |
| `G.Group(Prefix)` | A group inside G |
| `G.Use(M)` | Middleware for G's routes, after the router's |
| `G.WithoutCsrf` | The CSRF check does not run for G's routes |
| `G.WithoutRateLimit` | The router's rate limit does not count them; a group can have its own |
| `G.Get`, `G.Post`, ... | Routes under G's prefix |

A route in a group is a route like any other: the same specificity
ordering, the same `AsName` after it, and the same refusal when its full
path is already taken.

## sitemap.xml

```pascal
uses Askr.Http.Sitemap;

procedure AppSitemap(S: TSitemap);
begin
  S.Add('/');
  S.Add('/about', LastEdited);
  for P in Pages do
    S.Add('/docs/' + P.Slug, P.UpdatedAt);
end;

UseSitemap(R, @AppSitemap);   { after the static files }
```

**Askr knows the routes; it does not know which of them are public.** It
cannot turn `/docs/:slug` into the pages that exist either — that answer is
in a database, or a directory, or a decision. A sitemap generated from the
route table would be a list of patterns rather than pages, with every admin
route in it. So the application declares and the framework generates.

The source runs **per request**, so pages in a database are listed as they
are now.

Paths go in; absolute URLs come out, against `app.url`. A sitemap of
relative URLs is rejected by crawlers, and the only other source of an
origin is the request — which is [the one place it must never come
from](configuration.md#appurl-and-why-it-is-not-the-request). Without
`app.url` the handler raises rather than emitting a document nobody can
use, and the log line names the key.

`lastmod` is optional and is left out when you do not pass one. A `lastmod`
that is really "now" on every build tells a crawler nothing except that you
do not know, and it learns to ignore the field.

### The limits are not advice

A sitemap holds at most **50 000 URLs and 50 MB**. Over either, it is not a
large sitemap — it is a rejected one, and a crawler that rejects it reads
none of it. Askr splits the entries into parts and serves an index at
`/sitemap.xml` pointing at `/sitemap/1`, `/sitemap/2` and so on, which is
what the protocol says to do.

The part URLs have no `.xml` on them because a route parameter in Askr is a
whole segment. It makes no difference to a crawler, which follows the
absolute URLs the index gives it.

### Escaping

A `&` in a URL is the ordinary case — one query parameter is enough — and
an unescaped one makes the **whole document** malformed, not just that
entry. Entries are escaped for you. The test parses the output with a real
XML parser rather than matching it against a pattern, for the same reason
the markdown renderer is measured through the browser's own parser: a
regular expression is what one imagines XML to be.

## robots.txt

```pascal
uses Askr.Http.Robots;

UseRobots(R);     { after the static files }
```

**The default follows `APP_ENV`, and only production is open.** Anything
else answers `Disallow: /`, including a server with no configuration at
all — `AppEnv` is `local` when nothing is set.

That asymmetry is the point. A missing robots.txt does not mean "do not
index"; it means "index everything", because that is what a crawler
assumes when it asks and gets a 404. The dangerous state is not a wrong
file, it is no file on a staging site nobody thought about, and the first
sign of it is the unreleased pages in somebody's search results.

In production it allows everything and adds a `Sitemap:` line — but only
when `app.url` is set, since `Sitemap` takes an absolute URL and there is
nowhere truthful to get one from otherwise. The non-production body names
the environment, because the question this file gets asked is "why is my
site not being indexed" and the answer is nearly always that the
environment is not what somebody thought.

`askr new` registers it after the static files, so your own
`public/robots.txt` is found first and wins.

### What it does not decide

**It names no crawler.** Whether GPTBot, ClaudeBot or PerplexityBot may
read a site is a decision about that site. A framework that shipped an
opinion in the default would be making it for every application built on
it, silently, in a file most people never open. Write
`public/robots.txt` when you have decided.

**None of it is enforcement.** robots.txt is a request that well-behaved
crawlers honour; it keeps nothing private and stops nobody. A page that
must not be read needs a guard, not a line in a text file.

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

**And they run when the handler raised.** An exception that says which
status it is below 500 — `EForbidden` from a gate or `AuthorizeScope`,
your own `EHttpError` — is answered by the router, and the filters run on
that answer. Anything else runs the filters with a 500 in hand and is
raised again, so the server logs it as a fault. Until 0.13 they did not
run at all when a handler raised: `ReleaseDb` is an after-filter, so every
refusal and every 500 kept its pooled connection, until the pool had none
left to give.

## The standard stack

A project from `askr new` wires this, in this order:

```pascal
UseCors(R);             { first: a preflight carries no credentials }
R.Use(Statisk.Serve);   { static files: no session, no CSRF, short-circuits }
UseMaintenance(R);      { askr down / askr up }

SetSessions(TSessionStore.Create);
UseSessions(R);         { Start before, Commit after }
UseTokenAuth(R);        { Authorization: Bearer — before UseCsrf }
RateLimit.PerMinute(600).KeyBy(@TokenRateKey);
UseRateLimit(R);        { after the token, so the bucket can be named }
UseCsrf(R);             { rejects unsafe methods without a token }
UseAuth(R);             { restores login from the "remember me" cookie }
```

**The order is not optional.** The CSRF token lives in the session, and
"remember me" writes to it. Static files are registered first so they never
pay for any of it. `UseTokenAuth` comes before `UseCsrf` because a request
that authenticated with a header it carried itself is exempt from CSRF,
and that is only visible once the token has been read — see
[API tokens](tokens.md).

The database lease, when there is one, is registered before all of these:
a middleware that reads the database needs the connection already
leased.

`UseCors` is first because a preflight carries no credentials — the
browser strips them — so anything that refuses a request without one
would refuse every preflight, and the real request would never be sent.
It is also not a request the caller made, so it does not spend their rate
limit. `UseRateLimit` is after `UseTokenAuth` for the opposite reason: it
needs the token to have been read to key the bucket on it. See
[CORS](cors.md) and [Rate limiting](rate-limiting.md).

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
