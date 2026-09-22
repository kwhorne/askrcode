# APIs

Askr serves pages and it serves programs. The difference is not two sets
of routes — it is one route that can tell who is asking.

```pascal
function TCustomerCtl.Store(Req: TRequest): TResponse;
var
  C: TCustomer;
begin
  C := Req.Arena.New<TCustomer>;
  Req.FillInto(C);
  if not C.Validate then
    Exit(BackWithErrors(C.Errors));   { 302 + flash, or 422 + JSON }
  C.Save;
  Result := Redirect('/customers/' + IntToStr(C.Id), 303);
end;
```

A browser posting that form is redirected and reads the errors off the
page it lands on. A program posting the same body gets `422` with the
errors in the body. The handler does not ask which one it is talking to,
because a handler that has to ask will eventually forget.

## Who asked for JSON

```pascal
function TRequest.AcceptsJson: Boolean;
```

True when the `Accept` header names `application/json` before it names
`text/html`. That ordering is the whole rule:

| `Accept` | `AcceptsJson` |
|---|---|
| `application/json, text/plain, */*` | yes — this is what axios sends |
| `application/json` | yes |
| `text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8` | no — a browser |
| `text/html, application/json` | no — a page was asked for first |
| *(no `Accept` at all)* | no |

No `Accept` means no preference, and a page is the safer thing to hand
somebody who did not say. Quality values would be the thorough reading;
order is what clients actually express, and the thorough reading has more
places to be wrong.

**An Inertia request is not a JSON request.** It carries `X-Inertia` and
gets its own payload, and answering it with an API error would hand its
client something it has no idea what to do with. `AcceptsJson` is false
for it whatever the `Accept` header says.

## What an error looks like

