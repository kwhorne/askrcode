{ Test suite for Askr phase 1, step 1: the arena and the HTTP host.

  Run with `./askr test`, or directly. Exit code 1 on failure, so CI can
  use it as is. The test framework from the PRD (Askr.Testing) arrives in
  phase 2; this is deliberately only enough to keep step 1 honest. }
program AskrTests;

{$mode Delphi}{$H+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  SysUtils, StrUtils, Classes, Sockets, BaseUnix,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Clock,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response, Askr.Http.Server, Askr.Http.Stream, Askr.Http.WebSocket,
  Askr.Http.Multipart, Askr.Http.Static, Askr.Core.Log,
  Askr.Core.Json, Askr.Http.Router, Askr.Urd.Driver, Askr.Urd.Model,
  Askr.Urd.Bind, Askr.Norn.Schema, Askr.Norn.Introspect, Askr.Norn.Codegen,
  Askr.Inertia, Askr.Urd.Query, Askr.Urd.Sqlite, Askr.Urd.Grid,
  Askr.Cache, Askr.Queue, Askr.Core.Config, Askr.Core.Url, Askr.Urd.Json,
  Askr.Http.Robots, Askr.Http.Sitemap, Askr.Console.Commands;

var
  Passed: Integer = 0;
  Failed: Integer = 0;
  CurrentGroup: string = '';

procedure Si2(const Etikett, Value_: string);
begin
  WriteLn('    ', Etikett, ': ', Value_);
end;

procedure Group(const Name: string);
begin
  CurrentGroup := Name;
  WriteLn;
  WriteLn('  ', Name);
end;

procedure Check(Cond: Boolean; const Name: string);
begin
  if Cond then
  begin
    Inc(Passed);
    WriteLn('    ok   ', Name);
  end
  else
  begin
    Inc(Failed);
    WriteLn('    FEIL ', Name);
  end;
end;

procedure CheckEqS(const Actual, Expected, Name: string);
begin
  if Actual = Expected then
  begin
    Inc(Passed);
    WriteLn('    ok   ', Name);
  end
  else
  begin
    Inc(Failed);
    WriteLn('    FEIL ', Name);
    WriteLn('         expected: ', Expected);
    WriteLn('         got:      ', Actual);
  end;
end;

procedure CheckEqI(Actual, Expected: Int64; const Name: string);
begin
  if Actual = Expected then
  begin
    Inc(Passed);
    WriteLn('    ok   ', Name);
  end
  else
  begin
    Inc(Failed);
    WriteLn('    FEIL ', Name, ' — expected ', Expected, ', got ', Actual);
  end;
end;

{ ---------------------------------------------------------------- arena -- }

type
  TThing = class(TArenaObject)
  public
    Value: Integer;
    Name: string[16];
    constructor Create(AValue: Integer);
  end;

constructor TThing.Create(AValue: Integer);
begin
  inherited Create;
  Value := AValue;
  Name := 'thing';
end;

procedure TestArena;
var
  A: TArena;
  P1, P2, P3: Pointer;
  M: TArenaMark;
  Reserved1, Reserved2: PtrUInt;
  Resets: QWord;
  T: TThing;
  Prev: TArena;
  I: Integer;
begin
  Group('Arena');

  A := TArena.Create(4096);
  try
    P1 := A.Alloc(10);
    P2 := A.Alloc(10);
    Check(P1 <> nil, 'Alloc gives memory');
    CheckEqI(PtrUInt(P2) - PtrUInt(P1), ArenaAlignment,
      'allocations are aligned to ' + IntToStr(ArenaAlignment));
    CheckEqI(A.BytesLive, 2 * ArenaAlignment, 'BytesLive counts handed-out memory');

    A.Reset;
    CheckEqI(A.BytesLive, 0, 'Reset clears BytesLive');
    P3 := A.Alloc(10);
    Check(P3 = P1, 'Reset reuses the same addresses');
    CheckEqI(A.ResetCount, 1, 'ResetCount counts requests');

    { The core claim in the PRD: the arena stops asking the OS for more
      memory. }
    for I := 1 to 50 do
    begin
      A.Reset;
      A.Alloc(3000);
      A.Alloc(500);
    end;
    Reserved1 := A.BytesReserved;
    for I := 1 to 500 do
    begin
      A.Reset;
      A.Alloc(3000);
      A.Alloc(500);
    end;
    Reserved2 := A.BytesReserved;
    CheckEqI(Reserved2, Reserved1, 'BytesReserved levels off after warm-up');

    A.Reset;
    P1 := A.Alloc(1024 * 1024);
    Check(P1 <> nil, 'a large allocation gets its own block');
    A.Trim;
    CheckEqI(A.BlockCount, 1, 'Trim releases everything but the first block');

    A.Reset;
    Resets := A.ResetCount;
    M := A.Mark;
    A.Alloc(64);
    A.Rewind(M);
    CheckEqI(A.BytesLive, M.Live, 'Rewind rewinds to the mark');
    CheckEqI(A.ResetCount, Resets, 'Rewind does not count as a request boundary');

    { Objects in the arena: the constructor runs, the destructor never
      does. }
    A.Reset;
    Prev := UseArena(A);
    try
      T := TThing.Create(42);
      CheckEqI(T.Value, 42, 'the constructor runs on an arena object');
      Check(T.IsArenaAllocated, 'the object knows it is in the arena');
      Check(A.BytesLive >= T.InstanceSize, 'the object was allocated in the arena');
      T.Free;   { this is a no-op }
      CheckEqI(T.Value, 42, 'Free on an arena object does not touch the memory');
    finally
      UseArena(Prev);
    end;

    { Without a surrounding arena the class is to behave like an ordinary
      TObject. }
    T := TThing.Create(7);
    Check(not T.IsArenaAllocated, 'without an arena TArenaObject falls to the heap');
    T.Free;
  finally
    A.Free;
  end;
end;

{ ------------------------------------------------------------ arena New<T> -- }

type
  TAnimal = class(TArenaObject)
  private
    FSound: string;
  public
    Bein: Integer;
    constructor Create;
    function Sound: string; virtual;
    function Klassenavn: string;
  end;

  TCat = class(TAnimal)
  public
    constructor Create;
    function Sound: string; override;
  end;

constructor TAnimal.Create;
begin
  inherited Create;
  Bein := 4;
  FSound := 'undefined';
end;

function TAnimal.Sound: string;
begin
  Result := FSound;
end;

function TAnimal.Klassenavn: string;
begin
  Result := ClassName;
end;

constructor TCat.Create;
begin
  inherited Create;
  FSound := 'meow';
end;

function TCat.Sound: string;
begin
  Result := 'Cat says ' + FSound;
end;

procedure TestArenaNew;
var
  A, B: TArena;
  Prev: TArena;
  K: TCat;
  D: TAnimal;
  Adresse1, Adresse2: Pointer;
  Reservert: PtrUInt;
  I, J: Integer;
  Previous: Pointer;
  AllUnique: Boolean;
begin
  Group('Arena — New<T>');

  A := TArena.Create(64 * 1024);
  B := TArena.Create(4096);
  try
    K := A.New<TCat>;
    Check(K <> nil, 'New<T> gives an object');
    Check(A.Owns(Pointer(K)), 'the object is in the arena''s own memory');
    Check(not B.Owns(Pointer(K)), 'and not in another arena');
    Check(K.IsArenaAllocated, 'the object knows it is arena-allocated');
    Check(K.Arena = A, 'it points at the right arena');

    { The constructor has to have run — both its own and the inherited
      one. }
    CheckEqI(K.Bein, 4, 'the inherited constructor ran');
    CheckEqS(K.Sound, 'Cat says meow', 'its own constructor ran');

    { The VMT has to be set correctly, or the object is only bytes. }
    CheckEqS(K.Klassenavn, 'TCat', 'ClassName works (the VMT is in place)');
    Check(K is TAnimal, 'the is operator works');
    Check(K.InheritsFrom(TAnimal), 'the inheritance chain is intact');

    { A virtual call through the base type has to reach the override. }
    D := K;
    CheckEqS(D.Sound, 'Cat says meow', 'virtual dispatch through the base type');

    { New<T> is to hit its own arena even when another one surrounds
      it. }
    Prev := UseArena(B);
    try
      K := A.New<TCat>;
      Check(A.Owns(Pointer(K)), 'New<T> ignores the surrounding arena');
      Check(not B.Owns(Pointer(K)), 'and does not pollute the surrounding one');
      CheckEqS(K.Sound, 'Cat says meow', 'the object works anyway');
    finally
      UseArena(Prev);
    end;
    CheckEqI(B.BytesLive, 0, 'the surrounding arena was not touched');

    { Reset is to reuse the same memory. }
    A.Reset;
    K := A.New<TCat>;
    Adresse1 := Pointer(K);
    A.Reset;
    K := A.New<TCat>;
    Adresse2 := Pointer(K);
    Check(Adresse1 = Adresse2, 'Reset reuses the same address');
    CheckEqS(K.Sound, 'Cat says meow', 'the object is fully usable after Reset');

    { The string field in the object has to be released by Reset, not
      leak. }
    K.FSound := 'a sound long enough to live on the heap and not in the data segment';
    A.Reset;
    CheckEqI(Length(K.FSound), 0, 'the string field was finalized by Reset');

    { Many objects: none is to overlap, and the arena is to level off. }
    A.Reset;
    Previous := nil;
    AllUnique := True;
    for I := 1 to 10000 do
    begin
      K := A.New<TCat>;
      if Pointer(K) = Previous then
        AllUnique := False;
      Previous := Pointer(K);
      if K.Bein <> 4 then
        AllUnique := False;
    end;
    Check(AllUnique, '10,000 objects each got their own address and the right content');
    Reservert := A.BytesReserved;
    for I := 1 to 10 do
    begin
      A.Reset;
      for J := 1 to 10000 do
        A.New<TCat>;
    end;
    CheckEqI(A.BytesReserved, Reservert,
      'the arena did not grow over ten rounds of 10,000 objects');
  finally
    A.Free;
    B.Free;
  end;
end;

{ --------------------------------------------------- arena og string-felt -- }

type
  { Has_ en refcountet string — RTTI-tabellen er ikke tom. }
  TWithString = class(TArenaObject)
  public
    Name: string;
    Number: Integer;
  end;

  { Only ShortString and numbers — nothing to finalize. }
  TWithoutString = class(TArenaObject)
  public
    Kort: string[16];
    Number: Integer;
  end;

procedure TestArenaFinalisering;
var
  A: TArena;
  Prev: TArena;
  M: TWithString;
  U: TWithoutString;
  Used: PtrUInt;
begin
  Group('Arena — finalizing a string field');

  Check(ClassNeedsFinalization(TWithString),
    'a class with a string needs finalization');
  { TCat declares no managed fields of its own but inherits one from
    TAnimal. Its own init table is empty, so the check has to walk up the
    inheritance chain. }
  Check(ClassNeedsFinalization(TCat),
    'a subclass inheriting a string field needs it too');
  Check(not ClassNeedsFinalization(TWithoutString),
    'a class with only ShortString does not');
  Check(not ClassNeedsFinalization(TRequest),
    'TRequest pays nothing for the mechanism');
  Check(not ClassNeedsFinalization(TResponse),
    'nor does TResponse');

  A := TArena.Create(8192);
  Prev := UseArena(A);
  try
    U := TWithoutString.Create;
    U.Number := 1;
    Used := A.BytesLive;
    Check(Used <= U.InstanceSize + ArenaAlignment,
      'an object with no managed fields costs no defer node');

    M := TWithString.Create;
    { Plain ASCII, so that Length counts the same as the number of
      characters. }
    M.Name := 'a string long enough to land on the heap and not in the data segment';
    CheckEqI(Length(M.Name), 68, 'the string was set');

    A.Reset;
    { After Reset the memory is reusable. That the string was actually
      released is shown by the refcount falling — we do not read it
      directly, but the finalization clears the field. }
    CheckEqI(Length(M.Name), 0, 'Reset finalized the string field');
  finally
    UseArena(Prev);
    A.Free;
  end;
end;

{ ------------------------------------------------------------ arena defer -- }

var
  DeferSpor: string = '';

procedure SporA(Data: Pointer); begin DeferSpor := DeferSpor + 'a'; end;
procedure SporB(Data: Pointer); begin DeferSpor := DeferSpor + 'b'; end;
procedure SporC(Data: Pointer); begin DeferSpor := DeferSpor + 'c'; end;

procedure SporKaster(Data: Pointer);
begin
  DeferSpor := DeferSpor + 'x';
  raise Exception.Create('a cleanup that fails');
end;

procedure TestArenaDefer;
var
  A: TArena;
  M: TArenaMark;
begin
  Group('Arena — defer');

  A := TArena.Create(4096);
  try
    DeferSpor := '';
    A.Defer(SporA, nil);
    A.Defer(SporB, nil);
    CheckEqS(DeferSpor, '', 'nothing runs before Reset');
    A.Reset;
    CheckEqS(DeferSpor, 'ba', 'cleanup runs in reverse order');

    DeferSpor := '';
    A.Reset;
    CheckEqS(DeferSpor, '', 'a cleanup runs only once');

    { Rewind cleans up only what was registered after the mark. }
    DeferSpor := '';
    A.Defer(SporA, nil);
    M := A.Mark;
    A.Defer(SporB, nil);
    A.Defer(SporC, nil);
    A.Rewind(M);
    CheckEqS(DeferSpor, 'cb', 'Rewind cleans down to the mark');
    A.Reset;
    CheckEqS(DeferSpor, 'cba', 'the rest waits for Reset');

    { A cleanup that raises must not stop the others. }
    DeferSpor := '';
    A.Defer(SporA, nil);
    A.Defer(SporKaster, nil);
    A.Defer(SporB, nil);
    A.Reset;
    CheckEqS(DeferSpor, 'bxa', 'a cleanup that raises does not stop Reset');
    CheckEqI(A.BytesLive, 0, 'the arena was reset anyway');
  finally
    A.Free;
  end;

  { Destroy has to clean up what is left — the nodes are in the arena
    themselves. }
  DeferSpor := '';
  A := TArena.Create(4096);
  A.Defer(SporA, nil);
  A.Defer(SporB, nil);
  A.Free;
  CheckEqS(DeferSpor, 'ba', 'Destroy cleans up what is left');
end;

{ ----------------------------------------------------------------- tekst -- }

procedure TestText;
var
  A: TArena;
  S, L, R: TStr;
  B: TStrBuilder;
  V: Int64;
  I: Integer;
begin
  Group('Text_');
  A := TArena.Create(4096);
  try
    S := Str('Hello, world');
    CheckEqI(S.Len, 12, 'Str takes the length from the string');
    CheckEqS(S.ToString, 'Hello, world', 'ToString copies back out');
    Check(S.EqualsStr('Hello, world'), 'EqualsStr is exact');
    Check(not S.EqualsStr('hello, world'), 'EqualsStr distinguishes upper and lower case');
    Check(S.SameTextStr('HELLO, WORLD'), 'SameText ignores ASCII case');
    Check(S.StartsWithStr('Hello'), 'StartsWithStr');
    CheckEqI(S.IndexOfByte(Ord(',')), 5, 'IndexOfByte');
    CheckEqS(S.Slice(7).ToString, 'world', 'Slice til enden');
    CheckEqS(S.Slice(0, 5).ToString, 'Hello', 'Slice with a length');
    CheckEqS(Str('  text  ').TrimSpace.ToString, 'text', 'TrimSpace');

    Check(S.SplitAt(Ord(','), L, R), 'SplitAt finds the separator');
    CheckEqS(L.ToString, 'Hello', 'SplitAt left');
    CheckEqS(R.TrimSpace.ToString, 'world', 'SplitAt right');
    Check(not Str('uten').SplitAt(Ord(','), L, R), 'SplitAt with no match');
    CheckEqS(L.ToString, 'uten', 'SplitAt with no match gives the whole string');

    Check(Str('12345').ToInt64(V) and (V = 12345), 'ToInt64 positive');
    Check(Str('-42').ToInt64(V) and (V = -42), 'ToInt64 negative');
    Check(not Str('12a').ToInt64(V), 'ToInt64 rejects rubbish');
    Check(not Str('').ToInt64(V), 'ToInt64 rejects an empty string');
    Check(not Str('99999999999999999999').ToInt64(V),
      'ToInt64 rejects overflow instead of wrapping');
    CheckEqI(Str('nei').ToIntDef(7), 7, 'ToIntDef');

    B.Init(A, 16);
    B.Append('a');
    B.AppendInt(0);
    B.AppendInt(-1);
    B.AppendInt(Low(Int64));
    CheckEqS(B.ToString, 'a0-1-9223372036854775808',
      'AppendInt handles Low(Int64)');

    { Vekst skal bevare innholdet. }
    B.Init(A, 16);
    for I := 1 to 100 do
      B.Append('0123456789');
    CheckEqI(B.Len, 1000, 'StrBuilder grows');
    Check(B.Capacity >= 1000, 'the capacity followed');
    CheckEqS(B.ToStr.Slice(990).ToString, '0123456789', 'the content survived the growth');

    CheckEqS(StrDup(A, Str('kopi')).ToString, 'kopi', 'StrDup');
    CheckEqS(StrCat(A, Str('ab'), Str('cd')).ToString, 'abcd', 'StrCat');
  finally
    A.Free;
  end;
end;

{ ------------------------------------------------------------ http-typer -- }

procedure TestHttpTypes;
var
  A: TArena;
  V: TStr;
begin
  Group('HTTP types');
  A := TArena.Create(4096);
  try
    Check(MethodFromStr(Str('GET')) = hmGet, 'GET');
    Check(MethodFromStr(Str('DELETE')) = hmDelete, 'DELETE');
    Check(MethodFromStr(Str('get')) = hmUnknown, 'metoder er case-sensitive');
    Check(MethodFromStr(Str('BREW')) = hmUnknown, 'an unknown method');
    CheckEqS(StatusText(422), 'Unprocessable Content', 'StatusText');

    CheckEqS(UrlDecode(A, Str('a%20b')).ToString, 'a b', 'percent decoding');
    CheckEqS(UrlDecode(A, Str('a+b')).ToString, 'a+b', 'plus is not a space in a path');
    CheckEqS(UrlDecode(A, Str('a+b'), True).ToString, 'a b', 'plus is a space in a query');
    CheckEqS(UrlDecode(A, Str('%C3%A6')).ToString, 'æ', 'utf-8 through decoding');
    CheckEqS(UrlDecode(A, Str('100%')).ToString, '100%', 'an incomplete % sequence is kept');
    CheckEqS(UrlDecode(A, Str('%zz')).ToString, '%zz', 'invalid hex is kept');

    Check(QueryValue(A, Str('a=1&name=Knut&b=2'), 'name', V) and V.EqualsStr('Knut'),
      'QueryValue finds a value');
    Check(QueryValue(A, Str('tom=&x=1'), 'tom', V) and V.IsEmpty,
      'QueryValue with an empty value');
    Check(not QueryValue(A, Str('a=1'), 'b', V), 'QueryValue with no match');
    Check(QueryValue(A, Str('q=a%20b'), 'q', V) and V.EqualsStr('a b'),
      'QueryValue decodes');
  finally
    A.Free;
  end;
end;

{ ----------------------------------------------------------- requestparse -- }

function ParseIn(A: TArena; const Head: string; out Req: TRequest): TParseState;
var
  Prev: TArena;
begin
  Prev := UseArena(A);
  try
    Req := TRequest.Create;
    Result := Req.ParseHead(StrDup(A, Head), DefaultMaxBodyBytes);
  finally
    UseArena(Prev);
  end;
end;

{ ------------------------------------------------------------- multipart -- }

{ Builds a multipart body. Written out by hand with explicit CRLFs,
  because it is precisely the CRLFs around the boundaries that the test is
  about. }
{ FileUtil belongs to Lazarus, not to FPC's RTL. The cleanup is therefore
  written out by hand. }
procedure RemoveDir_(const Dir: string);
var
  R: TSearchRec;
begin
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, R) = 0 then
  begin
    repeat
      if (R.Name <> '.') and (R.Name <> '..') then
        DeleteFile(IncludeTrailingPathDelimiter(Dir) + R.Name);
    until FindNext(R) <> 0;
    FindClose(R);
  end;
  RemoveDir(Dir);
end;

function MpPart(const Boundary, Disp, Type_, Content_: string): string;
begin
  Result := '--' + Boundary + #13#10 + 'Content-Disposition: ' + Disp + #13#10;
  if Type_ <> '' then
    Result := Result + 'Content-Type: ' + Type_ + #13#10;
  Result := Result + #13#10 + Content_ + #13#10;
end;

function ParseWithBody(A: TArena; const Head, Body_: string;
  out Req: TRequest): TParseState;
var
  Prev: TArena;
begin
  Prev := UseArena(A);
  try
    Req := TRequest.Create;
    Result := Req.ParseHead(StrDup(A, Head + #13#10'Content-Length: ' +
      IntToStr(Length(Body_))), DefaultMaxBodyBytes);
    if Result = psOk then
      Req.SetBody(StrDup(A, Body_));
  finally
    UseArena(Prev);
  end;
end;

procedure TestMultipart;
const
  G = '----AskrBoundary7MA4YWxkTrZu0gW';
var
  A: TArena;
  Req: TRequest;
  St: TParseState;
  Body_, Path_, Folder: string;
  F: TUploadedFile;
  More: TUploadedFiles;
  Form: TMultipartForm;
  Bin: string;
  I: Integer;
  L: TStringList;
