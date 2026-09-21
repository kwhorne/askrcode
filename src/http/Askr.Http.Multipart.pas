{ Askr.Http.Multipart — `multipart/form-data`, that is forms with files.

  The parser copies nothing. The body already sits contiguously in the
  worker's read buffer, and every part becomes a `TStr` slice into that
  same buffer. A five-megabyte upload therefore costs five megabytes once
  — in the buffer that had to read them anyway — and not another copy in
  the arena. It is the same model as the rest of request parsing.

  **The limit is `MaxBodyBytes`** (8 MB by default, set in
  `TServerOptions`). The whole upload has to fit in memory at once. That
  is enough for forms with attachments, profile pictures and CSV imports,
  and it is not enough for video. Uploading something that does not fit in
  memory requires the body to be streamed to disk as it is read, and that
  is a different shape from "the body is one slice" — it would have to
  change in `TWorker`, not here.

  **The filename from the client is not to be trusted.** It is a string an
  attacker writes, and the classic mistake is to join it straight onto a
  directory path: `../../etc/passwd`, or a file called `.bashrc`. So
  `TUploadedFile` has both `SafeName`, which cleans the name, and
  `StoreIn`, which does not use the client's name at all. `SaveAs` writes
  where you say, and then the path is your responsibility. }
unit Askr.Http.Multipart;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, Askr.Core.Arena, Askr.Core.Text;

const
  { Guards against a body that is small but harmful: thousands of tiny
    parts cost parsing and allocation without breaking MaxBodyBytes. }
  MaxMultipartParts = 512;
  MaxPartHeaderBytes = 16 * 1024;

type
  TMultipartError = (
    mpOk,
    mpNoBoundary,       { Content-Type has no boundary= }
    mpMalformed,        { the boundaries are not where they should be }
    mpTooManyParts
  );

  { One file from the form. The content points into the request's read
    buffer and is valid as long as the request is — no longer. To outlive
    it, it has to be stored or copied. }
  TUploadedFile = record
    FieldName: TStr;
    { Exactly what the client sent. Do not use it as a filename. }
    ClientName: TStr;
    { The client's Content-Type. Also a claim from the client, not a
      measurement: an .exe can announce itself as image/png. For the type
      to be trustworthy, the content has to be checked. }
    ContentType: TStr;
    Content: TStr;

    function IsEmpty: Boolean;
    function Size: SizeInt;
    { The client name with directory parts and anything meaningful to a
      file system removed. An empty or impossible name becomes
      'upload'. }
    function SafeName: string;
    { The extension from SafeName, with the dot and lower-cased, or ''. }
    function Extension: string;
    { Writes to exactly this path. The path is the caller's responsibility
      — never build one out of ClientName. }
    function SaveAs(const Path: string): Boolean;
    { Writes into the directory under a random name with the original
      extension, and gives the whole path back. An empty string if it did
      not work. This is the safe route: the client's name never reaches
      the file system. }
    function StoreIn(const Dir: string): string;
  end;

  PUploadedFile = ^TUploadedFile;
  TUploadedFiles = array of TUploadedFile;

  TMultipartField = record
    Name: TStr;
    Value: TStr;
  end;
  PMultipartField = ^TMultipartField;

  { The tables are arena-allocated blocks with a count, not dynamic
    arrays. The reason is measured and has a test of its own: a dynamic
    array is a field that needs finalising, and a `TRequest` with one of
    those pays a `Defer` entry per request — on every single request,
    including those without a single file. The whole point of the arena
    model is that a request should not cost cleanup. }
  TMultipartForm = record
    Fields: PMultipartField;
    FieldCount: Integer;
    Files: PUploadedFile;
    FileCount: Integer;
    Error: TMultipartError;

    function Ok: Boolean;
    function FieldAt(Index: Integer): PMultipartField;
    function FileAt(Index: Integer): PUploadedFile;
    function Value(const AName: string): TStr;
    function Has(const AName: string): Boolean;
    function FileFor(const AName: string): TUploadedFile;
    { The return value is a dynamic array — it is a function value at the
      caller, not a field on the request, and so costs no Defer. }
    function FilesFor(const AName: string): TUploadedFiles;
    function ErrorText: string;
  end;

{ The boundary out of Content-Type. An empty TStr if it is not there.
  The value may be quoted, and then the quotes are not part of it. }
function MultipartBoundary(const ContentType: TStr): TStr;

{ Splits the body. Returns False and sets Error on failure — a broken
  body is a 400 from the caller, not an exception from here. }
function ParseMultipart(A: TArena; const Body, Boundary: TStr;
  out Form: TMultipartForm): Boolean;

{ The name a file gets on disk. Exposed because it is worth being able
  to test and call directly. }
function SanitizeFileName(const S: string): string;

implementation

uses
  Askr.Core.Crypto;

