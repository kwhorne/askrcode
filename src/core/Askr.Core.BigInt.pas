{ Askr.Core.BigInt — 256-bit integer arithmetic.

  It exists for ECDSA verification, which in turn exists for WebAuthn.
  Askr has no general bignum package and is not going to get one: this is
  exactly what P-256 needs, at a fixed width, and nothing more.

  THE LIMBS ARE 32 BITS, NOT 64

  A product of two 32-bit numbers fits in a UInt64 with room to spare —
  even with two carries added:

    $FFFFFFFF * $FFFFFFFF + $FFFFFFFF + $FFFFFFFF
      = $FFFFFFFFFFFFFFFF

  that is, just inside. With 64-bit limbs every product would have to be
  128 bits, and that type does not exist in Free Pascal. The price is
  roughly twice as many operations; the gain is that nothing here
  overflows, so the unit needs no range or overflow checking turned off
  and passes `./askr check` as it stands. It is a deliberate trade in code
  where a silent error cannot be spotted by reading.

  The limbs are stored least significant first. On the outside the format
  is big-endian byte order, because that is how keys and signatures
  arrive over the network. }
unit Askr.Core.BigInt;

{$mode Delphi}{$H+}

interface

uses
  SysUtils;

const
  U256Limbs = 8;          { 8 x 32 bit = 256 }
  U512Limbs = 16;
  U256Bytes = 32;

type
  { 256 bit. Lemme 0 er minst signifikant. }
  TU256 = record
    L: array[0..U256Limbs - 1] of UInt32;
  end;

  { 512 bits. The product of two TU256 fits here. }
  TU512 = record
    L: array[0..U512Limbs - 1] of UInt32;
  end;

{ ------------------------------------------------------------ grunnlag -- }

procedure U256SetZero(out A: TU256);
procedure U256SetU32(out A: TU256; V: UInt32);
function U256IsZero(const A: TU256): Boolean;

{ -1, 0 eller 1. }
function U256Cmp(const A, B: TU256): Integer;

{ Bit nummer I, 0 = minst signifikant. }
function U256Bit(const A: TU256; I: Integer): Integer;
{ The index of the highest set bit, or -1 for zero. }
function U256HighBit(const A: TU256): Integer;

{ ---------------------------------------------------------- aritmetikk -- }

{ Returns the carry out (0 or 1). R may be the same variable as A. }
function U256Add(const A, B: TU256; out R: TU256): UInt32;
{ Returns the borrow out (0 or 1), that is 1 when A < B. }
function U256Sub(const A, B: TU256; out R: TU256): UInt32;

procedure U256Mul(const A, B: TU256; out R: TU512);
procedure U256Sqr(const A: TU256; out R: TU512);

{ Skifter én bit. Returnerer biten som falt ut. }
function U256ShlOne(var A: TU256): UInt32;
function U256ShrOne(var A: TU256): UInt32;

{ ------------------------------------------------------------- 512 bit -- }

procedure U512SetZero(out A: TU512);
function U512Cmp(const A, B: TU512): Integer;
function U512Sub(const A, B: TU512; out R: TU512): UInt32;
{ The low and the high 256 bits respectively. }
procedure U512Low(const A: TU512; out R: TU256);
procedure U512High(const A: TU512; out R: TU256);
{ Utvider 256 til 512. }
procedure U256To512(const A: TU256; out R: TU512);

{ Full 512 x 512 multiplikasjon, avkortet til 512 bit. }
procedure U512MulLow(const A, B: TU512; out R: TU512);

{ Shifts a 512-bit number Count limbs to the right, that is divides by
  2^(32*Count). }
procedure U512ShrLimbs(const A: TU512; Count_: Integer; out R: TU512);

{ ---------------------------------------------------------------- byte -- }

{ Big-endian, 32 bytes. False when the length is wrong. }
function U256FromBytes(const B: array of Byte; out R: TU256): Boolean;
procedure U256ToBytes(const A: TU256; var B: array of Byte);

{ Hex, for use in tests and constants. Accepts upper and lower case and
  an optional 0x. Not meant for hot code. }
