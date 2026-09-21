{ Askr.Image.Vips — skalering og formatkonvertering, med libvips.

  Askr.Image sier hva et bilde ER uten å dekode det. Denne gjør det
  arbeidet som krever piksler, og det krever et bibliotek: å skrive en
  JPEG- og WebP-dekoder i Pascal ville vært flere tusen linjer og
  likevel tregere og mindre korrekt enn libvips.

  LASTES MED DLOPEN, SOM ALT ANNET NATIVT

  Samme mønster som OpenSSL, libpq, libmariadb og sqlite3: binæren
  starter uten libvips, og en app som aldri skalerer et bilde betaler
  ingenting. Missing biblioteket, sier `VipsError` hva som skal
  installeres — den lister ikke bare stier den lette i.

  Det er også grunnen til at dette IKKE er ren Pascal slik kryptoen er.
  Kryptoen må være det fordi enhver app med brukere trenger
  passordhashing; et rammeverk som legger den på libcrypto kan ikke
  kalle avhengigheten valgfri. Bildebehandling trenger ikke alle.

  OPSJONER GÅR I STRENGEN, IKKE I VARARGS

  Hele libvips' C-API er variadisk: valgfrie parametre sendes som
  NULL-terminerte navn/verdi-par. Der det går, unngås det ved at
  libvips også tar opsjoner i selve formatstrengen — `.jpg[Q=80]` —
  som er én vanlig peker. Det som gjenstår av varargs er erklært med
  FPCs `varargs`, slik at kompilatoren bruker plattformens egen
  konvensjon. Å telle argumenter for hånd på arm64 er nettopp feilen
  objc_msgSend allerede har lært oss. }
unit Askr.Image.Vips;

{$mode Delphi}{$H+}

interface

uses
{$IFDEF UNIX}
  dl,
{$ENDIF}
  SysUtils, Math, Askr.Image;

type
  EVipsError = class(Exception);

  { Hvordan et bilde skal passe inn i boksen. }
  TFitMode = (
    { Skalér ned til det får plass. Bevarer forholdet, fyller ikke
      nødvendigvis boksen. Standard, og det man vil ha til et bilde i
      en artikkel. }
    fmInside,
    { Fill boksen og beskjær det som stikker ut. To_ avatarer og
      kort, der alle rutene skal være like store. }
    fmCover
  );

{ Er libvips tilgjengelig? Laster det ved første kall. }
function VipsAvailable: Boolean;
{ Hvorfor ikke, hvis ikke. Tom streng når alt er i orden. }
function VipsError: string;
{ Versjonen, som '8.14.1'. Tom streng når biblioteket mangler. }
function VipsVersion: string;

{ Skalerer et bilde og gir det tilbake i Format.

  Width_ eller høyde kan være 0, og betyr da «regn den ut». Er begge
  satt, avgjør Fit hva som skjer med forholdet.

  Kvalitet gjelder JPEG og WebP, og ignoreres for PNG. 0 betyr
  bibliotekets standard.

  Skalerer aldri opp: et bilde som alt er mindre enn boksen kommer ut
  som det er. Å blåse opp en thumbnail gir et uskarpt bilde og en
  større fil, og er aldri det noen ba om. }
function ResizeImage(const Data: TBytes; Width, Height: Integer;
  Format: TImageFormat; Quality: Integer = 0;
  Fit: TFitMode = fmInside): TBytes;

{ Bare formatkonvertering, uten å endre størrelsen. }
function ConvertImage(const Data: TBytes; Format: TImageFormat;
  Quality: Integer = 0): TBytes;

implementation

{$IFDEF UNIX}
const
  { Rekkefølgen er med vilje: Debian og Homebrew først, så de generiske
    navnene. En som har bygget selv har som regel det siste. }
  Kandidater: array[0..5] of string = (
    'libvips.so.42',
    'libvips.42.dylib',
    'libvips.so',
    'libvips.dylib',
    '/opt/homebrew/lib/libvips.42.dylib',
    '/usr/local/lib/libvips.42.dylib'
  );
{$ENDIF}

type
  TVipsInit = function(Argv0: PAnsiChar): Integer; cdecl;
  TVipsErrorBuffer = function: PAnsiChar; cdecl;
  TVipsErrorClear = procedure; cdecl;
  TVipsVersion = function(Flag: Integer): Integer; cdecl;
  TGObjectUnref = procedure(Obj: Pointer); cdecl;
  TGFree = procedure(P: Pointer); cdecl;

  { Variadiske. FPCs varargs lar kompilatoren bruke plattformens egen
    konvensjon; å erklære dem med faste parametre ville vært feil på
    arm64. Siste argument er alltid nil. }
  TVipsThumbnailBuffer = function(Buf: Pointer; Len: NativeUInt;
    out Img: Pointer; Width: Integer): Integer; cdecl varargs;
  TVipsWriteToBuffer = function(Img: Pointer; Suffix: PAnsiChar;
    out Buf: Pointer; out Len: NativeUInt): Integer; cdecl varargs;
  TVipsNewFromBuffer = function(Buf: Pointer; Len: NativeUInt;
    OptionStr: PAnsiChar; out Img: Pointer): Integer; cdecl varargs;

