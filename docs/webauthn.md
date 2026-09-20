# Passkeys

`Askr.WebAuthn` verifies both WebAuthn ceremonies: registering a new
credential, and signing in with one. The cryptography underneath is
`Askr.Core.Ec` and `Askr.Core.Crypto`, both pure Pascal — this works on a
machine with no OpenSSL, like everything else here.

## Why passkeys rather than one-time codes

A TOTP code can be typed into a lookalike domain. That is the whole
phishing attack, and the code does not help against it — the user is the
one being asked, and the site looks right.

A passkey is bound to the RP ID. The browser refuses to use it anywhere
else, and that is not a warning someone can click past; it is something
that cannot happen. The server also stores only a public key, so a leaked
database yields no way in.

SMS is worse than both: SIM swap, SS7, and it costs money per message.

## Registering

```pascal
uses Askr.WebAuthn;

var
  Opts: TWebAuthnOptions;
  Reg: TRegistration;
begin
  Opts.RpId := 'example.com';
  Opts.Origin := 'https://example.com';
  Opts.RequireUserVerification := False;

  Reg := VerifyRegistration(Opts, ClientDataJson, AttestationObject,
                            Challenge);
  if not Reg.Ok then
    Exit(BadRequest(Reg.Error));

  { Store Reg.CredentialId, Reg.PublicKeyX, Reg.PublicKeyY and
    Reg.SignCount against the user. }
end;
```

`Challenge` is what you issued and kept in the session. `NewChallenge`
returns 32 random bytes, which is what the spec recommends.

## Signing in

```pascal
Asr := VerifyAssertion(Opts, ClientDataJson, AuthenticatorData,
                       Signature, Challenge, PubX, PubY, StoredSignCount);
if not Asr.Ok then
  Exit(Unauthorized(Asr.Error));

if Asr.CloneWarning then
  LogInfo('passkey sign counter did not advance', ['user', U.Id]);
```

Look up the stored credential by the credential ID the browser sends, and
pass that key in.

## What is checked

| | |
|---|---|
| Ceremony type | `webauthn.create` on registration, `webauthn.get` on sign-in |
| Challenge | Constant-time compare against the one you issued |
| Origin | **Exact** string equality |
| RP ID hash | SHA-256 of your RP ID, compared against `authData` |
| User presence | The UP flag, always |
| User verification | The UV flag, when you ask for it |
| Public key | EC2 / P-256 / ES256, and the point is on the curve |
| Signature | ECDSA over `authData ‖ SHA-256(clientDataJSON)` |

Origin is compared exactly, and it matters: `https://example.com.evil.example`
starts with `https://example.com`. A prefix check would accept it, and the
test vectors include that case precisely so the comparison cannot be
loosened without something failing.

## The sign counter is a warning, not a verdict

Authenticators are supposed to increment a counter on every use, so a
counter that does not advance suggests the credential was cloned. But
plenty of authenticators — including most platform ones — do not count at
all and always send zero.

So `CloneWarning` is something you decide about. Refusing every sign-in
where the counter stood still would lock out the most common hardware
there is.

## What is not here

**Attestation is not verified.** The attestation statement says which
authenticator the key came from; Askr reads past it. That is deliberate:
ordinary sign-in does not need to know whether the key lives in an iPhone
or a Yubikey, and demanding it locks out users with hardware you did not
think of. If you are in a setting that requires it — some regulated ones
are — this is the unit to extend, and it says so in its own header so
nobody assumes otherwise.

**Only ES256 on P-256.** An RSA or Ed25519 credential is refused at
registration rather than stored and hoped for.

**No scaffolding yet.** `askr make auth` does not create the credentials
table or the routes. You can build it today on top of these two functions;
the ceremonies and the verification are done. The sign-in scaffold's
security page says the same rather than implying more.

**No browser-side helper.** The `navigator.credentials` calls, the
base64url plumbing and the `PublicKeyCredentialCreationOptions` are yours
to write. They are perhaps thirty lines of JavaScript, and wrapping them
badly would be worse than leaving them.
