{ Askr.Qr — QR codes, drawn as SVG.

      Q := QrEncode(TotpUri('Shop', U.Email, Secret));
      Html := QrSvg(Q, 'Scan with your authenticator app');

  For the page where two-factor sign-in is set up: a phone scans the code
  and has the secret, without anyone typing thirty-two letters. It works
  like the rest of the sign-in pages -- no npm, no network, nothing next to
  the binary -- which is why it is here and not a script from a CDN.

  Byte mode only, which is what a URI needs, at any of the four levels and
  any of the forty versions; the smallest version that holds the text is
  used. The mask is chosen by the standard's penalty score unless one is
  given.

  **Two encoders say it is right.** Every module of a code at a fixed mask
  is set by the standard, so the tests hold the output to python-qrcode's,
  module for module, at every level and across the versions
  (tests/vectors/qr.txt, written by tools/vectors/qr.py). And ./askr
  qr:check has Chrome's own barcode reader read codes back, which is the
  check that matters: a phone. }
unit Askr.Qr;

{$mode Delphi}{$H+}

interface

uses
  SysUtils;

type
  EQrError = class(Exception);

  { How much of the code can be lost and still read: about 7, 15, 25 and
    30 per cent. Medium is the usual choice for a screen. }
  TQrEcc = (qrLow, qrMedium, qrQuartile, qrHigh);

  TQrCode = record
    Version: Integer;
    Size: Integer;
    Mask: Integer;
    { Size * Size, row by row; True is dark. }
    Modules: array of Boolean;
  end;

{ Data as bytes -- UTF-8 as it is. Mask -1 picks the best by the penalty
  score; 0 to 7 forces one, for a test. Raises when the text is longer than
  version 40 holds at that level. }
function QrEncode(const Data: string; Ecc: TQrEcc = qrMedium;
  Mask: Integer = -1): TQrCode;
function QrDark(const Q: TQrCode; X, Y: Integer): Boolean;
{ An inline SVG: a white square with the quiet zone the standard asks for
  -- four modules -- and one path for the dark ones. Label becomes its
  accessible name. }
function QrSvg(const Q: TQrCode; const Label_: string = '';
  Border: Integer = 4): string;

implementation

{$push}{$R-}{$Q-}

const
  { Error correction codewords per block, and blocks, per level and
    version -- the two tables of ISO/IEC 18004 that cannot be worked out.
    Index 0 is unused. }
  EccPerBlock: array[TQrEcc, 0..40] of Integer = (
    (-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28,
         28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30),
    (-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26,
         26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28),
    (-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30,
         28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30),
    (-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28,
         30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30));
  EccBlocks: array[TQrEcc, 0..40] of Integer = (
    (-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8,
         8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25),
    (-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16,
         17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49),
    (-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20,
         23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68),
    (-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25,
         25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81));
  { What the format information calls each level. Not in order: M is 00. }
  EccFormatBits: array[TQrEcc] of Integer = (1, 0, 3, 2);

type
  TGrid = record
    Size: Integer;
    Dark: array of Boolean;
    IsFunction: array of Boolean;
  end;

{ Modules the data can use: all of them, less the finders, timing,
  alignment, format and version areas. A formula, unlike the tables. }
function RawDataModules(Ver: Integer): Integer;
var
  NumAlign: Integer;
begin
  Result := (16 * Ver + 128) * Ver + 64;
  if Ver >= 2 then
  begin
    NumAlign := Ver div 7 + 2;
    Result := Result - ((25 * NumAlign - 10) * NumAlign - 55);
    if Ver >= 7 then
      Result := Result - 36;
  end;
end;

function DataCodewords(Ver: Integer; Ecc: TQrEcc): Integer;
begin
  Result := RawDataModules(Ver) div 8 - EccPerBlock[Ecc, Ver] * EccBlocks[Ecc, Ver];
end;

