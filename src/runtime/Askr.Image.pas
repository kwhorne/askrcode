{ Askr.Image — det du kan vite om et bilde uten å dekode det.

  Formatet leses av magiske byte, dimensjonene av hodet, og EXIF fjernes
  ved å skrive om segmenter. Ingenting her dekoder en eneste piksel, og
  uniten har derfor ingen avhengigheter i det hele tatt. Skalering og
  formatkonvertering ligger i Askr.Image.Vips, som laster libvips med
  dlopen og sier tydelig fra når det mangler.

  DETTE ER FØRST OG FREMST EN SIKKERHETSUNIT

  En opplastet fil som heter `.jpg` og faktisk er HTML er en lagret
  XSS-vektor: serveres den tilbake med feil Content-Type, kjører den i
  leserens nettleser under ditt domene. Filnavnet kommer fra en angriper
  og betyr ingenting. `SniffFormat` ser på innholdet.

  Og EXIF er en personvernlekkasje som er lett å glemme: et bilde tatt
  med en telefon bærer ofte GPS-koordinater. Legger noen ut et
  profilbilde, legger de ut hjemmeadressen sin med mindre noen har
  fjernet den. }
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
    { True når hodet ble lest og bredde og høyde er ekte tall. For et
      format vi kjenner, men ikke kan måle, er Format satt og Ok False. }
    Ok: Boolean;
    { Animert GIF eller WebP. Verdt å vite fordi en «avatar» som
      animerer sjelden er det noen ville hatt. }
    Animated: Boolean;
  end;

{ Formatet ut fra de første bytene. Ser aldri på filnavnet. }
function SniffFormat(const Data: TBytes): TImageFormat; overload;
function SniffFormat(const Path: string): TImageFormat; overload;
{ Rett på en opplasting: TUploadedFile.Content er en TStr inn i
  workerens lesebuffer, og kopieres ikke her.

  ContentType fra klienten er en påstand, ikke en måling — en .exe kan
  meldes som image/png. Dette er målingen. }
function SniffFormat(const S: TStr): TImageFormat; overload;

{ Navnet slik det skrives i en Content-Type. Tom streng for ifUnknown. }
function MimeTypeFor(F: TImageFormat): string;
{ Den vanlige endelsen, med punktum. }
function ExtensionFor(F: TImageFormat): string;

{ Leser format og dimensjoner uten å dekode. }
function ReadImageInfo(const Data: TBytes): TImageInfo; overload;
function ReadImageInfo(const Path: string): TImageInfo; overload;
function ReadImageInfo(const S: TStr): TImageInfo; overload;

{ Sier endelsen det samme som innholdet?

  Brukes på opplastinger: en .png som egentlig er JPEG er som regel
  harmløs slurv, mens en .png som er HTML ikke er det. Begge deler skal
  stoppes samme sted. }
function ExtensionMatches(const FileName: string; const Data: TBytes): Boolean; overload;
function ExtensionMatches(const FileName: string; const S: TStr): Boolean; overload;

{ Fjerner EXIF, XMP og kommentarer fra en JPEG.

  Pikslene røres ikke: bare APPn- og COM-segmentene hoppes over mens
  fila skrives om. Returnerer False når inndata ikke er en JPEG i det
  hele tatt; da er Ut uendret. }
function StripJpegMetadata(const Data: TBytes; out Ut: TBytes): Boolean;

{ Orienteringen fra EXIF, 1 til 8, eller 0 når den ikke står der.

  Verdt å lese FØR man fjerner EXIF: en telefon skriver ofte bildet
  liggende og lar orienteringen si at det skal vises stående. Strippes
  EXIF uten å rotere først, står bildet feil vei for alltid. }
function JpegOrientation(const Data: TBytes): Integer;

implementation

{ ------------------------------------------------------------ hjelpere -- }

function Les(const Path: string; Maks: Integer): TBytes;
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
    if (Maks > 0) and (N > Maks) then
      N := Maks;
    SetLength(B, N);
    if N > 0 then
      F.ReadBuffer(B[0], N);
    Result := B;
  finally
    F.Free;
  end;
end;

function Har(const D: TBytes; Pos_: Integer; const Magisk: array of Byte): Boolean;
var
  I: Integer;
begin
  Result := False;
  if Pos_ + Length(Magisk) > Length(D) then
    Exit;
  for I := 0 to High(Magisk) do
    if D[Pos_ + I] <> Magisk[I] then
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

