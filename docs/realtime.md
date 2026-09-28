# Real time

Two ways for the server to talk to a browser without being asked: a
**server-sent event stream**, one way, for notifications, progress and live
lists; and a **websocket**, both ways, for what the browser has to say often
and fast. Both are fed by the same `Broadcast`.

## Server-sent events

<!-- check
type
  TFeed = class
    function Open(Req: TRequest): TResponse;
  end;
-->

```pascal
uses Askr.Http.Stream;

function TFeed.Open(Req: TRequest): TResponse;
begin
  Authorize('see-orders');
  Result := StreamEvents(['orders', 'user.' + Askr.Auth.Id]);
end;
```

```pascal
{ anywhere: a handler, a job, the scheduler }
Broadcast('orders', 'placed', '{"id":42,"total":"12.50"}');
```

```js
const feed = new EventSource('/feed')
feed.addEventListener('placed', (e) => show(JSON.parse(e.data)))
```

A stream is a response that does not end. The server keeps the connection
and writes an event down it whenever one is broadcast on a channel it
listens to. `EventSource` is built into every browser: it reconnects by
itself, and says which event it saw last.

## Who hears what

The route decides. `StreamEvents` takes the channels after the route's own
checks have run — `RequireAuth`, a gate, whatever it needs — so a channel per
user, `user.42`, is how one user's events stay theirs. A channel name is
letters, digits and `. _ : -`; anything else is refused.

`Broadcast(Channel, Event, Data)` goes to every stream on that channel,
from any thread. `Data` is text — JSON by convention — and may have line
breaks: each becomes a `data:` line, which `EventSource` joins back with
`\n`.

## A stream does not hold a worker

Askr's workers each follow one connection from start to finish. A stream
open for an hour would hold one for the hour, and a few hundred open tabs
would stop the server answering anything else. So the worker writes the
head and hands the socket — and the TLS connection, on an HTTPS server — to a
thread of the stream's own, and goes back to serving requests. The test for
this runs the server with **one** worker and requires a request to be
answered while a stream is open.

A thread per open stream is fine for hundreds. For tens of thousands of open
connections, put something built for holding them in front.

`SetMaxStreams(N)` caps them — 1000 unless set — and one more is answered
`503` with `Retry-After`.

## Reconnecting without losing anything

Every event has an id, and the last 500 are kept (`SetStreamReplay`). A
browser that reconnects sends `Last-Event-ID`, and gets the events after it
on its channels, in order, before anything new. The replay and joining the
list happen under one lock, so a broadcast cannot fall between them.

The stream starts with `retry: 3000`, which is how long `EventSource` waits
before it reconnects.

## Keeping it alive

A comment line goes down every open stream every fifteen seconds
(`SetStreamHeartbeat`). `EventSource` ignores it; a proxy sees traffic and
does not close a quiet connection; and a stream whose browser has gone finds
out, because the write fails, and closes.

The head carries `Cache-Control: no-cache, no-transform` and
`X-Accel-Buffering: no`. The second is for nginx, which otherwise holds the
events back to fill a buffer.

## WebSockets

<!-- check
type
  TRooms = class
    function Join(Req: TRequest): TResponse;
  end;
var
  Chat: TWsHandler;
-->

```pascal
uses Askr.Http.WebSocket;

type
  TChat = class(TWsHandler)
    procedure Text(C: TWsConnection; const Msg: string); override;
  end;

procedure TChat.Text(C: TWsConnection; const Msg: string);
begin
  Broadcast(C.Tag, 'said', Msg);
end;

function TRooms.Join(Req: TRequest): TResponse;
begin
  Result := AcceptWebSocket(Req, Chat, ['room.1'], Askr.Auth.Id);
end;
```