{ GF(256) with the QR polynomial x^8 + x^4 + x^3 + x^2 + 1. }
function GfMul(X, Y: Integer): Integer;
var
  I, Z: Integer;
begin
  Z := 0;
  for I := 7 downto 0 do
  begin
    Z := (Z shl 1) xor ((Z shr 7) * $11D);
    Z := Z xor (((Y shr I) and 1) * X);
  end;
  Result := Z and $FF;
end;

function RsDivisor(Degree: Integer): TBytes;
var
  I, J, Root: Integer;
begin
  Result := nil;
  SetLength(Result, Degree);
  Result[Degree - 1] := 1;
  Root := 1;
  for I := 0 to Degree - 1 do
  begin
    for J := 0 to Degree - 1 do
    begin
      Result[J] := GfMul(Result[J], Root);
      if J + 1 < Degree then
        Result[J] := Result[J] xor Result[J + 1];
    end;
    Root := GfMul(Root, 2);
  end;
end;

function RsRemainder(const Data: TBytes; Start, Len: Integer;
  const Divisor: TBytes): TBytes;
var
  I, J, Factor: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Divisor));
  for I := Start to Start + Len - 1 do
  begin
    Factor := Data[I] xor Result[0];
    for J := 0 to High(Result) - 1 do
      Result[J] := Result[J + 1];
    Result[High(Result)] := 0;
    for J := 0 to High(Result) do
      Result[J] := Result[J] xor GfMul(Divisor[J], Factor);
  end;
end;

procedure SetFn(var G: TGrid; X, Y: Integer; Dark: Boolean);
begin
  G.Dark[Y * G.Size + X] := Dark;
  G.IsFunction[Y * G.Size + X] := True;
end;

type
  TInts = array of Integer;

function AlignPos(Ver: Integer): TInts;
var
  NumAlign, Step, I, Pos_, Size: Integer;
begin
  Result := nil;
  if Ver = 1 then
    Exit;
  Size := Ver * 4 + 17;
  NumAlign := Ver div 7 + 2;
  if Ver = 32 then
    Step := 26
  else
    Step := (Ver * 4 + NumAlign * 2 + 1) div (NumAlign * 2 - 2) * 2;
  SetLength(Result, NumAlign);
  Result[0] := 6;
  Pos_ := Size - 7;
  for I := NumAlign - 1 downto 1 do
  begin
    Result[I] := Pos_;
    Dec(Pos_, Step);
  end;
end;

procedure DrawFinder(var G: TGrid; CX, CY: Integer);
var
  DX, DY, Dist, X, Y: Integer;
begin
  for DY := -4 to 4 do
    for DX := -4 to 4 do
    begin
      Dist := Abs(DX);
      if Abs(DY) > Dist then
        Dist := Abs(DY);
      X := CX + DX;
      Y := CY + DY;
      if (X >= 0) and (X < G.Size) and (Y >= 0) and (Y < G.Size) then
        SetFn(G, X, Y, (Dist <> 2) and (Dist <> 4));
    end;
end;

procedure DrawAlignment(var G: TGrid; CX, CY: Integer);
var
  DX, DY, Dist: Integer;
begin
  for DY := -2 to 2 do
    for DX := -2 to 2 do
    begin
      Dist := Abs(DX);
      if Abs(DY) > Dist then
        Dist := Abs(DY);
      SetFn(G, CX + DX, CY + DY, Dist <> 1);
    end;
end;

{ The level and the mask, with a BCH code of their own, twice: beside the
  top-left finder, and split between the other two. }
procedure DrawFormat(var G: TGrid; Ecc: TQrEcc; Mask: Integer);
var
  Data, Rem, Bits, I: Integer;

  function Bit(N: Integer): Boolean;
  begin
    Result := ((Bits shr N) and 1) <> 0;
  end;

