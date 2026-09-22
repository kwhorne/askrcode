# Responses

`TResponse` lives in the arena and its builders return `Self`, so they chain:

```pascal
Result := Respond(201)
  .WithHeader('Location', '/customers/7')
  .WithJson(Payload);
```

## Constructors

| | |
|---|---|
| `Respond(Status)` | Empty, status 200 by default |
| `RespondText(S, Status)` | `text/plain; charset=utf-8` |
| `RespondHtml(S, Status)` | `text/html; charset=utf-8` |
| `RespondJson(S, Status)` | `application/json` |
| `Redirect(Location, Status)` | 302 by default |
| `NoContent` | 204 |
| `Problem(Status, Detail)` | `application/problem+json`, RFC 9457 |

```pascal
Result := RespondText('hello');
Result := RespondJson('{"ok":true}');
Result := Redirect('/customers', 303);
Result := NoContent;
Result := Problem(409, 'That order has already shipped.');
```

`Problem` is the shape errors take for a client that is not a browser, and
the framework's own 404, 405, 419, 401 and 500 use it when the caller
asked for JSON. See [APIs](api.md).

## Answering with a status from deep inside

Raising is the only way out of the middle of a function, and not every
failure is a fault. An exception descending from `EHttpError` says which
status it should become:

```pascal
type
  ENotFound = class(EHttpError)
  public
    function HttpStatus: Integer; override;      { 404 }
    function PublicDetail: string; override;     { optional }
  end;
```

The server answers with that instead of 500, and does not log it as a
failure when it is below 500 — a refused request is not a fault, and a
connection is not closed over one.

**The exception's message still does not reach the client.**
`PublicDetail` is empty by default, for the same reason `detail` in a
problem document is: the message is where the SQL, the path and the value
are. Overriding it is how an application says something on purpose.

`EForbidden`, from [gates](auth.md#gates), is the one Askr ships: 403,
with nothing added.

## Headers

```pascal
Res.WithHeader('X-Request-Id', Id);     { last value wins for that name }
Res.AddHeader('Set-Cookie', Raw);       { appends }
Res.HeaderValue('Content-Type');        { read it back }
```

`WithHeader` lets the last value win per name. Two `Location` or two
`Content-Type` headers is almost always a caller bug, and for those it is
actively harmful.

`Set-Cookie` is the exception that may legitimately repeat, which is what
`AddHeader` and `WithCookie` are for.

## Cookies

```pascal
Res.WithCookie('theme', 'dark', 86400);
```

```pascal
function WithCookie(const AName, AValue: string;
  MaxAge: Integer = -1;
  Secure: Boolean = False;
  ReadableByJs: Boolean = False;
  const SameSite: string = 'Lax';
  const Path: string = '/'): TResponse;
```

`HttpOnly` and `SameSite=Lax` are the default because the alternative is
remembering them. `ReadableByJs` turns `HttpOnly` off for the cookies a
frontend genuinely must read — `XSRF-TOKEN` is the one that matters.
`MaxAge` below zero gives a session cookie; zero deletes.

> Until `WithCookie` existed, the session cookie and the CSRF cookie
> overwrote each other, because `WithHeader` let the last value win. Two
> cookies in one response is exactly why it was added.

## Status codes

```pascal
Res.Status(422);
Res.StatusCode;
```

`StatusText` knows the usual codes plus **419 Page Expired**, which is not
in any RFC. It is a convention the Inertia client recognises: it reloads
the page instead of showing an error. That is the right behaviour for an
expired CSRF token — usually the user left a tab open, not an attack.

## Redirect status matters

**After `PUT`, `PATCH` or `DELETE`, redirect with 303.** With 302 the
browser repeats the method against the new address.

```pascal
Result := Redirect('/customers', 303);
```

## Conditional GET

```pascal
Respond(200).WithBody(Html).WithETag('v3')
```

The value is the opaque part **without quotes** — they are added for you,
because an unquoted ETag is not a valid one and the mistake stays invisible
until some client rejects it. `WithETag(Value, True)` makes it weak.

The comparison happens in the server, once, so no handler has to do it: a
`GET` or `HEAD` carrying `If-None-Match` that matches becomes a **304 with
no body**. Static files get an ETag automatically, from the file's
modification time and size.

**A response that sets a cookie never answers 304, and loses its ETag.**
A body that comes with a cookie is a body made for one client. A page with
a CSRF token in it, served from the client's cache on a later 304, is a
form whose token has since been rotated — a rejected submit that nobody
can reproduce. The guard is in the framework rather than in a rule you have
to remember, and it takes the ETag with it: leaving the tag would only move
the problem to the next cache in the chain.

Only `GET` and `HEAD` are conditional this way. `If-None-Match` on other
methods is a precondition — answered with `412`, which Askr does not do —
and turning a `POST` into a 304 would answer a write with "your copy is
current" and drop it.

### What is not here

**No `Last-Modified` or `If-Modified-Since`.** ETags answer the same
question with fewer ways to be subtly wrong, and a date has one-second
resolution with a timezone attached.

**The static ETag has a one-second window.** It is built from modification
time and size, as nginx and Apache build theirs, so a file rewritten within
the same second at the same length keeps its tag. Hashing the bytes would
close that window at the cost of a pass over every file on every request;
the window closes itself on the next write.

## Bodies

```pascal
Res.WithBody('text');
Res.WithBody(SomeTStr);       { no copy }
Res.Body;
```

A `TStr` body is written straight out. A `string` body is copied into the
arena.

`BodyForbidden` is true for the statuses that by definition have no body
(204, 304, 1xx). `HEAD` keeps `Content-Length` and drops the body, as the
protocol requires.

## JSON

```pascal
uses Askr.Core.Json;

W.Init(Arena, 1024);
W.BeginObject;
W.Field('id', C.Id);
W.Field('name', C.Name);
W.Key('orders');
W.BeginArray;
  ...
W.EndArray;
W.EndObject;
Result := RespondJson(W.ToString);
```

`TJsonWriter` writes into the arena and tracks nesting, so a mismatched
`EndObject` is caught rather than producing broken JSON.

Models serialise through RTTI in `Askr.Urd.Json`:

```pascal
Result := RespondJson(ToJson(Customer));
```

## Reading a response

Useful in response filters and tests:

```pascal
Res.StatusCode;
Res.HeaderValue('Location');
Res.HeaderCount;
Res.HeaderAt(I);          { for the several Set-Cookie case }
Res.Body.ToString;
```
