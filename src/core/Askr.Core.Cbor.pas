{ Askr.Core.Cbor — så mye CBOR som WebAuthn trenger, og ikke mer.

  Attestasjonsobjektet og COSE-nøkkelen er CBOR, så uten en dekoder
  kommer man ikke til den offentlige nøkkelen. Dette er ikke en generell
  CBOR-pakke: den leser de seks hovedtypene RFC 8949 kaller 0 til 5, og
  avviser resten.

  DEN ER STRENG MED VILJE

  Ubestemt lengde — «start en liste, si fra når den er slutt» — avvises.
  CTAP2s kanoniske form forbyr det, så ingen ekte autentikator sender
  det, og å godta det ville lagt til en tilstandsmaskin i kode som
  behandler data fra en angriper. Det samme gjelder tagger og
  flyttall: de forekommer ikke her, og et parseren ikke kjenner er et
  parseren skal si nei til.

  Leseren allokerer ingenting. Bytestrenger og tekst kommer ut som
  utsnitt inn i bufferet kalleren alt har. }
unit Askr.Core.Cbor;

{$mode Delphi}{$H+}

interface

uses
  SysUtils;

const
  { RFC 8949, tabell 1. }
  CborUInt   = 0;
  CborNegInt = 1;
  CborBytes  = 2;
  CborText   = 3;
  CborArray  = 4;
  CborMap    = 5;
  CborTag    = 6;
  CborSimple = 7;

type
  TCborReader = record
  private
    FBuf: PByte;
    FSize: Integer;
    FPos: Integer;
    { Leser hodet og flytter markøren. Major er hovedtypen, Arg det
      tilhørende tallet. }
    function ReadHeader(out Major: Byte; out Arg: UInt64): Boolean;
  public
    procedure Init(ABuf: PByte; ASize: Integer);

    function Pos_: Integer;
    function Size: Integer;
    function AtEnd: Boolean;
    { Alt lest, og ingenting igjen. WebAuthn-objekter skal være
      fullstendig konsumert — er det data igjen, er det ikke det vi
      trodde vi leste. }
    function Ferdig: Boolean;

    { Hovedtypen til neste verdi, uten å flytte markøren. }
    function NextType(out Major: Byte): Boolean;

    function ReadUInt(out V: UInt64): Boolean;
    { Heltall av begge fortegn. Negative er -1 - Arg. }
    function ReadInt(out V: Int64): Boolean;
    { Utsnitt inn i bufferet. Start er absolutt indeks. }
    function ReadBytes(out Start, Len: Integer): Boolean;
    function ReadText(out Start, Len: Integer): Boolean;
    { Teksten som Pascal-streng. Bare for korte nøkler. }
    function ReadTextStr(out S: string): Boolean;
    function ReadArrayLen(out N: Integer): Boolean;
    function ReadMapLen(out N: Integer): Boolean;

    { Hopper over neste verdi, uansett type, inkludert nøstede. Brukes
      til å gå forbi felter vi ikke bryr oss om. Has_ et dybdetak, slik
      at en dypt nøstet konstruksjon ikke blir en stakkoverflyt. }
    function Skip: Boolean;
  end;

implementation

const
  MaxDepth = 16;

procedure TCborReader.Init(ABuf: PByte; ASize: Integer);
begin
  FBuf := ABuf;
  if ASize < 0 then ASize := 0;
  FSize := ASize;
  FPos := 0;
end;

function TCborReader.Pos_: Integer;
begin
  Result := FPos;
end;

function TCborReader.Size: Integer;
begin
  Result := FSize;
end;

function TCborReader.AtEnd: Boolean;
begin
  Result := FPos >= FSize;
end;

function TCborReader.Ferdig: Boolean;
begin
  Result := FPos = FSize;
end;

function TCborReader.ReadHeader(out Major: Byte; out Arg: UInt64): Boolean;
var
  B: Byte;
  Ekstra, I: Integer;
begin
  Major := 0;
  Arg := 0;
  if FPos >= FSize then
    Exit(False);

  B := FBuf[FPos];
  Inc(FPos);
  Major := B shr 5;
  Ekstra := B and $1F;

  if Ekstra < 24 then
  begin
    Arg := Ekstra;
    Exit(True);
  end;

  { 28, 29 og 30 er reservert. 31 er ubestemt lengde, som vi ikke tar
    imot. Begge deler er en feil, ikke noe å tolke. }
  case Ekstra of
    24: Ekstra := 1;
    25: Ekstra := 2;
    26: Ekstra := 4;
    27: Ekstra := 8;
  else
    Exit(False);
  end;

  if FPos + Ekstra > FSize then
    Exit(False);
  for I := 0 to Ekstra - 1 do
    Arg := (Arg shl 8) or UInt64(FBuf[FPos + I]);
  Inc(FPos, Ekstra);
  Result := True;
end;

function TCborReader.NextType(out Major: Byte): Boolean;
begin
  Major := 0;
  if FPos >= FSize then
    Exit(False);
  Major := FBuf[FPos] shr 5;
  Result := True;