begin
  Data := (EccFormatBits[Ecc] shl 3) or Mask;
  Rem := Data;
  for I := 1 to 10 do
    Rem := (Rem shl 1) xor ((Rem shr 9) * $537);
  Bits := ((Data shl 10) or (Rem and $3FF)) xor $5412;
  for I := 0 to 5 do
    SetFn(G, 8, I, Bit(I));
  SetFn(G, 8, 7, Bit(6));
  SetFn(G, 8, 8, Bit(7));
  SetFn(G, 7, 8, Bit(8));
  for I := 9 to 14 do
    SetFn(G, 14 - I, 8, Bit(I));
  for I := 0 to 7 do
    SetFn(G, G.Size - 1 - I, 8, Bit(I));
  for I := 8 to 14 do
    SetFn(G, 8, G.Size - 15 + I, Bit(I));
  { The one module that is always dark. }
  SetFn(G, 8, G.Size - 8, True);
end;

procedure DrawVersion(var G: TGrid; Ver: Integer);
var
  Rem, Bits, I, A, B: Integer;
begin
  if Ver < 7 then
    Exit;
  Rem := Ver;
  for I := 1 to 12 do
    Rem := (Rem shl 1) xor ((Rem shr 11) * $1F25);
  Bits := (Ver shl 12) or (Rem and $FFF);
  for I := 0 to 17 do
  begin
    A := G.Size - 11 + I mod 3;
    B := I div 3;
    SetFn(G, A, B, ((Bits shr I) and 1) <> 0);
    SetFn(G, B, A, ((Bits shr I) and 1) <> 0);
  end;
end;

procedure DrawFunctionPatterns(var G: TGrid; Ver: Integer; Ecc: TQrEcc);
var
  I, J: Integer;
  P: TInts;
begin
  for I := 0 to G.Size - 1 do
  begin
    SetFn(G, 6, I, I mod 2 = 0);
    SetFn(G, I, 6, I mod 2 = 0);
  end;
  DrawFinder(G, 3, 3);
  DrawFinder(G, G.Size - 4, 3);
  DrawFinder(G, 3, G.Size - 4);
  P := AlignPos(Ver);
  for I := 0 to High(P) do
    for J := 0 to High(P) do
      { Not where a finder already is. }
      if not (((I = 0) and (J = 0)) or ((I = 0) and (J = High(P))) or
              ((I = High(P)) and (J = 0))) then
        DrawAlignment(G, P[I], P[J]);
  { Reserved now, drawn for real once the mask is known. }
  DrawFormat(G, Ecc, 0);
  DrawVersion(G, Ver);
end;

{ The codewords go up and down two columns at a time from the right,
  stepping over the vertical timing pattern. }
procedure DrawCodewords(var G: TGrid; const Data: TBytes);
var
  I, Right, Vert, J, X, Y: Integer;
  Upward: Boolean;
begin
  I := 0;
  Right := G.Size - 1;
  while Right >= 1 do
  begin
    if Right = 6 then
      Right := 5;
    for Vert := 0 to G.Size - 1 do
      for J := 0 to 1 do
      begin
        X := Right - J;
        Upward := ((Right + 1) and 2) = 0;
        if Upward then
          Y := G.Size - 1 - Vert
        else
          Y := Vert;
        if (not G.IsFunction[Y * G.Size + X]) and (I < Length(Data) * 8) then
        begin
          G.Dark[Y * G.Size + X] := ((Data[I shr 3] shr (7 - (I and 7))) and 1) <> 0;
          Inc(I);
        end;
      end;
    Dec(Right, 2);
  end;
end;

function MaskBit(Mask, X, Y: Integer): Boolean;
begin
  case Mask of
    0: Result := (X + Y) mod 2 = 0;
    1: Result := Y mod 2 = 0;
    2: Result := X mod 3 = 0;
    3: Result := (X + Y) mod 3 = 0;
    4: Result := (X div 3 + Y div 2) mod 2 = 0;
    5: Result := (X * Y) mod 2 + (X * Y) mod 3 = 0;
    6: Result := ((X * Y) mod 2 + (X * Y) mod 3) mod 2 = 0;
    7: Result := ((X + Y) mod 2 + (X * Y) mod 3) mod 2 = 0;
  else
    raise EQrError.CreateFmt('There is no mask %d; they are 0 to 7', [Mask]);
  end;