var
  GLastet: Boolean = False;
  GOk: Boolean = False;
  GErr: string = '';
  GHandle: Pointer = nil;

  vips_init: TVipsInit = nil;
  vips_error_buffer: TVipsErrorBuffer = nil;
  vips_error_clear: TVipsErrorClear = nil;
  vips_version: TVipsVersion = nil;
  vips_thumbnail_buffer: TVipsThumbnailBuffer = nil;
  vips_image_write_to_buffer: TVipsWriteToBuffer = nil;
  vips_image_new_from_buffer: TVipsNewFromBuffer = nil;
  g_object_unref: TGObjectUnref = nil;
  g_free: TGFree = nil;

{ ------------------------------------------------------------- lasting -- }

{$IFDEF UNIX}
{ Utypet var-parameter: Pointer(vips_init) i Delphi-modus KALLER
  variabelen i stedet for aa ta adressen. }
function Symbol(const Name_: string; var P): Boolean;
begin
  Pointer(P) := dlsym(GHandle, PChar(Name_));
  Result := Pointer(P) <> nil;
end;
{$ENDIF}

procedure Last;
{$IFDEF UNIX}
var
  I: Integer;
  Manglet: string;
{$ENDIF}
begin
  if GLastet then
    Exit;
  GLastet := True;
  GOk := False;

{$IFDEF UNIX}
  for I := Low(Kandidater) to High(Kandidater) do
  begin
    GHandle := dlopen(PChar(Kandidater[I]), RTLD_NOW);
    if GHandle <> nil then
      Break;
  end;
  if GHandle = nil then
  begin
    GErr := 'libvips is not installed. Image resizing needs it:' +
      LineEnding + LineEnding +
      '  Debian/Ubuntu   apt-get install libvips42' + LineEnding +
      '  macOS           brew install vips' + LineEnding +
      '  Alpine          apk add vips' + LineEnding + LineEnding +
      'Askr loads it at first use, so the binary starts without it and' +
      LineEnding +
      'an app that never resizes an image pays nothing for this.';
    Exit;
  end;

  Manglet := '';
  if not Symbol('vips_init', vips_init) then Manglet := 'vips_init';
  if not Symbol('vips_error_buffer', vips_error_buffer) then Manglet := 'vips_error_buffer';
  if not Symbol('vips_error_clear', vips_error_clear) then Manglet := 'vips_error_clear';
  if not Symbol('vips_version', vips_version) then Manglet := 'vips_version';
  if not Symbol('vips_thumbnail_buffer', vips_thumbnail_buffer) then Manglet := 'vips_thumbnail_buffer';
  if not Symbol('vips_image_write_to_buffer', vips_image_write_to_buffer) then Manglet := 'vips_image_write_to_buffer';
  if not Symbol('vips_image_new_from_buffer', vips_image_new_from_buffer) then Manglet := 'vips_image_new_from_buffer';
  if not Symbol('g_object_unref', g_object_unref) then Manglet := 'g_object_unref';
  if not Symbol('g_free', g_free) then Manglet := 'g_free';

  if Manglet <> '' then
  begin
    GErr := 'libvips was found but does not export ' + Manglet +
      '. It may be too old; Askr needs 8.9 or newer.';
    Exit;
  end;

  { Flyttallsunntakene MÅ maskeres før første libvips-kall.

    Free Pascal slår dem på; GLib, som libvips bygger på, regner
    rutinemessig med verdier som utløser dem. Without masken dør prosessen
    med EInvalidOp inne i vips_init, og stakksporet peker på biblioteker
    man ikke har skrevet — det ser ut som en feil i libvips.

    Nøyaktig samme felle som Cocoa og GTK i Askr.Desktop. Den er ikke
    valgfri, og den er funnet her ved at prosessen døde. }
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide,
                    exOverflow, exUnderflow, exPrecision]);

  { vips_init må kalles før noe annet. Feiler den, er biblioteket der,
    men ubrukelig — og da skal vi si det, ikke krasje senere. }
  if vips_init('askr') <> 0 then
  begin
    GErr := 'libvips failed to initialise.';
    Exit;
  end;
  GOk := True;
{$ELSE}
  GErr := 'Image resizing is only wired up on Unix. ' +
           'The binding loads libvips with dlopen.';
{$ENDIF}
end;

function VipsAvailable: Boolean;
begin
  Last;
  Result := GOk;
end;

function VipsError: string;
begin
  Last;
  if GOk then
    Result := ''
  else
    Result := GErr;
end;

function VipsVersion: string;
begin
  Last;
  if not GOk then
    Exit('');
  { 0 = major, 1 = minor, 2 = micro. }
  Result := Format('%d.%d.%d',
    [vips_version(0), vips_version(1), vips_version(2)]);
end;

{ ------------------------------------------------------------- hjelpere -- }

procedure Expect;
begin
  if not VipsAvailable then
    raise EVipsError.Create(GErr);
