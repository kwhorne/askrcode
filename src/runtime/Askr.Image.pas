{ Askr.Image — what you can know about an image without decoding it.

  The format is read from magic bytes, the dimensions from the header,
  and EXIF is removed by rewriting segments. Nothing here decodes a
  single pixel, so the unit has no dependencies at all. Resizing and
  format conversion live in Askr.Image.Vips, which loads libvips with
  dlopen and says clearly when it is missing.

  THIS IS FIRST AND FOREMOST A SECURITY UNIT

  An uploaded file called `.jpg` that is actually HTML is a stored XSS
  vector: serve it back with the wrong Content-Type and it runs in the
  reader's browser under your domain. The filename comes from an attacker
  and means nothing. `SniffFormat` looks at the content.

  And EXIF is a privacy leak that is easy to forget: a photo taken on a
  phone often carries GPS coordinates. If somebody uploads a profile
  picture, they upload their home address unless something removes it. }
unit Askr.Image;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, Askr.Core.Text;

type
  TImageFormat = (ifUnknown, ifJpeg, ifPng, ifGif, ifWebp, ifBmp, ifAvif,
                  ifTiff, ifSvg);

  TImageInfo = record
    Format: TImageFormat;
    Width: Integer;
    Height: Integer;
    { True when the header was read and width and height are real numbers.
      For a format we recognise but cannot measure, Format is set and Ok
      is False. }
    Ok: Boolean;
    { An animated GIF or WebP. Worth knowing, because an "avatar" that
      animates is rarely what anyone wanted. }
    Animated: Boolean;
  end;

{ The format from the first bytes. Never looks at the filename. }
function SniffFormat(const Data: TBytes): TImageFormat; overload;
function SniffFormat(const Path: string): TImageFormat; overload;
{ Straight onto an upload: TUploadedFile.Content is a TStr into the
  worker's read buffer, and is not copied here.

  ContentType from the client is a claim, not a measurement — an .exe can
  announce itself as image/png. This is the measurement. }
function SniffFormat(const S: TStr): TImageFormat; overload;

{ The name as written in a Content-Type. An empty string for
  ifUnknown. }
function MimeTypeFor(F: TImageFormat): string;
{ The usual extension, with the dot. }
function ExtensionFor(F: TImageFormat): string;

{ Reads the format and the dimensions without decoding. }
function ReadImageInfo(const Data: TBytes): TImageInfo; overload;
function ReadImageInfo(const Path: string): TImageInfo; overload;
function ReadImageInfo(const S: TStr): TImageInfo; overload;

{ Does the extension say the same thing as the content?

  Used on uploads: a .png that is really a JPEG is usually harmless
  sloppiness, while a .png that is HTML is not. Both are stopped in the
  same place. }
function ExtensionMatches(const FileName: string; const Data: TBytes): Boolean; overload;
function ExtensionMatches(const FileName: string; const S: TStr): Boolean; overload;

{ Removes EXIF, XMP and comments from a JPEG.

  The pixels are untouched: only the APPn and COM segments are skipped
  while the file is rewritten. Returns False when the input is not a JPEG
  at all; then Out is unchanged. }
function StripJpegMetadata(const Data: TBytes; out Ut: TBytes): Boolean;

{ The orientation from EXIF, 1 to 8, or 0 when it is not there.

  Worth reading BEFORE removing EXIF: a phone often writes the photo
  sideways and lets the orientation say which way up it goes. Strip the
  EXIF without rotating first and the picture is sideways forever. }
function JpegOrientation(const Data: TBytes): Integer;

implementation

{ ------------------------------------------------------------ hjelpere -- }

function Read_(const Path: string; MaxSide: Integer): TBytes;
var
  F: TFileStream;
  N: Integer;
  B: TBytes;
begin
  B := nil;
  Result := B;
  if not FileExists(Path) then
    Exit;
  F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    N := F.Size;
    if (MaxSide > 0) and (N > MaxSide) then
      N := MaxSide;
    SetLength(B, N);
    if N > 0 then
      F.ReadBuffer(B[0], N);
    Result := B;
  finally
    F.Free;
  end;