end;

{ XOR, so applying the same mask twice takes it off again. }
procedure ApplyMask(var G: TGrid; Mask: Integer);
var
  X, Y: Integer;
begin
  for Y := 0 to G.Size - 1 do
    for X := 0 to G.Size - 1 do
      if (not G.IsFunction[Y * G.Size + X]) and MaskBit(Mask, X, Y) then
        G.Dark[Y * G.Size + X] := not G.Dark[Y * G.Size + X];
end;

type
  TRunHistory = array[0..6] of Integer;

{ The run just ended, newest first. The first run of a line has the quiet
  zone added to it: outside the code is light. }
procedure AddHistory(var H: TRunHistory; Len, Size: Integer);
var
  I: Integer;
begin
  if H[0] = 0 then
    Inc(Len, Size);
  for I := 6 downto 1 do
    H[I] := H[I - 1];
  H[0] := Len;
end;

{ Called right after a light run is added: 1:1:3:1:1 at any width n, with
  at least 4n light before it or after it -- 0, 1 or 2 of them. }
function CountFinderLike(const H: TRunHistory): Integer;
var
  N: Integer;
  Core: Boolean;
begin
  N := H[1];
  Core := (N > 0) and (H[2] = N) and (H[4] = N) and (H[5] = N) and (H[3] = N * 3);
  Result := 0;
  if Core and (H[0] >= N * 4) and (H[6] >= N) then
    Inc(Result);
  if Core and (H[6] >= N * 4) and (H[0] >= N) then
    Inc(Result);
end;

function TerminateAndCount(Dark: Boolean; RunLen, Size: Integer;
  var H: TRunHistory): Integer;
begin
  if Dark then
  begin
    AddHistory(H, RunLen, Size);
    RunLen := 0;
  end;
  { The quiet zone after the last module is light too. }
  AddHistory(H, RunLen + Size, Size);
  Result := CountFinderLike(H);
end;

{ ISO/IEC 18004's four penalties, as Nayuki's qrcodegen reads them: runs
  of five or more of a colour, 2x2 blocks, the finder's 1:1:3:1:1 at any
  width with four light on a side -- the quiet zone counting as light --
  and the distance from half dark. The lowest total wins. The tests hold
  the choice to qrcodegen's, which is written from the 2015 text; python-
  qrcode scores with the format bits left light and is no reference. }
function Penalty(const G: TGrid): Integer;
var
  X, Y, Run, Dark, Total, K, N: Integer;
  RunDark, C: Boolean;
  H: TRunHistory;

  function At(AX, AY: Integer): Boolean;
  begin
    Result := G.Dark[AY * G.Size + AX];
  end;

