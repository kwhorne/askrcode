# Queues

```pascal
uses Askr.Queue;

SetQueue(TQueue.Create(4));          { four workers }
Queue.Handle('send-welcome', @SendWelcome);
Queue.Start;
```

```pascal
Queue.Push('send-welcome', Customer.Email);
Queue.Push('send-report', Payload, 60);     { in 60 seconds }
```

The queue, the scheduler and the cache run in the same process. **That is
the point**: no Redis, no Horizon, no supervisor beside the app.

## A handler

```pascal
procedure SendWelcome(const Ctx: TJobContext);
var
  M: TMailMessage;
begin
  { Ctx.Payload lives in the worker's own arena and dies with the job.
    Write this the way you would write a controller. }
  M := Mail.Message_;
  M.AddTo(Ctx.Payload.ToString).Subject('Welcome').Text('...');
  Mail.Send(M);
end;
```

| | |
|---|---|
| `Ctx.Name` | The job name |
| `Ctx.Payload` | `TStr`, in the worker's arena |
| `Ctx.Attempt` | Which attempt this is, from 1 |
| `Ctx.Arena` | The worker's arena |

`askr make job <Name>` writes the skeleton.

## The two copies

PRD rule two: **background jobs never borrow the request's arena, they get
their own.** Here is why that cannot be a convention.

When a controller pushes, the payload lives in the request arena. The
request is finished long before the job runs — the arena has been reset and
the memory handed to a new request. A job pointing there reads another
user's data.

```
request arena  ->  heap        (in Push, while the caller still owns the bytes)
               ->  worker arena (in the worker, before the handler is called)
```

Neither copy can be skipped. The first detaches the job from the request.
The second gives the handler a payload with the same lifetime as everything
else it works with, so it can be written exactly like a controller. The
worker resets its arena between jobs, as HTTP workers do between requests.

## Failure and retries

```pascal
SetQueue(TQueue.Create(4, 3));      { 3 attempts }
Queue.OnError := @LogJobFailure;
```

A handler that raises is retried with **exponential backoff**, capped at 30
seconds, until `MaxAttempts` is used up. `OnError` is called for every
failure, not only the last.

## Counters

```pascal
Queue.Pending;
Queue.Processed;  Queue.Retried;  Queue.Failed;  Queue.Dropped;
Queue.Workers;
Queue.Durable;
```

```sh
askr queue:status
```

`Dropped` counts jobs with no registered handler — a `Handle` line that was
lost.

## Stopping

```pascal
Queue.Stop;              { drains: waits until empty }
Queue.Stop(False);       { discards what is left }
Queue.WaitUntilEmpty(5000);
```

`WaitUntilEmpty` returns when no job is waiting **and none is running**, so
what the last job did is there to be checked. It is for tests.

## Durable jobs

The in-process queue loses everything on restart. A welcome email that was
never sent because someone deployed a new version is not a performance
detail — it is data that is gone.

```pascal
uses Askr.Queue.Db;

Store := TDbJobStore.Create(Cfg('database.url'));
Store.EnsureSchema;                     { askr_jobs, askr_failed_jobs }
SetQueue(TQueue.Create(Store, 4));
Queue.Handle('send-welcome', @SendWelcome);
Queue.Start;
```

Handlers are unchanged. `TQueue` and the workers are unchanged. **The only
thing that swaps is where the jobs live**, and that is deliberate: a
separate worker loop for durable jobs would give two sets of rules for
backoff, attempt counting and arena lifetime, and the two would drift apart.

The jobs go in the database the app already has. The transaction that saved
the order can be the one that queued the job.

### Four things that are choices

**The payload is text**, JSON in practice. Raw bytes are rejected at `Push`
rather than being silently mangled on the way into a `TEXT` column — a NUL
byte raises with the job name in the message.

**A job that gives up is moved to `askr_failed_jobs`, not deleted.** It is
the only trace that something was supposed to happen and did not.

```pascal
Store.FailedCount;
Store.RetryFailed;      { put them back in the queue }
Store.ClearFailed;
```

A job with no registered handler goes there too. In the in-process queue it
simply disappears — a real difference between the two.

**An abandoned reservation is released after five minutes.** If the process
dies mid-job, the row would otherwise stay reserved forever.

```pascal
Store.VisibilityMs := 10 * 60 * 1000;
```

**The attempt counter is in the row**, not in memory, so a restart mid-job
does not reset it to zero.

### Concurrency

`FOR UPDATE SKIP LOCKED` in Postgres and MySQL 8; an immediate transaction
in SQLite, which has a single writer anyway. Measured with **200 jobs and
six workers** against both servers: no job ran twice, none was skipped.

> Worth knowing: that test does **not** prove the guards are necessary.
> Remove both `FOR UPDATE SKIP LOCKED` and the `AND reserved_at IS NULL`
> guard on the UPDATE and it still passes — the window between SELECT and
> UPDATE is too narrow to hit. Put a `Sleep(5)` in that window and six of
> two hundred jobs run twice. That has been tried. The reservation holding
> is proven deterministically in the SQLite tests.

### Polling

```pascal
Store.Poll := 250;      { milliseconds, the default }
```

A worker with no work asks the database every time it wakes. Four workers at
20 ms would be 200 queries a second against an empty table. The in-process
store is signalled on push and can afford 20 ms; the database store cannot,
and a job pushed by another process does not signal at all.

## Running the queue separately

```sh
askr queue:work
```

You do not need it — the app process can serve HTTP and run the queue at the
same time, which is the whole point of having no sidecars. It exists for
when you want to scale them apart.

## What is not here

**Horizon.** A status endpoint in the app gives the same thing without an
app to operate, and "no sidecars" is a PRD principle.

**Job batches and chains.** Not built.
