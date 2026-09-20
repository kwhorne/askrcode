# Requests

`TRequest` is parsed into the arena and **copies nothing**. Every field is a
`TStr` slice into the buffer the bytes arrived in. When the host calls
`Arena.Reset`, both the buffer and the request go in one operation.

## The line

| | |
|---|---|
| `Method` | `hmGet`, `hmPost`, `hmPut`, `hmPatch`, `hmDelete`, `hmHead`, `hmOptions`, `hmUnknown` |
| `MethodStr` | As it arrived |
| `Path` | Percent-decoded. This is what the router matches |
| `RawPath` | As it arrived |
| `QueryString` | Everything after `?` |
| `Target` | Path and query together |
| `VersionMinor` | 1 for HTTP/1.1 |
| `RemoteAddr` | The peer |

```pascal
if Req.Method = hmPost then ...
```

> Inside a class, `MethodName` resolves to `TObject.MethodName`. Qualify it:
> `Askr.Http.Types.MethodName(Req.Method)`.

## Query parameters

```pascal
Name := Req.Query('name');              { TStr, percent-decoded, + is space }
Page := Req.Page;                       { ?page=N, clamped to at least 1 }
Limit := Req.IntQuery('limit', 25);
if Req.HasQuery('debug') then ...
```

`Page` exists because pagination is the most common place a query parameter
becomes a number.

## Route parameters

Set by the router when a pattern matches.

```pascal
Id := Req.IntParam('id');       { 0 if absent or not a number }
Slug := Req.Param('slug');      { TStr }
if Req.HasParam('id') then ...
```

## Form fields

```pascal
Name := Req.Form('name');
if Req.HasForm('subscribe') then ...
```

`Form` reads **both** `application/x-www-form-urlencoded` and the ordinary
fields of a `multipart/form-data` body. Without that, a form with a file in
it would make every other field unreachable — and the CSRF token is one of
them.

`HasForm` is not the same as a non-empty `Form`: a checkbox often sends an
empty value, and "present but empty" is different from "absent".

## Files

```pascal
if Req.IsMultipart then
begin
  F := Req.Upload('avatar');
  if not F.IsEmpty then
    Path := F.StoreIn('storage/uploads');
end;
```

See [File uploads](uploads.md).

## Headers

```pascal
Auth := Req.Header('Authorization');    { case-insensitive }
if Req.HasHeader('X-Inertia') then ...
```

`HasHeader` is true for a header present with an empty value; `Header` would
return an empty `TStr` for both.

## The body

```pascal
Req.Body;              { TStr, the raw bytes }
Req.ContentLength;
Req.IsJson;            { application/json, and anything +json }
Req.ContentType;
```

`IsJson` covers `application/ld+json`, `application/problem+json` and the
rest of the `+json` family, not just the exact type.

## JSON into a model

```pascal
uses Askr.Urd.Bind;

C := Arena.New<TCustomer>;
Req.FillInto(C);
if not C.Validate then
  Exit(BackWithErrors(C.Errors));
C.Save;
```

`FillInto` is a class helper in `Askr.Urd.Bind`, not a method on `TRequest`.
Without that split, `Askr.Http` would have to know `Askr.Urd`, and that
would bind the desktop shell and plain JSON services to the data layer.

It reads a JSON body or form fields, matching on published property names,
and converts to the property's type.

> **The primary key is never filled from a request.** Do not "improve" that.

The parsed JSON body is cached per request. The cache cannot be keyed on the
request pointer alone — the arena reuses addresses, so the next request
often lands exactly where the last one was. `Arena.Defer` clears it on
`Reset`.

## The ambient request

```pascal
CurrentRequest;          { the request being served on this thread }
UseRequest(R);           { the host sets it; returns the previous }
```

Set by the host before it calls into your code, so helpers like `Inertia()`
can find it without every controller passing it down.

## Limits and what is refused

| Condition | Status |
|---|---|
| Malformed | 400 |
| URI too long | 414 |
| Headers too large | 431 |
| Body over `MaxBodyBytes` (8 MB default) | 413 |
| HTTP version not 1.x | 505 |
| `Transfer-Encoding: chunked` | 501 |

Chunked request bodies are **refused, not misread**. Obsolete line folding
is refused for the same reason. The body limit is checked against
`Content-Length` before a single byte of body is read.
