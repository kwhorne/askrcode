{ Askr.Image.Vips — resizing and format conversion, with libvips.

  Askr.Image says what an image IS without decoding it. This does the work
  that needs pixels, and that needs a library: writing a JPEG and WebP
  decoder in Pascal would be several thousand lines and still slower and
  less correct than libvips.

  LOADED WITH DLOPEN, LIKE EVERYTHING ELSE NATIVE

  The same pattern as OpenSSL, libpq, libmariadb and sqlite3: the binary
  starts without libvips, and an app that never resizes an image pays
  nothing. If the library is missing, `VipsError` says what to install —
  it does not merely list the paths it looked in.

  It is also why this is NOT pure Pascal the way the crypto is. The crypto
  has to be, because every app with users needs password hashing; a
  framework that puts that on libcrypto cannot call the dependency
  optional. Image processing is not needed by everyone.

  OPTIONS GO IN THE STRING, NOT IN VARARGS

  The whole libvips C API is variadic: optional parameters are passed as
  NULL-terminated name/value pairs. Where possible that is avoided,
  because libvips also takes options in the format string itself —
  `.jpg[Q=80]` — which is one ordinary pointer. What remains of the
  varargs is declared with FPC's `varargs`, so the compiler uses the
  platform's own convention. Counting arguments by hand on arm64 is
  exactly the mistake objc_msgSend has already taught us. }
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

  { How an image is to fit in the box. }
  TFitMode = (
    { Scale down until it fits. Preserves the ratio, does not necessarily
      fill the box. The default, and what you want for a picture in an
      article. }
    fmInside,
    { Fill the box and crop what sticks out. For avatars and cards, where
      every tile has to be the same size. }
    fmCover
  );

{ Is libvips available? Loads it on the first call. }
function VipsAvailable: Boolean;
{ Why not, if not. An empty string when all is well. }
function VipsError: string;
{ The version, as '8.14.1'. An empty string when the library is
  missing. }
function VipsVersion: string;

{ Resizes an image and returns it in Format.

  Width or height may be 0, which means "work it out". With both set, Fit
  decides what happens to the ratio.

  Quality applies to JPEG and WebP, and is ignored for PNG. 0 means the
  library's default.

  Never scales up: an image already smaller than the box comes back as it
  is. Blowing up a thumbnail gives a blurry picture and a bigger file, and
  is never what anyone asked for. }
function ResizeImage(const Data: TBytes; Width, Height: Integer;
  Format: TImageFormat; Quality: Integer = 0;
  Fit: TFitMode = fmInside): TBytes;

{ Format conversion only, without changing the size. }
function ConvertImage(const Data: TBytes; Format: TImageFormat;
  Quality: Integer = 0): TBytes;

implementation

