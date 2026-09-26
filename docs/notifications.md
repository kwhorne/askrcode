# Notifications

Telling a person something, on the channels they are reached on: an order
has shipped, a payment failed, someone replied. A notification says *what*
to tell; `Via` says *where*, for each person; the channels do the sending.

```pascal
uses Askr.Notify, Askr.Notify.Db, Askr.Notify.Sms;

type
  TOrderShipped = class(TNotification)
  private
    FOrderId: Int64;
  public
    function Via(const N: TNotifiable): TStringArray; override;
    function ToMail(const N: TNotifiable): TMailMessage; override;
    function ToSms(const N: TNotifiable): string; override;
  published
    property OrderId: Int64 read FOrderId write FOrderId;
  end;

function TOrderShipped.Via(const N: TNotifiable): TStringArray;
begin
  Result := [ChannelMail, ChannelDatabase];
  if N.Phone <> '' then
    Result := Result + [ChannelSms];
end;

function TOrderShipped.ToMail(const N: TNotifiable): TMailMessage;
begin
  Result := Mail.Message_.Subject(Trans('orders.shipped', ['id', OrderId]))
    .Template('order-shipped', ['id', OrderId]);
end;

function TOrderShipped.ToSms(const N: TNotifiable): string;
begin
  Result := Trans('orders.shipped_sms', ['id', OrderId]);
end;
```

```pascal
{ a handler }
Notice := TOrderShipped.Create;
Notice.OrderId := O.Id;
NotifyLater(NotifiableFor(U.Id, U.Email).WithName(U.Name).WithPhone(U.Phone), Notice);
```

## Who is told

Askr does not own your user model, so a `TNotifiable` is a record you fill:

| | |
|---|---|
| `Id` | Your user id, as text — the one `Login` takes. Empty for someone who is not a user. |
| `Name`, `Email` | For the mail. |
| `Phone` | E.164, `+4791234567`, for a text message. |
| `Slack` | An incoming webhook. Empty uses `slack.webhook`. |
| `Locale` | The language it is written in. |

`NotifiableFor(Id, Email)` starts one, and `WithName`, `WithPhone`,
`WithSlack` and `WithLocale` add the rest. Someone who is not a user — the
people on call, an address from a form — is a notifiable with no id:

```pascal
Notify(NotifiableFor('', '').WithSlack(OpsWebhook), Alert);
```

**The locale is set while the notification is written**, on every channel,
and put back afterwards. A queue worker has no request to take a language
from, so a notification written in the recipient's language needs
`WithLocale` — keep the locale on the user.

## Now, or in the queue

`Notify(N, Notice)` sends before it returns. `NotifyLater(N, Notice)`
queues it:

```pascal
UseNotificationQueue(Queue);   { at startup, where the workers run }
```

`NotifyLater` queues **one job per channel**. A text message that fails is
retried by the queue without the mail going out a second time. `Via` is
asked when `NotifyLater` is called, while the request knows what the
person has chosen; the worker builds the notification again from its
published properties and sends on the one channel its job is for.

What crosses the queue is what crosses it for [events](events.md) —
strings, numbers, booleans, enumerations and dates — because a
notification *is* an event. A class with anything else published is
refused where `NotifyLater` is called, and the property is named. Keep
ids, not objects.

A worker in another process of the same binary finds the class by name:
`RegisterNotification(TOrderShipped)` at startup there, if it may get
notifications it never sent.

Both take an array, too — `Notify([Ada, Bo], Notice)` — and one person who
cannot be told is no reason for the rest not to be.

## Sent twice, or not

Every job for one person carries the same **uid**, made when the
notification was queued:

