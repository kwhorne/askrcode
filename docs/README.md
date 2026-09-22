# Askr

Askr is an application framework for Free Pascal. It gives you what Rails
gives you — routing, models, migrations, validation, sessions, auth,
queues, mail, a console, and an API layer with tokens and an OpenAPI
document — on a compiled stack that ships as **one binary with no
sidecars**.

Three things make it different from the frameworks it borrows from, and
they shape everything else in this documentation:

**Memory is an arena per request.** A worker owns one arena and resets it
before each request. Everything allocated during the request is freed in a
single operation. No per-object cleanup, no refcounting, no GC. Measured:
flat memory across 500 requests, and the first success criterion in the
PRD depends on it. See [The arena](arena.md).

**The schema is checked at compile time.** `askr schema` reads your real
database and generates typed column constants. `Where(Customers.Email, Eq, 42)`
is a compile error, not a runtime surprise. See [Typed columns](schema.md).

**The binary is the deployment.** No PHP-FPM, no Redis, no supervisor, no
Composer. The queue, cache and scheduler run in the same process. A durable
queue uses the database you already have. See [Deployment](deployment.md).

---

## Start here

| | |
|---|---|
| [Getting started](getting-started.md) | Install the toolchain, create a project, serve it |
| [The CLI](cli.md) | Every command, and what it does |
| [Configuration](configuration.md) | `.env`, `askr.toml`, and which one wins |
| [Versions](versions.md) | Pinning a release, `askr install` and `askr update` |
| [The arena](arena.md) | The memory model, and the rules it imposes on your code |
| [Coding agents](cli.md#an-mcp-server-for-agents) | `askr mcp`, and the tools it serves |

## HTTP

| | |
|---|---|
| [Routing](routing.md) | Routes, parameters, middleware, response filters |
| [Requests](requests.md) | Query, form, JSON, headers, route parameters |
| [Responses](responses.md) | Status, headers, cookies, redirects, JSON |
| [File uploads](uploads.md) | `multipart/form-data`, and why the client's filename is not to be trusted |
| [Images](images.md) | What a file really is, and resizing it |
| [Inertia and Svelte](inertia.md) | Server-driven pages without an API |
| [Lauf](lauf.md) | The frontend layer: components, forms, the data grid |

## APIs

| | |
|---|---|
| [APIs](api.md) | Who is asking, what an error looks like, and how the pieces fit |
| [API tokens](tokens.md) | `Authorization: Bearer`, scopes, revocation |
| [Lists and pagination](lists.md) | `data`, `meta`, `links`, and the grid on the server |
| [CORS](cors.md) | Who else may call this, from a browser |
| [Rate limiting](rate-limiting.md) | How often one caller may ask |
| [OpenAPI](openapi.md) | The document, and the gate that keeps it true |

## Data

| | |
|---|---|
| [Databases](database.md) | Postgres, MySQL, SQLite; connections and pooling |
| [Models](models.md) | Mapping, timestamps, soft deletes, lifecycle events |
| [Queries](queries.md) | The typed query builder, eager loading, pagination |
| [Validation](validation.md) | Rules on the model, errors keyed by column |
| [Migrations](migrations.md) | The schema builder and the migrator |
| [Typed columns](schema.md) | `askr schema`, generated from the live database |
| [Rún](run.md) | The optional query language with comptime schema checking |

## Security

| | |
|---|---|
| [Sessions](sessions.md) | Cookies, flash, and what a session costs |
| [CSRF](csrf.md) | On by default in a new project |
| [Authentication](auth.md) | Login, "remember me", gates |
| [Cryptography](crypto.md) | Hashing, password storage, signing, the app key |
| [Passkeys](webauthn.md) | WebAuthn: registering a credential, and signing in with it |
| [TLS](tls.md) | HTTPS in the server, verification in the client |

## Runtime

| | |
|---|---|
| [Queues](queue.md) | Background jobs, in-process or durable |
| [Scheduler](scheduler.md) | Recurring work |
| [Cache](cache.md) | A sharded LRU in the process |
| [Mail](mail.md) | Resend, SMTP with STARTTLS, or a log file |
| [Logging](logging.md) | Levels, fields, text or JSON |
| [HTTP client](http-client.md) | Calling other services, with certificate verification |
| [AI](ai.md) | Claude: text, streaming, tools, structured output |

## Tools

| | |
|---|---|
| [Testing](testing.md) | The test framework, and testing without a socket |
| [Desktop](desktop.md) | The same app in a native window |
| [Deployment](deployment.md) | Shipping the binary |

---

## What is not here

Askr is honest about what has not been done. **One thing is written but
never run in earnest**, and it is marked as such everywhere it appears:

- **The Windows WebView2 shell.** Compiled and type-checked against FPC's
  own `rtl/win` declarations; never started on a Windows machine. The next
  step there is a run, not more code.

The other two came off that list by being run, and what the runs cost is
the argument for keeping such a list rather than a reason to be quiet
about it.

**The AI layer** works against the real API — text, streaming, tool calls,
structured output ([`examples/ai/aiprobe.lpr`](../examples/ai/aiprobe.lpr)).
The run found a bug the suite could not: the tool loop sent the assistant
turn back without the `tool_use` blocks it had asked with, which the API
refuses. The suite had been green throughout, because it checked the shape
the author believed in rather than the one the API requires.

**The Resend transport** sends
([`examples/mail/resendprobe.lpr`](../examples/mail/resendprobe.lpr)): a
message accepted with an id, the same idempotency key giving the same id
rather than a second message, and a refusal arriving as `EResendError`.
That run found nothing wrong. Both outcomes are worth having.

Things that deliberately do **not** exist here, with the reasons, are
listed on each relevant page. Every page has that section, and it is the
part that makes this documentation something other than marketing.

## Version

This documentation describes Askr 0.12.0. The framework builds and passes
its full test suite on Free Pascal 3.2.2 and 3.3.1 trunk, on aarch64 and
x86_64, on macOS and Linux.
