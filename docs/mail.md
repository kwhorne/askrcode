# Mail

```pascal
uses Askr.Mail, Askr.Mail.Resend;

SetMail(TMailer.Create(MailFromConfig));
Mail.SetDefaultFrom('noreply@example.com', 'Shop');
```

```pascal
M := Mail.Message_;
M.AddTo('ada@example.com', 'Ada')
 .Subject('Welcome')
 .Text('Plain text for the clients that want it.')
 .Html('<p>And HTML for the rest.</p>');
Mail.Send(M);
```

`Send` frees the message unless you pass `False`. The builders return the
message, so they chain.

## Picking a transport

`MailFromConfig` reads `MAIL_TRANSPORT` and builds the right one, so
moving from a log file in development to a real provider in production is
a config change rather than a code change.

| `MAIL_TRANSPORT` | What it does |
|---|---|
| `log` (default) | Writes the message to `MAIL_LOG`, sends nothing |
| `resend` | Resend's HTTP API — needs `Askr.Mail.Resend` linked in |
| `smtp` | A real SMTP server |
| `null` | Discards everything |

```sh
MAIL_TRANSPORT=log            # development: read storage/mail.log
MAIL_FROM=noreply@example.com
```

**An unknown name is an error, not a fallback.** `MAIL_TRANSPORT=resnd`
stops the app at startup and lists what it does know. The alternative —
quietly writing production mail to a log file nobody reads — looks exactly
like everything working.

That also means the failure comes at boot, not at the first password
reset three days later.

If you would rather construct it yourself, every transport is still an
ordinary class:

```pascal
SetMail(TMailer.Create(TResendTransport.Create('re_...')));
SetMail(TMailer.Create(TLogTransport.Create('storage/mail.log')));
```

## Resend

```sh
MAIL_TRANSPORT=resend
RESEND_API_KEY=re_...
MAIL_FROM=noreply@example.com     # on a domain you verified at resend.com
```

That is the whole setup. The unit has to be linked in — `uses
Askr.Mail.Resend` — because that is what makes the name `resend` exist;
`askr new --auth` writes it for you.

**The key is never logged and never printed.** `Describe` gives
`resend (https://api.resend.com)` and nothing else, so it is safe in a bug
report.

A successful send logs one line with the provider's id:

```
INFO mail sent provider=resend id=49a3999c-… recipients=1
```

That id is what you search for in Resend's own dashboard when someone asks
whether a receipt went out. Addresses are not logged — they are personal
data, and a delivery log is not the place for them.

### Errors tell you whether to try again

```pascal
try
  Mail.Send(M);
except
  on E: EResendError do
    if E.Retryable then
      raise            { let the queue back off and retry }
    else
      LogException(E, 'mail rejected');
end;
```

`E.Status` is the HTTP status and `E.Name_` is Resend's own error type,
unchanged: `validation_error`, `rate_limit_exceeded`, `missing_api_key`.

`Retryable` is the framework's reading of it, and the distinction that
matters is inside the 429s: **a rate limit passes, a quota does not.**
Resend allows 10 requests a second, and a job that waits a moment gets
through. `daily_quota_exceeded` will not resolve within any backoff a
queue has, so it goes to the failed-jobs table where a person sees it
instead of burning every attempt first.

5xx is retryable. A validation error never is — the same message will be
rejected the same way.

### Sending the same mail twice

```pascal
M.Idempotency('order-' + Order.Id + '-receipt');
```

This is the reason to use the HTTP API rather than SMTP. A queued job that
fails *after* Resend accepted the message gets retried, and without a key
that survives the retry the customer gets two copies.

Set it to something that is **the same on a retry** — an order number, the
job's id — never something random. Without one, Askr falls back to the
message's `Message-ID`, which is stable for the same `TMailMessage` object
but not for a job that rebuilds the message from scratch. That fallback
covers a retry in the same process; the explicit key covers the case that
actually happens.

Resend honours the key for 24 hours. `TSmtpTransport` ignores it.

### What maps to what

| Askr | Resend |
|---|---|
| `From`, `AddTo`, `Cc`, `Bcc` | `from`, `to`, `cc`, `bcc` |
| `Subject`, `Text`, `Html` | `subject`, `text`, `html` |
| `Header('Reply-To', …)` | `reply_to` — moved out of `headers` |
| Any other `Header` | `headers` |
| `Idempotency(key)` | `Idempotency-Key` |

Reply-To is lifted out deliberately: Resend has a field for it and refuses
it as a free header, so leaving it in both places would make it a coin
toss which one won.

## SMTP