Errors are [RFC 9457](https://www.rfc-editor.org/rfc/rfc9457) problem
documents:

```json
{
  "type": "about:blank",
  "title": "Unprocessable Content",
  "status": 422,
  "detail": "The request body did not validate.",
  "errors": {
    "email": "email is not a valid email address",
    "display_name": "display_name is required"
  }
}
```

The content type is `application/problem+json`, not `application/json`.
That is what tells a client the body is the error rather than the thing it
asked for; a `422` with `application/json` looks exactly like a successful
payload to anything that switches on the content type alone.

`type` stays `about:blank` until an application has a page to point at,
which is what the RFC says that value means. `errors` is an extension
member, which the RFC allows.

### Building one

```pascal
function Problem(AStatus: Integer; const Detail: string = ''): TResponse;
```

```pascal
Exit(Problem(409, 'That order has already shipped.'));
```

For a document with extension members of your own, the two halves are
exposed separately:

```pascal
procedure BeginProblem(var W: TJsonWriter; AStatus: Integer;
  const Detail: string = '');
function ProblemFrom(var W: TJsonWriter; AStatus: Integer): TResponse;
```

```pascal
W.Init(Req.Arena, 256);
BeginProblem(W, 429, 'Slow down.');
W.Field('retry_after', Int64(30));
Result := ProblemFrom(W, 429);
```

### From a validation

```pascal
function ValidationProblem(E: TErrors;
  const Detail: string = 'The request body did not validate.'): TResponse;
```

In `Askr.Urd.Bind`, for the same reason `FillInto` is: the HTTP layer must
not know about Urd, and `TErrors` is a Urd type.

`BackWithErrors` calls it for you when the client asked for JSON, so most
code never names it. Reach for it directly in a handler that only ever
serves an API and has no session to flash into.

**The fields are keyed on the column name**, because `TErrors` is. Rules
are written with the property name — `V.Field('DisplayName')` — and the
error comes back as `display_name`. See [Validation](validation.md).

## Who is calling

A session is a browser mechanism: a cookie, a CSRF token beside it, and
something at the other end that stores cookies and follows redirects. A
program has none of that. It gets a bearer token instead.

```
Authorization: Bearer askr_kZ3n9QwR...
```

```pascal
UseSessions(R);
UseTokenAuth(R);   { before UseCsrf — see below }
UseCsrf(R);
UseAuth(R);
```

That is the whole setup. `askr new` writes it. From there `Check`, `Id`,
`User` and every gate answer for a token caller exactly as they do for a
browser, so an application does not write its authorisation twice.

### Minting one

```sh
askr token:issue 7 "ci deploy" --scopes=orders:read,orders:write
askr token:issue 7 "read only" --scopes=orders:read --days=90
askr token:issue 7 "everything" --scopes='*'
```

```
  askr_kZ3n9QwRt7xLm2pVc4hJdF8sYbN1aG6uE0iO3rT5w

This is the only time the token is shown. Only its SHA-256 is
stored, so there is no way to print it again.
```

`--scopes` is required and has no default. The one command that mints a
credential should make you say what it may do; a default of "everything"
would be the wrong answer most of the time and silent every time.

The `api_tokens` table is created by the first `token:issue`, not at
startup — an application has to start whether or not its database is up.

```sh
askr token:list 7
askr token:revoke 4
askr token:revoke --user=7     # everything that user has
```

### From code

```pascal
function IssueToken(Db: TDbConnection; const UserId, Name_: string;
  const Scopes: array of string; ExpiresInSeconds: Int64 = 0): string;
function FindToken(Db: TDbConnection; const Plain: string;
  out T: TApiToken): Boolean;
procedure RevokeToken(Db: TDbConnection; TokenId: Int64);
function RevokeTokensFor(Db: TDbConnection; const UserId: string): Integer;
function TokensFor(Db: TDbConnection; const UserId: string): TApiTokens;
procedure EnsureTokenSchema(Db: TDbConnection);
```

The user id is the application's own, as text — the same one `Login`
takes. The framework does not own your user model and does not own this
either; it stores an id and nothing else about a person.

### Scopes

```pascal
function TokenAllows(const Scope: string): Boolean;
procedure AuthorizeScope(const Scope: string);   { raises EForbidden → 403 }
```

```pascal
function TOrderCtl.Store(Req: TRequest): TResponse;
begin
  AuthorizeScope('orders:write');
  ...
end;
```

Scopes are exact strings. `*` is the only wildcard and means everything.
`orders:*` is deliberately **not** supported: it reads as an obvious
extension and then raises a question with no obvious answer — whether the
star crosses a colon — at the exact moment somebody is deciding what an
admin token may do. A token can list as many exact scopes as it likes,
which is the same reach without the ambiguity.

Three answers, and the middle one is worth reading twice:

| | |
|---|---|
| Nobody signed in | no |
| Signed in by session | **yes** |
| Signed in by token | the token's scopes decide |

A session is not scoped, so asking a browser session about a scope is
asking a question that has no answer. A handler that must also keep
browsers out needs `RequireAuth` or a gate — that is where that decision
belongs.

A token issued with no scopes allows nothing. Somebody will write
`IssueToken(..., [])` meaning "everything"; this is what they get.

### What is stored

The token itself is never stored. The row holds `sha256(token)` as hex,
and the plaintext is returned once and never again.

**The hash is a bare SHA-256, no salt and no key, and that is a
decision.** A salt defends a low-entropy secret against a precomputed
table. This secret is 32 bytes from the system CSPRNG — there is no table
to precompute and no dictionary to try — so a salt would buy nothing and
would cost the thing that matters: the lookup being one indexed equality
rather than a scan. An HMAC under `APP_KEY` was rejected for a different
reason: rotating `APP_KEY` is something operators are told they may do,
and it already signs everyone out. Making it silently kill every API
token as well widens that blast radius.

**There is no stored prefix column, and nothing keeps a fragment of a
live token.** The usual argument for a prefix is matching a token found
in a log or a public repository back to a row — but hashing the string
you found and looking it up does exactly that, with no part of any secret
kept. Telling two tokens apart in a list is what `name` is for.

`askr_` is on the front of every token so a secret scanner has something
to key on, and so a token in a paste is recognisable for what it is. It
is fixed framework-wide: a per-application prefix would mean no scanner
rule could cover Askr at all.

### Never from the query string

There is no code that reads a token from a URL, and there is a test that
says so. A query string goes into access logs, into `Referer` on every
outbound link, into browser history, and into whatever somebody pastes
into a chat. Each of those is a place a credential is then kept by
somebody who never agreed to keep it.

There is also one header, not several. No `X-Api-Key`, no `?api_key=`.

### Why it comes before UseCsrf

A request that authenticated with a credential it carried itself is not
what CSRF defends against. The whole attack is a browser being made to
send a request it did not mean to, with the cookie it carries everywhere;
an `Authorization` header is not carried everywhere, and no other site can
set one on a request to your server. Requiring a CSRF token as well would
ask an API client for something it has no way to obtain, and every POST
with a valid token would be a 419.

`UseCsrf` exempts a request whose identity came from a header. That is
only visible once the token has been read, which is why `UseTokenAuth`
has to be registered first.

### What a refused token gets

| | |
|---|---|
| No token at all | the request continues as anonymous |
| A token that is unknown, revoked or expired | `401`, and the request stops |

A credential that is offered and does not work is an error in itself.
Treating it as an anonymous request would surface the failure later,
somewhere else, as a 403 or a 404.

The 401 carries `WWW-Authenticate: Bearer error="invalid_token"`, as
RFC 6750 says a bearer scheme should. **The body never says which of the
three it was** — that a token is *revoked* rather than unknown tells the
caller it was real. The server logs the reason, and only for a token that
is actually in the table: a token that is not tells nobody anything, and
logging it would let anyone fill the log by sending words.

### Expiry and last use

`--days=N` sets an expiry; without one a token does not expire.
`last_used_at` is written at most once a minute per token, by one
conditional `UPDATE`, so an authenticated request is not also a write.
Times are unix milliseconds, not `TIMESTAMP`, for the same reason the
durable queue uses them: several processes share the table and an integer
means the same thing whatever time zone each server believes it is in.

Revoking marks the row rather than deleting it. "This token was revoked
on Tuesday" and "this token never existed" are different answers to the
only question anybody asks afterwards, and a deleted row can give only
the second.

## Returning a list

A list endpoint answers with three things: the rows, where in the set
they came from, and how to ask for the next lot.

```pascal
function TCustomerCtl.Index(Req: TRequest): TResponse;
var
  G: TGrid<TCustomer>;
begin
  G := TGrid<TCustomer>.New;
  G.Read(Req)
   .Sortable('name', Customers.Name)
   .Sortable('balance', Customers.Balance)
   .Searchable([Customers.Name, Customers.Email])
   .DefaultSort('name')
   .PerPage(25, 200);

  Result := G.ListResponse(G.Rows(TQuery<TCustomer>.New));
end;
```

```json
{
  "data": [ { "id": 1, "name": "Ada", "balance": 500.0000 } ],
  "meta": {
    "page": 1, "per": 25, "total": 137, "pages": 6,
    "sort": "name", "dir": "asc", "q": ""
  },
  "links": {
    "prev": null,
    "next": "/customers?sort=name&status=open&page=2"
  }
}
```

`GET /customers?sort=balance&dir=desc&per=50&q=ada&page=2` is read by
`Read`. This is the same `TGrid` the [data grid](lauf.md) component uses
— sorting, searching and paging happen in the database either way, and
the only difference is how the result is written out. `WriteJson` gives
the component its prop; `ListResponse` gives an API caller the envelope
above, and `WriteListInto` writes it into a document of your own.

### data is an array

`data` is an array whatever happens: `[]` when nothing matched, never
`null` and never missing. A consumer of a list is going to iterate that
key, and `null` is the one value that turns an empty result into a
crash. "You did not ask for this" is said by leaving a key out, which is
already the rule for [a relation that was never loaded](inertia.md).

### total is counted, not guessed

`Rows` runs `SELECT count(*)` over the filtered set **before** it fetches
the page, with the search applied and the limit and offset ignored. Do it
the other way round and you count the rows on the page.

Building the payload without calling `Rows` raises rather than reporting
`"total": 0` for a list that has rows in it.

`pages` is at least 1, including for an empty result: a set with nothing
in it still has one page, and a client that loops `for p := 1 to pages`
should visit it.

### The links are relative, and keep your parameters

`links.next` is the whole query string this request came in with, with
only `page` replaced. A list usually carries more than sort and search —
`?status=open&assignee=me` is the application's — and a next link that
quietly dropped those would page through a different list than the caller
asked for.

They are relative on purpose. An absolute URL needs an origin, and the
only truthful source of one is `app.url` ([see why](../src/core/Askr.Core.Url.pas));
a list endpoint has no business requiring that to be configured, and the
caller just made the request, so it has the origin already.

`prev` and `next` are `null` at the ends, and both are `null` when the
grid was never given a request — there is no path to build one from, and
guessing at one would be worse than saying so.

## Who else may call this, from a browser

CORS is not a lock. It is a browser telling a page on one origin what it
may do with a reply from another, and nothing else honours it — curl
ignores it, so does a server, so does anything that is not a browser. A
route that must not be reached by some callers needs a guard, not a
header.

```pascal
Cors.AllowOrigin('https://app.example')
    .AllowMethods(['GET', 'POST', 'PATCH', 'DELETE'])
    .AllowHeaders(['Content-Type', 'Authorization'])
    .AllowCredentials;
UseCors(R);
```

`askr new` writes `UseCors(R)` and nothing else, so a new project allows
nothing until somebody names an origin. That is the same rule as
[robots.txt](routing.md#robotstxt) and as a gate that does not exist: the
state you land in without deciding anything has to be the narrow one,
because the dangerous configuration is the one nobody thought about.

### Origins match exactly

`https://app.example.evil.example` starts with `https://app.example`, so
a prefix test lets it in. `Askr.WebAuthn` was caught by a mutation test on
exactly this shape — every wrong origin in its fixtures started with
something else, so nothing measured the rule. There is no pattern
matching and no wildcard subdomain here: an origin is a string, and it is
either on the list or it is not.

A trailing slash is refused rather than quietly kept, because a browser
never sends one and an origin written that way would never match
anything.

### `*` and credentials cannot both be asked for

A browser refuses `Access-Control-Allow-Origin: *` together with
`Access-Control-Allow-Credentials: true`. A server that sends both has a
configuration that reads as "anyone, with cookies" and behaves as
"nobody" — the worst kind of wrong, because it looks generous and fails.
`AllowCredentials` after `AllowAnyOrigin` raises, and so does the other
order.

With credentials the allowed origin is echoed back rather than `*`, since
that is the only form a browser will take alongside them.

### Vary: Origin, on everything

The same URL answers differently depending on who asked, so every reply
says so — including the ones from an origin that was not allowed and
carry no CORS header at all. Without it a cache in front of the server
hands a page from one origin the headers meant for another, or hands a
browser a reply with no CORS headers and the page silently cannot read
it. The same mistake as `Vary: X-Inertia`, and it shows up the same way:
only behind a cache, and only sometimes.

The headers go on error replies too. A page that cannot read the 401 is a
page whose developer has no idea what went wrong.

### The preflight

`OPTIONS` carrying `Access-Control-Request-Method` is answered with 204
before routing. An `OPTIONS` without that header is an ordinary request
and belongs to the application.

A preflight from an origin that is not allowed is still a 204, with no
CORS headers — the browser stops there, which is the answer. Refusing
with a 403 would say the same thing less clearly and would tell a script
which origins are on the list.

It is registered **first**, before the static files and before anything
that authenticates: a preflight carries no credentials by design, so
anything refusing a request without one would refuse every preflight and
the real request would never be sent. It also does not spend anybody's
rate limit, because it is the browser's request and not the caller's.

## How often one caller may ask

```pascal
RateLimit.PerMinute(600).KeyBy(@TokenRateKey);
UseRateLimit(R);
```

A token bucket, not a fixed window. A window of a minute lets somebody
spend the whole allowance in its last second and the whole of the next in
the first second of the next — twice the limit across two seconds, which
is exactly the burst the limit was for. A bucket refills continuously and
has no seam to sit on.

`PerMinute(600)` is a bucket of 600 refilling at ten a second; `Burst(N)`
sets the two apart when a different shape is wanted. Over the limit is
`429` with `Retry-After`, which is never less than 1 — a `Retry-After` of
0 says "now", and a client that obeys it spins.

Every reply under the limit carries `X-RateLimit-Limit` and
`X-RateLimit-Remaining`, so a client can slow down before it is refused
rather than after.

### What it is keyed on

`TokenRateKey` is the token when the request came in with one, and the
caller's address otherwise — a limit per credential rather than per
office. It is keyed on the token's **id**: the id is a number in a table,
the text is a credential, and a limiter has no business holding the
second in a process-wide table for the life of the process.

It has to be registered after `UseTokenAuth`, or there is no token to see
yet.

Static files that exist short-circuit before the limiter, so a page with
thirty assets does not spend thirty tokens.

### `X-Forwarded-For` is not read

It is a header the client writes. Trusting it without knowing exactly how
many proxies sit in front of you means anybody can put a new value in it
on every request and have an unlimited quota — **a rate limiter you can
opt out of is worse than none, because it is believed.** Behind a proxy,
have the proxy set the address it saw, or key on something the caller
cannot choose, such as a token.

### Memory does not grow with traffic

The table is a fixed number of slots. A new key lands in one of a few
decided by its hash, and when they are all taken one of them is taken
over — the least constrained, since whoever has the most left is least in
need of it.

**Taking a slot over never hands out a fresh allowance.** The new key
inherits whatever was in the bucket. The first version reset it to full,
and that is a way round the whole limiter: the hash is a pure function of
the key, so anybody can work out eight keys that collide with their own,
spend them, and have their own bucket dropped and refilled. Inheriting
instead means the worst a collision can do is limit somebody early, which
is the safe direction.

The counters live in the process. Two Askr processes behind a load
balancer each enforce the limit separately, so the effective limit is the
number times the processes. A shared counter needs somewhere shared to
put it, and that is a different piece with a different failure mode —
what happens to every request when the store is down.

## A document, from what is already true

There was no OpenAPI document here for a long time, and the reason was
written on this page: Askr knows its routes but not which of them are
public, what they accept or what they return, and a document generated
from the route table alone would be a confident description of the wrong
thing.

That reason still holds. What changed is the division of labour, and it
is the same one as the [sitemap](routing.md#sitemapxml): **the
application declares, the framework generates.**

```pascal
procedure AppApiDoc(D: TOpenApi);
begin
  D.Title('Shop').Version('1.0').Covers('/api');

  D.Get('/api/customers').Summary('Every customer')
   .ReturnsList(TCustomer).Secured('customers:read');
  D.Get('/api/customers/:id').Summary('One customer')
   .Returns(TCustomer).Secured('customers:read');
  D.Post('/api/customers').Summary('Add one')
   .Body(TCustomer).Returns(TCustomer, 201).Secured('customers:write');
end;

UseOpenApi(R, @AppApiDoc);
```

`GET /openapi.json` serves it. `askr openapi` prints it. Every line above
says something the framework cannot know; everything else comes from what
it does know, and cannot drift from it.

### The schemas come from the models

Not from a copy of them. `TModelMeta` is the same metadata `WriteModel`
serialises from, so:

- a column renamed in the model is renamed in the document;
- a column hidden with [`HideFromJson`](models.md) is not in the document
  either — otherwise the document would be a list of column names to go
  looking for;
- the request schema leaves out a generated primary key, because a
  request never fills one.

There is no `required` list on a request body. Which fields an
application insists on lives in `TModel.Rules`, and that is code that
runs rather than a declaration that can be read. Guessing at it is the
one thing this is built not to do.

**A `TDateTime` is not declared as `format: date-time`.** `DateTimeToSql`
writes `2026-09-22 13:00:00` — a space instead of a `T`, and no zone —
which is not RFC 3339. A generated client told otherwise would build a
date parser that fails on every row. The document says `string` and
describes the shape in words, which is true.

### The rest is read off what is running

| In the document | Because |
|---|---|
| `/api/customers/{id}` | the route is `/api/customers/:id` |
| the type of `{id}` | the model has a column by that name |
| `page`, `per`, `sort`, `dir`, `q` | `ReturnsList` means `TGrid.Read` reads them |
| `401`, and `403` with a scope | the operation is `Secured` |
| `404` | the path has a parameter |
| `422` | the operation takes a body |
| `429` | the rate limiter is configured |

All of the errors are `application/problem+json`, because that is what
Askr answers with.

### The drift gate is the point

A declaration that can disagree with the code is a worse lie than no
declaration, because it is believed. So the check runs **both ways**:

```sh
askr openapi --check
```

- every path described has to be a route that exists;
- every route under a `Covers` prefix has to be described.

One direction alone lets the other half rot — the same argument as the
`AGENTS.md` check, which had to be made both ways for the same reason. A
document that calls no paths its own is itself reported: half a check
that looks like a whole one.

It exits non-zero on drift, so it belongs in CI. `askr mcp`'s `openapi`
tool serves the same two answers to an agent.

### It is validated by something that is not us

`./askr api:check` runs the document through a real OpenAPI validator
against the published meta-schema, and resolves every `$ref`. The Pascal
suite checks that the fields Askr meant to write are where it meant to
put them — which is a check against its author's understanding of
OpenAPI. The validator is the check against OpenAPI. The gate also
confirms the validator refuses a document with its version taken out, so
"valid" means something.

[`examples/api/apidemo.lpr`](../examples/api/apidemo.lpr) is the app that
gate drives: tokens, scopes, the list envelope, CORS, a rate limit and
the document, wired together and answering over a socket.

## What the framework answers for you

| | |
|---|---|
| No route matched | `404 Not Found` |
| The path exists, the method does not | `405 Method Not Allowed` |
| A handler raised | `500 Internal Server Error` |
| CSRF token missing or wrong | `419 Page Expired` |
| Behind `RequireAuth`, not signed in | `401 Unauthorized` |

Each of those is a problem document for a JSON client and the plain text
body Askr has always sent for everybody else. Nothing changed for a
browser.

The 401 is the one worth spelling out: a browser is redirected to the
sign-in page, an Inertia client gets `401` as text because its client
reads the status and not the body, and an API client gets a problem
document. A `302` to an HTML sign-in form is useless to a program — it
follows it and gets a `200` with a login page in it, which is the failure
arriving disguised as success.

## An error body never carries an exception message

The body of a `500` is the words `Internal Server Error` and nothing else.
No class name, no message, no stack trace, in any environment.

This is not caution about debugging, it is where the secrets are. A
database error carries the SQL, a configuration error carries the value, a
file error carries the path. A framework that helpfully returns
`E.Message` has published a reconnaissance endpoint on every route that
can throw — and the routes that throw are the ones holding a connection
string.

The exception goes to the log, in full, with the method and path, always,
whatever `LogRequests` is set to. That is the one place it can be read by
somebody entitled to read it. See [Logging](logging.md).

`detail` is for text the application wrote on purpose, for that reply.
Passing a caught exception's message into it puts back exactly what this
rule removes.

## What is not here

**There are no per-field filters on a list.** `q` is free text over the
columns you named with `Searchable`. Per-field filters need an operator
per type and a way to express and/or, and that is a separate question
about how much of a query language a URL should carry. Add a `Where` of
your own to the query you hand `Rows` — a list over "my orders" is still
a list.

**There is no cursor pagination.** `page` and `per` over a total order,
which is what `Paginate` guarantees. Cursors are the right answer for a
feed that grows while you read it, and the wrong shape for a `pages`
count, which is what a table with page numbers under it needs.

**There is no refresh token and no OAuth.** A token is issued by somebody
who is already trusted -- at a console, or by a handler you wrote -- and
lives until it expires or is revoked. Three-legged OAuth is a product, not
a feature, and half of one is worse than none.

**The rate limiter does not share its counters between processes.** Two
Askr processes behind a load balancer each enforce the limit separately.
A shared counter needs somewhere shared to put it, and that brings a
question this does not have to answer: what happens to every request when
that store is down.

**The document does not describe request bodies as having required
fields**, and it does not describe your own error responses unless you
call `Answers`. Both are things `TModel.Rules` and the handler know and
the framework does not.

**Content negotiation reads `Accept` and nothing else.** No `?format=json`
query parameter, no `.json` suffix on the path. One way to ask means one
way to be wrong about it.

**`about:blank` is the only `type` the framework writes.** A registry of
problem types with a documentation page behind each URI is a good thing
for an application to have and a bad thing for a framework to invent: the
URIs would point at pages Askr does not host.
