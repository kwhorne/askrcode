{ Askr.WebAuthn — passkeys.

  The two ceremonies: registering a new key, and signing in with one that
  exists. All the arithmetic is underneath — SHA-256 in Askr.Core.Crypto,
  ECDSA in Askr.Core.Ec, CBOR in Askr.Core.Cbor — so this unit is parsing
  and checking, not mathematics.

  WHY PASSKEYS AND NOT ONE-TIME CODES

  A TOTP code can be typed into a fake domain; that is the whole phishing
  attack, and the code does not help against it. A passkey is bound to the
  RP ID, and the browser refuses to use it anywhere else — not as a
  warning the user can click away, but as something that cannot be done.
  And the server stores only a public key: a leaked database gives nobody
  a way in.

  ATTESTATION IS NOT VERIFIED

  The attestation statement says which authenticator the key came from.
  Askr does not read it. That is a choice, not an omission: for ordinary
  sign-in you do not need to know whether the key is in an iPhone or a
  Yubikey, and requiring it locks out users with equipment you have not
  thought of. If you do need it — regulated environments sometimes do —
  this is the unit that has to be extended, and it says so here so that
  nobody believes it has already been done.

  What IS verified: that the challenge is ours, that the origin matches,
  that the RP ID hash matches, that the user was present, and that the
  signature holds against the stored key. }
unit Askr.WebAuthn;

{$mode Delphi}{$H+}

interface

uses
  SysUtils,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Json,
  Askr.Core.Crypto, Askr.Core.Cbor, Askr.Core.BigInt, Askr.Core.Ec;

const
  { authenticatorData sine flagg, WebAuthn Level 2, 6.1. }
  FlagUserPresent  = $01;
  FlagUserVerified = $04;
  FlagAttested     = $40;
  FlagExtensions   = $80;

type
  TWebAuthnOptions = record
    { The domain the key is bound to, without scheme and port:
      'example.com'. A passkey made for one RP ID does not work for
      another. }
    RpId: string;
    { The whole origin as the browser reports it: 'https://example.com'.
      Compared exactly. }
    Origin: string;
    { Require that the authenticator actually verified the user — PIN,
      fingerprint, face — and not merely that somebody touched it. }
    RequireUserVerification: Boolean;
  end;

  TRegistration = record
    Ok: Boolean;
    { In English, and safe to show: it says what was wrong, never what
      anything contained. }
    Error: string;
    CredentialId: TBytes;
    PublicKeyX: TBytes;
    PublicKeyY: TBytes;
    SignCount: UInt32;
    UserVerified: Boolean;
  end;

  TAssertion = record
    Ok: Boolean;
    Error: string;
    SignCount: UInt32;
    UserVerified: Boolean;
    { True when the counter did not go up. See the comment at
      VerifyAssertion: it is a warning, not a verdict. }
    CloneWarning: Boolean;
  end;

{ Makes a challenge. 32 bytes is what WebAuthn recommends, and it has to
  be kept in the session until the answer comes back. }
function NewChallenge: TBytes;

{ Registration. ClientDataJson and AttestationObject are the two fields
  the browser gives, Challenge the one we handed out. }
function VerifyRegistration(const Opts: TWebAuthnOptions;
  const ClientDataJson, AttestationObject, Challenge: TBytes): TRegistration;

{ Sign-in. StoredSignCount is the one we saved last time; 0 means the
  authenticator does not count. }
function VerifyAssertion(const Opts: TWebAuthnOptions;
  const ClientDataJson, AuthenticatorData, Signature, Challenge,
        PubX, PubY: TBytes; StoredSignCount: UInt32): TAssertion;

{ Exposed for the tests: an ES256 signature arrives DER encoded, not as
  raw r||s. }
function DerToRawSignature(const Der: TBytes; out R, S: TBytes): Boolean;

implementation

{ ------------------------------------------------------------ hjelpere -- }

function Skive(const B: TBytes; Start, Len: Integer): TBytes;
var
  I: Integer;
  T: TBytes;
begin
  T := nil;
  if (Start < 0) or (Len < 0) or (Start + Len > Length(B)) then
  begin
    SetLength(T, 0);
    Exit(T);
  end;
  SetLength(T, Len);
  for I := 0 to Len - 1 do
    T[I] := B[Start + I];
  Result := T;
