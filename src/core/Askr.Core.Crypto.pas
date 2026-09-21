{ Askr.Core.Crypto — grunnmuren under CSRF, sesjoner og innlogging.

  Alt her er skrevet i ren Pascal, uten OpenSSL. Det er et bevisst valg, og
  grunnen er PRD-ens første løfte: binæren skal starte på en maskin uten
  OpenSSL. Lener passordhashing seg på libcrypto, kan ingen app med
  innlogging kjøre uten den, og «valgfri avhengighet» blir usant. TLS er noe
  annet — en app bak en reverse proxy trenger aldri Askr.Tls, mens enhver app
  med brukere trenger dette.

  Prisen er at passordhashen er **PBKDF2-HMAC-SHA256**, ikke Argon2id.
  OWASP regner PBKDF2 med høy iterasjonstelling som forsvarlig, men Argon2id
  er det anbefalte i 2026 fordi det også koster minne og dermed er dyrere å
  angripe med spesialisert maskinvare. Det er et kompromiss, ikke gratis, og
  det står her i stedet for å være gjemt.

  Tilfeldigheten kommer fra kjernen, aldri fra `Random`. FPCs `Random` er en
  Mersenne Twister sådd med klokka: den er fin til testdata og ubrukelig til
  en sesjons-id.

  Vektorene algoritmene er testet mot står i tests/askr_crypto_tests.lpr:
  NIST-vektorene for SHA-256, RFC 4231 for HMAC-SHA256 og RFC 6070 (med
  SHA-256-varianten fra RFC 7914) for PBKDF2. En kryptoimplementasjon uten
  offisielle vektorer er en gjetning. }
unit Askr.Core.Crypto;

{$mode Delphi}{$H+}

interface

uses
  SysUtils
{$IFDEF UNIX}
  , BaseUnix
{$ENDIF}
{$IFDEF WINDOWS}
  , Windows
{$ENDIF}
  ;

type
  ECryptoError = class(Exception);

  TSha256Digest = array[0..31] of Byte;

{ ------------------------------------------------------------ tilfeldig -- }

{ Bytes fra operativsystemets CSPRNG. Kaster hvis den ikke får dem — en
  tilfeldighet som stille faller tilbake på noe svakere er verre enn en
  prosess som ikke starter. }
function RandomBytes(Count: Integer): TBytes;
{ Samme, hex-kodet. `Count` er antall bytes, så strengen blir dobbelt så lang. }
function RandomHex(Count: Integer): string;
{ Samme, base64url uten utfylling. Formen som hører hjemme i en cookie,
  en URL eller et skjult skjemafelt. }
function RandomToken(Count: Integer = 32): string;

{ --------------------------------------------------------------- SHA-256 -- }

function Sha256(const Data: TBytes): TSha256Digest; overload;
function Sha256(const S: string): TSha256Digest; overload;
function Sha256Hex(const S: string): string;

{ ----------------------------------------------------------- HMAC-SHA256 -- }

function HmacSha256(const Key, Msg: TBytes): TSha256Digest; overload;
function HmacSha256(const Key, Msg: string): TSha256Digest; overload;
function HmacSha256Hex(const Key, Msg: string): string;

{ ------------------------------------------------------ konstant tid -- }

{ Sammenligner uten å røpe hvor de to er ulike. En vanlig `=` på strenger
  stopper ved første avvik, og tiden det tar forteller en angriper hvor
  langt han er kommet. Brukes på hver eneste sammenligning av noe hemmelig:
  tokens, signaturer, hasher. }
function ConstantTimeEquals(const A, B: TBytes): Boolean; overload;
function ConstantTimeEquals(const A, B: string): Boolean; overload;

{ ---------------------------------------------------------------- base64 -- }

function Base64Encode(const Data: TBytes): string;
function Base64Decode(const S: string): TBytes;
{ base64url: `-` og `_` i stedet for `+` og `/`, og ingen `=` på slutten.
  Trygg i en URL, i et filnavn og i en cookie-verdi. }
function Base64UrlEncode(const Data: TBytes): string;
function Base64UrlDecode(const S: string): TBytes;

