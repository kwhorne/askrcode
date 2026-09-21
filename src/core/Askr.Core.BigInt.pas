{ Askr.Core.BigInt — 256-bits heltallsaritmetikk.

  Finnes for ECDSA-verifisering, som igjen finnes for WebAuthn. Askr har
  ingen generell bignum-pakke og skal ikke få en: dette er nøyaktig det
  P-256 trenger, i fast bredde, og ikke noe mer.

  LEMMENE ER 32 BIT, IKKE 64

  Et produkt av to 32-bits tall får plass i UInt64 med god margin — selv
  med to bærere lagt til:

    $FFFFFFFF * $FFFFFFFF + $FFFFFFFF + $FFFFFFFF
      = $FFFFFFFFFFFFFFFF

  altså akkurat innenfor. With_ 64-bits lemmer måtte hvert produkt vært
  128 bit, og den typen finnes ikke i Free Pascal. Prisen er omtrent
  dobbelt så mange operasjoner; gevinsten er at ingenting her flyter
  over, så uniten trenger ingen avskrudd område- eller overflytkontroll
  og består `./askr check` slik
  den står. Det er et bevisst bytte i kode der en stille feil ikke kan
  oppdages ved lesing.

  Lemmene ligger med minst signifikante først. Utad er formatet
  big-endian byte-rekkefølge, fordi det er slik nøkler og signaturer
  kommer over nettet. }
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

  { 512 bit. Produktet av to TU256 får plass her. }
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
{ Indeksen til høyeste satte bit, eller -1 for null. }
function U256HighBit(const A: TU256): Integer;

{ ---------------------------------------------------------- aritmetikk -- }

{ Returnerer bæreren ut (0 eller 1). R kan være samme variabel som A. }
function U256Add(const A, B: TU256; out R: TU256): UInt32;
{ Returnerer lånet ut (0 eller 1), altså 1 når A < B. }
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
{ De 256 lave, henholdsvis høye, bitene. }
procedure U512Low(const A: TU512; out R: TU256);
procedure U512High(const A: TU512; out R: TU256);
{ Utvider 256 til 512. }
procedure U256To512(const A: TU256; out R: TU512);

{ Full 512 x 512 multiplikasjon, avkortet til 512 bit. }
procedure U512MulLow(const A, B: TU512; out R: TU512);

{ Skifter et 512-bits tall Count_ lemmer mot høyre, altså deler på
  2^(32*Count_). }
procedure U512ShrLimbs(const A: TU512; Count_: Integer; out R: TU512);

{ ---------------------------------------------------------------- byte -- }

{ Big-endian, 32 byte. False når lengden er feil. }
function U256FromBytes(const B: array of Byte; out R: TU256): Boolean;
procedure U256ToBytes(const A: TU256; var B: array of Byte);

{ Hex, til bruk i tester og i konstanter. Godtar store og små bokstaver
  og valgfri 0x. Ikke ment for varm kode. }
function U256FromHex(const S: string; out R: TU256): Boolean;
function U256ToHex(const A: TU256): string;

{ ----------------------------------------------------------- modulo M -- }

{ A + B mod M. Krever A, B < M. }
procedure ModAdd(const A, B, M: TU256; out R: TU256);
{ A - B mod M. Krever A, B < M. }
procedure ModSub(const A, B, M: TU256; out R: TU256);

{ Reduserer et 512-bits tall modulo M, med binær langdivisjon.

  Barrett ville vært raskere, men krever mellomregninger på 545 bit:
  q1 * mu passer ikke i 512, og en avkortet multiplikasjon kaster
  nettopp leddet man trenger. Det ville krevd en 1024-bits type for to
  operasjoner per verifisering. Reduksjon modulo n brukes bare når u1 og
  u2 regnes ut; feltet modulo p går den raske veien i Askr.Core.Ec. }
procedure ModReduce(const X: TU512; const M: TU256; out R: TU256);

{ A * B mod M. }
procedure ModMul(const A, B, M: TU256; out R: TU256);

{ Invers modulo M, med binær utvidet Euklid.

  Fermat — A^(M-2) — hadde vært kortere å skrive, men koster rundt 384
  multiplikasjoner modulo M. Binær Euklid koster rundt 512 runder med
  skift og subtraksjon, altså mye mindre. Inversen er den dyreste
  enkeltoperasjonen i en verifisering, så forskjellen merkes.

  False når A ikke er invertibel (felles faktor med M). }
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
  { From_ toppen: første ulike lemme avgjør. }
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
  Laan: UInt64;
begin
  Laan := 0;
  for I := 0 to U256Limbs - 1 do
  begin
    { Legger til 2^32 for å unngå at mellomregningen går under null.
      Den ekstra biten blir lånet ut, invertert. }
    T := (UInt64(A.L[I]) + $100000000) - UInt64(B.L[I]) - Laan;
    R.L[I] := UInt32(T and $FFFFFFFF);
    if T < $100000000 then Laan := 1 else Laan := 0;
  end;
  Result := UInt32(Laan);
