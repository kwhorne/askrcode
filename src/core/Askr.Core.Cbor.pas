{ Askr.Core.Cbor — as much CBOR as WebAuthn needs, and no more.

  The attestation object and the COSE key are CBOR, so without a decoder
  you never reach the public key. This is not a general CBOR package: it
  reads the six major types RFC 8949 calls 0 to 5, and refuses the rest.

  IT IS STRICT ON PURPOSE

  Indefinite lengths — "start a list, say when it ends" — are refused.
  CTAP2's canonical form forbids them, so no real authenticator sends
  them, and accepting them would add a state machine to code that handles
  data from an attacker. The same goes for tags and floats: they do not
  occur here, and something the parser does not know is something the
  parser should say no to.

  The reader allocates nothing. Byte strings and text come out as slices
  into the buffer the caller already has. }
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
    { Reads the head and moves the cursor. Major is the major type, Arg the
      number that goes with it. }
    function ReadHeader(out Major: Byte; out Arg: UInt64): Boolean;
  public
    procedure Init(ABuf: PByte; ASize: Integer);

    function Pos_: Integer;
    function Size: Integer;
    function AtEnd: Boolean;
    { Everything read and nothing left over. WebAuthn objects are meant to
      be consumed completely — if data remains, this is not what we thought
      we were reading. }
    function Ferdig: Boolean;

    { The major type of the next value, without moving the cursor. }
    function NextType(out Major: Byte): Boolean;

    function ReadUInt(out V: UInt64): Boolean;
    { Heltall av begge fortegn. Negative er -1 - Arg. }
    function ReadInt(out V: Int64): Boolean;
    { Utsnitt inn i bufferet. Start er absolutt indeks. }
    function ReadBytes(out Start, Len: Integer): Boolean;
    function ReadText(out Start, Len: Integer): Boolean;
    { The text as a Pascal string. For short keys only. }
    function ReadTextStr(out S: string): Boolean;
    function ReadArrayLen(out N: Integer): Boolean;
    function ReadMapLen(out N: Integer): Boolean;

    { Skips the next value, whatever its type, nested ones included. Used to
      step past fields we do not care about. Has a depth limit, so a deeply
      nested construction does not become a stack overflow. }
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

  { 28, 29 and 30 are reserved. 31 is an indefinite length, which we do
    not accept. Both are an error, not something to interpret. }
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
    { Above Int64 is not a number we can represent. None occur here, so it
      is an error. }
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
  { The length comes from data an attacker writes. A length that does not
    fit in the buffer is an error, not something to clamp. }
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
  { The limit is there so a one-megabyte key does not become a string. The
    keys we are looking for are a few characters. }
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
  { A length larger than what is left of the buffer cannot be right: every
    element is at least one byte. Without this a small message can ask for
    billions of rounds. }
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
          if not SkipInner(R, Depth_ + 1) then Exit(False);   { key }
          if not SkipInner(R, Depth_ + 1) then Exit(False);   { value }
        end;
        Result := True;
      end;
  else
    { Tags, floats and simple values do not occur in what we read. Skipping
      them would mean understanding them. }
    Result := False;
  end;
end;

end.