end;

function Has_(const D: TBytes; Pos_: Integer; const Magic: array of Byte): Boolean;
var
  I: Integer;
begin
  Result := False;
  if Pos_ + Length(Magic) > Length(D) then
    Exit;
  for I := 0 to High(Magic) do
    if D[Pos_ + I] <> Magic[I] then
      Exit;
  Result := True;
end;

function Be16(const D: TBytes; P: Integer): Integer;
begin
  if P + 1 >= Length(D) then
    Exit(0);
  Result := (Integer(D[P]) shl 8) or Integer(D[P + 1]);
end;

function Le16(const D: TBytes; P: Integer): Integer;
begin
  if P + 1 >= Length(D) then
    Exit(0);
  Result := (Integer(D[P + 1]) shl 8) or Integer(D[P]);
end;

function Be32(const D: TBytes; P: Integer): Int64;
begin
  if P + 3 >= Length(D) then
    Exit(0);
  Result := (Int64(D[P]) shl 24) or (Int64(D[P + 1]) shl 16) or
            (Int64(D[P + 2]) shl 8) or Int64(D[P + 3]);
end;

function Le32(const D: TBytes; P: Integer): Int64;
begin
  if P + 3 >= Length(D) then
    Exit(0);
  Result := (Int64(D[P + 3]) shl 24) or (Int64(D[P + 2]) shl 16) or
            (Int64(D[P + 1]) shl 8) or Int64(D[P]);
end;

{ A TStr is a slice into a buffer somebody else owns. It is copied here
  because the rest of the unit works in TBytes, and because the header is
  a few kilobytes anyway — not the whole upload. }
function StrBytes(const S: TStr; MaxSide: Integer): TBytes;
var
  N: Integer;
  B: TBytes;
begin
  B := nil;
  N := S.Len;
  if (MaxSide > 0) and (N > MaxSide) then
    N := MaxSide;
  SetLength(B, N);
  if N > 0 then
    Move(S.Data^, B[0], N);
  Result := B;
end;

{ ------------------------------------------------------------- sniffing -- }

function SniffFormat(const Data: TBytes): TImageFormat;
var
  I: Integer;
begin
  Result := ifUnknown;
  if Length(Data) < 12 then
    Exit;

  if Has_(Data, 0, [$FF, $D8, $FF]) then
    Exit(ifJpeg);
  if Has_(Data, 0, [$89, $50, $4E, $47, $0D, $0A, $1A, $0A]) then
    Exit(ifPng);
  if Has_(Data, 0, [$47, $49, $46, $38]) then   { GIF8 }
    Exit(ifGif);
  { RIFF....WEBP }
  if Has_(Data, 0, [$52, $49, $46, $46]) and Has_(Data, 8, [$57, $45, $42, $50]) then
    Exit(ifWebp);
  if Has_(Data, 0, [$42, $4D]) then             { BM }
    Exit(ifBmp);
  { ....ftypavif / ftypavis }
  if Has_(Data, 4, [$66, $74, $79, $70]) and
     (Has_(Data, 8, [$61, $76, $69, $66]) or Has_(Data, 8, [$61, $76, $69, $73])) then
    Exit(ifAvif);
  if Has_(Data, 0, [$49, $49, $2A, $00]) or Has_(Data, 0, [$4D, $4D, $00, $2A]) then
    Exit(ifTiff);

  { SVG is text, and therefore a special case: there is no magic byte. It
    counts as an image here because people upload it as one, but SVG can
    contain scripts and must NEVER be served from the same origin as the
    app. That is in docs/images.md. }
  for I := 0 to 255 do
  begin
    if I + 4 > Length(Data) then
      Break;
    if (Data[I] = $3C) and                     { < }
       ((Has_(Data, I, [$3C, $73, $76, $67]) ) or
        (Has_(Data, I, [$3C, $3F, $78, $6D]) )) then
    begin
      if Has_(Data, I, [$3C, $73, $76, $67]) then
        Exit(ifSvg);
    end;
  end;
end;

