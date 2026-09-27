# Dashboard

`/_askr` is what the app is doing, seen from inside it: the routes that
answered and how long they took, the statements that took the time, the
jobs by what became of them, mail sent and failed, and the pool, the queue
and the plugins as they are now. The idea is Phoenix's LiveDashboard.

```pascal
uses Askr.Dashboard;

UseDashboard(R, Cfg('app.env', 'local') = 'local', DbPool);
```

`askr new` writes that line in `app.lpr`, after `UsePlugins(R)`. The
second argument opens the page; the third is the app's pool, for its
gauges, and may be left out.

The page is in the binary. It is plain HTML, with no script, no npm and
nothing fetched, like the welcome page, and it works in an app that has
never run `npm install`. Refresh it to see it change.

## Who sees it

**Open is for development.** With `Open` false, the page answers only to a
signed-in user the gate `askr.dashboard` allows:

```pascal
function IsAdmin(const UserId: string; Resource: TObject): Boolean;
begin
  Result := UserId = '1';
end;

DefineGate('askr.dashboard', @IsAdmin);
```

To everyone else it is a 404, not a 403, so a probe learns no more than
it would from a path that was never there. Without the gate it answers
nobody. A gate that does not exist says no.

## What it shows

| Section | From |
|---|---|
| Requests, queries, failed queries, mail sent and failed | [telemetry](telemetry.md) since the process started |
| Pool in use | the pool you passed, as it is now |
| Jobs pending, jobs failed | the queue, when `SetQueue` has been called |
| Routes | each route by its pattern, with its requests, its 5xx responses, its average time and its slowest |
| Statements | the twenty with the most time in all, with runs, failures, average and slowest |
| Jobs | each job by name: done, retried, failed, dropped |
| Recent requests | the last fifty, newest first |
| Threads | the [supervised threads](threads.md) by name: running, crashes, restarts, the last crash's class and when |
| Plugins | the plugins `UsePlugins` started |

Statements are sorted by total time, not by their slowest run. A
statement that is fast and runs a hundred times on one page is the one
worth finding, and only its total shows it.

The dashboard's own requests are not in its numbers.

## Memory

Memory is fixed however long the process runs: fifty recent requests, and
at most two hundred routes, two hundred statements and a hundred jobs.
Anything past those limits is still counted in the totals. The page says
how many runs it counted but could not list.

## What it does not do

- **The numbers are this process's.** Two app servers behind a load
  balancer each have their own, and a restart starts from nothing. The
  dashboard is for looking now. For history, attach your own
  [telemetry](telemetry.md) handler and send the numbers somewhere that
  keeps them.
- **It can show values.** A statement sent with placeholders is shown as
  written, without its parameters. But a statement an app built by
  splicing a value into its text is shown with that value. That is why the
  page is closed outside development by default.
- **Every value is escaped.** SQL, paths, job and plugin names are
  HTML-escaped before they reach the page.
- **Nothing on it acts.** It has no buttons to retry a job or kill a
  query. A page behind a gate that can change things is a different page,
  with a different risk.
