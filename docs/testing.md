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

## Fakes

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