function U256FromHex(const S: string; out R: TU256): Boolean;
function U256ToHex(const A: TU256): string;

{ ----------------------------------------------------------- modulo M -- }

{ A + B mod M. Krever A, B < M. }
procedure ModAdd(const A, B, M: TU256; out R: TU256);
{ A - B mod M. Krever A, B < M. }
procedure ModSub(const A, B, M: TU256; out R: TU256);

{ Reduces a 512-bit number modulo M, with binary long division.

  Barrett would be faster, but needs intermediates of 545 bits: q1 * mu
  does not fit in 512, and a truncated multiplication throws away exactly
  the term you need. It would have required a 1024-bit type for two
  operations per verification. Reduction modulo n is used only when u1 and
  u2 are computed; the field modulo p takes the fast route in
  Askr.Core.Ec. }
procedure ModReduce(const X: TU512; const M: TU256; out R: TU256);

{ A * B mod M. }
procedure ModMul(const A, B, M: TU256; out R: TU256);

{ Inverse modulo M, with the binary extended Euclidean algorithm.

  Fermat — A^(M-2) — would have been shorter to write, but costs around
  384 multiplications modulo M. Binary Euclid costs around 512 rounds of
  shifting and subtraction, which is far less. The inverse is the most
  expensive single operation in a verification, so the difference shows.

  False when A is not invertible (a common factor with M). }
function ModInv(const A, M: TU256; out R: TU256): Boolean;

implementation

{ ------------------------------------------------------------ grunnlag -- }

procedure U256SetZero(out A: TU256);
var
  I: Integer;
begin
  for I := 0 to U256Limbs - 1 do
    A.L[I] := 0;
end;

procedure U256SetU32(out A: TU256; V: UInt32);
var
  I: Integer;
begin
  A.L[0] := V;
  for I := 1 to U256Limbs - 1 do
    A.L[I] := 0;
end;

function U256IsZero(const A: TU256): Boolean;
var
  I: Integer;
begin
  for I := 0 to U256Limbs - 1 do
    if A.L[I] <> 0 then
      Exit(False);
  Result := True;
end;

function U256Cmp(const A, B: TU256): Integer;
var
  I: Integer;
begin
  { From the top: the first differing limb decides. }
  for I := U256Limbs - 1 downto 0 do
  begin
    if A.L[I] < B.L[I] then Exit(-1);
    if A.L[I] > B.L[I] then Exit(1);
  end;
  Result := 0;
end;

function U256Bit(const A: TU256; I: Integer): Integer;
begin
  if (I < 0) or (I >= 256) then
    Exit(0);
  Result := Integer((A.L[I shr 5] shr (I and 31)) and 1);
end;

function U256HighBit(const A: TU256): Integer;
var
  I, B: Integer;
begin
  for I := U256Limbs - 1 downto 0 do
    if A.L[I] <> 0 then
    begin
      for B := 31 downto 0 do
        if (A.L[I] shr B) and 1 = 1 then
          Exit(I * 32 + B);
    end;
  Result := -1;
end;

{ ---------------------------------------------------------- aritmetikk -- }

function U256Add(const A, B: TU256; out R: TU256): UInt32;
var
  I: Integer;
  T: UInt64;
begin
  T := 0;
  for I := 0 to U256Limbs - 1 do
  begin
    T := UInt64(A.L[I]) + UInt64(B.L[I]) + T;
    R.L[I] := UInt32(T and $FFFFFFFF);
    T := T shr 32;
  end;
  Result := UInt32(T);
end;

function U256Sub(const A, B: TU256; out R: TU256): UInt32;
var
  I: Integer;
  T: UInt64;
  Borrow: UInt64;
begin
  Borrow := 0;
  for I := 0 to U256Limbs - 1 do
  begin
    { Adds 2^32 to keep the intermediate from going below zero. The extra
      bit becomes the borrow out, inverted. }
    T := (UInt64(A.L[I]) + $100000000) - UInt64(B.L[I]) - Borrow;
    R.L[I] := UInt32(T and $FFFFFFFF);
    if T < $100000000 then Borrow := 1 else Borrow := 0;
  end;
  Result := UInt32(Borrow);