```sh
MAIL_TRANSPORT=smtp
MAIL_HOST=smtp.example.com
MAIL_PORT=587
MAIL_USERNAME=…
MAIL_PASSWORD=…
MAIL_ENCRYPTION=tls     # tls (STARTTLS) | ssl (port 465) | none
```

```pascal
T := TSmtpTransport.Create(Host, 587, smtpStartTls);
T.Credentials(User, Password);
```

**STARTTLS is the default, and plaintext has to be chosen.** A setup that
silently falls back to plaintext is worse than one that stops and says so:
if the server does not offer STARTTLS, the send is aborted.

**The password is never sent over an unencrypted connection.** AUTH PLAIN
and AUTH LOGIN both put it on the wire in base64, which is not encryption.
With `MAIL_ENCRYPTION=none` and a username set, Askr refuses rather than
hands the password to anyone watching. If the relay really is on loopback:

```pascal
T.AllowPlainAuth := True;
```

PLAIN is preferred over LOGIN — one round trip instead of three — and a
server that offers neither is an error rather than a guess.

```pascal
T.VerifyPeer := False;      { self-signed certificates in test only }
```

A client that does not verify has encryption but no idea who it is talking
to.

STARTTLS needs OpenSSL. See [TLS](tls.md), and note that **on macOS you
must install it yourself**. Resend needs it too, for the same reason —
`Askr.Mail.Resend` goes over HTTPS.

## The message

| | |
|---|---|
| `From(address, name)` | Overrides the default |
| `AddTo`, `Cc`, `Bcc` | Repeatable |
| `Subject`, `Text`, `Html` | |
| `Header(name, value)` | Anything else |
| `Idempotency(key)` | For providers that support it |
| `Render` | The RFC 5322 text, for tests |

With both `Text` and `Html` the message becomes `multipart/alternative`.

**Bcc recipients receive the mail but do not appear in the head.** That is
the whole point of Bcc, and getting it wrong reveals the list to everyone
on it.

A name is always quoted. A comma in an unquoted name splits the address
field in two, and then the wrong person gets the mail.

## Testing

```pascal
T := TNullTransport.Create;
SetMail(TMailer.Create(T));
...
AssertEqual(T.Count, 1, 'one mail sent');
AssertTrue(Pos('Welcome', T.LastMessage) > 0, 'right subject');
```

For the Resend path specifically, `TFakeResendHttp` lets you check the
request without sending anything:

```pascal
H := TFakeResendHttp.Create;
T := TResendTransport.Create('re_test');
T.UseHttp(H);
H.Queue('{"id":"x"}', 200);
Mail.Send(M);
AssertTrue(Pos('"subject":"Welcome"', H.Sent[0]) > 0, 'subject went out');
```

Queue a non-2xx body to exercise the error path.

## Name resolution

Worth knowing if you touch it: `TSmtpTransport` uses **both** functions in
`netdb`. `GetHostByName` reads `/etc/hosts` and returns the address in host
byte order; `ResolveHostByName` does DNS and returns it in network order.
Getting that wrong gives an address that looks valid and points the wrong
way.

(The HTTP client went a different way and uses `getaddrinfo` from libc —
see [HTTP client](http-client.md). That is the path Resend takes.)

## Sending from a queue

Mail is the archetypal background job, and with a provider it is more
than a latency argument: a request that sends mail inline **fails with a
500 when the provider does**.

```pascal
Queue.Handle('send-welcome', @SendWelcome);
Queue.Push('send-welcome', Customer.Email);
```

```pascal
procedure SendWelcome(const Ctx: TJobContext);
var
  M: TMailMessage;
begin
  M := Mail.Message_;
  M.AddTo(Ctx.Payload.ToString).Subject('Welcome').Text('...')
   .Idempotency('welcome-' + Ctx.Payload.ToString);
  Mail.Send(M);
end;
```

With a [durable queue](queue.md) that mail survives a restart, and the
idempotency key makes the retry safe.

## What is not here

**No attachments.** `TMailMessage` has no attachment API, so neither
transport can send one. Adding it means `multipart/mixed` in `Render` as
well as the provider field, and it is not written yet.

**No templates.** Messages are built with string concatenation. A small
template interpreter for mail is a real need and is on the list; a full
templating engine is not, because Inertia covers pages.

**No Resend batch endpoint, tags, scheduling or audiences.** One message
per call. The batch endpoint is a throughput optimisation for people
sending thousands at once, and Askr has a queue for that.

**No webhook handling.** Resend can post delivery, bounce and complaint
events back to you. That is an ordinary route in your app, and what you do
with a bounce is a product decision.

**Only Resend, so far.** The transport interface is one virtual method
and the registry takes a name, so Postmark or SES is the same shape —
`Askr.Mail.Resend` is the worked example.
