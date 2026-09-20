# TLS

OpenSSL is loaded with `dlopen`, not linked in. **The binary starts on a
machine without OpenSSL** — an app behind a reverse proxy never needs it.

```pascal
uses Askr.Tls;

TlsAvailable;        { False if it could not be loaded }
TlsLibraryName;
TlsVersion;
TlsLastError;
```

> **On macOS you must install OpenSSL yourself**: `brew install openssl@3`.
> The system `libssl` is LibreSSL, and Apple blocks `dlopen` against it from
> third-party binaries — the process dies with "loading libcrypto in an
> unsafe way". There is no way around it, and the error message says so
> outright rather than listing paths without explanation.

## HTTPS in the server

```pascal
Opts.TlsCertFile := Cfg('askr.tls.cert');
Opts.TlsKeyFile := Cfg('askr.tls.key');
```

Both or neither. With neither the app speaks HTTP, which is the right thing
behind a proxy that terminates TLS itself.

For a self-signed certificate in development, the framework's own build
script has a helper (this is `./askr` in a checkout of the framework, not
the `askr` CLI in your project):

```sh
./askr tls:certs    # writes .build/tls/cert.pem and key.pem
```

Or use `openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem
-out cert.pem -days 365 -subj /CN=127.0.0.1` directly.

Two things about when work happens:

**The certificate is read in `Start`**, not at the first handshake, and
`SSL_CTX_check_private_key` runs in the same place. A misspelled path or a
key that does not belong to the certificate must stop startup, not every
request.

**The handshake happens in `TWorker.Execute`, before `ServeConnection`.** A
client that cannot complete it costs one closed socket — not an arena and
not a log line per request.

Minimum version is **TLS 1.2**. Allowing 1.0 and 1.1 is offering a
downgrade target nobody needs.

## The client side

`Askr.Http.Client` and the SMTP transport both verify by default: **the
chain and the host name.**

The host name is not a detail. `SSL_VERIFY_PEER` on its own accepts a
genuine, valid certificate for *any* domain — that is the whole
man-in-the-middle attack. SNI says which certificate we want;
`SSL_set1_host` says the one we got must be for this host. Both are set.

Proven against the real internet: `wrong.host.badssl.com` and
`expired.badssl.com` are both rejected.

```pascal
Client.Insecure := True;       { self-signed, development only }
Transport.VerifyPeer := False; { the SMTP equivalent }
```

The HTTP client logs a warning on every request that uses it.

## STARTTLS

See [Mail](mail.md). STARTTLS is the default for SMTP, and a server that
does not offer it aborts the send rather than falling back to plaintext.

## Testing

**The TLS tests run in the container.** Natively on macOS the suite skips
itself — and says why. A skip that does not say why is worse than a failure.

The HTTP client's TLS is tested against **Askr's own TLS server** rather
than a real website. That is hermetic and tests the security property
itself: the server's certificate is self-signed and *must* be rejected by a
client that verifies. If it goes through, verification is an empty
procedure.

## Implementation notes

`SSL_CTX_set_min_proto_version` is a macro in C and does not exist as a
symbol to bind against; `SSL_CTX_ctrl` is used instead.

`TTlsConn.Read` and `Write` loop on `WANT_READ`/`WANT_WRITE` even though the
socket is blocking — renegotiation can produce them anyway.
