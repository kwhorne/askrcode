# Testing

```pascal
uses Askr.Testing;

begin
  Group('Customers');
  Test('index lists them', @TestIndex);
  Test('show 404s for a stranger', @TestMissing);
  RunTestsAndHalt;
end.
```

`RunTestsAndHalt` prints a report and exits non-zero on failure.
`RunTests` returns the failure count if you want to do something else.

```sh
askr test
```

## Assertions

```pascal
AssertTrue(Cond, 'what');
AssertFalse(Cond, 'what');
AssertEqual(Actual, Expected, 'what');     { string, Int64, Currency, Boolean }
AssertContains(Haystack, Needle, 'what');
AssertNotContains(Haystack, Needle, 'what');
AssertNotNil(Obj, 'what');
AssertNil(Obj, 'what');
AssertStatus(Res, 200, 'what');
Fail('what');
```

The `what` is a sentence about the behaviour, not a restatement of the
expression. It is what you read when it fails.

## Testing HTTP without a socket

```pascal
K := TTestClient.Create(R);
try
  Res := K.Get('/customers/7');
  AssertStatus(Res, 200, 'found');
  AssertContains(Res.Body.ToString, 'Ada', 'the right customer');
finally
  K.Free;
end;
```

```pascal
K.Post('/customers', '{"name":"Ada"}');
K.Put('/customers/7', Body, 'application/x-www-form-urlencoded');
K.Delete('/customers/7');
K.WithHeader('X-Prove', 'v').Get('/x');      { next call only }
K.AsInertia.Get('/customers');               { sets X-Inertia }
```

The client drives the router directly. No port, no socket, no waiting, and
tests can run in parallel without fighting over ports.

A refusal a handler raises — `AuthorizeScope`, a gate — comes back as the
403 or 401 the server would send, because the router answers it. A real
fault still raises out of the test: an exception says more than a 500.

`K.Arena` is the arena it uses, if you need to allocate alongside.

## Testing the arena

```pascal
AssertArenaStable(Klient.Arena, @OneRequest, 300,
  'the arena levels off over 300 requests');
```

Runs the procedure N times and asserts that `BytesReserved` stops growing.

> **It warms up first.** The first rounds always grow; the number only means
> something after warm-up.

Two such tests are **premise tests** and must not be softened:
`BytesReserved` must level off in the arena alone and across 500 requests
through the server. If they stop holding, it is the arena model that is
failing, not the test.

## A database

```pascal
C := UseTestDatabase;       { sqlite::memory:, set as ambient }
try
  ...
finally
  CloseTestDatabase;
end;
```

In memory, so nothing to clean up and nothing to collide with.

For a test that needs durability across connections — a durable queue, for
instance — use a file under `.build/` and delete it in the teardown.

## Factories

```pascal
uses Askr.Factory;

G := TFactory<TOrder>.Create;
try
  O := G.Insert;                                   { and its customer }
  Big := G.Values(['total', 5000]).Insert;
  Lots := G.InsertMany(20);
  Draft := G.Make;                                 { not saved }
finally
  G.Free;
end;
```

A factory fills every column a row needs from the model's own mapping, with
a value that fits and is different from every other model any factory has
made — so a unique column stays unique across factories and tests.

- **What goes in.** A string is its column's name and a number, except where
  the name says more: an address for `email`, a link for `url`, a UUID for
  `uuid`, and for `password_hash` the hash of `password` — computed once,
  because a real one costs a noticeable fraction of a second each. Integers
  count, money and floats count by a quarter, a boolean is false, a date is
  today and a datetime now.
- **What stays out.** The primary key and the columns the model manages —
  timestamps, `deleted_at`. A column marked `EmptyIsNull` or `ZeroIsNull` is
  nullable and stays null. A key to a parent is left for `Insert`.
- **Parents are made.** `Insert` makes a row for each `BelongsTo` whose key
  was not given, the same way, so orders need no customer first. `Make`
  saves nothing and makes no parents.
