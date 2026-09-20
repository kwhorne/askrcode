# Scheduler

```pascal
uses Askr.Scheduler;

SetSchedule(TScheduler.Create(Queue));

Schedule.EveryMinutes(5, 'poll-inbox');
Schedule.Hourly('warm-cache');
Schedule.DailyAt(3, 30, 'nightly-report');
Schedule.WeeklyAt(dowMonday, 8, 0, 'weekly-digest');
Schedule.MonthlyAt(1, 6, 0, 'invoice-run', Payload);
Schedule.EverySeconds(30, 'heartbeat');

Schedule.Start;
```

## It dispatches; it never executes

**The scheduler pushes to the queue and never runs anything itself.**

Do not "simplify" that to running the job directly. It would give two
execution paths with their own lifetime rules — one with a worker arena and
one without — and they would drift apart. Same reason the durable queue
reuses `TQueue` rather than having its own loop.

It follows that the scheduler needs a queue, and that a scheduled job is an
ordinary job: `Queue.Handle('nightly-report', @NightlyReport)`.

## UTC

**The next run time is computed in UTC.** Local time would give two runs or
none at the daylight-saving change.

A `DailyAt(3, 30, ...)` is 03:30 UTC. If you need local wall-clock time, you
need a timezone database, and Askr does not ship one.

## Overlap

```pascal
Schedule.SkipWhenPending;
```

Skips a dispatch when the same job is still queued. Without it, a job that
takes longer than its interval piles up.

## Running it

```pascal
Schedule.Start;     { a thread that ticks }
Schedule.Stop;
```

```pascal
N := Schedule.Tick;     { dispatch what is due, once; returns how many }
```

`Tick` is what `askr schedule:run` calls — one pass, for a cron that drives
the app from outside instead of letting it tick itself.

```sh
askr schedule:list
askr schedule:run
```

## Inspecting

```pascal
Schedule.Count;
Schedule.Describe(Lines);
Schedule.Ticks;  Schedule.Dispatched;
```