function SniffFormat(const Path: string): TImageFormat;
begin
  Result := SniffFormat(Read_(Path, 4096));
end;

function SniffFormat(const S: TStr): TImageFormat;
begin
  Result := SniffFormat(StrBytes(S, 4096));
end;

function MimeTypeFor(F: TImageFormat): string;
begin
  case F of
    ifJpeg: Result := 'image/jpeg';
    ifPng:  Result := 'image/png';
    ifGif:  Result := 'image/gif';
    ifWebp: Result := 'image/webp';
    ifBmp:  Result := 'image/bmp';
    ifAvif: Result := 'image/avif';
    ifTiff: Result := 'image/tiff';
    ifSvg:  Result := 'image/svg+xml';
  else
    Result := '';
  end;
end;

function ExtensionFor(F: TImageFormat): string;
begin
  case F of
    ifJpeg: Result := '.jpg';
    ifPng:  Result := '.png';
    ifGif:  Result := '.gif';
    ifWebp: Result := '.webp';
    ifBmp:  Result := '.bmp';
    ifAvif: Result := '.avif';
    ifTiff: Result := '.tiff';
    ifSvg:  Result := '.svg';
  else
    Result := '';
  end;
end;

{ ---------------------------------------------------------- dimensjoner -- }

{ JPEG: walk the segments until a SOF, which carries the height and
  width.

  All the SOF markers count — SOF0 is baseline, SOF2 progressive, and
  there are a dozen more. DHT, DAC and RSTn are NOT SOF, and including
  them is the usual mistake: then the length field is read as
  dimensions. }
function JpegSize(const D: TBytes; out W, H: Integer): Boolean;
var
  P, Len: Integer;
  M: Byte;
begin
  W := 0; H := 0;
  Result := False;
  P := 2;
  while P + 3 < Length(D) do
  begin
    if D[P] <> $FF then
    begin
      Inc(P);
      Continue;
    end;
    M := D[P + 1];
    { Fyllbyte. }
    if M = $FF then
    begin
      Inc(P);
      Continue;
    end;
    { Markers with no length field. }
    if (M = $D8) or ((M >= $D0) and (M <= $D9)) or (M = $01) then
    begin
      Inc(P, 2);
      Continue;
    end;
    Len := Be16(D, P + 2);
    if Len < 2 then
      Exit;
    { SOF0..SOF15, but not DHT ($C4), JPG ($C8) and DAC ($CC). }
    if ((M >= $C0) and (M <= $CF)) and (M <> $C4) and (M <> $C8) and (M <> $CC) then
    begin
      if P + 9 >= Length(D) then
        Exit;
      H := Be16(D, P + 5);
      W := Be16(D, P + 7);
      Exit((W > 0) and (H > 0));
    end;
    { SOS: compressed data starts here, and there is no SOF after it. }
    if M = $DA then
      Exit;
    Inc(P, 2 + Len);
  end;
end;

function ReadImageInfo(const Data: TBytes): TImageInfo;
var
  P, Len: Integer;
  Block: Int64;
