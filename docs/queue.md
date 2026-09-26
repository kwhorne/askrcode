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
| `Ctx.Last` | True when a failure now is final — no attempt comes after it |
| `Ctx.Arena` | The worker's arena |
| `Ctx.BatchId` | The [batch](#batches) this job belongs to, or `''` |
| `Ctx.Queue` | The queue running it |

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

When the store itself fails — a database that is busy, or gone for a
moment — the worker logs it, tells `OnError` (`the job store failed: …`)
and carries on. A job that ran and whose store then failed to record it
is not a job that failed, and is not retried as one; a durable store's row
stays reserved until the visibility timeout lets it go.

## Chains

```pascal
Queue.Chain
  .Add('resize-photo', Id)
  .Add('upload-photo', Id)
  .Add('tell-owner', Id)
  .OnFailure('photo-failed', Id)
  .Push;
```

The steps run **one after another**, each only when the one before it has
succeeded, however many workers are free. A step that fails is retried like
any job; when its last attempt fails, the steps after it never run and
`OnFailure` is queued, once.

A chain is one job at a time: the first step, carrying the rest. When it
succeeds, the rest goes back in the queue as a chain of its own. So each
step gets the queue's retries, and a chain in a durable store survives a
restart between two steps — tested by queuing a chain, dropping the queue
without running it, and starting another on the same database.

Each step is an ordinary job, with an ordinary handler and payload.

## Batches

```pascal
B := Queue.Batch('import customers.csv');
for Row in Rows do
  B := B.Add('import-row', Row);
Id := B.OnSuccess('import-done', FileId)
       .OnFailure('import-failed', FileId)
       .Always('import-finished', FileId)
       .Push;
```

The jobs run **side by side**, and the batch knows when they are all done:

| | |
|---|---|
| `OnSuccess` | When every job has succeeded |
| `OnFailure` | When the first job has failed for good — once, however many fail |
| `Always` | When every job has run, however it went |

A job that fails and then succeeds on a retry has not failed: the batch
waits for the attempt after it. The rest of the batch keeps running after
a failure — for an import, one bad row is no reason to drop the others.
To stop it, cancel it:

```pascal
Queue.CancelBatch(Ctx.BatchId);           { from OnFailure, or a job }
```

The jobs not yet started are skipped; those running finish. `OnSuccess` is
not queued, `Always` is.

Every job and every callback of a batch has `Ctx.BatchId`, and the state
can be read for a progress bar:

```pascal
if Queue.BatchStatus(Id, S) then
  Percent := (S.Total - S.Pending) * 100 div S.Total;
```

`TBatchState` has `Total`, `Pending`, `Failed`, `Cancelled` and
`Finished`. A batch with no jobs has succeeded the moment it is pushed.

**Which job was the last is decided in the store, in one step.** Two
workers settling the last two jobs at once must not both think they
finished the batch, or neither. In the process it is a lock; in a database
it is a conditional `UPDATE`, whose row count says who won — the same in
all three dialects, without `SELECT … FOR UPDATE`. Measured with 240 jobs
on six workers against Postgres and MySQL: each callback once.

**At least once, like every job.** A job that finished and was counted,
in a process that died before the job was marked done, runs again after a
restart. Its second settling is not counted: the count does not go below
nothing. The batch is made before its jobs are queued; a process that dies
halfway through queuing them leaves a batch that waits for jobs that are
not there.

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
Store.EnsureSchema;                     { askr_jobs, askr_failed_jobs, askr_job_batches }
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
in SQLite, which has a single writer anyway. Immediate matters: a deferred
transaction reads under a snapshot and asks for the write lock at the
`UPDATE`, and in WAL mode a worker another worker has written past gets
`database is locked` at once, without waiting for the busy timeout. Measured with **200 jobs and
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

**A chain inside a batch, or a batch inside a chain.** Each is one of
the two. A chain step can push a batch of its own, and a batch's
`OnSuccess` can push a chain.

**Pruning batches.** A durable batch's row stays in `askr_job_batches`.
Delete finished ones older than you care about from the
[scheduler](scheduler.md). In the process, the last thousand finished
batches are kept.