function HexEncode(const Data: TBytes): string;
function HexDecode(const S: string): TBytes;

{ ---------------------------------------------------------------- PBKDF2 -- }

function Pbkdf2Sha256(const Password: string; const Salt: TBytes;
  Iterations, DkLen: Integer): TBytes;

{ ----------------------------------------------------------- passord -- }

const
  { OWASPs anbefaling for PBKDF2-HMAC-SHA256 er 600 000 i 2026. Tallet står
    i hashen, så en verdi hevet senere gjør ikke gamle hasher ugyldige —
    NeedsRehash sier fra, og neste innlogging oppgraderer dem. }
  DefaultPbkdf2Iterations = 600000;

{ Hasher et passord. Resultatet er en PHC-streng som bærer med seg
  algoritme, iterasjoner og salt:

      $pbkdf2-sha256$i=600000$<salt>$<hash>

  Hele strengen lagres i databasen. Det er den som gjør at parametrene kan
  endres uten en migrasjon. }
function HashPassword(const Password: string;
  Iterations: Integer = DefaultPbkdf2Iterations): string;
{ Sjekker et passord mot en hash fra HashPassword. Returnerer False på en
  hash den ikke kjenner igjen — aldri en exception, for da ville et ødelagt
  felt i databasen blitt en 500 i stedet for en avvist innlogging. }
function VerifyPassword(const Password, Hash: string): Boolean;
{ True hvis hashen ble laget med svakere parametre enn dagens. Kalles etter
  en vellykket VerifyPassword: da har man passordet i klartekst og kan
  skrive en ny hash uten å spørre brukeren om noe. }
function NeedsRehash(const Hash: string;
  Iterations: Integer = DefaultPbkdf2Iterations): Boolean;

{ ------------------------------------------------------------ appnøkkel -- }

{ Appens signeringsnøkkel. Én nøkkel for hele appen, brukt til alt som må
  kunne bevises å komme fra oss: «husk meg»-kaka, signerte URL-er, og
  senere kryptering.

  Nøkkelen kommer fra miljøet, aldri fra kildekoden. Byttes den ut, blir
  alt som er signert med den forrige ugyldig — det er hele poenget med å
  kunne bytte den. }
procedure SetAppKey(const Key: string);
{ Nøkkelen som bytes. Kaster hvis den ikke er satt: en app som signerer med
  en tom nøkkel signerer ingenting, og det skal ikke være mulig å komme i
  den tilstanden uten å merke det. }
function AppKey: TBytes;
function HasAppKey: Boolean;
{ En ny nøkkel, til `askr key:generate` og til .env.example. }
function GenerateAppKey: string;

{ Signerer en tekst med appnøkkelen. Resultatet er `<tekst>.<signatur>`, og
  teksten er **lesbar** — signaturen beviser at den ikke er endret, den
  skjuler den ikke. Put aldri noe hemmelig i en signert verdi. }
function Sign(const Payload: string): string;
{ Sjekker signaturen og gir teksten tilbake. False hvis den ikke stemmer,
  mangler eller er tuklet med. Sammenligningen går i konstant tid. }
function Unsign(const Signed: string; out Payload: string): Boolean;

implementation

function Bytes_(const S: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(S));
  if Length(S) > 0 then
    Move(S[1], Result[0], Length(S));
end;

{ ------------------------------------------------------------ tilfeldig -- }

{$IFDEF WINDOWS}
{ BCryptGenRandom er Windows' CSPRNG. Flagget 2 er
  BCRYPT_USE_SYSTEM_PREFERRED_RNG, som lar oss slippe å åpne en algoritme-
  handle først. Denne stien er skrevet, men aldri kjørt — som resten av
  Windows-støtten i Askr. }
const
  BCRYPT_USE_SYSTEM_PREFERRED_RNG = 2;

function BCryptGenRandom(hAlgorithm: Pointer; pbBuffer: PByte;
  cbBuffer: LongWord; dwFlags: LongWord): LongInt; stdcall;
  external 'bcrypt.dll' name 'BCryptGenRandom';
{$ENDIF}

