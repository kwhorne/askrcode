{ Askr.Core.Ec — P-256 og ECDSA-verifisering.

  Finnes for WebAuthn. Askr verifiserer signaturer; den signerer ikke, og
  det er en vesentlig forenkling: verifisering regner utelukkende på
  offentlige verdier — signaturen og den offentlige nøkkelen — så den
  trenger ikke være konstant-tid. Signering ville krevd det, og da ville
  punktmultiplikasjonen sett helt annerledes ut.

  REDUKSJON MODULO p ER IKKE LANGDIVISJON

  En verifisering gjør i størrelsesorden 8000 feltmultiplikasjoner. With_
  den generiske reduksjonen i Askr.Core.BigInt ville hver av dem kostet
  512 runder med skift og subtraksjon, altså over hundre millioner
  operasjoner for én innlogging. P-256 er valgt med et Solinas-primtall
  nettopp for å slippe det:

    p = 2^256 - 2^224 + 2^192 + 2^96 - 1

  Da blir reduksjonen ni omstokkinger av 32-bits ord, lagt sammen og
  trukket fra. Formlene står i FIPS 186-4, tillegg D.2.3, og er skrevet
  av derfra — ikke utledet her.

  Modulo n er en annen sak: n er ikke spesiell, men brukes bare et par
  ganger per verifisering, så den generiske veien holder. }
unit Askr.Core.Ec;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Askr.Core.BigInt;

type
  { Punkt i jacobiske koordinater: x = X/Z^2, y = Y/Z^3. Z = 0 er
    uendelig. Koordinatene holdes jacobiske gjennom hele
    multiplikasjonen, slik at det bare trengs én invers til slutt. }
  TEcPoint = record
    X, Y, Z: TU256;
  end;

{ Kurvens parametre, som TU256. Fylt i initialization. }
function EcP: TU256;      { primtallet }
function EcN: TU256;      { ordenen til G }
function EcGx: TU256;
function EcGy: TU256;
function EcB: TU256;      { kurvens b; a er -3 }

{ ------------------------------------------------------------- feltet -- }

procedure FpAdd(const A, B: TU256; out R: TU256);
procedure FpSub(const A, B: TU256; out R: TU256);
{ Rask reduksjon etter FIPS 186-4 D.2.3. }
procedure FpReduce(const C: TU512; out R: TU256);
procedure FpMul(const A, B: TU256; out R: TU256);
procedure FpSqr(const A: TU256; out R: TU256);
function FpInv(const A: TU256; out R: TU256): Boolean;

{ ------------------------------------------------------------- punkter -- }

procedure EcSetInfinity(out P: TEcPoint);
function EcIsInfinity(const P: TEcPoint): Boolean;
{ Setter et affint punkt, altså Z = 1. }
procedure EcSetAffine(const X, Y: TU256; out P: TEcPoint);
{ Henter ut affine koordinater. False for uendelig. }
function EcToAffine(const P: TEcPoint; out X, Y: TU256): Boolean;

procedure EcDouble(const P: TEcPoint; out R: TEcPoint);
procedure EcAdd(const P, Q: TEcPoint; out R: TEcPoint);
procedure EcMul(const K: TU256; const P: TEcPoint; out R: TEcPoint);

{ Ligger punktet på kurven, og er det ikke uendelig? Må sjekkes for
  enhver nøkkel som kommer utenfra: et punkt på en annen kurve kan lekke
  hemmeligheter i andre sammenhenger, og her ville det uansett gitt et
  meningsløst svar. }
function EcOnCurve(const X, Y: TU256): Boolean;

{ ---------------------------------------------------------------- ecdsa -- }

{ Verifiserer en P-256-signatur.

  Hash er meldingssammendraget som 32 byte — for WebAuthn alltid
  SHA-256, så ingen avkorting trengs. R og S er signaturen, Qx og Qy den
  offentlige nøkkelen, alle 32 byte big-endian.

  False betyr ugyldig, uansett grunn. Kallstedet skal ikke få vite
  hvilken av sjekkene som slo til. }
function EcdsaVerifyP256(const Qx, Qy, SigR, SigS, Hash: array of Byte): Boolean;

implementation

var
  GP, GN, GGx, GGy, GB: TU256;

function EcP: TU256;  begin Result := GP;  end;
function EcN: TU256;  begin Result := GN;  end;
function EcGx: TU256; begin Result := GGx; end;
function EcGy: TU256; begin Result := GGy; end;
function EcB: TU256;  begin Result := GB;  end;

{ ------------------------------------------------------------- feltet -- }

procedure FpAdd(const A, B: TU256; out R: TU256);
begin
  ModAdd(A, B, GP, R);
end;

