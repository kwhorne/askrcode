{ Askr.WebAuthn — passkeys.

  De to seremoniene: registrering av en ny nøkkel, og innlogging med en
  som finnes. Alt regnestykket ligger under — SHA-256 i
  Askr.Core.Crypto, ECDSA i Askr.Core.Ec, CBOR i Askr.Core.Cbor — så
  denne uniten er parsing og kontroll, ikke matematikk.

  HVORFOR PASSKEYS OG IKKE ENGANGSKODER

  En TOTP-kode kan tastes inn på et falskt domene; det er hele
  phishing-angrepet, og koden hjelper ikke mot det. En passkey er bundet
  til RP ID-en, og nettleseren nekter å bruke den andre steder — ikke
  som en advarsel brukeren kan klikke bort, men som noe som ikke lar seg
  gjøre. Og serveren lagrer bare en offentlig nøkkel: en lekket database
  gir ingen innlogging.

  ATTESTASJON VERIFISERES IKKE

  Attestasjonsuttalelsen sier hvilken autentikator nøkkelen kom fra.
  Askr leser den ikke. Det er et valg, ikke en mangel: for vanlig
  innlogging trenger man ikke vite om nøkkelen ligger i en iPhone eller
  en Yubikey, og å kreve det låser ute brukere med utstyr man ikke har
  tenkt på. Trenger du det — regulerte miljøer gjør det av og til —
  er det denne uniten som må utvides, og det står her for at ingen skal
  tro det allerede er gjort.

  Det som ER verifisert: at utfordringen er vår, at origin stemmer, at
  RP ID-hashen stemmer, at brukeren var til stede, og at signaturen
  holder mot den lagrede nøkkelen. }
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
    { Domenet nøkkelen bindes til, uten skjema og port: 'example.com'.
      En passkey laget for ett RP ID virker ikke for et annet. }
    RpId: string;
    { Hele origin slik nettleseren oppgir den: 'https://example.com'.
      Sammenlignes eksakt. }
    Origin: string;
    { Expect at autentikatoren faktisk verifiserte brukeren — PIN,
      fingeravtrykk, ansikt — og ikke bare at noen rørte den. }
    RequireUserVerification: Boolean;
  end;

  TRegistration = record
    Ok: Boolean;
    { Engelsk, og trygg å vise: den sier hva som var galt, aldri hva
      noe inneholdt. }
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
    { True når telleren ikke gikk opp. Se kommentaren ved
      VerifyAssertion: det er et varsel, ikke en dom. }
    CloneWarning: Boolean;
  end;

{ Storage en utfordring. 32 byte er det WebAuthn anbefaler, og den må
  lagres i sesjonen til svaret kommer. }
function NewChallenge: TBytes;

{ Registrering. ClientDataJson og AttestationObject er de to feltene
  nettleseren gir, Challenge den vi ga ut. }
function VerifyRegistration(const Opts: TWebAuthnOptions;
  const ClientDataJson, AttestationObject, Challenge: TBytes): TRegistration;

{ Innlogging. StoredSignCount er den vi har lagret fra sist; 0 betyr at
  autentikatoren ikke teller. }
function VerifyAssertion(const Opts: TWebAuthnOptions;
  const ClientDataJson, AuthenticatorData, Signature, Challenge,
        PubX, PubY: TBytes; StoredSignCount: UInt32): TAssertion;

{ Eksponert for testene: en ES256-signatur kommer DER-kodet, ikke som
  rå r||s. }
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

{ Leser en ASN.1-INTEGER og gir den som nøyaktig 32 byte.

  DER skriver heltall med fortegn, så en verdi med høyeste bit satt får
  en ledende nullbyte foran. Og små verdier er kortere enn 32 byte.
  Begge deler må håndteres: å kopiere rått inn i et 32-bytes felt er
  nettopp feilen som gjør at noen signaturer verifiserer og andre ikke,
  tilsynelatende tilfeldig. }
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
  { Lengder over 127 bruker lang form. En P-256-komponent er høyst 33
    byte, så lang form er alltid feil her. }
  if (Len = 0) or (Len > 33) or (P + Len > Length(Der)) then
    Exit(False);

  Start := P;
  { Skip over den ledende nullen DER legger på for å holde tallet
    positivt. Mer enn én er ikke minimal koding. }
  if (Len > 1) and (Der[Start] = 0) then
  begin
    Inc(Start);
    Dec(Len);
    if Der[Start] < $80 then
      { En null foran en byte som ikke trengte den er ikke DER. }
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
    { Lang form. En ES256-signatur er under 72 byte, så dette er feil. }
    Exit(False);
  if P + Len <> Length(Der) then
    { Etterfølgende data. En signatur med noe bak seg er ikke en
      signatur vi har sett hele av. }
    Exit(False);

  if not ReadDerInt(Der, P, R) then Exit(False);
  if not ReadDerInt(Der, P, S) then Exit(False);
  Result := P = Length(Der);