function RandomBytes(Count: Integer): TBytes;
{$IFDEF UNIX}
var
  F: cint;
  Got, Want: Integer;
{$ENDIF}
begin
  Result := nil;
  if Count <= 0 then
    Exit;
  SetLength(Result, Count);

{$IFDEF UNIX}
  F := fpOpen('/dev/urandom', O_RDONLY);
  if F < 0 then
    raise ECryptoError.Create('Could not open /dev/urandom');
  try
    { En kort lesning er lovlig fra en fil-deskriptor, også fra urandom.
      Løkka er ikke pedanteri — uten den kunne halve nøkkelen vært nuller. }
    Want := 0;
    while Want < Count do
    begin
      Got := fpRead(F, Result[Want], Count - Want);
      if Got <= 0 then
        raise ECryptoError.Create('Could not read enough random bytes');
      Inc(Want, Got);
    end;
  finally
    fpClose(F);
  end;
{$ELSE}
{$IFDEF WINDOWS}
  if BCryptGenRandom(nil, @Result[0], Count,
    BCRYPT_USE_SYSTEM_PREFERRED_RNG) <> 0 then
    raise ECryptoError.Create('BCryptGenRandom failed');
{$ELSE}
  raise ECryptoError.Create('No CSPRNG available on this platform');
{$ENDIF}
{$ENDIF}
end;

function RandomHex(Count: Integer): string;
begin
  Result := HexEncode(RandomBytes(Count));
end;

function RandomToken(Count: Integer): string;
begin
  Result := Base64UrlEncode(RandomBytes(Count));
end;

{ --------------------------------------------------------------- SHA-256 -- }

{ SHA-256 regner modulo 2^32, og addisjonene flyter over med vilje. Without
  denne merkingen krasjer hele uniten med ERangeError i enhver bygging med
  -Cr eller -Co, som ./askr check gjør. Samme grunn som FNV-hashene i
  Askr.Cache. }
{$push}{$R-}{$Q-}

const
  Sha256K: array[0..63] of Cardinal = (
    $428a2f98, $71374491, $b5c0fbcf, $e9b5dba5,
    $3956c25b, $59f111f1, $923f82a4, $ab1c5ed5,
    $d807aa98, $12835b01, $243185be, $550c7dc3,
    $72be5d74, $80deb1fe, $9bdc06a7, $c19bf174,
    $e49b69c1, $efbe4786, $0fc19dc6, $240ca1cc,
    $2de92c6f, $4a7484aa, $5cb0a9dc, $76f988da,
    $983e5152, $a831c66d, $b00327c8, $bf597fc7,
    $c6e00bf3, $d5a79147, $06ca6351, $14292967,
    $27b70a85, $2e1b2138, $4d2c6dfc, $53380d13,
    $650a7354, $766a0abb, $81c2c92e, $92722c85,
    $a2bfe8a1, $a81a664b, $c24b8b70, $c76c51a3,
    $d192e819, $d6990624, $f40e3585, $106aa070,
    $19a4c116, $1e376c08, $2748774c, $34b0bcb5,
    $391c0cb3, $4ed8aa4a, $5b9cca4f, $682e6ff3,
    $748f82ee, $78a5636f, $84c87814, $8cc70208,
    $90befffa, $a4506ceb, $bef9a3f7, $c67178f2);

type
  TSha256State = record
    H: array[0..7] of Cardinal;
    Buf: array[0..63] of Byte;
    BufLen: Integer;
    Total: QWord;   { i bytes, for lengdefeltet til slutt }
  end;

function RotR(X: Cardinal; N: Byte): Cardinal; inline;
begin
  Result := (X shr N) or (X shl (32 - N));
end;

procedure Sha256Init(out St: TSha256State);
begin
  St.H[0] := $6a09e667; St.H[1] := $bb67ae85;
  St.H[2] := $3c6ef372; St.H[3] := $a54ff53a;
  St.H[4] := $510e527f; St.H[5] := $9b05688c;
  St.H[6] := $1f83d9ab; St.H[7] := $5be0cd19;
  St.BufLen := 0;
  St.Total := 0;
