# Events

```pascal
uses Askr.Events;

type
  TUserRegistered = class(TEvent)
  private
    FUserId: Int64;
    FEmail: string;
  published
    property UserId: Int64 read FUserId write FUserId;
    property Email: string read FEmail write FEmail;
  end;
```

```pascal
{ at startup }
Listen(TUserRegistered, @AddToNewsletter);
ListenQueued(Queue, TUserRegistered, 'welcome-mail', @SendWelcome);

{ where it happens }
E := TUserRegistered.Create;
E.UserId := U.Id;
E.Email := U.Email;
DispatchEvent(E);
```

```pascal
procedure SendWelcome(E: TEvent);
var
  R: TUserRegistered;
begin
  R := TUserRegistered(E);
  ...
end;
```

The code that registers a user says what happened. It does not need to know
that a newsletter and a welcome mail follow, and neither of them needs to be
written into it.

## Now, or in the queue

**`Listen` runs the listener now**, inside `DispatchEvent`, before it
returns, in the order the listeners were registered. An exception from a
listener comes out of `DispatchEvent`: a listener that failed quietly is a
welcome mail nobody knows was never sent.

**`ListenQueued` runs it in the queue.** The event crosses as JSON, is built
again in a worker, and gets what every job gets: retries with backoff, and
the failed table when they run out. What should not hold up a request — a
mail, a call to somebody else's API — or should survive a failure, goes
there. The name is the job's name and has to be unique.

A listener for a class hears its subclasses too. A queued listener gets the
class that was dispatched, not the one it asked for, so a subclass's own
fields arrive as well.

`DispatchEvent` owns the event and frees it when every listener has had it.

## What crosses the queue

The published properties: strings, integers, `Int64`, booleans,
enumerations, `Currency`, floats and `TDateTime`. Each arrives exactly as it
was sent — `Int64` past 2^53, `Currency` to the fourth decimal, a `Double`
to the last bit, a `TDateTime` to the millisecond, and text outside ASCII.

**`ListenQueued` refuses anything else and names the property.** An object
or a list would arrive empty, and nothing would say so. Carry an id, not an
object: a model loaded in the request is not the row the worker sees a
second later.

A property the sender did not have — an event queued before a deploy that
added it — keeps what the constructor gave it. A class the worker does not
know fails the job, with a message that says so, rather than arriving as
some other class.

**With a durable queue, register what may arrive.** A worker finds the class
by its name. The class a listener asks for, and every class dispatched in
this process, are known already; but a job in the database can be taken by
another process of the same binary that never dispatched it. Call
`RegisterEvent(TBigOrderPlaced)` at startup for a subclass that is
dispatched to a queued listener. Two event classes with the same name are
refused: the queue could not tell them apart.

## Listening is set up once

Listeners are registered at startup, before the server takes requests. The
lists are read by every worker without a lock, so registering while requests
are running is not safe. `ClearListeners` forgets them all, for a test.

It is `DispatchEvent`, not `Dispatch`: inside a class, `Dispatch` is
`TObject.Dispatch`.

## Model events are something else

A model's `BeforeSave`, `AfterInsert` and the rest are virtual methods on the
model — see [Models](models.md). They are for what the model itself has to
do. An event is for what other code wants to hear about; a model's
`AfterInsert` is a good place to dispatch one.

## What is not here

**No wildcard or string-named events.** An event is a class, so the
compiler knows which fields a listener can read.

**No subscribers** — one class registering many listeners. A procedure that
calls `Listen` a few times is the same thing.

**No stopping propagation.** Every listener hears every event it asked for.
A listener that wants the others not to run is two concerns in one event.

**No events across processes, other than through the queue.** Telling a
browser that something happened is a different thing, and not this.