end;

procedure U256Mul(const A, B: TU256; out R: TU512);
var
  I, J: Integer;
  T, Carry: UInt64;
begin
  U512SetZero(R);
  for I := 0 to U256Limbs - 1 do
  begin
    if A.L[I] = 0 then
      Continue;
    Carry := 0;
    for J := 0 to U256Limbs - 1 do
    begin
      { This is the line that decided the limb width. With 32-bit limbs the
        product plus two carries fits in a UInt64 exactly. }
      T := UInt64(A.L[I]) * UInt64(B.L[J]) + UInt64(R.L[I + J]) + Carry;
      R.L[I + J] := UInt32(T and $FFFFFFFF);
      Carry := T shr 32;
    end;
    R.L[I + U256Limbs] := UInt32(UInt64(R.L[I + U256Limbs]) + Carry);
  end;
end;

procedure U256Sqr(const A: TU256; out R: TU512);
begin
  { This could exploit the symmetry and save almost half. It does not: a
    separate squaring routine is a separate source of error, and it would
    demand vectors of its own. The multiplication has been tested. }
  U256Mul(A, A, R);
end;

function U256ShlOne(var A: TU256): UInt32;
var
  I: Integer;
  Inn, Ut: UInt32;
begin
  Inn := 0;
  for I := 0 to U256Limbs - 1 do
  begin
    Ut := A.L[I] shr 31;
    A.L[I] := (A.L[I] shl 1) or Inn;
    Inn := Ut;
  end;
  Result := Inn;
end;

function U256ShrOne(var A: TU256): UInt32;
var
  I: Integer;
  Inn, Ut: UInt32;
begin
  Inn := 0;
  for I := U256Limbs - 1 downto 0 do
  begin
    Ut := A.L[I] and 1;
    A.L[I] := (A.L[I] shr 1) or (Inn shl 31);
    Inn := Ut;
  end;
  Result := Inn;
end;

{ ------------------------------------------------------------- 512 bit -- }

procedure U512SetZero(out A: TU512);
var
  I: Integer;
begin
  for I := 0 to U512Limbs - 1 do
    A.L[I] := 0;
end;

function U512Cmp(const A, B: TU512): Integer;
var
  I: Integer;
begin
  for I := U512Limbs - 1 downto 0 do
  begin
    if A.L[I] < B.L[I] then Exit(-1);
    if A.L[I] > B.L[I] then Exit(1);
  end;
  Result := 0;
end;

function U512Sub(const A, B: TU512; out R: TU512): UInt32;
var
  I: Integer;
  T, Borrow: UInt64;
begin
  Borrow := 0;
  for I := 0 to U512Limbs - 1 do
  begin
    T := (UInt64(A.L[I]) + $100000000) - UInt64(B.L[I]) - Borrow;
    R.L[I] := UInt32(T and $FFFFFFFF);
    if T < $100000000 then Borrow := 1 else Borrow := 0;
  end;
  Result := UInt32(Borrow);
end;

procedure U512Low(const A: TU512; out R: TU256);
var
  I: Integer;
begin
  for I := 0 to U256Limbs - 1 do
    R.L[I] := A.L[I];
end;

procedure U512High(const A: TU512; out R: TU256);
var
  I: Integer;
begin
  for I := 0 to U256Limbs - 1 do
    R.L[I] := A.L[I + U256Limbs];
end;

procedure U256To512(const A: TU256; out R: TU512);
var
  I: Integer;
begin
  for I := 0 to U256Limbs - 1 do
    R.L[I] := A.L[I];
  for I := U256Limbs to U512Limbs - 1 do
    R.L[I] := 0;
end;

procedure U512MulLow(const A, B: TU512; out R: TU512);
var
  I, J: Integer;
  T, Carry: UInt64;
