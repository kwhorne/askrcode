# Telemetry

The framework says when something is done -- a request, a query, a job, a
mail -- with how long it took, to anything that listens. A log, a
dashboard or a metrics exporter each attach, and the code that did the
work knows none of them. The idea is Phoenix's `:telemetry`.

The [dashboard](dashboard.md) at `/_askr` is one such listener, and
ships with every new app.

```pascal
uses Askr.Core.Telemetry;

procedure SlowQueries(const E: TTelemetryEvent);
begin
  if E.DurationUs > 100000 then       { 100 ms }
    LogWarn('slow query', ['sql', E.Field('sql'), 'us', E.DurationUs]);
end;

AttachTelemetry('askr.query', @SlowQueries);
```

## What the framework says

| Event | When | Fields |
|---|---|---|
| `askr.request` | the router has answered | `method`, `route`, `path`, `status` |
| `askr.query` | a statement has run, or failed | `sql`, `rows`, and `error` when it failed |
| `askr.job` | a queue job is settled | `job`, `outcome`, `attempt` |
| `askr.mail` | a mail has gone, or failed | `transport`, `recipients`, and `error` when it failed |

Every event has `E.DurationUs`, its duration in microseconds, and
`E.Field(Key)` for a field.

- **`route` is the pattern** -- `/orders/:id` -- so a dashboard has one
  line per route and not one per order; `path` is the path, without its
  query string. A request no route matched has an empty `route`.
- **`outcome` is `done`, `retry`, `failed` or `dropped`**: a job that ran,
  one that failed and will run again, one that failed on its last attempt,
  and one no handler was registered for.
- **`rows`** is the rows a query gave, or the rows it touched.

## What they never carry

**A value from a request, or a secret.** A query is its statement with
its placeholders -- `WHERE email = ?` -- and never its parameters. A mail
says how many recipients, and not who. A failure says its SQLSTATE, or
its exception's class, and not its message: MySQL's message for a unique
violation quotes the value that was already there, and an SMTP server's
refusal quotes the address. A handler that needs more has the thing
itself, where it runs.

## Listening

`AttachTelemetry(Prefix, @Handler)` hears every event whose name is
`Prefix` or starts with `Prefix` and a dot:

| Prefix | Hears |
|---|---|
| `'askr.query'` | the queries |
| `'askr'` | everything the framework says |
| `'stripe'` | everything the Stripe plugin says |
| `''` | everything |

A prefix is whole names: `'askr.req'` does not hear `askr.request`.
`DetachTelemetry(@Handler)` stops it.

**A handler runs on the thread that emitted**, in the middle of a request
or a job. It has to be quick and safe on any thread; work that is slow --
sending numbers over a network -- belongs in the queue. **A handler that
raises is logged and skipped**, and the request goes on: a broken meter
must not become a 500.

## Saying something of your own

```pascal
var
  Started: Int64;
begin
  Started := TelemetryStart;         { 0 when nobody is listening }
  ChargeTheCard;
  EmitSince('shop.charge', Started, ['provider', 'stripe', 'outcome', 'ok']);
end;
```

`TelemetryStart` reads the clock only when something is attached, and
`EmitSince` does nothing with a start of 0, so code that says what it did
costs nothing in an app nobody measures. `EmitTelemetry(Name, DurationUs,
Fields)` sends one with a duration you have. Name it under a prefix of
your own; `askr.` is the framework's.

## What it costs

With nothing attached, one integer read at each place that emits: no
clock, no strings, no allocation. With a handler attached, a clock read
at the start and the end, the fields as strings, and a copy of the list
of handlers per event.

## What is not here

- **An exporter.** Nothing here sends numbers to Prometheus, StatsD or
  OpenTelemetry. A handler that does is a few lines, and which one an app
  wants is the app's choice.
- **Spans and traces.** An event is one thing that finished, not a tree;
  a request's queries are not linked to the request that made them.
