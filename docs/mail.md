# Mail

```pascal
uses Askr.Mail;

SetMail(TMailer.Create(
  TSmtpTransport.Create(Cfg('smtp.host'), 587, smtpStartTls)));
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

## The message

| | |
|---|---|
| `From(address, name)` | Overrides the default |
| `AddTo`, `Cc`, `Bcc` | Repeatable |
| `Subject`, `Text`, `Html` | |
| `Header(name, value)` | Anything else |
| `Render` | The RFC 5322 text, for tests |

With both `Text` and `Html` the message becomes `multipart/alternative`.

**Bcc recipients receive the mail but do not appear in the head.** That is
the whole point of Bcc, and getting it wrong reveals the list to everyone on
it.

## Transports

| | |
|---|---|
| `TSmtpTransport` | A real server |
| `TLogTransport` | Writes to a file — for development |
| `TNullTransport` | Counts and keeps the last message — for tests |

```pascal
SetMail(TMailer.Create(TLogTransport.Create('storage/mail.log')));
```

```pascal
T := TNullTransport.Create;
SetMail(TMailer.Create(T));
...
AssertEqual(T.Count, 1, 'one mail sent');
AssertTrue(Pos('Welcome', T.LastMessage) > 0, 'right subject');
```

## Encryption

```pascal
TSmtpTransport.Create(Host, 587, smtpStartTls);    { the default }
TSmtpTransport.Create(Host, 465, smtpTlsDirect);   { TLS from the first byte }
TSmtpTransport.Create(Host, 25, smtpPlain);        { a local relay, and nothing else }
```

**STARTTLS is the default, and plaintext has to be chosen.** A setup that
silently falls back to plaintext is worse than one that stops and says so:
if the server does not offer STARTTLS, the send is aborted.

```pascal
T.VerifyPeer := False;      { self-signed certificates in test only }
```

A client that does not verify has encryption but no idea who it is talking
to.

STARTTLS needs OpenSSL. See [TLS](tls.md), and note that **on macOS you must
install it yourself**.

## Name resolution

Worth knowing if you touch it: `Askr.Mail` uses **both** functions in
`netdb`. `GetHostByName` reads `/etc/hosts` and returns the address in host
byte order; `ResolveHostByName` does DNS and returns it in network order.
Getting that wrong gives an address that looks valid and points the wrong
way.

(The HTTP client went a different way and uses `getaddrinfo` from libc —
see [HTTP client](http-client.md).)

## Sending from a queue

Mail is the archetypal background job. Do not block a request on an SMTP
handshake:

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
  M.AddTo(Ctx.Payload.ToString).Subject('Welcome').Text('...');
  Mail.Send(M);
end;
```

With a [durable queue](queue.md) that mail survives a restart.

## What is not here

**Templates.** Messages are built with string concatenation. A small
template interpreter for mail is a real need and is on the list; a full
templating engine is not, because Inertia covers pages.
