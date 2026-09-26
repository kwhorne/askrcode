# Server-sent events

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

## The process's, not the server's

Streams belong to the process: `Broadcast` reaches every stream, whichever
server opened it, and stopping a server closes them all. A process runs one
server.

## What is not here

**Broadcasting across processes.** `Broadcast` reaches the streams of this
process. Behind a load balancer with several processes, a browser connected
to one does not hear what the other broadcast — send events through the
durable queue to every process, or run one process.

**WebSockets.** A stream goes one way, server to browser, which is what
notifications, progress and live lists need, and it is plain HTTP that
proxies and `EventSource` already understand. What the browser sends goes
in an ordinary request.