begin
  Result := 0;
  N := G.Size;
  for Y := 0 to N - 1 do
  begin
    RunDark := False;
    Run := 0;
    FillChar(H, SizeOf(H), 0);
    for X := 0 to N - 1 do
    begin
      C := At(X, Y);
      if C = RunDark then
      begin
        Inc(Run);
        if Run = 5 then Inc(Result, 3)
        else if Run > 5 then Inc(Result);
      end
      else
      begin
        AddHistory(H, Run, N);
        if not RunDark then
          Inc(Result, CountFinderLike(H) * 40);
        RunDark := C;
        Run := 1;
      end;
    end;
    Inc(Result, TerminateAndCount(RunDark, Run, N, H) * 40);
  end;
  for X := 0 to N - 1 do
  begin
    RunDark := False;
    Run := 0;
    FillChar(H, SizeOf(H), 0);
    for Y := 0 to N - 1 do
    begin
      C := At(X, Y);
      if C = RunDark then
      begin
        Inc(Run);
        if Run = 5 then Inc(Result, 3)
        else if Run > 5 then Inc(Result);
      end
      else
      begin
        AddHistory(H, Run, N);
        if not RunDark then
          Inc(Result, CountFinderLike(H) * 40);
        RunDark := C;
        Run := 1;
      end;
    end;
    Inc(Result, TerminateAndCount(RunDark, Run, N, H) * 40);
  end;
  for Y := 0 to N - 2 do
    for X := 0 to N - 2 do
    begin
      C := At(X, Y);
      if (At(X + 1, Y) = C) and (At(X, Y + 1) = C) and (At(X + 1, Y + 1) = C) then
        Inc(Result, 3);
    end;
  { The smallest k with (45 - 5k)% <= dark <= (55 + 5k)%. }
  Dark := 0;
  for Y := 0 to N - 1 do
    for X := 0 to N - 1 do
      if At(X, Y) then
        Inc(Dark);
  Total := N * N;
  K := (Abs(Dark * 20 - Total * 10) + Total - 1) div Total - 1;
  Inc(Result, K * 10);
end;

function QrEncode(const Data: string; Ecc: TQrEcc; Mask: Integer): TQrCode;
var
  Ver, Cap, CountBits, Len, I, J, K, BitLen, NumBlocks, EccLen, RawCw,
    NumShort, ShortLen, Best, Score, BestScore, DataLen: Integer;
  Buf, Codewords, Final_, Divisor, Ecc_: TBytes;
  Blocks: array of TBytes;
  G, Trial: TGrid;

  procedure Put(Value, Bits: Integer);
  var
    B: Integer;
  begin
    for B := Bits - 1 downto 0 do
    begin
      if ((Value shr B) and 1) <> 0 then
        Buf[BitLen shr 3] := Buf[BitLen shr 3] or (1 shl (7 - (BitLen and 7)));
      Inc(BitLen);
    end;
  end;