end;

{ ------------------------------------------------------------ COSE -- }

{ Henter x og y ut av en COSE_Key.

  Kartet ser slik ut for ES256, med nøkler som er heltall:
    1  (kty) = 2   EC2
    3  (alg) = -7  ES256
   -1  (crv) = 1   P-256
   -2  (x)   = 32 byte
   -3  (y)   = 32 byte

  Alt annet enn nøyaktig denne kombinasjonen avvises. Askr verifiserer
  bare P-256; en RSA- eller Ed25519-nøkkel er ikke noe vi kan sjekke,
  og å lagre den og late som er verre enn å si nei ved registrering. }
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
      { Ukjente felter hoppes over. COSE tillater dem, og en ny
        nøkkeltype skal ikke gjøre parsingen til en feil her — det er
        sjekkene under som avgjør. }
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
    { 16 byte aaguid, to byte lengde, så id-en. }
    if P + 18 > Length(B) then
    begin
      Err := 'attested credential data is truncated';
      Exit(False);
    end;
    Inc(P, 16);
    CredLen := (Integer(B[P]) shl 8) or Integer(B[P + 1]);
    Inc(P, 2);
    { WebAuthn setter taket på 1023. En lengde over det er enten en feil
      eller noen som prøver seg. }
    if (CredLen = 0) or (CredLen > 1023) or (P + CredLen > Length(B)) then
    begin
      Err := 'the credential id length is not usable';
      Exit(False);
    end;
    A.CredentialId := Skive(B, P, CredLen);
    Inc(P, CredLen);

    { Nøkkelen står etter id-en. Leseren tar ingen startposisjon, så
      den får et utsnitt i stedet — da blir utsnittene den gir tilbake
      relative til det samme. }
    Rest := Skive(B, P, Length(B) - P);
    if Length(Rest) = 0 then
    begin
      Err := 'the credential public key is missing';
      Exit(False);
    end;
    R.Init(@Rest[0], Length(Rest));
    if not ReadCoseKey(R, Rest, A.KeyX, A.KeyY, Err) then
      Exit(False);

    { Et punkt som ikke ligger på kurven skal aldri havne i databasen.
      Her er det billig å si nei; senere er det bare rart. }
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

  { Egen arena: denne kan kalles utenfor en request, og clientData er
    noen hundre byte. }
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

    { Origin sammenlignes eksakt. Ikke «starter med», ikke «inneholder»:
      https://example.com.angriper.no starter med ingenting nyttig, men
      en løs sammenligning har sluppet gjennom verre. }
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

  { Attestasjonsobjektet er et kart med fmt, attStmt og authData. Vi
    leter bare etter authData; attStmt hoppes over uten å bli sett på,
    og det står i overskriften hvorfor. }
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

  { Nøkkelen kommer utenfra. Et punkt som ikke ligger på kurven skal
    aldri havne i databasen. }
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

  { Det signerte er authenticatorData etterfulgt av hashen av
    clientDataJSON. Rekkefølgen er ikke valgfri. }
  ClientHash := DigestBytes(Sha256(ClientDataJson));
  Signert := Sammen(AuthenticatorData, ClientHash);

  if not EcdsaVerifyP256(PubX, PubY, R, S, DigestBytes(Sha256(Signert))) then
  begin
    Result.Error := 'the signature does not match';
    Exit;
  end;

  { Telleren skal gå opp for hver bruk. Gjør den ikke det, kan nøkkelen
    være kopiert — men mange autentikatorer teller ikke i det hele tatt
    og sender alltid null. Derfor et varsel kallstedet kan handle på, og
    ikke en avvisning: å nekte innlogging til alle med en teller som
    står stille ville stengt ute det vanligste utstyret. }
  Result.SignCount := A.SignCount;
  if (StoredSignCount > 0) and (A.SignCount > 0) and
     (A.SignCount <= StoredSignCount) then
    Result.CloneWarning := True;

  Result.UserVerified := (A.Flags and FlagUserVerified) <> 0;
  Result.Ok := True;
end;

end.
