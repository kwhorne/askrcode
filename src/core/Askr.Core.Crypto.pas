{ Askr.Core.Crypto — the foundation under CSRF, sessions and sign-in.

  Everything here is written in plain Pascal, without OpenSSL. That is a
  deliberate choice, and the reason is the PRD's first promise: the binary
  must start on a machine with no OpenSSL. If password hashing leans on
  libcrypto, no app with sign-in can run without it, and "optional
  dependency" becomes untrue. TLS is a different matter — an app behind a
  reverse proxy never needs Askr.Tls, while every app with users needs
  this.

  The price is that the password hash is **PBKDF2-HMAC-SHA256**, not
  Argon2id. OWASP considers PBKDF2 with a high iteration count defensible,
  but Argon2id is the recommendation in 2026 because it also costs memory
  and is therefore more expensive to attack with specialised hardware. It
  is a compromise, not free, and it is stated here rather than hidden.

  Randomness comes from the kernel, never from `Random`. FPC's `Random` is
  a Mersenne Twister seeded from the clock: fine for test data and useless
  for a session id.

  The vectors the algorithms are tested against are in
  tests/askr_crypto_tests.lpr: the NIST vectors for SHA-256, RFC 4231 for
  HMAC-SHA256 and RFC 6070 (with the SHA-256 variant from RFC 7914) for
  PBKDF2. A crypto implementation without official vectors is a
  guess. }
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

{ Bytes from the operating system's CSPRNG. Raises if it cannot get them
  — randomness that quietly falls back to something weaker is worse than a
  process that does not start. }
function RandomBytes(Count: Integer): TBytes;
{ The same, hex encoded. `Count` is a number of bytes, so the string comes
  out twice as long. }
function RandomHex(Count: Integer): string;
{ The same, base64url without padding. The form that belongs in a cookie,
  a URL or a hidden form field. }
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

{ Compares without revealing where the two differ. An ordinary `=` on
  strings stops at the first difference, and the time it takes tells an
  attacker how far they have got. Used on every comparison of anything
  secret: tokens, signatures, hashes. }
function ConstantTimeEquals(const A, B: TBytes): Boolean; overload;
function ConstantTimeEquals(const A, B: string): Boolean; overload;

{ ---------------------------------------------------------------- base64 -- }

function Base64Encode(const Data: TBytes): string;
function Base64Decode(const S: string): TBytes;
{ base64url: `-` and `_` instead of `+` and `/`, and no `=` at the end.
  Safe in a URL, in a filename and in a cookie value. }
function Base64UrlEncode(const Data: TBytes): string;
function Base64UrlDecode(const S: string): TBytes;

function HexEncode(const Data: TBytes): string;
function HexDecode(const S: string): TBytes;

{ ---------------------------------------------------------------- PBKDF2 -- }

function Pbkdf2Sha256(const Password: string; const Salt: TBytes;
  Iterations, DkLen: Integer): TBytes;

{ ----------------------------------------------------------- passord -- }

const
  { OWASP's recommendation for PBKDF2-HMAC-SHA256 is 600 000 in 2026. The
    number is carried in the hash, so raising it later does not invalidate
    old hashes — NeedsRehash says so, and the next sign-in upgrades
    them. }
  DefaultPbkdf2Iterations = 600000;

{ Hashes a password. The result is a PHC string carrying the algorithm,
  the iteration count and the salt:

  $pbkdf2-sha256$i=600000$<salt>$<hash>

  The whole string is stored in the database. That is what lets the
  parameters change without a migration. }
function HashPassword(const Password: string;
  Iterations: Integer = DefaultPbkdf2Iterations): string;
{ Checks a password against a hash from HashPassword. Returns False on a
  hash it does not recognise — never an exception, because then a corrupt
  field in the database would become a 500 rather than a refused
  sign-in. }
function VerifyPassword(const Password, Hash: string): Boolean;
{ True if the hash was made with weaker parameters than today's. Called
  after a successful VerifyPassword: the plaintext password is in hand
  then, and a new hash can be written without asking the user
  anything. }
