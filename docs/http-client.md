# HTTP client

```pascal
uses Askr.Http.Client;

K := THttpClient.Create;
try
  K.WithBearer(CfgOrFail('api.token'));
  R := K.Get('https://api.example.com/v1/things');
  if R.Ok then
    Handle(R.Body);
finally
  K.Free;
end;
```

## Requests

```pascal
K.Get(Url);
K.Delete(Url);
K.Post(Url, Body);                          { application/json by default }
K.Put(Url, Body, 'text/plain');
K.Patch(Url, Body);
K.Request(Method, Url, Body, ContentType);
```

```pascal
K.WithHeader('X-Request-Id', Id);
K.WithBearer(Token);                        { Authorization: Bearer ... }
K.ClearHeaders;
```

Headers set on the client go with every request it makes.

## Responses

```pascal
R.Status;        R.Reason;      R.Ok;        { 200-299 }
R.Body;
R.Header('Content-Type');                    { case-insensitive }
R.HasHeader('Location');
R.IsJson;
R.FinalUrl;      R.Redirects;   R.ElapsedMs;
```

A 404 is **a response, not an exception**. Exceptions are for the request
never completing: DNS, connection, TLS, a malformed reply, a body over the
cap.

## TLS

**The certificate is verified — both the chain and the host name.**

The second is not a detail. `SSL_VERIFY_PEER` on its own accepts a genuine,
valid certificate for *any* domain, and then there is nothing left of the
protection. Both are checked, and that is proven against the real internet:
`wrong.host.badssl.com` and `expired.badssl.com` are both rejected.

```pascal
K.Insecure := True;      { a self-signed certificate in development }
```

It logs a warning on **every** request that uses it, on purpose. A setup
that silently stopped verifying is exactly the mistake nobody notices.

HTTPS needs OpenSSL. See [TLS](tls.md).

## Streaming

For Server-Sent Events, and for long responses that should not sit in memory
before the caller sees any of them:

```pascal
function TListener.Chunk(const S: string): Boolean;
begin
  Write(S);
  Result := not Cancelled;     { False stops the read }
end;

R := K.Stream('POST', Url, Body, 'application/json', Listener.Chunk);
```

`R.Body` is empty when streaming — the callback got it.

> Returning `False` stops the read everywhere, including from the very first
> chunk. The first version ignored the answer from the chunk that was
> already in the buffer after the head and kept reading; for an SSE stream
> that means the listener never stops listening.

## Redirects

Followed, up to `MaxRedirects` (5). **307 and 308 keep the method and the
body; 301, 302 and 303 become GET** — that is the whole reason 307 and 308
exist.

```pascal
K.MaxRedirects := 0;        { return the 302 itself }
```

A chain that does not end raises rather than hanging.

## Limits

```pascal
K.ConnectTimeoutMs := 10000;
K.ReadTimeoutMs := 30000;
K.MaxResponseBytes := 32 * 1024 * 1024;
K.UserAgent := 'shop/1.0';
```

`MaxResponseBytes` is a **stop, not an optimisation**: a response with
neither `Content-Length` nor chunked framing can in principle go on forever.

## Chunked

Decoded transparently. Which matters, because that is what every server uses
when it does not know the length in advance — nearly always for a streamed
API.

## Name resolution

`getaddrinfo` from libc, not FPC's `netdb`.

> netdb has its own DNS implementation that reads `/etc/resolv.conf` and
> speaks UDP itself, and it fails where the system manages: in a container
> with Docker Desktop's resolver it gave up entirely while `getent hosts`
> answered. `getaddrinfo` goes the way the system goes — nsswitch,
> `/etc/hosts`, DNS, mDNS. netdb remains as a fallback.

IPv4 only. The rest of Askr uses `TInetSockAddr`, and IPv6 needs a different
address family the whole way — a documented limit in the server since step 1,
which the client inherits.

## Compression

The client asks for `identity`, so it never receives gzip. Without zlib it
could not decompress, and a client that asks for something it cannot read is
a bug waiting. Binding zlib to save bandwidth on an API call is the wrong
trade when the binary is supposed to start on a machine without it.

## What is not here

HTTP/2, proxy support, a cookie jar, automatic retry. All four are real
needs for somebody; none of them was for what was queued behind this file.
