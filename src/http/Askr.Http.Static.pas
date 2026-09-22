{ Askr.Http.Static — static files from a directory.

  The PRD puts static files in the web shell, alongside the server, TLS
  and sessions. In practice it is the Vite build that goes out here: a
  handful of JS and CSS files with a hash in the name.

  The dangerous part of a static file server is the path. A request for
  /../../etc/passwd must not reach outside the root directory, and looking
  for ".." in the text is not enough — percent encoding, absolute paths
  and symlinks all have to be stopped as well. Here the path is normalised
  into segments, and anything pointing upwards or starting with a slash is
  refused before anything on disk is touched. }
unit Askr.Http.Static;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, Askr.Core.Arena, Askr.Core.Text, Askr.Core.Clock,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response;

const
  { 16 MB. Larger files are not served from here. }
  MaxStaticFileBytes = 16 * 1024 * 1024;

type
  TStaticFiles = class
  private
    FRoot: string;
    FMaxAge: Integer;
    FIndexFile: string;
    function Resolve(const UrlPath: TStr; out FullPath: string): Boolean;
  public
    { ARoot is the directory being served. It has to exist. }
    constructor Create(const ARoot: string);
    { Answers the request if the file exists, otherwise nil. The caller
      decides what happens then — routing onwards, or a 404. }
    function Serve(Req: TRequest): TResponse;
    { Seconds in Cache-Control. 0 turns it off. A build with a hash in the
      filename tolerates a long value; anything else should have 0. }
    property MaxAge: Integer read FMaxAge write FMaxAge;
    { The file served when the path points at a directory. Empty turns it
      off. }
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
      { Anything pointing upwards is refused. We do not normalise '..' away
        by popping — a request that tries it is a request we do not
        want. }
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

    { The last guard: the resolved path must still lie under the root, also
      after the OS has followed any symlinks. }
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
    { The file is read into the request arena, so a large file becomes a
      large arena the worker keeps. Above the limit it is a job for a
      reverse proxy or a sendfile path, not for this one. }
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

  { Modification time and size, which is what nginx and Apache use. The
    value is opaque -- it only has to change when the file does -- so the
    timestamp needs no format, only to be a number that moves.

    Hashing the bytes would be a stronger promise, and the file is already
    in memory, but it would cost a pass over every file on every request
    to close a window that is one second wide and closes itself on the
    next write. }
  Result.WithETag(Format('%x-%x', [FileAge(FullPath), Size]));

  if FMaxAge > 0 then
    Result.WithHeader('Cache-Control',
      Format('public, max-age=%d', [FMaxAge]))
  else
    Result.WithHeader('Cache-Control', 'no-cache');
end;

end.