{ ------------------------------------------------------------- filnavn -- }

function SanitizeFileName(const S: string): string;
var
  I: Integer;
  C: Char;
  Base: string;
begin
  { First remove anything resembling a directory path. Both / and \,
    because a Windows client sends \ and a Unix server would otherwise see
    it as a perfectly ordinary character in the name. }
  Base := S;
  for I := Length(Base) downto 1 do
    if (Base[I] = '/') or (Base[I] = '\') or (Base[I] = ':') then
    begin
      Base := Copy(Base, I + 1, MaxInt);
      Break;
    end;

  Result := '';
  for I := 1 to Length(Base) do
  begin
    C := Base[I];
    if ((C >= 'a') and (C <= 'z')) or ((C >= 'A') and (C <= 'Z')) or
       ((C >= '0') and (C <= '9')) or (C = '.') or (C = '-') or (C = '_') then
      Result := Result + C
    else
      { Everything else becomes an underscore, spaces and non-ASCII
        included. A name that survives this far must not be able to mean
        anything to a shell. }
      Result := Result + '_';
  end;

  { Leading dots removed: ".bashrc" and ".." are both names you do not
    want created by accident. }
  while (Result <> '') and (Result[1] = '.') do
    Delete(Result, 1, 1);

  if Length(Result) > 200 then
    Result := Copy(Result, 1, 200);
  if Result = '' then
    Result := 'upload';
end;

{ ------------------------------------------------------- TUploadedFile -- }

function TUploadedFile.IsEmpty: Boolean;
begin
  { Empty means "no file came". A form field where the user chose
    nothing sends a part with an empty filename and zero bytes, and that
    must not look like an upload. }
  Result := (ClientName.Len = 0) and (Content.Len = 0);
end;

function TUploadedFile.Size: SizeInt;
begin
  Result := Content.Len;
end;

function TUploadedFile.SafeName: string;
begin
  Result := SanitizeFileName(ClientName.ToString);
end;

function TUploadedFile.Extension: string;
var
  N: string;
  P: Integer;
begin
  N := SafeName;
  Result := '';
  for P := Length(N) downto 1 do
    if N[P] = '.' then
    begin
      Result := LowerCase(Copy(N, P, MaxInt));
      Break;
    end;
  { An "extension" of twenty characters is not an extension. }
  if Length(Result) > 16 then
    Result := '';
end;

function TUploadedFile.SaveAs(const Path: string): Boolean;
var
  F: TFileStream;
begin
  Result := False;
  try
    F := TFileStream.Create(Path, fmCreate);
    try
      if Content.Len > 0 then
        F.WriteBuffer(Content.Data^, Content.Len);
      Result := True;
    finally
      F.Free;
    end;
  except
    on EStreamError do
      Result := False;
  end;
end;

function TUploadedFile.StoreIn(const Dir: string): string;
var
  Path_: string;
begin
  Result := '';
  if not ForceDirectories(Dir) then
    Exit;
  { A random name, not the client's. Two users uploading "photo.jpg"
    must not overwrite each other, and the client's name must not reach the
    file system at all. The original name is still in ClientName if the app
    wants to store it alongside. }
  Path_ := IncludeTrailingPathDelimiter(Dir) + RandomHex(16) + Extension;
  if not SaveAs(Path_) then
    Exit;
  Result := Path_;
end;

{ -------------------------------------------------------- TMultipartForm -- }

function TMultipartForm.Ok: Boolean;
begin
  Result := Error = mpOk;
end;

function TMultipartForm.FieldAt(Index: Integer): PMultipartField;
begin
  if (Index < 0) or (Index >= FieldCount) then
    Exit(nil);
  Result := Fields;
  Inc(Result, Index);
end;

function TMultipartForm.FileAt(Index: Integer): PUploadedFile;
begin
  if (Index < 0) or (Index >= FileCount) then
    Exit(nil);
  Result := Files;
  Inc(Result, Index);
end;

function TMultipartForm.Value(const AName: string): TStr;
var
  I: Integer;
begin
  for I := 0 to FieldCount - 1 do
    if FieldAt(I)^.Name.EqualsStr(AName) then
      Exit(FieldAt(I)^.Value);
  Result.Data := nil;
  Result.Len := 0;
end;

function TMultipartForm.Has(const AName: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to FieldCount - 1 do
    if FieldAt(I)^.Name.EqualsStr(AName) then
      Exit(True);
  Result := False;
end;

function TMultipartForm.FileFor(const AName: string): TUploadedFile;
var
  I: Integer;
begin
  for I := 0 to FileCount - 1 do
    if FileAt(I)^.FieldName.EqualsStr(AName) then
      Exit(FileAt(I)^);
  FillChar(Result, SizeOf(Result), 0);
end;

function TMultipartForm.FilesFor(const AName: string): TUploadedFiles;
var
  I, N: Integer;
begin
  Result := nil;
  N := 0;
  for I := 0 to FileCount - 1 do
    if FileAt(I)^.FieldName.EqualsStr(AName) then
    begin
      SetLength(Result, N + 1);
      Result[N] := FileAt(I)^;
      Inc(N);
    end;
end;

function TMultipartForm.ErrorText: string;
begin
  case Error of
    mpOk: Result := '';
    mpNoBoundary: Result := 'The multipart Content-Type has no boundary.';
    mpMalformed: Result := 'The multipart body is malformed.';
    mpTooManyParts: Result := 'The multipart body has too many parts.';
  end;
end;

{ ------------------------------------------------------------ parsing -- }

function MultipartBoundary(const ContentType: TStr): TStr;
var
  P: SizeInt;
  Rest: TStr;
begin
  Result.Data := nil;
  Result.Len := 0;
  P := ContentType.IndexOfStr('boundary=');
  if P < 0 then
    Exit;
  Rest := ContentType.Slice(P + Length('boundary='));
  { The value may be quoted. RFC 2046 allows characters in a boundary
    that otherwise have to be quoted, and a client that does so must not
    produce a boundary starting with a quote. }
  if (Rest.Len > 0) and (Rest.Data^ = Ord('"')) then
  begin
    Rest := Rest.Slice(1);
    P := Rest.IndexOfByte(Ord('"'));
    if P < 0 then
      Exit;
    Result := Rest.Slice(0, P);
    Exit;
  end;
  { Otherwise it ends at a semicolon or at the end. }
  P := Rest.IndexOfByte(Ord(';'));
  if P >= 0 then
    Rest := Rest.Slice(0, P);
  Result := Rest.TrimSpace;
end;

{ Pulls a named parameter out of a Content-Disposition line:
  `form-data; name="file"; filename="photo.jpg"`. The value may be quoted
  or bare. }
function DispositionParam(const Line: TStr; const Key: string): TStr;
var
  P: SizeInt;
  Rest: TStr;
begin
  Result.Data := nil;
  Result.Len := 0;
  P := Line.IndexOfStr(Key + '=');
  if P < 0 then
    Exit;
  Rest := Line.Slice(P + Length(Key) + 1);
  if (Rest.Len > 0) and (Rest.Data^ = Ord('"')) then
  begin
    Rest := Rest.Slice(1);
    P := Rest.IndexOfByte(Ord('"'));
    if P < 0 then
      Exit;
    Result := Rest.Slice(0, P);
    Exit;
  end;
  P := Rest.IndexOfByte(Ord(';'));
  if P >= 0 then
    Rest := Rest.Slice(0, P);
  Result := Rest.TrimSpace;
end;

{ Én navngitt header ut av delens headerblokk. }
function PartHeader(const Block: TStr; const Name_: string): TStr;
var
  Rest, Line, K, V: TStr;
  P: SizeInt;
begin
  Result.Data := nil;
  Result.Len := 0;
  Rest := Block;
  while Rest.Len > 0 do
  begin
    P := Rest.IndexOfStr(#13#10);
    if P < 0 then
    begin
      Line := Rest;
      Rest.Len := 0;
    end
    else
    begin
      Line := Rest.Slice(0, P);
      Rest := Rest.Slice(P + 2);
    end;
    if Line.SplitAt(Ord(':'), K, V) and K.TrimSpace.SameTextStr(Name_) then
      Exit(V.TrimSpace);
  end;
end;

function ParseMultipart(A: TArena; const Body, Boundary: TStr;
  out Form: TMultipartForm): Boolean;
var
  Sep_: TStrBuilder;
  Delim, Start: TStr;
  P, HeaderEnd, Next_: SizeInt;
  Header_, Content_, Disp, Name_, FileName_: TStr;
  FieldsSeen, FilesSeen, PartsSeen: Integer;
  FieldCap, FileCap: Integer;
  NewField: PMultipartField;
  NewFile: PUploadedFile;
begin
  Form.Fields := nil;
  Form.FieldCount := 0;
  Form.Files := nil;
  Form.FileCount := 0;
  Form.Error := mpOk;
  FieldsSeen := 0;
  FilesSeen := 0;
  PartsSeen := 0;
  FieldCap := 0;
  FileCap := 0;

  if Boundary.Len = 0 then
  begin
    Form.Error := mpNoBoundary;
    Exit(False);
  end;

  { The delimiter is CRLF + "--" + the boundary. The CRLF in front
    belongs to the delimiter, not to the content — forget that and every
    single file gets two extra bytes at the end, which is noticed first
    when somebody cannot open a zip file. }
  Sep_.Init(A, Boundary.Len + 8);
  Sep_.Append(#13#10'--');
  Sep_.Append(Boundary);
  Delim := Sep_.ToStr;
  { The very first boundary has no CRLF in front of it when there is no
    preamble. }
  Start := Delim.Slice(2);

  if (Body.Len >= Start.Len) and
     (CompareByte(Body.Data^, Start.Data^, Start.Len) = 0) then
    P := Start.Len
  else
  begin
    { With a preamble: look for the first real boundary. }
    P := Body.IndexOfStr(Delim);
    if P < 0 then
    begin
      Form.Error := mpMalformed;
      Exit(False);
    end;
    Inc(P, Delim.Len);
  end;

  while True do
  begin
    { After the boundary: either "--" and the end, or CRLF and another
      part. }
    if P + 2 > Body.Len then
    begin
      Form.Error := mpMalformed;
      Exit(False);
    end;
    if ((Body.Data + P)^ = Ord('-')) and ((Body.Data + P + 1)^ = Ord('-')) then
      Break;
    if ((Body.Data + P)^ <> 13) or ((Body.Data + P + 1)^ <> 10) then
    begin
      { Some clients add whitespace after the boundary. Skip past it rather
        than refuse a body that is otherwise fine. }
      while (P < Body.Len) and
            (((Body.Data + P)^ = 32) or ((Body.Data + P)^ = 9)) do
        Inc(P);
      if (P + 2 > Body.Len) or ((Body.Data + P)^ <> 13) or
         ((Body.Data + P + 1)^ <> 10) then
      begin
        Form.Error := mpMalformed;
        Exit(False);
      end;
    end;
    Inc(P, 2);

    Inc(PartsSeen);
    if PartsSeen > MaxMultipartParts then
    begin
      Form.Error := mpTooManyParts;
      Exit(False);
    end;

    HeaderEnd := Body.IndexOfStr(#13#10#13#10, P);
    if (HeaderEnd < 0) or (HeaderEnd - P > MaxPartHeaderBytes) then
    begin
      Form.Error := mpMalformed;
      Exit(False);
    end;
    Header_ := Body.Slice(P, HeaderEnd - P);
    P := HeaderEnd + 4;

    Next_ := Body.IndexOfStr(Delim, P);
    if Next_ < 0 then
    begin
      { Without a closing boundary the body is truncated. Taking the rest
        anyway would give half a file that looks whole. }
      Form.Error := mpMalformed;
      Exit(False);
    end;
    Content_ := Body.Slice(P, Next_ - P);
    P := Next_ + Delim.Len;

    Disp := PartHeader(Header_, 'Content-Disposition');
    Name_ := DispositionParam(Disp, 'name');
    if Name_.Len = 0 then
      { A part without a name does not belong to the form. It is skipped
        rather than bringing the whole body down. }
      Continue;

    { `filename` is what separates a file from an ordinary field — also
      when it is empty, which is how a form with an empty file field
      sends it. }
    FileName_ := DispositionParam(Disp, 'filename');
    if Disp.IndexOfStr('filename=') >= 0 then
    begin
      { Doubling in the arena. The previous block stays until Reset — the
        same trade-off TStrBuilder makes, and it costs nothing in an
        arena. A form usually has one file, so that is zero growths. }
      if FilesSeen >= FileCap then
      begin
        if FileCap = 0 then
          FileCap := 4
        else
          FileCap := FileCap * 2;
        NewFile := PUploadedFile(A.Alloc(PtrUInt(FileCap) * SizeOf(TUploadedFile)));
        if FilesSeen > 0 then
          Move(Form.Files^, NewFile^, PtrUInt(FilesSeen) * SizeOf(TUploadedFile));
        Form.Files := NewFile;
      end;
      NewFile := Form.Files;
      Inc(NewFile, FilesSeen);
      NewFile^.FieldName := Name_;
      NewFile^.ClientName := FileName_;
      NewFile^.ContentType := PartHeader(Header_, 'Content-Type');
      NewFile^.Content := Content_;
      Inc(FilesSeen);
      Form.FileCount := FilesSeen;
    end
    else
    begin
      if FieldsSeen >= FieldCap then
      begin
        if FieldCap = 0 then
          FieldCap := 8
        else
          FieldCap := FieldCap * 2;
        NewField := PMultipartField(
          A.Alloc(PtrUInt(FieldCap) * SizeOf(TMultipartField)));
        if FieldsSeen > 0 then
          Move(Form.Fields^, NewField^, PtrUInt(FieldsSeen) * SizeOf(TMultipartField));
        Form.Fields := NewField;
      end;
      NewField := Form.Fields;
      Inc(NewField, FieldsSeen);
      NewField^.Name := Name_;
      NewField^.Value := Content_;
      Inc(FieldsSeen);
      Form.FieldCount := FieldsSeen;
    end;
  end;

  Result := True;
end;

end.