procedure FpSub(const A, B: TU256; out R: TU256);
begin
  ModSub(A, B, GP, R);
end;

{ Trekker fra p til verdien er mindre enn p. Hvert s-ledd under er under
  2^256, og p er over 2^255, så én gang holder — men løkka er skrevet
  generelt, fordi summene lenger nede kan være større. }
procedure Normaliser(var A: TU256);
var
  T: TU256;
begin
  while U256Cmp(A, GP) >= 0 do
  begin
    U256Sub(A, GP, T);
    A := T;
  end;
end;

{ Bygger et 256-bits tall av åtte ord, oppgitt mest signifikante først,
  slik FIPS skriver dem. Et ord nummer over 15 betyr null. }
procedure Clause(const C: TU512; W7, W6, W5, W4, W3, W2, W1, W0: Integer;
  out R: TU256);

  function Word_(I: Integer): UInt32;
  begin
    if (I < 0) or (I > 15) then
      Result := 0
    else
      Result := C.L[I];
  end;

begin
  R.L[7] := Word_(W7); R.L[6] := Word_(W6);
  R.L[5] := Word_(W5); R.L[4] := Word_(W4);
  R.L[3] := Word_(W3); R.L[2] := Word_(W2);
  R.L[1] := Word_(W1); R.L[0] := Word_(W0);
  Normaliser(R);
end;

procedure FpReduce(const C: TU512; out R: TU256);
var
  S1, S2, S3, S4, S5, S6, S7, S8, S9, T: TU256;
begin
  { FIPS 186-4, D.2.3. Ordene telles som i standarden: c0 er minst
    signifikant. -1 står for et ord som er null i det leddet. }
  Clause(C,  7,  6,  5,  4,  3,  2,  1,  0, S1);
  Clause(C, 15, 14, 13, 12, 11, -1, -1, -1, S2);
  Clause(C, -1, 15, 14, 13, 12, -1, -1, -1, S3);
  Clause(C, 15, 14, -1, -1, -1, 10,  9,  8, S4);
  Clause(C,  8, 13, 15, 14, 13, 11, 10,  9, S5);
  Clause(C, 10,  8, -1, -1, -1, 13, 12, 11, S6);
  Clause(C, 11,  9, -1, -1, 15, 14, 13, 12, S7);
  Clause(C, 12, -1, 10,  9,  8, 15, 14, 13, S8);
  Clause(C, 13, -1, 11, 10,  9, -1, 15, 14, S9);

  { r = s1 + 2*s2 + 2*s3 + s4 + s5 - s6 - s7 - s8 - s9 }
  R := S1;
  FpAdd(R, S2, T); R := T;
  FpAdd(R, S2, T); R := T;
  FpAdd(R, S3, T); R := T;
  FpAdd(R, S3, T); R := T;
  FpAdd(R, S4, T); R := T;
  FpAdd(R, S5, T); R := T;
  FpSub(R, S6, T); R := T;
  FpSub(R, S7, T); R := T;
  FpSub(R, S8, T); R := T;
  FpSub(R, S9, T); R := T;
end;

procedure FpMul(const A, B: TU256; out R: TU256);
var
  P: TU512;
begin
  U256Mul(A, B, P);
  FpReduce(P, R);
end;

procedure FpSqr(const A: TU256; out R: TU256);
begin
  FpMul(A, A, R);
end;

function FpInv(const A: TU256; out R: TU256): Boolean;
begin
  Result := ModInv(A, GP, R);
end;

{ ------------------------------------------------------------- punkter -- }

procedure EcSetInfinity(out P: TEcPoint);
begin
  U256SetU32(P.X, 1);
  U256SetU32(P.Y, 1);
  U256SetZero(P.Z);
end;

function EcIsInfinity(const P: TEcPoint): Boolean;
begin
  Result := U256IsZero(P.Z);
end;

procedure EcSetAffine(const X, Y: TU256; out P: TEcPoint);
begin
  P.X := X;
  P.Y := Y;
  U256SetU32(P.Z, 1);
end;

function EcToAffine(const P: TEcPoint; out X, Y: TU256): Boolean;
var
  ZInv, Z2, Z3: TU256;
begin
  U256SetZero(X);
  U256SetZero(Y);
  if EcIsInfinity(P) then
    Exit(False);
  if not FpInv(P.Z, ZInv) then
    Exit(False);
  FpSqr(ZInv, Z2);
  FpMul(Z2, ZInv, Z3);
  FpMul(P.X, Z2, X);
  FpMul(P.Y, Z3, Y);
  Result := True;
end;

{ Dobling med a = -3, som lar alpha regnes uten en egen multiplikasjon
  med a. Formlene er de vanlige for jacobiske koordinater. }