begin
  Result.Format := SniffFormat(Data);
  Result.Width := 0;
  Result.Height := 0;
  Result.Ok := False;
  Result.Animated := False;

  case Result.Format of
    ifJpeg:
      Result.Ok := JpegSize(Data, Result.Width, Result.Height);

    ifPng:
      begin
        { IHDR always comes first, right after the eight-byte signature,
          and carries width and height as big-endian. }
        if (Length(Data) >= 24) and Has_(Data, 12, [$49, $48, $44, $52]) then
        begin
          Result.Width := Integer(Be32(Data, 16));
          Result.Height := Integer(Be32(Data, 20));
          Result.Ok := (Result.Width > 0) and (Result.Height > 0);
        end;
        { APNG: an acTL chunk before IDAT. }
        P := 8;
        while P + 8 <= Length(Data) do
        begin
          Block := Be32(Data, P);
          if Has_(Data, P + 4, [$61, $63, $54, $4C]) then
          begin
            Result.Animated := True;
            Break;
          end;
          if Has_(Data, P + 4, [$49, $44, $41, $54]) then
            Break;
          if (Block < 0) or (Block > Length(Data)) then
            Break;
          Inc(P, 12 + Integer(Block));
        end;
      end;

    ifGif:
      begin
        if Length(Data) >= 10 then
        begin
          Result.Width := Le16(Data, 6);
          Result.Height := Le16(Data, 8);
          Result.Ok := (Result.Width > 0) and (Result.Height > 0);
        end;
        { An animated GIF has more than one frame. Counting them properly
          means walking the blocks; here it is enough to look for the
          NETSCAPE extension, which every animated one has. }
        for P := 0 to Length(Data) - 11 do
          if Has_(Data, P, [$4E, $45, $54, $53, $43, $41, $50, $45]) then
          begin
            Result.Animated := True;
            Break;
          end;
      end;

    ifWebp:
      begin
        { Three varianter: VP8 (lossy), VP8L (lossless), VP8X (utvidet). }
        if Has_(Data, 12, [$56, $50, $38, $20]) and (Length(Data) >= 30) then
        begin
          Result.Width := Le16(Data, 26) and $3FFF;
          Result.Height := Le16(Data, 28) and $3FFF;
          Result.Ok := (Result.Width > 0) and (Result.Height > 0);
        end
        else if Has_(Data, 12, [$56, $50, $38, $4C]) and (Length(Data) >= 25) then
        begin
          { 14 bits of width and 14 of height, packed over four bytes. }
          Len := Integer(Le32(Data, 21));
          Result.Width := (Len and $3FFF) + 1;
          Result.Height := ((Len shr 14) and $3FFF) + 1;
          Result.Ok := True;
        end
        else if Has_(Data, 12, [$56, $50, $38, $58]) and (Length(Data) >= 30) then
        begin
          { 24 bit, minus én, little-endian. }
          Result.Width := (Integer(Data[24]) or (Integer(Data[25]) shl 8) or
                           (Integer(Data[26]) shl 16)) + 1;
          Result.Height := (Integer(Data[27]) or (Integer(Data[28]) shl 8) or
                            (Integer(Data[29]) shl 16)) + 1;
          Result.Ok := True;
          { Bit 1 i flaggbyten sier animasjon. }
          Result.Animated := (Data[20] and $02) <> 0;
        end;
      end;

    ifBmp:
      if Length(Data) >= 26 then
      begin
        Result.Width := Integer(Le32(Data, 18));
        Result.Height := Abs(Integer(Le32(Data, 22)));
        Result.Ok := (Result.Width > 0) and (Result.Height > 0);
      end;
    ifUnknown, ifAvif, ifTiff, ifSvg:
      { AVIF and TIFF have dimensions, but behind enough structure that
        reading them is decoding in practice. SVG often does not have them
        at all. Format is set; Ok stays False, and that is the answer. }
      ;
  end;
end;