end;

procedure Sha256Block(var St: TSha256State; const Block: array of Byte;
  Offset: Integer);
var
  W: array[0..63] of Cardinal;
  A, B, C, D, E, F, G, H, T1, T2, S0, S1, Ch, Maj: Cardinal;
  I: Integer;
begin
  { Big-endian inn. SHA-256 er spesifisert i nettverksrekkefølge, og maskinen
    under er little-endian; bommer man her stemmer ingen vektor. }
  for I := 0 to 15 do
    W[I] := (Cardinal(Block[Offset + I * 4]) shl 24) or
            (Cardinal(Block[Offset + I * 4 + 1]) shl 16) or
            (Cardinal(Block[Offset + I * 4 + 2]) shl 8) or
             Cardinal(Block[Offset + I * 4 + 3]);
  for I := 16 to 63 do
  begin
    S0 := (RotR(W[I - 15], 7) xor RotR(W[I - 15], 18)) xor (W[I - 15] shr 3);
    S1 := (RotR(W[I - 2], 17) xor RotR(W[I - 2], 19)) xor (W[I - 2] shr 10);
    W[I] := W[I - 16] + S0 + W[I - 7] + S1;
  end;

  A := St.H[0]; B := St.H[1]; C := St.H[2]; D := St.H[3];
  E := St.H[4]; F := St.H[5]; G := St.H[6]; H := St.H[7];

  for I := 0 to 63 do
  begin
    S1 := (RotR(E, 6) xor RotR(E, 11)) xor RotR(E, 25);
    Ch := (E and F) xor ((not E) and G);
    T1 := H + S1 + Ch + Sha256K[I] + W[I];
    S0 := (RotR(A, 2) xor RotR(A, 13)) xor RotR(A, 22);
    Maj := ((A and B) xor (A and C)) xor (B and C);
    T2 := S0 + Maj;
    H := G; G := F; F := E;
    E := D + T1;
    D := C; C := B; B := A;
    A := T1 + T2;
  end;

  Inc(St.H[0], A); Inc(St.H[1], B); Inc(St.H[2], C); Inc(St.H[3], D);
  Inc(St.H[4], E); Inc(St.H[5], F); Inc(St.H[6], G); Inc(St.H[7], H);
end;

procedure Sha256Update(var St: TSha256State; const Data: array of Byte;
  Len: Integer);
var
  Pos_, Take: Integer;
begin
  Inc(St.Total, QWord(Len));
  Pos_ := 0;
  while Pos_ < Len do
  begin
    Take := 64 - St.BufLen;
    if Take > Len - Pos_ then
      Take := Len - Pos_;
    Move(Data[Pos_], St.Buf[St.BufLen], Take);
    Inc(St.BufLen, Take);
    Inc(Pos_, Take);
    if St.BufLen = 64 then
    begin
      Sha256Block(St, St.Buf, 0);
      St.BufLen := 0;
    end;
  end;
end;

procedure Sha256Final(var St: TSha256State; out Digest: TSha256Digest);
var
  Bits: QWord;
  I: Integer;
begin
  Bits := St.Total * 8;
  { Utfylling: én 1-bit, så nuller, så lengden i bit som 64-bit big-endian.
    Får ikke lengden plass i denne blokka, går den i en til. }
  St.Buf[St.BufLen] := $80;
  Inc(St.BufLen);
  if St.BufLen > 56 then
  begin
    while St.BufLen < 64 do
    begin
      St.Buf[St.BufLen] := 0;
      Inc(St.BufLen);
    end;
    Sha256Block(St, St.Buf, 0);
    St.BufLen := 0;
  end;
  while St.BufLen < 56 do
  begin
    St.Buf[St.BufLen] := 0;
    Inc(St.BufLen);
  end;
  for I := 0 to 7 do
    St.Buf[56 + I] := Byte((Bits shr ((7 - I) * 8)) and $FF);
  Sha256Block(St, St.Buf, 0);

  for I := 0 to 7 do
  begin
    Digest[I * 4]     := Byte((St.H[I] shr 24) and $FF);
    Digest[I * 4 + 1] := Byte((St.H[I] shr 16) and $FF);
    Digest[I * 4 + 2] := Byte((St.H[I] shr 8) and $FF);
    Digest[I * 4 + 3] := Byte(St.H[I] and $FF);
  end;