- **Mail** uses it as the idempotency key, `notification-<uid>`, unless
  `ToMail` set one. [Resend](mail.md#resend) refuses a second send with the
  same key, so a job retried after Resend accepted the mail does not send
  two. SMTP has no such thing.
- **The database** uses it as the row's key. A retry that finds the row
  there is done.
- **Slack and SMS have no key.** A job retried after Slack or Twilio took
  the message, but before the answer came back, sends it twice. That is
  the provider's API, and it is said here rather than hidden.

## When a channel fails

`Notify` tries **every** channel before it raises. A text message that
could not go is no reason for the row in the database not to be written,
and the exception afterwards names each channel that failed:

```
TOrderShipped to user 7 did not go by sms: "91234567" is not a phone number…
```

Queued, each channel is its own job, with the queue's retries and — for a
durable queue — its failed table.

A channel name nothing has registered raises **before anything is
sent**, where `Notify` or `NotifyLater` is called. Use the constants —
`ChannelMail`, `ChannelDatabase`, `ChannelSlack`, `ChannelSms` — and the
compiler catches a typo in them.

`Via` raises unless it is overridden: a notification that goes nowhere
should be one somebody chose. An override may give `[]` for someone who
wants nothing.

## Mail

Built in. `ToMail` returns a `TMailMessage`, built the way any mail is —
[templates](mail.md#templates) included — and it goes to `N.Email` and
`N.Name` unless it has recipients of its own. It is sent through the
app's mailer, so `FakeMail` sees it.

## The database

For the bell in the corner of the page.

```pascal
uses Askr.Notify.Db;

Notes := UseDatabaseNotifications(Pool);   { at startup }
```

`ToDatabase` gives a JSON object, and by default it is the published
properties. The table, `notifications`, is made the first time it is
needed, so the app starts with the database down.

```pascal
Rows := DatabaseNotifications.ListFor(Auth.Id, True);   { unread, newest first }
Count := DatabaseNotifications.UnreadCount(Auth.Id);
DatabaseNotifications.MarkRead(Auth.Id, Req.Param('id'));
DatabaseNotifications.MarkAllRead(Auth.Id);
DatabaseNotifications.Delete(Auth.Id, Req.Param('id'));
Result := RespondJson(NotificationsJson(Rows));             { for the bell to fetch }
```

**Every read and write names whose.** `MarkRead` and `Delete` take the
owner's id beside the notification's, and one that belongs to someone
else is not found: a controller that passes the id from the URL straight
on cannot mark another user's. `NotificationsJson` gives `id`, `kind` —
the class it was sent as — `data` as the object it is, and `created_at` and
`read_at` in ISO 8601, `read_at` null while unread.

Inside a request the request's own connection is used; a queue worker
borrows from the pool.

## Slack

```pascal
uses Askr.Notify.Slack;   { registers the channel }

function TDeployFailed.ToSlack(const N: TNotifiable): string;
begin
  Result := 'Deploy of ' + Commit + ' failed';
end;
```

Over an [incoming webhook](https://api.slack.com/messaging/webhooks): the
recipient's `Slack`, or `SLACK_WEBHOOK`. Text goes as `{"text": ...}`;
something that starts with a brace goes as it is, for blocks.

**The webhook URL is a secret** — anyone who has it can post. It is in no
error and no log line; an error says what Slack answered, which is a word
like `no_service`. The HTTP client's own errors quote the URL they were
given, and the channel takes it out of them. It has to be HTTPS, except to
this machine.

## Text messages

```pascal
uses Askr.Notify.Sms;     { registers the channel }

SetSms(SmsFromConfig);    { at startup }
```

```sh
SMS_DRIVER=twilio         # or log, the default
TWILIO_SID=AC…
TWILIO_TOKEN=…
TWILIO_FROM=+15005550006  # or a Messaging Service, MG…
```

`log` writes each message to `storage/logs/sms.log`, for development.
`twilio` sends through Twilio's REST API. Another provider is a
`TSmsTransport` with a `Send`.

**A number is E.164 or it is refused** before anything goes out: a plus, a
country code, the rest — 8 to 15 digits in all. `+47 912 34 567`,
`91234567` and `004791234567` are all refused. A number written for a
person would reach the provider, which charges for the attempt.

A Twilio error comes back as `ESmsError`, with Twilio's own code —
`21211` for a number it will not send to — and never the token.

**No message has been sent through Twilio from here.** The request is held
to Twilio's documented form by a test that reads the bytes sent to a
local server: the path, Basic auth, every field encoded. That the
request has the right form is proven; that Twilio delivers it is not, and
it is said until someone has done it with a real account.

## A channel of your own

```pascal
type
  TPushChannel = class(TNotificationChannel)
    procedure Send(const N: TNotifiable; Notice: TNotification;
      const Uid: string); override;
  end;

RegisterChannel('push', TPushChannel.Create);
```

`Send` gets the person, the notification and the uid. What it asks the
notification for is up to it — cast to a class or an interface of your
own.

## Testing

```pascal
FakeNotifications([TOrderShipped]);
try
  PlaceOrder(...);
  AssertEqual(NotificationsSent(TOrderShipped, '7'), 1, 'the customer was told');
  AssertEqual(SentNotificationChannels(TOrderShipped), 'mail,database,sms', 'every way');
  AssertContains(SentNotificationJson(TOrderShipped), '"OrderId":42', 'about the order');
finally
  StopFakingNotifications;
end;
```

Faked, nothing is sent and nothing is queued — `NotifyLater` needs no
queue — but `Via` is asked and each channel's `To…` is called and thrown
away. A notification that would fail for real fails in the test.

## What is not here

**Pushing a notification to the browser** as it arrives. That is a
channel of your own, a few lines that call `Broadcast` from
[real time](realtime.md) on the user's channel.

**Pruning.** Rows stay until they are deleted. Delete read ones older
than you care about from the [scheduler](scheduler.md).

**Preferences.** Which channels a person wants is your data; `Via` reads
it.

**Other providers** — Vonage, MessageBird, Discord, Teams, push. Each is a
channel or an SMS transport of a few dozen lines, and none is here until
it can be held to something.
