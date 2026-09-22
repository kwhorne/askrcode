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

**There is no token authentication.** `RequireAuth` is cookie and session
based. An API client today authenticates the way a browser does, or the
application brings its own middleware. Tokens — hashed at rest, scoped,
revocable — are the next step and are not written yet.

**There is no list envelope.** A handler that returns a collection decides
its own shape. `TQuery.Paginate(Page, PerPage)` gives you the rows and
`TQuery.Count` the total ([Queries](queries.md)); wrapping the two in a
`data` / `meta` object is yours to write. A framework opinion here is
worth having only once the rest of the layer agrees with it.

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