begin
  U512SetZero(R);
  for I := 0 to U512Limbs - 1 do
  begin
    if A.L[I] = 0 then
      Continue;
    Carry := 0;
    for J := 0 to U512Limbs - 1 - I do
    begin
      T := UInt64(A.L[I]) * UInt64(B.L[J]) + UInt64(R.L[I + J]) + Carry;
      R.L[I + J] := UInt32(T and $FFFFFFFF);
      Carry := T shr 32;
    end;
    { The carry out of the top is dropped deliberately: the call site uses
      only the low 512 bits. }
  end;
end;

procedure U512ShrLimbs(const A: TU512; Count_: Integer; out R: TU512);
var
  I: Integer;
begin
  U512SetZero(R);
  if Count_ >= U512Limbs then
    Exit;
  for I := 0 to U512Limbs - 1 - Count_ do
    R.L[I] := A.L[I + Count_];
end;

{ ---------------------------------------------------------------- byte -- }

function U256FromBytes(const B: array of Byte; out R: TU256): Boolean;
var
  I: Integer;
begin
  U256SetZero(R);
  if Length(B) <> U256Bytes then
    Exit(False);
  { Big-endian inn: B[0] er mest signifikant. }
  for I := 0 to U256Bytes - 1 do
    R.L[(U256Bytes - 1 - I) shr 2] :=
      R.L[(U256Bytes - 1 - I) shr 2] or
      (UInt32(B[I]) shl (((U256Bytes - 1 - I) and 3) * 8));
  Result := True;
end;

procedure U256ToBytes(const A: TU256; var B: array of Byte);
var
  I, Pos_: Integer;
begin
  if Length(B) < U256Bytes then
    Exit;
  for I := 0 to U256Bytes - 1 do
  begin
    Pos_ := U256Bytes - 1 - I;
    B[I] := Byte((A.L[Pos_ shr 2] shr ((Pos_ and 3) * 8)) and $FF);
  end;
end;

function HexValue(C: Char; out V: Integer): Boolean;
begin
  Result := True;
  case C of
    '0'..'9': V := Ord(C) - Ord('0');
    'a'..'f': V := Ord(C) - Ord('a') + 10;
    'A'..'F': V := Ord(C) - Ord('A') + 10;
  else
    V := 0;
    Result := False;
  end;
end;

function U256FromHex(const S: string; out R: TU256): Boolean;
var
  T: string;
  I, V, Bit: Integer;
begin
  U256SetZero(R);
  T := Trim(S);
  if (Length(T) > 2) and (T[1] = '0') and ((T[2] = 'x') or (T[2] = 'X')) then
    T := Copy(T, 3, Length(T));
  if (T = '') or (Length(T) > 64) then
    Exit(False);

  { Bakfra: siste tegn er de fire minst signifikante bitene. }
  Bit := 0;
  for I := Length(T) downto 1 do
  begin
    if not HexValue(T[I], V) then
      Exit(False);
    R.L[Bit shr 5] := R.L[Bit shr 5] or (UInt32(V) shl (Bit and 31));
    Inc(Bit, 4);
  end;
  Result := True;
end;

function U256ToHex(const A: TU256): string;
const
  Digits = '0123456789abcdef';
var
  B: array[0..U256Bytes - 1] of Byte;
  I: Integer;
begin
  U256ToBytes(A, B);
  SetLength(Result, U256Bytes * 2);
  for I := 0 to U256Bytes - 1 do
  begin
    Result[I * 2 + 1] := Digits[(B[I] shr 4) + 1];
    Result[I * 2 + 2] := Digits[(B[I] and $F) + 1];
  end;
end;

{ ----------------------------------------------------------- modulo M -- }

procedure ModAdd(const A, B, M: TU256; out R: TU256);
var
  Carry: UInt32;
  T: TU256;
begin
  Carry := U256Add(A, B, R);
  { The sum can reach >= M either by overflowing 256 bits or by simply
    being large. Both have the same answer: subtract M once. }
  if (Carry <> 0) or (U256Cmp(R, M) >= 0) then
  begin
    U256Sub(R, M, T);
    R := T;
  end;
end;

procedure ModSub(const A, B, M: TU256; out R: TU256);
var
  Borrow: UInt32;
  T: TU256;
