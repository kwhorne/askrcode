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

```pascal
Result := RespondText('hello');
Result := RespondJson('{"ok":true}');
Result := Redirect('/customers', 303);
Result := NoContent;
```

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
in any RFC — it is Laravel's, and the Inertia client recognises it and
reloads the page instead of showing an error. That is the right behaviour
for an expired CSRF token: usually the user left a tab open, not an attack.

## Redirect status matters

**After `PUT`, `PATCH` or `DELETE`, redirect with 303.** With 302 the
browser repeats the method against the new address.

```pascal
Result := Redirect('/customers', 303);
```

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