begin
  Group('Multipart');
  A := TArena.Create(64 * 1024);
  try
    Body_ :=
      MpPart(G, 'form-data; name="title"', '', 'Årsrapport') +
      MpPart(G, 'form-data; name="_token"', '', 'abc123') +
      MpPart(G, 'form-data; name="doc"; filename="report.pdf"',
        'application/pdf', '%PDF-1.4 content') +
      '--' + G + '--' + #13#10;

    St := ParseWithBody(A, 'POST /upload HTTP/1.1'#13#10'Host: x'#13#10 +
      'Content-Type: multipart/form-data; boundary=' + G, Body_, Req);
    Check(St = psOk, 'the request parses');
    Check(Req.IsMultipart, 'recognised as multipart');
    Check(Req.Multipart.Ok, 'kroppen lot seg dele');

    { Ordinary fields are to keep working. A form with a file in it must
      not make the rest of the fields unreachable — and the CSRF token is
      in one of them. }
    CheckEqS(Req.Form('title').ToString, 'Årsrapport',
      'a text field is read with Form');
    CheckEqS(Req.Form('_token').ToString, 'abc123',
      'the CSRF token is there in a multipart');
    Check(Req.HasForm('title'), 'HasForm finds the field');
    Check(not Req.HasForm('does-not-exist'), 'and not one that is missing');

    F := Req.Upload('doc');
    Check(not F.IsEmpty, 'the file came along');
    CheckEqS(F.ClientName.ToString, 'report.pdf', 'the file name from the client');
    CheckEqS(F.ContentType.ToString, 'application/pdf', 'content-type');
    CheckEqS(F.Content.ToString, '%PDF-1.4 content', 'the content is intact');
    CheckEqI(F.Size, Length('%PDF-1.4 content'), 'the size is right');

    { The content is to be a slice into the body, not a copy. That is the
      whole reason the parser is written the way it is. }
    Check((PtrUInt(F.Content.Data) >= PtrUInt(Req.Body.Data)) and
          (PtrUInt(F.Content.Data) < PtrUInt(Req.Body.Data) + Req.Body.Len),
      'the content points into the body, with no copy');

    Check(Req.Upload('does-not-exist').IsEmpty, 'a field that does not exist is empty');

    { ---- boundaries that are easy to get wrong ---- }
    A.Reset;
    { Binary content with CRLFs and with something that looks like the
      boundary inside it. Cut in the wrong place and the file is corrupt
      with nothing to say so. }
    Bin := 'AB'#13#10'--not-the-boundary'#13#10#0#1#2#255'CD';
    Body_ := MpPart(G, 'form-data; name="f"; filename="a.bin"',
      'application/octet-stream', Bin) + '--' + G + '--' + #13#10;
    St := ParseWithBody(A, 'POST /u HTTP/1.1'#13#10'Host: x'#13#10 +
      'Content-Type: multipart/form-data; boundary=' + G, Body_, Req);
    Check(St = psOk, 'a binary body parses');
    F := Req.Upload('f');
    CheckEqI(F.Size, Length(Bin), 'binary content keeps every byte');
    Check(CompareByte(F.Content.Data^, Bin[1], Length(Bin)) = 0,
      'a zero byte too, and something that looks like the boundary');

    A.Reset;
    { The boundary in quotes, as some clients send it. }
    Body_ := MpPart(G, 'form-data; name="a"', '', 'x') + '--' + G + '--'#13#10;
    St := ParseWithBody(A, 'POST /u HTTP/1.1'#13#10'Host: x'#13#10 +
      'Content-Type: multipart/form-data; boundary="' + G + '"', Body_, Req);
    CheckEqS(Req.Form('a').ToString, 'x', 'a boundary in quotes');

    A.Reset;
    { More filer under samme navn: <input type="file" multiple>. }
    Body_ :=
      MpPart(G, 'form-data; name="images"; filename="one.png"', 'image/png', '1') +
      MpPart(G, 'form-data; name="images"; filename="two.png"', 'image/png', '22') +
      MpPart(G, 'form-data; name="other"; filename="three.txt"', 'text/plain', '333') +
      '--' + G + '--'#13#10;
    ParseWithBody(A, 'POST /u HTTP/1.1'#13#10'Host: x'#13#10 +
      'Content-Type: multipart/form-data; boundary=' + G, Body_, Req);
    More := Req.Uploads('images');
    CheckEqI(Length(More), 2, 'two files under the same name');
    CheckEqS(More[1].ClientName.ToString, 'two.png', 'the order holds');
    CheckEqI(Length(Req.Uploads('other')), 1, 'and one under another');

    A.Reset;
    { A file field the user did not fill in: an empty file name, zero
      bytes. It must not look like an upload. }
    Body_ := MpPart(G, 'form-data; name="optional"; filename=""', '', '') +
      '--' + G + '--'#13#10;
    ParseWithBody(A, 'POST /u HTTP/1.1'#13#10'Host: x'#13#10 +
      'Content-Type: multipart/form-data; boundary=' + G, Body_, Req);
    Check(Req.Upload('optional').IsEmpty, 'an empty file field is not a file');

    A.Reset;
    { Broken bodies are to give Ok = False, not an exception and not half a
      file. }
    Body_ := MpPart(G, 'form-data; name="a"', '', 'x');  { uten avsluttende grense }
    ParseWithBody(A, 'POST /u HTTP/1.1'#13#10'Host: x'#13#10 +
      'Content-Type: multipart/form-data; boundary=' + G, Body_, Req);
    Check(not Req.Multipart.Ok, 'a body with no closing boundary is rejected');

    A.Reset;
    Body_ := 'nothing that resembles it';
    ParseWithBody(A, 'POST /u HTTP/1.1'#13#10'Host: x'#13#10 +
      'Content-Type: multipart/form-data; boundary=' + G, Body_, Req);
    Check(not Req.Multipart.Ok, 'rubbish is rejected');

    A.Reset;
    ParseWithBody(A, 'POST /u HTTP/1.1'#13#10'Host: x'#13#10 +
      'Content-Type: multipart/form-data', '', Req);
    Check(not Req.Multipart.Ok, 'multipart without a boundary is rejected');
    Check(Req.Multipart.Error = mpNoBoundary, 'and says why');

    A.Reset;
    { Too many parts. The limit is against a body that is small but costs
      in parsing and allocation. }
    Body_ := '';
    for I := 1 to MaxMultipartParts + 5 do
      Body_ := Body_ + MpPart(G, 'form-data; name="f' + IntToStr(I) + '"',
        '', 'x');
    Body_ := Body_ + '--' + G + '--'#13#10;
    ParseWithBody(A, 'POST /u HTTP/1.1'#13#10'Host: x'#13#10 +
      'Content-Type: multipart/form-data; boundary=' + G, Body_, Req);
    Check(Req.Multipart.Error = mpTooManyParts, 'too many parts are rejected');
  finally
    A.Free;
  end;

  { ---- a file name from the client cannot be trusted ---- }
  Group('Multipart: file names');
  CheckEqS(SanitizeFileName('image.jpg'), 'image.jpg', 'an ordinary name stands');
  CheckEqS(SanitizeFileName('../../etc/passwd'), 'passwd',
    'directory traversal is removed');
  CheckEqS(SanitizeFileName('..\..\windows\system32\cmd.exe'), 'cmd.exe',
    'with a backslash too');
  CheckEqS(SanitizeFileName('C:\Users\x\report.pdf'), 'report.pdf',
    'and with a drive letter');
  CheckEqS(SanitizeFileName('.bashrc'), 'bashrc',
    'a leading full stop is removed');
  CheckEqS(SanitizeFileName('..'), 'upload', 'only a full stop becomes upload');
  CheckEqS(SanitizeFileName(''), 'upload', 'an empty name becomes upload');
  CheckEqS(SanitizeFileName('a b;rm -rf *.txt'), 'a_b_rm_-rf__.txt',
    'shell characters become underscores');
  { The slash is a directory separator, not a character in the name — also
    when it sits in the middle of something that looks like a name. }
  CheckEqS(SanitizeFileName('a b;rm -rf /.txt'), 'txt',
    'everything before the last slash is a path and goes away');
  Check(Length(SanitizeFileName(StringOfChar('a', 400))) <= 200,
    'the name is truncated');

  { ---- lagring ---- }
  Group('Multipart: storing');
  A := TArena.Create(16 * 1024);
  Folder := '.build/upload-test';
  try
    Body_ := MpPart(G, 'form-data; name="f"; filename="../../evil.TXT"',
      'text/plain', 'hei') + '--' + G + '--'#13#10;
    ParseWithBody(A, 'POST /u HTTP/1.1'#13#10'Host: x'#13#10 +
      'Content-Type: multipart/form-data; boundary=' + G, Body_, Req);
    F := Req.Upload('f');
    CheckEqS(F.SafeName, 'evil.TXT', 'SafeName cleans the name');
    CheckEqS(F.Extension, '.txt', 'the extension is lower case');

    Path_ := F.StoreIn(Folder);
    Check(Path_ <> '', 'StoreIn wrote the file');
    Check(FileExists(Path_), 'and it is there');
    { The client's name must not reach the file system at all. }
    Check(Pos('evil', Path_) = 0, 'the client''s name is not used as the file name');
    Check(Pos(Folder, Path_) = 1, 'and the file landed in the directory we asked for');
    CheckEqS(ExtractFileExt(Path_), '.txt', 'but the extension is there');

    L := TStringList.Create;
    try
      L.LoadFromFile(Path_);
      CheckEqS(Trim(L.Text), 'hei', 'the content reached disk unchanged');
    finally
      L.Free;
    end;

    { Two saves of the same file must not overwrite each other. }
    Check(F.StoreIn(Folder) <> Path_, 'two saves give two files');
  finally
    A.Free;
    RemoveDir_(Folder);
  end;
end;

procedure TestRequest;
var
  A: TArena;
  Req: TRequest;
  St: TParseState;
begin
  Group('Request-parsing');
  A := TArena.Create(8192);
  try
    St := ParseIn(A, 'GET /customers?page=2&q=a%20b HTTP/1.1'#13#10 +
                     'Host: askrcode.test'#13#10 +
                     'X-Tom:'#13#10 +
                     'Accept:  application/json  ', Req);
    Check(St = psOk, 'enkel GET parser');
    Check(Req.Method = hmGet, 'the method');
    CheckEqS(Req.Path.ToString, '/customers', 'the path');
    CheckEqS(Req.QueryString.ToString, 'page=2&q=a%20b', 'query string');
    CheckEqI(Req.VersionMinor, 1, 'HTTP/1.1');
    CheckEqI(Req.HeaderCount, 3, 'headers counted');
    CheckEqS(Req.Header('host').ToString, 'askrcode.test', 'header lookup');
    CheckEqS(Req.Header('HOST').ToString, 'askrcode.test', 'header lookup ignores case');
    CheckEqS(Req.Header('accept').ToString, 'application/json',
      'a header value is trimmed');
    Check(Req.Header('x-tom').IsEmpty, 'tom header-verdi');
    Check(Req.HasHeader('x-tom'), 'an empty header is still there');
    CheckEqS(Req.Query('page').ToString, '2', 'a query parameter');
    CheckEqS(Req.Query('q').ToString, 'a b', 'query-parameter dekodes');
    Check(Req.KeepAlive, 'HTTP/1.1 er keep-alive som standard');

    A.Reset;
    St := ParseIn(A, 'GET /a%2Fb/%C3%A6 HTTP/1.1'#13#10'Host: x', Req);
    Check(St = psOk, 'a percent-encoded path');
    CheckEqS(Req.Path.ToString, '/a/b/æ', 'the path is decoded');
    CheckEqS(Req.RawPath.ToString, '/a%2Fb/%C3%A6', 'a raw path is kept');

    A.Reset;
    St := ParseIn(A, 'GET http://askrcode.test/path?x=1 HTTP/1.1'#13#10'Host: x', Req);
    Check(St = psOk, 'absolute-form target');
    CheckEqS(Req.Path.ToString, '/path', 'absolute-form gives a path');
    CheckEqS(Req.QueryString.ToString, 'x=1', 'absolute-form gir query');

    A.Reset;
    St := ParseIn(A, 'GET /path#frag HTTP/1.1'#13#10'Host: x', Req);
    Check(St = psOk, 'fragment i target');
    CheckEqS(Req.Path.ToString, '/path', 'the fragment is removed');

    A.Reset;
    St := ParseIn(A, 'POST /skjema HTTP/1.1'#13#10 +
                     'Host: x'#13#10 +
                     'Content-Type: application/x-www-form-urlencoded'#13#10 +
                     'Content-Length: 19', Req);
    Check(St = psOk, 'POST with a body');
    CheckEqI(Req.ContentLength, 19, 'Content-Length');
    Req.SetBody(StrDup(A, 'name=Knut&alder=40'));
    CheckEqS(Req.Form('name').ToString, 'Knut', 'Form reads from the body');

    A.Reset;
    St := ParseIn(A, 'GET /kort HTTP/1.0'#13#10, Req);
    Check(St = psOk, 'HTTP/1.0 without Host is fine');
    Check(not Req.KeepAlive, 'HTTP/1.0 closes by default');

    A.Reset;
    St := ParseIn(A, 'GET /kort HTTP/1.0'#13#10'Connection: keep-alive', Req);
    Check(Req.KeepAlive, 'HTTP/1.0 med Connection: keep-alive');

    A.Reset;
    St := ParseIn(A, 'GET / HTTP/1.1'#13#10'Host: x'#13#10'Connection: close', Req);
    Check(not Req.KeepAlive, 'Connection: close');

    { Avvisninger. }
    A.Reset;
    Check(ParseIn(A, 'GET / HTTP/1.1', Req) = psBadRequest,
      'HTTP/1.1 without Host is rejected');
    A.Reset;
    Check(ParseIn(A, 'GET /'#13#10'Host: x', Req) = psBadRequest,
      'a request line without a version is rejected');
    A.Reset;
    Check(ParseIn(A, 'GET / HTTP/2.0'#13#10'Host: x', Req) = psUnsupportedVersion,
      'HTTP/2 over cleartext is rejected');
    A.Reset;
    Check(ParseIn(A, 'GET / HTTP/1.1'#13#10'Host: x'#13#10 +
      'Content-Length: 5'#13#10'Content-Length: 6', Req) = psBadRequest,
      'two different Content-Lengths are rejected');
    A.Reset;
    Check(ParseIn(A, 'GET / HTTP/1.1'#13#10'Host: x'#13#10 +
      'Transfer-Encoding: chunked', Req) = psNotImplemented,
      'chunked is rejected explicitly');
    A.Reset;
    Check(ParseIn(A, 'GET / HTTP/1.1'#13#10'Host: x'#13#10 +
      'X-Fold: a'#13#10' b', Req) = psBadRequest,
      'obsolete line folding avvises');
    A.Reset;
    Check(ParseIn(A, 'GET / HTTP/1.1'#13#10'Host : x', Req) = psBadRequest,
      'a space before the colon is rejected');
    A.Reset;
    Check(ParseIn(A, 'GET / HTTP/1.1'#13#10'Host: x'#13#10 +
      'Content-Length: -1', Req) = psBadRequest,
      'a negative Content-Length is rejected');
    A.Reset;
    Req := nil;
    Check(ParseIn(A, 'GET sti HTTP/1.1'#13#10'Host: x', Req) = psBadRequest,
      'a target without a slash is rejected');
  finally
    A.Free;
  end;
end;

{ -------------------------------------------------------------- response -- }

function Serialize(A: TArena; Res: TResponse; Close_, HeadOnly: Boolean): string;
var
  B: TStrBuilder;
begin
  B.Init(A, 512);
  Res.WriteTo(B, Close_, HeadOnly);
  Result := B.ToString;
end;

function CountOf(const Haystack, Needle: string): Integer;
var
  P, Start: Integer;
begin
  Result := 0;
  Start := 1;
  repeat
    P := PosEx(Needle, Haystack, Start);
    if P = 0 then
      Break;
    Inc(Result);
    Start := P + Length(Needle);
  until False;
end;

procedure TestResponse;
var
  A: TArena;
  Prev: TArena;
  Raw: string;
  Res: TResponse;
begin
  Group('Response');
  A := TArena.Create(8192);
  Prev := UseArena(A);
  try
    Raw := Serialize(A, RespondText('hei'), False, False);
    Check(Pos('HTTP/1.1 200 OK'#13#10, Raw) = 1, 'the status line');
    Check(Pos('Content-Length: 3'#13#10, Raw) > 0, 'Content-Length');
    Check(Pos('Content-Type: text/plain; charset=utf-8'#13#10, Raw) > 0, 'Content-Type');
    Check(Pos('Connection: keep-alive'#13#10, Raw) > 0, 'Connection: keep-alive');
    Check(Pos('Date: '#13#10, Raw) = 0, 'Date er ikke tom');
    Check(Copy(Raw, Length(Raw) - 2, 3) = 'hei', 'the body last');

    A.Reset;
    Raw := Serialize(A, RespondText('hei'), True, False);
    Check(Pos('Connection: close'#13#10, Raw) > 0, 'Connection: close');

    { ---- conditional GET ---- }

    A.Reset;
    Res := RespondText('hei').WithETag('abc');
    Check(Res.HeaderValue('ETag') = '"abc"',
      'the ETag is quoted, because an unquoted one is not valid');
    Res := RespondText('hei').WithETag('abc', True);
    Check(Res.HeaderValue('ETag') = 'W/"abc"', 'and weak when asked');

    A.Reset;
    Res := RespondText('hei').WithETag('abc');
    Check(not Res.NotModifiedIfMatches('"zzz"'), 'a different tag is a miss');
    CheckEqI(Res.StatusCode, 200, 'and the answer stays a 200');

    A.Reset;
    Res := RespondText('hei').WithETag('abc');
    Check(Res.NotModifiedIfMatches('"abc"'), 'the same tag is a hit');
    CheckEqI(Res.StatusCode, 304, 'which makes it a 304');
    CheckEqI(Res.Body.Len, 0, 'with no body');
    Check(Res.HeaderValue('ETag') = '"abc"', 'keeping the ETag');
    Check(Res.HeaderValue('Content-Type') = '',
      'and dropping Content-Type, which describes a body there is none of');
    Raw := Serialize(A, Res, False, False);
    Check(Pos('Content-Length:', Raw) = 0, 'a 304 sends no Content-Length');
    Check(Pos('304 Not Modified', Raw) > 0, 'and says so');

    { The header is a list, and W/"x" matches "x" for If-None-Match --
      the opposite of If-Match, and the one people get backwards. }
    A.Reset;
    Res := RespondText('hei').WithETag('abc');
    Check(Res.NotModifiedIfMatches('"one", W/"abc", "two"'),
      'a list is searched, weakly');
    A.Reset;
    Res := RespondText('hei').WithETag('abc');
    Check(Res.NotModifiedIfMatches('*'), '* matches anything with a tag');

    { A body that comes with a cookie is a body made for one client. A
      page with a CSRF token in it, served from cache on a later 304, is a
      form whose token has since been rotated -- a rejected submit nobody
      can reproduce. The ETag goes too, or the problem only moves to the
      next cache in the chain. }
    A.Reset;
    Res := RespondText('hei').WithETag('abc').WithCookie('session', 'x');
    Check(not Res.NotModifiedIfMatches('"abc"'),
      'a response that sets a cookie never answers 304');
    CheckEqI(Res.StatusCode, 200, 'it stays a 200');
    Check(Res.HeaderValue('ETag') = '', 'and loses the ETag entirely');

    { Only a 200 becomes a 304. A 404 carrying an ETag is a mistake
      somewhere else, and answering it conditionally would hide it. }
    A.Reset;
    Res := RespondText('nope', 404).WithETag('abc');
    Check(not Res.NotModifiedIfMatches('"abc"'), 'a 404 is not conditional');

    A.Reset;
    Res := RespondText('hei');
    Check(not Res.NotModifiedIfMatches('"abc"'),
      'and neither is a response with no ETag at all');

    A.Reset;
    Raw := Serialize(A, RespondText('hei'), False, True);
    Check(Pos('Content-Length: 3'#13#10, Raw) > 0, 'HEAD beholder Content-Length');
    Check(Copy(Raw, Length(Raw) - 3, 4) = #13#10#13#10, 'HEAD leaves out the body');

    A.Reset;
    Raw := Serialize(A, NoContent, False, False);
    Check(Pos('HTTP/1.1 204 No Content', Raw) = 1, '204');
    Check(Pos('Content-Length', Raw) = 0, '204 has no Content-Length');

    A.Reset;
    Raw := Serialize(A, Redirect('/customers', 303), False, False);
    Check(Pos('HTTP/1.1 303 See Other', Raw) = 1, '303');
    Check(Pos('Location: /customers'#13#10, Raw) > 0, 'Location');

    A.Reset;
    Res := Respond(200).WithHeader('X-A', 'en').WithHeader('X-A', 'to');
    Raw := Serialize(A, Res, False, False);
    CheckEqI(Res.HeaderCount, 1, 'samme header to ganger gir én');
    Check(Pos('X-A: to'#13#10, Raw) > 0, 'the last value wins');
    CheckEqI(CountOf(Raw, 'X-A:'), 1, 'the header is written only once');

    A.Reset;
    Res := Respond(200);
    { Tvinger vekst av header-tabellen forbi startkapasiteten. }
    Res.WithHeader('X-1', '1').WithHeader('X-2', '2').WithHeader('X-3', '3')
       .WithHeader('X-4', '4').WithHeader('X-5', '5').WithHeader('X-6', '6')
       .WithHeader('X-7', '7').WithHeader('X-8', '8').WithHeader('X-9', '9')
       .WithHeader('X-10', '10');
    Raw := Serialize(A, Res, False, False);
    CheckEqI(Res.HeaderCount, 10, 'the header table grows');
    Check(Pos('X-1: 1'#13#10, Raw) > 0, 'the first header survived the growth');
    Check(Pos('X-10: 10'#13#10, Raw) > 0, 'the last header after the growth');
  finally
    UseArena(Prev);
    A.Free;
  end;
end;

{ ------------------------------------------------------------------ dato -- }

procedure TestClock;
var
  A: TArena;
  B: TStrBuilder;
begin
  Group('Clock');
  A := TArena.Create(4096);
  try
    B.Init(A, 64);
    AppendHttpDate(B, 784111777);
    CheckEqS(B.ToString, 'Sun, 06 Nov 1994 08:49:37 GMT',
      'an RFC 9110 date (the example from the specification)');

    B.Init(A, 64);
    AppendHttpDate(B, 0);
    CheckEqS(B.ToString, 'Thu, 01 Jan 1970 00:00:00 GMT', 'epoch');

    B.Init(A, 64);
    AppendHttpDate(B, 951782400);
    CheckEqS(B.ToString, 'Tue, 29 Feb 2000 00:00:00 GMT', 'leap year 2000');

    B.Init(A, 64);
    AppendHttpDate(B, 1709164800);
    CheckEqS(B.ToString, 'Thu, 29 Feb 2024 00:00:00 GMT', 'leap year 2024');

    { The second call hits the thread cache and has to give the same
      answer. }
    B.Init(A, 64);
    AppendHttpDate(B, 1709164800);
    CheckEqS(B.ToString, 'Thu, 29 Feb 2024 00:00:00 GMT', 'the cached date is the same');

    Check(UnixNow > 1700000000, 'UnixNow is in our era');
    Check(MonotonicMs > 0, 'MonotonicMs counts');
  finally
    A.Free;
  end;
end;

{ ------------------------------------------------------------------ json -- }

procedure TestJsonWrite;
var
  A: TArena;
  W: TJsonWriter;
  Value_: Currency;
begin
  Group('JSON — writing');
  A := TArena.Create(8192);
  try
    W.Init(A, 256);
    W.BeginObject;
    W.Field('name', 'Knut');
    W.Field('alder', Int64(40));
    W.Field('active', True);
    W.FieldNull('email');
    W.Key('tall');
    W.BeginArray;
    W.Int(1);
    W.Int(2);
    W.Int(3);
    W.EndArray;
    W.Key('nested');
    W.BeginObject;
    W.Field('a', Int64(1));
    W.EndObject;
    W.EndObject;
    CheckEqS(W.ToString,
      '{"name":"Knut","alder":40,"active":true,"email":null,' +
      '"tall":[1,2,3],"nested":{"a":1}}',
      'object, array and nesting');
    CheckEqI(W.Depth, 0, 'every level closed');

    W.Init(A, 64);
    W.BeginArray;
    W.EndArray;
    CheckEqS(W.ToString, '[]', 'tom array');

    W.Init(A, 64);
    W.BeginObject;
    W.EndObject;
    CheckEqS(W.ToString, '{}', 'an empty object');

    W.Init(A, 128);
    W.Str('a quote " and a backslash \ and a line break' + #10 + 'and a tab' + #9);
    CheckEqS(W.ToString,
      '"a quote \" and a backslash \\ and a line break\nand a tab\t"',
      'escaping the usual ones');

    W.Init(A, 64);
    W.Str('control characters' + #1 + #31);
    CheckEqS(W.ToString, '"control characters\u0001\u001f"',
      'control characters are encoded as \u');

    W.Init(A, 64);
    W.Str('æøå — 日本');
    CheckEqS(W.ToString, '"æøå — 日本"', 'UTF-8 passes through unchanged');

    { Currency must never get a decimal comma, whatever the locale. }
    Value_ := 1234.5;
    W.Init(A, 64);
    W.Money(Value_);
    CheckEqS(W.ToString, '1234.5', 'Currency with decimals');
    Value_ := 1234;
    W.Init(A, 64);
    W.Money(Value_);
    CheckEqS(W.ToString, '1234', 'Currency without decimals');
    Value_ := -0.05;
    W.Init(A, 64);
    W.Money(Value_);
    CheckEqS(W.ToString, '-0.05', 'negative Currency');

    W.Init(A, 64);
    W.Num(1.5);
    CheckEqS(W.ToString, '1.5', 'Double uses a full stop');

    W.Init(A, 64);
    W.Raw(Str('{"done":1}'));
    CheckEqS(W.ToString, '{"done":1}',
      'already encoded JSON is inserted as is');

    CheckEqS(HtmlAttrEscape(A, Str('<b>&"x"')).ToString,
      '&lt;b&gt;&amp;&quot;x&quot;', 'HTML attribute escaping');
  finally
    A.Free;
  end;
end;

procedure TestJsonRead;
var
  A: TArena;
  V, M: PJsonValue;
  ErrPos: SizeInt;
begin
  Group('JSON — reading');
  A := TArena.Create(8192);
  try
    Check(JsonParse(A, Str('{"a":1,"b":"to","c":true,"d":null,"e":[1,2]}'),
      V, ErrPos), 'parser et objekt');
    Check(V^.Kind = jkObject, 'rot er objekt');
    CheckEqI(V^.Count, 5, 'five members');
    CheckEqI(JsonAsInt(JsonMember(V, 'a')), 1, 'tall');
    CheckEqS(JsonAsString(JsonMember(V, 'b')), 'to', 'streng');
    Check(JsonAsBool(JsonMember(V, 'c')), 'boolean');
    Check(JsonIsNull(JsonMember(V, 'd')), 'null');
    M := JsonMember(V, 'e');
    Check(M^.Kind = jkArray, 'array');
    CheckEqI(M^.Count, 2, 'two elements');
    CheckEqI(JsonAsInt(JsonAt(M, 1)), 2, 'an element by index');
    Check(JsonMember(V, 'does-not-exist') = nil, 'an unknown key gives nil');

    Check(JsonParse(A, Str('"with \" and \\ and \n"'), V, ErrPos),
      'escapes i streng');
    CheckEqS(JsonAsString(V), 'with " and \ and ' + #10, 'escapes decoded');

    Check(JsonParse(A, Str('"æøå"'), V, ErrPos), 'u-escapes');
    CheckEqS(JsonAsString(V), 'æøå', 'u-escapes become UTF-8');

    Check(JsonParse(A, Str('"😀"'), V, ErrPos), 'a surrogate pair');
    CheckEqI(Length(JsonAsString(V)), 4, 'an emoji is four bytes in UTF-8');

    Check(JsonParse(A, Str('  [ 1 , 2 ]  '), V, ErrPos), 'whitespace');
    CheckEqI(V^.Count, 2, 'two elements despite the whitespace');

    Check(JsonParse(A, Str('-12.5e3'), V, ErrPos), 'a number with an exponent');
    CheckEqS(JsonAsStr(V).ToString, '-12.5e3', 'the number is kept as text');

    Check(not JsonParse(A, Str('{"a":}'), V, ErrPos),
      'a missing value is rejected');
    Check(not JsonParse(A, Str('{"a":1'), V, ErrPos),
      'an unterminated object is rejected');
    Check(not JsonParse(A, Str('[1,2] nonsense'), V, ErrPos),
      'trailing rubbish is rejected');
    Check(not JsonParse(A, Str(''), V, ErrPos), 'tom streng avvises');
  finally
    A.Free;
  end;
end;

{ --------------------------------------------------------------- inertia -- }

function MakeRequest(A: TArena; const Head: string): TRequest;
var
  Prev: TArena;
begin
  Prev := UseArena(A);
  try
    Result := TRequest.Create;
    Result.ParseHead(StrDup(A, Head), DefaultMaxBodyBytes);
  finally
    UseArena(Prev);
  end;
end;

function Reply(A: TArena; R: TResponse): string;
var
  B: TStrBuilder;
begin
  B.Init(A, 2048);
  R.WriteTo(B, False, False);
  Result := B.ToString;
end;

{ Characters of text in the body, outside every script element, with the
  tags removed.

  The same thing a `curl | strip scripts | count` does, because that is the
  measurement the fallback exists for: 213 kB of HTML with nothing to read
  in it was the finding, and a proxy for it would not have been.

  The body, not the whole document -- the <title> is real text and a
  crawler does read it, but a title is not a page. }
function VisibleTextLength(const Html: string): Integer;
var
  I, Depth, BodyAt: Integer;
  InTag, InScript: Boolean;
  Low_: string;
begin
  Result := 0;
  Low_ := LowerCase(Html);
  BodyAt := Pos('<body', Low_);
  if BodyAt > 0 then
  begin
    Low_ := Copy(Low_, BodyAt, MaxInt);
    I := 1;
    Low_ := LowerCase(Copy(Html, BodyAt, MaxInt));
  end
  else
    I := 1;
  InScript := False;
  while I <= Length(Low_) do
  begin
    if (not InScript) and (Copy(Low_, I, 7) = '<script') then
    begin
      InScript := True;
      Inc(I, 7);
      Continue;
    end;
    if InScript then
    begin
      if Copy(Low_, I, 9) = '</script>' then
      begin
        InScript := False;
        Inc(I, 9);
        Continue;
      end;
      Inc(I);
      Continue;
    end;
    if Low_[I] = '<' then
    begin
      Depth := 1;
      InTag := True;
      while (I <= Length(Low_)) and InTag do
      begin
        Inc(I);
        if (I <= Length(Low_)) and (Low_[I] = '>') then
        begin
          Dec(Depth);
          InTag := Depth > 0;
        end;
      end;
      Inc(I);
      Continue;
    end;
    if not (Low_[I] in [#9, #10, #13, ' ']) then
      Inc(Result);
    Inc(I);
  end;
end;

procedure TestInertia;
var
  A: TArena;
  PrevA: TArena;
  PrevR: TRequest;
  Req: TRequest;
  R: TResponse;
  Body, Raw: string;
  Lines: TStringList;
  Raised_: Boolean;
begin
  Group('Inertia');
  A := TArena.Create(32 * 1024);
  PrevA := UseArena(A);
  PrevR := UseRequest(nil);
  try
    TInertia.SetVersion('abc123');

    { ---- this page's head ----

      Two escapings, and which applies depends on where the value lands.
      An attribute takes HTML escaping; the JSON-LD lands inside a script
      element, where the browser decodes no entities -- so HTML escaping
      there would put `&quot;` into the JSON as six characters and break
      it, while an unescaped `</script>` would close the element. }
    ForceDirectories('.build' + PathDelim + 'cfg-head');
    Lines := TStringList.Create;
    try
      Lines.Add('APP_ENV=local');
      Lines.Add('APP_URL=https://example.com');
      Lines.SaveToFile('.build' + PathDelim + 'cfg-head' + PathDelim + '.env');
    finally
      Lines.Free;
    end;
    ClearConfig;
    LoadConfig('.build' + PathDelim + 'cfg-head');

    Req := MakeRequest(A, 'GET /docs/queries HTTP/1.1'#13#10'Host: test');
    UseRequest(Req);
    TInertia.PageTitle('Queries — "typed" <b>');
    TInertia.PageDescription('A description with " and <b> and </script> in it');
    TInertia.PageCanonical('/docs/queries');
    TInertia.PageOg('title', 'Queries');
    TInertia.PageJsonLd('{"@type":"Article","name":"a </script> b"}');
    R := Inertia('Docs/Show', ['slug', 'queries']);
    Raw := R.Body.ToString;

    Check(Pos('<title>Queries &amp; ', Raw) = 0, 'sanity: not a stray match');
    Check(Pos('&quot;typed&quot;', Raw) > 0,
      'the page title overrides the site default, escaped');
    Check(Pos('&lt;b&gt;', Raw) > 0, 'and its angle brackets are gone');
    Check(Pos('<meta name="description"', Raw) > 0, 'a description is written');
    Check(Pos('name="description" content="A description with &quot;', Raw) > 0,
      'with the quote escaped, or the attribute would end there');
    Check(Pos('<link rel="canonical" href="https://example.com/docs/queries">',
      Raw) > 0, 'the canonical is absolute, from app.url');
    Check(Pos('<meta property="og:title" content="Queries">', Raw) > 0,
      'and Open Graph gets its prefix');

    { The one that decides whether a page can be hijacked from its own
      metadata: no raw </script> anywhere outside the payload. }
    Check(Pos('</script><img', Raw) = 0, 'nothing closed the script element');
    { One backslash, not two: Pascal does not interpret escapes in a
      string literal, so '\\' would be two characters. The same trap as
      the emitted /\\//g that once left a regex unclosed. The '/' is
      escaped as well, so the whole thing reads \u003c\/script. }
    Check(Pos('\u003c\/script', Raw) > 0,
      'the JSON-LD escaped its closing tag as JSON, not as HTML');
    Check(Pos('&quot;@type&quot;', Raw) = 0,
      'and was not HTML-escaped, which would have broken the JSON');

    { Per thread and per response: the next page does not inherit this
      one's head. A worker serves one request after another. }
    A.Reset;
    Req := MakeRequest(A, 'GET /other HTTP/1.1'#13#10'Host: test');
    UseRequest(Req);
    R := Inertia('Other', []);
    Raw := R.Body.ToString;
    Check(Pos('description', Raw) = 0, 'the next page inherits no description');
    Check(Pos('canonical', Raw) = 0, 'nor a canonical');
    Check(Pos('og:', Raw) = 0, 'nor Open Graph');
    Check(Pos('ld+json', Raw) = 0, 'nor the JSON-LD');
    Check(Pos('<title>Askr</title>', Raw) > 0,
      'and the title is the site default again');

    { ---- what a reader without JavaScript gets ----

      This is the measurement, not a proxy for it. Strip every script
      element and count what is left. An Inertia page without a fallback
      answers a crawler with a payload in a script element and an empty
      div: zero characters. Googlebot runs scripts and copes; the fetchers
      behind most language models do not. }
    A.Reset;
    Req := MakeRequest(A, 'GET /docs/queries HTTP/1.1'#13#10'Host: test');
    UseRequest(Req);
    R := Inertia('Docs/Show', ['slug', 'queries']);
    CheckEqI(VisibleTextLength(R.Body.ToString), 0,
      'without a fallback there is nothing to read outside the scripts');

    A.Reset;
    Req := MakeRequest(A, 'GET /docs/queries HTTP/1.1'#13#10'Host: test');
    UseRequest(Req);
    TInertia.PageFallback('<h1>Queries</h1><p>The typed query builder.</p>');
    R := Inertia('Docs/Show', ['slug', 'queries']);
    Raw := R.Body.ToString;
    Check(VisibleTextLength(Raw) > 20,
      'with one there is, and it is real text');
    Check(Pos('<h1>Queries</h1>', Raw) > 0, 'the markup is not escaped');
    { Inside the mount element, so the client replaces it rather than
      leaving it beside the app. }
    Check(Pos('<div id="app"><h1>Queries</h1>', Raw) > 0,
      'and it sits inside the mount element');

    { It is per page, like the rest of the head. }
    A.Reset;
    Req := MakeRequest(A, 'GET /other HTTP/1.1'#13#10'Host: test');
    UseRequest(Req);
    R := Inertia('Other', []);
    CheckEqI(VisibleTextLength(R.Body.ToString), 0,
      'and the next page does not inherit it');

    { A template with nowhere to put it is a mistake worth stopping on.
      Dropping it quietly would leave the page empty for exactly the
      readers it was written for. }
    A.Reset;
    TInertia.SetRootTemplate('<html><body><div id="{{root}}"></div>' +
      '<script>{{page}}</script></body></html>');
    Req := MakeRequest(A, 'GET /x HTTP/1.1'#13#10'Host: test');
    UseRequest(Req);
    TInertia.PageFallback('<p>hei</p>');
    Raised_ := False;
    try
      Inertia('X', []);
    except
      on E: EInertiaError do
        Raised_ := True;
    end;
    Check(Raised_, 'a template with no {{fallback}} refuses the page');
    TInertia.SetRootTemplate('');
    TInertia.ClearPageHead;

    ClearConfig;
    A.Reset;

    { Without X-Inertia: hele HTML-skallet. }
    Req := MakeRequest(A, 'GET /customers?page=2 HTTP/1.1'#13#10'Host: test');
    UseRequest(Req);
    { The prop value deliberately contains something that would have ended
      the script block if the escaping did not work. }
    R := Inertia('Customers/Index',
      ['count', Int64(3), 'malicious', '</script><img src=x onerror=alert(1)>']);
    Raw := Reply(A, R);
    Check(Pos('text/html', Raw) > 0, 'an ordinary request gives HTML');
    Check(Pos('</script><img', Raw) = 0,
      'a prop value cannot break out of the script block');
    { Only < og / escapes; > er ufarlig alene. }
    Check(Pos('\u003c\/script>', Raw) > 0,
      'it is escaped to \u003c and \/ instead');
    Check(Pos('<script data-page="app" type="application/json">', Raw) > 0,
      'Inertia 3 legger payloaden i et script-element');
    Check(Pos('<div id="app"></div>', Raw) > 0, 'an empty mount div');

    { A page without a title is a serious accessibility violation, and it
      applied to every single Inertia page until this arrived. Found by
      running axe against a site built with the framework. }
    Check(Pos('<title>', Raw) > 0, 'the shell has a title');
    Check(Pos('<title></title>', Raw) = 0, 'and it is not empty');
    { lang must not be hard-coded Norwegian in an international
      framework. }
    Check(Pos('lang="en"', Raw) > 0, 'and lang is en, not no');

    TInertia.SetTitle('Ada & <Co>');
    Raw := Reply(A, Inertia('Customers/Index', ['count', Int64(1)]));
    Check(Pos('<title>Ada &amp; &lt;Co&gt;</title>', Raw) > 0,
      'the title is escaped — it is user-controlled');
    TInertia.SetTitle('Askr');
    Check(Pos('"component":"Customers\/Index"', Raw) > 0,
      'a slash is escaped in ordinary values too');
    Check(Pos('Vary: X-Inertia', Raw) > 0, 'Vary is set on HTML too');

    { With_ X-Inertia: ren JSON. }
    A.Reset;
    Req := MakeRequest(A, 'GET /customers?page=2 HTTP/1.1'#13#10'Host: test'#13#10 +
      'X-Inertia: true');
    UseRequest(Req);
    R := Inertia('Customers/Index', ['count', Int64(3)]);
    Body := R.Body.ToString;
    Raw := Reply(A, R);
    Check(Pos('X-Inertia: true', Raw) > 0, 'X-Inertia is set on the reply');
    Check(Pos('application/json', Raw) > 0, 'Content-Type er JSON');
    CheckEqS(Body,
      '{"component":"Customers/Index","props":{"locale":"en","count":3},' +
      '"url":"/customers?page=2","version":"abc123",' +
      '"clearHistory":false,"encryptHistory":false}',
      'payloaden er standard Inertia 3');

    { A version mismatch: the client is to reload, not get a useless
      payload. }
    A.Reset;
    Req := MakeRequest(A, 'GET /customers HTTP/1.1'#13#10'Host: test'#13#10 +
      'X-Inertia: true'#13#10'X-Inertia-Version: gammel');
    UseRequest(Req);
    R := Inertia('Customers/Index', ['count', Int64(3)]);
    CheckEqI(R.StatusCode, 409, 'a version mismatch gives 409');
    Check(Pos('X-Inertia-Location: /customers', Reply(A, R)) > 0,
      'and points the client at the address again');

    A.Reset;
    Req := MakeRequest(A, 'GET /customers HTTP/1.1'#13#10'Host: test'#13#10 +
      'X-Inertia: true'#13#10'X-Inertia-Version: abc123');
    UseRequest(Req);
    R := Inertia('Customers/Index', ['count', Int64(3)]);
    CheckEqI(R.StatusCode, 200, 'the right version passes');

    { A partial reload: only what the client asked for. }
    A.Reset;
    Req := MakeRequest(A, 'GET /customers HTTP/1.1'#13#10'Host: test'#13#10 +
      'X-Inertia: true'#13#10 +
      'X-Inertia-Partial-Component: Customers/Index'#13#10 +
      'X-Inertia-Partial-Data: customers');
    UseRequest(Req);
    R := Inertia('Customers/Index',
      ['customers', 'list', 'statistics', 'heavy', 'menu', 'thing']);
    Check(Pos('"props":{"customers":"list"}', R.Body.ToString) > 0,
      'only the requested prop is there');
    Check(Pos('statistics', R.Body.ToString) = 0, 'the rest is left out');

    A.Reset;
    Req := MakeRequest(A, 'GET /customers HTTP/1.1'#13#10'Host: test'#13#10 +
      'X-Inertia: true'#13#10 +
      'X-Inertia-Partial-Component: Customers/Index'#13#10 +
      'X-Inertia-Partial-Except: statistics');
    UseRequest(Req);
    R := Inertia('Customers/Index', ['customers', 'list', 'statistics', 'heavy']);
    Check(Pos('statistics', R.Body.ToString) = 0, 'Except leaves the prop out');
    Check(Pos('customers', R.Body.ToString) > 0, 'the rest is there');

    { Delvis oppdatering for en annen komponent er en vanlig navigering. }
    A.Reset;
    Req := MakeRequest(A, 'GET /customers HTTP/1.1'#13#10'Host: test'#13#10 +
      'X-Inertia: true'#13#10 +
      'X-Inertia-Partial-Component: Orders/Index'#13#10 +
      'X-Inertia-Partial-Data: order');
    UseRequest(Req);
    R := Inertia('Customers/Index', ['customers', 'list']);
    Check(Pos('customers', R.Body.ToString) > 0,
      'a partial for another component gives the full payload');

    { Inertia 3: props the client already holds as "once" must not be
      sent. }
    A.Reset;
    Req := MakeRequest(A, 'GET /customers HTTP/1.1'#13#10'Host: test'#13#10 +
      'X-Inertia: true'#13#10 +
      'X-Inertia-Except-Once-Props: menu');
    UseRequest(Req);
    R := Inertia('Customers/Index', ['customers', 'list', 'menu', 'thing']);
    Check(Pos('menu', R.Body.ToString) = 0,
      'a once prop the client already has is left out');
    Check(Pos('customers', R.Body.ToString) > 0, 'the rest is there');

    { Deferred props: not in the first reply, but listed in
      deferredProps. }
    A.Reset;
    Req := MakeRequest(A, 'GET /customers HTTP/1.1'#13#10'Host: test'#13#10 +
      'X-Inertia: true');
    UseRequest(Req);
    R := Inertia('Customers/Index',
      ['customers', 'list', 'statistics', 'heavy'], ['statistics']);
    Check(Pos('"customers":"list"', R.Body.ToString) > 0, 'an ordinary prop is there');
    Check(Pos('"statistics":"heavy"', R.Body.ToString) = 0,
      'a deferred prop is not among the values');
    Check(Pos('"deferredProps":{"default":["statistics"]}', R.Body.ToString) > 0,
      'but it is listed as deferred');

    { When the client asks for it, it arrives. }
    A.Reset;
    Req := MakeRequest(A, 'GET /customers HTTP/1.1'#13#10'Host: test'#13#10 +
      'X-Inertia: true'#13#10 +
      'X-Inertia-Partial-Component: Customers/Index'#13#10 +
      'X-Inertia-Partial-Data: statistics');
    UseRequest(Req);
    R := Inertia('Customers/Index',
      ['customers', 'list', 'statistics', 'heavy'], ['statistics']);
    Check(Pos('"statistics":"heavy"', R.Body.ToString) > 0,
      'a deferred prop is fetched in its own round');
    Check(Pos('deferredProps', R.Body.ToString) = 0,
      'and is no longer listed as deferred');

    { Redirect: 303 after PUT, PATCH and DELETE. }
    A.Reset;
    Req := MakeRequest(A, 'POST /customers HTTP/1.1'#13#10'Host: test');
    UseRequest(Req);
    CheckEqI(InertiaRedirect('/customers').StatusCode, 302, 'POST gives 302');

    A.Reset;
    Req := MakeRequest(A, 'PUT /customers/1 HTTP/1.1'#13#10'Host: test');
    UseRequest(Req);
    CheckEqI(InertiaRedirect('/customers').StatusCode, 303, 'PUT gives 303');

    A.Reset;
    Req := MakeRequest(A, 'DELETE /customers/1 HTTP/1.1'#13#10'Host: test');
    UseRequest(Req);
    CheckEqI(InertiaRedirect('/customers').StatusCode, 303, 'DELETE gives 303');

    { Props have to come in pairs. }
    A.Reset;
    Req := MakeRequest(A, 'GET / HTTP/1.1'#13#10'Host: test');
    UseRequest(Req);
    try
      Inertia('X', ['bare-name']);
      Check(False, 'an odd number of props should have raised');
    except
      on E: EInertiaError do
        Check(True, 'an odd number of props is rejected');
    end;
  finally
    UseRequest(PrevR);
    UseArena(PrevA);
    A.Free;
  end;
end;

{ ----------------------------------------------------------------- ruter -- }

type
  TRouteTrace = class
  public
    Matched: string;
    function Index(Req: TRequest): TResponse;
    function Vis(Req: TRequest): TResponse;
    function New_(Req: TRequest): TResponse;
    function Save(Req: TRequest): TResponse;
    function File_(Req: TRequest): TResponse;
    function Stop_(Req: TRequest): TResponse;
    function SlippGjennom(Req: TRequest): TResponse;
  end;

function TRouteTrace.Index(Req: TRequest): TResponse;
begin
  Matched := 'index';
  Result := RespondText('index');
end;

function TRouteTrace.Vis(Req: TRequest): TResponse;
begin
  Matched := 'vis:' + Req.Param('id').ToString;
  Result := RespondText(Matched);
end;

function TRouteTrace.New_(Req: TRequest): TResponse;
begin
  Matched := 'new';
  Result := RespondText('new');
end;

function TRouteTrace.Save(Req: TRequest): TResponse;
begin
  Matched := 'lagre';
  Result := RespondText('lagre');
end;

function TRouteTrace.File_(Req: TRequest): TResponse;
begin
  Matched := 'file:' + Req.Param('path').ToString;
  Result := RespondText(Matched);
end;

function TRouteTrace.Stop_(Req: TRequest): TResponse;
begin
  Result := RespondText('stopped by middleware', 403);
end;

function TRouteTrace.SlippGjennom(Req: TRequest): TResponse;
begin
  Result := nil;
end;

procedure TestSitemapSource(S: TSitemap);
begin
  S.Add('/').Add('/customers');
end;

procedure TestRuter;
var
  A: TArena;
  PrevA: TArena;
  R: TRouter;
  Spor: TRouteTrace;
  Req: TRequest;
  Reply_: TResponse;
  Lines: TStringList;
  StaticFile: TStringList;
begin
  Group('Router');
  A := TArena.Create(32 * 1024);
  PrevA := UseArena(A);
  Spor := TRouteTrace.Create;
  R := TRouter.Create;
  try
    R.Get('/customers', Spor.Index);
    R.Get('/customers/:id', Spor.Vis);
    R.Get('/customers/new', Spor.New_);
    R.Post('/customers', Spor.Save);
    R.Get('/files/*path', Spor.File_);
    R.AsName('files');

    Req := MakeRequest(A, 'GET /customers HTTP/1.1'#13#10'Host: t');
    Reply_ := R.Handle(Req);
    CheckEqS(Spor.Matched, 'index', 'a fixed route matches');
    CheckEqI(Reply_.StatusCode, 200, 'and answers 200');

    A.Reset;
    Req := MakeRequest(A, 'GET /customers/42 HTTP/1.1'#13#10'Host: t');
    R.Handle(Req);
    CheckEqS(Spor.Matched, 'vis:42', 'a parameter is captured');
    CheckEqI(Req.IntParam('id'), 42, 'IntParam');

    { This is the whole point of the sorting: /customers/new is registered
      after /customers/:id, but is to win anyway. }
    A.Reset;
    Req := MakeRequest(A, 'GET /customers/new HTTP/1.1'#13#10'Host: t');
    R.Handle(Req);
    CheckEqS(Spor.Matched, 'new', 'a fixed segment beats a parameter whatever the order');

    A.Reset;
    Req := MakeRequest(A, 'GET /files/images/logo.png HTTP/1.1'#13#10'Host: t');
    R.Handle(Req);
    CheckEqS(Spor.Matched, 'file:images/logo.png', 'a wildcard captures the rest');

    A.Reset;
    Req := MakeRequest(A, 'POST /customers HTTP/1.1'#13#10'Host: t');
    R.Handle(Req);
    CheckEqS(Spor.Matched, 'lagre', 'the method separates the routes');

    A.Reset;
    Req := MakeRequest(A, 'HEAD /customers HTTP/1.1'#13#10'Host: t');
    Reply_ := R.Handle(Req);
    CheckEqI(Reply_.StatusCode, 200, 'HEAD hits the GET route');

    A.Reset;
    Req := MakeRequest(A, 'DELETE /customers HTTP/1.1'#13#10'Host: t');
    Reply_ := R.Handle(Req);
    CheckEqI(Reply_.StatusCode, 405, 'a known path with an unknown method gives 405');

    A.Reset;
    Req := MakeRequest(A, 'GET /does-not-exist HTTP/1.1'#13#10'Host: t');
    Reply_ := R.Handle(Req);
    CheckEqI(Reply_.StatusCode, 404, 'an unknown path gives 404');

    A.Reset;
    Req := MakeRequest(A, 'GET /customers/42/order HTTP/1.1'#13#10'Host: t');
    Reply_ := R.Handle(Req);
    CheckEqI(Reply_.StatusCode, 404, 'too many segments do not match');

    Lines := TStringList.Create;
    try
      R.Describe(Lines);
      CheckEqI(Lines.Count, 5, 'Describe lister alle rutene');
      Check(Pos('(files)', Lines.Text) > 0, 'a named route is shown with its name');
    finally
      Lines.Free;
    end;

    { robots.txt is a route, not middleware: it costs nothing on requests
      that are not for it, and an application's own public/robots.txt is
      served by the static files ahead of the router and wins without this
      having to know about it.

      Registered after the count above, so that the route table this test
      describes stays the one it was written for. }
    UseRobots(R);
    A.Reset;
    Req := MakeRequest(A, 'GET /robots.txt HTTP/1.1'#13#10'Host: t');
    Reply_ := R.Handle(Req);
    CheckEqI(Reply_.StatusCode, 200, 'robots.txt is answered');
    Check(Pos('text/plain', Reply_.HeaderValue('Content-Type')) > 0,
      'as text');
    Check(Pos('User-agent: *', Reply_.Body.ToString) > 0, 'with a body');

    A.Reset;
    Req := MakeRequest(A, 'POST /robots.txt HTTP/1.1'#13#10'Host: t');
    Reply_ := R.Handle(Req);
    Check((Reply_ = nil) or (Reply_.StatusCode <> 200), 'and only by GET');

    { A sitemap needs an origin, and refuses rather than emitting relative
      URLs a crawler would reject. Without app.url the handler raises, the
      server turns that into a 500, and the log line names the key -- which
      is the right noise for a misconfiguration, and the reason this test
      has to say which origin it means. }
    ForceDirectories('.build' + PathDelim + 'cfg-sitemap-route');
    StaticFile := TStringList.Create;
    try
      StaticFile.Add('APP_ENV=local');
      StaticFile.Add('APP_URL=https://example.com');
      StaticFile.SaveToFile('.build' + PathDelim + 'cfg-sitemap-route' +
        PathDelim + '.env');
    finally
      StaticFile.Free;
    end;
    ClearConfig;
    LoadConfig('.build' + PathDelim + 'cfg-sitemap-route');

    UseSitemap(R, @TestSitemapSource);
    A.Reset;
    Req := MakeRequest(A, 'GET /sitemap.xml HTTP/1.1'#13#10'Host: t');
    Reply_ := R.Handle(Req);
    CheckEqI(Reply_.StatusCode, 200, 'sitemap.xml is answered');
    Check(Pos('application/xml', Reply_.HeaderValue('Content-Type')) > 0,
      'as xml');
    Check(Pos('<urlset', Reply_.Body.ToString) > 0, 'with a urlset');

    { A part number is text a client wrote. One that does not exist is a
      404 rather than an empty document, which would read as a site with
      no pages at all. }
    A.Reset;
    Req := MakeRequest(A, 'GET /sitemap/9 HTTP/1.1'#13#10'Host: t');
    Reply_ := R.Handle(Req);
    CheckEqI(Reply_.StatusCode, 404, 'a part that does not exist is a 404');
    A.Reset;
    Req := MakeRequest(A, 'GET /sitemap/nonsense HTTP/1.1'#13#10'Host: t');
    Reply_ := R.Handle(Req);
    CheckEqI(Reply_.StatusCode, 404, 'and so is a part that is not a number');
    ClearConfig;
  finally
    R.Free;
    Spor.Free;
    UseArena(PrevA);
    A.Free;
  end;

  { Middleware stops before the handler. }
  A := TArena.Create(8192);
  PrevA := UseArena(A);
  Spor := TRouteTrace.Create;
  R := TRouter.Create;
  try
    Spor.Matched := '';
    R.Use(Spor.SlippGjennom);
    R.Use(Spor.Stop_);
    R.Get('/', Spor.Index);
    Req := MakeRequest(A, 'GET / HTTP/1.1'#13#10'Host: t');
    Reply_ := R.Handle(Req);
    CheckEqI(Reply_.StatusCode, 403, 'middleware can stop the request');
    CheckEqS(Spor.Matched, '', 'and the handler never ran');
  finally
    R.Free;
    Spor.Free;
    UseArena(PrevA);
    A.Free;
  end;
end;

{ Middleware and after-filters run in registration order, whichever kind
  each one is.

  There used to be one list for methods and one for plain procedures, and
  every method ran before every procedure. Which list a piece of
  middleware landed in was decided by how it happened to be written, not
  by anything at the call site -- so `R.Use(@A); R.Use(B.C);` ran C, then
  A, and a reader had no way to see it.

  It cost a real bug: a generated app leased its database connection with
  a procedure and read API tokens with a class method, so the token
  middleware asked for the connection before it was there. Every request
  carrying a token was a 500. The suite could not see it, because a test
  that registers only one kind never notices; this one registers both,
  alternating. }
type
  TOrderTrace = class
  public
    function First_(Req: TRequest): TResponse;
    function Third(Req: TRequest): TResponse;
    function AfterB(Req: TRequest; Res: TResponse): TResponse;
    function AfterD(Req: TRequest; Res: TResponse): TResponse;
    function Handler(Req: TRequest): TResponse;
  end;

var
  GOrder: string;

function TOrderTrace.First_(Req: TRequest): TResponse;
begin
  GOrder := GOrder + 'A';
  Result := nil;
end;

function SecondProc(Req: TRequest): TResponse;
begin
  GOrder := GOrder + 'B';
  Result := nil;
end;

function TOrderTrace.Third(Req: TRequest): TResponse;
begin
  GOrder := GOrder + 'C';
  Result := nil;
end;

function FourthProc(Req: TRequest): TResponse;
begin
  GOrder := GOrder + 'D';
  Result := nil;
end;

function TOrderTrace.Handler(Req: TRequest): TResponse;
begin
  GOrder := GOrder + '|';
  Result := RespondText('ok');
end;

function AfterAProc(Req: TRequest; Res: TResponse): TResponse;
begin
  GOrder := GOrder + 'a';
  Result := Res;
end;

function TOrderTrace.AfterB(Req: TRequest; Res: TResponse): TResponse;
begin
  GOrder := GOrder + 'b';
  Result := Res;
end;

function AfterCProc(Req: TRequest; Res: TResponse): TResponse;
begin
  GOrder := GOrder + 'c';
  Result := Res;
end;

function TOrderTrace.AfterD(Req: TRequest; Res: TResponse): TResponse;
begin
  GOrder := GOrder + 'd';
  Result := Res;
end;

procedure TestMiddlewareOrder;
var
  A, PrevA: TArena;
  R: TRouter;
  T: TOrderTrace;
  Req: TRequest;
begin
  Group('Middleware order');
  A := TArena.Create(8192);
  PrevA := UseArena(A);
  T := TOrderTrace.Create;
  R := TRouter.Create;
  try
    GOrder := '';
    { Method, procedure, method, procedure. }
    R.Use(T.First_);
    R.Use(@SecondProc);
    R.Use(T.Third);
    R.Use(@FourthProc);
    { And the filters the other way round: procedure, method, procedure,
      method -- so neither ordering can come out right by accident. }
    R.After(@AfterAProc);
    R.After(T.AfterB);
    R.After(@AfterCProc);
    R.After(T.AfterD);
    R.Get('/', T.Handler);

    Req := MakeRequest(A, 'GET / HTTP/1.1'#13#10'Host: t');
    R.Handle(Req);
    CheckEqS(GOrder, 'ABCD|dcba',
      'middleware in registration order, filters in reverse, both kinds');
  finally
    R.Free;
    T.Free;
    UseArena(PrevA);
    A.Free;
  end;
end;

{ ------------------------------------------------------------- validering -- }

type
{ A model with something in it that must never leave the process, and a
  parent that carries it as a relation. Both are needed: the check lives
  in one place, and the way to find out whether that place is the right
  one is to reach it from every direction. }
  TSecretUser = class(TModel)
  private
    FId: Int64;
    FEmail: string;
    FPasswordHash: string;
    FResetToken: string;
  published
    property Id: Int64 read FId write FId;
    property Email: string read FEmail write FEmail;
    property PasswordHash: string read FPasswordHash write FPasswordHash;
    property ResetToken: string read FResetToken write FResetToken;
  public
    class procedure Describe(S: TSchema); override;
    class procedure HideFromJson(H: TJsonHidden); override;
  end;

  TSecretUserList = TModelList<TSecretUser>;

{ What `askr schema` would generate for this table. Written by hand here
  because the test has no database; the point is that the names are typed
  constants and not strings. }
const
  SecretUsers: record
    Id: TColInt64;
    Email: TColStr;
    PasswordHash: TColStr;
    ResetToken: TColStr;
  end = (
    Id: (Name: 'id'; Table: 'secret_users');
    Email: (Name: 'email'; Table: 'secret_users');
    PasswordHash: (Name: 'password_hash'; Table: 'secret_users');
    ResetToken: (Name: 'reset_token'; Table: 'secret_users'));

type

  TSecretTeam = class(TModel)
  private
    FId: Int64;
    FName: string;
  published
    { The relation is a published FIELD, not a property: that is what
      FieldAddress finds, and a published field has to come before the
      properties in the same section. }
    Members: TSecretUserList;
    property Id: Int64 read FId write FId;
    property Name: string read FName write FName;
  public
    class procedure Describe(S: TSchema); override;
  end;

  TTestCustomer = class(TModel)
  private
    FId: Int64;
    FName: string;
    FEmail: string;
    FEmailAgain: string;
    FBalance: Currency;
    FStatus: string;
  published
    property Id: Int64 read FId write FId;
    property Name: string read FName write FName;
    property Email: string read FEmail write FEmail;
    property EmailAgain: string read FEmailAgain write FEmailAgain;
    property Balance: Currency read FBalance write FBalance;
    property Status: string read FStatus write FStatus;
  public
    class procedure Describe(S: TSchema); override;
    procedure Rules(V: TValidator); override;
  end;

class procedure TSecretUser.Describe(S: TSchema);
begin
  S.Table('secret_users');
end;

class procedure TSecretUser.HideFromJson(H: TJsonHidden);
begin
  { Typed, so a column that is renamed later stops compiling instead of
    starting to leak. }
  H.Add(SecretUsers.PasswordHash);
  H.Add(SecretUsers.ResetToken);
end;

class procedure TSecretTeam.Describe(S: TSchema);
begin
  S.Table('secret_teams');
  S.HasMany('Members', TSecretUser, 'team_id');
end;

{ Nothing a model hides may appear in any payload.

  WriteModel writes every mapped column, which is right for a query
  builder and wrong for anything that leaves the process. `askr new --auth`
  generates a user with a PasswordHash property, so before this a single
  `Inertia('Page', ['user', U])` put the hash on the wire. Measured, not
  feared: a program written to check printed an object with id, email and
  a password_hash field carrying the hash verbatim.

  So: a sentinel in the secret, and a sweep of every way a model reaches
  JSON. The same shape as the sweep that found two DSN leaks -- finding
  the string anywhere is the failure, and a path added later is covered by
  the same assertion. }
procedure TestHiddenColumns;
const
  Sentinel = 'SENTINEL-HASH-MUST-NOT-LEAK';
  TokenSentinel = 'SENTINEL-TOKEN-MUST-NOT-LEAK';
var
  A: TArena;
  PrevA: TArena;
  U: TSecretUser;
  Team: TSecretTeam;
  L: TSecretUserList;
  W: TJsonWriter;
  Json_: string;

  procedure Sweep(const What, Payload: string);
  begin
    Check(Pos(Sentinel, Payload) = 0, What + ': no password hash');
    Check(Pos(TokenSentinel, Payload) = 0, What + ': no reset token');
  end;

begin
  Group('Hidden columns');
  A := TArena.Create(32 * 1024);
  PrevA := UseArena(A);
  try
    U := A.New<TSecretUser>;
    U.Id := 7;
    U.Email := 'kh@example.com';
    U.PasswordHash := Sentinel;
    U.ResetToken := TokenSentinel;

    { 1. the model on its own }
    W.Init(A, 512);
    WriteModel(W, U);
    Json_ := W.ToString;
    Sweep('a model', Json_);
    { And the rest is still there: hiding two columns must not hide the
      object. }
    Check(Pos('"email":"kh@example.com"', Json_) > 0,
      'a model: what is not hidden still goes out');
    Check(Pos('"id":7', Json_) > 0, 'a model: including the key');

    { 2. a list }
    L := A.New<TSecretUserList>;
    L.Add(U);
    W.Init(A, 512);
    WriteModelList(W, L);
    Sweep('a list', W.ToString);

    { 3. as a relation on a parent }
    Team := A.New<TSecretTeam>;
    Team.Id := 1;
    Team.Name := 'Core';
    Team.Members := L;
    W.Init(A, 1024);
    WriteModel(W, Team);
    Json_ := W.ToString;
    Sweep('a relation', Json_);
    Check(Pos('"members"', Json_) > 0,
      'a relation: the relation itself is still there');

    { 4. as an Inertia prop, which is the one that shipped it }
    UseRequest(MakeRequest(A, 'GET /team HTTP/1.1'#13#10'Host: t'));
    Sweep('an Inertia prop',
      Inertia('Team/Show', ['user', U, 'team', Team]).Body.ToString);
    UseRequest(nil);

    { The meta answers directly too, so a caller building its own payload
      can ask instead of guessing. }
    Check(TSecretUser.Meta.IsHidden('password_hash'), 'the meta says so');
    Check(not TSecretUser.Meta.IsHidden('email'), 'and only about those');
  finally
    UseArena(PrevA);
    A.Free;
  end;
end;

class procedure TTestCustomer.Describe(S: TSchema);
begin
  S.Table('testcustomers');
end;

procedure TTestCustomer.Rules(V: TValidator);
begin
  V.Field('Name').Required.MaxLen(10);
  V.Field('Email').Required.Email;
  V.Field('EmailAgain').SameAs('Email').Says('The emails do not match');
  V.Field('Balance').Min(0).Max(1000);
  V.Field('Status').OneOf(['new', 'active', 'blocked']);
end;

procedure TestValidering;
var
  A: TArena;
  PrevA: TArena;
  K: TTestCustomer;
  W: TJsonWriter;
begin
  Group('Validation');
  A := TArena.Create(32 * 1024);
  PrevA := UseArena(A);
  try
    { Alt riktig. }
    K := A.New<TTestCustomer>;
    K.Name := 'Knut';
    K.Email := 'kh@gets.no';
    K.EmailAgain := 'kh@gets.no';
    K.Balance := 500;
    K.Status := 'active';
    Check(K.Validate, 'a valid model passes');
    Check(K.Errors.IsEmpty, 'no errors');

    { Tomt navn. }
    A.Reset;
    K := A.New<TTestCustomer>;
    K.Email := 'kh@gets.no';
    K.EmailAgain := 'kh@gets.no';
    K.Status := 'new';
    Check(not K.Validate, 'an empty required field fails');
    Check(K.Errors.Has('name'), 'the error is keyed on the column name');
    Check(not K.Errors.Has('email_again'),
      'fields without errors are not listed');
    CheckEqS(K.Errors.First('name'), 'name is required', 'the message');

    { Only the first error per field. }
    A.Reset;
    K := A.New<TTestCustomer>;
    K.Name := 'a far too long name that does not fit';
    K.Email := 'ikke-en-email';
    K.EmailAgain := 'something-else';
    K.Status := 'new';
    Check(not K.Validate, 'several errors');
    CheckEqI(K.Errors.Count, 3, 'én feil per felt, ikke flere');
    CheckEqS(K.Errors.First('name'), 'name can be at most 10 characters', 'MaxLen');
    CheckEqS(K.Errors.First('email'), 'email is not a valid email address',
      'Email');
    CheckEqS(K.Errors.First('email_again'), 'The emails do not match',
      'Says overrides the message');

    { Tallgrenser. }
    A.Reset;
    K := A.New<TTestCustomer>;
    K.Name := 'Knut';
    K.Email := 'kh@gets.no';
    K.EmailAgain := 'kh@gets.no';
    K.Balance := 2000;
    K.Status := 'active';
    Check(not K.Validate, 'over the maximum it fails');
    Check(Pos('greater than', K.Errors.First('balance')) > 0, 'the Max message');

    A.Reset;
    K := A.New<TTestCustomer>;
    K.Name := 'Knut';
    K.Email := 'kh@gets.no';
    K.EmailAgain := 'kh@gets.no';
    K.Balance := 100;
    K.Status := 'unknown';
    Check(not K.Validate, 'a value outside OneOf fails');
    Check(K.Errors.Has('status'), 'OneOf');

    { Email validation is deliberately generous, but not empty. }
    A.Reset;
    K := A.New<TTestCustomer>;
    K.Name := 'Knut';
    K.EmailAgain := '';
    K.Balance := 0;
    K.Status := 'new';
    K.Email := 'a@b.no';
    K.EmailAgain := 'a@b.no';
    Check(K.Validate, 'a short but valid address');
    A.Reset;
    K := A.New<TTestCustomer>;
    K.Name := 'Knut';
    K.Status := 'new';
    K.Email := 'a@b';
    K.EmailAgain := 'a@b';
    Check(not K.Validate, 'an address with no full stop in the domain is rejected');

    { Feilene som JSON — formen Inertia forventer i props.errors. }
    A.Reset;
    K := A.New<TTestCustomer>;
    K.Status := 'new';
    K.Validate;
    W.Init(A, 256);
    K.Errors.WriteJson(W);
    Check(Pos('"name":"name is required"', W.ToString) > 0,
      'WriteJson gives field to message');
    Check(Pos('"email"', W.ToString) > 0, 'several fields included');
  finally
    UseArena(PrevA);
    A.Free;
  end;
end;

{ ---------------------------------------------------------------- binding -- }

function MakeRequestWithBody(A: TArena; const Head, Body_: string): TRequest;
var
  Prev: TArena;
begin
  Prev := UseArena(A);
  try
    Result := TRequest.Create;
    Result.ParseHead(StrDup(A, Head), DefaultMaxBodyBytes);
    Result.SetBody(StrDup(A, Body_));
  finally
    UseArena(Prev);
  end;
end;

procedure TestBinding;
var
  A: TArena;
  PrevA: TArena;
  Req: TRequest;
  K: TTestCustomer;
  Msg: string;
begin
  Group('Binding');
  A := TArena.Create(32 * 1024);
  PrevA := UseArena(A);
  try
    { JSON-kropp. }
    Req := MakeRequestWithBody(A,
      'POST /customers HTTP/1.1'#13#10'Host: t'#13#10 +
      'Content-Type: application/json'#13#10'Content-Length: 99',
      '{"name":"Knut","email":"kh@gets.no","balance":1234.50,"status":"active"}');
    K := A.New<TTestCustomer>;
    Req.FillInto(K);
    CheckEqS(K.Name, 'Knut', 'streng fra JSON');
    CheckEqS(K.Email, 'kh@gets.no', 'email fra JSON');
    Check(K.Balance = 1234.5, 'Currency fra JSON');
    CheckEqS(K.Status, 'active', 'status fra JSON');

    { The primary key is never filled, whatever the client sends. }
    A.Reset;
    Req := MakeRequestWithBody(A,
      'POST /customers HTTP/1.1'#13#10'Host: t'#13#10 +
      'Content-Type: application/json'#13#10'Content-Length: 30',
      '{"id":999,"name":"Forsøk"}');
    K := A.New<TTestCustomer>;
    K.Id := 7;
    Req.FillInto(K);
    CheckEqI(K.Id, 7, 'id cannot be set from a request');
    CheckEqS(K.Name, 'Forsøk', 'but the rest is filled');

    { Skjemakropp. }
    A.Reset;
    Req := MakeRequestWithBody(A,
      'POST /customers HTTP/1.1'#13#10'Host: t'#13#10 +
      'Content-Type: application/x-www-form-urlencoded'#13#10 +
      'Content-Length: 40',
      'name=Ada+Lovelace&email=ada%40gets.no&balance=99.95');
    K := A.New<TTestCustomer>;
    Req.FillInto(K);
    CheckEqS(K.Name, 'Ada Lovelace', 'plus becomes a space in a form');
    CheckEqS(K.Email, 'ada@gets.no', 'percent encoding is decoded');
    Check(K.Balance = 99.95, 'Currency fra skjema');

    { Query-streng. }
    A.Reset;
    Req := MakeRequest(A, 'GET /customers?name=Grace&balance=5 HTTP/1.1'#13#10'Host: t');
    K := A.New<TTestCustomer>;
    Req.FillInto(K);
    CheckEqS(K.Name, 'Grace', 'fra query');
    Check(K.Balance = 5, 'tall fra query');

    { Partial: fields that were not sent are left alone. }
    A.Reset;
    Req := MakeRequestWithBody(A,
      'PATCH /customers/1 HTTP/1.1'#13#10'Host: t'#13#10 +
      'Content-Type: application/json'#13#10'Content-Length: 20',
      '{"balance":42}');
    K := A.New<TTestCustomer>;
    K.Name := 'Unchanged';
    K.Email := 'unchanged@example.com';
    Req.FillInto(K);
    Check(K.Balance = 42, 'a sent field is updated');
    CheckEqS(K.Name, 'Unchanged', 'a field that was not sent is untouched');
    CheckEqS(K.Email, 'unchanged@example.com', 'and the second one too');

    { **Only the columns named.** The one-argument form fills whatever a
      client sends that the model maps; a form that has two fields should
      not let a third be set by adding it to the body. }
    A.Reset;
    Req := MakeRequestWithBody(A,
      'PUT /customers/1 HTTP/1.1'#13#10'Host: t'#13#10 +
      'Content-Type: application/json'#13#10'Content-Length: 60',
      '{"name":"Ada","email":"forged@example.com","balance":1}');
    K := A.New<TTestCustomer>;
    K.Email := 'kept@example.com';
    Req.FillInto(K, ['name', 'balance']);
    CheckEqS(K.Name, 'Ada', 'a named column is filled');
    Check(K.Balance = 1, 'and the other named one');
    CheckEqS(K.Email, 'kept@example.com',
      'a column that was sent but not named is left alone');

    Msg := '';
    try
      Req.FillInto(K, ['name', 'nmae']);
    except
      on E: EModelError do
        Msg := E.Message;
    end;
    Check(Pos('nmae', Msg) > 0,
      'a name the model does not map raises, and says which');

    { Input og HasInput. }
    A.Reset;
    Req := MakeRequestWithBody(A,
      'POST /x HTTP/1.1'#13#10'Host: t'#13#10 +
      'Content-Type: application/json'#13#10'Content-Length: 40',
      '{"a":"en","b":2,"c":true,"d":null}');
    Check(Req.HasInput('a'), 'HasInput finds the field');
    Check(not Req.HasInput('z'), 'and not one that is missing');
    CheckEqS(Req.Input('a').ToString, 'en', 'Input gives the string');
    CheckEqI(Req.InputInt('b'), 2, 'InputInt');
    Check(Req.InputBool('c'), 'InputBool');
    Check(not Req.InputBool('z', False), 'a default when the field is missing');
  finally
    UseArena(PrevA);
    A.Free;
  end;
end;

{ ------------------------------------------------------------------ norn -- }

function Sql(S: TSchemaBuilder; Index: Integer): string;
var
  A: TStringArray;
begin
  A := S.ToSql;
  if (Index < 0) or (Index > High(A)) then
    Exit('(no statement ' + IntToStr(Index) + ')');
  Result := A[Index];
end;

function SqlCount(S: TSchemaBuilder): Integer;
begin
  Result := Length(S.ToSql);
end;

procedure TestNornSchema;
var
  S: TSchemaBuilder;
  Cur: Currency;
begin
  Group('Norn — the schema builder');

  S := TSchemaBuilder.Create(sdPostgres);
  try
    with S.Create('customers') do
    begin
      Id;
      Text('name', 120);
      Text('email', 255).Unique;
      Money('balance').Default(0);
      Timestamps;
      Index(['created_at']);
    end;
    CheckEqI(SqlCount(S), 2, 'CREATE TABLE plus one index');
    CheckEqS(Sql(S, 0),
      'CREATE TABLE "customers" ("id" BIGSERIAL PRIMARY KEY, ' +
      '"name" VARCHAR(120) NOT NULL, "email" VARCHAR(255) NOT NULL UNIQUE, ' +
      '"balance" NUMERIC(12,2) NOT NULL DEFAULT 0, ' +
      '"created_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP, ' +
      '"updated_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP)',
      'the PRD''s migration gives this SQL');
    CheckEqS(Sql(S, 1),
      'CREATE INDEX "customers_created_at_idx" ON "customers" ("created_at")',
      'the index gets a derived name');
  finally
    S.Free;
  end;

  { Samme migrasjon, andre dialekter. }
  S := TSchemaBuilder.Create(sdMySql);
  try
    with S.Create('t') do
    begin
      Id;
      Bool('flag').Default(True);
      Timestamp('at');
    end;
    Check(Pos('`t`', Sql(S, 0)) > 0, 'MySQL quotes with a backtick');
    Check(Pos('BIGINT AUTO_INCREMENT', Sql(S, 0)) > 0, 'the MySQL auto key');
    Check(Pos('TINYINT(1)', Sql(S, 0)) > 0, 'MySQL has no BOOLEAN');
    Check(Pos('DATETIME', Sql(S, 0)) > 0, 'a MySQL timestamp');
  finally
    S.Free;
  end;

  S := TSchemaBuilder.Create(sdSqlite);
  try
    with S.Create('t') do
    begin
      Id;
      Bool('flag');
      Timestamp('at');
    end;
    Check(Pos('"id" INTEGER PRIMARY KEY', Sql(S, 0)) > 0,
      'SQLite uses INTEGER as the auto key');
    { SQLite has no date type and stores text anyway. But the declared
      type is what the introspection reads, and with TEXT it could not tell
      a date from any other string — then askr schema typed created_at as
      string against SQLite and as TDateTime against Postgres, from the
      same migration. DATETIME gives NUMERIC affinity, and an ISO text
      cannot be converted losslessly to a number, so the storage is
      unchanged. }
    Check(Pos('"at" DATETIME', Sql(S, 0)) > 0,
      'SQLite declares DATETIME, so the introspection sees what it is');
  finally
    S.Free;
  end;

  { A foreign key, ALTER and DROP. }
  S := TSchemaBuilder.Create(sdPostgres);
  try
    with S.Create('orders') do
      ForeignKey('customer_id', 'customers');
    Check(Pos('REFERENCES "customers"("id") ON DELETE CASCADE', Sql(S, 0)) > 0,
      'a foreign key with ON DELETE');
  finally
    S.Free;
  end;

  S := TSchemaBuilder.Create(sdPostgres);
  try
    with S.Alter('customers') do
    begin
      Bool('active').Default(True);
      DropColumn('old');
    end;
    CheckEqS(Sql(S, 0),
      'ALTER TABLE "customers" ADD COLUMN "active" BOOLEAN NOT NULL DEFAULT true',
      'ALTER ADD COLUMN');
    CheckEqS(Sql(S, 1),
      'ALTER TABLE "customers" DROP COLUMN "old"', 'ALTER DROP COLUMN');
  finally
    S.Free;
  end;

  S := TSchemaBuilder.Create(sdPostgres);
  try
    S.Drop('old');
    CheckEqS(Sql(S, 0), 'DROP TABLE IF EXISTS "old"', 'DROP TABLE');
  finally
    S.Free;
  end;

  { Nullable og standardverdier. }
  S := TSchemaBuilder.Create(sdPostgres);
  try
    with S.Create('t') do
    begin
      Text('a').Nullable;
      Text('b').Default('hei');
      Text('c').Default('med''fnutt');
      Cur := 1.5;
      Numeric('d', 8, 4).Default(Cur);
    end;
    Check(Pos('"a" TEXT DEFAULT', Sql(S, 0)) = 0, 'nullable does not give NOT NULL');
    Check(Pos('"b" TEXT NOT NULL DEFAULT ''hei''', Sql(S, 0)) > 0,
      'a text value is quoted');
    Check(Pos('''med''''fnutt''', Sql(S, 0)) > 0, 'a quote in the value is doubled');
    Check(Pos('"d" NUMERIC(8,4) NOT NULL DEFAULT 1.5000', Sql(S, 0)) > 0,
      'Currency is formatted without a locale');
  finally
    S.Free;
  end;
end;

procedure TestNornNaming;
begin
  Group('Norn — naming conventions');

  CheckEqS(PascalCase('customers'), 'Customers', 'a simple name');
  CheckEqS(PascalCase('order_lines'), 'OrderLines', 'snake_case');
  CheckEqS(PascalCase('created_at'), 'CreatedAt', 'column names');
  CheckEqS(PascalCase('id'), 'Id', 'a short name');
  CheckEqS(TableTypeName('customers'), 'TCustomersColumns', 'the type name');
  CheckEqS(TableConstName('order_lines'), 'OrderLines', 'the constant name');
  CheckEqS(MemberName('created_at'), 'CreatedAt', 'the member name');
  { A column name that collides with a reserved word has to be escaped. }
  CheckEqS(MemberName('type'), 'Type_', 'a reserved word gets an underscore');
  CheckEqS(MemberName('end'), 'End_', 'end likewise');
  CheckEqS(MemberName('name'), 'Name', 'name is not reserved');

  CheckEqS(ColAliasFor('bigint', 0), 'TColInt64', 'bigint');
  CheckEqS(ColAliasFor('integer', 0), 'TColInt64', 'integer');
  CheckEqS(ColAliasFor('text', 0), 'TColStr', 'text');
  CheckEqS(ColAliasFor('character varying', 0), 'TColStr', 'varchar');
  CheckEqS(ColAliasFor('boolean', 0), 'TColBool', 'boolean');
  CheckEqS(ColAliasFor('numeric', 2), 'TColCurrency', 'numeric with two decimals');
  CheckEqS(ColAliasFor('numeric', 8), 'TColFloat',
    'more decimals than Currency handles become a float');
  CheckEqS(ColAliasFor('double precision', 0), 'TColFloat', 'double');
  CheckEqS(ColAliasFor('timestamp with time zone', 0), 'TColDateTime',
    'timestamptz');
  CheckEqS(ColAliasFor('date', 0), 'TColDateTime', 'date');
  CheckEqS(ColAliasFor('jsonb', 0), 'TColStr', 'jsonb is treated as text');

  CheckEqS(PascalTypeFor('numeric', 2), 'Currency', 'Pascal-type for penger');
  CheckEqS(PascalTypeFor('bigint', 0), 'Int64', 'Pascal-type for bigint');
  CheckEqS(PascalTypeFor('timestamp with time zone', 0), 'TDateTime',
    'Pascal-type for tidsstempel');
end;

{ ----------------------------------------------------------------- cache -- }

procedure TestCache;
var
  C: TCache;
  A, B: TArena;
  V: TStr;
  S: string;
  I: Integer;
  Fill: PByte;
  Found: Integer;
begin
  Group('Cache');
  C := TCache.Create(256, 8);
  A := TArena.Create(16 * 1024);
  B := TArena.Create(16 * 1024);
  try
    C.Put('a', 'value a');
    Check(C.Get(A, 'a', V), 'Get finds what was put in');
    CheckEqS(V.ToString, 'value a', 'the right value');
    Check(not C.Get(A, 'does-not-exist', V), 'an unknown key gives False');
    Check(C.Has('a'), 'Has');
    CheckEqI(C.Count, 1, 'én post');

    { This is the question itself. The value is put in from an arena, the
      arena is reset and written full of something else, and the value has
      to still be right. Without the copy in Put it would be rubbish
      here. }
    A.Reset;
    V := StrDup(A, 'fra request-arenaen');
    C.Put('fra-arena', V);
    A.Reset;
    Fill := PByte(A.Alloc(8192));
    FillChar(Fill^, 8192, Ord('X'));
    Check(C.Get(B, 'fra-arena', V), 'the entry is there after Reset');
    CheckEqS(V.ToString, 'fra request-arenaen',
      'Put copied out of the arena — the value survived');

    { And the other way: what Get gave back is in the caller's arena, not
      in the cache. Then the cache can evict the entry without leaving a
      dangling pointer. }
    C.Forget('fra-arena');
    CheckEqS(V.ToString, 'fra request-arenaen',
      'the value lives on after the entry was evicted');
    Check(not C.Has('fra-arena'), 'and the entry really is gone');

    { Expiry. }
    C.Put('kort', 'lives briefly', 1);
    Check(C.Has('kort'), 'is there at once');
    C.Put('lang', 'lives long', 3600);
    Check(C.Has('lang'), 'a long TTL');

    { LRU: fill the shard until it evicts. }
    C.Flush;
    for I := 1 to 2000 do
      C.Put('n' + IntToStr(I), 'v' + IntToStr(I));
    Check(C.Count <= 256, 'the cache stays within its limit');
    Check(C.Evictions > 0, 'and evicted what it had to');
    Found := 0;
    for I := 1990 to 2000 do
      if C.Get(A, 'n' + IntToStr(I), V) then
        Inc(Found);
    Check(Found >= 8, 'the most recently written are mostly kept');

    C.Flush;
    CheckEqI(C.Count, 0, 'Flush empties it');

    { Strengformen for oppstartskode og bakgrunnsjobber. }
    C.Put('s', 'text');
    Check(C.Get('s', S) and (S = 'text'), 'the string form works');

    Check(C.Hits > 0, 'hits are counted');
    Check(C.Misses > 0, 'misses are counted');
  finally
    A.Free;
    B.Free;
    C.Free;
  end;
end;

{ ----------------------------------------------------------------- queue -- }

var
  QSum: LongInt = 0;
  QLast: string = '';
  QAttempts: LongInt = 0;
  QFeilmeldinger: LongInt = 0;
  QLock: TRTLCriticalSection;

procedure JobCount(const Ctx: TJobContext);
var
  N: Int64;
begin
  if Ctx.Payload.ToInt64(N) then
    InterLockedExchangeAdd(QSum, LongInt(N));
end;

procedure JobRemember(const Ctx: TJobContext);
begin
  EnterCriticalSection(QLock);
  try
    QLast := Ctx.Payload.ToString;
  finally
    LeaveCriticalSection(QLock);
  end;
end;

{ Fails the first two times, succeeds on the third. }
procedure JobFlaky(const Ctx: TJobContext);
begin
  InterLockedIncrement(QAttempts);
  if Ctx.Attempt < 3 then
    raise Exception.Create('not yet');
end;

procedure JobAlwaysFails(const Ctx: TJobContext);
begin
  raise Exception.Create('always');
end;

procedure CountFail(const JobName, Message_: string);
begin
  InterLockedIncrement(QFeilmeldinger);
end;

{ Uses its arena the way a controller would. }
procedure JobUsesArena(const Ctx: TJobContext);
var
  B: TStrBuilder;
begin
  B.Init(Ctx.Arena, 128);
  B.Append('job:');
  B.Append(Ctx.Payload);
  EnterCriticalSection(QLock);
  try
    QLast := B.ToString;
  finally
    LeaveCriticalSection(QLock);
  end;
end;

{ ------------------------------------------------- modell-livskvalitet -- }

var
  MlHendelser: string;
  MlSlugFromHook: string;

type
  { A model with timestamps, soft deletes and events. }
  TMlPost = class(TModel)
  private
    FId: Int64;
    FTitle: string;
    FSlug: string;
    FCreatedAt: TDateTime;
    FUpdatedAt: TDateTime;
    FDeletedAt: TDateTime;
  published
    property Id: Int64 read FId write FId;
    property Title: string read FTitle write FTitle;
    property Slug: string read FSlug write FSlug;
    property CreatedAt: TDateTime read FCreatedAt write FCreatedAt;
    property UpdatedAt: TDateTime read FUpdatedAt write FUpdatedAt;
    property DeletedAt: TDateTime read FDeletedAt write FDeletedAt;
  public
    class procedure Describe(S: TSchema); override;
    procedure BeforeSave; override;
    procedure AfterSave; override;
    procedure BeforeInsert; override;
    procedure AfterInsert; override;
    procedure BeforeUpdate; override;
    procedure AfterUpdate; override;
    procedure BeforeDelete; override;
    procedure AfterDelete; override;
  end;

  { The same table, but without timestamps and soft deletes — to show that
    what is meant to raise, raises. }
  TMlBar = class(TModel)
  private
    FId: Int64;
    FTitle: string;
  published
    property Id: Int64 read FId write FId;
    property Title: string read FTitle write FTitle;
  public
    class procedure Describe(S: TSchema); override;
  end;

class procedure TMlPost.Describe(S: TSchema);
begin
  S.Table('ml_posts');
  S.Timestamps;
  S.SoftDeletes;
end;

class procedure TMlBar.Describe(S: TSchema);
begin
  S.Table('ml_posts');
end;

{ The events record themselves, so that the order can be asserted. }
procedure TMlPost.BeforeSave;
begin
  MlHendelser := MlHendelser + 'BS,';
  { An event is to be able to change the model before it is written. That
    is the most common use: deriving one field from another. }
  if FSlug = '' then
    FSlug := LowerCase(StringReplace(FTitle, ' ', '-', [rfReplaceAll]));
  MlSlugFromHook := FSlug;
end;

procedure TMlPost.AfterSave;   begin MlHendelser := MlHendelser + 'AS,'; end;
procedure TMlPost.BeforeInsert; begin MlHendelser := MlHendelser + 'BI,'; end;
procedure TMlPost.AfterInsert;  begin MlHendelser := MlHendelser + 'AI,'; end;
procedure TMlPost.BeforeUpdate; begin MlHendelser := MlHendelser + 'BU,'; end;
procedure TMlPost.AfterUpdate;  begin MlHendelser := MlHendelser + 'AU,'; end;
procedure TMlPost.BeforeDelete; begin MlHendelser := MlHendelser + 'BD,'; end;
procedure TMlPost.AfterDelete;  begin MlHendelser := MlHendelser + 'AD,'; end;

{ "Query scopes" require nothing of the framework in Pascal: a scope is
  a function that returns a query. It is typed, the compiler sees it, and
  it can be chained like everything else.

  It stands as a standalone function and not as a class method on TMlPost,
  because a method returning TQuery<TMlPost> would forward-reference its
  own class type. That is the same limit that applies to TModelList<M>. }
function NyestePoster(Count_: Integer): TQuery<TMlPost>;
begin
  Result := TQuery<TMlPost>.New
    .OrderBy(ColDateTime('ml_posts', 'created_at'), Desc)
    .Limit(Count_);
end;

{ Rows in the table regardless of deleted_at — the point is to see that
  a soft-deleted row is still there. }
function MlRawCount(C: TDbConnection; A: TArena): Int64;
var
  R: TDbResult;
begin
  R := C.Exec(A, 'SELECT count(*) FROM ml_posts');
  Result := R.AsInt64(0, 0);
end;

procedure TestModellLivskvalitet;
var
  A, PrevA: TArena;
  C: TDbConnection;
  PrevDb: TDbConnection;
  S: TSchemaBuilder;
  Stmts: TStringArray;
  I: Integer;
  P: TMlPost;
  Made, Oppdatert: TDateTime;
  Items: TModelList<TMlPost>;
  Schema_: TDbSchema;
  Tab: TDbTable;
  Err: string;
begin
  Group('Model: timestamps, soft deletes, events');
  if not SqliteAvailable then
  begin
    Check(False, 'libsqlite3 loaded');
    Exit;
  end;

  A := TArena.Create(64 * 1024);
  PrevA := UseArena(A);
  C := OpenDbConnection('sqlite::memory:');
  PrevDb := UseDb(C);
  try
    S := TSchemaBuilder.Create(C.Dialect);
    try
      with S.Create('ml_posts') do
      begin
        Id;
        Text('title', 120);
        Text('slug', 120).Nullable;
        Timestamp('created_at').Nullable;
        Timestamp('updated_at').Nullable;
        Timestamp('deleted_at').Nullable;
      end;
      Stmts := S.ToSql;
      for I := 0 to High(Stmts) do
        C.Exec(A, Stmts[I]);
    finally
      S.Free;
    end;

    { ---- tidsstempler ---- }
    MlHendelser := '';
    P := A.New<TMlPost>;
    P.Title := 'First post';
    P.Save;
    Made := P.CreatedAt;
    Check(Made > 0, 'created_at was set on INSERT');
    Check(P.UpdatedAt > 0, 'updated_at too');
    { UTC, not local time: two servers in different zones are to write the
      same thing for the same moment. The tolerance is one minute. }
    Check(Abs(P.CreatedAt - UtcNow) < 1 / (24 * 60),
      'and they are in UTC, not local time');

    { The events in the right order, and BeforeSave got to change the
      model. }
    CheckEqS(MlHendelser, 'BS,BI,AI,AS,', 'the events on INSERT');
    CheckEqS(P.Slug, 'first-post', 'BeforeSave got to change the model');

    Sleep(1100);
    MlHendelser := '';
    P.Title := 'Changed';
    P.Save;
    Oppdatert := P.UpdatedAt;
    CheckEqS(MlHendelser, 'BS,BU,AU,AS,', 'the events on UPDATE');
    Check(P.CreatedAt = Made, 'created_at is left alone on UPDATE');
    Check(Oppdatert > Made, 'but updated_at moves');

    { An import that preserves original timestamps must not have them
      overwritten. }
    P := A.New<TMlPost>;
    P.Title := 'Imported';
    P.CreatedAt := EncodeDate(2020, 1, 1);
    P.Save;
    Check(Abs(P.CreatedAt - EncodeDate(2020, 1, 1)) < 0.0001,
      'a created_at that is already set is kept');

    { ---- soft deletes ---- }
    CheckEqI(TQuery<TMlPost>.New.Count, 2, 'to poster synlige');
    CheckEqI(MlRawCount(C, A), 2, 'and two rows in the table');

    MlHendelser := '';
    P.Delete;
    CheckEqS(MlHendelser, 'BD,AD,', 'the events on DELETE');
    Check(P.IsTrashed, 'modellen vet at den er slettet');
    { This is the whole point: the row is there, but the queries do not see
      it. }
    CheckEqI(MlRawCount(C, A), 2, 'the row is still in the table');
    CheckEqI(TQuery<TMlPost>.New.Count, 1, 'but the query does not see it');
    CheckEqI(TQuery<TMlPost>.New.WithTrashed.Count, 2,
      'WithTrashed includes it');
    CheckEqI(TQuery<TMlPost>.New.OnlyTrashed.Count, 1,
      'OnlyTrashed shows only that one');

    { A filter is to work together with the soft-delete clause, not instead
      of it. }
    CheckEqI(TQuery<TMlPost>.New
      .Where(ColStr('ml_posts', 'title'), Eq, 'Imported').Count, 0,
      'a filter combines with the soft-delete clause');
    CheckEqI(TQuery<TMlPost>.New.WithTrashed
      .Where(ColStr('ml_posts', 'title'), Eq, 'Imported').Count, 1,
      'and with WithTrashed it finds the row');

    P.Restore;
    Check(not P.IsTrashed, 'Restore brought it back');
    CheckEqI(TQuery<TMlPost>.New.Count, 2, 'and it is visible again');

    { ---- at the query level ---- }
    CheckEqI(TQuery<TMlPost>.New.DeleteAll, 2,
      'DeleteAll deletes softly when the model has soft deletes');
    CheckEqI(MlRawCount(C, A), 2, 'the rows are still there');
    CheckEqI(TQuery<TMlPost>.New.Count, 0, 'but none is visible');
    CheckEqI(TQuery<TMlPost>.New.RestoreAll, 2, 'RestoreAll brings them back');
    CheckEqI(TQuery<TMlPost>.New.Count, 2, 'og de er synlige');

    CheckEqI(TQuery<TMlPost>.New.ForceDeleteAll, 2,
      'ForceDeleteAll deletes for good');
    CheckEqI(MlRawCount(C, A), 0, 'og da er tabellen tom');

    { ForceDelete on a single model. }
    P := A.New<TMlPost>;
    P.Title := 'Skal bort';
    P.Save;
    CheckEqI(MlRawCount(C, A), 1, 'én rad');
    P.ForceDelete;
    CheckEqI(MlRawCount(C, A), 0, 'ForceDelete removed it');

    { ---- what is meant to raise ---- }
    Err := '';
    try
      TMlBar.Meta;
      P := A.New<TMlPost>;
      P.Title := 'x';
      P.Save;
      TQuery<TMlBar>.New.Count;
      { A model without SoftDeletes has nothing to restore. }
      A.New<TMlBar>.Restore;
    except
      on E: EModelError do Err := E.Message;
    end;
    Check(Pos('no soft deletes', Err) > 0,
      'Restore without SoftDeletes raises, and says what is missing');

    { A model without deleted_at sees every row — the soft-delete clause is
      added only when the model actually has it. }
    CheckEqI(TQuery<TMlBar>.New.Count, 1,
      'a model without soft deletes filters nothing');

    Items := TQuery<TMlPost>.New.Get;
    CheckEqI(Items.Count, 1, 'Get works with the soft-delete clause on');

    { ---- tidsstempler overlever rundturen ---- }
    { What actually matters about DATETIME in SQLite: that the
      introspection sees a date, and that the value comes back as a date.
      Without both, the declared type is only decoration. }
    Schema_ := IntrospectSchema(C);
    try
      Tab := Schema_.Table('ml_posts');
      Check(Tab <> nil, 'the table was introspected');
      CheckEqS(PascalTypeFor(
        Tab.Column(Tab.IndexOfColumn('created_at')).SqlType,
        Tab.Column(Tab.IndexOfColumn('created_at')).Scale), 'TDateTime',
        'created_at is introspected as TDateTime, not string');
    finally
      Schema_.Free;
    end;

    P := TQuery<TMlPost>.New.WithTrashed.Get[0];
    Check(P.CreatedAt > EncodeDate(2020, 1, 1),
      'and the value came back as a real date from the database');

    { ---- query scopes ---- }
    P := A.New<TMlPost>;
    P.Title := 'Nyere';
    { created_at is set explicitly. The SQL timestamp has second
      resolution, and two rows made in the same second have no defined
      order — the test would then be green or red depending on how fast the
      machine was. }
    P.CreatedAt := UtcNow + 1;
    P.Save;
    Items := NyestePoster(1).Get;
    CheckEqI(Items.Count, 1, 'a scope is only a function that gives a query');
    CheckEqS(Items[0].Title, 'Nyere', 'and it can be sorted and limited');
    { A scope can be chained on, and the soft-delete clause comes along. }
    CheckEqI(NyestePoster(10).WithTrashed.Count, 2,
      'and it chains on like everything else');
  finally
    UseDb(PrevDb);
    C.Free;
    UseArena(PrevA);
    A.Free;
  end;
end;

procedure TestQueue;
var
  Q: TQueue;
  A: TArena;
  I: Integer;
  V: TStr;
  Fill: PByte;
  Frist: Integer;
begin
  Group('Queue');
  InitCriticalSection(QLock);
  A := TArena.Create(16 * 1024);
  Q := TQueue.Create(3, 3);
  try
    Q.Handle('tell', @JobCount);
    Q.Handle('husk', @JobRemember);
    Q.Handle('flaky', @JobFlaky);
    Q.Handle('always-fails', @JobAlwaysFails);
    Q.Handle('arena', @JobUsesArena);
    Q.OnError := @CountFail;
    Q.Start;

    { A hundred jobs from the main thread, three workers. }
    QSum := 0;
    for I := 1 to 100 do
      Q.Push('tell', IntToStr(I));
    Check(Q.WaitUntilEmpty(5000), 'the queue drained');
    Sleep(50);
    CheckEqI(QSum, 5050, 'all hundred jobs ran, and only once each');
    CheckEqI(Q.Processed, 100, 'Processed counts correctly');

    { The same question as for the cache, but worse: the job runs after the
      request is gone. The payload is put in an arena, the arena is reset
      and written over, and the job still has to see the right content. }
    A.Reset;
    V := StrDup(A, 'a payload from the request');
    QLast := '';
    Q.Push('husk', V);
    A.Reset;
    Fill := PByte(A.Alloc(8192));
    FillChar(Fill^, 8192, Ord('Z'));
    Check(Q.WaitUntilEmpty(5000), 'the job was taken');
    Sleep(80);
    EnterCriticalSection(QLock);
    try
      CheckEqS(QLast, 'a payload from the request',
        'Push copied out of the arena — the payload survived');
    finally
      LeaveCriticalSection(QLock);
    end;

    { The handler gets the payload in its own arena and can use it as
      usual. }
    QLast := '';
    Q.Push('arena', 'something');
    Check(Q.WaitUntilEmpty(5000), 'the arena job was taken');
    Sleep(80);
    EnterCriticalSection(QLock);
    try
      CheckEqS(QLast, 'job:something', 'the handler used its own arena');
    finally
      LeaveCriticalSection(QLock);
    end;

    { Forsinkelse. }
    QLast := '';
    Q.Push('husk', 'delayed', 1);
    Sleep(200);
    EnterCriticalSection(QLock);
    try
      CheckEqS(QLast, '', 'a delayed job does not run at once');
    finally
      LeaveCriticalSection(QLock);
    end;
    Check(Q.WaitUntilEmpty(4000), 'but it runs in time');
    Sleep(80);
    EnterCriticalSection(QLock);
    try
      CheckEqS(QLast, 'delayed', 'and with the right payload');
    finally
      LeaveCriticalSection(QLock);
    end;

    { Retry with backoff, then success. The same reason to wait on the
      number. }
    QAttempts := 0;
    Q.Push('flaky', 'x');
    Check(Q.WaitUntilEmpty(6000), 'the flaky job finished');
    Frist := 0;
    while (QAttempts < 3) and (Frist < 5000) do
    begin
      Sleep(20);
      Inc(Frist, 20);
    end;
    CheckEqI(QAttempts, 3, 'three attempts before it succeeded');
    Check(Q.Retried >= 2, 'two of them were retries');

    { Gives up after MaxAttempts.

      WaitUntilEmpty only says the queue is empty now, and a job waiting on
      backoff between two attempts is not in the queue. So it waits on
      Failed itself rather than on the clock: a fixed Sleep here was enough
      on a fast machine and too short in a container. }
    QFeilmeldinger := 0;
    Q.Push('always-fails', 'y');
    Check(Q.WaitUntilEmpty(6000), 'the failing job gave up');
    Frist := 0;
    while (Q.Failed < 1) and (Frist < 5000) do
    begin
      Sleep(20);
      Inc(Frist, 20);
    end;
    CheckEqI(Q.Failed, 1, 'counted as failed');
    Check(QFeilmeldinger >= 3, 'OnError was called for every attempt');

    { Unknown_ jobbnavn forkastes, ikke krasjer. }
    Q.Push('does-not-exist', 'z');
    Check(Q.WaitUntilEmpty(3000), 'an unknown job is discarded');
    Frist := 0;
    while (Q.Dropped < 1) and (Frist < 3000) do
    begin
      Sleep(20);
      Inc(Frist, 20);
    end;
    Check(Q.Dropped >= 1, 'and is counted');

    Q.Stop(True);
  finally
    Q.Free;
    A.Free;
    DoneCriticalSection(QLock);
  end;
end;

{ ---------------------------------------------------------------- sqlite -- }

type
  TSqOrder = class(TModel)
  private
    FId: Int64;
    FCustomerId: Int64;
    FSum: Currency;
  published
    property Id: Int64 read FId write FId;
    property CustomerId: Int64 read FCustomerId write FCustomerId;
    property Sum_: Currency read FSum write FSum;
  public
    class procedure Describe(S: TSchema); override;
  end;

  TSqOrderList = TModelList<TSqOrder>;

  TSqCustomer = class(TModel)
  private
    FId: Int64;
    FName: string;
    FEmail: string;
    FBalance: Currency;
    FActive: Boolean;
  published
    Order: TSqOrderList;
    property Id: Int64 read FId write FId;
    property Name: string read FName write FName;
    property Email: string read FEmail write FEmail;
    property Balance: Currency read FBalance write FBalance;
    property Active: Boolean read FActive write FActive;
  public
    class procedure Describe(S: TSchema); override;
    procedure Rules(V: TValidator); override;
  end;

  TSqCustomerList = TModelList<TSqCustomer>;

class procedure TSqOrder.Describe(S: TSchema);
begin
  S.Table('sq_orders');
  S.Column('Sum_', 'sum');
  S.BelongsTo('Customer', TSqCustomer, 'customer_id');
end;

class procedure TSqCustomer.Describe(S: TSchema);
begin
  S.Table('sq_customers');
  S.HasMany('Order', TSqOrder, 'customer_id');
end;

procedure TSqCustomer.Rules(V: TValidator);
begin
  V.Field('Name').Required.MaxLen(60);
  V.Field('Email').Required.Email.UniqueIn('sq_customers');
end;

var
  SqCustomers: record
    Id: TColInt64;
    Name: TColStr;
    Email: TColStr;
    Balance: TColCurrency;
    Active: TColBool;
  end;
  SqOrders: record
    Id: TColInt64;
    CustomerId: TColInt64;
    Sum_: TColCurrency;
  end;

procedure SetUpColumns;
begin
  SqCustomers.Id := ColInt64('sq_customers', 'id');
  SqCustomers.Name := ColStr('sq_customers', 'name');
  SqCustomers.Email := ColStr('sq_customers', 'email');
  SqCustomers.Balance := ColCurrency('sq_customers', 'balance');
  SqCustomers.Active := ColBool('sq_customers', 'active');
  SqOrders.Id := ColInt64('sq_orders', 'id');
  SqOrders.CustomerId := ColInt64('sq_orders', 'customer_id');
  SqOrders.Sum_ := ColCurrency('sq_orders', 'sum');
end;

{ Reads one member out of a JSON document, through the real parser rather
  than by matching text. A substring check passes on a body that is not
  JSON at all, which is the failure being guarded against.

  The key may be a dotted path -- `meta.total` -- so a nested object can
  be asked about without a second helper. A member that is not there and
  a member that is an empty string both read as '', which is why the
  tests that care about the difference ask for the raw text as well. }
function ProblemMember(const Body_, Key: string): string;
var
  A: TArena;
  Root, V: PJsonValue;
  ErrAt: SizeInt;
  Rest, One: string;
  P: Integer;
begin
  A := TArena.Create(16 * 1024);
  try
    if not JsonParse(A, StrDup(A, Body_), Root, ErrAt) then
      Exit('<not json>');
    V := Root;
    Rest := Key;
    while Rest <> '' do
    begin
      P := Pos('.', Rest);
      if P = 0 then
      begin
        One := Rest;
        Rest := '';
      end
      else
      begin
        One := Copy(Rest, 1, P - 1);
        Rest := Copy(Rest, P + 1, MaxInt);
      end;
      V := JsonMember(V, One);
    end;
    Result := JsonAsString(V);
  finally
    A.Free;
  end;
end;

{ True when the document parses at all. A payload nobody can parse is the
  one failure a substring check never notices. }
function IsJson(const Body_: string): Boolean;
var
  A: TArena;
  Root: PJsonValue;
  ErrAt: SizeInt;
begin
  A := TArena.Create(16 * 1024);
  try
    Result := JsonParse(A, StrDup(A, Body_), Root, ErrAt);
  finally
    A.Free;
  end;
end;

{ ------------------------------------------------------ schema drift -- }

{ The gate for `askr schema:check`.

  The command was named in the header of every file `askr schema` has ever
  written, and it did not exist. The fingerprint it would have compared
  was in each file too, and nothing read it. So this holds down the four
  things the check has to tell apart, in both directions -- and that the
  promise in the header names commands that exist. }
function DriftKindOf(const D: TDrifts; const Name_: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(D) do
    if D[I].FileName = Name_ then
      Exit(Ord(D[I].Kind));
  Result := -1;
end;

function ReplaceInFile(const Path_, Old, New_: string): Boolean;
var
  L: TStringList;
  T: string;
begin
  L := TStringList.Create;
  try
    L.LoadFromFile(Path_);
    T := L.Text;
    Result := Pos(Old, T) > 0;
    L.Text := StringReplace(T, Old, New_, []);
    L.SaveToFile(Path_);
  finally
    L.Free;
  end;
end;

procedure TestSchemaDrift;
const
  Dir = '.build/drift-test';
  DbPath = '.build/drift-test/drift.sqlite';
  OutDir = '.build/drift-test/schema';
var
  C: TDbConnection;
  A, PrevA: TArena;
  Opts: TCodegenOptions;
  F: TGeneratedFiles;
  D: TDrifts;
  Removed, Bad: TStringArray;
  I, P, Q: Integer;
  Hdr, Cmd: string;
  Helper: TStringList;

  function Regen: TGeneratedFiles;
  var
    S: TDbSchema;
  begin
    S := IntrospectSchema(C);
    try
      Result := GenerateSources(S, Opts);
    finally
      S.Free;
    end;
  end;

begin
  Group('Schema drift');
  ForceDirectories(OutDir);
  DeleteFile(DbPath);
  DeleteFile(OutDir + '/App.Schema.Customers.pas');
  DeleteFile(OutDir + '/App.Schema.Orders.pas');
  DeleteFile(OutDir + '/App.Schema.Manifest.pas');
  DeleteFile(OutDir + '/App.Schema.Helpers.pas');

  A := TArena.Create(64 * 1024);
  PrevA := UseArena(A);
  C := OpenDbConnection('sqlite:' + DbPath);
  try
    Opts := DefaultCodegenOptions;
    Opts.OutputDir := OutDir;

    C.Exec(A, 'CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL)');
    { A table the framework owns. It was left off the skip list in 0.12.0,
      so every app that issued a token got App.Schema.ApiTokens for a
      table it never queries. }
    C.Exec(A, 'CREATE TABLE api_tokens (id INTEGER PRIMARY KEY, token_hash TEXT)');

    F := Regen;
    WriteSources(F, Opts);
    Check(not FileExists(OutDir + '/App.Schema.ApiTokens.pas'),
      'a table the framework owns gets no typed columns');
    D := FindDrift(F, Opts);
    CheckEqI(Length(D), 0, 'freshly written, nothing has drifted');

    { A file of the application's in the same directory. It is not Norn's,
      so it is not reported -- and below, not removed either. }
    Helper := TStringList.Create;
    try
      Helper.Add('unit App.Schema.Helpers;');
      Helper.Add('interface');
      Helper.Add('implementation');
      Helper.Add('end.');
      Helper.SaveToFile(OutDir + '/App.Schema.Helpers.pas');
    finally
      Helper.Free;
    end;
    D := FindDrift(F, Opts);
    CheckEqI(Length(D), 0, 'a file of the app''s own is none of this');

    { The table changes under the file. }
    C.Exec(A, 'ALTER TABLE customers ADD COLUMN email TEXT');
    F := Regen;
    D := FindDrift(F, Opts);
    CheckEqI(DriftKindOf(D, 'App.Schema.Customers.pas'), Ord(dkChanged),
      'a column added by hand is reported against its table');
    Check(DriftKindOf(D, 'App.Schema.Manifest.pas') = Ord(dkChanged),
      'and the manifest has changed with it');
    Check(Length(CheckDrift(F, Opts)) > 0, 'and it is drift that matters');
    WriteSources(F, Opts);
    CheckEqI(Length(CheckDrift(F, Opts)), 0, 'regenerating settles it');

    { A table with no file. }
    C.Exec(A, 'CREATE TABLE orders (id INTEGER PRIMARY KEY, total NUMERIC)');
    F := Regen;
    D := FindDrift(F, Opts);
    CheckEqI(DriftKindOf(D, 'App.Schema.Orders.pas'), Ord(dkMissing),
      'a new table with no typed columns is reported');
    WriteSources(F, Opts);

    { **And a file with no table.** The direction that was not checked at
      all: a dropped table left its file behind, and code using its
      columns went on compiling against a table that was gone. }
    C.Exec(A, 'DROP TABLE orders');
    F := Regen;
    D := FindDrift(F, Opts);
    CheckEqI(DriftKindOf(D, 'App.Schema.Orders.pas'), Ord(dkNoSuchTable),
      'a file for a dropped table is reported');
    Check(DriftMatters(dkNoSuchTable), 'and that matters');
    Removed := RemoveStaleSources(F, Opts);
    CheckEqI(Length(Removed), 1, 'askr schema removes it');
    Check(not FileExists(OutDir + '/App.Schema.Orders.pas'),
      'and it is gone');
    Check(FileExists(OutDir + '/App.Schema.Helpers.pas'),
      'while the app''s own file in the same directory is untouched');
    WriteSources(F, Opts);
    CheckEqI(Length(CheckDrift(F, Opts)), 0, 'and then nothing is left');

    { **A file written by an older askr schema.** Same table, same
      declarations, the header in the words it used before the language
      sweep. That is not the database drifting, and failing CI over it
      after every upgrade would teach people to ignore the check. }
    Check(ReplaceInFile(OutDir + '/App.Schema.Customers.pas',
      '{ GENERATED BY NORN - DO NOT EDIT.', '{ AUTOGENERERT AV NORN - IKKE REDIGER.'),
      'the header was found to rewrite');
    Check(ReplaceInFile(OutDir + '/App.Schema.Customers.pas',
      'Schema fingerprint: ', 'Skjemaavtrykk: '),
      'and the fingerprint line');
    D := FindDrift(F, Opts);
    CheckEqI(DriftKindOf(D, 'App.Schema.Customers.pas'), Ord(dkOlderTemplate),
      'an older header over the same declarations is told apart');
    CheckEqI(Length(CheckDrift(F, Opts)), 0, 'and does not fail the check');

    { A comment **inside** the declarations, reworded. The first run
      against a real project reported exactly this as "retyped" -- the
      manifest had a comment translated when the codebase went English,
      and no type had changed. And the alignment of a column: a template
      that lines things up differently has not typed anything
      differently. }
    WriteSources(F, Opts);
    Check(ReplaceInFile(OutDir + '/App.Schema.Manifest.pas',
      '{ Lookups at run time.', '{ Oppslag ved kjoring.'),
      'a comment in the manifest was found to reword');
    Check(ReplaceInFile(OutDir + '/App.Schema.Customers.pas',
      'const Name  : TColStr', 'const Name      :   TColStr'),
      'and a declaration was found to realign');
    D := FindDrift(F, Opts);
    CheckEqI(DriftKindOf(D, 'App.Schema.Manifest.pas'), Ord(dkOlderTemplate),
      'a reworded comment is not a retyping');
    CheckEqI(DriftKindOf(D, 'App.Schema.Customers.pas'), Ord(dkOlderTemplate),
      'and nor is wider alignment');
    CheckEqI(Length(CheckDrift(F, Opts)), 0, 'so neither fails the check');

    { **Retyped.** The fingerprint says the table is the same; the types
      below it say something else. That has happened -- SQLite's
      created_at was typed `string` while Postgres typed the same
      migration `TDateTime` -- and it is easy to wave through as "only a
      template change". It is not: code compiles against the old types. }
    WriteSources(F, Opts);
    Check(ReplaceInFile(OutDir + '/App.Schema.Customers.pas',
      ': TColStr   = (Name: ''name''', ': TColInt64 = (Name: ''name'''),
      'a declaration was found to change');
    D := FindDrift(F, Opts);
    CheckEqI(DriftKindOf(D, 'App.Schema.Customers.pas'), Ord(dkRetyped),
      'the same table typed differently is reported');
    Check(Length(CheckDrift(F, Opts)) > 0, 'and fails the check');
    WriteSources(F, Opts);

    { **The promise in the header names commands that exist.** It named
      one that did not for as long as the header has existed. Every
      `askr <word>` in it has to be something the binary answers to. }
    Hdr := F[0].Source;
    Hdr := Copy(Hdr, 1, Pos('unit ', Hdr));
    Bad := nil;
    P := Pos('`askr ', Hdr);
    I := 0;
    while P > 0 do
    begin
      Q := PosEx('`', Hdr, P + 1);
      Cmd := Trim(Copy(Hdr, P + 6, Q - P - 6));
      if Pos(' ', Cmd) > 0 then
        Cmd := Copy(Cmd, 1, Pos(' ', Cmd) - 1);
      Inc(I);
      if not IsConsoleCommand(Cmd) then
      begin
        SetLength(Bad, Length(Bad) + 1);
        Bad[High(Bad)] := Cmd;
      end;
      P := PosEx('`askr ', Hdr, Q + 1);
    end;
    Check(I >= 2, 'the header names the commands it relies on');
    CheckEqI(Length(Bad), 0, 'and every one of them exists');
  finally
    C.Free;
    UseArena(PrevA);
    A.Free;
  end;
end;

procedure PivotStart(const Name: string);
begin
  Group(Name);
end;

procedure PivotOk(const What: string; Cond: Boolean);
begin
  Check(Cond, What);
end;

{$I pivot.inc}

procedure TestSqlite;
var
  A: TArena;
  PrevA: TArena;
  PrevDb: TDbConnection;
  C: TDbConnection;
  S: TSchemaBuilder;
  Stmts: TStringArray;
  I, J: Integer;
  K: TSqCustomer;
  O: TSqOrder;
  Items: TSqCustomerList;
  Count_: Integer;
  Reservert: PtrUInt;
  Sq: TSqliteConnection;
  R2: TDbResult;
  ForPrep, ForHits: Int64;
  ForApne: Integer;
  Sql: string;
  G: TGrid<TSqCustomer>;
  Cust_: TSqCustomer;
  Reply2: TResponse;
  Q_: TQuery<TSqCustomer>;
  Raised_: Boolean;
  GW: TJsonWriter;
  GJson: string;
  Failed_: Boolean;
  T0, Without, With_: Int64;
  Kr: Integer;
  Cur: Currency;
begin
  Group('SQLite');

  if not SqliteAvailable then
  begin
    Check(False, 'libsqlite3 loaded');
    Exit;
  end;
  Check(True, 'libsqlite3 loaded with dlopen');
  Si2('the sqlite version', SqliteVersion);

  SetUpColumns;
  A := TArena.Create(64 * 1024);
  PrevA := UseArena(A);
  { No file, no server: the whole data layer is tested in memory. }
  C := OpenDbConnection('sqlite::memory:');
  PrevDb := UseDb(C);
  try
    Check(C.Dialect = sdSqlite, 'dialekten er sqlite');

    { A migration through the same schema builder Postgres uses. }
    S := TSchemaBuilder.Create(C.Dialect);
    try
      with S.Create('sq_customers') do
      begin
        Id;
        Text('name', 60);
        Text('email', 120).Unique;
        Money('balance').Default(0);
        Bool('active').Default(True);
      end;
      with S.Create('sq_orders') do
      begin
        Id;
        ForeignKey('customer_id', 'sq_customers');
        Money('sum').Default(0);
        Index(['customer_id']);
      end;
      Stmts := S.ToSql;
      for I := 0 to High(Stmts) do
        C.Exec(A, Stmts[I]);
      CheckEqI(Length(Stmts), 3, 'two tables and one index');
    finally
      S.Free;
    end;

    { Save, with the auto key from last_insert_rowid. }
    K := A.New<TSqCustomer>;
    K.Name := 'Ada';
    K.Email := 'ada@gets.no';
    K.Balance := 1234.5;
    K.Active := True;
    K.Save;
    Check(K.Id > 0, 'INSERT gave the primary key back');
    CheckEqI(K.Id, 1, 'the first row gets id 1');

    K.Balance := 99.95;
    K.Save;
    CheckEqI(TQuery<TSqCustomer>.New.Count, 1,
      'the second Save was an UPDATE, not a new row');
    Check(TQuery<TSqCustomer>.New.Find(1).Balance = 99.95, 'the value was updated');

    for I := 2 to 5 do
    begin
      K := A.New<TSqCustomer>;
      K.Name := Format('Customer %d', [I]);
      K.Email := Format('customer%d@gets.no', [I]);
      K.Balance := I * 100;
      K.Active := I mod 2 = 0;
      K.Save;
      for J := 1 to I - 1 do
      begin
        O := A.New<TSqOrder>;
        O.CustomerId := K.Id;
        O.Sum_ := J * 50;
        O.Save;
      end;
    end;

    { Typed queries against the same query builder as Postgres. }
    CheckEqI(TQuery<TSqCustomer>.New.Count, 5, 'five customers');
    Check(Pos('"sq_customers"."name"', TQuery<TSqCustomer>.New.ToSql) > 0,
      'SQLite quotes with double quotes');
    Check(Pos('?', TQuery<TSqCustomer>.New
      .Where(SqCustomers.Balance, GT, 150).ToSql) > 0,
      'the placeholder is ?, not $1');

    Items := TQuery<TSqCustomer>.New
      .Where(SqCustomers.Balance, GT, 150)
      .OrderBy(SqCustomers.Balance, Desc)
      .Get;
    CheckEqI(Items.Count, 4, 'fire over 150');
    Check(Items[0].Balance = 500, 'sorted descending');
    CheckEqS(Items[0].Name, 'Customer 5', 'the right row hydrated');
    Check(Items[0].Active = False, 'boolean hydrated from INTEGER');

    { An OR group: free-text search across several columns.

      Without it TQuery has only AND, and "find Ada in the name or the
      email" cannot be expressed. The parentheses are what matter: without
      them a Where that is already there binds to only the first term in
      the group, and the search leaks rows. }
    Sql := TQuery<TSqCustomer>.New
      .Where(SqCustomers.Balance, GT, 100)
      .WhereAnyLike([SqCustomers.Name, SqCustomers.Email], 'ada')
      .ToSql;
    Check(Pos(' OR ', Sql) > 0, 'OR between the search columns');
    Check(Pos(' AND (', Sql) > 0, 'AND binds to the whole group, not only the first term');
    Check(Sql[Length(Sql)] = ')', 'and the group is closed');
    { SQLite has no ILIKE. LIKE there is already ASCII-insensitive. }
    Check(Pos('ILIKE', Sql) = 0, 'ILIKE is translated away outside Postgres');
    Check(Pos(' LIKE ', Sql) > 0, 'til LIKE');

    { One term in the group must not get parentheses it does not need, and
      empty text must not add a clause at all. }
    CheckEqS(TQuery<TSqCustomer>.New.WhereAnyLike([SqCustomers.Name], '').ToSql,
      TQuery<TSqCustomer>.New.ToSql, 'an empty search adds nothing');

    Items := TQuery<TSqCustomer>.New
      .WhereAnyLike([SqCustomers.Name, SqCustomers.Email], 'ada')
      .Get;
    CheckEqI(Items.Count, 1, 'the search matches Ada on the name');

    { Matches on the email even though the name does not contain the search
      term. That is the whole point of the OR. }
    Items := TQuery<TSqCustomer>.New
      .WhereAnyLike([SqCustomers.Name, SqCustomers.Email], 'customer3@')
      .Get;
    CheckEqI(Items.Count, 1, 'and matches on the email when the name does not');

    { Case-insensitive, outside Postgres too. }
    Items := TQuery<TSqCustomer>.New
      .WhereAnyLike([SqCustomers.Name, SqCustomers.Email], 'ADA')
      .Get;
    CheckEqI(Items.Count, 1, 'the search does not care about case');

    { ---- TGrid: sorting, search and pagination in the database ---- }
    begin
      { The count is read from the database rather than assumed. The
        fixture above changes, and a test that hard-codes the number
        breaks for reasons that have nothing to do with the grid. }
      Count_ := TQuery<TSqCustomer>.New.Count;
      { The default state: no parameters at all. }
      G := TGrid<TSqCustomer>.New;
      G.Read(MakeRequest(A, 'GET /customers HTTP/1.1'#13#10'Host: t'))
       .Sortable('name', SqCustomers.Name)
       .Sortable('balance', SqCustomers.Balance)
       .Searchable([SqCustomers.Name, SqCustomers.Email])
       .DefaultSort('name')
       .PerPage(2);
      Items := G.Rows(TQuery<TSqCustomer>.New);
      CheckEqI(Items.Count, 2, 'the grid gives one page');
      CheckEqI(G.Total, Count_, 'men teller hele settet');
      CheckEqS(Items[0].Name, 'Ada', 'the default sort applies');

      { Side to. }
      Sql := Items[1].Name;   { the last row on page one }
      G := TGrid<TSqCustomer>.New;
      G.Read(MakeRequest(A, 'GET /c?page=2 HTTP/1.1'#13#10'Host: t'))
       .Sortable('name', SqCustomers.Name).DefaultSort('name').PerPage(2);
      Items := G.Rows(TQuery<TSqCustomer>.New);
      Check(Items[0].Name > Sql, 'page two continues where page one ended');

      { Sortering fra URL-en. }
      G := TGrid<TSqCustomer>.New;
      G.Read(MakeRequest(A, 'GET /c?sort=balance&dir=desc HTTP/1.1'#13#10'Host: t'))
       .Sortable('balance', SqCustomers.Balance).DefaultSort('balance').PerPage(10);
      Items := G.Rows(TQuery<TSqCustomer>.New);
      Check(Items[0].Balance = 500, 'descending on balance');

      { **The column from the URL is allowlisted.** A column that is not
        registered falls back to the default instead of reaching the SQL.
        That is not a check we wrote — OrderBy takes a typed TCol, so the
        shape does not exist to write. This only holds down that the
        fallback works. }
      G := TGrid<TSqCustomer>.New;
      G.Read(MakeRequest(A,
        'GET /c?sort=email); DROP TABLE sq_customers;-- HTTP/1.1'#13#10'Host: t'))
       .Sortable('name', SqCustomers.Name).DefaultSort('name').PerPage(10);
      Items := G.Rows(TQuery<TSqCustomer>.New);
      CheckEqS(Items[0].Name, 'Ada', 'an unknown sort column falls back');
      CheckEqI(TQuery<TSqCustomer>.New.Count, Count_, 'and the table is still there');

      { Search across several columns. }
      G := TGrid<TSqCustomer>.New;
      G.Read(MakeRequest(A, 'GET /c?q=ada@ HTTP/1.1'#13#10'Host: t'))
       .Sortable('name', SqCustomers.Name)
       .Searchable([SqCustomers.Name, SqCustomers.Email])
       .DefaultSort('name').PerPage(10);
      Items := G.Rows(TQuery<TSqCustomer>.New);
      CheckEqI(Items.Count, 1, 'the search matches on the email');
      CheckEqI(G.Total, 1, 'and the total counts the matches, not the table');

      { The search has to apply together with the caller's own Where, not
        instead of it. It is the parentheses around the OR group that
        decide that. }
      G := TGrid<TSqCustomer>.New;
      G.Read(MakeRequest(A, 'GET /c?q=customer HTTP/1.1'#13#10'Host: t'))
       .Sortable('name', SqCustomers.Name)
       .Searchable([SqCustomers.Name, SqCustomers.Email])
       .DefaultSort('name').PerPage(10);
      Items := G.Rows(TQuery<TSqCustomer>.New.Where(SqCustomers.Balance, GT, 300));
      CheckEqI(Items.Count, 2, 'the search and your own Where apply together');

      { The cap on page size. Without it per=1000000 is a way of asking for
        the whole table. }
      G := TGrid<TSqCustomer>.New;
      G.Read(MakeRequest(A, 'GET /c?per=100000 HTTP/1.1'#13#10'Host: t'))
       .Sortable('name', SqCustomers.Name).DefaultSort('name').PerPage(2, 3);
      Items := G.Rows(TQuery<TSqCustomer>.New);
      CheckEqI(Items.Count, 3, 'the page size is clamped to the cap');

      { Payloaden frontend leser. }
      GW.Init(A, 256);
      G.WriteJson(GW);
      GJson := GW.ToString;
      Check(Pos('"total":' + IntToStr(Count_), GJson) > 0,
        'the grid prop carries the total');
      Check(Pos('"pages":', GJson) > 0, 'og antall sider');
      Check(Pos('"per":3', GJson) > 0, 'and the page size after the cap');
      Check(Pos('"sort":"name"', GJson) > 0, 'and which column is sorted');

      { ---- the list envelope, for a caller that is not the grid ---- }

      { A page in the middle of a set: data, a measured total, and a next
        link. }
      G := TGrid<TSqCustomer>.New;
      G.Read(MakeRequest(A,
        'GET /customers?sort=name&status=open HTTP/1.1'#13#10'Host: t'))
       .Sortable('name', SqCustomers.Name).DefaultSort('name').PerPage(2);
      Items := G.Rows(TQuery<TSqCustomer>.New);
      GJson := G.ListResponse(Items).Body.ToString;

      Check(IsJson(GJson), 'the envelope parses');
      CheckEqS(ProblemMember(GJson, 'meta.total'), IntToStr(Count_),
        'the total is the whole set, not the page');
      CheckEqS(ProblemMember(GJson, 'meta.per'), '2', 'and the page size');
      CheckEqS(ProblemMember(GJson, 'meta.page'), '1', 'and which page');
      Check(Pos('"data":[{', GJson) > 0, 'data is an array of objects');

      { **The next link keeps the application''s own parameters.** A list
        usually carries more than sort and search, and a link that paged
        through a different list than the caller asked for would be worse
        than no link. }
      Sql := ProblemMember(GJson, 'links.next');
      Check(Pos('status=open', Sql) > 0, 'the next link keeps status=open');
      Check(Pos('sort=name', Sql) > 0, 'and the sort');
      Check(Pos('page=2', Sql) > 0, 'and moves to page two');
      Check(Pos('/customers?', Sql) = 1, 'and is a relative path');
      CheckEqS(ProblemMember(GJson, 'links.prev'), '',
        'there is no page before the first');

      { Page two of two: prev is there, next is not, and page= is
        replaced rather than repeated. }
      G := TGrid<TSqCustomer>.New;
      G.Read(MakeRequest(A,
        'GET /customers?page=2&status=open HTTP/1.1'#13#10'Host: t'))
       .Sortable('name', SqCustomers.Name).DefaultSort('name').PerPage(100);
      Items := G.Rows(TQuery<TSqCustomer>.New);
      GJson := G.ListResponse(Items).Body.ToString;
      Sql := ProblemMember(GJson, 'links.prev');
      Check(Pos('page=1', Sql) > 0, 'prev goes back one');
      Check(Pos('page=2', Sql) = 0, 'and the old page is gone, not repeated');
      Check(Pos('status=open', Sql) > 0, 'with the parameters still there');
      CheckEqS(ProblemMember(GJson, 'links.next'), '',
        'and there is nothing after the last page');

      { **Nothing matched.** This is the case the envelope exists for:
        data has to be an empty array, never null. A client of a list
        iterates that key, and null is the one value that turns an empty
        result into a crash. }
      G := TGrid<TSqCustomer>.New;
      G.Read(MakeRequest(A, 'GET /customers?q=zzzznothing HTTP/1.1'#13#10'Host: t'))
       .Sortable('name', SqCustomers.Name)
       .Searchable([SqCustomers.Name, SqCustomers.Email])
       .DefaultSort('name').PerPage(10);
      Items := G.Rows(TQuery<TSqCustomer>.New);
      GJson := G.ListResponse(Items).Body.ToString;
      Check(Pos('"data":[]', GJson) > 0, 'nothing matched gives an empty array');
      Check(Pos('null', ProblemMember(GJson, 'data')) = 0, 'and not null');
      Check(Pos('"data":null', GJson) = 0, 'data is never null');
      CheckEqS(ProblemMember(GJson, 'meta.total'), '0', 'the total is zero');
      CheckEqS(ProblemMember(GJson, 'meta.pages'), '1',
        'and there is still one page, not zero');
      CheckEqS(ProblemMember(GJson, 'links.next'), '', 'with no next');
      CheckEqS(ProblemMember(GJson, 'links.prev'), '', 'and no prev');

      { **One model as a whole reply.** The same serialisation as
        everywhere else, because it is the same code -- including that a
        hidden column stays hidden. }
      Cust_ := TQuery<TSqCustomer>.New.OrderBy(SqCustomers.Id).First;
      Reply2 := RespondModel(Cust_, 201);
      CheckEqI(Reply2.StatusCode, 201, 'RespondModel answers with the status');
      CheckEqS(Reply2.HeaderValue('Content-Type'),
        'application/json; charset=utf-8', 'and says it is JSON');
      GJson := Reply2.Body.ToString;
      Check(Pos('"name":', GJson) > 0, 'with the model in it');
      Check(Copy(GJson, 1, 1) = '{', 'as an object, not as null');

      { A list nobody built at all is still an array. }
      GW.Init(A, 64);
      WriteModelList(GW, nil);
      CheckEqS(GW.ToString, '[]', 'no list at all is an empty array');

      { **The total has to be measured, not assumed.** Building the
        payload without calling Rows would report a total of zero for a
        list with rows in it. }
      G := TGrid<TSqCustomer>.New;
      G.Read(MakeRequest(A, 'GET /customers HTTP/1.1'#13#10'Host: t'))
       .Sortable('name', SqCustomers.Name).DefaultSort('name');
      Raised_ := False;
      try
        G.ListResponse(nil);
      except
        on E: EGridError do
          Raised_ := True;
      end;
      Check(Raised_, 'a payload built without Rows raises');

      { And the reply says it is JSON. }
      G := TGrid<TSqCustomer>.New;
      G.Read(MakeRequest(A, 'GET /customers HTTP/1.1'#13#10'Host: t'))
       .Sortable('name', SqCustomers.Name).DefaultSort('name');
      Items := G.Rows(TQuery<TSqCustomer>.New);
      CheckEqS(G.ListResponse(Items).HeaderValue('Content-Type'),
        'application/json; charset=utf-8', 'the envelope is served as JSON');

      { **A page is cut out of an order, so the order has to be total.**
        Where the sort does not decide between two rows the database may
        put them either way round, on each query -- so page one shows a
        row that page two shows again, and some other row is never shown.
        Paginate puts the primary key last for that, and this is the SQL
        that comes out. There is no way to make SQLite return them in a
        different order on demand, so the assertion is on the ORDER BY
        and not on the symptom. }
      Sql := TQuery<TSqCustomer>.New.OrderBy(SqCustomers.Name).ToSql;
      Sql := Copy(Sql, Pos('ORDER BY', Sql), MaxInt);
      Check(Pos('name', Sql) > 0, 'an ordinary query orders by what it was told');
      Check(Pos('id', Sql) = 0, 'and nothing is added to it');
      Sql := TQuery<TSqCustomer>.New.Limit(2).ToSql;
      Check(Pos('ORDER BY', Sql) = 0,
        'nor does a plain Limit, which is the caller''s own business');
      G := TGrid<TSqCustomer>.New;
      G.Read(MakeRequest(A, 'GET /customers HTTP/1.1'#13#10'Host: t'))
       .Sortable('name', SqCustomers.Name).DefaultSort('name').PerPage(2);
      Q_ := TQuery<TSqCustomer>.New;
      G.Rows(Q_);
      Sql := Q_.ToSql;
      Check(Pos('ORDER BY', Sql) > 0, 'a page is ordered');
      Check(Pos('name', Copy(Sql, Pos('ORDER BY', Sql), MaxInt)) > 0,
        'by what was asked for');
      Check(Pos('id', Copy(Sql, Pos('ORDER BY', Sql), MaxInt)) >
            Pos('name', Copy(Sql, Pos('ORDER BY', Sql), MaxInt)),
        'and then by the primary key, last');

      { And only once. A caller who already ordered by the key has said
        everything there is to say about the order; adding it again is
        harmless SQL and a sign the check is not there. }
      Q_ := TQuery<TSqCustomer>.New.OrderBy(SqCustomers.Id);
      Q_.Paginate(1, 2);
      Sql := Copy(Q_.ToSql, Pos('ORDER BY', Q_.ToSql), MaxInt);
      Count_ := 0;
      I := Pos('id', Sql);
      while I > 0 do
      begin
        Inc(Count_);
        I := PosEx('id', Sql, I + 1);
      end;
      CheckEqI(Count_, 1, 'the key is not added when it is already there');

    end;

    { Ada is active, and of Customer 2..5 so are 2 and 4. Three in
      all. }
    CheckEqI(TQuery<TSqCustomer>.New.Where(SqCustomers.Active, Eq, True).Count, 3,
      'a boolean filter against an INTEGER column');
    CheckEqI(TQuery<TSqCustomer>.New.WhereIn(SqCustomers.Id, [1, 2, 3]).Count, 3,
      'WhereIn');

    { Eager loading. }
    Items := TQuery<TSqCustomer>.New.Preload(['Order']).OrderBy(SqCustomers.Id).Get;
    Count_ := 0;
    for I := 0 to Items.Count - 1 do
      if Items[I].Order <> nil then
        Count_ := Count_ + Items[I].Order.Count;
    CheckEqI(Count_, 1 + 2 + 3 + 4, 'eager loading fordelte alle orders');
    CheckEqI(Items[0].Order.Count, 0, 'the first customer has none');
    CheckEqI(Items[4].Order.Count, 4, 'the last one has four');

    { Validering, inkludert UniqueIn mot SQLite. }
    K := A.New<TSqCustomer>;
    K.Name := 'Duplicate';
    K.Email := 'ada@gets.no';
    Check(not K.Validate, 'UniqueIn catches the duplicate');
    Check(K.Errors.Has('email'), 'the error is on email');

    { A unique violation from the database is translated to the same
      SQLSTATE as Postgres. }
    try
      K.Save;
      Check(False, 'the unique violation should have raised');
    except
      on E: EDbError do
        Check(E.IsUniqueViolation,
          'SQLITE_CONSTRAINT is translated to 23505');
    end;

    { Foreign keys are enforced only with the pragma set. }
    try
      O := A.New<TSqOrder>;
      O.CustomerId := 9999;
      O.Save;
      Check(False, 'the foreign key should have raised');
    except
      on E: EDbError do
        Check(E.IsForeignKeyViolation, 'a foreign key gives 23503');
    end;

    { Transaksjon. }
    C.StartTransaction;
    K := A.New<TSqCustomer>;
    K.Name := 'Rolled back';
    K.Email := 'rull@gets.no';
    K.Save;
    CheckEqI(TQuery<TSqCustomer>.New.Count, 6, 'visible inside the transaction');
    C.Rollback;
    CheckEqI(TQuery<TSqCustomer>.New.Count, 5, 'ROLLBACK fjernet den');

    { The arena is to level off as it does against Postgres. }
    for I := 1 to 50 do
    begin
      A.Reset;
      TQuery<TSqCustomer>.New.Preload(['Order']).Get;
    end;
    Reservert := A.BytesReserved;
    for I := 1 to 500 do
    begin
      A.Reset;
      TQuery<TSqCustomer>.New.Preload(['Order']).Get;
    end;
    CheckEqI(A.BytesReserved, Reservert,
      'the arena does not grow over 500 queries against SQLite');

    { ---- Currency arithmetic across compilers and architectures ---- }
    { A premise test, and it has been wrong twice.

      First premise: FPC 3.3.1 and 3.2.2 disagree about one form.
      Currency(I) * <integer literal> gives I/100 on trunk and I*100 on
      3.2.2 — silently, on money.

      Second premise, found when the framework was first compiled for
      x86_64. A typecast into Currency does one of three things there,
      and the difference is invisible at the call site — measured with
      I = 7:

                                  x86_64      aarch64
        Currency(I)               refuses to compile
        Currency(I * 100)         0.0700      700.0000
        Currency(10)              0.0010       10.0000
        Currency(1234.50)      1234.5000     1234.5000

      An integer operand is reinterpreted as the scaled Int64 that
      Currency is underneath, rather than converted. A real literal is
      converted. The old version of this test used the first form and
      therefore only ever built on aarch64.

      So the rule has no exceptions worth teaching: **assign into
      Currency, never cast into it.** Assignment is a defined conversion
      on every compiler and every target. That is what the forms below
      use, and it is what PropAsCurrency in Askr.Urd.Model exists for.

      Checked through CurrencyToSql, which is what actually reaches the
      database — and because any scaling by an integer here would be the
      very trap the test is about. }
    Kr := 7;
    Cur := Kr;
    CheckEqS(CurrencyToSql(Cur), '7.0000', 'assignment from an integer');
    Cur := Kr * 100;
    CheckEqS(CurrencyToSql(Cur), '700.0000',
      'multiplication before the conversion');
    Cur := Kr;
    Cur := Cur * 100;
    CheckEqS(CurrencyToSql(Cur), '700.0000', 'Currency * integer literal');
    Cur := Kr;
    Cur := Cur / 4;
    CheckEqS(CurrencyToSql(Cur), '1.7500', 'Currency / 4');
    Cur := Kr;
    Cur := Cur + 1;
    CheckEqS(CurrencyToSql(Cur), '8.0000', 'Currency + 1');

    { ---- statement-cachen ---- }
    Sq := TSqliteConnection(C);
    Sq.FlushStatementCache;
    A.Reset;

    ForPrep := Sq.PreparedCount;
    ForHits := Sq.CacheHits;
    ForApne := Sq.OpenStatements;
    for I := 1 to 20 do
      C.ExecParams(A, 'SELECT name FROM sq_customers WHERE id = ?',
        [DbParam(A, Int64(1))]);
    CheckEqI(Sq.PreparedCount - ForPrep, 1,
      'the same query is prepared once');
    CheckEqI(Sq.CacheHits - ForHits, 19, 'the rest hit the cache');
    CheckEqI(Sq.OpenStatements - ForApne, 1,
      'and SQLite has exactly one statement open');

    { Bindings from the previous run must not linger. Without
      sqlite3_clear_bindings a call with fewer or different parameters
      would see values from the previous round. }
    A.Reset;
    R2 := C.ExecParams(A, 'SELECT count(*) FROM sq_customers WHERE name = ?',
      [DbParam(A, 'Ada')]);
    Count_ := Integer(R2.AsInt64(0, 0));
    R2 := C.ExecParams(A, 'SELECT count(*) FROM sq_customers WHERE name = ?',
      [DbParam(A, 'does-not-exist')]);
    CheckEqI(R2.AsInt64(0, 0), 0,
      'a reused statement uses the new parameters');
    R2 := C.ExecParams(A, 'SELECT count(*) FROM sq_customers WHERE name = ?',
      [DbParam(A, 'Ada')]);
    CheckEqI(R2.AsInt64(0, 0), Count_,
      'and gives the same answer as before when the parameter is the same');

    { NULL after a non-NULL value on the same statement. }
    R2 := C.ExecParams(A, 'SELECT count(*) FROM sq_customers WHERE name IS ?',
      [DbNull]);
    Check(R2.RowCount = 1, 'a NULL parameter on a reused statement');

    { An error must not damage the cached statement. }
    Failed_ := False;
    try
      C.ExecParams(A, 'INSERT INTO sq_customers (id, name, email) VALUES (?, ?, ?)',
        [DbParam(A, Int64(1)), DbParam(A, 'Kopi'), DbParam(A, 'kopi@x.no')]);
    except
      on E: EDbError do Failed_ := True;
    end;
    Check(Failed_, 'a duplicate primary key raises');
    R2 := C.ExecParams(A, 'SELECT name FROM sq_customers WHERE id = ?',
      [DbParam(A, Int64(1))]);
    Check(R2.RowCount = 1, 'cachet statement virker etter en feil');

    { prepare_v2 handles schema changes itself — where MySQL has to evict
      the statement from the cache, SQLite does not need to. }
    C.Exec(A, 'ALTER TABLE sq_customers ADD COLUMN note TEXT');
    R2 := C.ExecParams(A, 'SELECT name FROM sq_customers WHERE id = ?',
      [DbParam(A, Int64(1))]);
    Check(R2.RowCount = 1, 'cachet statement overlever ALTER TABLE');

    { The cache off: prepared every time, and nothing is left open. }
    Sq.FlushStatementCache;
    ForApne := Sq.OpenStatements;
    ForPrep := Sq.PreparedCount;
    Sq.CacheLimit := 0;
    for I := 1 to 30 do
      C.ExecParams(A, 'SELECT email FROM sq_customers WHERE id = ?',
        [DbParam(A, Int64(1))]);
    CheckEqI(Sq.PreparedCount - ForPrep, 30, 'the cache off: prepared every time');
    CheckEqI(Sq.OpenStatements - ForApne, 0,
      'and no statements are left open');
    Sq.CacheLimit := 64;

    { Past the limit the cache is emptied, and the number of open ones
      follows it down. }
    Sq.FlushStatementCache;
    Sq.CacheLimit := 4;
    for I := 1 to 12 do
      C.ExecParams(A, Format('SELECT %d FROM sq_customers WHERE id = ?', [I]),
        [DbParam(A, Int64(1))]);
    Check(Sq.OpenStatements <= 4, 'the cache stays within its limit');
    Sq.CacheLimit := 64;
    Sq.FlushStatementCache;
    CheckEqI(Sq.OpenStatements, 0, 'flush lukker alle');

    { A measurement, not an assertion. Time limits in a suite go flaky on
      a loaded machine, but "a cache" is empty talk without a number
      behind it. }
    A.Reset;
    Sq.CacheLimit := 0;
    T0 := MonotonicMs;
    for I := 1 to 2000 do
      C.ExecParams(A, 'SELECT name FROM sq_customers WHERE id = ?',
        [DbParam(A, Int64(1))]);
    Without := MonotonicMs - T0;
    Sq.CacheLimit := 64;
    Sq.FlushStatementCache;
    T0 := MonotonicMs;
    for I := 1 to 2000 do
      C.ExecParams(A, 'SELECT name FROM sq_customers WHERE id = ?',
        [DbParam(A, Int64(1))]);
    With_ := MonotonicMs - T0;
    Si2('2000 queries', Format('%d ms without the cache, %d ms with', [Without, With_]));
    Check(With_ <= Without + (Without div 4) + 2, 'the cache did not make it slower');

    PivotPart(C);
  finally
    UseDb(PrevDb);
    UseArena(PrevA);
    C.Free;
    A.Free;
  end;
end;

{ ------------------------------------------------------------ ende-til-ende -- }

type
  TClient = record
    Sock: TSocket;
    function Connect(Port: Word): Boolean;
    procedure SendRaw(const S: string);
    { Reads exactly one response, driven by Content-Length. NoBody has to
      be set for answers to HEAD: they give a Content-Length without sending
      the body. }
    function ReadResponse(out Head, Body: string; NoBody: Boolean = False): Boolean;
    procedure Close;
  private
    Buf: string;
    function FillOnce: Boolean;
  end;

function TClient.Connect(Port: Word): Boolean;
var
  Addr: TInetSockAddr;
  TV: TTimeVal;
begin
  Buf := '';
  Sock := fpSocket(AF_INET, SOCK_STREAM, 0);
  if Sock < 0 then
    Exit(False);
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := HToNS(Port);
  Addr.sin_addr := StrToNetAddr('127.0.0.1');
  Result := fpConnect(Sock, @Addr, SizeOf(Addr)) = 0;
  if not Result then
  begin
    CloseSocket(Sock);
    Exit;
  end;
  { Without this a fault in the host turns into a test suite that hangs. }
  TV.tv_sec := 3;
  TV.tv_usec := 0;
  fpSetSockOpt(Sock, SOL_SOCKET, SO_RCVTIMEO, @TV, SizeOf(TV));
end;

procedure TClient.SendRaw(const S: string);
begin
  fpSend(Sock, PChar(S), Length(S), 0);
end;

function TClient.FillOnce: Boolean;
var
  Tmp: array[0..8191] of Byte;
  N: ssize_t;
begin
  N := fpRecv(Sock, @Tmp[0], SizeOf(Tmp), 0);
  if N <= 0 then
    Exit(False);
  SetLength(Buf, Length(Buf) + N);
  Move(Tmp[0], Buf[Length(Buf) - N + 1], N);
  Result := True;
end;

function TClient.ReadResponse(out Head, Body: string; NoBody: Boolean): Boolean;
var
  P, CL, LineEnd: Integer;
  Line: string;
begin
  Head := '';
  Body := '';
  repeat
    P := Pos(#13#10#13#10, Buf);
    if P > 0 then
      Break;
    if not FillOnce then
      Exit(False);
  until False;

  Head := Copy(Buf, 1, P - 1);
  Delete(Buf, 1, P + 3);

  CL := 0;
  if NoBody then
  begin
    Result := True;
    Exit;
  end;
  P := Pos('Content-Length: ', Head);
  if P > 0 then
  begin
    LineEnd := PosEx(#13#10, Head, P);
    if LineEnd = 0 then
      LineEnd := Length(Head) + 1;
    Line := Copy(Head, P + 16, LineEnd - P - 16);
    CL := StrToIntDef(Trim(Line), 0);
  end;

  while Length(Buf) < CL do
    if not FillOnce then
      Break;

  Body := Copy(Buf, 1, CL);
  Delete(Buf, 1, CL);
  Result := True;
end;

procedure TClient.Close;
begin
  CloseSocket(Sock);
end;

type
  { An exception that says what it should become.

    Before EHttpError existed, every way of stopping a handler from the
    middle of its work was a 500 -- so a guard that refused exactly as it
    was meant to looked like a broken server, in the log and to the
    caller. Raising is the only way out of the middle of a function, and
    some of those failures are not faults. }
  ERefused = class(EHttpError)
  public
    function HttpStatus: Integer; override;
  end;

  { And one that says something on purpose. The default is silence, for
    the same reason a problem document has no detail by default. }
  EShipped = class(EHttpError)
  public
    function HttpStatus: Integer; override;
    function PublicDetail: string; override;
  end;

const
  { Shaped like a message that really does carry something: the gate name
    and the row it was about. It belongs in the log and nowhere else. }
  RefusedSecret = 'gate=orders:write user=7 row=/var/db/orders.sqlite';

function ERefused.HttpStatus: Integer;
begin
  Result := 403;
end;

function EShipped.HttpStatus: Integer;
begin
  Result := 409;
end;

function EShipped.PublicDetail: string;
begin
  Result := 'That order has already shipped.';
end;

type
  TE2EHandler = class
  public
    Statisk: TStaticFiles;
    function Handle(Req: TRequest): TResponse;
  end;

const
  { The message /boom raises. It is shaped like the exception messages
    that really do carry secrets -- a path and a value -- because that is
    what makes the rule worth a test. A framework that helpfully puts
    E.Message in the reply body has published a reconnaissance endpoint on
    every route that can throw, and the ones that throw are the ones
    holding a connection string. }
  BoomSecret = '/Users/askr/secret/db.pass: password=hunter2';

{ The size is the whole point. The file has to fit inside the arena
  block that is already in use by the request — larger, and it gets a new
  block, and that path works. The suite runs with 16 kB blocks, so 6000
  bytes lands on the right side: the head and TRequest take a couple of kB,
  and the rest is free. }
const
  StaticSize = 6000;

function TE2EHandler.Handle(Req: TRequest): TResponse;
begin
  if Statisk <> nil then
  begin
    Result := Statisk.Serve(Req);
    if Result <> nil then
      Exit;
  end;
  if Req.Path.EqualsStr('/') then
    Exit(RespondText('rot'));
  if Req.Path.EqualsStr('/ekko') then
    Exit(Respond(200).WithContentType('text/plain').WithBody(Req.Body));
  if Req.Path.EqualsStr('/name') then
    Exit(RespondText(Req.Query('name').ToString));
  { The absolute URL of this very request, which is where a canonical link
    or a link in an email would come from. The handler has the request in
    its hand and still cannot build the origin out of it -- AbsoluteUrl
    takes a path and nothing else. }
  if Req.Path.EqualsStr('/absolute') then
    Exit(RespondText(AbsoluteUrl(Req.Path.ToString)));
  { A handler that sets an ETag and a cookie on the same response. It is
    the shape of any page with a session and a CSRF token in the form. }
  { Echoes the body, and carries an ETag. A POST here is the case the
    method check exists for: without it the write would be answered with
    "your copy is current" and dropped. Without the ETag the test would
    pass whatever the method check did, which is how the first version of
    it passed. }
  if Req.Path.EqualsStr('/etag-ekko') then
    Exit(Respond(200).WithContentType('text/plain')
      .WithBody(Req.Body).WithETag('fast'));
  if Req.Path.EqualsStr('/med-kake') then
    Exit(RespondText('skjema').WithETag('fast').WithCookie('session', 'abc'));
  if Req.Path.EqualsStr('/upload') then
  begin
    if not Req.Multipart.Ok then
      Exit(RespondText(Req.Multipart.ErrorText, 400));
    Exit(RespondText(Format('%s|%s|%d|%s',
      [Req.Form('title').ToString,
       Req.Upload('file').ClientName.ToString,
       Req.Upload('file').Size,
       Req.Upload('file').Content.ToString])));
  end;
  if Req.Path.EqualsStr('/boom') then
    raise Exception.Create('on purpose: ' + BoomSecret);
  { Refused, not broken. }
  if Req.Path.EqualsStr('/refused') then
    raise ERefused.Create(RefusedSecret);
  if Req.Path.EqualsStr('/shipped') then
    raise EShipped.Create('order 7 is in state shipped, table orders');
  { Answers with nothing, so the server's own 404 runs. The fall-through
    below is the application's 404 and a different path entirely. }
  if Req.Path.EqualsStr('/nowhere') then
    Exit(nil);
  Result := RespondText('gone', 404);
end;

procedure TestEndToEnd;
var
  Opts: TServerOptions;
  Server: TAskrServer;
  H: TE2EHandler;
  C: TClient;
  Head, Body: string;
  Port: Word;
  I: Integer;
  Reserved1, Reserved2: PtrUInt;
  MpBody, MpContent: string;
  StaticFile: TStringList;
  Etag_: string;
begin
  Group('End to end over a socket');
  { Content with CRLFs in it, and with something that looks like the
    boundary. If it goes all the way through a socket unchanged, the
    framework holds. }
  MpContent := 'linje1'#13#10'--XA'#13#10'linje2';

  Opts := DefaultServerOptions;
  Opts.Port := 0;             { la kjernen velge }
  Opts.Workers := 2;
  Opts.ArenaBlockSize := 16 * 1024;
  H := TE2EHandler.Create;
  { A file on disk to serve. The directory is under .build, so it goes
    away with the rest when somebody cleans up. }
  ForceDirectories('.build' + PathDelim + 'e2e-statisk' + PathDelim + 'static');
  StaticFile := TStringList.Create;
  try
    StaticFile.Text := StringOfChar('a', StaticSize - 1);
    StaticFile.SaveToFile('.build' + PathDelim + 'e2e-statisk' + PathDelim +
      'static' + PathDelim + 'big.css');
  finally
    StaticFile.Free;
  end;
  H.Statisk := TStaticFiles.Create('.build' + PathDelim + 'e2e-statisk');

  Server := TAskrServer.Create(Opts);
  try
    Server.SetHandler(H.Handle);
    Server.Start;
    Port := Server.BoundPort;
    Check(Port > 0, 'serveren valgte en port (bind til 0)');

    Check(C.Connect(Port), 'the client connects');
    C.SendRaw('GET / HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    Check(C.ReadResponse(Head, Body), 'got an answer');
    Check(Pos('HTTP/1.1 200 OK', Head) = 1, 'GET / gives 200');
    CheckEqS(Body, 'rot', 'the right body');

    { Samme tilkobling igjen — keep-alive. }
    C.SendRaw('GET /name?name=Knut HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    Check(C.ReadResponse(Head, Body), 'the second request on the same connection');
    CheckEqS(Body, 'Knut', 'keep-alive fungerer');

    C.SendRaw('GET /does-not-exist HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    C.ReadResponse(Head, Body);
    Check(Pos('HTTP/1.1 404 Not Found', Head) = 1, '404');

    { ---- an absolute URL is never built from the Host header ----

      Host is a header, which means it is text the client writes. A
      canonical link built from it tells a search engine the page lives on
      the attacker's domain; a password-reset link built from it sends the
      token there. Host-header injection is the ordinary name for both.

      So: a forged Host, over a real socket, and the answer has to be the
      configured origin. The unit is shaped so that it cannot go wrong --
      AbsoluteUrl takes a path and has no request to look at -- and this is
      the end of the wire that proves the shape survived the journey. }
    ForceDirectories('.build' + PathDelim + 'e2e-url');
    StaticFile := TStringList.Create;
    try
      StaticFile.Add('APP_ENV=local');
      StaticFile.Add('APP_URL=https://example.com');
      StaticFile.SaveToFile('.build' + PathDelim + 'e2e-url' +
        PathDelim + '.env');
    finally
      StaticFile.Free;
    end;
    ClearConfig;
    LoadConfig('.build' + PathDelim + 'e2e-url');

    C.SendRaw('GET /absolute HTTP/1.1'#13#10 +
      'Host: evil.example'#13#10#13#10);
    Check(C.ReadResponse(Head, Body), 'the request with a forged Host');
    CheckEqS(Body, 'https://example.com/absolute',
      'the absolute URL comes from app.url');
    Check(Pos('evil.example', Body) = 0,
      'and the Host header is nowhere in it');

    { The same with a Host that would pass any sanity check, so that the
      assertion above is not passing merely because the forgery looked
      obviously wrong. }
    C.SendRaw('GET /absolute HTTP/1.1'#13#10 +
      'Host: example.com.evil.example'#13#10#13#10);
    Check(C.ReadResponse(Head, Body), 'and one that starts with the real host');
    CheckEqS(Body, 'https://example.com/absolute', 'same answer');

    ClearConfig;

    { A static file as a follow-up on the same connection.

      This is the shape every browser uses: fetch the page, then fetch the
      css and the js over the same connection. It crashed with an
      EAccessViolation on a real site built with the framework, and only
      when the file fit inside the arena block that was already in use — a
      large file got a new block and was fine, a small one did not. Alone,
      both were fine. }
    C.SendRaw('GET / HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    Check(C.ReadResponse(Head, Body), 'the page before the static file');
    C.SendRaw('GET /static/big.css HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    Check(C.ReadResponse(Head, Body), 'got an answer for the static file');
    Check(Pos('HTTP/1.1 200 OK', Head) = 1,
      'a static file after a page on the same connection');
    CheckEqI(Length(Body), StaticSize, 'and the whole file came along');
    Check(Pos('text/css', Head) > 0, 'with the right content type');

    { And once more, to show it was not a single lucky time. }
    C.SendRaw('GET /name?name=x HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    C.ReadResponse(Head, Body);
    C.SendRaw('GET /static/big.css HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    C.ReadResponse(Head, Body);
    Check(Pos('HTTP/1.1 200 OK', Head) = 1, 'and again');

    C.SendRaw('HEAD / HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    C.ReadResponse(Head, Body, True);
    Check(Pos('Content-Length: 3', Head) > 0, 'HEAD har Content-Length');
    CheckEqS(Body, '', 'HEAD has no body');

    { ---- conditional GET, over the wire ----

      The comparison lives in the server, so every handler gets it without
      asking. What is proved here rather than in the unit is that the
      header survives the trip, and that a 304 really sends nothing after
      the head on a keep-alive connection -- a body there would
      desynchronise the stream and be read as the start of the next
      response. }
    C.SendRaw('GET /static/big.css HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    Check(C.ReadResponse(Head, Body), 'a static file');
    Check(Pos('ETag: "', Head) > 0, 'comes with an ETag');
    Etag_ := Copy(Head, Pos('ETag: ', Head) + 6, MaxInt);
    Etag_ := Copy(Etag_, 1, Pos(#13, Etag_) - 1);

    C.SendRaw('GET /static/big.css HTTP/1.1'#13#10'Host: test'#13#10 +
      'If-None-Match: ' + Etag_ + #13#10#13#10);
    Check(C.ReadResponse(Head, Body), 'the same file with If-None-Match');
    Check(Pos('HTTP/1.1 304 Not Modified', Head) = 1, 'gives 304');
    CheckEqI(Length(Body), 0, 'with nothing after the head');

    { The connection is still in step. If a 304 had sent a body, this is
      where it would show. }
    C.SendRaw('GET / HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    Check(C.ReadResponse(Head, Body), 'and the connection is still usable');
    CheckEqS(Body, 'rot', 'reading the next response cleanly');

    C.SendRaw('GET /static/big.css HTTP/1.1'#13#10'Host: test'#13#10 +
      'If-None-Match: "something-else"'#13#10#13#10);
    Check(C.ReadResponse(Head, Body), 'a stale If-None-Match');
    Check(Pos('HTTP/1.1 200 OK', Head) = 1, 'gets the file again');
    CheckEqI(Length(Body), StaticSize, 'in full');

    { A conditional POST must not become a 304: that would answer a write
      with "your copy is current" and drop it. }
    C.SendRaw('POST /etag-ekko HTTP/1.1'#13#10'Host: test'#13#10 +
      'If-None-Match: *'#13#10'Content-Length: 4'#13#10#13#10'data');
    Check(C.ReadResponse(Head, Body), 'a POST carrying If-None-Match');
    Check(Pos('ETag: "fast"', Head) > 0,
      'against a response that does have an ETag');
    Check(Pos('HTTP/1.1 200 OK', Head) = 1, 'is not answered conditionally');
    CheckEqS(Body, 'data', 'and still does the work');

    { The same route by GET is conditional, which is what makes the line
      above a statement about the method and not about the route. }
    C.SendRaw('GET /etag-ekko HTTP/1.1'#13#10'Host: test'#13#10 +
      'If-None-Match: *'#13#10#13#10);
    Check(C.ReadResponse(Head, Body), 'and a GET of the same route');
    Check(Pos('HTTP/1.1 304 Not Modified', Head) = 1, 'is');

    { A validator that never changes is worse than none: it would serve a
      stale file forever. So the file is changed and asked for again.

      The size is changed, not just the bytes. The tag is built from the
      modification time and the size, and the time has second resolution --
      a rewrite within the same second at the same length is not detected.
      That is the same window nginx and Apache have, and it closes itself
      on the next write; hashing the contents would close it at the cost of
      a pass over every file on every request. }
    StaticFile := TStringList.Create;
    try
      StaticFile.Text := 'first';
      StaticFile.SaveToFile('.build' + PathDelim + 'e2e-statisk' +
        PathDelim + 'static' + PathDelim + 'vary.txt');
    finally
      StaticFile.Free;
    end;
    C.SendRaw('GET /static/vary.txt HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    Check(C.ReadResponse(Head, Body), 'a file that is about to change');
    Etag_ := Copy(Head, Pos('ETag: ', Head) + 6, MaxInt);
    Etag_ := Copy(Etag_, 1, Pos(#13, Etag_) - 1);

    StaticFile := TStringList.Create;
    try
      StaticFile.Text := 'second, and longer than the first';
      StaticFile.SaveToFile('.build' + PathDelim + 'e2e-statisk' +
        PathDelim + 'static' + PathDelim + 'vary.txt');
    finally
      StaticFile.Free;
    end;
    C.SendRaw('GET /static/vary.txt HTTP/1.1'#13#10'Host: test'#13#10 +
      'If-None-Match: ' + Etag_ + #13#10#13#10);
    Check(C.ReadResponse(Head, Body), 'the same file after it changed');
    Check(Pos('HTTP/1.1 200 OK', Head) = 1,
      'is sent again, not answered 304 from the old tag');
    Check(Pos('ETag: ' + Etag_, Head) = 0, 'and the tag moved with it');

    { And the cookie guard, at the far end of the wire. }
    C.SendRaw('GET /med-kake HTTP/1.1'#13#10'Host: test'#13#10 +
      'If-None-Match: "fast"'#13#10#13#10);
    Check(C.ReadResponse(Head, Body), 'a page that sets a cookie');
    Check(Pos('HTTP/1.1 200 OK', Head) = 1, 'is never a 304');
    CheckEqS(Body, 'skjema', 'the body comes every time');
    Check(Pos('ETag:', Head) = 0, 'and it carries no ETag at all');
    Check(Pos('Set-Cookie:', Head) > 0, 'but still sets the cookie');

    { A real upload over the socket. Everything else about multipart is
      tested against a body that is already in memory; this is the only
      test where the bytes actually go through the read buffer and
      Content-Length. }
    MpBody :=
      '--XB'#13#10'Content-Disposition: form-data; name="title"'#13#10#13#10 +
      'Report'#13#10 +
      '--XB'#13#10'Content-Disposition: form-data; name="file"; ' +
      'filename="data.bin"'#13#10'Content-Type: application/octet-stream' +
      #13#10#13#10 + MpContent + #13#10 +
      '--XB--'#13#10;
    C.SendRaw('POST /upload HTTP/1.1'#13#10'Host: test'#13#10 +
      'Content-Type: multipart/form-data; boundary=XB'#13#10 +
      'Content-Length: ' + IntToStr(Length(MpBody)) + #13#10#13#10 + MpBody);
    Check(C.ReadResponse(Head, Body), 'the upload was answered');
    CheckEqS(Body, 'Report|data.bin|' + IntToStr(Length(MpContent)) + '|' +
      MpContent, 'the file and the field came whole through the socket');

    C.SendRaw('POST /ekko HTTP/1.1'#13#10'Host: test'#13#10 +
              'Content-Length: 11'#13#10#13#10'hello arena');
    C.ReadResponse(Head, Body);
    CheckEqS(Body, 'hello arena', 'a POST body is read');

    { Pipelining: to requests i én skriving. }
    C.SendRaw('GET / HTTP/1.1'#13#10'Host: test'#13#10#13#10 +
              'GET /name?name=to HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    C.ReadResponse(Head, Body);
    CheckEqS(Body, 'rot', 'pipelining, the first reply');
    C.ReadResponse(Head, Body);
    CheckEqS(Body, 'to', 'pipelining, the second reply');

    { An exception in the handler is to cost the request, not the
      worker. }
    C.SendRaw('GET /boom HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    C.ReadResponse(Head, Body);
    Check(Pos('HTTP/1.1 500', Head) = 1, 'an exception gives 500');
    C.Close;

    Check(C.Connect(Port), 'the server survives an exception');
    C.SendRaw('GET / HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    C.ReadResponse(Head, Body);
    CheckEqS(Body, 'rot', 'a new connection works');
    C.Close;

    { The errors the framework answers for you, for a client that is not a
      browser.

      A 404 as an HTML page is not an answer to a program: it has to read
      the status out of something, and the body it was handed is the wrong
      kind of document. RFC 9457 says what the right one looks like, and
      the content type -- application/problem+json, not application/json --
      is what tells a client the body is the error rather than the thing
      it asked for. }
    Check(C.Connect(Port), 'connects for the error shapes');

    C.SendRaw('GET /nowhere HTTP/1.1'#13#10'Host: test'#13#10 +
              'Accept: application/json'#13#10#13#10);
    C.ReadResponse(Head, Body);
    Check(Pos('HTTP/1.1 404', Head) = 1, 'a JSON client gets the 404');
    Check(Pos('application/problem+json', Head) > 0,
      'as a problem document, not as a page');
    CheckEqS(ProblemMember(Body, 'title'), 'Not Found', 'with the title');
    CheckEqS(ProblemMember(Body, 'status'), '404', 'and the status in it');
    CheckEqS(ProblemMember(Body, 'type'), 'about:blank',
      'and about:blank until an app has a page to point at');
    Check(Pos('<', Body) = 0, 'and no markup anywhere in it');

    { And the browser is left exactly as it was. The body it used to get
      is the body it still gets -- this is negotiation, not a new default
      for everybody. }
    C.SendRaw('GET /nowhere HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    C.ReadResponse(Head, Body);
    CheckEqS(Body, 'Not Found', 'a client that said nothing gets the text');
    Check(Pos('text/plain', Head) > 0, 'as text/plain');

    { The Accept header a browser really sends. It lists several types and
      none of them is application/json, so a bare substring test would have
      been enough here -- the one below is the case that needs the
      ordering. }
    C.SendRaw('GET /nowhere HTTP/1.1'#13#10'Host: test'#13#10 +
              'Accept: text/html,application/xhtml+xml,application/xml;' +
              'q=0.9,*/*;q=0.8'#13#10#13#10);
    C.ReadResponse(Head, Body);
    CheckEqS(Body, 'Not Found', 'a browser is given the page answer');
    Check(Pos('problem+json', Head) = 0, 'and never a problem document');

    { The header axios sends by default, which is what most of the
      machine clients out there are. JSON is named first. }
    C.SendRaw('GET /nowhere HTTP/1.1'#13#10'Host: test'#13#10 +
              'Accept: application/json, text/plain, */*'#13#10#13#10);
    C.ReadResponse(Head, Body);
    Check(Pos('problem+json', Head) > 0, 'axios'' own Accept gets JSON');

    { Both named, page first. This is the case the ordering rule exists
      for, and the only one that tells the two readings apart: a bare
      search for 'application/json' in the header answers yes here and is
      wrong. Quality values would be the thorough way; order is what
      clients actually express. }
    C.SendRaw('GET /nowhere HTTP/1.1'#13#10'Host: test'#13#10 +
              'Accept: text/html, application/json'#13#10#13#10);
    C.ReadResponse(Head, Body);
    CheckEqS(Body, 'Not Found', 'asked for a page first, given a page');
    Check(Pos('problem+json', Head) = 0, 'and not a problem document');

    { The 500 after an unhandled exception. The status and the shape are
      the easy half; the body is the half that matters. }
    C.SendRaw('GET /boom HTTP/1.1'#13#10'Host: test'#13#10 +
              'Accept: application/json'#13#10#13#10);
    C.ReadResponse(Head, Body);
    Check(Pos('HTTP/1.1 500', Head) = 1, 'a JSON client gets the 500');
    Check(Pos('application/problem+json', Head) > 0, 'as a problem document');
    CheckEqS(ProblemMember(Body, 'title'), 'Internal Server Error',
      'titled by the status and nothing else');
    Check(Pos(BoomSecret, Body) = 0, 'the exception message is not in it');
    Check(Pos('hunter2', Body) = 0, 'not the value it carried');
    Check(Pos('/Users/askr', Body) = 0, 'nor the path');
    Check(Pos('detail', Body) = 0, 'there is no detail to give');
    C.Close;

    Check(C.Connect(Port), 'connects again after the 500');
    C.SendRaw('GET /boom HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    C.ReadResponse(Head, Body);
    CheckEqS(Body, 'Internal Server Error', 'and the text client likewise');
    Check(Pos(BoomSecret, Body) = 0,
      'the leak is closed on both sides, not just the new one');
    C.Close;

    { An exception that knows what it should become. A refused
      authorisation is a 403; it was a 500 until EHttpError existed, and
      a working guard that answers 500 looks like a broken server. }
    Check(C.Connect(Port), 'connects for the refusals');
    C.SendRaw('GET /refused HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    C.ReadResponse(Head, Body);
    Check(Pos('HTTP/1.1 403', Head) = 1, 'a refusal is 403, not 500');
    CheckEqS(Body, 'Forbidden', 'with the status text and nothing else');
    { The same rule as the 500: the message is where the detail is, and
      the detail is what must not travel. A 403 that explains itself
      tells whoever hit it what they nearly got. }
    Check(Pos(RefusedSecret, Body) = 0, 'the message is not in the body');
    Check(Pos('orders:write', Body) = 0, 'nor the gate it names');

    { And the connection is still good. A refusal is an ordinary answer
      and the caller usually asks something else next; only a fault costs
      the connection. }
    C.SendRaw('GET / HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    C.ReadResponse(Head, Body);
    CheckEqS(Body, 'rot', 'and the connection stays open after a 403');

    C.SendRaw('GET /refused HTTP/1.1'#13#10'Host: test'#13#10 +
              'Accept: application/json'#13#10#13#10);
    C.ReadResponse(Head, Body);
    Check(Pos('HTTP/1.1 403', Head) = 1, 'a JSON client gets the 403');
    Check(Pos('application/problem+json', Head) > 0, 'as a problem document');
    CheckEqS(ProblemMember(Body, 'title'), 'Forbidden', 'titled');
    Check(Pos('detail', Body) = 0, 'and with nothing to add');

    { Silence is the default, not the only option. An application that
      wants to say something says it in PublicDetail, on purpose. }
    C.SendRaw('GET /shipped HTTP/1.1'#13#10'Host: test'#13#10 +
              'Accept: application/json'#13#10#13#10);
    C.ReadResponse(Head, Body);
    Check(Pos('HTTP/1.1 409', Head) = 1, 'and any other status it names');
    CheckEqS(ProblemMember(Body, 'detail'),
      'That order has already shipped.', 'with the detail it chose');
    Check(Pos('table orders', Body) = 0,
      'and still not the message it was raised with');
    C.Close;

    { Ugyldig request. }
    Check(C.Connect(Port), 'connects for the invalid request');
    C.SendRaw('GET / HTTP/1.1'#13#10#13#10);
    C.ReadResponse(Head, Body);
    Check(Pos('HTTP/1.1 400', Head) = 1, 'a missing Host gives 400');
    C.Close;

    Check(C.Connect(Port), 'kobler til for chunked');
    C.SendRaw('POST / HTTP/1.1'#13#10'Host: t'#13#10 +
              'Transfer-Encoding: chunked'#13#10#13#10);
    C.ReadResponse(Head, Body);
    Check(Pos('HTTP/1.1 501', Head) = 1, 'chunked gives 501');
    C.Close;

    { The arena is to level off under load, not grow per request. }
    Check(C.Connect(Port), 'connects for the load test');
    for I := 1 to 50 do
    begin
      C.SendRaw('GET /name?name=oppvarming HTTP/1.1'#13#10'Host: test'#13#10#13#10);
      C.ReadResponse(Head, Body);
    end;
    C.SendRaw('GET / HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    C.ReadResponse(Head, Body);
    Reserved1 := Server.TotalArenaReserved;
    for I := 1 to 500 do
    begin
      C.SendRaw('GET /name?name=last HTTP/1.1'#13#10'Host: test'#13#10#13#10);
      C.ReadResponse(Head, Body);
    end;
    Reserved2 := Server.TotalArenaReserved;
    CheckEqI(Reserved2, Reserved1, 'the arena does not grow under sustained load');
    Check(Server.TotalArenaHighWater < 64 * 1024,
      'toppforbruket per request holder seg lite');
    { 35 valid requests above, then 50 + 1 + 500 here. The two rejected
      ones (400 and 501) are not counted, because they never reached a
      handler. The number is written out rather than computed: the point
      of it is that the server's own count agrees with what the suite
      actually sent, and a computed one would agree with itself. }
    CheckEqI(Server.TotalRequests, 587, 'every valid request was counted');
    C.Close;
  finally
    Server.Free;
    H.Free;
  end;
end;

{ ------------------------------------------------------- event streams -- }

type
  TStreamHandler = class
    function Handle(Req: TRequest): TResponse;
  end;

function TStreamHandler.Handle(Req: TRequest): TResponse;
begin
  if Req.Path.EqualsStr('/events') then
    Result := StreamEvents(['news'])
  else
    Result := RespondText('pong');
end;

{ Reads until Needle is in what has come, or the time is up. }
function ReadUntil(var C: TClient; const Needle: string; Ms: Integer): Boolean;
var
  Deadline: Int64;
begin
  Deadline := MonotonicMs + Ms;
  while Pos(Needle, C.Buf) = 0 do
  begin
    if MonotonicMs > Deadline then
      Exit(False);
    if not C.FillOnce then
      Exit(Pos(Needle, C.Buf) > 0);
  end;
  Result := True;
end;

function WaitForStreams(N, Ms: Integer): Boolean;
var
  Deadline: Int64;
begin
  Deadline := MonotonicMs + Ms;
  while OpenStreams <> N do
  begin
    if MonotonicMs > Deadline then
      Exit(False);
    Sleep(10);
  end;
  Result := True;
end;

procedure TestEventStreams;
var
  Opts: TServerOptions;
  Server: TAskrServer;
  H: TStreamHandler;
  A, B, C, D, E: TClient;
  Head, Body, Id: string;
  Raised: Boolean;
begin
  WriteLn;
  WriteLn('event streams');
  Raised := False;
  try
    StreamEvents(['has space']);
  except
    on EStreamError do Raised := True;
  end;
  Check(Raised, 'a channel name with a space in it is refused');

  SetStreamHeartbeat(300);
  SetMaxStreams(2);
  SetStreamReplay(100);
  Opts := DefaultServerOptions;
  Opts.Port := 0;
  { One worker: with a stream open, the next request still has to be
    answered, which it would not be if the stream held the worker. }
  Opts.Workers := 1;
  H := TStreamHandler.Create;
  Server := TAskrServer.Create(Opts);
  try
    Server.SetHandler(H.Handle);
    Server.Start;

    Check(A.Connect(Server.BoundPort), 'a client connects');
    A.SendRaw('GET /events HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    Check(ReadUntil(A, 'retry: 3000', 2000), 'the stream opens, and says how long to wait before reconnecting');
    Head := Copy(A.Buf, 1, Pos(#13#10#13#10, A.Buf));
    Check(Pos('HTTP/1.1 200', Head) = 1, 'with a 200');
    Check(Pos('Content-Type: text/event-stream', Head) > 0, 'as text/event-stream');
    Check(Pos('Content-Length', Head) = 0, 'with no length: the body is whatever comes');
    Check(Pos('X-Accel-Buffering: no', Head) > 0, 'and a word to nginx not to hold it back');

    Check(B.Connect(Server.BoundPort), 'another client connects');
    B.SendRaw('GET /ping HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    Check(B.ReadResponse(Head, Body) and (Body = 'pong'),
      'and is answered by the one worker, with the stream still open');
    B.Close;
    Check(WaitForStreams(1, 2000), 'one stream is open');

    Broadcast('other', 'x', 'not for this stream');
    Broadcast('news', 'hello', 'line one' + #10 + 'line two');
    Check(ReadUntil(A, 'data: line two' + #10#10, 2000), 'a broadcast on its channel reaches it');
    Check(Pos('event: hello' + #10 + 'data: line one' + #10 + 'data: line two', A.Buf) > 0,
      'with the event name and a data line for each line');
    Check(Pos('not for this stream', A.Buf) = 0, 'and one on another channel does not');
    Id := Copy(A.Buf, Pos('id: ', A.Buf) + 4, MaxInt);
    Id := Copy(Id, 1, Pos(#10, Id) - 1);
    Check(StrToInt64Def(Id, 0) > 0, 'each event has an id');
    Check(ReadUntil(A, ': ping', 2000), 'a quiet stream gets its comment line');

    Broadcast('news', 'second', 'missed');
    Check(C.Connect(Server.BoundPort), 'a stream reconnects');
    C.SendRaw('GET /events HTTP/1.1'#13#10'Host: test'#13#10'Last-Event-ID: ' + Id + #13#10#13#10);
    Check(ReadUntil(C, 'event: second', 2000), 'and gets what it missed after the id it saw last');
    Check(Pos('event: hello', C.Buf) = 0, 'but not what it saw');

    Check(D.Connect(Server.BoundPort), 'a third stream connects');
    D.SendRaw('GET /events HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    Check(ReadUntil(D, #13#10#13#10, 2000) and (Pos('HTTP/1.1 503', D.Buf) = 1),
      'past the most streams allowed, a 503');
    D.Close;

    A.Close;
    C.Close;
    Check(WaitForStreams(0, 3000), 'a stream whose client went away is closed');

    { One left open for the server to close. }
    Check(E.Connect(Server.BoundPort), 'a last stream connects');
    E.SendRaw('GET /events HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    Check(ReadUntil(E, 'retry: 3000', 2000) and WaitForStreams(1, 2000), 'and is open');
  finally
    Server.Stop;
    Server.Free;
    H.Free;
    SetStreamHeartbeat(15000);
    SetMaxStreams(1000);
  end;
  Check(OpenStreams = 0, 'stopping the server closes the streams it had');
  E.Close;
end;

{ ------------------------------------------------------------ websockets -- }

type
  TWsTestHandler = class(TWsHandler)
    Log: string;
    procedure Opened(C: TWsConnection); override;
    procedure Text(C: TWsConnection; const Msg: string); override;
    procedure Closed(C: TWsConnection; Code: Word); override;
  end;

  TWsHost = class
    Handler: TWsTestHandler;
    function Handle(Req: TRequest): TResponse;
  end;

procedure TWsTestHandler.Opened(C: TWsConnection);
begin
  Log := Log + 'open:' + C.UserId + ' ';
end;

procedure TWsTestHandler.Text(C: TWsConnection; const Msg: string);
begin
  C.SendText('echo:' + Msg);
end;

procedure TWsTestHandler.Closed(C: TWsConnection; Code: Word);
begin
  Log := Log + 'closed:' + IntToStr(Code) + ' ';
end;

function TWsHost.Handle(Req: TRequest): TResponse;
begin
  if Req.Path.EqualsStr('/ws') then
    Result := AcceptWebSocket(Req, Handler, ['room'], 'user-7')
  else
    Result := RespondText('pong');
end;

{ A client's frame: masked, as a client's has to be, unless told not to. }
function ClientFrame(Opcode: Byte; const Payload: string; Masked: Boolean = True): string;
const
  Key: array[0..3] of Byte = ($12, $34, $56, $78);
var
  I: Integer;
begin
  Result := Chr($80 or Opcode);
  if Masked then
    Result := Result + Chr($80 or Length(Payload)) + Chr(Key[0]) + Chr(Key[1]) +
      Chr(Key[2]) + Chr(Key[3])
  else
    Result := Result + Chr(Length(Payload));
  for I := 1 to Length(Payload) do
    if Masked then
      Result := Result + Chr(Ord(Payload[I]) xor Key[(I - 1) mod 4])
    else
      Result := Result + Payload[I];
end;

const
  WsHandshake = 'GET /ws HTTP/1.1'#13#10'Host: test'#13#10'Upgrade: websocket'#13#10 +
    'Connection: Upgrade'#13#10'Sec-WebSocket-Version: 13'#13#10 +
    'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=='#13#10;

function WaitForSockets(N, Ms: Integer): Boolean;
var
  Deadline: Int64;
begin
  Deadline := MonotonicMs + Ms;
  while OpenWebSockets <> N do
  begin
    if MonotonicMs > Deadline then
      Exit(False);
    Sleep(10);
  end;
  Result := True;
end;

procedure TestWebSockets;
var
  Opts: TServerOptions;
  Server: TAskrServer;
  Host: TWsHost;
  A, B, C, D, E: TClient;
  Head, Body: string;
begin
  WriteLn;
  WriteLn('websockets');
  CheckEqS(WebSocketAccept('dGhlIHNhbXBsZSBub25jZQ=='), 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=',
    'the accept value is RFC 6455''s own example');

  Opts := DefaultServerOptions;
  Opts.Port := 0;
  Opts.Workers := 1;
  Host := TWsHost.Create;
  Host.Handler := TWsTestHandler.Create;
  Server := TAskrServer.Create(Opts);
  try
    Server.SetHandler(Host.Handle);
    Server.Start;

    { The handshake and the first frame in one write: the frame is in the
      worker's buffer when it hands over, and has to go with it. }
    Check(A.Connect(Server.BoundPort), 'a client connects');
    A.SendRaw(WsHandshake + #13#10 + ClientFrame($1, 'first'));
    Check(ReadUntil(A, 'echo:first', 2000), 'a frame sent with the handshake is not lost');
    Check(Pos('HTTP/1.1 101 Switching Protocols', A.Buf) = 1, 'the answer is 101');
    Check(Pos('Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=', A.Buf) > 0, 'with the accept value');
    Check(Pos('open:user-7', Host.Handler.Log) > 0, 'the handler hears it open, with the user the route gave');

    Check(B.Connect(Server.BoundPort), 'another client connects');
    B.SendRaw('GET /ping HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    Check(B.ReadResponse(Head, Body) and (Body = 'pong'),
      'and the one worker answers it, with the websocket open');
    B.Close;

    A.SendRaw(ClientFrame($1, 'again'));
    Check(ReadUntil(A, 'echo:again', 2000), 'a message and its answer');
    Broadcast('elsewhere', 'said', 'not for this one');
    Broadcast('room', 'said', 'hello');
    Check(ReadUntil(A, '"data":"hello"', 2000), 'a broadcast on its channel reaches it');
    Check(Pos('not for this one', A.Buf) = 0, 'and one on another channel does not');
    Check(Pos('{"id":', A.Buf) > 0, 'as JSON with the id and the event');

    Check(C.Connect(Server.BoundPort), 'a client that does not mask connects');
    C.SendRaw(WsHandshake + #13#10 + ClientFrame($1, 'bare', False));
    Check(ReadUntil(C, #$88#$02#$03#$EA, 2000), 'and is closed with 1002, as the RFC says');
    C.Close;

    Check(D.Connect(Server.BoundPort), 'a page from another site tries');
    D.SendRaw(WsHandshake + 'Origin: https://evil.example'#13#10#13#10);
    Check(D.ReadResponse(Head, Body) and (Pos('HTTP/1.1 403', Head) = 1),
      'and is refused: its cookies are the signed-in user''s');
    D.Close;

    Check(E.Connect(Server.BoundPort), 'an old client connects');
    E.SendRaw(StringReplace(WsHandshake, 'Version: 13', 'Version: 8', []) + #13#10);
    Check(E.ReadResponse(Head, Body) and (Pos('HTTP/1.1 426', Head) = 1) and
      (Pos('Sec-WebSocket-Version: 13', Head) > 0), 'another version is 426, saying which it takes');
    E.Close;

    A.SendRaw(ClientFrame($8, #$03#$E8));
    Check(ReadUntil(A, #$88#$02#$03#$E8, 2000), 'a close is answered with the same code');
    Check(WaitForSockets(0, 2000) and (Pos('closed:1000', Host.Handler.Log) > 0),
      'the connection goes, and the handler hears the code');
    A.Close;

    { One left open for the server to close. }
    Check(A.Connect(Server.BoundPort), 'a last client connects');
    A.Buf := '';
    A.SendRaw(WsHandshake + #13#10);
    Check(ReadUntil(A, #13#10#13#10, 2000) and WaitForSockets(1, 2000), 'and is open');
  finally
    Server.Stop;
    Server.Free;
    Host.Handler.Free;
    Host.Free;
  end;
  Check(OpenWebSockets = 0, 'stopping the server closes its websockets');
  A.Close;
end;

begin
  { This suite does not test the log, and the end-to-end part raises in
    /boom on purpose. Without this an ERROR line lands in the middle of the
    output and looks like a failure in the test. }
  SetLogLevel(llNone);
  WriteLn('Askr — test suite for phase 1, step 1');

  TestArena;
  TestArenaNew;
  TestArenaFinalisering;
  TestArenaDefer;
  TestText;
  TestHttpTypes;
  TestRequest;
  TestMultipart;
  TestResponse;
  TestClock;
  TestJsonWrite;
  TestJsonRead;
  TestInertia;
  TestHiddenColumns;
  TestRuter;
  TestMiddlewareOrder;
  TestValidering;
  TestBinding;
  TestNornSchema;
  TestNornNaming;
  TestCache;
  TestModellLivskvalitet;
  TestQueue;
  TestSqlite;
  TestSchemaDrift;
  TestEndToEnd;
  TestEventStreams;
  TestWebSockets;

  WriteLn;
  WriteLn(Format('%d ok, %d failed', [Passed, Failed]));
  if Failed > 0 then
    Halt(1);
end.