{ TStr er et utsnitt inn i et buffer noen andre eier. Det kopieres her
  fordi resten av uniten regner i TBytes, og fordi hodet uansett er noen
  kilobyte — ikke hele opplastingen. }
function StrBytes(const S: TStr; Maks: Integer): TBytes;
var
  N: Integer;
  B: TBytes;
begin
  B := nil;
  N := S.Len;
  if (Maks > 0) and (N > Maks) then
    N := Maks;
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

  if Har(Data, 0, [$FF, $D8, $FF]) then
    Exit(ifJpeg);
  if Har(Data, 0, [$89, $50, $4E, $47, $0D, $0A, $1A, $0A]) then
    Exit(ifPng);
  if Har(Data, 0, [$47, $49, $46, $38]) then   { GIF8 }
    Exit(ifGif);
  { RIFF....WEBP }
  if Har(Data, 0, [$52, $49, $46, $46]) and Har(Data, 8, [$57, $45, $42, $50]) then
    Exit(ifWebp);
  if Har(Data, 0, [$42, $4D]) then             { BM }
    Exit(ifBmp);
  { ....ftypavif / ftypavis }
  if Har(Data, 4, [$66, $74, $79, $70]) and
     (Har(Data, 8, [$61, $76, $69, $66]) or Har(Data, 8, [$61, $76, $69, $73])) then
    Exit(ifAvif);
  if Har(Data, 0, [$49, $49, $2A, $00]) or Har(Data, 0, [$4D, $4D, $00, $2A]) then
    Exit(ifTiff);

  { SVG er tekst, og derfor et spesialtilfelle: det finnes ingen magisk
    byte. Den regnes som et bilde her fordi noen laster den opp som ett,
    men SVG kan inneholde skript og skal ALDRI serveres fra samme
    origin som appen. Det står i docs/images.md. }
  for I := 0 to 255 do
  begin
    if I + 4 > Length(Data) then
      Break;
    if (Data[I] = $3C) and                     { < }
       ((Har(Data, I, [$3C, $73, $76, $67]) ) or
        (Har(Data, I, [$3C, $3F, $78, $6D]) )) then
    begin
      if Har(Data, I, [$3C, $73, $76, $67]) then
        Exit(ifSvg);
    end;
  end;
end;

function SniffFormat(const Path: string): TImageFormat;
begin
  Result := SniffFormat(Les(Path, 4096));
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

{ JPEG: gå gjennom segmentene til en SOF, som bærer høyde og bredde.

  Alle SOF-markørene teller — SOF0 er baseline, SOF2 progressiv, og det
  finnes et dusin til. DHT, DAC og RSTn er IKKE SOF, og å ta dem med er
  den vanlige feilen: da leses lengdefeltet som dimensjoner. }
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
    { Markører uten lengdefelt. }
    if (M = $D8) or ((M >= $D0) and (M <= $D9)) or (M = $01) then
    begin
      Inc(P, 2);
      Continue;
    end;
    Len := Be16(D, P + 2);
    if Len < 2 then
      Exit;
    { SOF0..SOF15, men ikke DHT ($C4), JPG ($C8) og DAC ($CC). }
    if ((M >= $C0) and (M <= $CF)) and (M <> $C4) and (M <> $C8) and (M <> $CC) then
    begin
      if P + 9 >= Length(D) then
        Exit;
      H := Be16(D, P + 5);
      W := Be16(D, P + 7);
      Exit((W > 0) and (H > 0));
    end;
    { SOS: nå kommer komprimerte data, og det er ingen SOF etter. }
    if M = $DA then
      Exit;
    Inc(P, 2 + Len);
  end;
end;

