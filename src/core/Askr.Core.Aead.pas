{ Askr.Core.Aead — ChaCha20-Poly1305, RFC 8439, in Pascal.

      Sealed := SealText(Secret, 'totp');
      if OpenText(Sealed, 'totp', Secret) then ...

  Encryption that also proves the text was not changed, for a secret that
  has to be kept in the database and read back -- a TOTP secret, above
  all. A table that leaks should not hand out the codes too.

  **Why ChaCha20-Poly1305, and why here.** The crypto in Askr is Pascal,
  not OpenSSL, for the reason in Askr.Core.Crypto: the binary has to start
  on a machine without it. AES is the other standard choice, and is table
  lookups that leak timing in software; ChaCha20 is additions, rotations
  and XOR, which do not. Both come with vectors; RFC 8439's are in the
  suite, and python-cryptography reads what this writes.

  Not a construction of our own. HMAC in counter mode with a MAC after it
  would have worked, and would have had no vectors to hold it to -- only
  the belief that it was right.

  SealText keys with APP_KEY, and a new APP_KEY makes everything sealed
  with the old one unreadable. That is rotating a key; plan for it before
  doing it to a table of TOTP secrets. }
unit Askr.Core.Aead;

{$mode Delphi}{$H+}

interface

uses
  SysUtils;

type
  EAeadError = class(Exception);

{ One 64-byte block of keystream. Key is 32 bytes, Nonce 12. }
function ChaCha20Block(const Key: TBytes; Counter: Cardinal;
  const Nonce: TBytes): TBytes;
{ Data XORed with the keystream from block Counter on: encryption and
  decryption are the same thing. }
function ChaCha20Xor(const Key: TBytes; Counter: Cardinal;
  const Nonce, Data: TBytes): TBytes;
{ The 16-byte tag of Msg under a one-time 32-byte key. }
function Poly1305(const Key, Msg: TBytes): TBytes;

{ RFC 8439 section 2.8: the ciphertext with the 16-byte tag after it. A
  nonce is used once per key, never again -- SealText makes a random one
  each time. }
function AeadSeal(const Key, Nonce, Aad, Plain: TBytes): TBytes;
{ False when the tag does not match: changed, cut short, the wrong key,
  or the wrong Aad. Plain is empty then, and nothing is decrypted before
  the tag is checked. }
function AeadOpen(const Key, Nonce, Aad, Sealed: TBytes;
  out Plain: TBytes): Boolean;

(* Plain sealed under APP_KEY, as text for a column: v1.<base64url of
   nonce, ciphertext and tag>. Purpose is bound in as associated data, so
   a value sealed for one thing does not open as another -- a TOTP secret
   copied into another column stays shut. *)
function SealText(const Plain, Purpose: string): string;
function OpenText(const Sealed, Purpose: string; out Plain: string): Boolean;

implementation

uses
  Askr.Core.Crypto;

{$push}{$R-}{$Q-}

function Le32(const B: TBytes; At: Integer): Cardinal; inline;
begin
  Result := Cardinal(B[At]) or (Cardinal(B[At + 1]) shl 8) or
    (Cardinal(B[At + 2]) shl 16) or (Cardinal(B[At + 3]) shl 24);
end;

procedure PutLe32(var B: TBytes; At: Integer; V: Cardinal); inline;
begin
  B[At] := V and $FF;
  B[At + 1] := (V shr 8) and $FF;
  B[At + 2] := (V shr 16) and $FF;
  B[At + 3] := (V shr 24) and $FF;
end;

function Rotl(V: Cardinal; N: Integer): Cardinal; inline;
begin
  Result := (V shl N) or (V shr (32 - N));
end;

procedure QuarterRound(var X: array of Cardinal; A, B, C, D: Integer); inline;
begin
  X[A] := X[A] + X[B]; X[D] := Rotl(X[D] xor X[A], 16);
  X[C] := X[C] + X[D]; X[B] := Rotl(X[B] xor X[C], 12);
  X[A] := X[A] + X[B]; X[D] := Rotl(X[D] xor X[A], 8);
  X[C] := X[C] + X[D]; X[B] := Rotl(X[B] xor X[C], 7);
end;

