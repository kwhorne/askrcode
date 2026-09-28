# Live props

A page that finds out its data went stale and fetches it again, without
the person looking at it doing anything. The server says which props have
changed; every page listening reloads those props, and only those.

<!-- check
type
  TOrder = class(TModel)
  private
    FId: Int64;
    FStatus: string;
  published
    property Id: Int64 read FId write FId;
    property Status: string read FStatus write FStatus;
  end;
  TOrders = class
    function Index(Req: TRequest): TResponse;
  end;
var
  G: TGrid<TOrder>;
  Q: TQuery<TOrder>;
-->

```pascal
uses Askr.Live;

{ the list's handler: this page listens on the orders channel }
function TOrders.Index(Req: TRequest): TResponse;
begin
  LiveOn(['orders']);
  Result := Inertia('Orders/Index', ['rows', G.Rows(Q), 'grid', G]);
end;

{ wherever an order changes: a handler, a job, the scheduler }
PropsChanged('orders', ['rows', 'grid']);
```

```svelte
<!-- the layout, once -->
<script>
  import { Flash, Live } from '@askrcode/lauf/inertia'
</script>

<Flash />
<Live />
```

`askr new` writes `UseLive(R)` in `app.lpr` and `<Live />` in the layout,
so a new app only needs the two Pascal calls.

The reload is an Inertia **partial reload**. The page keeps its scroll
position, what has been typed into a form, and an open menu, and a prop
the event did not name is not sent again. The idea is Phoenix LiveView's:
the server says when a view is out of date. It is done without a socket
per view and without view state kept on the server. The event names
props, and the page asks for them the way it would on any visit.

## Who may listen to what

**The page that was shown decides.** `LiveOn` signs the stream's URL
under `APP_KEY`: the channels, the signed-in user, and an expiry a day
away. The browser gets it as the `askrLive` prop. `/_askr/live` opens a
stream only for a URL signed here, for the user asking, before it expires.
Anything else is a 403.

There is no list of channels a browser may ask for, because the handler
that rendered the page already did the checking. A channel per user,
`'user.' + Id`, stays that user's. A copied URL is of no use to anyone
signed in as someone else.

**An event carries names, never values.** Everyone on a channel hears
it, so what changed is fetched through the page's own handler, with the
viewer's own authorisation. Data the viewer may not see is never in the
event in the first place.

## Not computing what is not asked for

A partial reload asks for some props, but the handler runs in full. When
a prop costs a query, ask first:

<!-- check
var
  Stats: Int64;
function CountByStatus: Int64; begin Result := 0; end;
-->

```pascal
if InertiaWants('Orders/Index', 'stats') then
  Stats := CountByStatus;
```

`InertiaWants` is false on a partial reload that asked for other props,
and true on every ordinary visit.

## Many changes at once

Events that arrive within 50 ms of each other become one reload, of all
the props they named. A job that touches three rows sends three events,
and the page asks once.

## What it does not do

- **It is not a socket per view.** The browser holds a
  [server-sent event stream](realtime.md) while the page is open, and a
  stream is a thread on the server. That is fine for hundreds of open
  pages, and it is why `LiveOn` is something a page asks for rather than
  something every page does. A page that does not call it opens nothing.
- **It does not merge.** The props are fetched again, whole. A list of
  ten thousand rows reloads ten thousand rows. Page the list, which
  [DataGrid](lists.md) does already.
- **Past the day the URL is signed for, the stream stops.** EventSource
  does not reconnect after a 403, so a tab left open for two days stops
  listening quietly instead of asking every three seconds. The next visit
  gets a new URL.
- **Across processes it needs the database driver.** `PropsChanged` is a
  `Broadcast`, and by default a broadcast reaches the streams of the
  process that sent it. With `BROADCAST_DRIVER=database`, a page on any
  process hears what changed on another. See
  [Real time](realtime.md#across-processes).