end;

function Sammen(const A, B: TBytes): TBytes;
var
  I: Integer;
  T: TBytes;
begin
  T := nil;
  SetLength(T, Length(A) + Length(B));
  for I := 0 to High(A) do T[I] := A[I];
  for I := 0 to High(B) do T[Length(A) + I] := B[I];
  Result := T;
end;

{ Sha256 gir et fast array; resten av uniten regner i TBytes. }
function DigestBytes(const D: TSha256Digest): TBytes;
var
  I: Integer;
  T: TBytes;
begin
  T := nil;
  SetLength(T, 32);
  for I := 0 to 31 do T[I] := D[I];
  Result := T;
end;

function NewChallenge: TBytes;
begin
  Result := RandomBytes(32);
end;

{ ---------------------------------------------------------------- DER -- }

{ Reads an ASN.1 INTEGER and gives it back as exactly 32 bytes.

  DER writes integers with a sign, so a value with the top bit set gets a
  leading zero byte in front. And small values are shorter than 32 bytes.
  Both have to be handled: copying raw into a 32-byte field is precisely
  the bug that makes some signatures verify and others not, seemingly at
  random. }
function ReadDerInt(const Der: TBytes; var P: Integer; out Ut: TBytes): Boolean;
var
  Len, I, Start: Integer;
  T: TBytes;
begin
  T := nil;
  SetLength(T, 32);
  Ut := T;
  if (P + 2 > Length(Der)) or (Der[P] <> $02) then
    Exit(False);
  Inc(P);
  Len := Der[P];
  Inc(P);
  { Lengths above 127 use the long form. A P-256 component is at most 33
    bytes, so the long form is always wrong here. }
  if (Len = 0) or (Len > 33) or (P + Len > Length(Der)) then
    Exit(False);

  Start := P;
  { Skip the leading zero DER adds to keep the number positive. More than
    one is not minimal encoding. }
  if (Len > 1) and (Der[Start] = 0) then
  begin
    Inc(Start);
    Dec(Len);
    if Der[Start] < $80 then
      { A zero in front of a byte that did not need one is not DER. }
      Exit(False);
  end;
  if Len > 32 then
    Exit(False);

  for I := 0 to Len - 1 do
    T[32 - Len + I] := Der[Start + I];
  Ut := T;
  P := Start + Len;
  Result := True;
end;

function DerToRawSignature(const Der: TBytes; out R, S: TBytes): Boolean;
var
  P, Len: Integer;
  T: TBytes;
begin
  T := nil;
  SetLength(T, 32);
  R := T; S := T;
  if (Length(Der) < 8) or (Der[0] <> $30) then
    Exit(False);
  P := 1;
  Len := Der[P];
  Inc(P);
  if Len > 127 then
    { The long form. An ES256 signature is under 72 bytes, so this is
      wrong. }
    Exit(False);
  if P + Len <> Length(Der) then
    { Trailing data. A signature with something behind it is not a
      signature we have seen all of. }
    Exit(False);

  if not ReadDerInt(Der, P, R) then Exit(False);
  if not ReadDerInt(Der, P, S) then Exit(False);
  Result := P = Length(Der);
end;

{ ------------------------------------------------------------ COSE -- }

{ Pulls x and y out of a COSE_Key.

  The map looks like this for ES256, with keys that are integers:
    1  (kty) = 2   EC2
    3  (alg) = -7  ES256
   -1  (crv) = 1   P-256
   -2  (x)   = 32 bytes
   -3  (y)   = 32 bytes

  Anything but exactly that combination is rejected. Askr verifies P-256
  only; an RSA or Ed25519 key is not something we can check, and storing
  it and pretending is worse than saying no at registration. }
function ReadCoseKey(var R: TCborReader; const Buf: TBytes;
  out X, Y: TBytes; out Err: string): Boolean;
var
  N, I: Integer;
  Key_, Value_: Int64;
  Start, Len: Integer;
  Kty, Alg, Crv: Int64;
  HarX, HarY: Boolean;
  M: Byte;