function ReadImageInfo(const Data: TBytes): TImageInfo;
var
  P, Len: Integer;
  Blokk: Int64;
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
        { IHDR står alltid først, rett etter den åtte byte lange
          signaturen, og har bredde og høyde som big-endian. }
        if (Length(Data) >= 24) and Har(Data, 12, [$49, $48, $44, $52]) then
        begin
          Result.Width := Integer(Be32(Data, 16));
          Result.Height := Integer(Be32(Data, 20));
          Result.Ok := (Result.Width > 0) and (Result.Height > 0);
        end;
        { APNG: en acTL-chunk før IDAT. }
        P := 8;
        while P + 8 <= Length(Data) do
        begin
          Blokk := Be32(Data, P);
          if Har(Data, P + 4, [$61, $63, $54, $4C]) then
          begin
            Result.Animated := True;
            Break;
          end;
          if Har(Data, P + 4, [$49, $44, $41, $54]) then
            Break;
          if (Blokk < 0) or (Blokk > Length(Data)) then
            Break;
          Inc(P, 12 + Integer(Blokk));
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
        { En animert GIF har mer enn ett bilde. Å telle dem ordentlig
          krever å gå gjennom blokkene; her holder det å se etter
          NETSCAPE-utvidelsen, som alle animerte har. }
        for P := 0 to Length(Data) - 11 do
          if Har(Data, P, [$4E, $45, $54, $53, $43, $41, $50, $45]) then
          begin
            Result.Animated := True;
            Break;
          end;
      end;

    ifWebp:
      begin
        { Tre varianter: VP8 (lossy), VP8L (lossless), VP8X (utvidet). }
        if Har(Data, 12, [$56, $50, $38, $20]) and (Length(Data) >= 30) then
        begin
          Result.Width := Le16(Data, 26) and $3FFF;
          Result.Height := Le16(Data, 28) and $3FFF;
          Result.Ok := (Result.Width > 0) and (Result.Height > 0);
        end
        else if Har(Data, 12, [$56, $50, $38, $4C]) and (Length(Data) >= 25) then
        begin
          { 14 bit bredde og 14 bit høyde, pakket over fire byte. }
          Len := Integer(Le32(Data, 21));
          Result.Width := (Len and $3FFF) + 1;
          Result.Height := ((Len shr 14) and $3FFF) + 1;
          Result.Ok := True;
        end
        else if Har(Data, 12, [$56, $50, $38, $58]) and (Length(Data) >= 30) then
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
      { AVIF og TIFF har dimensjoner, men bak nok struktur til at det
        er dekoding i praksis. SVG har dem ofte ikke i det hele tatt.
        Format er satt; Ok blir staaende False, og det er svaret. }
      ;
  end;
end;

function ReadImageInfo(const Path: string): TImageInfo;
begin
  { 64 kB rekker til hodet i alle formatene over. GIF-ens
    NETSCAPE-utvidelse står tidlig, og PNG-ens acTL før IDAT. }
  Result := ReadImageInfo(Les(Path, 64 * 1024));
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
  P, Len, Tiff, Antall, I, Felt: Integer;
  LilleEndian: Boolean;

  function Les16(Pos_: Integer): Integer;
  begin
    if LilleEndian then
      Result := Le16(Data, Pos_)
    else
      Result := Be16(Data, Pos_);
  end;

  function Les32(Pos_: Integer): Int64;
  begin
    if LilleEndian then
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
    if (Data[P + 1] = $E1) and Har(Data, P + 4, [$45, $78, $69, $66, $00, $00]) then
    begin
      Tiff := P + 10;
      if Tiff + 8 > Length(Data) then
        Exit;
      LilleEndian := Har(Data, Tiff, [$49, $49]);
      if not (LilleEndian or Har(Data, Tiff, [$4D, $4D])) then
        Exit;
      I := Tiff + Integer(Les32(Tiff + 4));
      if (I + 2 > Length(Data)) or (I < Tiff) then
        Exit;
      Antall := Les16(I);
      Inc(I, 2);
      { Hvert felt er tolv byte: tag, type, antall, verdi. }
      for Felt := 0 to Antall - 1 do
      begin
        if I + 12 > Length(Data) then
          Exit;
        if Les16(I) = $0112 then          { Orientation }
        begin
          Result := Les16(I + 8);
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

    { SOS: fra her og ut er komprimerte data, og alt kopieres uendret. }
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

    { APP0 beholdes: JFIF sier noe om oppløsning, og noen lesere blir
      sure uten. APP1 til APP15 og COM er metadata og ryker — der ligger
      EXIF, XMP, IPTC og Photoshop-ressurser.

      APP2 med ICC_PROFILE beholdes likevel: uten fargeprofilen kan et
      bilde skifte farge synlig, og det er ikke metadata i samme
      forstand. }
    Behold := True;
    if (M >= $E1) and (M <= $EF) then
      Behold := (M = $E2) and Har(Data, P + 4, [$49, $43, $43, $5F]);
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

  { Kom vi hit, fantes ingen SOS. Da er fila avkortet. }
  Result := False;
end;

end.