end;

function LastVipsError: string;
var
  P: PAnsiChar;
begin
  Result := '';
  if not Assigned(vips_error_buffer) then
    Exit;
  P := vips_error_buffer;
  if P <> nil then
    Result := Trim(string(P));
  if Assigned(vips_error_clear) then
    vips_error_clear;
end;

{ Endelsen libvips skriver med, inkludert opsjoner. Opsjonene går her
  og ikke som varargs — én streng er én peker, og det er det tryggeste
  over en variadisk grense. }
function Suffix(F: TImageFormat; Kvalitet: Integer): string;
begin
  case F of
    ifJpeg:
      begin
        Result := '.jpg';
        if Kvalitet > 0 then
          Result := Result + '[Q=' + IntToStr(Kvalitet) + ',strip=true]'
        else
          Result := Result + '[strip=true]';
      end;
    ifWebp:
      begin
        Result := '.webp';
        if Kvalitet > 0 then
          Result := Result + '[Q=' + IntToStr(Kvalitet) + ',strip=true]'
        else
          Result := Result + '[strip=true]';
      end;
    ifPng:
      { PNG er tapsfritt, så Q betyr ingenting. strip=true tar
        metadata, som er hele grunnen til at det står her. }
      Result := '.png[strip=true]';
    ifGif:
      Result := '.gif';
    ifAvif:
      begin
        Result := '.avif';
        if Kvalitet > 0 then
          Result := Result + '[Q=' + IntToStr(Kvalitet) + ']';
      end;
  else
    raise EVipsError.Create('Cannot write that image format.');
  end;
end;

function Kopier(P: Pointer; N: NativeUInt): TBytes;
var
  B: TBytes;
begin
  B := nil;
  SetLength(B, N);
  if N > 0 then
    Move(P^, B[0], N);
  Result := B;
end;

{ ---------------------------------------------------------- operasjoner -- }

function ResizeImage(const Data: TBytes; Width, Height: Integer;
  Format: TImageFormat; Quality: Integer; Fit: TFitMode): TBytes;
var
  Img, Ut: Pointer;
  Len: NativeUInt;
  Inn: TImageInfo;
  Res: Integer;
  S: AnsiString;
begin
  Result := nil;
  Expect;
  if Length(Data) = 0 then
    raise EVipsError.Create('The image is empty.');

  { Askr.Image leser dimensjonene uten å dekode, og det er nok til å
    avgjøre om det i det hele tatt er noe å gjøre. }
  Inn := ReadImageInfo(Data);
  if Inn.Format = ifUnknown then
    raise EVipsError.Create('That file is not an image Askr recognises.');

  if Width <= 0 then
    Width := Inn.Width;
  if Width <= 0 then
    raise EVipsError.Create('Could not work out a target width.');

  { Aldri opp. Et bilde som alt er mindre enn boksen kommer ut som det
    er — oppblåsing gir uskarphet og en større fil, og er aldri det
    noen ba om. Formatet kan likevel være et annet, så konverteringen
    gjøres uansett. }
  if Inn.Ok and (Inn.Width > 0) and (Width > Inn.Width) then
    Width := Inn.Width;

  Img := nil;
  S := AnsiString(Suffix(Format, Quality));

  if (Height > 0) and (Fit = fmCover) then
    { crop=centre fyller boksen og beskjærer resten. VIPS_INTERESTING_CENTRE
      er 2. }
    Res := vips_thumbnail_buffer(@Data[0], Length(Data), Img, Width,
             PAnsiChar('height'), Height, PAnsiChar('crop'), 2, nil)
  else if Height > 0 then
    Res := vips_thumbnail_buffer(@Data[0], Length(Data), Img, Width,
             PAnsiChar('height'), Height, nil)
  else
    Res := vips_thumbnail_buffer(@Data[0], Length(Data), Img, Width, nil);

  if (Res <> 0) or (Img = nil) then
    raise EVipsError.Create('Could not read that image: ' + LastVipsError);

  try
    Ut := nil;
    Len := 0;
    if vips_image_write_to_buffer(Img, PAnsiChar(S), Ut, Len, nil) <> 0 then
      raise EVipsError.Create('Could not write the image: ' + LastVipsError);
    try
      Result := Kopier(Ut, Len);
    finally
      { Bufferet er libvips sitt, og må frigjøres med g_free. Å la det
        stå er en lekkasje per skalering. }
      if Ut <> nil then
        g_free(Ut);
    end;
  finally
    g_object_unref(Img);
  end;
end;

function ConvertImage(const Data: TBytes; Format: TImageFormat;
  Quality: Integer): TBytes;
var
  Inn: TImageInfo;
begin
  Expect;
  Inn := ReadImageInfo(Data);
  if not Inn.Ok then
    raise EVipsError.Create('Could not read the image dimensions.');
  { Samme vei som skalering, med bredden bildet alt har. Én kodesti er
    én kodesti å teste. }
  Result := ResizeImage(Data, Inn.Width, 0, Format, Quality, fmInside);
end;

end.