function ChaCha20Block(const Key: TBytes; Counter: Cardinal;
  const Nonce: TBytes): TBytes;
var
  State, X: array[0..15] of Cardinal;
  I: Integer;
begin
  if Length(Key) <> 32 then
    raise EAeadError.Create('A ChaCha20 key is 32 bytes');
  if Length(Nonce) <> 12 then
    raise EAeadError.Create('A ChaCha20 nonce is 12 bytes');
  State[0] := $61707865;
  State[1] := $3320646E;
  State[2] := $79622D32;
  State[3] := $6B206574;
  for I := 0 to 7 do
    State[4 + I] := Le32(Key, I * 4);
  State[12] := Counter;
  for I := 0 to 2 do
    State[13 + I] := Le32(Nonce, I * 4);
  X := State;
  for I := 1 to 10 do
  begin
    QuarterRound(X, 0, 4, 8, 12);
    QuarterRound(X, 1, 5, 9, 13);
    QuarterRound(X, 2, 6, 10, 14);
    QuarterRound(X, 3, 7, 11, 15);
    QuarterRound(X, 0, 5, 10, 15);
    QuarterRound(X, 1, 6, 11, 12);
    QuarterRound(X, 2, 7, 8, 13);
    QuarterRound(X, 3, 4, 9, 14);
  end;
  Result := nil;
  SetLength(Result, 64);
  for I := 0 to 15 do
    PutLe32(Result, I * 4, X[I] + State[I]);
end;

function ChaCha20Xor(const Key: TBytes; Counter: Cardinal;
  const Nonce, Data: TBytes): TBytes;
var
  Block: TBytes;
  I, J, N: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Data));
  I := 0;
  while I < Length(Data) do
  begin
    Block := ChaCha20Block(Key, Counter, Nonce);
    Inc(Counter);
    N := Length(Data) - I;
    if N > 64 then
      N := 64;
    for J := 0 to N - 1 do
      Result[I + J] := Data[I + J] xor Block[J];
    Inc(I, 64);
  end;
end;

{ Poly1305 in five 26-bit limbs, as poly1305-donna does it: a product of
  two limbs and the sums of five of them fit in 64 bits, so nothing needs
  a wider type than Pascal has. }
function Poly1305(const Key, Msg: TBytes): TBytes;
const
  M26 = $3FFFFFF;
var
  R0, R1, R2, R3, R4, S1, S2, S3, S4: Cardinal;
  H0, H1, H2, H3, H4, C, G0, G1, G2, G3, G4, Mask, HiBit: Cardinal;
  D0, D1, D2, D3, D4, F: UInt64;
  Block: TBytes;
  I, N, Pos_: Integer;