end;

function TCborReader.ReadUInt(out V: UInt64): Boolean;
var
  M: Byte;
begin
  V := 0;
  Result := ReadHeader(M, V) and (M = CborUInt);
end;

function TCborReader.ReadInt(out V: Int64): Boolean;
var
  M: Byte;
  Arg: UInt64;
begin
  V := 0;
  if not ReadHeader(M, Arg) then
    Exit(False);
  if M = CborUInt then
  begin
    { Over Int64 er ikke et tall vi kan representere. Her finnes ingen
      slike, så det er en feil. }
    if Arg > UInt64(High(Int64)) then
      Exit(False);
    V := Int64(Arg);
    Exit(True);
  end;
  if M = CborNegInt then
  begin
    if Arg > UInt64(High(Int64)) then
      Exit(False);
    V := -1 - Int64(Arg);
    Exit(True);
  end;
  Result := False;
end;

function TCborReader.ReadBytes(out Start, Len: Integer): Boolean;
var
  M: Byte;
  Arg: UInt64;
begin
  Start := 0; Len := 0;
  if not ReadHeader(M, Arg) then Exit(False);
  if M <> CborBytes then Exit(False);
  { Lengden kommer fra data en angriper skriver. En lengde som ikke får
    plass i bufferet er en feil, ikke noe å klippe til. }
  if Arg > UInt64(FSize - FPos) then Exit(False);
  Start := FPos;
  Len := Integer(Arg);
  Inc(FPos, Len);
  Result := True;
end;

function TCborReader.ReadText(out Start, Len: Integer): Boolean;
var
  M: Byte;
  Arg: UInt64;
begin
  Start := 0; Len := 0;
  if not ReadHeader(M, Arg) then Exit(False);
  if M <> CborText then Exit(False);
  if Arg > UInt64(FSize - FPos) then Exit(False);
  Start := FPos;
  Len := Integer(Arg);
  Inc(FPos, Len);
  Result := True;
end;

function TCborReader.ReadTextStr(out S: string): Boolean;
var
  Start, Len, I: Integer;
begin
  S := '';
  if not ReadText(Start, Len) then
    Exit(False);
  { Taket er der for at en nøkkel på en megabyte ikke skal bli en
    streng. Nøklene vi leter etter er noen få tegn. }
  if Len > 256 then
    Exit(False);
  SetLength(S, Len);
  for I := 0 to Len - 1 do
    S[I + 1] := Chr(FBuf[Start + I]);
  Result := True;
end;

function TCborReader.ReadArrayLen(out N: Integer): Boolean;
var
  M: Byte;
  Arg: UInt64;
begin
  N := 0;
  if not ReadHeader(M, Arg) then Exit(False);
  if M <> CborArray then Exit(False);
  { En lengde større enn det som er igjen av bufferet kan ikke stemme:
    hvert element er minst én byte. Without denne kan en liten melding be
    om milliarder av runder. }
  if Arg > UInt64(FSize - FPos) then Exit(False);
  N := Integer(Arg);
  Result := True;
end;

function TCborReader.ReadMapLen(out N: Integer): Boolean;
var
  M: Byte;
  Arg: UInt64;
begin
  N := 0;
  if not ReadHeader(M, Arg) then Exit(False);
  if M <> CborMap then Exit(False);
  { Hvert par er minst to byte. }
  if Arg > UInt64((FSize - FPos) div 2) then Exit(False);
  N := Integer(Arg);
  Result := True;
end;

function SkipInner(var R: TCborReader; Depth_: Integer): Boolean; forward;

function TCborReader.Skip: Boolean;
begin
  Result := SkipInner(Self, 0);
end;

function SkipInner(var R: TCborReader; Depth_: Integer): Boolean;
var
  M: Byte;
  Arg: UInt64;
  N, I: Integer;
begin
  if Depth_ > MaxDepth then
    Exit(False);
  if not R.ReadHeader(M, Arg) then
    Exit(False);

  case M of
    CborUInt, CborNegInt:
      Result := True;
    CborBytes, CborText:
      begin
        if Arg > UInt64(R.FSize - R.FPos) then
          Exit(False);
        Inc(R.FPos, Integer(Arg));
        Result := True;
      end;
    CborArray:
      begin
        if Arg > UInt64(R.FSize - R.FPos) then Exit(False);
        N := Integer(Arg);
        for I := 1 to N do
          if not SkipInner(R, Depth_ + 1) then
            Exit(False);
        Result := True;
      end;
    CborMap:
      begin
        if Arg > UInt64((R.FSize - R.FPos) div 2) then Exit(False);
        N := Integer(Arg);
        for I := 1 to N do
        begin
          if not SkipInner(R, Depth_ + 1) then Exit(False);   { nøkkel }
          if not SkipInner(R, Depth_ + 1) then Exit(False);   { verdi }
        end;
        Result := True;
      end;
  else
    { Tagger, flyttall og simple values forekommer ikke i det vi leser.
      Å hoppe over dem ville betydd å forstå dem. }
    Result := False;
  end;
end;

end.