begin
  X := nil; Y := nil;
  Err := '';
  Kty := 0; Alg := 0; Crv := 0;
  HarX := False; HarY := False;

  if not R.ReadMapLen(N) then
  begin
    Err := 'the credential public key is not a CBOR map';
    Exit(False);
  end;

  for I := 1 to N do
  begin
    if not R.ReadInt(Key_) then
    begin
      Err := 'the credential public key has a non-integer label';
      Exit(False);
    end;
    case Key_ of
      1, 3, -1:
        begin
          if not R.ReadInt(Value_) then
          begin
            Err := 'the credential public key is malformed';
            Exit(False);
          end;
          if Key_ = 1 then Kty := Value_
          else if Key_ = 3 then Alg := Value_
          else Crv := Value_;
        end;
      -2, -3:
        begin
          if not R.NextType(M) or (M <> CborBytes) then
          begin
            Err := 'the credential public key coordinates are malformed';
            Exit(False);
          end;
          if not R.ReadBytes(Start, Len) or (Len <> 32) then
          begin
            Err := 'the credential public key is not 32 bytes per coordinate';
            Exit(False);
          end;
          if Key_ = -2 then
          begin
            X := Skive(Buf, Start, Len);
            HarX := True;
          end
          else
          begin
            Y := Skive(Buf, Start, Len);
            HarY := True;
          end;
        end;
    else
      { Unknown fields are skipped. COSE allows them, and a new key type
        must not turn the parsing itself into an error here — it is the
        checks below that decide. }
      if not R.Skip then
      begin
        Err := 'the credential public key is malformed';
        Exit(False);
      end;
    end;
  end;

  if (Kty <> 2) or (Alg <> -7) or (Crv <> 1) then
  begin
    Err := 'only ES256 on P-256 is supported';
    Exit(False);
  end;
  if not (HarX and HarY) then
  begin
    Err := 'the credential public key has no coordinates';
    Exit(False);
  end;
  Result := True;
end;

{ ------------------------------------------------------ authenticatorData -- }

type
  TAuthData = record
    RpIdHash: TBytes;
    Flags: Byte;
    SignCount: UInt32;
    HasKey: Boolean;
    CredentialId: TBytes;
    KeyX, KeyY: TBytes;
  end;

{ TU256 fra 32 byte, for kurvesjekken. }
function BytesToU256(const B: TBytes): TU256;
begin
  if not U256FromBytes(B, Result) then
    U256SetZero(Result);
end;

function ReadAuthData(const B: TBytes; out A: TAuthData;
  out Err: string): Boolean;
var
  P, CredLen: Integer;
  R: TCborReader;
  Rest: TBytes;
begin
  Err := '';
  A.RpIdHash := nil; A.CredentialId := nil; A.KeyX := nil; A.KeyY := nil;
  A.Flags := 0; A.SignCount := 0; A.HasKey := False;

  { 32 byte hash, ett flaggbyte, fire byte teller. }
  if Length(B) < 37 then
  begin
    Err := 'authenticator data is too short';
    Exit(False);
  end;
  A.RpIdHash := Skive(B, 0, 32);
  A.Flags := B[32];
  A.SignCount := (UInt32(B[33]) shl 24) or (UInt32(B[34]) shl 16) or
                 (UInt32(B[35]) shl 8) or UInt32(B[36]);
  P := 37;

  if (A.Flags and FlagAttested) <> 0 then
  begin
    { 16 bytes of aaguid, two bytes of length, then the id. }
    if P + 18 > Length(B) then
    begin
      Err := 'attested credential data is truncated';
      Exit(False);
    end;
    Inc(P, 16);
    CredLen := (Integer(B[P]) shl 8) or Integer(B[P + 1]);
    Inc(P, 2);
    { WebAuthn puts the cap at 1023. A length above that is either a bug
      or somebody having a go. }
    if (CredLen = 0) or (CredLen > 1023) or (P + CredLen > Length(B)) then
    begin
      Err := 'the credential id length is not usable';
      Exit(False);
    end;
    A.CredentialId := Skive(B, P, CredLen);
    Inc(P, CredLen);

    { The key comes after the id. The reader takes no start position, so
      it gets a slice instead — then the slices it gives back are
      relative to the same thing. }
    Rest := Skive(B, P, Length(B) - P);
    if Length(Rest) = 0 then
    begin
      Err := 'the credential public key is missing';
      Exit(False);
    end;
    R.Init(@Rest[0], Length(Rest));
    if not ReadCoseKey(R, Rest, A.KeyX, A.KeyY, Err) then
      Exit(False);

    { A point that is not on the curve must never end up in the database.
      Here it is cheap to say no; later it is merely strange. }
    if not EcOnCurve(BytesToU256(A.KeyX), BytesToU256(A.KeyY)) then
    begin
      Err := 'the credential public key is not on the curve';
      Exit(False);
    end;
    A.HasKey := True;
  end;

  Result := True;