begin
  if Length(Key) <> 32 then
    raise EAeadError.Create('A Poly1305 key is 32 bytes');
  { r is clamped as the RFC says: some bits of it are always 0. }
  R0 := Le32(Key, 0) and $3FFFFFF;
  R1 := (Le32(Key, 3) shr 2) and $3FFFF03;
  R2 := (Le32(Key, 6) shr 4) and $3FFC0FF;
  R3 := (Le32(Key, 9) shr 6) and $3F03FFF;
  R4 := (Le32(Key, 12) shr 8) and $00FFFFF;
  S1 := R1 * 5; S2 := R2 * 5; S3 := R3 * 5; S4 := R4 * 5;
  H0 := 0; H1 := 0; H2 := 0; H3 := 0; H4 := 0;
  Block := nil;
  SetLength(Block, 17);
  Pos_ := 0;
  while Pos_ < Length(Msg) do
  begin
    N := Length(Msg) - Pos_;
    if N >= 16 then
    begin
      N := 16;
      HiBit := 1 shl 24;
      for I := 0 to 15 do
        Block[I] := Msg[Pos_ + I];
    end
    else
    begin
      { A short last block: a 1 after the bytes, zeros after that, and no
        high bit -- the 1 is in the block itself. }
      HiBit := 0;
      for I := 0 to 16 do
        Block[I] := 0;
      for I := 0 to N - 1 do
        Block[I] := Msg[Pos_ + I];
      Block[N] := 1;
    end;
    H0 := H0 + (Le32(Block, 0) and M26);
    H1 := H1 + ((Le32(Block, 3) shr 2) and M26);
    H2 := H2 + ((Le32(Block, 6) shr 4) and M26);
    H3 := H3 + ((Le32(Block, 9) shr 6) and M26);
    H4 := H4 + ((Le32(Block, 12) shr 8) or HiBit);

    D0 := UInt64(H0) * R0 + UInt64(H1) * S4 + UInt64(H2) * S3 + UInt64(H3) * S2 + UInt64(H4) * S1;
    D1 := UInt64(H0) * R1 + UInt64(H1) * R0 + UInt64(H2) * S4 + UInt64(H3) * S3 + UInt64(H4) * S2;
    D2 := UInt64(H0) * R2 + UInt64(H1) * R1 + UInt64(H2) * R0 + UInt64(H3) * S4 + UInt64(H4) * S3;
    D3 := UInt64(H0) * R3 + UInt64(H1) * R2 + UInt64(H2) * R1 + UInt64(H3) * R0 + UInt64(H4) * S4;
    D4 := UInt64(H0) * R4 + UInt64(H1) * R3 + UInt64(H2) * R2 + UInt64(H3) * R1 + UInt64(H4) * R0;

    C := Cardinal(D0 shr 26); H0 := Cardinal(D0) and M26;
    D1 := D1 + C; C := Cardinal(D1 shr 26); H1 := Cardinal(D1) and M26;
    D2 := D2 + C; C := Cardinal(D2 shr 26); H2 := Cardinal(D2) and M26;
    D3 := D3 + C; C := Cardinal(D3 shr 26); H3 := Cardinal(D3) and M26;
    D4 := D4 + C; C := Cardinal(D4 shr 26); H4 := Cardinal(D4) and M26;
    H0 := H0 + C * 5; C := H0 shr 26; H0 := H0 and M26;
    H1 := H1 + C;
    Inc(Pos_, 16);
  end;

  { Carry all the way through. }
  C := H1 shr 26; H1 := H1 and M26;
  H2 := H2 + C; C := H2 shr 26; H2 := H2 and M26;
  H3 := H3 + C; C := H3 shr 26; H3 := H3 and M26;
  H4 := H4 + C; C := H4 shr 26; H4 := H4 and M26;
  H0 := H0 + C * 5; C := H0 shr 26; H0 := H0 and M26;
  H1 := H1 + C;

  { h - p, and h itself when that goes below zero: chosen with a mask, not
    a branch, so the time taken does not depend on the value. }
  G0 := H0 + 5; C := G0 shr 26; G0 := G0 and M26;
  G1 := H1 + C; C := G1 shr 26; G1 := G1 and M26;
  G2 := H2 + C; C := G2 shr 26; G2 := G2 and M26;
  G3 := H3 + C; C := G3 shr 26; G3 := G3 and M26;
  G4 := H4 + C - (1 shl 26);
  Mask := (G4 shr 31) - 1;
  G0 := G0 and Mask; G1 := G1 and Mask; G2 := G2 and Mask;
  G3 := G3 and Mask; G4 := G4 and Mask;
  Mask := not Mask;
  H0 := (H0 and Mask) or G0; H1 := (H1 and Mask) or G1;
  H2 := (H2 and Mask) or G2; H3 := (H3 and Mask) or G3;
  H4 := (H4 and Mask) or G4;

  { Back to four 32-bit words, and s added. }
  H0 := H0 or (H1 shl 26);
  H1 := (H1 shr 6) or (H2 shl 20);
  H2 := (H2 shr 12) or (H3 shl 14);
  H3 := (H3 shr 18) or (H4 shl 8);
  F := UInt64(H0) + Le32(Key, 16); H0 := Cardinal(F);
  F := UInt64(H1) + Le32(Key, 20) + (F shr 32); H1 := Cardinal(F);
  F := UInt64(H2) + Le32(Key, 24) + (F shr 32); H2 := Cardinal(F);
  F := UInt64(H3) + Le32(Key, 28) + (F shr 32); H3 := Cardinal(F);

  Result := nil;
  SetLength(Result, 16);
  PutLe32(Result, 0, H0);
  PutLe32(Result, 4, H1);
  PutLe32(Result, 8, H2);
  PutLe32(Result, 12, H3);