end;

procedure U256Mul(const A, B: TU256; out R: TU512);
var
  I, J: Integer;
  T, Baerer: UInt64;
begin
  U512SetZero(R);
  for I := 0 to U256Limbs - 1 do
  begin
    if A.L[I] = 0 then
      Continue;
    Baerer := 0;
    for J := 0 to U256Limbs - 1 do
    begin
      { Dette er linja som avgjorde lemmebredden. With_ 32-bits lemmer
        får produktet pluss to bærere akkurat plass i UInt64. }
      T := UInt64(A.L[I]) * UInt64(B.L[J]) + UInt64(R.L[I + J]) + Baerer;
      R.L[I + J] := UInt32(T and $FFFFFFFF);
      Baerer := T shr 32;
    end;
    R.L[I + U256Limbs] := UInt32(UInt64(R.L[I + U256Limbs]) + Baerer);
  end;
end;

procedure U256Sqr(const A: TU256; out R: TU512);
begin
  { Kunne utnyttet symmetrien og spart nesten halvparten. Gjør det ikke:
    en egen kvadreringsrutine er en egen kilde til feil, og den ville
    hatt sine egne vektorer å kreve. Multiplikasjonen er prøvd. }
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
  T, Laan: UInt64;
begin
  Laan := 0;
  for I := 0 to U512Limbs - 1 do
  begin
    T := (UInt64(A.L[I]) + $100000000) - UInt64(B.L[I]) - Laan;
    R.L[I] := UInt32(T and $FFFFFFFF);
    if T < $100000000 then Laan := 1 else Laan := 0;
  end;
  Result := UInt32(Laan);
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
  T, Baerer: UInt64;
begin
  U512SetZero(R);
  for I := 0 to U512Limbs - 1 do
  begin
    if A.L[I] = 0 then
      Continue;
    Baerer := 0;
    for J := 0 to U512Limbs - 1 - I do
    begin
      T := UInt64(A.L[I]) * UInt64(B.L[J]) + UInt64(R.L[I + J]) + Baerer;
      R.L[I + J] := UInt32(T and $FFFFFFFF);
      Baerer := T shr 32;
    end;
    { Bæreren ut av toppen forsvinner med vilje: kallstedet bruker bare
      de lave 512 bitene. }
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
  Sifre = '0123456789abcdef';
var
  B: array[0..U256Bytes - 1] of Byte;
  I: Integer;
begin
  U256ToBytes(A, B);
  SetLength(Result, U256Bytes * 2);
  for I := 0 to U256Bytes - 1 do
  begin
    Result[I * 2 + 1] := Sifre[(B[I] shr 4) + 1];
    Result[I * 2 + 2] := Sifre[(B[I] and $F) + 1];
  end;
end;

{ ----------------------------------------------------------- modulo M -- }

procedure ModAdd(const A, B, M: TU256; out R: TU256);
var
  Baerer: UInt32;
  T: TU256;
begin
  Baerer := U256Add(A, B, R);
  { Summen kan bli >= M enten ved at den flyter over 256 bit, eller ved
    at den bare er stor. Begge gir samme svar: trekk fra M én gang. }
  if (Baerer <> 0) or (U256Cmp(R, M) >= 0) then
  begin
    U256Sub(R, M, T);
    R := T;
  end;
end;

procedure ModSub(const A, B, M: TU256; out R: TU256);
var
  Laan: UInt32;
  T: TU256;
begin
  Laan := U256Sub(A, B, R);
  if Laan <> 0 then
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

  { Er X allerede mindre enn M, er svaret X. Sparer 512 runder for det
    vanlige tilfellet der en verdi bare skal snevres inn. }
  if U512Cmp(X, Divisor) < 0 then
  begin
    U512Low(X, R);
    Exit;
  end;

  { Binær langdivisjon. Kvotienten kastes — bare resten skal ut. }
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
  Baerer: UInt32;
begin
  U256SetZero(R);
  if U256IsZero(A) or U256IsZero(M) then
    Exit(False);

  { Binær utvidet Euklid. U og V krymper mot gcd; X1 og X2 følger med
    som koeffisienter modulo M. }
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
        { X1 er odde: legg til M først, slik at halveringen er hel.
          Bæreren ut må tas vare på — summen kan være 257 bit. }
        Baerer := U256Add(X1, M, T);
        X1 := T;
        U256ShrOne(X1);
        if Baerer <> 0 then
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
        Baerer := U256Add(X2, M, T);
        X2 := T;
        U256ShrOne(X2);
        if Baerer <> 0 then
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

  { gcd(A, M) står nå i U. Er den ikke 1, finnes ingen invers. }
  if U256IsZero(U) then
    Exit(False);
  U256SetU32(T, 1);
  if U256Cmp(U, T) <> 0 then
    Exit(False);

  R := X1;
  Result := True;
end;

end.