begin
  Borrow := U256Sub(A, B, R);
  if Borrow <> 0 then
  begin
    U256Add(R, M, T);
    R := T;
  end;
end;

{ Skifter et 512-bits tall én bit mot venstre. Returnerer biten ut. }
function U512ShlOne(var A: TU512): UInt32;
var
  I: Integer;
  Inn, Ut: UInt32;
begin
  Inn := 0;
  for I := 0 to U512Limbs - 1 do
  begin
    Ut := A.L[I] shr 31;
    A.L[I] := (A.L[I] shl 1) or Inn;
    Inn := Ut;
  end;
  Result := Inn;
end;

procedure ModReduce(const X: TU512; const M: TU256; out R: TU256);
var
  Rest, Divisor, T: TU512;
  I, Hoy: Integer;
begin
  U256SetZero(R);
  if U256IsZero(M) then
    Exit;

  U256To512(M, Divisor);

  { If X is already smaller than M, the answer is X. Saves 512 rounds for
    the common case where a value is merely being narrowed. }
  if U512Cmp(X, Divisor) < 0 then
  begin
    U512Low(X, R);
    Exit;
  end;

  { Binary long division. The quotient is discarded — only the remainder
    is wanted. }
  U512SetZero(Rest);
  Hoy := U512Limbs * 32 - 1;
  for I := Hoy downto 0 do
  begin
    U512ShlOne(Rest);
    Rest.L[0] := Rest.L[0] or ((X.L[I shr 5] shr (I and 31)) and 1);
    if U512Cmp(Rest, Divisor) >= 0 then
    begin
      U512Sub(Rest, Divisor, T);
      Rest := T;
    end;
  end;
  U512Low(Rest, R);
end;

procedure ModMul(const A, B, M: TU256; out R: TU256);
var
  P: TU512;
begin
  U256Mul(A, B, P);
  ModReduce(P, M, R);
end;

function ModInv(const A, M: TU256; out R: TU256): Boolean;
var
  U, V, X1, X2, T: TU256;
  Carry: UInt32;
begin
  U256SetZero(R);
  if U256IsZero(A) or U256IsZero(M) then
    Exit(False);

  { The binary extended Euclidean algorithm. U and V shrink towards the
    gcd; X1 and X2 come along as coefficients modulo M. }
  U := A;
  V := M;
  U256SetU32(X1, 1);
  U256SetZero(X2);

  while (not U256IsZero(U)) and (U256Cmp(U, V) <> 0) do
  begin
    if U256Bit(U, 0) = 0 then
    begin
      U256ShrOne(U);
      if U256Bit(X1, 0) = 0 then
        U256ShrOne(X1)
      else
      begin
        { X1 is odd: add M first, so the halving is exact. The carry out has
          to be kept — the sum can be 257 bits. }
        Carry := U256Add(X1, M, T);
        X1 := T;
        U256ShrOne(X1);
        if Carry <> 0 then
          X1.L[U256Limbs - 1] := X1.L[U256Limbs - 1] or $80000000;
      end;
    end
    else if U256Bit(V, 0) = 0 then
    begin
      U256ShrOne(V);
      if U256Bit(X2, 0) = 0 then
        U256ShrOne(X2)
      else
      begin
        Carry := U256Add(X2, M, T);
        X2 := T;
        U256ShrOne(X2);
        if Carry <> 0 then
          X2.L[U256Limbs - 1] := X2.L[U256Limbs - 1] or $80000000;
      end;
    end
    else if U256Cmp(U, V) > 0 then
    begin
      U256Sub(U, V, T); U := T;
      ModSub(X1, X2, M, T); X1 := T;
    end
    else
    begin
      U256Sub(V, U, T); V := T;
      ModSub(X2, X1, M, T); X2 := T;
    end;
  end;

  { gcd(A, M) is now in U. If it is not 1 there is no inverse. }
  if U256IsZero(U) then
    Exit(False);
  U256SetU32(T, 1);
  if U256Cmp(U, T) <> 0 then
    Exit(False);

  R := X1;
  Result := True;
end;

end.