end;

function Sha256(const Data: TBytes): TSha256Digest;
var
  St: TSha256State;
begin
  Sha256Init(St);
  if Length(Data) > 0 then
    Sha256Update(St, Data, Length(Data));
  Sha256Final(St, Result);
end;

function Sha256(const S: string): TSha256Digest;
var
  B: TBytes;
begin
  SetLength(B, Length(S));
  if Length(S) > 0 then
    Move(S[1], B[0], Length(S));
  Result := Sha256(B);
end;

function Sha256Hex(const S: string): string;
var
  D: TSha256Digest;
  B: TBytes;
begin
  D := Sha256(S);
  SetLength(B, 32);
  Move(D[0], B[0], 32);
  Result := HexEncode(B);
end;

{ ----------------------------------------------------------- HMAC-SHA256 -- }

function HmacSha256(const Key, Msg: TBytes): TSha256Digest;
var
  K: TBytes;
  Inner, Outer: array[0..63] of Byte;
  D: TSha256Digest;
  St: TSha256State;
  I: Integer;
begin
  { En nøkkel lengre enn blokka hashes først. Det er ikke en optimalisering,
    det står i RFC 2104 — og uten det stemmer ikke RFC 4231-vektor 6. }
  if Length(Key) > 64 then
  begin
    D := Sha256(Key);
    SetLength(K, 32);
    Move(D[0], K[0], 32);
  end
  else
    K := Copy(Key, 0, Length(Key));

  FillChar(Inner, SizeOf(Inner), $36);
  FillChar(Outer, SizeOf(Outer), $5C);
  for I := 0 to Length(K) - 1 do
  begin
    Inner[I] := Inner[I] xor K[I];
    Outer[I] := Outer[I] xor K[I];
  end;

  Sha256Init(St);
  Sha256Update(St, Inner, 64);
  if Length(Msg) > 0 then
    Sha256Update(St, Msg, Length(Msg));
  Sha256Final(St, D);

  Sha256Init(St);
  Sha256Update(St, Outer, 64);
  Sha256Update(St, D, 32);
  Sha256Final(St, Result);
end;

function HmacSha256(const Key, Msg: string): TSha256Digest;
var
  KB, MB: TBytes;
begin
  SetLength(KB, Length(Key));
  if Length(Key) > 0 then
    Move(Key[1], KB[0], Length(Key));
  SetLength(MB, Length(Msg));
  if Length(Msg) > 0 then
    Move(Msg[1], MB[0], Length(Msg));
  Result := HmacSha256(KB, MB);
end;

function HmacSha256Hex(const Key, Msg: string): string;
var
  D: TSha256Digest;
  B: TBytes;
begin
  D := HmacSha256(Key, Msg);
  SetLength(B, 32);
  Move(D[0], B[0], 32);
  Result := HexEncode(B);
end;

{ ---------------------------------------------------------------- PBKDF2 -- }

function Pbkdf2Sha256(const Password: string; const Salt: TBytes;
  Iterations, DkLen: Integer): TBytes;
var
  PwBytes, Block: TBytes;
  U, T: TSha256Digest;
  Blocks, I, J, K, Take, Out_: Integer;