end;

{ ----------------------------------------------------------- clientData -- }

function CheckClientData(const Json: TBytes; const ForventetType: string;
  const Opts: TWebAuthnOptions; const Challenge: TBytes;
  out Err: string): Boolean;
var
  A: TArena;
  Rot, V: PJsonValue;
  ErrPos: SizeInt;
  S: string;
  Fikk: TBytes;
  I: Integer;
  Text_: string;
begin
  Err := '';
  Result := False;
  if Length(Json) = 0 then
  begin
    Err := 'the client data is empty';
    Exit;
  end;

  SetLength(Text_, Length(Json));
  for I := 0 to High(Json) do
    Text_[I + 1] := Chr(Json[I]);

  { Its own arena: this can be called outside a request, and clientData is
      a few hundred bytes. }
  A := TArena.Create(64 * 1024);
  try
    if not JsonParse(A, StrDup(A, Text_), Rot, ErrPos) then
    begin
      Err := 'the client data is not valid JSON';
      Exit;
    end;

    V := JsonMember(Rot, 'type');
    if (V = nil) or (JsonAsString(V) <> ForventetType) then
    begin
      Err := 'the client data is for a different ceremony';
      Exit;
    end;

    { The origin is compared exactly. Not "starts with", not "contains":
          https://example.com.attacker.example starts with nothing useful, but
          a loose comparison has let worse through. }
    V := JsonMember(Rot, 'origin');
    if (V = nil) or (JsonAsString(V) <> Opts.Origin) then
    begin
      Err := 'the origin does not match';
      Exit;
    end;

    V := JsonMember(Rot, 'challenge');
    if V = nil then
    begin
      Err := 'the client data has no challenge';
      Exit;
    end;
    S := JsonAsString(V);
    Fikk := Base64UrlDecode(S);
    if (Length(Fikk) <> Length(Challenge)) or (Length(Challenge) = 0) then
    begin
      Err := 'the challenge does not match';
      Exit;
    end;
    if not ConstantTimeEquals(Fikk, Challenge) then
    begin
      Err := 'the challenge does not match';
      Exit;
    end;

    Result := True;
  finally
    A.Free;
  end;
end;

{ --------------------------------------------------------- seremoniene -- }

function CheckFlags(Flags: Byte; const Opts: TWebAuthnOptions;
  out Err: string): Boolean;
begin
  Err := '';
  if (Flags and FlagUserPresent) = 0 then
  begin
    Err := 'the user was not present';
    Exit(False);
  end;
  if Opts.RequireUserVerification and ((Flags and FlagUserVerified) = 0) then
  begin
    Err := 'the user was not verified';
    Exit(False);
  end;
  Result := True;
end;

function CheckRpIdHash(const Hash: TBytes; const RpId: string;
  out Err: string): Boolean;
var
  Wait: TBytes;
begin
  Err := '';
  Wait := DigestBytes(Sha256(RpId));
  if (Length(Hash) <> 32) or not ConstantTimeEquals(Hash, Wait) then
  begin
    Err := 'the credential belongs to a different site';
    Exit(False);
  end;
  Result := True;
end;

function VerifyRegistration(const Opts: TWebAuthnOptions;
  const ClientDataJson, AttestationObject, Challenge: TBytes): TRegistration;
var
  R: TCborReader;
  N, I, Start, Len: Integer;
  Key_: string;
  AuthData: TBytes;
  A: TAuthData;
  Err: string;