function ReadImageInfo(const Path: string): TImageInfo;
begin
  { 64 kB is enough for the header in every format above. The GIF's
    NETSCAPE extension comes early, and the PNG's acTL before IDAT. }
  Result := ReadImageInfo(Read_(Path, 64 * 1024));
end;

function ReadImageInfo(const S: TStr): TImageInfo;
begin
  Result := ReadImageInfo(StrBytes(S, 64 * 1024));
end;

function ExtensionMatches(const FileName: string; const Data: TBytes): Boolean;
var
  E: string;
  F: TImageFormat;
begin
  F := SniffFormat(Data);
  if F = ifUnknown then
    Exit(False);
  E := LowerCase(ExtractFileExt(FileName));
  if E = '.jpeg' then
    E := '.jpg';
  if E = '.tif' then
    E := '.tiff';
  if E = '.htm' then
    E := '.html';
  Result := E = ExtensionFor(F);
end;

function ExtensionMatches(const FileName: string; const S: TStr): Boolean;
begin
  Result := ExtensionMatches(FileName, StrBytes(S, 4096));
end;

{ ----------------------------------------------------------------- EXIF -- }

function JpegOrientation(const Data: TBytes): Integer;
var
  P, Len, Tiff, Count_, I, Field_: Integer;
  LittleEndian: Boolean;

  function Read16(Pos_: Integer): Integer;
  begin
    if LittleEndian then
      Result := Le16(Data, Pos_)
    else
      Result := Be16(Data, Pos_);
  end;

  function Read32(Pos_: Integer): Int64;
  begin
    if LittleEndian then
      Result := Le32(Data, Pos_)
    else
      Result := Be32(Data, Pos_);
  end;

begin
  Result := 0;
  if SniffFormat(Data) <> ifJpeg then
    Exit;

  P := 2;
  while P + 3 < Length(Data) do
  begin
    if Data[P] <> $FF then
    begin
      Inc(P);
      Continue;
    end;
    if Data[P + 1] = $DA then
      Exit;
    Len := Be16(Data, P + 2);
    if Len < 2 then
      Exit;
    { APP1 med Exif\0\0. }
    if (Data[P + 1] = $E1) and Has_(Data, P + 4, [$45, $78, $69, $66, $00, $00]) then
    begin
      Tiff := P + 10;
      if Tiff + 8 > Length(Data) then
        Exit;
      LittleEndian := Has_(Data, Tiff, [$49, $49]);
      if not (LittleEndian or Has_(Data, Tiff, [$4D, $4D])) then
        Exit;
      I := Tiff + Integer(Read32(Tiff + 4));
      if (I + 2 > Length(Data)) or (I < Tiff) then
        Exit;
      Count_ := Read16(I);
      Inc(I, 2);
      { Hvert felt er tolv byte: tag, type, antall, verdi. }
      for Field_ := 0 to Count_ - 1 do
      begin
        if I + 12 > Length(Data) then
          Exit;
        if Read16(I) = $0112 then          { Orientation }
        begin
          Result := Read16(I + 8);
          if (Result < 1) or (Result > 8) then
            Result := 0;
          Exit;
        end;
        Inc(I, 12);
      end;
      Exit;
    end;
    Inc(P, 2 + Len);
  end;
end;

function StripJpegMetadata(const Data: TBytes; out Ut: TBytes): Boolean;
var
  P, Len, N, I: Integer;
  B: TBytes;
  M: Byte;
  Behold: Boolean;
begin
  B := nil;
  Ut := B;
  Result := False;
  if SniffFormat(Data) <> ifJpeg then
    Exit;

  SetLength(B, Length(Data));
  N := 0;
  { SOI beholdes alltid. }
  B[0] := Data[0]; B[1] := Data[1];
  N := 2;
  P := 2;

  while P + 3 < Length(Data) do
  begin
    if Data[P] <> $FF then
    begin
      Inc(P);
      Continue;
    end;
    M := Data[P + 1];
    if M = $FF then
    begin
      Inc(P);
      Continue;
    end;

    { SOS: from here on it is compressed data, and everything is copied
      unchanged. }
    if M = $DA then
    begin
      for I := P to Length(Data) - 1 do
      begin
        B[N] := Data[I];
        Inc(N);
      end;
      SetLength(B, N);
      Ut := B;
      Exit(True);
    end;

    Len := Be16(Data, P + 2);
    if (Len < 2) or (P + 2 + Len > Length(Data)) then
      Exit;

    { APP0 is kept: JFIF says something about resolution, and some
      readers get upset without it. APP1 through APP15 and COM are
      metadata and go — that is where EXIF, XMP, IPTC and Photoshop
      resources live.

      APP2 with ICC_PROFILE is kept anyway: without the colour profile an
      image can visibly shift colour, and that is not metadata in the same
      sense. }
    Behold := True;
    if (M >= $E1) and (M <= $EF) then
      Behold := (M = $E2) and Has_(Data, P + 4, [$49, $43, $43, $5F]);
    if M = $FE then
      Behold := False;

    if Behold then
      for I := P to P + 1 + Len do
      begin
        B[N] := Data[I];
        Inc(N);
      end;

    Inc(P, 2 + Len);
  end;

  { If we got here there was no SOS. Then the file is truncated. }
  Result := False;
end;

end.
