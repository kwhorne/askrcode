# APIs

Askr serves pages and it serves programs, and the difference is not two
sets of routes. It is one route that can tell who is asking.

```pascal
function TCustomerCtl.Store(Req: TRequest): TResponse;
var
  C: TCustomer;
begin
  AuthorizeScope('customers:write');
  C := Req.Arena.New<TCustomer>;
  Req.FillInto(C);
  if not C.Validate then
    Exit(BackWithErrors(C.Errors));   { 302 + flash, or 422 + JSON }
  C.Save;
  Result := RespondModel(C, 201);
end;
```

A browser posting that form is redirected and reads the errors off the
page it lands on. A program posting the same body gets `422` with the
errors in it. The handler never asks which one it is talking to, because
a handler that has to ask will eventually forget.

## The whole stack

This is what `askr new` writes, in this order, and the order is the
argument:

```pascal
UseCors(R);             { first: a preflight carries no credentials }
R.Use(StaticFiles.Serve);
UseMaintenance(R);
UseSitemap(R, @AppSitemap);
UseRobots(R);

R.Use(@LeaseDb);        { before anything that reads the database }
R.After(@ReleaseDb);

SetSessions(TSessionStore.Create);
UseSessions(R);
UseTokenAuth(R);        { Authorization: Bearer — before UseCsrf }
RateLimit.PerMinute(600).KeyBy(@TokenRateKey);
UseRateLimit(R);        { after the token, so the bucket can be named }
UseCsrf(R);
UseAuth(R);
```

CORS allows nothing and no token has been issued, so a new project
behaves exactly as it did before — the pieces are wired, not switched on.
[`UseOpenApi`](openapi.md) is the one line the scaffold does **not**
write: there is nothing to describe yet, and a stub document that failed
its own drift check on the first run would be a poor introduction to it.

| | |
|---|---|
| [API tokens](tokens.md) | `Authorization: Bearer`, scopes, revocation |
| [Lists and pagination](lists.md) | `data`, `meta`, `links`, and the grid on the server |
| [CORS](cors.md) | Who else may call this, from a browser |
| [Rate limiting](rate-limiting.md) | How often one caller may ask |
| [OpenAPI](openapi.md) | The document, and the gate that keeps it true |

[`examples/api/apidemo.lpr`](../examples/api/apidemo.lpr) is all of it
wired together in one file, and it is what `./askr api:check` drives.

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

## What the framework answers for you

| | |
|---|---|
| No route matched | `404 Not Found` |
| The path exists, the method does not | `405 Method Not Allowed` |
| A bad or missing API token | `401 Unauthorized` |
| A gate or a scope said no | `403 Forbidden` |
| CSRF token missing or wrong | `419 Page Expired` |
| Over the rate limit | `429 Too Many Requests` + `Retry-After` |
| A handler raised | `500 Internal Server Error` |

Each of those is a problem document for a JSON client and the plain text
body Askr has always sent for everybody else. Nothing changed for a
browser.

### 401 and 403 are not the same refusal

`401` says the request carried no credential, or none that worked, and
the caller should send one. `403` says they did and it is not enough. A
client told `403` when it should have been told `401` does not know to
authenticate, and stops there.

It is easy to get wrong because the code that refuses is the same:
`Authorize` asks a gate, the gate says no, and whether anybody was asking
has to be looked at separately. Askr had it wrong until a gate driving a
real API found it. `Authorize` and `AuthorizeScope` raise
`EUnauthenticated` when nobody is signed in and `EForbidden` when
somebody is, and a bare `401` carries `WWW-Authenticate: Bearer` where a
bearer scheme is wired up.

A browser behind `RequireAuth` is redirected to the sign-in page instead,
and an Inertia client gets `401` as text because its client reads the
status and not the body. A `302` to an HTML sign-in form is useless to a
program — it follows it and gets a `200` with a login page in it, which is
the failure arriving disguised as success.

### Raising one from a handler

Raising is the only way out of the middle of a function, and not every
failure is a fault. An exception descending from `EHttpError` says which
status it should become:

```pascal
type
  ENotFound = class(EHttpError)
  public
    function HttpStatus: Integer; override;      { 404 }
    function PublicDetail: string; override;     { optional, empty by default }
  end;
```

The server answers with that instead of `500`, does not log it as a
failure below `500`, and does not close the connection over it. See
[Responses](responses.md#answering-with-a-status-from-deep-inside).

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

**Content negotiation reads `Accept` and nothing else.** No `?format=json`
query parameter, no `.json` suffix on the path. One way to ask means one
way to be wrong about it.

**`about:blank` is the only `type` the framework writes.** A registry of
problem types with a documentation page behind each URI is a good thing
for an application to have and a bad thing for a framework to invent: the
URIs would point at pages Askr does not host. Write your own `type` with
`BeginProblem`.

**There is no resource or transformer layer.** A model serialises itself,
minus whatever [`HideFromJson`](models.md) hides. Picking a different set
of columns per endpoint needs a typed column list the framework does not
have a shape for yet, and a stringly-typed one would undo what
`askr schema` is for.

**There is no versioning scheme.** `/api/v2` is a path prefix and works
today; the framework has no opinion beyond that, and nothing here reads a
version header.

Each page above ends with its own list of what it does not do.