end;

{$pop}

function Concat_(const A, B: TBytes): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(A) + Length(B));
  if Length(A) > 0 then
    Move(A[0], Result[0], Length(A));
  if Length(B) > 0 then
    Move(B[0], Result[Length(A)], Length(B));
end;

{ What the tag is over: the associated data and the ciphertext, each
  padded to 16 bytes, and then both lengths as 64-bit little-endian. }
function MacData(const Aad, Cipher: TBytes): TBytes;
var
  Pad, Lens: TBytes;
  I: Integer;
  L: UInt64;
begin
  Pad := nil;
  Result := Aad;
  SetLength(Pad, (16 - Length(Aad) mod 16) mod 16);
  Result := Concat_(Result, Pad);
  Result := Concat_(Result, Cipher);
  SetLength(Pad, (16 - Length(Cipher) mod 16) mod 16);
  Result := Concat_(Result, Pad);
  Lens := nil;
  SetLength(Lens, 16);
  L := Length(Aad);
  for I := 0 to 7 do
    Lens[I] := (L shr (8 * I)) and $FF;
  L := Length(Cipher);
  for I := 0 to 7 do
    Lens[8 + I] := (L shr (8 * I)) and $FF;
  Result := Concat_(Result, Lens);
end;

function OneTimeKey(const Key, Nonce: TBytes): TBytes;
begin
  Result := Copy(ChaCha20Block(Key, 0, Nonce), 0, 32);
end;

function AeadSeal(const Key, Nonce, Aad, Plain: TBytes): TBytes;
var
  Cipher: TBytes;
begin
  Cipher := ChaCha20Xor(Key, 1, Nonce, Plain);
  Result := Concat_(Cipher, Poly1305(OneTimeKey(Key, Nonce), MacData(Aad, Cipher)));
end;

function AeadOpen(const Key, Nonce, Aad, Sealed: TBytes;
  out Plain: TBytes): Boolean;
var
  Cipher, Tag: TBytes;
begin
  Plain := nil;
  if Length(Sealed) < 16 then
    Exit(False);
  Cipher := Copy(Sealed, 0, Length(Sealed) - 16);
  Tag := Copy(Sealed, Length(Sealed) - 16, 16);
  { The tag first, and nothing decrypted unless it holds. }
  if not ConstantTimeEquals(Poly1305(OneTimeKey(Key, Nonce), MacData(Aad, Cipher)), Tag) then
    Exit(False);
  Plain := ChaCha20Xor(Key, 1, Nonce, Cipher);
  Result := True;
end;

function TextBytes(const S: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(S));
  if S <> '' then
    Move(S[1], Result[0], Length(S));
end;

{ The key SealText uses: APP_KEY through HMAC with a label of its own, so
  it is never the key anything else is signed with. }
function SealKey: TBytes;
var
  D: TSha256Digest;
begin
  D := HmacSha256(AppKey, TextBytes('askr.seal'));
  Result := nil;
  SetLength(Result, 32);
  Move(D[0], Result[0], 32);
end;

function SealText(const Plain, Purpose: string): string;
var
  Nonce: TBytes;
begin
  Nonce := RandomBytes(12);
  Result := 'v1.' + Base64UrlEncode(Concat_(Nonce,
    AeadSeal(SealKey, Nonce, TextBytes(Purpose), TextBytes(Plain))));
end;

function OpenText(const Sealed, Purpose: string; out Plain: string): Boolean;
var
  Raw, Nonce, P: TBytes;
begin
  Plain := '';
  if Copy(Sealed, 1, 3) <> 'v1.' then
    Exit(False);
  try
    Raw := Base64UrlDecode(Copy(Sealed, 4, MaxInt));
  except
    on Exception do
      Exit(False);
  end;
  if Length(Raw) < 12 + 16 then
    Exit(False);
  Nonce := Copy(Raw, 0, 12);
  if not AeadOpen(SealKey, Nonce, TextBytes(Purpose), Copy(Raw, 12, MaxInt), P) then
    Exit(False);
  SetLength(Plain, Length(P));
  if Length(P) > 0 then
    Move(P[0], Plain[1], Length(P));
  Result := True;
end;

end.