procedure EcDouble(const P: TEcPoint; out R: TEcPoint);
var
  Delta, Gamma, Beta, Alpha, T1, T2, T3: TU256;
  U: TEcPoint;
begin
  if EcIsInfinity(P) or U256IsZero(P.Y) then
  begin
    EcSetInfinity(R);
    Exit;
  end;

  FpSqr(P.Z, Delta);              { delta = Z^2 }
  FpSqr(P.Y, Gamma);              { gamma = Y^2 }
  FpMul(P.X, Gamma, Beta);        { beta  = X*gamma }

  FpSub(P.X, Delta, T1);          { X - delta }
  FpAdd(P.X, Delta, T2);          { X + delta }
  FpMul(T1, T2, T3);
  FpAdd(T3, T3, Alpha);
  FpAdd(Alpha, T3, Alpha);        { alpha = 3*(X-delta)*(X+delta) }

  FpSqr(Alpha, T1);               { alpha^2 }
  FpAdd(Beta, Beta, T2);          { 2beta }
  FpAdd(T2, T2, T2);              { 4beta }
  FpAdd(T2, T2, T3);              { 8beta }
  FpSub(T1, T3, U.X);             { X' = alpha^2 - 8beta }

  FpAdd(P.Y, P.Z, T1);
  FpSqr(T1, T2);
  FpSub(T2, Gamma, T1);
  FpSub(T1, Delta, U.Z);          { Z' = (Y+Z)^2 - gamma - delta }

  FpAdd(Beta, Beta, T1);
  FpAdd(T1, T1, T1);              { 4beta }
  FpSub(T1, U.X, T2);             { 4beta - X' }
  FpMul(Alpha, T2, T1);
  FpSqr(Gamma, T2);
  FpAdd(T2, T2, T3);
  FpAdd(T3, T3, T3);
  FpAdd(T3, T3, T3);              { 8*gamma^2 }
  FpSub(T1, T3, U.Y);             { Y' = alpha*(4beta - X') - 8gamma^2 }
  { Tilordnes til slutt: R kan være samme variabel som P. }
  R := U;
end;

procedure EcAdd(const P, Q: TEcPoint; out R: TEcPoint);
var
  Z1z1, Z2z2, U1, U2, S1, S2, H, I_, J_, Rr, V, T1, T2: TU256;
  W: TEcPoint;
begin
  if EcIsInfinity(P) then begin R := Q; Exit; end;
  if EcIsInfinity(Q) then begin R := P; Exit; end;

  FpSqr(P.Z, Z1z1);
  FpSqr(Q.Z, Z2z2);
  FpMul(P.X, Z2z2, U1);
  FpMul(Q.X, Z1z1, U2);
  FpMul(Q.Z, Z2z2, T1);
  FpMul(P.Y, T1, S1);
  FpMul(P.Z, Z1z1, T1);
  FpMul(Q.Y, T1, S2);

  if U256Cmp(U1, U2) = 0 then
  begin
    { Samme x. Enten samme punkt — da er det en dobling — eller to
      punkter som er hverandres negasjon, og da er summen uendelig.
      Bommer man på dette, gir addisjonen null i nevneren og et svar som
      ser ut som et gyldig punkt. }
    if U256Cmp(S1, S2) = 0 then
      EcDouble(P, R)
    else
      EcSetInfinity(R);
    Exit;
  end;

  FpSub(U2, U1, H);
  FpAdd(H, H, T1);
  FpSqr(T1, I_);                  { I = (2H)^2 }
  FpMul(H, I_, J_);               { J = H*I }
  FpSub(S2, S1, T1);
  FpAdd(T1, T1, Rr);              { r = 2*(S2-S1) }
  FpMul(U1, I_, V);

  FpSqr(Rr, T1);
  FpSub(T1, J_, T2);
  FpAdd(V, V, T1);
  FpSub(T2, T1, W.X);             { X3 = r^2 - J - 2V }

  FpSub(V, W.X, T1);
  FpMul(Rr, T1, T2);
  FpMul(S1, J_, T1);
  FpAdd(T1, T1, T1);
  FpSub(T2, T1, W.Y);             { Y3 = r*(V - X3) - 2*S1*J }

  FpAdd(P.Z, Q.Z, T1);
  FpSqr(T1, T2);
  FpSub(T2, Z1z1, T1);
  FpSub(T1, Z2z2, T2);
  FpMul(T2, H, W.Z);              { Z3 = ((Z1+Z2)^2 - Z1z1 - Z2z2)*H }
  { Samme grunn som i EcDouble: R kan aliasere P eller Q. }
  R := W;
end;

procedure EcMul(const K: TU256; const P: TEcPoint; out R: TEcPoint);
var
  I, Hoy: Integer;
  Akk, Base: TEcPoint;
begin
  { Vanlig dobbel-og-legg-til, fra toppen. Ikke konstant-tid: hoppet
    avhenger av bitene i K, som her alltid er offentlige.

    EcMul(K, P, P) virker fordi akkumulatoren er lokal og R skrives
    først til slutt. Den forrige utgaven kalte EcSetInfinity(R) med én
    gang, og da var P borte før første runde leste den — testen «20G + G
    = 21G» fanget nettopp det. Base-kopien er belte og seler oppå; den
    alene er ikke det som gjør det trygt. }
  Base := P;
  EcSetInfinity(Akk);
  Hoy := U256HighBit(K);
  if Hoy >= 0 then
    for I := Hoy downto 0 do
    begin
      EcDouble(Akk, Akk);
      if U256Bit(K, I) = 1 then
        EcAdd(Akk, Base, Akk);
    end;
  R := Akk;
end;

function EcOnCurve(const X, Y: TU256): Boolean;
var
  Y2, X3, T: TU256;
  Tre: TU256;
begin
  { Utenfor feltet er det ikke et punkt i det hele tatt. }
  if (U256Cmp(X, GP) >= 0) or (U256Cmp(Y, GP) >= 0) then
    Exit(False);
  { (0,0) er ikke på kurven, og ville ellers sluppet gjennom som
    uendelig forkledd som et affint punkt. }
  if U256IsZero(X) and U256IsZero(Y) then
    Exit(False);

  FpSqr(Y, Y2);
  FpSqr(X, T);
  FpMul(T, X, X3);                { x^3 }
  U256SetU32(Tre, 3);
  FpMul(X, Tre, T);
  FpSub(X3, T, X3);               { x^3 - 3x }
  FpAdd(X3, GB, T);               { + b }
  Result := U256Cmp(Y2, T) = 0;
end;

{ ---------------------------------------------------------------- ecdsa -- }

function EcdsaVerifyP256(const Qx, Qy, SigR, SigS, Hash: array of Byte): Boolean;
var
  X, Y, R_, S_, E, W, U1, U2, Rx, Ry, En: TU256;
  G, Q, P1, P2, Sum: TEcPoint;
begin
  Result := False;

  if not U256FromBytes(Qx, X) then Exit;
  if not U256FromBytes(Qy, Y) then Exit;
  if not U256FromBytes(SigR, R_) then Exit;
  if not U256FromBytes(SigS, S_) then Exit;
  if not U256FromBytes(Hash, E) then Exit;

  { r og s må ligge i [1, n-1]. Null slipper ellers gjennom som en
    signatur som verifiserer mot hva som helst. }
  if U256IsZero(R_) or (U256Cmp(R_, GN) >= 0) then Exit;
  if U256IsZero(S_) or (U256Cmp(S_, GN) >= 0) then Exit;

  { Nøkkelen må være et punkt på kurven. Without denne sjekken tar
    verifiseringen imot et punkt fra en annen kurve. }
  if not EcOnCurve(X, Y) then Exit;

  { Sammendraget tolkes som et heltall og snevres inn modulo n. For
    SHA-256 og P-256 er begge 256 bit, så det er sjelden en reell
    reduksjon — men e kan være større enn n. }
  if U256Cmp(E, GN) >= 0 then
  begin
    U256Sub(E, GN, En);
    E := En;
  end;

  if not ModInv(S_, GN, W) then Exit;
  ModMul(E, W, GN, U1);
  ModMul(R_, W, GN, U2);

  EcSetAffine(GGx, GGy, G);
  EcSetAffine(X, Y, Q);
  EcMul(U1, G, P1);
  EcMul(U2, Q, P2);
  EcAdd(P1, P2, Sum);

  if EcIsInfinity(Sum) then Exit;
  if not EcToAffine(Sum, Rx, Ry) then Exit;

  { Sammenligningen er modulo n, ikke modulo p. }
  if U256Cmp(Rx, GN) >= 0 then
  begin
    U256Sub(Rx, GN, En);
    Rx := En;
  end;
  Result := U256Cmp(Rx, R_) = 0;
end;

initialization
  U256FromHex('ffffffff00000001000000000000000000000000ffffffff' +
              'ffffffffffffffff', GP);
  U256FromHex('ffffffff00000000ffffffffffffffffbce6faada7179e84' +
              'f3b9cac2fc632551', GN);
  U256FromHex('6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0' +
              'f4a13945d898c296', GGx);
  U256FromHex('4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ece' +
              'cbb6406837bf51f5', GGy);
  U256FromHex('5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f6' +
              '3bce3c3e27d2604b', GB);

end.
