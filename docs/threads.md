# Threads

A thread in Free Pascal that raises out of its `Execute` just ends. The
exception is kept in `FatalException`, nobody reads it, and whatever the
thread did stops being done. Askr's own background threads -- the queue's
workers, the scheduler, every server-sent event stream and every websocket
-- are `TSupervisedThread`s instead. The idea is Erlang's supervisor, as
Phoenix inherits it.

```pascal
uses Askr.Core.Supervisor;

type
  TIndexer = class(TSupervisedThread)
  protected
    procedure Run; override;
  end;

procedure TIndexer.Run;
begin
  while not Terminated do
  begin
    IndexWhatChanged;          { may raise: the database was gone }
    Sleep(1000);
  end;
end;

Indexer := TIndexer.Create('app.indexer', rpOnCrash);
```

The work goes in `Run`. Returning from it is the thread done; raising is
a crash.

## What a crash does

| Policy | On a crash | Used by |
|---|---|---|
| `rpOnCrash` | logs it and starts `Run` again, after a backoff | the queue's workers, the scheduler |
| `rpNever` | logs it, and the thread ends | streams and websockets |

A stream or a websocket is not restarted because its connection went
with it. The browser reconnects on its own.

**The backoff doubles**, from 100 ms to 30 s. A run that lasted thirty
seconds without a crash resets it, so a thread that falls over once a day
is not made to wait the half-minute a crash loop earns.

**It restarts only while `Wanted` says so.** `Wanted` returns `not Terminated`
by default. Override it when the owner keeps its own flag, as the queue
does, so a stop is never answered by a restart. A thread waiting out its
backoff checks `Wanted` every 20 ms, so the owner's `WaitFor` does not wait
thirty seconds.

## What it fixed in Askr

Three of these threads could end silently before 0.18.0:

- **The scheduler.** A push to a durable queue whose database was gone
  for a moment ended the scheduler's thread. Every scheduled job then
  stopped until the process restarted. Now the thread starts again. The
  entry whose push failed was not advanced, so it runs on the first tick
  after the restart.
- **A queue worker whose `OnError` raised.** The worker ended, and took
  its share of the queue with it. On the no-handler path it also left the
  job counted as running, so `WaitUntilEmpty` waited for it. Now the
  worker restarts. `OnError` is told only after the job has been retried,
  failed or dropped, so a raising `OnError` cannot leave a job unsettled.
- **A websocket whose `Opened` raised.** The connection was closed, but
  nothing said why. Now it is a log line and a count.

## Seeing it

Every crash is:

- **a log line at `error`**, with the thread's name, the exception's class
  and message, and when it restarts;
- **an `askr.thread` event** with `thread`, `outcome` (`restarted` or
  `ended`), `error` (the exception's class, never its message, like every
  [telemetry](telemetry.md) event), `restarts` and `in_ms`;
- **a count by name**, from `SupervisedThreads`: running now, crashes,
  restarts, and the last crash's class and time.

The count is by name, not by thread, so a stream that crashed and was
freed a minute ago is still there, and a hundred streams make one line.
The [dashboard](dashboard.md) shows it.

| Name | Thread |
|---|---|
| `askr.queue` | a queue worker |
| `askr.scheduler` | the scheduler |
| `askr.stream` | a server-sent event stream |
| `askr.websocket` | a websocket connection |

## What it does not do

- **It does not restart a process.** A crash that takes the process down
  -- a segfault in a C library, a failed allocation -- is for systemd,
  Docker or whatever runs the binary. `Restart=always` is still the outer
  supervisor.
- **It has no supervision tree.** Nothing escalates. A thread that keeps
  crashing keeps restarting, thirty seconds apart, and says so every time.
  In Erlang that would be where its supervisor gives up and fails upward.
  Here it is where someone reads the log.
- **It does not guard the HTTP workers.** Their loop already catches what
  a handler raises and answers 500. A crash there is a bug in Askr, not in
  the app.