{$IFDEF UNIX}
const
  { The order is deliberate: Debian and Homebrew first, then the generic
    names. Somebody who built it themselves usually has the latter. }
  Candidates: array[0..5] of string = (
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

  { Variadic. FPC's varargs lets the compiler use the platform's own
    convention; declaring them with fixed parameters would be wrong on
    arm64. The last argument is always nil. }
  TVipsThumbnailBuffer = function(Buf: Pointer; Len: NativeUInt;
    out Img: Pointer; Width: Integer): Integer; cdecl varargs;
  TVipsWriteToBuffer = function(Img: Pointer; Suffix: PAnsiChar;
    out Buf: Pointer; out Len: NativeUInt): Integer; cdecl varargs;
  TVipsNewFromBuffer = function(Buf: Pointer; Len: NativeUInt;
    OptionStr: PAnsiChar; out Img: Pointer): Integer; cdecl varargs;

var
  GLoaded: Boolean = False;
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
  Missing_: string;
{$ENDIF}
begin
  if GLoaded then
    Exit;
  GLoaded := True;
  GOk := False;

{$IFDEF UNIX}
  for I := Low(Candidates) to High(Candidates) do
  begin
    GHandle := dlopen(PChar(Candidates[I]), RTLD_NOW);
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

  Missing_ := '';
  if not Symbol('vips_init', vips_init) then Missing_ := 'vips_init';
  if not Symbol('vips_error_buffer', vips_error_buffer) then Missing_ := 'vips_error_buffer';
  if not Symbol('vips_error_clear', vips_error_clear) then Missing_ := 'vips_error_clear';
  if not Symbol('vips_version', vips_version) then Missing_ := 'vips_version';
  if not Symbol('vips_thumbnail_buffer', vips_thumbnail_buffer) then Missing_ := 'vips_thumbnail_buffer';
  if not Symbol('vips_image_write_to_buffer', vips_image_write_to_buffer) then Missing_ := 'vips_image_write_to_buffer';
  if not Symbol('vips_image_new_from_buffer', vips_image_new_from_buffer) then Missing_ := 'vips_image_new_from_buffer';
  if not Symbol('g_object_unref', g_object_unref) then Missing_ := 'g_object_unref';
  if not Symbol('g_free', g_free) then Missing_ := 'g_free';

  if Missing_ <> '' then
  begin
    GErr := 'libvips was found but does not export ' + Missing_ +
      '. It may be too old; Askr needs 8.9 or newer.';
    Exit;
  end;

  { The floating-point exceptions MUST be masked before the first libvips
    call.

    Free Pascal turns them on; GLib, which libvips is built on, routinely
    computes values that trigger them. Without the mask the process dies
    with EInvalidOp inside vips_init, and the stack trace points at
    libraries you did not write — it looks like a bug in libvips.

    Exactly the same trap as Cocoa and GTK in Askr.Desktop. It is not
    optional, and it was found here by the process dying. }
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide,
                    exOverflow, exUnderflow, exPrecision]);

  { vips_init has to be called before anything else. If it fails, the
    library is there but unusable — and then we should say so rather than
    crash later. }
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

{ The extension libvips writes with, options included. The options go
  here rather than as varargs — one string is one pointer, and that is the
  safest thing across a variadic boundary. }
function Suffix(F: TImageFormat; Quality: Integer): string;
begin
  case F of
    ifJpeg:
      begin
        Result := '.jpg';
        if Quality > 0 then
          Result := Result + '[Q=' + IntToStr(Quality) + ',strip=true]'
        else
          Result := Result + '[strip=true]';
      end;
    ifWebp:
      begin
        Result := '.webp';
        if Quality > 0 then
          Result := Result + '[Q=' + IntToStr(Quality) + ',strip=true]'
        else
          Result := Result + '[strip=true]';
      end;
    ifPng:
      { PNG is lossless, so Q means nothing. strip=true removes metadata,
        which is the whole reason it is here. }
      Result := '.png[strip=true]';
    ifGif:
      Result := '.gif';
    ifAvif:
      begin
        Result := '.avif';
        if Quality > 0 then
          Result := Result + '[Q=' + IntToStr(Quality) + ']';
      end;
  else
    raise EVipsError.Create('Cannot write that image format.');
  end;
end;

function CopyOf(P: Pointer; N: NativeUInt): TBytes;
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

  { Askr.Image reads the dimensions without decoding, and that is enough
    to decide whether there is anything to do at all. }
  Inn := ReadImageInfo(Data);
  if Inn.Format = ifUnknown then
    raise EVipsError.Create('That file is not an image Askr recognises.');

  if Width <= 0 then
    Width := Inn.Width;
  if Width <= 0 then
    raise EVipsError.Create('Could not work out a target width.');

  { Never up. An image already smaller than the box comes out as it is —
    blowing it up gives blur and a bigger file, and is never what anyone
    asked for. The format may still be a different one, so the conversion
    is done regardless. }
  if Inn.Ok and (Inn.Width > 0) and (Width > Inn.Width) then
    Width := Inn.Width;

  Img := nil;
  S := AnsiString(Suffix(Format, Quality));

  if (Height > 0) and (Fit = fmCover) then
    { crop=centre fills the box and crops the rest.
      VIPS_INTERESTING_CENTRE is 2. }
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
      Result := CopyOf(Ut, Len);
    finally
      { The buffer is libvips's, and has to be freed with g_free. Leaving
        it is a leak per resize. }
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
  { The same route as resizing, with the width the image already has. One
    code path is one code path to test. }
  Result := ResizeImage(Data, Inn.Width, 0, Format, Quality, fmInside);
end;

end.