begin
  Result := nil;
  if Iterations < 1 then
    raise ECryptoError.Create('PBKDF2 needs at least one iteration');
  if DkLen < 1 then
    raise ECryptoError.Create('PBKDF2 needs a positive key length');

  SetLength(PwBytes, Length(Password));
  if Length(Password) > 0 then
    Move(Password[1], PwBytes[0], Length(Password));

  SetLength(Result, DkLen);
  Blocks := (DkLen + 31) div 32;
  Out_ := 0;

  for I := 1 to Blocks do
  begin
    { U1 = HMAC(P, S || INT_BE32(i)). Blokkteller er 1-basert og
      big-endian — begge deler er lette å bomme på, og begge gir en hash
      som ser riktig ut og ikke stemmer med noen vektor. }
    SetLength(Block, Length(Salt) + 4);
    if Length(Salt) > 0 then
      Move(Salt[0], Block[0], Length(Salt));
    Block[Length(Salt)]     := Byte((I shr 24) and $FF);
    Block[Length(Salt) + 1] := Byte((I shr 16) and $FF);
    Block[Length(Salt) + 2] := Byte((I shr 8) and $FF);
    Block[Length(Salt) + 3] := Byte(I and $FF);

    U := HmacSha256(PwBytes, Block);
    T := U;
    for J := 2 to Iterations do
    begin
      SetLength(Block, 32);
      Move(U[0], Block[0], 32);
      U := HmacSha256(PwBytes, Block);
      for K := 0 to 31 do
        T[K] := T[K] xor U[K];
    end;

    Take := DkLen - Out_;
    if Take > 32 then
      Take := 32;
    Move(T[0], Result[Out_], Take);
    Inc(Out_, Take);
  end;
end;

{$pop}

{ ------------------------------------------------------ konstant tid -- }

function ConstantTimeEquals(const A, B: TBytes): Boolean;
var
  Diff, I: Integer;
begin
  { Ulik lengde er i seg selv en lekkasje, men en uunngåelig en: lengden på
    en hash er offentlig. Det som ikke skal lekke, er *hvor* de er ulike,
    og derfor går løkka alltid hele veien. }
  if Length(A) <> Length(B) then
    Exit(False);
  Diff := 0;
  for I := 0 to Length(A) - 1 do
    Diff := Diff or (A[I] xor B[I]);
  Result := Diff = 0;
end;

function ConstantTimeEquals(const A, B: string): Boolean;
var
  Diff, I: Integer;
begin
  if Length(A) <> Length(B) then
    Exit(False);
  Diff := 0;
  for I := 1 to Length(A) do
    Diff := Diff or (Ord(A[I]) xor Ord(B[I]));
  Result := Diff = 0;
end;

{ ---------------------------------------------------------------- base64 -- }

const
  B64Std = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  B64Url = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  HexChars = '0123456789abcdef';

function EncodeWith(const Data: TBytes; const Alphabet: string;
  Pad: Boolean): string;
var
  I, N, Rest: Integer;
  V: Cardinal;
begin
  N := Length(Data);
  Result := '';
  I := 0;
  while I + 3 <= N do
  begin
    V := (Cardinal(Data[I]) shl 16) or (Cardinal(Data[I + 1]) shl 8) or
      Cardinal(Data[I + 2]);
    Result := Result + Alphabet[((V shr 18) and 63) + 1] +
      Alphabet[((V shr 12) and 63) + 1] + Alphabet[((V shr 6) and 63) + 1] +
      Alphabet[(V and 63) + 1];
    Inc(I, 3);
  end;
  Rest := N - I;
  if Rest = 1 then
  begin
    V := Cardinal(Data[I]) shl 16;
    Result := Result + Alphabet[((V shr 18) and 63) + 1] +
      Alphabet[((V shr 12) and 63) + 1];
    if Pad then
      Result := Result + '==';
  end
  else if Rest = 2 then
  begin
    V := (Cardinal(Data[I]) shl 16) or (Cardinal(Data[I + 1]) shl 8);
    Result := Result + Alphabet[((V shr 18) and 63) + 1] +
      Alphabet[((V shr 12) and 63) + 1] + Alphabet[((V shr 6) and 63) + 1];
    if Pad then
      Result := Result + '=';
  end;
end;

function DecodeWith(const S: string; const Alphabet: string): TBytes;
var
  Value_: array[0..255] of ShortInt;
  I, N, Bits, Acc, Out_: Integer;
  C: Char;