```js
const ws = new WebSocket(`wss://${location.host}/rooms/1`)
ws.onmessage = (e) => { const m = JSON.parse(e.data); ... }
ws.send('hello')
```

`AcceptWebSocket` answers the handshake — `101`, or `400` for a request that
is not one, `426` for another protocol version — and the worker hands the
connection to a thread of its own, as it does a stream. Bytes the client
sent right behind the handshake go with it.

- **The handler** is a `TWsHandler` with `Opened`, `Text`, `Binary` and
  `Closed`. It runs in the connection's thread, one message at a time, with
  an arena reset between messages. One handler object serves every
  connection, from as many threads, so it keeps no unguarded state of its
  own. An exception closes the connection with `1011` and is logged.
- **The session is not there.** The route passes what the connection needs
  — the user id above all, which it keeps as `UserId` — and `Tag` holds
  anything else.
- **The origin is checked.** A browser sends its cookies with a websocket
  handshake from any site, so a server that took it would let any page open
  a socket as the signed-in user. A handshake whose `Origin` is not
  `app.url`'s is refused `403`; `AddWebSocketOrigin` allows another. A
  client with no `Origin` is not a browser and has nobody else's cookies.
- **`Broadcast` reaches it** on the channels it was given or has `Join`ed, as
  a text message: `{"id":..,"event":..,"data":..}` with the data as the
  string it was broadcast as.
- `SendText`, `SendBinary` and `Close` are safe from any thread. A quiet
  connection gets a ping every 30 seconds (`SetWebSocketPing`), and one that
  stays silent through two is closed. A message over 1 MB
  (`SetWebSocketMaxMessage`) closes it with `1009`.

`./askr ws:check` runs the **Autobahn test suite** — the conformance suite
for websocket servers — against an echo server built on Askr: 247 cases of
framing, fragmentation, UTF-8, control frames and closing: 240 OK, three
informational ones that have no pass or fail, and four "non-strict", where
Autobahn would rather see invalid UTF-8 caught halfway through a fragmented
message than at its end. Compression and the
performance runs are left out, because Askr does not do them. What Autobahn
cannot send — an unmasked frame, a foreign origin — is in the socket test.

## The process's, not the server's

Streams and websockets belong to the process: `Broadcast` reaches every one,
whichever server opened it, and stopping a server closes them all. A process
runs one server.

## Across processes

With several app processes behind a load balancer, a browser connected to
one hears only what that one broadcast, unless broadcasts go through the
database:

```sh
BROADCAST_DRIVER=database
```

<!-- check
var
  DbPool: TDbPool;
-->

```pascal
uses Askr.Broadcast.Db;

SetBroadcasts(BroadcastsFromConfig(DbPool));   { askr new writes this }
```

Each broadcast is then a row in `askr_broadcasts` in the app's database,
and every process reads what the others wrote, a tenth of a second apart.
No Redis, for the same reason the durable queue and the database sessions
have none.

- **The row's id is the event's id.** A browser that reconnects to another
  process sends `Last-Event-ID`, and is replayed from the same numbers,
  because every process delivered every event under the id the database
  gave it.
- **The process that broadcasts delivers at once**, under the id it got
  back. It does not wait for its own poll, and it skips its own row when
  the poll comes round.
- **An id can commit after a larger one.** Two inserts at once take 10 and
  11, and 11 can commit first. An id a poll skipped is asked for again, by
  number, for five seconds, so it is delivered when it commits. A
  rollback leaves a hole that is never filled, and after five seconds it
  stops being asked for.
- **In a request, the row goes in on the request's own connection**, as the
  database sessions do, since a second connection from the same pool
  would deadlock. If that transaction rolls back, the other processes never
  hear it, and this one already did.
- **The table is made on first use**, so the app starts with the database
  down, and rows older than ten minutes are swept.

`./askr broadcast:check` holds it: two app processes on SQLite, Postgres
and MySQL. A stream on one hears what the other broadcast, the sender's
own stream hears it once, and a reconnect to the other process is
replayed from the id it got from the first. The same scenario with the
memory driver is the control, and must fail.

## What is not here

**A broker.** Across processes, broadcasts go through the app's database,
a tenth of a second behind. That suits a page telling its viewers that
something changed. It does not suit thousands of messages a second: every
process reads every row, and there is no fan-out cheaper than that here.

**Compression.** `permessage-deflate` is not offered, so a websocket
message goes as it is. Nothing is lost by it but bandwidth, and it keeps
zlib out of the binary.