- **`Insert` validates.** A row the model's own `Rules` refuse is an error
  that names the column, rather than a row no request could have made.
  `Values(['column', value])` sets one; `State(@Proc)` runs
  `procedure(M: TModel; N: Int64)` on each model for what a name cannot
  tell.
- **The rows live as long as their arena** — the one around the factory, or
  the factory's own when there is none, which goes when the factory is
  freed.

## Fakes

For the three things a test should not do for real:

```pascal
Queue.Fake;
PlaceOrder;
AssertEqual(Queue.Pushed('send-invoice'), 1, 'the invoice is queued');
Queue.RunPushed;                       { through the real handler, now }
Queue.StopFaking;
```

```pascal
F := FakeMail;
try
  PlaceOrder;
  AssertEqual(F.SentTo('ada@example.com'), 1, 'a receipt');
  AssertEqual(F.Last.Subject, 'Your order', '');
  AssertEqual(F.Last.Attachments[0], 'receipt.pdf', '');
  AssertEqual(F.Last.Idempotency, 'order-42', 'safe to retry');
finally
  StopFakingMail;
end;
```

```pascal
FakeEvents([TOrderPlaced]);            { none given: every class }
try
  PlaceOrder;
  AssertEqual(EventsDispatched(TOrderPlaced), 1, '');
  AssertContains(DispatchedEventJson(TOrderPlaced), '"Total":"12.5"', '');
finally
  StopFakingEvents;
end;
```

```pascal
FakeNotifications([TOrderShipped]);
try
  PlaceOrder;
  AssertEqual(NotificationsSent(TOrderShipped, '7'), 1, 'user 7 was told');
  AssertEqual(SentNotificationChannels(TOrderShipped), 'mail,database', '');
finally
  StopFakingNotifications;
end;
```

- **The queue** records what is pushed and runs nothing, so a test can ask
  without a worker racing it; `RunPushed` then runs the record through the
  real handlers, in order, with an arena as a worker would, and lets an
  exception out.
- **The mail fake renders each message first**, and refuses one a real
  transport would refuse — no sender, no recipient. A fake that took it
  would be a test that passes on mail that never goes.
- **Faked events** are recorded instead of delivered: no listener runs and
  nothing is queued. The fields are kept as they were when dispatched.
- **Faked notifications** are recorded and not sent, and `NotifyLater`
  needs no queue. `Via` is asked and each channel's `To…` is built and
  thrown away, so one that would fail for real fails here. See
  [notifications](notifications.md#testing).

| | |
|---|---|
| `TNullTransport` | Mail: counts and keeps the last message |
| `TLogTransport` | Mail: writes to a file |
| `TFakeAiTransport` | AI: canned responses, and records what was sent |

```pascal
F := TFakeAiTransport.Create;
K.UseTransport(F, True);
F.Enqueue('{"content":[{"type":"text","text":"hi"}]}');
...
AssertContains(F.Sent[0], '"model":"claude-opus-5"', 'default model');
```

Asserting on **what was sent** is often more valuable than asserting on what
came back, especially where the real service cannot be reached from the test
machine.

## How the framework tests itself

Worth copying, because the reasoning transfers:

**End-to-end over real sockets** binds to port 0 and reads the port back, so
suites run in parallel without colliding.

**Premise tests** are stated as such. That a typecast into `Currency`
answers differently per compiler *and* per architecture, and that the arena
levels off, are held down by tests whose job is to fail loudly if the
premise changes. The `Currency` one has been wrong twice, which is the
argument for writing premises down rather than remembering them.

**Mutation checks.** After writing a test for something important — session
fixation, double-delivery in the queue — remove the code it guards and check
that the test actually fails. Twice in this project a test that looked right
did not catch the regression it was written for.

**Say what a test does not prove.** The queue's concurrency test passes even
with both safety guards removed, because the race window is too narrow. That
is written in the test, so nobody reads a green run as proof the guard is
unnecessary.

**Official vectors, not self-consistency.** A SHA-256 with the wrong byte
order is stable, consistent and worthless. Every algorithm in
`Askr.Core.Crypto` is checked against NIST and RFC numbers.
