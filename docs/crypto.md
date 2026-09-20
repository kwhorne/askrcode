# Cryptography

```pascal
uses Askr.Core.Crypto;
```

**Everything here is written in pure Pascal, without OpenSSL.** That is a
deliberate choice, and the reason is the PRD's first promise: the binary
must start on a machine without OpenSSL. If password hashing leaned on
libcrypto, no app with a login could run without it, and "optional
dependency" would become untrue. TLS is different — an app behind a reverse
proxy never needs `Askr.Tls` — but any app with users needs this.

The price is that the password hash is **PBKDF2-HMAC-SHA256, not Argon2id**.
OWASP considers PBKDF2 with a high iteration count sound, but Argon2id is
the 2026 recommendation because it also costs memory and is therefore more
expensive to attack with specialised hardware. That is a trade-off, not free,
and it is stated rather than hidden.

## Everything is tested against official vectors

A SHA-256 with the wrong byte order is stable, consistent and completely
worthless, and nothing in an app would say so. So every algorithm here is
checked against numbers somebody else published:

| | |
|---|---|
| SHA-256 | NIST FIPS 180-4 |
| HMAC-SHA256 | RFC 4231, all seven cases |
| PBKDF2 | RFC 6070 cases carried over to SHA-256 |
| base64 | RFC 4648 |

## Randomness

```pascal
RandomBytes(32);        { TBytes, from the kernel }
RandomHex(16);          { 32 characters }
RandomToken;            { 32 bytes, base64url — URL and cookie safe }
```

From `/dev/urandom` on Unix, `BCryptGenRandom` on Windows. It **raises** if
it cannot get them: randomness that silently falls back to something weaker
is worse than a process that will not start.

Never `Random`. FPC's `Random` is a Mersenne Twister seeded from the clock —
fine for test data, useless for a session id.

## Hashing

```pascal
Sha256(S);              { TSha256Digest — 32 bytes }
Sha256Hex(S);
HmacSha256(Key, Msg);
HmacSha256Hex(Key, Msg);
```

> The SHA-256 implementation is marked `{$push}{$R-}{$Q-}`. It computes
> modulo 2^32 and overflows on purpose. Without the marking the whole unit
> dies with `ERangeError` in any build with overflow checking — which
> `./askr check` does. Same reason as the FNV hashes in `Askr.Cache`.

## Comparing secrets

```pascal
ConstantTimeEquals(A, B);
```

Use it on every comparison of anything secret — tokens, signatures, hashes.
A plain `=` stops at the first difference, and how long that took tells an
attacker how far they got.

Unequal lengths leak, but unavoidably: the length of a hash is public. What
must not leak is *where* they differ, so the loop always runs to the end.

## Passwords

```pascal
Hash := HashPassword('correct horse battery staple');
VerifyPassword(Password, Hash);
NeedsRehash(Hash);
```

The result is a PHC string carrying the algorithm, the iteration count and
the salt:

```
$pbkdf2-sha256$i=600000$<salt>$<hash>
```

The whole string goes in the database. That is what lets the parameters
change without a migration.

**600 000 iterations** is OWASP's 2026 recommendation, measured at **573 ms**
on an M-series Mac. That is the point of a password hash: it should cost.

`NeedsRehash` returns true when the stored hash used weaker parameters than
today's. Call it after a successful `VerifyPassword` — you have the plaintext
right then and can write a new hash without asking the user anything:

```pascal
if VerifyPassword(P, U.PasswordHash) then
begin
  if NeedsRehash(U.PasswordHash) then
  begin
    U.PasswordHash := HashPassword(P);
    U.Save;
  end;
  Login(IntToStr(U.Id));
end;
```

**`VerifyPassword` never raises.** A corrupt field in the database becomes a
rejected login, not a 500.

## The app key

One key for the whole app, used for everything that must be provable to
come from us: the "remember me" cookie, signed URLs, and later encryption.

```sh
askr key:generate
```

```pascal
SetAppKey(Env('APP_KEY'));
HasAppKey;
```

The key comes from the environment, never from source. Replace it and
everything signed with the previous one becomes invalid — which is the whole
point of being able to replace it.

`askr key:generate` prints a key; it does **not** write it into `.env`. A
key swapped silently logs everyone out.

## Signing

```pascal
Signed := Sign('user=7|expires=1790000000');
if Unsign(Signed, Payload) then ...
```

The result is `<text>.<signature>`, and **the text is readable** — the
signature proves it was not changed, it does not hide it. Never put anything
secret in a signed value.

`Unsign` splits on the **last** dot: the payload may contain dots, the
signature cannot. Comparison is constant time.

## Encoding

```pascal
Base64Encode(B);      Base64Decode(S);
Base64UrlEncode(B);   Base64UrlDecode(S);     { -_ and no padding }
HexEncode(B);         HexDecode(S);
```

base64url is the form that belongs in a URL, a filename or a cookie value.

## Low level

```pascal
Pbkdf2Sha256(Password, Salt, Iterations, DkLen);
```

Exposed for building something else on. Use `HashPassword` for passwords.
