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

**There is no list envelope.** A handler that returns a collection decides
its own shape. `TQuery.Paginate(Page, PerPage)` gives you the rows and
`TQuery.Count` the total ([Queries](queries.md)); wrapping the two in a
`data` / `meta` object is yours to write. A framework opinion here is
worth having only once the rest of the layer agrees with it.

**There is no refresh token and no OAuth.** A token is issued by somebody
who is already trusted -- at a console, or by a handler you wrote -- and
lives until it expires or is revoked. Three-legged OAuth is a product, not
a feature, and half of one is worse than none.

**There is no CORS handling and no rate limiting.** Both are real and both
are absent. A browser calling an Askr API from another origin will be
stopped by the browser, not by Askr, and nothing in the framework counts
requests per caller.

**There is no OpenAPI document.** Askr knows its routes but not which of
them are public, what they accept, or what they return, and generating a
document from the route table alone would produce a confident description
of the wrong thing. The same argument as the [sitemap](../src/http/Askr.Http.Sitemap.pas):
the framework generates, the application declares.

**Content negotiation reads `Accept` and nothing else.** No `?format=json`
query parameter, no `.json` suffix on the path. One way to ask means one
way to be wrong about it.

**`about:blank` is the only `type` the framework writes.** A registry of
problem types with a documentation page behind each URI is a good thing
for an application to have and a bad thing for a framework to invent: the
URIs would point at pages Askr does not host.