begin
  Result := nil;
  FillChar(Value_, SizeOf(Value_), Byte(-1));
  for I := 1 to Length(Alphabet) do
    Value_[Ord(Alphabet[I])] := I - 1;

  SetLength(Result, (Length(S) * 3) div 4 + 3);
  Acc := 0;
  Bits := 0;
  Out_ := 0;
  N := Length(S);
  for I := 1 to N do
  begin
    C := S[I];
    if C = '=' then
      Break;
    if Value_[Ord(C)] < 0 then
      raise ECryptoError.Create('Invalid base64 input');
    Acc := (Acc shl 6) or Value_[Ord(C)];
    Inc(Bits, 6);
    if Bits >= 8 then
    begin
      Dec(Bits, 8);
      Result[Out_] := Byte((Acc shr Bits) and $FF);
      Inc(Out_);
    end;
  end;
  SetLength(Result, Out_);
end;

function Base64Encode(const Data: TBytes): string;
begin
  Result := EncodeWith(Data, B64Std, True);
end;

function Base64Decode(const S: string): TBytes;
begin
  Result := DecodeWith(S, B64Std);
end;

function Base64UrlEncode(const Data: TBytes): string;
begin
  Result := EncodeWith(Data, B64Url, False);
end;

function Base64UrlDecode(const S: string): TBytes;
begin
  Result := DecodeWith(S, B64Url);
end;

function HexEncode(const Data: TBytes): string;
var
  I: Integer;
begin
  SetLength(Result, Length(Data) * 2);
  for I := 0 to Length(Data) - 1 do
  begin
    Result[I * 2 + 1] := HexChars[(Data[I] shr 4) + 1];
    Result[I * 2 + 2] := HexChars[(Data[I] and $0F) + 1];
  end;
end;

function HexVal(C: Char): Integer;
begin
  case C of
    '0'..'9': Result := Ord(C) - Ord('0');
    'a'..'f': Result := Ord(C) - Ord('a') + 10;
    'A'..'F': Result := Ord(C) - Ord('A') + 10;
  else
    raise ECryptoError.Create('Invalid hex input');
  end;
end;

function HexDecode(const S: string): TBytes;
var
  I: Integer;
begin
  Result := nil;
  if Length(S) mod 2 <> 0 then
    raise ECryptoError.Create('Hex input must have an even length');
  SetLength(Result, Length(S) div 2);
  for I := 0 to Length(Result) - 1 do
    Result[I] := Byte(HexVal(S[I * 2 + 1]) shl 4) or Byte(HexVal(S[I * 2 + 2]));
end;

{ ----------------------------------------------------------- passord -- }

const
  PhcPrefix = '$pbkdf2-sha256$i=';

function HashPassword(const Password: string; Iterations: Integer): string;
var
  Salt, Dk: TBytes;
begin
  if Iterations < 1 then
    raise ECryptoError.Create('Password hashing needs at least one iteration');
  { 16 byte salt er det PHC-formatet og OWASP begge lander på. Saltet er
    ikke hemmelig — det står i klartekst i hashen — men det må være unikt
    per passord, og derfor kommer det fra CSPRNG-en og ikke fra brukeren. }
  Salt := RandomBytes(16);
  Dk := Pbkdf2Sha256(Password, Salt, Iterations, 32);
  Result := PhcPrefix + IntToStr(Iterations) + '$' + Base64UrlEncode(Salt) +
    '$' + Base64UrlEncode(Dk);
end;

{ Plukker fra hverandre `$pbkdf2-sha256$i=N$salt$hash`. Returnerer False i
  stedet for å kaste: et ødelagt felt i databasen skal bli en avvist
  innlogging, ikke en 500. }
function ParsePhc(const Hash: string; out Iterations: Integer;
  out Salt, Dk: TBytes): Boolean;
var
  Rest, ItStr, SaltStr, DkStr: string;
  P: Integer;