begin
  if (Mask < -1) or (Mask > 7) then
    raise EQrError.CreateFmt('There is no mask %d; they are 0 to 7, or -1 for the best', [Mask]);
  Len := Length(Data);
  { The smallest version that holds it: four bits of mode, the length, and
    the bytes. The length takes 8 bits up to version 9 and 16 after. }
  Ver := 0;
  for I := 1 to 40 do
  begin
    if I <= 9 then CountBits := 8 else CountBits := 16;
    if (Len < (1 shl CountBits)) and (4 + CountBits + Len * 8 <= DataCodewords(I, Ecc) * 8) then
    begin
      Ver := I;
      Break;
    end;
  end;
  if Ver = 0 then
    raise EQrError.CreateFmt('%d bytes is more than a QR code holds at this level', [Len]);
  if Ver <= 9 then CountBits := 8 else CountBits := 16;
  Cap := DataCodewords(Ver, Ecc);

  Buf := nil;
  SetLength(Buf, Cap);
  BitLen := 0;
  Put(4, 4);                      { byte mode }
  Put(Len, CountBits);
  for I := 1 to Len do
    Put(Ord(Data[I]), 8);
  { Up to a whole byte, then the two pad bytes the standard names, in
    turn, to fill. The standard's terminator -- up to four zero bits -- is
    in the rounding: four bits of mode, a length of 8 or 16 and whole bytes
    always leave four over, and a mutation that took a separate step for
    it away showed it changed nothing. }
  BitLen := (BitLen + 7) and not 7;
  K := 0;
  while BitLen < Cap * 8 do
  begin
    if K mod 2 = 0 then Buf[BitLen shr 3] := $EC else Buf[BitLen shr 3] := $11;
    Inc(K);
    Inc(BitLen, 8);
  end;

  { Split into blocks, the short ones first, each with its own error
    correction, and then interleaved a codeword from each at a time. }
  NumBlocks := EccBlocks[Ecc, Ver];
  EccLen := EccPerBlock[Ecc, Ver];
  RawCw := RawDataModules(Ver) div 8;
  NumShort := NumBlocks - RawCw mod NumBlocks;
  ShortLen := RawCw div NumBlocks;
  Divisor := RsDivisor(EccLen);
  SetLength(Blocks, NumBlocks);
  K := 0;
  for I := 0 to NumBlocks - 1 do
  begin
    DataLen := ShortLen - EccLen;
    if I >= NumShort then
      Inc(DataLen);
    Ecc_ := RsRemainder(Buf, K, DataLen, Divisor);
    Blocks[I] := nil;
    SetLength(Blocks[I], ShortLen + 1);
    for J := 0 to DataLen - 1 do
      Blocks[I][J] := Buf[K + J];
    { A short block leaves one place empty before its error correction,
      so the columns line up when they are interleaved. }
    for J := 0 to EccLen - 1 do
      Blocks[I][ShortLen + 1 - EccLen + J] := Ecc_[J];
    Inc(K, DataLen);
  end;
  Final_ := nil;
  SetLength(Final_, RawCw);
  K := 0;
  for J := 0 to ShortLen do
    for I := 0 to NumBlocks - 1 do
      if (J <> ShortLen - EccLen) or (I >= NumShort) then
      begin
        Final_[K] := Blocks[I][J];
        Inc(K);
      end;
  Codewords := Final_;

  G.Size := Ver * 4 + 17;
  SetLength(G.Dark, G.Size * G.Size);
  SetLength(G.IsFunction, G.Size * G.Size);
  DrawFunctionPatterns(G, Ver, Ecc);
  DrawCodewords(G, Codewords);

  if Mask < 0 then
  begin
    Best := 0;
    BestScore := MaxInt;
    for I := 0 to 7 do
    begin
      Trial := G;
      Trial.Dark := Copy(G.Dark);
      ApplyMask(Trial, I);
      DrawFormat(Trial, Ecc, I);
      Score := Penalty(Trial);
      if Score < BestScore then
      begin
        Best := I;
        BestScore := Score;
      end;
    end;
    Mask := Best;
  end;
  ApplyMask(G, Mask);
  DrawFormat(G, Ecc, Mask);

  Result.Version := Ver;
  Result.Size := G.Size;
  Result.Mask := Mask;
  Result.Modules := G.Dark;
end;

{$pop}

function QrDark(const Q: TQrCode; X, Y: Integer): Boolean;
begin
  Result := (X >= 0) and (Y >= 0) and (X < Q.Size) and (Y < Q.Size) and
    Q.Modules[Y * Q.Size + X];
end;

function Esc(const S: string): string;
begin
  Result := StringReplace(StringReplace(StringReplace(StringReplace(S, '&', '&amp;',
    [rfReplaceAll]), '<', '&lt;', [rfReplaceAll]), '>', '&gt;', [rfReplaceAll]),
    '"', '&quot;', [rfReplaceAll]);
end;

function QrSvg(const Q: TQrCode; const Label_: string; Border: Integer): string;
var
  X, Y, W: Integer;
  Path: string;
begin
  W := Q.Size + Border * 2;
  Path := '';
  for Y := 0 to Q.Size - 1 do
    for X := 0 to Q.Size - 1 do
      if Q.Modules[Y * Q.Size + X] then
        Path := Path + 'M' + IntToStr(X + Border) + ',' + IntToStr(Y + Border) + 'h1v1h-1z';
  Result := '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ' + IntToStr(W) + ' ' +
    IntToStr(W) + '" shape-rendering="crispEdges" role="img"';
  if Label_ <> '' then
    Result := Result + ' aria-label="' + Esc(Label_) + '"';
  { White and black, not the page's colours: a scanner wants dark on light
    whatever theme the page is in. }
  Result := Result + '><rect width="' + IntToStr(W) + '" height="' + IntToStr(W) +
    '" fill="#fff"/><path fill="#000" d="' + Path + '"/></svg>';
end;

end.