function NeedsRehash(const Hash: string;
  Iterations: Integer = DefaultPbkdf2Iterations): Boolean;

{ --------------------------------------------------------- the app key -- }

{ The app's signing key. One key for the whole app, used for everything
  that has to be provably from us: the "remember me" cookie, signed URLs,
  and encryption later.

  The key comes from the environment, never from the source. Replace it
  and everything signed with the previous one becomes invalid — that is
  the whole point of being able to replace it. }
procedure SetAppKey(const Key: string);
{ The key as bytes. Raises if it is not set: an app signing with an empty
  key signs nothing, and it should not be possible to reach that state
  without noticing. }
function AppKey: TBytes;
function HasAppKey: Boolean;
{ A new key, for `askr key:generate` and for .env.example. }
function GenerateAppKey: string;

{ Signs a piece of text with the app key. The result is
  `<text>.<signature>`, and the text is **readable** — the signature
  proves it has not been changed, it does not hide it. Never put anything
  secret in a signed value. }
function Sign(const Payload: string): string;
{ Checks the signature and gives the text back. False if it does not
  match, is missing or has been tampered with. The comparison runs in
  constant time. }
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
{ BCryptGenRandom is Windows' CSPRNG. Flag 2 is
  BCRYPT_USE_SYSTEM_PREFERRED_RNG, which saves us opening an algorithm
  handle first. This path is written but never run — like the rest of the
  Windows support in Askr. }
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
    { A short read is legal from a file descriptor, urandom included. The
      loop is not pedantry — without it half the key could be zeroes. }
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

{ SHA-256 works modulo 2^32, and the additions overflow on purpose.
  Without this marking the whole unit crashes with ERangeError in any
  build with -Cr or -Co, which ./askr check does. The same reason as the
  FNV hashes in Askr.Cache. }
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
  { Big-endian in. SHA-256 is specified in network order and the machine
    underneath is little-endian; get this wrong and no vector matches. }
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
  { Padding: one 1 bit, then zeroes, then the length in bits as a 64-bit
    big-endian value. If the length does not fit in this block, it goes in
    another one. }
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
  { A key longer than the block is hashed first. That is not an
    optimisation, it is in RFC 2104 — and without it RFC 4231 vector 6
    does not match. }
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
    { U1 = HMAC(P, S || INT_BE32(i)). The block counter is 1-based and
      big-endian — both are easy to get wrong, and both give a hash that
      looks right and matches no vector. }
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
  { Differing lengths are themselves a leak, but an unavoidable one: the
    length of a hash is public. What must not leak is *where* they differ,
    which is why the loop always runs all the way. }
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
  { A 16-byte salt is what the PHC format and OWASP both land on. The salt
    is not secret — it sits in cleartext in the hash — but it has to be
    unique per password, which is why it comes from the CSPRNG and not
    from the user. }
  Salt := RandomBytes(16);
  Dk := Pbkdf2Sha256(Password, Salt, Iterations, 32);
  Result := PhcPrefix + IntToStr(Iterations) + '$' + Base64UrlEncode(Salt) +
    '$' + Base64UrlEncode(Dk);
end;

{ Takes `$pbkdf2-sha256$i=N$salt$hash` apart. Returns False rather than
  raising: a corrupt field in the database should become a refused
  sign-in, not a 500. }
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
  { The length is taken from the stored hash rather than assumed to be 32.
    That way a hash made with other parameters still works, and the
    comparison is always between tables of equal length. }
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


{ --------------------------------------------------------- the app key -- }

var
  GAppKey: TBytes;

procedure SetAppKey(const Key: string);
begin
  if Key = '' then
  begin
    GAppKey := nil;
    Exit;
  end;
  { The key is written as base64 in .env. If it is not, the characters are
    used as they stand — a passphrase is weaker than 32 random bytes, but
    refusing it would stop an app from starting for a reason that is not
    security. }
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
  { The last dot separates, not the first: the text may itself contain
    dots, the signature cannot. }
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
