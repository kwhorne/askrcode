# OpenAPI

There was no OpenAPI document in Askr for a long time, and the reason was
written down rather than left implied: Askr knows its routes but not
which of them are public, what they accept or what they return, and a
document generated from the route table alone would be a confident
description of the wrong thing.

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

## The schemas come from the models

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
describes the shape in words, which is true — and allows `null`, which is
how an unset date goes out.

## The rest is read off what is running

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

## The drift gate is the point

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

## It is validated by something that is not us

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

## What is not here

**Request bodies have no `required` list.** Which fields an application
insists on lives in `TModel.Rules`, which is code that runs rather than a
declaration that can be read. Guessing at it is the one thing this is
built not to do.

**Your own error responses are not in it unless you say so.** `Answers`
adds one. The framework writes the statuses it answers with itself, and
knows nothing about the 409 your handler raises.

**There is no YAML, and no bundled reader.** One format, and it is the one
a tool parses. Point Redoc, Scalar, Swagger UI or anything else at
`/openapi.json`; shipping a copy of one of them would be a frontend
dependency in a framework whose welcome page works without npm.

**A wildcard route cannot be described.** OpenAPI has no way to say "the
rest of the path", so `--check` reports one under a covered prefix rather
than inventing something.
