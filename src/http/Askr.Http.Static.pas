{ Askr.Http.Static — statiske filer fra en mappe.

  PRD-en legger statiske filer i web-skallet, sammen med server, TLS og
  sesjoner. I praksis er det Vite-bygget som skal ut her: en håndfull
  JS- og CSS-filer med hash i navnet.

  Det farlige ved en statisk filserver er stien. En request på
  /../../etc/passwd skal ikke nå utenfor rotmappa, og det holder ikke å lete
  etter «..» i teksten — prosentkoding, absolutte stier og symlenker må også
  stoppes. Her normaliseres stien til segmenter, og alt som peker oppover
  eller begynner med skråstrek avvises før noe røres på disk. }
unit Askr.Http.Static;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, Askr.Core.Arena, Askr.Core.Text, Askr.Core.Clock,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response;

const
  { 16 MB. Større filer serveres ikke herfra. }
  MaxStaticFileBytes = 16 * 1024 * 1024;

type
  TStaticFiles = class
  private
    FRoot: string;
    FMaxAge: Integer;
    FIndexFile: string;
    function Resolve(const UrlPath: TStr; out FullPath: string): Boolean;
  public
    { ARoot er mappa som serveres. Den må finnes. }
    constructor Create(const ARoot: string);
    { Svarer på requesten hvis fila finnes, ellers nil. Kalleren bestemmer
      hva som skjer da — ruting videre, eller 404. }
    function Serve(Req: TRequest): TResponse;
    { Sekunder i Cache-Control. 0 slår den av. Bygg med hash i filnavnet
      tåler en lang verdi; alt annet bør ha 0. }
    property MaxAge: Integer read FMaxAge write FMaxAge;
    { Fil som serveres når stien peker på en mappe. Tom slår det av. }
    property IndexFile: string read FIndexFile write FIndexFile;
    property Root: string read FRoot;
  end;

function ContentTypeForExt(const Ext: string): string;

implementation

function ContentTypeForExt(const Ext: string): string;
var
  E: string;
begin
  E := LowerCase(Ext);
  if (E = '.html') or (E = '.htm') then Exit('text/html; charset=utf-8');
  if E = '.js' then Exit('text/javascript; charset=utf-8');
  if E = '.mjs' then Exit('text/javascript; charset=utf-8');
  if E = '.css' then Exit('text/css; charset=utf-8');
  if E = '.json' then Exit('application/json');
  if E = '.svg' then Exit('image/svg+xml');
  if E = '.png' then Exit('image/png');
  if (E = '.jpg') or (E = '.jpeg') then Exit('image/jpeg');
  if E = '.webp' then Exit('image/webp');
  if E = '.gif' then Exit('image/gif');
  if E = '.ico' then Exit('image/x-icon');
  if E = '.woff2' then Exit('font/woff2');
  if E = '.woff' then Exit('font/woff');
  if E = '.map' then Exit('application/json');
  if E = '.txt' then Exit('text/plain; charset=utf-8');
  if E = '.wasm' then Exit('application/wasm');
  Result := 'application/octet-stream';
end;

constructor TStaticFiles.Create(const ARoot: string);
begin
  inherited Create;
  FRoot := ExpandFileName(ExcludeTrailingPathDelimiter(ARoot));
  FMaxAge := 0;
  FIndexFile := '';
end;

function TStaticFiles.Resolve(const UrlPath: TStr; out FullPath: string): Boolean;
var
  Rest, Seg: TStr;
  Parts: TStringList;
  S: string;
  I: Integer;
begin
  FullPath := '';
  if (UrlPath.Len = 0) or (UrlPath.Data^ <> Ord('/')) then
    Exit(False);

  Parts := TStringList.Create;
  try
    Rest := UrlPath.Slice(1);
    while Rest.Len > 0 do
    begin
      Rest.SplitAt(Ord('/'), Seg, Rest);
      S := Seg.ToString;
      if (S = '') or (S = '.') then
        Continue;
      { Alt som peker oppover avvises. Vi normaliserer ikke bort '..' ved å
        poppe — en request som prøver det er en request vi ikke vil ha. }
      if S = '..' then
        Exit(False);
      if (Pos(#0, S) > 0) or (Pos('\', S) > 0) or (Pos(':', S) > 0) then
        Exit(False);
      Parts.Add(S);
    end;

    if Parts.Count = 0 then
    begin
      if FIndexFile = '' then
        Exit(False);
      Parts.Add(FIndexFile);
    end;

    S := FRoot;
    for I := 0 to Parts.Count - 1 do
      S := S + PathDelim + Parts[I];

    if DirectoryExists(S) then
    begin
      if FIndexFile = '' then
        Exit(False);
      S := S + PathDelim + FIndexFile;
    end;

    if not FileExists(S) then
      Exit(False);

    { Siste sikring: den oppslåtte stien må fortsatt ligge under rota, også
      etter at OS har fulgt eventuelle symlenker. }
    FullPath := ExpandFileName(S);
    if Copy(FullPath, 1, Length(FRoot) + 1) <> FRoot + PathDelim then
      Exit(False);
    Result := True;
  finally
    Parts.Free;
  end;
end;

function TStaticFiles.Serve(Req: TRequest): TResponse;
var
  FullPath: string;
  F: TFileStream;
  A: TArena;
  Buf: PByte;
  Size: Int64;
  Ext: string;
begin
  Result := nil;
  if (Req.Method <> hmGet) and (Req.Method <> hmHead) then
    Exit;
  if not Resolve(Req.Path, FullPath) then
    Exit;

  A := Req.Arena;
  F := TFileStream.Create(FullPath, fmOpenRead or fmShareDenyNone);
  try
    Size := F.Size;
    { Fila leses inn i request-arenaen, så en stor fil blir en stor arena som
      workeren beholder. Over grensen er det en jobb for en reverse proxy
      eller en sendfile-vei, ikke for denne. }
    if Size > MaxStaticFileBytes then
      Exit;
    Buf := PByte(A.Alloc(PtrUInt(Size) + 1));
    if Size > 0 then
      F.ReadBuffer(Buf^, Size);
  finally
    F.Free;
  end;

  Ext := ExtractFileExt(FullPath);
  Result := Respond(200)
    .WithContentType(ContentTypeForExt(Ext))
    .WithBody(StrRef(Buf, SizeInt(Size)));

  if FMaxAge > 0 then
    Result.WithHeader('Cache-Control',
      Format('public, max-age=%d', [FMaxAge]))
  else
    Result.WithHeader('Cache-Control', 'no-cache');
end;

end.
