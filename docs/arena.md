# The arena

This is the one page to read before writing Askr code. Everything else in
the framework follows from it.

## The model

A worker owns **one arena** and calls `Reset` before each request.
Everything allocated during the request is freed in a single operation. No
per-object cleanup, no refcounting, no garbage collector.

```pascal
type
  TGreeting = class(TArenaObject)      // inherits arena allocation
    Name: TStr;
    constructor Create(const AName: TStr);
  end;

G := TGreeting.Create(Req.Query('name'));   // in the arena, constructor runs
// no try/finally, no Free
```

`Reset` does not release the memory back to the OS — it rewinds the
allocation pointer. The block is reserved once and reused for every request
after it. That is why memory is flat under load, and it is measured: two
tests assert that `BytesReserved` levels off after warm-up, in the arena
alone and across 500 requests through the server. Those are premise tests.
If they stop holding, the model is wrong, not the test.

## The rules

**Anything that must outlive the current statement inherits `TArenaObject`
and is created inside a `UseArena` block.** The host sets the arena; your
code does not touch it.

**Never call `Free` on an arena object.** It is a no-op, but writing it
signals that the author believes in the wrong model.

**The destructor never runs on an arena object.** This is the rule that
surprises people, so read the next part carefully.

## What is cleaned up, and what leaks

Destructors do not run. But `string`, dynamic array and interface fields
**are** cleaned: `NewInstance` checks `ClassNeedsFinalization` and registers
`CleanupInstance` as a `Defer`. `TSession`, `TQuery` and `TErrors` depend on
that.

A field that points at an *object* — a `TStringList`, a `TList` — **leaks**,
because only a destructor would free it, and that never runs.

```pascal
type
  TGood = class(TArenaObject)
    Name: string;          // cleaned via Defer
    Items: array of Int64; // cleaned via Defer
  end;

  TBad = class(TArenaObject)
    List: TStringList;     // LEAKS — nothing frees it
  end;
```

**Prefer `TStr` anyway.** Every field that needs finalisation costs one
`Defer` entry per object per request. `TStr` is a slice — a pointer and a
length — and costs nothing.

```pascal
type
  TBetter = class(TArenaObject)
    Name: TStr;            // no Defer entry at all
  end;
```

`ClassNeedsFinalization` walks the whole inheritance chain. Free Pascal
emits one init table per class covering only that class's own fields, so a
subclass that inherits a `string` field has an empty table of its own.
Checking only the class itself would leak one string per such model per
request.

## Creating objects

```pascal
Customer := Arena.New<TCustomer>;
```

`Arena.New<T>` runs the constructor, sets up the VMT, and puts the object in
**that** arena even when another one is ambient. The type parameter is bound
to `TArenaObject` on purpose: an arbitrary `TObject` would land on the heap
without the call site noticing.

`Arena.Owns(P)` says whether a pointer actually lives in the arena's memory.
Use it in tests instead of assuming.

## Cleanup you schedule yourself

```pascal
Arena.Defer(@CloseHandle, Pointer(H));
```

`Defer` is the answer to destructors never running. The deferred functions
run in reverse order on `Reset`, `Rewind` and `Destroy`. A function that
raises is swallowed deliberately — a half-finished `Reset` is worse than a
lost error message.

## Marks and rewinding

```pascal
Mark := A.Mark;
try
  { scratch allocations }
finally
  A.Rewind(Mark);
end;
```

Used where the framework builds SQL text and parameters that are not needed
after the call.

> **Allocate parameters BEFORE `Arena.Mark` when the code rewinds
> afterwards.** If they sit after the mark, the next allocations overwrite
> the values while they are being read. That hit `LoadRelation` and produced
> a bug that did not show up in the tests.

## Reading the numbers

| Property | What it counts |
|---|---|
| `BytesLive` | Allocated right now |
| `BytesReserved` | Held by the arena, across resets |
| `HighWaterMark` | The most that was ever live |
| `ResetCount` | Requests this worker has served |

The welcome page in a new project shows all four for the worker that served
it. That is the whole memory model in one screen.

## The three copies that cannot be skipped

Three places in the framework copy data across an arena boundary. None of
them is an optimisation to remove:

**`Cache.Put` copies out of the caller's arena.** The value must outlive the
request that stored it.

**`Cache.Get` copies out into the caller's arena.** Returning a pointer into
the cache would let an eviction leave a dangling pointer, and the value
would outlive the request.

**`Queue.Push` copies out; the queue worker copies in.** When a controller
pushes, the payload lives in the request arena. The request is finished long
before the job runs — the arena has been reset and the memory handed to a
new request. A job pointing there would read another user's data.

```
request arena  ->  heap (in Push, while the caller still owns the bytes)
               ->  worker arena (in the worker, before the handler is called)
```

If you touch any of them, run the arena tests. They zero the arena and fill
it with garbage before reading back.

## Things that live outside the arena on purpose

**`TPgConnection` and the other connections.** They live on the heap across
requests. A connection is not a request-scoped object and must never become
one.

**The worker's read buffer.** It must survive `Reset` for keep-alive and
pipelining to work. The request head is copied into the arena before
parsing, so the buffer can grow when the body arrives without leaving the
slices in `TRequest` dangling.

**Uploaded file content.** It is a slice into the read buffer, valid for the
duration of the request. See [File uploads](uploads.md).

## `TStr`

A slice: a pointer and a length into memory someone else owns. The parser
copies nothing — every field on a request is a slice into the buffer the
bytes arrived in.

```pascal
function TStr.IsEmpty: Boolean;
function TStr.ToString: string;          { copies out; use at the edges }
function TStr.EqualsStr(const S: string): Boolean;
function TStr.SameTextStr(const S: string): Boolean;   { ASCII case-insensitive }
function TStr.StartsWithStr(const S: string): Boolean;
function TStr.IndexOfByte(B: Byte; StartAt: SizeInt = 0): SizeInt;
function TStr.IndexOfStr(const Needle: string; StartAt: SizeInt = 0): SizeInt;
function TStr.Slice(Start: SizeInt; Count: SizeInt = -1): TStr;
function TStr.TrimSpace: TStr;
function TStr.SplitAt(B: Byte; out Left, Right: TStr): Boolean;
function TStr.ToInt64(out V: Int64): Boolean;
```

`ToString` copies into a heap string. Use it at the edges — logging, a model
property, an exception message — not in a loop.

> `TStr.SplitAt` cannot take `Self` as an out parameter: `Left` is written
> before `Right` is computed.

## Background work

PRD rule two: **background jobs never borrow the request's arena, they get
their own.** The queue worker resets its arena between jobs, exactly as HTTP
workers do between requests. A job handler is written the same way a
controller is.