begin
  Result := False;
  Iterations := 0;
  SetLength(Salt, 0);
  SetLength(Dk, 0);

  if Copy(Hash, 1, Length(PhcPrefix)) <> PhcPrefix then
    Exit;
  Rest := Copy(Hash, Length(PhcPrefix) + 1, MaxInt);

  P := Pos('$', Rest);
  if P <= 1 then
    Exit;
  ItStr := Copy(Rest, 1, P - 1);
  Rest := Copy(Rest, P + 1, MaxInt);

  P := Pos('$', Rest);
  if P <= 1 then
    Exit;
  SaltStr := Copy(Rest, 1, P - 1);
  DkStr := Copy(Rest, P + 1, MaxInt);
  if DkStr = '' then
    Exit;

  if not TryStrToInt(ItStr, Iterations) then
    Exit;
  if Iterations < 1 then
    Exit;

  try
    Salt := Base64UrlDecode(SaltStr);
    Dk := Base64UrlDecode(DkStr);
  except
    on ECryptoError do
      Exit;
  end;
  if (Length(Salt) = 0) or (Length(Dk) = 0) then
    Exit;
  Result := True;
end;

function VerifyPassword(const Password, Hash: string): Boolean;
var
  Iterations: Integer;
  Salt, Dk, Mine: TBytes;
begin
  if not ParsePhc(Hash, Iterations, Salt, Dk) then
    Exit(False);
  { Lengden tas fra den lagrede hashen, ikke antatt til 32. Da virker en
    hash laget med andre parametre, og sammenligningen er alltid mot like
    lange tabeller. }
  Mine := Pbkdf2Sha256(Password, Salt, Iterations, Length(Dk));
  Result := ConstantTimeEquals(Mine, Dk);
end;

function NeedsRehash(const Hash: string; Iterations: Integer): Boolean;
var
  Has_: Integer;
  Salt, Dk: TBytes;
begin
  if not ParsePhc(Hash, Has_, Salt, Dk) then
    Exit(True);
  Result := Has_ < Iterations;
end;


{ ------------------------------------------------------------ appnøkkel -- }

var
  GAppKey: TBytes;

procedure SetAppKey(const Key: string);
begin
  if Key = '' then
  begin
    GAppKey := nil;
    Exit;
  end;
  { Nøkkelen skrives som base64 i .env. Er den ikke det, brukes tegnene
    som de står — en passfrase er svakere enn 32 tilfeldige byte, men å
    avvise den ville gjort at en app ikke starter av en grunn som ikke er
    sikkerhet. }
  try
    GAppKey := Base64Decode(Key);
  except
    on ECryptoError do
    begin
      SetLength(GAppKey, Length(Key));
      Move(Key[1], GAppKey[0], Length(Key));
    end;
  end;
  if Length(GAppKey) = 0 then
    GAppKey := nil;
end;

function HasAppKey: Boolean;
begin
  Result := Length(GAppKey) > 0;
end;

function AppKey: TBytes;
begin
  if Length(GAppKey) = 0 then
    raise ECryptoError.Create(
      'No application key is set. Put APP_KEY in .env (generate one with ' +
      '"askr key:generate") and call SetAppKey at startup.');
  Result := GAppKey;
end;

function GenerateAppKey: string;
begin
  Result := Base64Encode(RandomBytes(32));
end;

function Sign(const Payload: string): string;
var
  D: TSha256Digest;
  B: TBytes;
begin
  D := HmacSha256(AppKey, Bytes_(Payload));
  SetLength(B, 32);
  Move(D[0], B[0], 32);
  Result := Payload + '.' + Base64UrlEncode(B);
end;

function Unsign(const Signed: string; out Payload: string): Boolean;
var
  P, I: Integer;
  Sig: string;
  D: TSha256Digest;
  B: TBytes;
begin
  Payload := '';
  { Siste punktum skiller, ikke det første: teksten kan selv inneholde
    punktum, signaturen kan ikke. }
  P := 0;
  for I := Length(Signed) downto 1 do
    if Signed[I] = '.' then
    begin
      P := I;
      Break;
    end;
  if P <= 1 then
    Exit(False);

  Payload := Copy(Signed, 1, P - 1);
  Sig := Copy(Signed, P + 1, MaxInt);

  D := HmacSha256(AppKey, Bytes_(Payload));
  SetLength(B, 32);
  Move(D[0], B[0], 32);
  Result := ConstantTimeEquals(Base64UrlEncode(B), Sig);
  if not Result then
    Payload := '';
end;

end.
