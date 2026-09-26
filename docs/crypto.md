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
| SHA-1 | FIPS 180, and every length around the block edge |
| HMAC-SHA1 | RFC 2202 |
| PBKDF2 | RFC 6070 cases carried over to SHA-256 |
| base64, base32 | RFC 4648 |
| HOTP, TOTP | RFC 4226 and RFC 6238 |
| ChaCha20-Poly1305 | RFC 8439, its Appendix A.3, and 150 vectors from python-cryptography |

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

`Sha1` and `HmacSha1` are there too, for TOTP and nothing else. SHA-1 is
broken for collisions, and HMAC is not touched by that; the authenticator
apps people have compute HMAC-SHA1 whatever the setup asks for.

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

## Encrypting a column

```pascal
uses Askr.Core.Aead;

U.TotpSecret := SealText(Secret, 'totp');
if OpenText(U.TotpSecret, 'totp', Secret) then ...
```

For a secret the app has to read back — a TOTP secret, an API key for a
customer's own account elsewhere — and that a leaked table should not hand
out with it. The text is `v1.` and then, in base64url, a fresh 12-byte
nonce, the ciphertext and a 16-byte tag.

- **ChaCha20-Poly1305, RFC 8439.** Encryption that also proves the text was
  not changed: a sealed value that was altered, cut short or made under
  another key does not open, and nothing is decrypted before the tag has
  been checked. ChaCha20 is additions, rotations and XOR, which take the
  same time whatever the key; AES in software is table lookups that do not.
- **The purpose is bound in.** It goes in as associated data, so a value
  sealed as `'totp'` does not open as anything else — copied into another
  column, it stays shut.
- **The key is `APP_KEY`**, through HMAC with a label of its own. A new
  `APP_KEY` makes everything sealed under the old one unreadable, which is
  what rotating a key means — for a table of TOTP secrets, it means every
  user sets up two-factor again. Plan it before doing it.
- **Not a construction of our own.** HMAC in counter mode with a MAC after
  it would have worked and would have had nothing to be held to. This has
  RFC 8439's vectors, the Appendix A.3 cases built to hit the hard carries
  in Poly1305, and 150 vectors from python-cryptography at every block
  edge. `tools/vectors/aead.py` writes them again.

`AeadSeal`, `AeadOpen`, `ChaCha20Xor` and `Poly1305` are there underneath,
for a key and nonce of your own. A nonce is used once per key, never again.

## Encoding

```pascal
Base64Encode(B);      Base64Decode(S);
Base64UrlEncode(B);   Base64UrlDecode(S);     { -_ and no padding }
Base32Encode(B);      Base32Decode(S);        { what a TOTP secret is written in }
HexEncode(B);         HexDecode(S);
```

`Base32Decode` takes lower case, spaces and dashes, as people type a secret,
and **raises** on a character outside the alphabet rather than skipping
it: a secret read wrong gives codes that never match, and nothing says
why.

base64url is the form that belongs in a URL, a filename or a cookie value.

## Elliptic curves

`Askr.Core.Ec` verifies ECDSA signatures on P-256, on top of the 256-bit
arithmetic in `Askr.Core.BigInt`. It exists for WebAuthn — Askr **verifies
signatures, it does not produce them.**

```pascal
if EcdsaVerifyP256(Qx, Qy, R, S, Hash) then
```

All five arguments are 32-byte big-endian.

Verification is a much smaller problem than signing, and the difference is
worth knowing: it operates entirely on public values — the signature and
the public key — so it does not have to be constant-time. Signing would,
and none of this code would be fit for it.

Two decisions shape the implementation:

**Limbs are 32 bits, not 64.** A 32x32 product plus two carries fits in a
`UInt64` exactly, so nothing in the arithmetic overflows and the unit needs
no overflow-check suppression. The 64-bit alternative would need a 128-bit
type Free Pascal does not have. It costs roughly twice the operations, and
buys an entire class of silent bug that cannot be found by reading.

**Reduction modulo p is not long division.** One verification is around
8000 field multiplications; the generic path would make that hundreds of
millions of operations. P-256 was chosen with a Solinas prime so the
reduction is nine word shuffles added and subtracted (FIPS 186-4, D.2.3).
Modulo *n* is generic, because it happens two or three times per
verification.

A verification takes about **5 ms**.

### What is not here

**No signing, no key generation, no ECDH.** Only what WebAuthn
verification needs.

**No other curve.** P-256 only. Ed25519 is a different implementation, not
a parameter.

**The vectors are generated, not NIST's.** They come from
python-cryptography, which verifies through OpenSSL — an independent
implementation of the same spec. That shows Askr agrees with OpenSSL on
those cases; it does not show that both follow the standard. The
adversarial rows are the interesting half: tampered `r`, tampered `s`,
`r = 0`, `s = n`, a mirrored `y`, a point off the curve, and another
key's signature.

**WebAuthn itself is not here yet.** This is the floor it needs. A CBOR
decoder and COSE key parsing still have to be written before a passkey can
be registered.

## Low level

```pascal
Pbkdf2Sha256(Password, Salt, Iterations, DkLen);
```

Exposed for building something else on. Use `HashPassword` for passwords.