begin
  Result.Ok := False;
  Result.Error := '';
  Result.CredentialId := nil;
  Result.PublicKeyX := nil;
  Result.PublicKeyY := nil;
  Result.SignCount := 0;
  Result.UserVerified := False;

  if not CheckClientData(ClientDataJson, 'webauthn.create', Opts,
                         Challenge, Err) then
  begin
    Result.Error := Err;
    Exit;
  end;

  if Length(AttestationObject) = 0 then
  begin
    Result.Error := 'the attestation object is empty';
    Exit;
  end;

  { The attestation object is a map with fmt, attStmt and authData. We look
    only for authData; attStmt is skipped without being looked at, and the
    header says why. }
  R.Init(@AttestationObject[0], Length(AttestationObject));
  if not R.ReadMapLen(N) then
  begin
    Result.Error := 'the attestation object is not a CBOR map';
    Exit;
  end;
  AuthData := nil;
  for I := 1 to N do
  begin
    if not R.ReadTextStr(Key_) then
    begin
      Result.Error := 'the attestation object is malformed';
      Exit;
    end;
    if Key_ = 'authData' then
    begin
      if not R.ReadBytes(Start, Len) then
      begin
        Result.Error := 'the attestation object has no usable authData';
        Exit;
      end;
      AuthData := Skive(AttestationObject, Start, Len);
    end
    else if not R.Skip then
    begin
      Result.Error := 'the attestation object is malformed';
      Exit;
    end;
  end;

  if AuthData = nil then
  begin
    Result.Error := 'the attestation object has no authData';
    Exit;
  end;

  if not ReadAuthData(AuthData, A, Err) then
  begin
    Result.Error := Err;
    Exit;
  end;
  if not A.HasKey then
  begin
    Result.Error := 'the authenticator returned no credential';
    Exit;
  end;
  if not CheckRpIdHash(A.RpIdHash, Opts.RpId, Err) then
  begin
    Result.Error := Err;
    Exit;
  end;
  if not CheckFlags(A.Flags, Opts, Err) then
  begin
    Result.Error := Err;
    Exit;
  end;

  { The key comes from outside. A point that is not on the curve must
    never end up in the database. }
  Result.CredentialId := A.CredentialId;
  Result.PublicKeyX := A.KeyX;
  Result.PublicKeyY := A.KeyY;
  Result.SignCount := A.SignCount;
  Result.UserVerified := (A.Flags and FlagUserVerified) <> 0;
  Result.Ok := True;
end;

function VerifyAssertion(const Opts: TWebAuthnOptions;
  const ClientDataJson, AuthenticatorData, Signature, Challenge,
        PubX, PubY: TBytes; StoredSignCount: UInt32): TAssertion;
var
  A: TAuthData;
  Err: string;
  ClientHash, Signert, R, S: TBytes;
begin
  Result.Ok := False;
  Result.Error := '';
  Result.SignCount := 0;
  Result.UserVerified := False;
  Result.CloneWarning := False;

  if not CheckClientData(ClientDataJson, 'webauthn.get', Opts,
                         Challenge, Err) then
  begin
    Result.Error := Err;
    Exit;
  end;

  if not ReadAuthData(AuthenticatorData, A, Err) then
  begin
    Result.Error := Err;
    Exit;
  end;
  if not CheckRpIdHash(A.RpIdHash, Opts.RpId, Err) then
  begin
    Result.Error := Err;
    Exit;
  end;
  if not CheckFlags(A.Flags, Opts, Err) then
  begin
    Result.Error := Err;
    Exit;
  end;

  if not DerToRawSignature(Signature, R, S) then
  begin
    Result.Error := 'the signature is not a valid ES256 signature';
    Exit;
  end;

  { What is signed is authenticatorData followed by the hash of
    clientDataJSON. The order is not optional. }
  ClientHash := DigestBytes(Sha256(ClientDataJson));
  Signert := Sammen(AuthenticatorData, ClientHash);

  if not EcdsaVerifyP256(PubX, PubY, R, S, DigestBytes(Sha256(Signert))) then
  begin
    Result.Error := 'the signature does not match';
    Exit;
  end;

  { The counter is supposed to go up on every use. If it does not, the key
    may have been copied — but many authenticators do not count at all and
    always send zero. Hence a warning the caller can act on, and not a
    rejection: refusing to sign in everybody whose counter stands still
    would shut out the most common equipment. }
  Result.SignCount := A.SignCount;
  if (StoredSignCount > 0) and (A.SignCount > 0) and
     (A.SignCount <= StoredSignCount) then
    Result.CloneWarning := True;

  Result.UserVerified := (A.Flags and FlagUserVerified) <> 0;
  Result.Ok := True;
end;

end.
