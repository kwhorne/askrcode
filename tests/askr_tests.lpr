{ Testsuite for Askr fase 1, steg 1: arena og HTTP-vert.

  Kjøres med `./askr test` eller direkte. Exit-kode 1 ved feil, slik at CI
  kan bruke den uten videre. Testrammeverket i PRD-en (Askr.Testing) kommer i
  fase 2; dette er med vilje bare nok til å holde steg 1 ærlig. }
program AskrTests;

{$mode Delphi}{$H+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  SysUtils, StrUtils, Classes, Sockets, BaseUnix,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Clock,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response, Askr.Http.Server,
  Askr.Http.Multipart, Askr.Http.Static, Askr.Core.Log,
  Askr.Core.Json, Askr.Http.Router, Askr.Urd.Driver, Askr.Urd.Model,
  Askr.Urd.Bind, Askr.Norn.Schema, Askr.Norn.Introspect, Askr.Norn.Codegen,
  Askr.Inertia, Askr.Urd.Query, Askr.Urd.Sqlite, Askr.Urd.Grid,
  Askr.Cache, Askr.Queue;

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
    WriteLn('         forventet: ', Expected);
    WriteLn('         fikk:      ', Actual);
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
    WriteLn('    FEIL ', Name, ' — forventet ', Expected, ', fikk ', Actual);
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
  Name := 'ting';
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
    Check(P1 <> nil, 'Alloc gir minne');
    CheckEqI(PtrUInt(P2) - PtrUInt(P1), ArenaAlignment,
      'allokeringer er alignet til ' + IntToStr(ArenaAlignment));
    CheckEqI(A.BytesLive, 2 * ArenaAlignment, 'BytesLive teller utdelt minne');

    A.Reset;
    CheckEqI(A.BytesLive, 0, 'Reset nullstiller BytesLive');
    P3 := A.Alloc(10);
    Check(P3 = P1, 'Reset gjenbruker de samme adressene');
    CheckEqI(A.ResetCount, 1, 'ResetCount teller requests');

    { Kjernepåstanden i PRD-en: arenaen slutter å be OS om mer minne. }
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
    CheckEqI(Reserved2, Reserved1, 'BytesReserved flater ut etter oppvarming');

    A.Reset;
    P1 := A.Alloc(1024 * 1024);
    Check(P1 <> nil, 'stor allokering får egen blokk');
    A.Trim;
    CheckEqI(A.BlockCount, 1, 'Trim frigir alt unntatt første blokk');

    A.Reset;
    Resets := A.ResetCount;
    M := A.Mark;
    A.Alloc(64);
    A.Rewind(M);
    CheckEqI(A.BytesLive, M.Live, 'Rewind spoler tilbake til merket');
    CheckEqI(A.ResetCount, Resets, 'Rewind teller ikke som request-grense');

    { Objekter i arenaen: constructor kjører, destructor gjør det aldri. }
    A.Reset;
    Prev := UseArena(A);
    try
      T := TThing.Create(42);
      CheckEqI(T.Value, 42, 'constructor kjører på arena-objekt');
      Check(T.IsArenaAllocated, 'objektet vet at det ligger i arenaen');
      Check(A.BytesLive >= T.InstanceSize, 'objektet ble allokert i arenaen');
      T.Free;   { skal være en no-op }
      CheckEqI(T.Value, 42, 'Free på arena-objekt rører ikke minnet');
    finally
      UseArena(Prev);
    end;

    { Without omgivende arena skal klassen oppføre seg som en vanlig TObject. }
    T := TThing.Create(7);
    Check(not T.IsArenaAllocated, 'uten arena faller TArenaObject til heapen');
    T.Free;
  finally
    A.Free;
  end;
end;

{ ------------------------------------------------------------ arena New<T> -- }

type
  TDyr = class(TArenaObject)
  private
    FLyd: string;
  public
    Bein: Integer;
    constructor Create;
    function Lyd: string; virtual;
    function Klassenavn: string;
  end;

  TKatt = class(TDyr)
  public
    constructor Create;
    function Lyd: string; override;
  end;

constructor TDyr.Create;
begin
  inherited Create;
  Bein := 4;
  FLyd := 'udefinert';
end;

function TDyr.Lyd: string;
begin
  Result := FLyd;
end;

function TDyr.Klassenavn: string;
begin
  Result := ClassName;
end;

constructor TKatt.Create;
begin
  inherited Create;
  FLyd := 'mjau';
end;

function TKatt.Lyd: string;
begin
  Result := 'Katt sier ' + FLyd;
end;

procedure TestArenaNew;
var
  A, B: TArena;
  Prev: TArena;
  K: TKatt;
  D: TDyr;
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
    K := A.New<TKatt>;
    Check(K <> nil, 'New<T> gir et objekt');
    Check(A.Owns(Pointer(K)), 'objektet ligger i arenaens eget minne');
    Check(not B.Owns(Pointer(K)), 'og ikke i en annen arena');
    Check(K.IsArenaAllocated, 'objektet vet selv at det er arena-allokert');
    Check(K.Arena = A, 'det peker på riktig arena');

    { Constructoren må ha kjørt — både egen og arvet. }
    CheckEqI(K.Bein, 4, 'arvet constructor kjørte');
    CheckEqS(K.Lyd, 'Katt sier mjau', 'egen constructor kjørte');

    { VMT-en må være riktig satt, ellers er objektet bare bytes. }
    CheckEqS(K.Klassenavn, 'TKatt', 'ClassName virker (VMT er på plass)');
    Check(K is TDyr, 'is-operatoren virker');
    Check(K.InheritsFrom(TDyr), 'arvekjeden er intakt');

    { Virtuelt kall gjennom basetypen må treffe overstyringen. }
    D := K;
    CheckEqS(D.Lyd, 'Katt sier mjau', 'virtuell dispatch gjennom basetypen');

    { New<T> skal treffe sin egen arena selv om en annen er omgivende. }
    Prev := UseArena(B);
    try
      K := A.New<TKatt>;
      Check(A.Owns(Pointer(K)), 'New<T> ignorerer omgivende arena');
      Check(not B.Owns(Pointer(K)), 'og forurenser ikke den omgivende');
      CheckEqS(K.Lyd, 'Katt sier mjau', 'objektet virker likevel');
    finally
      UseArena(Prev);
    end;
    CheckEqI(B.BytesLive, 0, 'den omgivende arenaen ble ikke rørt');

    { Reset skal gjenbruke det samme minnet. }
    A.Reset;
    K := A.New<TKatt>;
    Adresse1 := Pointer(K);
    A.Reset;
    K := A.New<TKatt>;
    Adresse2 := Pointer(K);
    Check(Adresse1 = Adresse2, 'Reset gjenbruker den samme adressen');
    CheckEqS(K.Lyd, 'Katt sier mjau', 'objektet er fullt brukbart etter Reset');

    { String-feltet i objektet må frigjøres av Reset, ikke lekke. }
    K.FLyd := 'en lyd lang nok til aa ligge paa heapen og ikke i datasegmentet';
    A.Reset;
    CheckEqI(Length(K.FLyd), 0, 'string-feltet ble finalisert av Reset');

    { Mange objekter: ingen skal overlappe, og arenaen skal flate ut. }
    A.Reset;
    Previous := nil;
    AllUnique := True;
    for I := 1 to 10000 do
    begin
      K := A.New<TKatt>;
      if Pointer(K) = Previous then
        AllUnique := False;
      Previous := Pointer(K);
      if K.Bein <> 4 then
        AllUnique := False;
    end;
    Check(AllUnique, '10 000 objekter fikk hver sin adresse og riktig innhold');
    Reservert := A.BytesReserved;
    for I := 1 to 10 do
    begin
      A.Reset;
      for J := 1 to 10000 do
        A.New<TKatt>;
    end;
    CheckEqI(A.BytesReserved, Reservert,
      'arenaen vokste ikke over ti runder med 10 000 objekter');
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

  { Only ShortString og tall — ingenting å finalisere. }
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
  Group('Arena — finalisering av string-felt');

  Check(ClassNeedsFinalization(TWithString),
    'klasse med string trenger finalisering');
  { TKatt deklarerer ingen managed felter selv, men arver ett fra TDyr.
    Egen init-tabell er tom, så sjekken må gå opp arvekjeden. }
  Check(ClassNeedsFinalization(TKatt),
    'underklasse som arver et string-felt trenger det også');
  Check(not ClassNeedsFinalization(TWithoutString),
    'klasse med bare ShortString gjør ikke det');
  Check(not ClassNeedsFinalization(TRequest),
    'TRequest betaler ingenting for mekanismen');
  Check(not ClassNeedsFinalization(TResponse),
    'TResponse heller ikke');

  A := TArena.Create(8192);
  Prev := UseArena(A);
  try
    U := TWithoutString.Create;
    U.Number := 1;
    Used := A.BytesLive;
    Check(Used <= U.InstanceSize + ArenaAlignment,
      'objekt uten managed felter koster ingen defer-node');

    M := TWithString.Create;
    { Ren ASCII, slik at Length teller det samme som antall tegn. }
    M.Name := 'en streng lang nok til aa havne paa heapen og ikke i datasegmentet';
    CheckEqI(Length(M.Name), 66, 'strengen ble satt');

    A.Reset;
    { After_ Reset er minnet gjenbrukbart. At strengen faktisk ble frigjort
      vises ved at refcounten falt — vi leser den ikke direkte, men
      finaliseringen nullstiller feltet. }
    CheckEqI(Length(M.Name), 0, 'Reset finaliserte string-feltet');
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
  raise Exception.Create('opprydning som svikter');
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
    CheckEqS(DeferSpor, '', 'ingenting kjører før Reset');
    A.Reset;
    CheckEqS(DeferSpor, 'ba', 'opprydning kjører i motsatt rekkefølge');

    DeferSpor := '';
    A.Reset;
    CheckEqS(DeferSpor, '', 'en opprydning kjører bare én gang');

    { Rewind rydder bare det som ble registrert etter merket. }
    DeferSpor := '';
    A.Defer(SporA, nil);
    M := A.Mark;
    A.Defer(SporB, nil);
    A.Defer(SporC, nil);
    A.Rewind(M);
    CheckEqS(DeferSpor, 'cb', 'Rewind rydder ned til merket');
    A.Reset;
    CheckEqS(DeferSpor, 'cba', 'resten venter på Reset');

    { En opprydning som kaster skal ikke stoppe de andre. }
    DeferSpor := '';
    A.Defer(SporA, nil);
    A.Defer(SporKaster, nil);
    A.Defer(SporB, nil);
    A.Reset;
    CheckEqS(DeferSpor, 'bxa', 'en opprydning som kaster stopper ikke Reset');
    CheckEqI(A.BytesLive, 0, 'arenaen ble likevel nullstilt');
  finally
    A.Free;
  end;

  { Destroy må rydde det som står igjen — nodene ligger i arenaen selv. }
  DeferSpor := '';
  A := TArena.Create(4096);
  A.Defer(SporA, nil);
  A.Defer(SporB, nil);
  A.Free;
  CheckEqS(DeferSpor, 'ba', 'Destroy rydder det som står igjen');
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
    S := Str('Hallo, verden');
    CheckEqI(S.Len, 13, 'Str tar lengden fra strengen');
    CheckEqS(S.ToString, 'Hallo, verden', 'ToString kopierer ut igjen');
    Check(S.EqualsStr('Hallo, verden'), 'EqualsStr er eksakt');
    Check(not S.EqualsStr('hallo, verden'), 'EqualsStr skiller store og små');
    Check(S.SameTextStr('HALLO, VERDEN'), 'SameText ignorerer ASCII-kasus');
    Check(S.StartsWithStr('Hallo'), 'StartsWithStr');
    CheckEqI(S.IndexOfByte(Ord(',')), 5, 'IndexOfByte');
    CheckEqS(S.Slice(7).ToString, 'verden', 'Slice til enden');
    CheckEqS(S.Slice(0, 5).ToString, 'Hallo', 'Slice med lengde');
    CheckEqS(Str('  tekst  ').TrimSpace.ToString, 'tekst', 'TrimSpace');

    Check(S.SplitAt(Ord(','), L, R), 'SplitAt finner skilletegnet');
    CheckEqS(L.ToString, 'Hallo', 'SplitAt venstre');
    CheckEqS(R.TrimSpace.ToString, 'verden', 'SplitAt høyre');
    Check(not Str('uten').SplitAt(Ord(','), L, R), 'SplitAt uten treff');
    CheckEqS(L.ToString, 'uten', 'SplitAt uten treff gir hele strengen');

    Check(Str('12345').ToInt64(V) and (V = 12345), 'ToInt64 positiv');
    Check(Str('-42').ToInt64(V) and (V = -42), 'ToInt64 negativ');
    Check(not Str('12a').ToInt64(V), 'ToInt64 avviser søppel');
    Check(not Str('').ToInt64(V), 'ToInt64 avviser tom streng');
    Check(not Str('99999999999999999999').ToInt64(V),
      'ToInt64 avviser overflow i stedet for å pakke rundt');
    CheckEqI(Str('nei').ToIntDef(7), 7, 'ToIntDef');

    B.Init(A, 16);
    B.Append('a');
    B.AppendInt(0);
    B.AppendInt(-1);
    B.AppendInt(Low(Int64));
    CheckEqS(B.ToString, 'a0-1-9223372036854775808',
      'AppendInt takler Low(Int64)');

    { Vekst skal bevare innholdet. }
    B.Init(A, 16);
    for I := 1 to 100 do
      B.Append('0123456789');
    CheckEqI(B.Len, 1000, 'StrBuilder vokser');
    Check(B.Capacity >= 1000, 'kapasiteten fulgte med');
    CheckEqS(B.ToStr.Slice(990).ToString, '0123456789', 'innholdet overlevde vekst');

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
  Group('HTTP-typer');
  A := TArena.Create(4096);
  try
    Check(MethodFromStr(Str('GET')) = hmGet, 'GET');
    Check(MethodFromStr(Str('DELETE')) = hmDelete, 'DELETE');
    Check(MethodFromStr(Str('get')) = hmUnknown, 'metoder er case-sensitive');
    Check(MethodFromStr(Str('BREW')) = hmUnknown, 'ukjent metode');
    CheckEqS(StatusText(422), 'Unprocessable Content', 'StatusText');

    CheckEqS(UrlDecode(A, Str('a%20b')).ToString, 'a b', 'prosentdekoding');
    CheckEqS(UrlDecode(A, Str('a+b')).ToString, 'a+b', 'pluss er ikke mellomrom i sti');
    CheckEqS(UrlDecode(A, Str('a+b'), True).ToString, 'a b', 'pluss er mellomrom i query');
    CheckEqS(UrlDecode(A, Str('%C3%A6')).ToString, 'æ', 'utf-8 gjennom dekoding');
    CheckEqS(UrlDecode(A, Str('100%')).ToString, '100%', 'ufullstendig %-sekvens beholdes');
    CheckEqS(UrlDecode(A, Str('%zz')).ToString, '%zz', 'ugyldig hex beholdes');

    Check(QueryValue(A, Str('a=1&name=Knut&b=2'), 'name', V) and V.EqualsStr('Knut'),
      'QueryValue finner verdi');
    Check(QueryValue(A, Str('tom=&x=1'), 'tom', V) and V.IsEmpty,
      'QueryValue med tom verdi');
    Check(not QueryValue(A, Str('a=1'), 'b', V), 'QueryValue uten treff');
    Check(QueryValue(A, Str('q=a%20b'), 'q', V) and V.EqualsStr('a b'),
      'QueryValue dekoder');
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

{ Bygger en multipart-kropp. Skrevet ut for hånd med eksplisitte CRLF-er,
  fordi det er nettopp CRLF-ene rundt grensene testen handler om. }
{ FileUtil hører til Lazarus, ikke til FPCs RTL. Ryddingen skrives derfor
  ut for hånd. }
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
      MpPart(G, 'form-data; name="doc"; filename="rapport.pdf"',
        'application/pdf', '%PDF-1.4 innhold') +
      '--' + G + '--' + #13#10;

    St := ParseWithBody(A, 'POST /upload HTTP/1.1'#13#10'Host: x'#13#10 +
      'Content-Type: multipart/form-data; boundary=' + G, Body_, Req);
    Check(St = psOk, 'requesten parser');
    Check(Req.IsMultipart, 'gjenkjent som multipart');
    Check(Req.Multipart.Ok, 'kroppen lot seg dele');

    { Vanlige felter skal fortsatt virke. Et skjema med en fil i skal ikke
      gjøre resten av feltene utilgjengelige — og CSRF-tokenet ligger i ett
      av dem. }
    CheckEqS(Req.Form('title').ToString, 'Årsrapport',
      'tekstfelt leses med Form');
    CheckEqS(Req.Form('_token').ToString, 'abc123',
      'CSRF-tokenet finnes i en multipart');
    Check(Req.HasForm('title'), 'HasForm finner feltet');
    Check(not Req.HasForm('finnes-ikke'), 'og ikke et som mangler');

    F := Req.Upload('doc');
    Check(not F.IsEmpty, 'fila kom med');
    CheckEqS(F.ClientName.ToString, 'rapport.pdf', 'filnavnet fra klienten');
    CheckEqS(F.ContentType.ToString, 'application/pdf', 'content-type');
    CheckEqS(F.Content.ToString, '%PDF-1.4 innhold', 'innholdet er intakt');
    CheckEqI(F.Size, Length('%PDF-1.4 innhold'), 'størrelsen stemmer');

    { Innholdet skal være et utsnitt inn i kroppen, ikke en kopi. Det er
      hele grunnen til at parseren er skrevet slik. }
    Check((PtrUInt(F.Content.Data) >= PtrUInt(Req.Body.Data)) and
          (PtrUInt(F.Content.Data) < PtrUInt(Req.Body.Data) + Req.Body.Len),
      'innholdet peker inn i kroppen, uten kopi');

    Check(Req.Upload('finnes-ikke').IsEmpty, 'et felt som ikke finnes er tomt');

    { ---- grenser som er lette å bomme på ---- }
    A.Reset;
    { Binært innhold med CRLF og med noe som ligner grensen inni. Kutter
      parseren på feil sted, blir fila ødelagt uten at noe sier fra. }
    Bin := 'AB'#13#10'--ikke-grensen'#13#10#0#1#2#255'CD';
    Body_ := MpPart(G, 'form-data; name="f"; filename="a.bin"',
      'application/octet-stream', Bin) + '--' + G + '--' + #13#10;
    St := ParseWithBody(A, 'POST /u HTTP/1.1'#13#10'Host: x'#13#10 +
      'Content-Type: multipart/form-data; boundary=' + G, Body_, Req);
    Check(St = psOk, 'binær kropp parser');
    F := Req.Upload('f');
    CheckEqI(F.Size, Length(Bin), 'binært innhold beholder hver byte');
    Check(CompareByte(F.Content.Data^, Bin[1], Length(Bin)) = 0,
      'også nullbyte og noe som ligner grensen');

    A.Reset;
    { Grensen i anførselstegn, som noen klienter sender. }
    Body_ := MpPart(G, 'form-data; name="a"', '', 'x') + '--' + G + '--'#13#10;
    St := ParseWithBody(A, 'POST /u HTTP/1.1'#13#10'Host: x'#13#10 +
      'Content-Type: multipart/form-data; boundary="' + G + '"', Body_, Req);
    CheckEqS(Req.Form('a').ToString, 'x', 'grense i anførselstegn');

    A.Reset;
    { More filer under samme navn: <input type="file" multiple>. }
    Body_ :=
      MpPart(G, 'form-data; name="bilder"; filename="en.png"', 'image/png', '1') +
      MpPart(G, 'form-data; name="bilder"; filename="to.png"', 'image/png', '22') +
      MpPart(G, 'form-data; name="annet"; filename="tre.txt"', 'text/plain', '333') +
      '--' + G + '--'#13#10;
    ParseWithBody(A, 'POST /u HTTP/1.1'#13#10'Host: x'#13#10 +
      'Content-Type: multipart/form-data; boundary=' + G, Body_, Req);
    More := Req.Uploads('bilder');
    CheckEqI(Length(More), 2, 'to filer under samme navn');
    CheckEqS(More[1].ClientName.ToString, 'to.png', 'rekkefølgen holder');
    CheckEqI(Length(Req.Uploads('annet')), 1, 'og én under et annet');

    A.Reset;
    { Et filfelt brukeren ikke fylte ut: tomt filnavn, null bytes. Det skal
      ikke se ut som en opplasting. }
    Body_ := MpPart(G, 'form-data; name="valgfri"; filename=""', '', '') +
      '--' + G + '--'#13#10;
    ParseWithBody(A, 'POST /u HTTP/1.1'#13#10'Host: x'#13#10 +
      'Content-Type: multipart/form-data; boundary=' + G, Body_, Req);
    Check(Req.Upload('valgfri').IsEmpty, 'et tomt filfelt er ikke en fil');

    A.Reset;
    { Ødelagte kropper skal gi Ok = False, ikke en exception og ikke en
      halv fil. }
    Body_ := MpPart(G, 'form-data; name="a"', '', 'x');  { uten avsluttende grense }
    ParseWithBody(A, 'POST /u HTTP/1.1'#13#10'Host: x'#13#10 +
      'Content-Type: multipart/form-data; boundary=' + G, Body_, Req);
    Check(not Req.Multipart.Ok, 'kropp uten avsluttende grense avvises');

    A.Reset;
    Body_ := 'ingenting som ligner';
    ParseWithBody(A, 'POST /u HTTP/1.1'#13#10'Host: x'#13#10 +
      'Content-Type: multipart/form-data; boundary=' + G, Body_, Req);
    Check(not Req.Multipart.Ok, 'søppel avvises');

    A.Reset;
    ParseWithBody(A, 'POST /u HTTP/1.1'#13#10'Host: x'#13#10 +
      'Content-Type: multipart/form-data', '', Req);
    Check(not Req.Multipart.Ok, 'multipart uten boundary avvises');
    Check(Req.Multipart.Error = mpNoBoundary, 'og sier hvorfor');

    A.Reset;
    { For mange deler. Grensen er mot en kropp som er liten, men som koster
      i parsing og allokering. }
    Body_ := '';
    for I := 1 to MaxMultipartParts + 5 do
      Body_ := Body_ + MpPart(G, 'form-data; name="f' + IntToStr(I) + '"',
        '', 'x');
    Body_ := Body_ + '--' + G + '--'#13#10;
    ParseWithBody(A, 'POST /u HTTP/1.1'#13#10'Host: x'#13#10 +
      'Content-Type: multipart/form-data; boundary=' + G, Body_, Req);
    Check(Req.Multipart.Error = mpTooManyParts, 'for mange deler avvises');
  finally
    A.Free;
  end;

  { ---- filnavn fra klienten er ikke til å stole på ---- }
  Group('Multipart: filnavn');
  CheckEqS(SanitizeFileName('bilde.jpg'), 'bilde.jpg', 'et vanlig navn står');
  CheckEqS(SanitizeFileName('../../etc/passwd'), 'passwd',
    'katalogtraversering fjernes');
  CheckEqS(SanitizeFileName('..\..\windows\system32\cmd.exe'), 'cmd.exe',
    'også med omvendt skråstrek');
  CheckEqS(SanitizeFileName('C:\Users\x\rapport.pdf'), 'rapport.pdf',
    'og med stasjonsbokstav');
  CheckEqS(SanitizeFileName('.bashrc'), 'bashrc',
    'ledende punktum fjernes');
  CheckEqS(SanitizeFileName('..'), 'upload', 'bare punktum blir upload');
  CheckEqS(SanitizeFileName(''), 'upload', 'tomt navn blir upload');
  CheckEqS(SanitizeFileName('a b;rm -rf *.txt'), 'a_b_rm_-rf__.txt',
    'skalltegn blir understrek');
  { Skråstreken er en katalogskille, ikke et tegn i navnet — også når den
    står midt i noe som ser ut som et navn. }
  CheckEqS(SanitizeFileName('a b;rm -rf /.txt'), 'txt',
    'alt før siste skråstrek er en sti og forsvinner');
  Check(Length(SanitizeFileName(StringOfChar('a', 400))) <= 200,
    'navnet kortes av');

  { ---- lagring ---- }
  Group('Multipart: lagring');
  A := TArena.Create(16 * 1024);
  Folder := '.build/upload-test';
  try
    Body_ := MpPart(G, 'form-data; name="f"; filename="../../onde.TXT"',
      'text/plain', 'hei') + '--' + G + '--'#13#10;
    ParseWithBody(A, 'POST /u HTTP/1.1'#13#10'Host: x'#13#10 +
      'Content-Type: multipart/form-data; boundary=' + G, Body_, Req);
    F := Req.Upload('f');
    CheckEqS(F.SafeName, 'onde.TXT', 'SafeName rydder navnet');
    CheckEqS(F.Extension, '.txt', 'endelsen er i små bokstaver');

    Path_ := F.StoreIn(Folder);
    Check(Path_ <> '', 'StoreIn skrev fila');
    Check(FileExists(Path_), 'og den finnes');
    { Klientens navn skal ikke nå filsystemet i det hele tatt. }
    Check(Pos('onde', Path_) = 0, 'klientens navn brukes ikke som filnavn');
    Check(Pos(Folder, Path_) = 1, 'og fila havnet i katalogen vi ba om');
    CheckEqS(ExtractFileExt(Path_), '.txt', 'men endelsen er med');

    L := TStringList.Create;
    try
      L.LoadFromFile(Path_);
      CheckEqS(Trim(L.Text), 'hei', 'innholdet kom uendret på disk');
    finally
      L.Free;
    end;

    { To lagringer av samme fil skal ikke skrive over hverandre. }
    Check(F.StoreIn(Folder) <> Path_, 'to lagringer gir to filer');
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
    St := ParseIn(A, 'GET /customers?side=2&q=a%20b HTTP/1.1'#13#10 +
                     'Host: askrcode.no'#13#10 +
                     'X-Tom:'#13#10 +
                     'Accept:  application/json  ', Req);
    Check(St = psOk, 'enkel GET parser');
    Check(Req.Method = hmGet, 'metode');
    CheckEqS(Req.Path.ToString, '/customers', 'sti');
    CheckEqS(Req.QueryString.ToString, 'side=2&q=a%20b', 'query string');
    CheckEqI(Req.VersionMinor, 1, 'HTTP/1.1');
    CheckEqI(Req.HeaderCount, 3, 'headere telt');
    CheckEqS(Req.Header('host').ToString, 'askrcode.no', 'header-oppslag');
    CheckEqS(Req.Header('HOST').ToString, 'askrcode.no', 'header-oppslag ignorerer kasus');
    CheckEqS(Req.Header('accept').ToString, 'application/json',
      'header-verdi trimmes');
    Check(Req.Header('x-tom').IsEmpty, 'tom header-verdi');
    Check(Req.HasHeader('x-tom'), 'tom header finnes likevel');
    CheckEqS(Req.Query('side').ToString, '2', 'query-parameter');
    CheckEqS(Req.Query('q').ToString, 'a b', 'query-parameter dekodes');
    Check(Req.KeepAlive, 'HTTP/1.1 er keep-alive som standard');

    A.Reset;
    St := ParseIn(A, 'GET /a%2Fb/%C3%A6 HTTP/1.1'#13#10'Host: x', Req);
    Check(St = psOk, 'prosentkodet sti');
    CheckEqS(Req.Path.ToString, '/a/b/æ', 'stien dekodes');
    CheckEqS(Req.RawPath.ToString, '/a%2Fb/%C3%A6', 'rå sti beholdes');

    A.Reset;
    St := ParseIn(A, 'GET http://askrcode.no/sti?x=1 HTTP/1.1'#13#10'Host: x', Req);
    Check(St = psOk, 'absolute-form target');
    CheckEqS(Req.Path.ToString, '/sti', 'absolute-form gir sti');
    CheckEqS(Req.QueryString.ToString, 'x=1', 'absolute-form gir query');

    A.Reset;
    St := ParseIn(A, 'GET /sti#frag HTTP/1.1'#13#10'Host: x', Req);
    Check(St = psOk, 'fragment i target');
    CheckEqS(Req.Path.ToString, '/sti', 'fragment fjernes');

    A.Reset;
    St := ParseIn(A, 'POST /skjema HTTP/1.1'#13#10 +
                     'Host: x'#13#10 +
                     'Content-Type: application/x-www-form-urlencoded'#13#10 +
                     'Content-Length: 19', Req);
    Check(St = psOk, 'POST med kropp');
    CheckEqI(Req.ContentLength, 19, 'Content-Length');
    Req.SetBody(StrDup(A, 'name=Knut&alder=40'));
    CheckEqS(Req.Form('name').ToString, 'Knut', 'Form leser fra kroppen');

    A.Reset;
    St := ParseIn(A, 'GET /kort HTTP/1.0'#13#10, Req);
    Check(St = psOk, 'HTTP/1.0 uten Host er greit');
    Check(not Req.KeepAlive, 'HTTP/1.0 lukker som standard');

    A.Reset;
    St := ParseIn(A, 'GET /kort HTTP/1.0'#13#10'Connection: keep-alive', Req);
    Check(Req.KeepAlive, 'HTTP/1.0 med Connection: keep-alive');

    A.Reset;
    St := ParseIn(A, 'GET / HTTP/1.1'#13#10'Host: x'#13#10'Connection: close', Req);
    Check(not Req.KeepAlive, 'Connection: close');

    { Avvisninger. }
    A.Reset;
    Check(ParseIn(A, 'GET / HTTP/1.1', Req) = psBadRequest,
      'HTTP/1.1 uten Host avvises');
    A.Reset;
    Check(ParseIn(A, 'GET /'#13#10'Host: x', Req) = psBadRequest,
      'request-linje uten versjon avvises');
    A.Reset;
    Check(ParseIn(A, 'GET / HTTP/2.0'#13#10'Host: x', Req) = psUnsupportedVersion,
      'HTTP/2 over klartekst avvises');
    A.Reset;
    Check(ParseIn(A, 'GET / HTTP/1.1'#13#10'Host: x'#13#10 +
      'Content-Length: 5'#13#10'Content-Length: 6', Req) = psBadRequest,
      'to ulike Content-Length avvises');
    A.Reset;
    Check(ParseIn(A, 'GET / HTTP/1.1'#13#10'Host: x'#13#10 +
      'Transfer-Encoding: chunked', Req) = psNotImplemented,
      'chunked avvises eksplisitt');
    A.Reset;
    Check(ParseIn(A, 'GET / HTTP/1.1'#13#10'Host: x'#13#10 +
      'X-Fold: a'#13#10' b', Req) = psBadRequest,
      'obsolete line folding avvises');
    A.Reset;
    Check(ParseIn(A, 'GET / HTTP/1.1'#13#10'Host : x', Req) = psBadRequest,
      'mellomrom foran kolon avvises');
    A.Reset;
    Check(ParseIn(A, 'GET / HTTP/1.1'#13#10'Host: x'#13#10 +
      'Content-Length: -1', Req) = psBadRequest,
      'negativ Content-Length avvises');
    A.Reset;
    Req := nil;
    Check(ParseIn(A, 'GET sti HTTP/1.1'#13#10'Host: x', Req) = psBadRequest,
      'target uten skråstrek avvises');
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
    Check(Pos('HTTP/1.1 200 OK'#13#10, Raw) = 1, 'statuslinje');
    Check(Pos('Content-Length: 3'#13#10, Raw) > 0, 'Content-Length');
    Check(Pos('Content-Type: text/plain; charset=utf-8'#13#10, Raw) > 0, 'Content-Type');
    Check(Pos('Connection: keep-alive'#13#10, Raw) > 0, 'Connection: keep-alive');
    Check(Pos('Date: '#13#10, Raw) = 0, 'Date er ikke tom');
    Check(Copy(Raw, Length(Raw) - 2, 3) = 'hei', 'kroppen sist');

    A.Reset;
    Raw := Serialize(A, RespondText('hei'), True, False);
    Check(Pos('Connection: close'#13#10, Raw) > 0, 'Connection: close');

    A.Reset;
    Raw := Serialize(A, RespondText('hei'), False, True);
    Check(Pos('Content-Length: 3'#13#10, Raw) > 0, 'HEAD beholder Content-Length');
    Check(Copy(Raw, Length(Raw) - 3, 4) = #13#10#13#10, 'HEAD utelater kroppen');

    A.Reset;
    Raw := Serialize(A, NoContent, False, False);
    Check(Pos('HTTP/1.1 204 No Content', Raw) = 1, '204');
    Check(Pos('Content-Length', Raw) = 0, '204 har ikke Content-Length');

    A.Reset;
    Raw := Serialize(A, Redirect('/customers', 303), False, False);
    Check(Pos('HTTP/1.1 303 See Other', Raw) = 1, '303');
    Check(Pos('Location: /customers'#13#10, Raw) > 0, 'Location');

    A.Reset;
    Res := Respond(200).WithHeader('X-A', 'en').WithHeader('X-A', 'to');
    Raw := Serialize(A, Res, False, False);
    CheckEqI(Res.HeaderCount, 1, 'samme header to ganger gir én');
    Check(Pos('X-A: to'#13#10, Raw) > 0, 'siste verdi vinner');
    CheckEqI(CountOf(Raw, 'X-A:'), 1, 'headeren skrives bare én gang');

    A.Reset;
    Res := Respond(200);
    { Tvinger vekst av header-tabellen forbi startkapasiteten. }
    Res.WithHeader('X-1', '1').WithHeader('X-2', '2').WithHeader('X-3', '3')
       .WithHeader('X-4', '4').WithHeader('X-5', '5').WithHeader('X-6', '6')
       .WithHeader('X-7', '7').WithHeader('X-8', '8').WithHeader('X-9', '9')
       .WithHeader('X-10', '10');
    Raw := Serialize(A, Res, False, False);
    CheckEqI(Res.HeaderCount, 10, 'header-tabellen vokser');
    Check(Pos('X-1: 1'#13#10, Raw) > 0, 'første header overlevde vekst');
    Check(Pos('X-10: 10'#13#10, Raw) > 0, 'siste header etter vekst');
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
  Group('Klokke');
  A := TArena.Create(4096);
  try
    B.Init(A, 64);
    AppendHttpDate(B, 784111777);
    CheckEqS(B.ToString, 'Sun, 06 Nov 1994 08:49:37 GMT',
      'RFC 9110-dato (eksempelet fra spesifikasjonen)');

    B.Init(A, 64);
    AppendHttpDate(B, 0);
    CheckEqS(B.ToString, 'Thu, 01 Jan 1970 00:00:00 GMT', 'epoch');

    B.Init(A, 64);
    AppendHttpDate(B, 951782400);
    CheckEqS(B.ToString, 'Tue, 29 Feb 2000 00:00:00 GMT', 'skuddår 2000');

    B.Init(A, 64);
    AppendHttpDate(B, 1709164800);
    CheckEqS(B.ToString, 'Thu, 29 Feb 2024 00:00:00 GMT', 'skuddår 2024');

    { Andre kall treffer trådcachen og må gi samme svar. }
    B.Init(A, 64);
    AppendHttpDate(B, 1709164800);
    CheckEqS(B.ToString, 'Thu, 29 Feb 2024 00:00:00 GMT', 'cachet dato er lik');

    Check(UnixNow > 1700000000, 'UnixNow er i vår tid');
    Check(MonotonicMs > 0, 'MonotonicMs teller');
  finally
    A.Free;
  end;
end;

{ ------------------------------------------------------------------ json -- }

procedure TestJsonSkriv;
var
  A: TArena;
  W: TJsonWriter;
  Value_: Currency;
begin
  Group('JSON — skriving');
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
      'objekt, array og nesting');
    CheckEqI(W.Depth, 0, 'alle nivåer lukket');

    W.Init(A, 64);
    W.BeginArray;
    W.EndArray;
    CheckEqS(W.ToString, '[]', 'tom array');

    W.Init(A, 64);
    W.BeginObject;
    W.EndObject;
    CheckEqS(W.ToString, '{}', 'tomt objekt');

    W.Init(A, 128);
    W.Str('anførsel " og bakstrek \ og linjeskift' + #10 + 'og tab' + #9);
    CheckEqS(W.ToString,
      '"anførsel \" og bakstrek \\ og linjeskift\nog tab\t"',
      'escaping av de vanlige');

    W.Init(A, 64);
    W.Str('styretegn' + #1 + #31);
    CheckEqS(W.ToString, '"styretegn\u0001\u001f"', 'styretegn kodes som \u');

    W.Init(A, 64);
    W.Str('æøå — 日本');
    CheckEqS(W.ToString, '"æøå — 日本"', 'UTF-8 slipper gjennom uendret');

    { Currency må aldri få desimalkomma, uansett locale. }
    Value_ := 1234.5;
    W.Init(A, 64);
    W.Money(Value_);
    CheckEqS(W.ToString, '1234.5', 'Currency med desimaler');
    Value_ := 1234;
    W.Init(A, 64);
    W.Money(Value_);
    CheckEqS(W.ToString, '1234', 'Currency uten desimaler');
    Value_ := -0.05;
    W.Init(A, 64);
    W.Money(Value_);
    CheckEqS(W.ToString, '-0.05', 'negativ Currency');

    W.Init(A, 64);
    W.Num(1.5);
    CheckEqS(W.ToString, '1.5', 'Double bruker punktum');

    W.Init(A, 64);
    W.Raw(Str('{"ferdig":1}'));
    CheckEqS(W.ToString, '{"ferdig":1}',
      'ferdig kodet JSON settes inn som det er');

    CheckEqS(HtmlAttrEscape(A, Str('<b>&"x"')).ToString,
      '&lt;b&gt;&amp;&quot;x&quot;', 'HTML-attributtescaping');
  finally
    A.Free;
  end;
end;

procedure TestJsonLes;
var
  A: TArena;
  V, M: PJsonValue;
  ErrPos: SizeInt;
begin
  Group('JSON — lesing');
  A := TArena.Create(8192);
  try
    Check(JsonParse(A, Str('{"a":1,"b":"to","c":true,"d":null,"e":[1,2]}'),
      V, ErrPos), 'parser et objekt');
    Check(V^.Kind = jkObject, 'rot er objekt');
    CheckEqI(V^.Count, 5, 'fem medlemmer');
    CheckEqI(JsonAsInt(JsonMember(V, 'a')), 1, 'tall');
    CheckEqS(JsonAsString(JsonMember(V, 'b')), 'to', 'streng');
    Check(JsonAsBool(JsonMember(V, 'c')), 'boolean');
    Check(JsonIsNull(JsonMember(V, 'd')), 'null');
    M := JsonMember(V, 'e');
    Check(M^.Kind = jkArray, 'array');
    CheckEqI(M^.Count, 2, 'to elementer');
    CheckEqI(JsonAsInt(JsonAt(M, 1)), 2, 'element etter indeks');
    Check(JsonMember(V, 'finnes-ikke') = nil, 'ukjent nøkkel gir nil');

    Check(JsonParse(A, Str('"med \" og \\ og \n"'), V, ErrPos),
      'escapes i streng');
    CheckEqS(JsonAsString(V), 'med " og \ og ' + #10, 'escapes avkodet');

    Check(JsonParse(A, Str('"æøå"'), V, ErrPos), 'u-escapes');
    CheckEqS(JsonAsString(V), 'æøå', 'u-escapes blir UTF-8');

    Check(JsonParse(A, Str('"😀"'), V, ErrPos), 'surrogatpar');
    CheckEqI(Length(JsonAsString(V)), 4, 'emoji er fire bytes i UTF-8');

    Check(JsonParse(A, Str('  [ 1 , 2 ]  '), V, ErrPos), 'whitespace');
    CheckEqI(V^.Count, 2, 'to elementer tross mellomrom');

    Check(JsonParse(A, Str('-12.5e3'), V, ErrPos), 'tall med eksponent');
    CheckEqS(JsonAsStr(V).ToString, '-12.5e3', 'tallet beholdes som tekst');

    Check(not JsonParse(A, Str('{"a":}'), V, ErrPos),
      'manglende verdi avvises');
    Check(not JsonParse(A, Str('{"a":1'), V, ErrPos),
      'uavsluttet objekt avvises');
    Check(not JsonParse(A, Str('[1,2] tull'), V, ErrPos),
      'søppel etter avvises');
    Check(not JsonParse(A, Str(''), V, ErrPos), 'tom streng avvises');
  finally
    A.Free;
  end;
end;

{ --------------------------------------------------------------- inertia -- }

function LagRequest(A: TArena; const Head: string): TRequest;
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

procedure TestInertia;
var
  A: TArena;
  PrevA: TArena;
  PrevR: TRequest;
  Req: TRequest;
  R: TResponse;
  Body, Raw: string;
begin
  Group('Inertia');
  A := TArena.Create(32 * 1024);
  PrevA := UseArena(A);
  PrevR := UseRequest(nil);
  try
    TInertia.SetVersion('abc123');

    { Without X-Inertia: hele HTML-skallet. }
    Req := LagRequest(A, 'GET /customers?side=2 HTTP/1.1'#13#10'Host: test');
    UseRequest(Req);
    { Propverdien inneholder med vilje noe som ville avsluttet script-blokka
      hvis escapingen ikke virket. }
    R := Inertia('Customers/Index',
      ['antall', Int64(3), 'ondsinnet', '</script><img src=x onerror=alert(1)>']);
    Raw := Reply(A, R);
    Check(Pos('text/html', Raw) > 0, 'vanlig request gir HTML');
    Check(Pos('</script><img', Raw) = 0,
      'en propverdi kan ikke bryte ut av script-blokka');
    { Only < og / escapes; > er ufarlig alene. }
    Check(Pos('\u003c\/script>', Raw) > 0,
      'den er escapet til \u003c og \/ i stedet');
    Check(Pos('<script data-page="app" type="application/json">', Raw) > 0,
      'Inertia 3 legger payloaden i et script-element');
    Check(Pos('<div id="app"></div>', Raw) > 0, 'tom monteringsdiv');

    { En side uten tittel er et alvorlig tilgjengelighetsbrudd, og det
      gjaldt hver eneste Inertia-side til dette kom på plass. Oppdaget ved
      å kjøre axe mot et nettsted bygget med rammeverket. }
    Check(Pos('<title>', Raw) > 0, 'skallet har en tittel');
    Check(Pos('<title></title>', Raw) = 0, 'og den er ikke tom');
    { lang må ikke være hardkodet norsk i et internasjonalt rammeverk. }
    Check(Pos('lang="en"', Raw) > 0, 'og lang er en, ikke no');

    TInertia.SetTitle('Ada & <Co>');
    Raw := Reply(A, Inertia('Customers/Index', ['antall', Int64(1)]));
    Check(Pos('<title>Ada &amp; &lt;Co&gt;</title>', Raw) > 0,
      'tittelen escapes — den er brukerkontrollert');
    TInertia.SetTitle('Askr');
    Check(Pos('"component":"Customers\/Index"', Raw) > 0,
      'skråstrek er escapet også i vanlige verdier');
    Check(Pos('Vary: X-Inertia', Raw) > 0, 'Vary settes også på HTML');

    { With_ X-Inertia: ren JSON. }
    A.Reset;
    Req := LagRequest(A, 'GET /customers?side=2 HTTP/1.1'#13#10'Host: test'#13#10 +
      'X-Inertia: true');
    UseRequest(Req);
    R := Inertia('Customers/Index', ['antall', Int64(3)]);
    Body := R.Body.ToString;
    Raw := Reply(A, R);
    Check(Pos('X-Inertia: true', Raw) > 0, 'X-Inertia settes på svaret');
    Check(Pos('application/json', Raw) > 0, 'Content-Type er JSON');
    CheckEqS(Body,
      '{"component":"Customers/Index","props":{"antall":3},' +
      '"url":"/customers?side=2","version":"abc123",' +
      '"clearHistory":false,"encryptHistory":false}',
      'payloaden er standard Inertia 3');

    { Versjonsavvik: klienten skal laste på nytt, ikke få en ubrukelig payload. }
    A.Reset;
    Req := LagRequest(A, 'GET /customers HTTP/1.1'#13#10'Host: test'#13#10 +
      'X-Inertia: true'#13#10'X-Inertia-Version: gammel');
    UseRequest(Req);
    R := Inertia('Customers/Index', ['antall', Int64(3)]);
    CheckEqI(R.StatusCode, 409, 'versjonsavvik gir 409');
    Check(Pos('X-Inertia-Location: /customers', Reply(A, R)) > 0,
      'og peker klienten på adressen igjen');

    A.Reset;
    Req := LagRequest(A, 'GET /customers HTTP/1.1'#13#10'Host: test'#13#10 +
      'X-Inertia: true'#13#10'X-Inertia-Version: abc123');
    UseRequest(Req);
    R := Inertia('Customers/Index', ['antall', Int64(3)]);
    CheckEqI(R.StatusCode, 200, 'riktig versjon slipper gjennom');

    { Delvis oppdatering: bare det klienten ba om. }
    A.Reset;
    Req := LagRequest(A, 'GET /customers HTTP/1.1'#13#10'Host: test'#13#10 +
      'X-Inertia: true'#13#10 +
      'X-Inertia-Partial-Component: Customers/Index'#13#10 +
      'X-Inertia-Partial-Data: customers');
    UseRequest(Req);
    R := Inertia('Customers/Index',
      ['customers', 'liste', 'statistikk', 'tung', 'meny', 'ting']);
    Check(Pos('"props":{"customers":"liste"}', R.Body.ToString) > 0,
      'bare den etterspurte propen er med');
    Check(Pos('statistikk', R.Body.ToString) = 0, 'resten er utelatt');

    A.Reset;
    Req := LagRequest(A, 'GET /customers HTTP/1.1'#13#10'Host: test'#13#10 +
      'X-Inertia: true'#13#10 +
      'X-Inertia-Partial-Component: Customers/Index'#13#10 +
      'X-Inertia-Partial-Except: statistikk');
    UseRequest(Req);
    R := Inertia('Customers/Index', ['customers', 'liste', 'statistikk', 'tung']);
    Check(Pos('statistikk', R.Body.ToString) = 0, 'Except utelater propen');
    Check(Pos('customers', R.Body.ToString) > 0, 'resten er med');

    { Delvis oppdatering for en annen komponent er en vanlig navigering. }
    A.Reset;
    Req := LagRequest(A, 'GET /customers HTTP/1.1'#13#10'Host: test'#13#10 +
      'X-Inertia: true'#13#10 +
      'X-Inertia-Partial-Component: Orders/Index'#13#10 +
      'X-Inertia-Partial-Data: order');
    UseRequest(Req);
    R := Inertia('Customers/Index', ['customers', 'liste']);
    Check(Pos('customers', R.Body.ToString) > 0,
      'partial for en annen komponent gir full payload');

    { Inertia 3: props klienten allerede har som «once» skal ikke sendes. }
    A.Reset;
    Req := LagRequest(A, 'GET /customers HTTP/1.1'#13#10'Host: test'#13#10 +
      'X-Inertia: true'#13#10 +
      'X-Inertia-Except-Once-Props: meny');
    UseRequest(Req);
    R := Inertia('Customers/Index', ['customers', 'liste', 'meny', 'ting']);
    Check(Pos('meny', R.Body.ToString) = 0,
      'once-prop klienten har fra før utelates');
    Check(Pos('customers', R.Body.ToString) > 0, 'resten er med');

    { Utsatte props: ikke med i første svar, men oppført i deferredProps. }
    A.Reset;
    Req := LagRequest(A, 'GET /customers HTTP/1.1'#13#10'Host: test'#13#10 +
      'X-Inertia: true');
    UseRequest(Req);
    R := Inertia('Customers/Index',
      ['customers', 'liste', 'statistikk', 'tung'], ['statistikk']);
    Check(Pos('"customers":"liste"', R.Body.ToString) > 0, 'vanlig prop er med');
    Check(Pos('"statistikk":"tung"', R.Body.ToString) = 0,
      'utsatt prop er ikke med i verdiene');
    Check(Pos('"deferredProps":{"default":["statistikk"]}', R.Body.ToString) > 0,
      'men den er oppført som utsatt');

    { Når klienten ber om den, kommer den. }
    A.Reset;
    Req := LagRequest(A, 'GET /customers HTTP/1.1'#13#10'Host: test'#13#10 +
      'X-Inertia: true'#13#10 +
      'X-Inertia-Partial-Component: Customers/Index'#13#10 +
      'X-Inertia-Partial-Data: statistikk');
    UseRequest(Req);
    R := Inertia('Customers/Index',
      ['customers', 'liste', 'statistikk', 'tung'], ['statistikk']);
    Check(Pos('"statistikk":"tung"', R.Body.ToString) > 0,
      'utsatt prop hentes i egen runde');
    Check(Pos('deferredProps', R.Body.ToString) = 0,
      'og oppføres ikke som utsatt lenger');

    { Omdirigering: 303 etter PUT, PATCH og DELETE. }
    A.Reset;
    Req := LagRequest(A, 'POST /customers HTTP/1.1'#13#10'Host: test');
    UseRequest(Req);
    CheckEqI(InertiaRedirect('/customers').StatusCode, 302, 'POST gir 302');

    A.Reset;
    Req := LagRequest(A, 'PUT /customers/1 HTTP/1.1'#13#10'Host: test');
    UseRequest(Req);
    CheckEqI(InertiaRedirect('/customers').StatusCode, 303, 'PUT gir 303');

    A.Reset;
    Req := LagRequest(A, 'DELETE /customers/1 HTTP/1.1'#13#10'Host: test');
    UseRequest(Req);
    CheckEqI(InertiaRedirect('/customers').StatusCode, 303, 'DELETE gir 303');

    { Props må komme i par. }
    A.Reset;
    Req := LagRequest(A, 'GET / HTTP/1.1'#13#10'Host: test');
    UseRequest(Req);
    try
      Inertia('X', ['bare-name']);
      Check(False, 'ujevnt antall props skulle kastet');
    except
      on E: EInertiaError do
        Check(True, 'ujevnt antall props avvises');
    end;
  finally
    UseRequest(PrevR);
    UseArena(PrevA);
    A.Free;
  end;
end;

{ ----------------------------------------------------------------- ruter -- }

type
  TRuteSpor = class
  public
    Truffet: string;
    function Index(Req: TRequest): TResponse;
    function Vis(Req: TRequest): TResponse;
    function Ny(Req: TRequest): TResponse;
    function Save(Req: TRequest): TResponse;
    function Fil(Req: TRequest): TResponse;
    function Stop_(Req: TRequest): TResponse;
    function SlippGjennom(Req: TRequest): TResponse;
  end;

function TRuteSpor.Index(Req: TRequest): TResponse;
begin
  Truffet := 'index';
  Result := RespondText('index');
end;

function TRuteSpor.Vis(Req: TRequest): TResponse;
begin
  Truffet := 'vis:' + Req.Param('id').ToString;
  Result := RespondText(Truffet);
end;

function TRuteSpor.Ny(Req: TRequest): TResponse;
begin
  Truffet := 'new';
  Result := RespondText('new');
end;

function TRuteSpor.Save(Req: TRequest): TResponse;
begin
  Truffet := 'lagre';
  Result := RespondText('lagre');
end;

function TRuteSpor.Fil(Req: TRequest): TResponse;
begin
  Truffet := 'fil:' + Req.Param('sti').ToString;
  Result := RespondText(Truffet);
end;

function TRuteSpor.Stop_(Req: TRequest): TResponse;
begin
  Result := RespondText('stoppet av middleware', 403);
end;

function TRuteSpor.SlippGjennom(Req: TRequest): TResponse;
begin
  Result := nil;
end;

procedure TestRuter;
var
  A: TArena;
  PrevA: TArena;
  R: TRouter;
  Spor: TRuteSpor;
  Req: TRequest;
  Reply_: TResponse;
  Lines: TStringList;
begin
  Group('Ruter');
  A := TArena.Create(32 * 1024);
  PrevA := UseArena(A);
  Spor := TRuteSpor.Create;
  R := TRouter.Create;
  try
    R.Get('/customers', Spor.Index);
    R.Get('/customers/:id', Spor.Vis);
    R.Get('/customers/new', Spor.Ny);
    R.Post('/customers', Spor.Save);
    R.Get('/files/*sti', Spor.Fil);
    R.AsName('files');

    Req := LagRequest(A, 'GET /customers HTTP/1.1'#13#10'Host: t');
    Reply_ := R.Handle(Req);
    CheckEqS(Spor.Truffet, 'index', 'fast rute treffer');
    CheckEqI(Reply_.StatusCode, 200, 'og svarer 200');

    A.Reset;
    Req := LagRequest(A, 'GET /customers/42 HTTP/1.1'#13#10'Host: t');
    R.Handle(Req);
    CheckEqS(Spor.Truffet, 'vis:42', 'parameter fanges');
    CheckEqI(Req.IntParam('id'), 42, 'IntParam');

    { Denne er hele poenget med sorteringen: /customers/new er registrert
      etter /customers/:id, men skal likevel vinne. }
    A.Reset;
    Req := LagRequest(A, 'GET /customers/new HTTP/1.1'#13#10'Host: t');
    R.Handle(Req);
    CheckEqS(Spor.Truffet, 'new', 'fast segment slår parameter uansett rekkefølge');

    A.Reset;
    Req := LagRequest(A, 'GET /files/bilder/logo.png HTTP/1.1'#13#10'Host: t');
    R.Handle(Req);
    CheckEqS(Spor.Truffet, 'fil:bilder/logo.png', 'wildcard fanger resten');

    A.Reset;
    Req := LagRequest(A, 'POST /customers HTTP/1.1'#13#10'Host: t');
    R.Handle(Req);
    CheckEqS(Spor.Truffet, 'lagre', 'metoden skiller rutene');

    A.Reset;
    Req := LagRequest(A, 'HEAD /customers HTTP/1.1'#13#10'Host: t');
    Reply_ := R.Handle(Req);
    CheckEqI(Reply_.StatusCode, 200, 'HEAD treffer GET-ruten');

    A.Reset;
    Req := LagRequest(A, 'DELETE /customers HTTP/1.1'#13#10'Host: t');
    Reply_ := R.Handle(Req);
    CheckEqI(Reply_.StatusCode, 405, 'kjent sti, ukjent metode gir 405');

    A.Reset;
    Req := LagRequest(A, 'GET /finnes-ikke HTTP/1.1'#13#10'Host: t');
    Reply_ := R.Handle(Req);
    CheckEqI(Reply_.StatusCode, 404, 'ukjent sti gir 404');

    A.Reset;
    Req := LagRequest(A, 'GET /customers/42/order HTTP/1.1'#13#10'Host: t');
    Reply_ := R.Handle(Req);
    CheckEqI(Reply_.StatusCode, 404, 'for mange segmenter treffer ikke');

    Lines := TStringList.Create;
    try
      R.Describe(Lines);
      CheckEqI(Lines.Count, 5, 'Describe lister alle rutene');
      Check(Pos('(files)', Lines.Text) > 0, 'navngitt rute vises med name');
    finally
      Lines.Free;
    end;
  finally
    R.Free;
    Spor.Free;
    UseArena(PrevA);
    A.Free;
  end;

  { Middleware stopper før handleren. }
  A := TArena.Create(8192);
  PrevA := UseArena(A);
  Spor := TRuteSpor.Create;
  R := TRouter.Create;
  try
    Spor.Truffet := '';
    R.Use(Spor.SlippGjennom);
    R.Use(Spor.Stop_);
    R.Get('/', Spor.Index);
    Req := LagRequest(A, 'GET / HTTP/1.1'#13#10'Host: t');
    Reply_ := R.Handle(Req);
    CheckEqI(Reply_.StatusCode, 403, 'middleware kan stoppe requesten');
    CheckEqS(Spor.Truffet, '', 'og handleren kjørte aldri');
  finally
    R.Free;
    Spor.Free;
    UseArena(PrevA);
    A.Free;
  end;
end;

{ ------------------------------------------------------------- validering -- }

type
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

class procedure TTestCustomer.Describe(S: TSchema);
begin
  S.Table('testcustomers');
end;

procedure TTestCustomer.Rules(V: TValidator);
begin
  V.Field('Name').Required.MaxLen(10);
  V.Field('Email').Required.Email;
  V.Field('EmailAgain').SameAs('Email').Says('E-postene er ulike');
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
  Group('Validering');
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
    Check(K.Validate, 'gyldig modell passerer');
    Check(K.Errors.IsEmpty, 'ingen feil');

    { Tomt navn. }
    A.Reset;
    K := A.New<TTestCustomer>;
    K.Email := 'kh@gets.no';
    K.EmailAgain := 'kh@gets.no';
    K.Status := 'new';
    Check(not K.Validate, 'tomt påkrevd felt feiler');
    Check(K.Errors.Has('name'), 'feilen er nøklet på kolonnenavnet');
    Check(not K.Errors.Has('email_again'),
      'felter uten feil står ikke oppført');
    CheckEqS(K.Errors.First('name'), 'name is required', 'meldingen');

    { Only første feil per felt. }
    A.Reset;
    K := A.New<TTestCustomer>;
    K.Name := 'et altfor langt name som ikke passer';
    K.Email := 'ikke-en-email';
    K.EmailAgain := 'noe-annet';
    K.Status := 'new';
    Check(not K.Validate, 'flere feil');
    CheckEqI(K.Errors.Count, 3, 'én feil per felt, ikke flere');
    CheckEqS(K.Errors.First('name'), 'name can be at most 10 characters', 'MaxLen');
    CheckEqS(K.Errors.First('email'), 'email is not a valid email address',
      'Email');
    CheckEqS(K.Errors.First('email_again'), 'E-postene er ulike',
      'Says overstyrer meldingen');

    { Tallgrenser. }
    A.Reset;
    K := A.New<TTestCustomer>;
    K.Name := 'Knut';
    K.Email := 'kh@gets.no';
    K.EmailAgain := 'kh@gets.no';
    K.Balance := 2000;
    K.Status := 'active';
    Check(not K.Validate, 'over maksgrensen feiler');
    Check(Pos('greater than', K.Errors.First('balance')) > 0, 'Max-melding');

    A.Reset;
    K := A.New<TTestCustomer>;
    K.Name := 'Knut';
    K.Email := 'kh@gets.no';
    K.EmailAgain := 'kh@gets.no';
    K.Balance := 100;
    K.Status := 'ukjent';
    Check(not K.Validate, 'verdi utenfor OneOf feiler');
    Check(K.Errors.Has('status'), 'OneOf');

    { E-postvalidering er bevisst romslig, men ikke tom. }
    A.Reset;
    K := A.New<TTestCustomer>;
    K.Name := 'Knut';
    K.EmailAgain := '';
    K.Balance := 0;
    K.Status := 'new';
    K.Email := 'a@b.no';
    K.EmailAgain := 'a@b.no';
    Check(K.Validate, 'kort men gyldig adresse');
    A.Reset;
    K := A.New<TTestCustomer>;
    K.Name := 'Knut';
    K.Status := 'new';
    K.Email := 'a@b';
    K.EmailAgain := 'a@b';
    Check(not K.Validate, 'adresse uten punktum i domenet avvises');

    { Feilene som JSON — formen Inertia forventer i props.errors. }
    A.Reset;
    K := A.New<TTestCustomer>;
    K.Status := 'new';
    K.Validate;
    W.Init(A, 256);
    K.Errors.WriteJson(W);
    Check(Pos('"name":"name is required"', W.ToString) > 0,
      'WriteJson gir felt til melding');
    Check(Pos('"email"', W.ToString) > 0, 'flere felter med');
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

    { Primærnøkkelen fylles aldri, uansett hva klienten sender. }
    A.Reset;
    Req := MakeRequestWithBody(A,
      'POST /customers HTTP/1.1'#13#10'Host: t'#13#10 +
      'Content-Type: application/json'#13#10'Content-Length: 30',
      '{"id":999,"name":"Forsøk"}');
    K := A.New<TTestCustomer>;
    K.Id := 7;
    Req.FillInto(K);
    CheckEqI(K.Id, 7, 'id kan ikke settes fra en request');
    CheckEqS(K.Name, 'Forsøk', 'men resten fylles');

    { Skjemakropp. }
    A.Reset;
    Req := MakeRequestWithBody(A,
      'POST /customers HTTP/1.1'#13#10'Host: t'#13#10 +
      'Content-Type: application/x-www-form-urlencoded'#13#10 +
      'Content-Length: 40',
      'name=Ada+Lovelace&email=ada%40gets.no&balance=99.95');
    K := A.New<TTestCustomer>;
    Req.FillInto(K);
    CheckEqS(K.Name, 'Ada Lovelace', 'pluss blir mellomrom i skjema');
    CheckEqS(K.Email, 'ada@gets.no', 'prosentkoding dekodes');
    Check(K.Balance = 99.95, 'Currency fra skjema');

    { Query-streng. }
    A.Reset;
    Req := LagRequest(A, 'GET /customers?name=Grace&balance=5 HTTP/1.1'#13#10'Host: t');
    K := A.New<TTestCustomer>;
    Req.FillInto(K);
    CheckEqS(K.Name, 'Grace', 'fra query');
    Check(K.Balance = 5, 'tall fra query');

    { Delvis: felter som ikke er sendt røres ikke. }
    A.Reset;
    Req := MakeRequestWithBody(A,
      'PATCH /customers/1 HTTP/1.1'#13#10'Host: t'#13#10 +
      'Content-Type: application/json'#13#10'Content-Length: 20',
      '{"balance":42}');
    K := A.New<TTestCustomer>;
    K.Name := 'Uendret';
    K.Email := 'uendret@gets.no';
    Req.FillInto(K);
    Check(K.Balance = 42, 'sendt felt oppdateres');
    CheckEqS(K.Name, 'Uendret', 'usendt felt står urørt');
    CheckEqS(K.Email, 'uendret@gets.no', 'og det andre også');

    { Input og HasInput. }
    A.Reset;
    Req := MakeRequestWithBody(A,
      'POST /x HTTP/1.1'#13#10'Host: t'#13#10 +
      'Content-Type: application/json'#13#10'Content-Length: 40',
      '{"a":"en","b":2,"c":true,"d":null}');
    Check(Req.HasInput('a'), 'HasInput finner feltet');
    Check(not Req.HasInput('z'), 'og ikke et som mangler');
    CheckEqS(Req.Input('a').ToString, 'en', 'Input gir strengen');
    CheckEqI(Req.InputInt('b'), 2, 'InputInt');
    Check(Req.InputBool('c'), 'InputBool');
    Check(not Req.InputBool('z', False), 'standardverdi når feltet mangler');
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
    Exit('(ingen setning ' + IntToStr(Index) + ')');
  Result := A[Index];
end;

function SqlCount(S: TSchemaBuilder): Integer;
begin
  Result := Length(S.ToSql);
end;

procedure TestNornSchema;
var
  S: TSchemaBuilder;
begin
  Group('Norn — skjemabygger');

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
    CheckEqI(SqlCount(S), 2, 'CREATE TABLE pluss én indeks');
    CheckEqS(Sql(S, 0),
      'CREATE TABLE "customers" ("id" BIGSERIAL PRIMARY KEY, ' +
      '"name" VARCHAR(120) NOT NULL, "email" VARCHAR(255) NOT NULL UNIQUE, ' +
      '"balance" NUMERIC(12,2) NOT NULL DEFAULT 0, ' +
      '"created_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP, ' +
      '"updated_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP)',
      'PRD-ens migrasjon gir denne SQL-en');
    CheckEqS(Sql(S, 1),
      'CREATE INDEX "customers_created_at_idx" ON "customers" ("created_at")',
      'indeksen får utledet name');
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
    Check(Pos('`t`', Sql(S, 0)) > 0, 'MySQL siterer med backtick');
    Check(Pos('BIGINT AUTO_INCREMENT', Sql(S, 0)) > 0, 'MySQL-autonøkkel');
    Check(Pos('TINYINT(1)', Sql(S, 0)) > 0, 'MySQL har ikke BOOLEAN');
    Check(Pos('DATETIME', Sql(S, 0)) > 0, 'MySQL-tidsstempel');
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
      'SQLite bruker INTEGER som autonøkkel');
    { SQLite har ingen datotype og lagrer tekst uansett. Men den erklærte
      typen er det introspeksjonen leser, og med TEXT kunne den ikke skille
      en dato fra en hvilken som helst streng — da typet askr schema
      created_at som string mot SQLite og som TDateTime mot Postgres, av
      samme migrasjon. DATETIME gir NUMERIC-affinitet, og en ISO-tekst lar
      seg ikke konvertere tapsfritt til et tall, så lagringen er uendret. }
    Check(Pos('"at" DATETIME', Sql(S, 0)) > 0,
      'SQLite erklærer DATETIME, slik at introspeksjonen ser hva det er');
  finally
    S.Free;
  end;

  { Fremmednøkkel, ALTER og DROP. }
  S := TSchemaBuilder.Create(sdPostgres);
  try
    with S.Create('orders') do
      ForeignKey('customer_id', 'customers');
    Check(Pos('REFERENCES "customers"("id") ON DELETE CASCADE', Sql(S, 0)) > 0,
      'fremmednøkkel med ON DELETE');
  finally
    S.Free;
  end;

  S := TSchemaBuilder.Create(sdPostgres);
  try
    with S.Alter('customers') do
    begin
      Bool('active').Default(True);
      DropColumn('gammel');
    end;
    CheckEqS(Sql(S, 0),
      'ALTER TABLE "customers" ADD COLUMN "active" BOOLEAN NOT NULL DEFAULT true',
      'ALTER ADD COLUMN');
    CheckEqS(Sql(S, 1),
      'ALTER TABLE "customers" DROP COLUMN "gammel"', 'ALTER DROP COLUMN');
  finally
    S.Free;
  end;

  S := TSchemaBuilder.Create(sdPostgres);
  try
    S.Drop('gammel');
    CheckEqS(Sql(S, 0), 'DROP TABLE IF EXISTS "gammel"', 'DROP TABLE');
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
      Numeric('d', 8, 4).Default(Currency(1.5));
    end;
    Check(Pos('"a" TEXT DEFAULT', Sql(S, 0)) = 0, 'nullable gir ikke NOT NULL');
    Check(Pos('"b" TEXT NOT NULL DEFAULT ''hei''', Sql(S, 0)) > 0,
      'tekstverdi siteres');
    Check(Pos('''med''''fnutt''', Sql(S, 0)) > 0, 'fnutt i verdien dobles');
    Check(Pos('"d" NUMERIC(8,4) NOT NULL DEFAULT 1.5000', Sql(S, 0)) > 0,
      'Currency formateres uten locale');
  finally
    S.Free;
  end;
end;

procedure TestNornNavn;
begin
  Group('Norn — navnekonvensjoner');

  CheckEqS(PascalCase('customers'), 'Customers', 'enkelt name');
  CheckEqS(PascalCase('order_lines'), 'OrderLines', 'snake_case');
  CheckEqS(PascalCase('created_at'), 'CreatedAt', 'kolonnenavn');
  CheckEqS(PascalCase('id'), 'Id', 'kort name');
  CheckEqS(TableTypeName('customers'), 'TCustomersColumns', 'typenavn');
  CheckEqS(TableConstName('order_lines'), 'OrderLines', 'konstantnavn');
  CheckEqS(MemberName('created_at'), 'CreatedAt', 'medlemsnavn');
  { Et kolonnenavn som kolliderer med et reservert ord må escapes. }
  CheckEqS(MemberName('type'), 'Type_', 'reservert ord får understrek');
  CheckEqS(MemberName('end'), 'End_', 'end likeså');
  CheckEqS(MemberName('name'), 'Name', 'name er ikke reservert');

  CheckEqS(ColAliasFor('bigint', 0), 'TColInt64', 'bigint');
  CheckEqS(ColAliasFor('integer', 0), 'TColInt64', 'integer');
  CheckEqS(ColAliasFor('text', 0), 'TColStr', 'text');
  CheckEqS(ColAliasFor('character varying', 0), 'TColStr', 'varchar');
  CheckEqS(ColAliasFor('boolean', 0), 'TColBool', 'boolean');
  CheckEqS(ColAliasFor('numeric', 2), 'TColCurrency', 'numeric med to desimaler');
  CheckEqS(ColAliasFor('numeric', 8), 'TColFloat',
    'flere desimaler enn Currency takler blir flyttall');
  CheckEqS(ColAliasFor('double precision', 0), 'TColFloat', 'double');
  CheckEqS(ColAliasFor('timestamp with time zone', 0), 'TColDateTime',
    'timestamptz');
  CheckEqS(ColAliasFor('date', 0), 'TColDateTime', 'date');
  CheckEqS(ColAliasFor('jsonb', 0), 'TColStr', 'jsonb behandles som tekst');

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
    C.Put('a', 'verdi a');
    Check(C.Get(A, 'a', V), 'Get finner det som ble lagt inn');
    CheckEqS(V.ToString, 'verdi a', 'riktig verdi');
    Check(not C.Get(A, 'finnes-ikke', V), 'ukjent nøkkel gir False');
    Check(C.Has('a'), 'Has');
    CheckEqI(C.Count, 1, 'én post');

    { Dette er selve spørsmålet. Verdien legges inn fra en arena, arenaen
      nullstilles og skrives full av noe annet, og verdien må fortsatt
      stemme. Without kopien i Put ville den vært søppel her. }
    A.Reset;
    V := StrDup(A, 'fra request-arenaen');
    C.Put('fra-arena', V);
    A.Reset;
    Fill := PByte(A.Alloc(8192));
    FillChar(Fill^, 8192, Ord('X'));
    Check(C.Get(B, 'fra-arena', V), 'posten finnes etter Reset');
    CheckEqS(V.ToString, 'fra request-arenaen',
      'Put kopierte ut av arenaen — verdien overlevde');

    { Og motsatt vei: det Get ga tilbake ligger i kallerens arena, ikke i
      cachen. Da kan cachen kaste ut posten uten å etterlate en dinglende
      peker. }
    C.Forget('fra-arena');
    CheckEqS(V.ToString, 'fra request-arenaen',
      'verdien lever videre etter at posten ble slettet');
    Check(not C.Has('fra-arena'), 'og posten er faktisk borte');

    { Utløp. }
    C.Put('kort', 'lever kort', 1);
    Check(C.Has('kort'), 'finnes med en gang');
    C.Put('lang', 'lever lenge', 3600);
    Check(C.Has('lang'), 'lang TTL');

    { LRU: fyll sharden til den kaster ut. }
    C.Flush;
    for I := 1 to 2000 do
      C.Put('n' + IntToStr(I), 'v' + IntToStr(I));
    Check(C.Count <= 256, 'cachen holder seg innenfor grensen');
    Check(C.Evictions > 0, 'og kastet ut det den måtte');
    Found := 0;
    for I := 1990 to 2000 do
      if C.Get(A, 'n' + IntToStr(I), V) then
        Inc(Found);
    Check(Found >= 8, 'de sist skrevne er stort sett beholdt');

    C.Flush;
    CheckEqI(C.Count, 0, 'Flush tømmer');

    { Strengformen for oppstartskode og bakgrunnsjobber. }
    C.Put('s', 'tekst');
    Check(C.Get('s', S) and (S = 'tekst'), 'strengformen virker');

    Check(C.Hits > 0, 'treff telles');
    Check(C.Misses > 0, 'bom telles');
  finally
    A.Free;
    B.Free;
    C.Free;
  end;
end;

{ -------------------------------------------------------------------- kø -- }

var
  QSum: LongInt = 0;
  QLast: string = '';
  QAttempts: LongInt = 0;
  QFeilmeldinger: LongInt = 0;
  QLock: TRTLCriticalSection;

procedure JobbTell(const Ctx: TJobContext);
var
  N: Int64;
begin
  if Ctx.Payload.ToInt64(N) then
    InterLockedExchangeAdd(QSum, LongInt(N));
end;

procedure JobbHusk(const Ctx: TJobContext);
begin
  EnterCriticalSection(QLock);
  try
    QLast := Ctx.Payload.ToString;
  finally
    LeaveCriticalSection(QLock);
  end;
end;

{ Feiler de to første gangene, lykkes på tredje. }
procedure JobbFlakete(const Ctx: TJobContext);
begin
  InterLockedIncrement(QAttempts);
  if Ctx.Attempt < 3 then
    raise Exception.Create('ikke ennå');
end;

procedure JobbAlltidFeil(const Ctx: TJobContext);
begin
  raise Exception.Create('alltid');
end;

procedure TellFeil(const JobName, Message_: string);
begin
  InterLockedIncrement(QFeilmeldinger);
end;

{ Bruker arenaen sin som en kontroller ville gjort. }
procedure JobbBrukerArena(const Ctx: TJobContext);
var
  B: TStrBuilder;
begin
  B.Init(Ctx.Arena, 128);
  B.Append('jobb:');
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
  { En modell med tidsstempler, soft deletes og hendelser. }
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

  { Samme tabell, men uten tidsstempler og soft deletes — til å vise at
    det som skal kaste, kaster. }
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

{ Hendelsene noterer seg selv, slik at rekkefølgen kan hevdes om. }
procedure TMlPost.BeforeSave;
begin
  MlHendelser := MlHendelser + 'BS,';
  { En hendelse skal kunne endre modellen før den skrives. Det er det
    vanligste de brukes til: utlede et felt av et annet. }
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

{ «Query scopes» krever ingenting av rammeverket i Pascal: en scope er en
  funksjon som returnerer en spørring. Den er typet, kompilatoren ser den,
  og den kan kjedes videre som alt annet.

  Den står som en frittstående funksjon og ikke som en klassemetode på
  TMlPost, fordi en metode som returnerer TQuery<TMlPost> ville
  fremoverreferert klassen sin egen type. Det er den samme grensen som
  gjelder TModelList<M>. }
function NyestePoster(Count_: Integer): TQuery<TMlPost>;
begin
  Result := TQuery<TMlPost>.New
    .OrderBy(ColDateTime('ml_posts', 'created_at'), Desc)
    .Limit(Count_);
end;

{ Rader i tabellen uten hensyn til deleted_at — poenget er å se at en
  myktslettet rad fortsatt finnes. }
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
  Group('Modell: tidsstempler, soft deletes, hendelser');
  if not SqliteAvailable then
  begin
    Check(False, 'libsqlite3 lot seg laste');
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
    P.Title := 'Første post';
    P.Save;
    Made := P.CreatedAt;
    Check(Made > 0, 'created_at ble satt ved INSERT');
    Check(P.UpdatedAt > 0, 'updated_at også');
    { UTC, ikke lokaltid: to servere i hver sin sone skal skrive det samme
      for det samme øyeblikket. Toleransen er ett minutt. }
    Check(Abs(P.CreatedAt - UtcNow) < 1 / (24 * 60),
      'og de er i UTC, ikke lokaltid');

    { Hendelsene i riktig rekkefølge, og BeforeSave rakk å endre modellen. }
    CheckEqS(MlHendelser, 'BS,BI,AI,AS,', 'hendelsene ved INSERT');
    CheckEqS(P.Slug, 'første-post', 'BeforeSave fikk endre modellen');

    Sleep(1100);
    MlHendelser := '';
    P.Title := 'Endret';
    P.Save;
    Oppdatert := P.UpdatedAt;
    CheckEqS(MlHendelser, 'BS,BU,AU,AS,', 'hendelsene ved UPDATE');
    Check(P.CreatedAt = Made, 'created_at røres ikke ved UPDATE');
    Check(Oppdatert > Made, 'men updated_at flyttes');

    { En import som bevarer opprinnelige tidspunkter skal ikke få dem
      overskrevet. }
    P := A.New<TMlPost>;
    P.Title := 'Importert';
    P.CreatedAt := EncodeDate(2020, 1, 1);
    P.Save;
    Check(Abs(P.CreatedAt - EncodeDate(2020, 1, 1)) < 0.0001,
      'en created_at som alt er satt beholdes');

    { ---- soft deletes ---- }
    CheckEqI(TQuery<TMlPost>.New.Count, 2, 'to poster synlige');
    CheckEqI(MlRawCount(C, A), 2, 'og to rader i tabellen');

    MlHendelser := '';
    P.Delete;
    CheckEqS(MlHendelser, 'BD,AD,', 'hendelsene ved DELETE');
    Check(P.IsTrashed, 'modellen vet at den er slettet');
    { Dette er hele poenget: raden er der, men spørringene ser den ikke. }
    CheckEqI(MlRawCount(C, A), 2, 'raden ligger fortsatt i tabellen');
    CheckEqI(TQuery<TMlPost>.New.Count, 1, 'men spørringen ser den ikke');
    CheckEqI(TQuery<TMlPost>.New.WithTrashed.Count, 2,
      'WithTrashed tar den med');
    CheckEqI(TQuery<TMlPost>.New.OnlyTrashed.Count, 1,
      'OnlyTrashed viser bare den');

    { Et filter skal virke sammen med soft-delete-leddet, ikke i stedet
      for det. }
    CheckEqI(TQuery<TMlPost>.New
      .Where(ColStr('ml_posts', 'title'), Eq, 'Importert').Count, 0,
      'et filter kombineres med soft-delete-leddet');
    CheckEqI(TQuery<TMlPost>.New.WithTrashed
      .Where(ColStr('ml_posts', 'title'), Eq, 'Importert').Count, 1,
      'og med WithTrashed finner det raden');

    P.Restore;
    Check(not P.IsTrashed, 'Restore tok den tilbake');
    CheckEqI(TQuery<TMlPost>.New.Count, 2, 'og den er synlig igjen');

    { ---- på spørringsnivå ---- }
    CheckEqI(TQuery<TMlPost>.New.DeleteAll, 2,
      'DeleteAll sletter mykt når modellen har soft deletes');
    CheckEqI(MlRawCount(C, A), 2, 'radene er der fortsatt');
    CheckEqI(TQuery<TMlPost>.New.Count, 0, 'men ingen er synlige');
    CheckEqI(TQuery<TMlPost>.New.RestoreAll, 2, 'RestoreAll tar dem tilbake');
    CheckEqI(TQuery<TMlPost>.New.Count, 2, 'og de er synlige');

    CheckEqI(TQuery<TMlPost>.New.ForceDeleteAll, 2,
      'ForceDeleteAll sletter for godt');
    CheckEqI(MlRawCount(C, A), 0, 'og da er tabellen tom');

    { ForceDelete på én modell. }
    P := A.New<TMlPost>;
    P.Title := 'Skal bort';
    P.Save;
    CheckEqI(MlRawCount(C, A), 1, 'én rad');
    P.ForceDelete;
    CheckEqI(MlRawCount(C, A), 0, 'ForceDelete fjernet den');

    { ---- det som skal kaste ---- }
    Err := '';
    try
      TMlBar.Meta;
      P := A.New<TMlPost>;
      P.Title := 'x';
      P.Save;
      TQuery<TMlBar>.New.Count;
      { En modell uten SoftDeletes har ingenting å gjenopprette. }
      A.New<TMlBar>.Restore;
    except
      on E: EModelError do Err := E.Message;
    end;
    Check(Pos('no soft deletes', Err) > 0,
      'Restore uten SoftDeletes kaster, og sier hva som mangler');

    { En modell uten deleted_at ser alle rader — soft-delete-leddet legges
      bare på når modellen faktisk har det. }
    CheckEqI(TQuery<TMlBar>.New.Count, 1,
      'en modell uten soft deletes filtrerer ingenting');

    Items := TQuery<TMlPost>.New.Get;
    CheckEqI(Items.Count, 1, 'Get virker med soft-delete-leddet på');

    { ---- tidsstempler overlever rundturen ---- }
    { Det som virkelig betyr noe med DATETIME i SQLite: at
      introspeksjonen ser en dato, og at verdien kommer tilbake som en
      dato. Without begge deler er den erklærte typen bare pynt. }
    Schema_ := IntrospectSchema(C);
    try
      Tab := Schema_.Table('ml_posts');
      Check(Tab <> nil, 'tabellen ble introspisert');
      CheckEqS(PascalTypeFor(
        Tab.Column(Tab.IndexOfColumn('created_at')).SqlType,
        Tab.Column(Tab.IndexOfColumn('created_at')).Scale), 'TDateTime',
        'created_at introspiseres som TDateTime, ikke string');
    finally
      Schema_.Free;
    end;

    P := TQuery<TMlPost>.New.WithTrashed.Get[0];
    Check(P.CreatedAt > EncodeDate(2020, 1, 1),
      'og verdien kom tilbake som en ekte dato fra databasen');

    { ---- query scopes ---- }
    P := A.New<TMlPost>;
    P.Title := 'Nyere';
    { created_at settes eksplisitt. SQL-tidsstempelet har sekundoppløsning,
      og to rader laget i samme sekund har ingen definert rekkefølge — da
      ville testen vært grønn eller rød etter hvor raskt maskinen var. }
    P.CreatedAt := UtcNow + 1;
    P.Save;
    Items := NyestePoster(1).Get;
    CheckEqI(Items.Count, 1, 'en scope er bare en funksjon som gir en query');
    CheckEqS(Items[0].Title, 'Nyere', 'og den kan sorteres og begrenses');
    { En scope kan kjedes videre, og soft-delete-leddet blir med. }
    CheckEqI(NyestePoster(10).WithTrashed.Count, 2,
      'og den kjedes videre som alt annet');
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
  Group('Kø');
  InitCriticalSection(QLock);
  A := TArena.Create(16 * 1024);
  Q := TQueue.Create(3, 3);
  try
    Q.Handle('tell', @JobbTell);
    Q.Handle('husk', @JobbHusk);
    Q.Handle('flakete', @JobbFlakete);
    Q.Handle('alltid-feil', @JobbAlltidFeil);
    Q.Handle('arena', @JobbBrukerArena);
    Q.OnError := @TellFeil;
    Q.Start;

    { Hundre jobber fra hovedtråden, tre workere. }
    QSum := 0;
    for I := 1 to 100 do
      Q.Push('tell', IntToStr(I));
    Check(Q.WaitUntilEmpty(5000), 'køen ble tom');
    Sleep(50);
    CheckEqI(QSum, 5050, 'alle hundre jobbene kjørte, og bare én gang hver');
    CheckEqI(Q.Processed, 100, 'Processed teller riktig');

    { Det samme spørsmålet som for cachen, men verre: jobben kjører etter at
      requesten er borte. Payloaden legges i en arena, arenaen nullstilles og
      skrives over, og jobben må likevel se riktig innhold. }
    A.Reset;
    V := StrDup(A, 'payload fra requesten');
    QLast := '';
    Q.Push('husk', V);
    A.Reset;
    Fill := PByte(A.Alloc(8192));
    FillChar(Fill^, 8192, Ord('Z'));
    Check(Q.WaitUntilEmpty(5000), 'jobben ble tatt');
    Sleep(80);
    EnterCriticalSection(QLock);
    try
      CheckEqS(QLast, 'payload fra requesten',
        'Push kopierte ut av arenaen — payloaden overlevde');
    finally
      LeaveCriticalSection(QLock);
    end;

    { Handleren får payloaden i sin egen arena og kan bruke den som vanlig. }
    QLast := '';
    Q.Push('arena', 'noe');
    Check(Q.WaitUntilEmpty(5000), 'arena-jobben ble tatt');
    Sleep(80);
    EnterCriticalSection(QLock);
    try
      CheckEqS(QLast, 'jobb:noe', 'handleren brukte sin egen arena');
    finally
      LeaveCriticalSection(QLock);
    end;

    { Forsinkelse. }
    QLast := '';
    Q.Push('husk', 'forsinket', 1);
    Sleep(200);
    EnterCriticalSection(QLock);
    try
      CheckEqS(QLast, '', 'forsinket jobb kjører ikke med en gang');
    finally
      LeaveCriticalSection(QLock);
    end;
    Check(Q.WaitUntilEmpty(4000), 'men den kjører etter hvert');
    Sleep(80);
    EnterCriticalSection(QLock);
    try
      CheckEqS(QLast, 'forsinket', 'og med riktig payload');
    finally
      LeaveCriticalSection(QLock);
    end;

    { Retry med backoff, så suksess. Samme grunn til å vente på tallet. }
    QAttempts := 0;
    Q.Push('flakete', 'x');
    Check(Q.WaitUntilEmpty(6000), 'flakete jobb ble ferdig');
    Frist := 0;
    while (QAttempts < 3) and (Frist < 5000) do
    begin
      Sleep(20);
      Inc(Frist, 20);
    end;
    CheckEqI(QAttempts, 3, 'tre forsøk før den lyktes');
    Check(Q.Retried >= 2, 'to av dem var retries');

    { Gir opp etter MaxAttempts.

      WaitUntilEmpty sier bare at køen er tom nå, og en jobb som venter på
      backoff mellom to forsøk er ikke i køen. Derfor ventes det på Failed
      selv i stedet for på klokka: et fast Sleep her var nok på en rask
      maskin og for kort i container. }
    QFeilmeldinger := 0;
    Q.Push('alltid-feil', 'y');
    Check(Q.WaitUntilEmpty(6000), 'den feilende jobben ga seg');
    Frist := 0;
    while (Q.Failed < 1) and (Frist < 5000) do
    begin
      Sleep(20);
      Inc(Frist, 20);
    end;
    CheckEqI(Q.Failed, 1, 'talt som feilet');
    Check(QFeilmeldinger >= 3, 'OnError ble kalt for hvert forsøk');

    { Unknown_ jobbnavn forkastes, ikke krasjer. }
    Q.Push('finnes-ikke', 'z');
    Check(Q.WaitUntilEmpty(3000), 'ukjent jobb forkastes');
    Frist := 0;
    while (Q.Dropped < 1) and (Frist < 3000) do
    begin
      Sleep(20);
      Inc(Frist, 20);
    end;
    Check(Q.Dropped >= 1, 'og telles');

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
  GW: TJsonWriter;
  GJson: string;
  Feilet_: Boolean;
  T0, Without, With_: Int64;
  Kr: Integer;
begin
  Group('SQLite');

  if not SqliteAvailable then
  begin
    Check(False, 'libsqlite3 lot seg laste');
    Exit;
  end;
  Check(True, 'libsqlite3 lastet med dlopen');
  Si2('sqlite-versjon', SqliteVersion);

  SetUpColumns;
  A := TArena.Create(64 * 1024);
  PrevA := UseArena(A);
  { Ingen fil, ingen server: hele datalaget testes i minnet. }
  C := OpenDbConnection('sqlite::memory:');
  PrevDb := UseDb(C);
  try
    Check(C.Dialect = sdSqlite, 'dialekten er sqlite');

    { Migrasjon gjennom den samme skjemabyggeren som Postgres bruker. }
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
      CheckEqI(Length(Stmts), 3, 'to tabeller og én indeks');
    finally
      S.Free;
    end;

    { Save, med autonøkkel fra last_insert_rowid. }
    K := A.New<TSqCustomer>;
    K.Name := 'Ada';
    K.Email := 'ada@gets.no';
    K.Balance := 1234.5;
    K.Active := True;
    K.Save;
    Check(K.Id > 0, 'INSERT ga primærnøkkel tilbake');
    CheckEqI(K.Id, 1, 'første rad får id 1');

    K.Balance := 99.95;
    K.Save;
    CheckEqI(TQuery<TSqCustomer>.New.Count, 1,
      'andre Save ble UPDATE, ikke ny rad');
    Check(TQuery<TSqCustomer>.New.Find(1).Balance = 99.95, 'verdien ble oppdatert');

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

    { Typede spørringer mot samme query builder som Postgres. }
    CheckEqI(TQuery<TSqCustomer>.New.Count, 5, 'fem customers');
    Check(Pos('"sq_customers"."name"', TQuery<TSqCustomer>.New.ToSql) > 0,
      'SQLite siterer med doble anførselstegn');
    Check(Pos('?', TQuery<TSqCustomer>.New
      .Where(SqCustomers.Balance, GT, 150).ToSql) > 0,
      'plassholderen er ?, ikke $1');

    Items := TQuery<TSqCustomer>.New
      .Where(SqCustomers.Balance, GT, 150)
      .OrderBy(SqCustomers.Balance, Desc)
      .Get;
    CheckEqI(Items.Count, 4, 'fire over 150');
    Check(Items[0].Balance = 500, 'sortert synkende');
    CheckEqS(Items[0].Name, 'Customer 5', 'riktig rad hydrert');
    Check(Items[0].Active = False, 'boolean hydrert fra INTEGER');

    { OR-gruppe: fritekstsøk over flere kolonner.

      Without den har TQuery bare AND, og «finn Ada i navn eller e-post» lar
      seg ikke uttrykke. Parentesen er det som betyr noe: uten den binder
      et Where som står fra før seg til bare det første leddet i gruppa, og
      søket lekker rader. }
    Sql := TQuery<TSqCustomer>.New
      .Where(SqCustomers.Balance, GT, 100)
      .WhereAnyLike([SqCustomers.Name, SqCustomers.Email], 'ada')
      .ToSql;
    Check(Pos(' OR ', Sql) > 0, 'OR mellom søkekolonnene');
    Check(Pos(' AND (', Sql) > 0, 'AND binder mot hele gruppa, ikke bare første ledd');
    Check(Sql[Length(Sql)] = ')', 'og gruppa lukkes');
    { SQLite har ingen ILIKE. LIKE der er ufølsom for ASCII fra før. }
    Check(Pos('ILIKE', Sql) = 0, 'ILIKE oversettes bort utenfor Postgres');
    Check(Pos(' LIKE ', Sql) > 0, 'til LIKE');

    { Ett ledd i gruppa skal ikke få parentes den ikke trenger, og tom
      tekst skal ikke legge på noe ledd i det hele tatt. }
    CheckEqS(TQuery<TSqCustomer>.New.WhereAnyLike([SqCustomers.Name], '').ToSql,
      TQuery<TSqCustomer>.New.ToSql, 'tomt søk legger ikke på noe');

    Items := TQuery<TSqCustomer>.New
      .WhereAnyLike([SqCustomers.Name, SqCustomers.Email], 'ada')
      .Get;
    CheckEqI(Items.Count, 1, 'søket treffer Ada på navnet');

    { Treffer på e-post selv om navnet ikke inneholder søkeordet. Det er
      hele poenget med OR-en. }
    Items := TQuery<TSqCustomer>.New
      .WhereAnyLike([SqCustomers.Name, SqCustomers.Email], 'customer3@')
      .Get;
    CheckEqI(Items.Count, 1, 'og treffer på e-post når navnet ikke passer');

    { Ufølsom for store bokstaver, også utenfor Postgres. }
    Items := TQuery<TSqCustomer>.New
      .WhereAnyLike([SqCustomers.Name, SqCustomers.Email], 'ADA')
      .Get;
    CheckEqI(Items.Count, 1, 'søket bryr seg ikke om store bokstaver');

    { ---- TGrid: sortering, søk og paginering i databasen ---- }
    begin
      { Tellingen leses fra databasen i stedet for å antas. Fiksturen over
        endrer seg, og en test som hardkoder antallet ryker av grunner som
        ikke har noe med griden å gjøre. }
      Count_ := TQuery<TSqCustomer>.New.Count;
      { Standardtilstand: ingen parametre i det hele tatt. }
      G := TGrid<TSqCustomer>.New;
      G.Read(LagRequest(A, 'GET /customers HTTP/1.1'#13#10'Host: t'))
       .Sortable('name', SqCustomers.Name)
       .Sortable('balance', SqCustomers.Balance)
       .Searchable([SqCustomers.Name, SqCustomers.Email])
       .DefaultSort('name')
       .PerPage(2);
      Items := G.Rows(TQuery<TSqCustomer>.New);
      CheckEqI(Items.Count, 2, 'griden gir én side');
      CheckEqI(G.Total, Count_, 'men teller hele settet');
      CheckEqS(Items[0].Name, 'Ada', 'standardsorteringen gjelder');

      { Side to. }
      Sql := Items[1].Name;   { siste rad på side én }
      G := TGrid<TSqCustomer>.New;
      G.Read(LagRequest(A, 'GET /c?page=2 HTTP/1.1'#13#10'Host: t'))
       .Sortable('name', SqCustomers.Name).DefaultSort('name').PerPage(2);
      Items := G.Rows(TQuery<TSqCustomer>.New);
      Check(Items[0].Name > Sql, 'side to fortsetter der side én sluttet');

      { Sortering fra URL-en. }
      G := TGrid<TSqCustomer>.New;
      G.Read(LagRequest(A, 'GET /c?sort=balance&dir=desc HTTP/1.1'#13#10'Host: t'))
       .Sortable('balance', SqCustomers.Balance).DefaultSort('balance').PerPage(10);
      Items := G.Rows(TQuery<TSqCustomer>.New);
      Check(Items[0].Balance = 500, 'synkende på balance');

      { **Kolonnen fra URL-en er hvitelistet.** En kolonne som ikke er
        registrert faller tilbake til standarden i stedet for å havne i
        SQL-en. Det er ikke en sjekk vi har skrevet — OrderBy tar en typet
        TCol, så formen finnes ikke å skrive. Dette holder bare fast at
        fallbacken virker. }
      G := TGrid<TSqCustomer>.New;
      G.Read(LagRequest(A,
        'GET /c?sort=email); DROP TABLE sq_customers;-- HTTP/1.1'#13#10'Host: t'))
       .Sortable('name', SqCustomers.Name).DefaultSort('name').PerPage(10);
      Items := G.Rows(TQuery<TSqCustomer>.New);
      CheckEqS(Items[0].Name, 'Ada', 'ukjent sorteringskolonne faller tilbake');
      CheckEqI(TQuery<TSqCustomer>.New.Count, Count_, 'og tabellen står der fortsatt');

      { Søk over flere kolonner. }
      G := TGrid<TSqCustomer>.New;
      G.Read(LagRequest(A, 'GET /c?q=ada@ HTTP/1.1'#13#10'Host: t'))
       .Sortable('name', SqCustomers.Name)
       .Searchable([SqCustomers.Name, SqCustomers.Email])
       .DefaultSort('name').PerPage(10);
      Items := G.Rows(TQuery<TSqCustomer>.New);
      CheckEqI(Items.Count, 1, 'søket treffer på e-post');
      CheckEqI(G.Total, 1, 'og totalen teller treffene, ikke tabellen');

      { Søket må gjelde sammen med kallerens eget Where, ikke i stedet for.
        Det er parentesen rundt OR-gruppa som avgjør det. }
      G := TGrid<TSqCustomer>.New;
      G.Read(LagRequest(A, 'GET /c?q=customer HTTP/1.1'#13#10'Host: t'))
       .Sortable('name', SqCustomers.Name)
       .Searchable([SqCustomers.Name, SqCustomers.Email])
       .DefaultSort('name').PerPage(10);
      Items := G.Rows(TQuery<TSqCustomer>.New.Where(SqCustomers.Balance, GT, 300));
      CheckEqI(Items.Count, 2, 'søk og eget Where gjelder samtidig');

      { Taket på sidestørrelse. Without det er per=1000000 en måte å be om
        hele tabellen på. }
      G := TGrid<TSqCustomer>.New;
      G.Read(LagRequest(A, 'GET /c?per=100000 HTTP/1.1'#13#10'Host: t'))
       .Sortable('name', SqCustomers.Name).DefaultSort('name').PerPage(2, 3);
      Items := G.Rows(TQuery<TSqCustomer>.New);
      CheckEqI(Items.Count, 3, 'sidestørrelsen klemmes ned til taket');

      { Payloaden frontend leser. }
      GW.Init(A, 256);
      G.WriteJson(GW);
      GJson := GW.ToString;
      Check(Pos('"total":' + IntToStr(Count_), GJson) > 0,
        'grid-proppen bærer totalen');
      Check(Pos('"pages":', GJson) > 0, 'og antall sider');
      Check(Pos('"per":3', GJson) > 0, 'og sidestørrelsen etter taket');
      Check(Pos('"sort":"name"', GJson) > 0, 'og hvilken kolonne som er sortert');
    end;

    { Ada er aktiv, og av Customer 2..5 er 2 og 4 det. Three til sammen. }
    CheckEqI(TQuery<TSqCustomer>.New.Where(SqCustomers.Active, Eq, True).Count, 3,
      'boolean-filter mot INTEGER-kolonne');
    CheckEqI(TQuery<TSqCustomer>.New.WhereIn(SqCustomers.Id, [1, 2, 3]).Count, 3,
      'WhereIn');

    { Eager loading. }
    Items := TQuery<TSqCustomer>.New.Preload(['Order']).OrderBy(SqCustomers.Id).Get;
    Count_ := 0;
    for I := 0 to Items.Count - 1 do
      if Items[I].Order <> nil then
        Count_ := Count_ + Items[I].Order.Count;
    CheckEqI(Count_, 1 + 2 + 3 + 4, 'eager loading fordelte alle orders');
    CheckEqI(Items[0].Order.Count, 0, 'første customer har ingen');
    CheckEqI(Items[4].Order.Count, 4, 'siste har fire');

    { Validering, inkludert UniqueIn mot SQLite. }
    K := A.New<TSqCustomer>;
    K.Name := 'Duplikat';
    K.Email := 'ada@gets.no';
    Check(not K.Validate, 'UniqueIn fanger duplikatet');
    Check(K.Errors.Has('email'), 'feilen er på email');

    { Unik-brudd fra databasen oversettes til samme SQLSTATE som Postgres. }
    try
      K.Save;
      Check(False, 'unik-brudd skulle kastet');
    except
      on E: EDbError do
        Check(E.IsUniqueViolation,
          'SQLITE_CONSTRAINT oversettes til 23505');
    end;

    { Fremmednøkler håndheves bare med pragma satt. }
    try
      O := A.New<TSqOrder>;
      O.CustomerId := 9999;
      O.Save;
      Check(False, 'fremmednøkkel skulle kastet');
    except
      on E: EDbError do
        Check(E.IsForeignKeyViolation, 'fremmednøkkel gir 23503');
    end;

    { Transaksjon. }
    C.StartTransaction;
    K := A.New<TSqCustomer>;
    K.Name := 'Rulles tilbake';
    K.Email := 'rull@gets.no';
    K.Save;
    CheckEqI(TQuery<TSqCustomer>.New.Count, 6, 'synlig inne i transaksjonen');
    C.Rollback;
    CheckEqI(TQuery<TSqCustomer>.New.Count, 5, 'ROLLBACK fjernet den');

    { Arenaen skal flate ut som mot Postgres. }
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
      'arenaen vokser ikke over 500 spørringer mot SQLite');

    { ---- Currency-aritmetikk på tvers av kompilatorer ---- }
    { Premisstest. FPC 3.3.1 og 3.2.2 er uenige om én form:
      Currency(I) * <heltallsliteral> gir I/100 på trunk og I*100 på 3.2.2.
      Formene under er like på begge, og det er dem koden skal bruke.
      Slutter de å være like, er det et funn og ikke en grunn til å myke
      opp testen. }
    { Sjekkes gjennom CurrencyToSql, altså det som faktisk havner i
      databasen — og fordi enhver skalering med et heltall her ville vært
      den samme fella testen handler om. }
    Kr := 7;
    CheckEqS(CurrencyToSql(Currency(Kr)), '7.0000', 'Currency(I) alene');
    CheckEqS(CurrencyToSql(Currency(Kr * 100)), '700.0000',
      'Currency(I * 100) — multiplikasjon før konvertering');
    CheckEqS(CurrencyToSql(Currency(Kr) * 100.0), '700.0000',
      'Currency(I) * flyttallsliteral');
    CheckEqS(CurrencyToSql(Currency(Kr) / 4), '1.7500', 'Currency(I) / 4');
    CheckEqS(CurrencyToSql(Currency(Kr) + 1), '8.0000', 'Currency(I) + 1');

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
      'samme spørring forberedes én gang');
    CheckEqI(Sq.CacheHits - ForHits, 19, 'resten traff cachen');
    CheckEqI(Sq.OpenStatements - ForApne, 1,
      'og SQLite har nøyaktig ett statement åpent');

    { Bindinger fra forrige kjøring må ikke henge igjen. Without
      sqlite3_clear_bindings ville et kall med færre eller andre parametre
      sett verdier fra forrige runde. }
    A.Reset;
    R2 := C.ExecParams(A, 'SELECT count(*) FROM sq_customers WHERE name = ?',
      [DbParam(A, 'Ada')]);
    Count_ := Integer(R2.AsInt64(0, 0));
    R2 := C.ExecParams(A, 'SELECT count(*) FROM sq_customers WHERE name = ?',
      [DbParam(A, 'finnes-ikke')]);
    CheckEqI(R2.AsInt64(0, 0), 0,
      'gjenbrukt statement bruker de nye parametrene');
    R2 := C.ExecParams(A, 'SELECT count(*) FROM sq_customers WHERE name = ?',
      [DbParam(A, 'Ada')]);
    CheckEqI(R2.AsInt64(0, 0), Count_,
      'og gir samme svar som før når parameteren er den samme');

    { NULL etter en ikke-NULL-verdi på samme statement. }
    R2 := C.ExecParams(A, 'SELECT count(*) FROM sq_customers WHERE name IS ?',
      [DbNull]);
    Check(R2.RowCount = 1, 'NULL-parameter på et gjenbrukt statement');

    { En feil skal ikke ødelegge det cachede statementet. }
    Feilet_ := False;
    try
      C.ExecParams(A, 'INSERT INTO sq_customers (id, name, email) VALUES (?, ?, ?)',
        [DbParam(A, Int64(1)), DbParam(A, 'Kopi'), DbParam(A, 'kopi@x.no')]);
    except
      on E: EDbError do Feilet_ := True;
    end;
    Check(Feilet_, 'dobbel primærnøkkel gir feil');
    R2 := C.ExecParams(A, 'SELECT name FROM sq_customers WHERE id = ?',
      [DbParam(A, Int64(1))]);
    Check(R2.RowCount = 1, 'cachet statement virker etter en feil');

    { prepare_v2 håndterer skjemaendringer selv — der MySQL må kaste
      statementet ut av cachen, trenger SQLite det ikke. }
    C.Exec(A, 'ALTER TABLE sq_customers ADD COLUMN note TEXT');
    R2 := C.ExecParams(A, 'SELECT name FROM sq_customers WHERE id = ?',
      [DbParam(A, Int64(1))]);
    Check(R2.RowCount = 1, 'cachet statement overlever ALTER TABLE');

    { Cachen av: forberedes hver gang, og ingenting blir liggende åpent. }
    Sq.FlushStatementCache;
    ForApne := Sq.OpenStatements;
    ForPrep := Sq.PreparedCount;
    Sq.CacheLimit := 0;
    for I := 1 to 30 do
      C.ExecParams(A, 'SELECT email FROM sq_customers WHERE id = ?',
        [DbParam(A, Int64(1))]);
    CheckEqI(Sq.PreparedCount - ForPrep, 30, 'cachen av: forberedes hver gang');
    CheckEqI(Sq.OpenStatements - ForApne, 0,
      'og ingen statements blir liggende åpne');
    Sq.CacheLimit := 64;

    { Over grensen tømmes cachen, og antallet åpne følger med ned. }
    Sq.FlushStatementCache;
    Sq.CacheLimit := 4;
    for I := 1 to 12 do
      C.ExecParams(A, Format('SELECT %d FROM sq_customers WHERE id = ?', [I]),
        [DbParam(A, Int64(1))]);
    Check(Sq.OpenStatements <= 4, 'cachen holder seg innenfor grensen');
    Sq.CacheLimit := 64;
    Sq.FlushStatementCache;
    CheckEqI(Sq.OpenStatements, 0, 'flush lukker alle');

    { Et måltall, ikke en påstand. Tidsgrenser i en suite blir flakete på en
      lastet maskin, men «cache» er tom tale uten et tall bak. }
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
    Si2('2000 spørringer', Format('%d ms uten cache, %d ms med', [Without, With_]));
    Check(With_ <= Without + (Without div 4) + 2, 'cachen gjorde det ikke tregere');
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
    { Leser nøyaktig én respons, styrt av Content-Length. NoBody må settes
      for svar på HEAD: de oppgir Content-Length uten å sende kroppen. }
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
  { Without dette blir en feil i verten til en testsuite som står i stampe. }
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
  TE2EHandler = class
  public
    Statisk: TStaticFiles;
    function Handle(Req: TRequest): TResponse;
  end;

{ Størrelsen er hele poenget. Fila må få plass i arenablokka som alt er i
  bruk av requesten — er den større, får den en ny blokk, og den veien
  virker. Suiten kjører med 16 kB blokker, så 6000 byte lander på riktig
  side: hodet og TRequest tar et par kB, og resten er ledig. }
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
  if Req.Path.EqualsStr('/last-opp') then
  begin
    if not Req.Multipart.Ok then
      Exit(RespondText(Req.Multipart.ErrorText, 400));
    Exit(RespondText(Format('%s|%s|%d|%s',
      [Req.Form('tittel').ToString,
       Req.Upload('fil').ClientName.ToString,
       Req.Upload('fil').Size,
       Req.Upload('fil').Content.ToString])));
  end;
  if Req.Path.EqualsStr('/sprekk') then
    raise Exception.Create('med vilje');
  Result := RespondText('borte', 404);
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
  StatiskFil: TStringList;
begin
  Group('Ende-til-ende over socket');
  { Content_ med CRLF i, og med noe som ligner grensen. Går det hele veien
    gjennom en socket uendret, holder rammeverket. }
  MpContent := 'linje1'#13#10'--XA'#13#10'linje2';

  Opts := DefaultServerOptions;
  Opts.Port := 0;             { la kjernen velge }
  Opts.Workers := 2;
  Opts.ArenaBlockSize := 16 * 1024;
  H := TE2EHandler.Create;
  { En fil på disk å servere. Katalogen er under .build, så den forsvinner
    med resten når noen rydder. }
  ForceDirectories('.build' + PathDelim + 'e2e-statisk' + PathDelim + 'statisk');
  StatiskFil := TStringList.Create;
  try
    StatiskFil.Text := StringOfChar('a', StaticSize - 1);
    StatiskFil.SaveToFile('.build' + PathDelim + 'e2e-statisk' + PathDelim +
      'statisk' + PathDelim + 'stor.css');
  finally
    StatiskFil.Free;
  end;
  H.Statisk := TStaticFiles.Create('.build' + PathDelim + 'e2e-statisk');

  Server := TAskrServer.Create(Opts);
  try
    Server.SetHandler(H.Handle);
    Server.Start;
    Port := Server.BoundPort;
    Check(Port > 0, 'serveren valgte en port (bind til 0)');

    Check(C.Connect(Port), 'klienten kobler til');
    C.SendRaw('GET / HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    Check(C.ReadResponse(Head, Body), 'fikk svar');
    Check(Pos('HTTP/1.1 200 OK', Head) = 1, 'GET / gir 200');
    CheckEqS(Body, 'rot', 'riktig kropp');

    { Samme tilkobling igjen — keep-alive. }
    C.SendRaw('GET /name?name=Knut HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    Check(C.ReadResponse(Head, Body), 'andre request på samme tilkobling');
    CheckEqS(Body, 'Knut', 'keep-alive fungerer');

    C.SendRaw('GET /finnes-ikke HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    C.ReadResponse(Head, Body);
    Check(Pos('HTTP/1.1 404 Not Found', Head) = 1, '404');

    { En statisk fil som oppfølging på samme tilkobling.

      Dette er formen enhver nettleser bruker: hent siden, hent så css-en
      og js-en over den samme tilkoblingen. Den krasjet med
      EAccessViolation på et ekte nettsted bygget med rammeverket, og bare
      når fila fikk plass i arenablokka som alt var i bruk — en stor fil
      fikk en ny blokk og gikk fint, en liten fikk det ikke. Alene gikk
      begge. }
    C.SendRaw('GET / HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    Check(C.ReadResponse(Head, Body), 'side før den statiske fila');
    C.SendRaw('GET /statisk/stor.css HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    Check(C.ReadResponse(Head, Body), 'fikk svar på den statiske fila');
    Check(Pos('HTTP/1.1 200 OK', Head) = 1,
      'statisk fil etter en side på samme tilkobling');
    CheckEqI(Length(Body), StaticSize, 'og hele fila kom med');
    Check(Pos('text/css', Head) > 0, 'med riktig innholdstype');

    { Og én gang til, for å vise at det ikke var én tilfeldig gang. }
    C.SendRaw('GET /name?name=x HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    C.ReadResponse(Head, Body);
    C.SendRaw('GET /statisk/stor.css HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    C.ReadResponse(Head, Body);
    Check(Pos('HTTP/1.1 200 OK', Head) = 1, 'og igjen');

    C.SendRaw('HEAD / HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    C.ReadResponse(Head, Body, True);
    Check(Pos('Content-Length: 3', Head) > 0, 'HEAD har Content-Length');
    CheckEqS(Body, '', 'HEAD har ingen kropp');

    { En ekte opplasting over socketen. Alt annet om multipart testes mot
      en kropp som allerede ligger i minnet; dette er den eneste testen der
      bytene faktisk går gjennom lesebufferet og Content-Length. }
    MpBody :=
      '--XB'#13#10'Content-Disposition: form-data; name="tittel"'#13#10#13#10 +
      'Rapport'#13#10 +
      '--XB'#13#10'Content-Disposition: form-data; name="fil"; ' +
      'filename="data.bin"'#13#10'Content-Type: application/octet-stream' +
      #13#10#13#10 + MpContent + #13#10 +
      '--XB--'#13#10;
    C.SendRaw('POST /last-opp HTTP/1.1'#13#10'Host: test'#13#10 +
      'Content-Type: multipart/form-data; boundary=XB'#13#10 +
      'Content-Length: ' + IntToStr(Length(MpBody)) + #13#10#13#10 + MpBody);
    Check(C.ReadResponse(Head, Body), 'opplastingen ble besvart');
    CheckEqS(Body, 'Rapport|data.bin|' + IntToStr(Length(MpContent)) + '|' +
      MpContent, 'fil og felt kom hele gjennom socketen');

    C.SendRaw('POST /ekko HTTP/1.1'#13#10'Host: test'#13#10 +
              'Content-Length: 11'#13#10#13#10'hallo arena');
    C.ReadResponse(Head, Body);
    CheckEqS(Body, 'hallo arena', 'POST-kropp leses');

    { Pipelining: to requests i én skriving. }
    C.SendRaw('GET / HTTP/1.1'#13#10'Host: test'#13#10#13#10 +
              'GET /name?name=to HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    C.ReadResponse(Head, Body);
    CheckEqS(Body, 'rot', 'pipelining, første svar');
    C.ReadResponse(Head, Body);
    CheckEqS(Body, 'to', 'pipelining, andre svar');

    { En exception i handleren skal koste requesten, ikke workeren. }
    C.SendRaw('GET /sprekk HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    C.ReadResponse(Head, Body);
    Check(Pos('HTTP/1.1 500', Head) = 1, 'exception gir 500');
    C.Close;

    Check(C.Connect(Port), 'serveren lever etter en exception');
    C.SendRaw('GET / HTTP/1.1'#13#10'Host: test'#13#10#13#10);
    C.ReadResponse(Head, Body);
    CheckEqS(Body, 'rot', 'ny tilkobling virker');
    C.Close;

    { Ugyldig request. }
    Check(C.Connect(Port), 'kobler til for ugyldig request');
    C.SendRaw('GET / HTTP/1.1'#13#10#13#10);
    C.ReadResponse(Head, Body);
    Check(Pos('HTTP/1.1 400', Head) = 1, 'manglende Host gir 400');
    C.Close;

    Check(C.Connect(Port), 'kobler til for chunked');
    C.SendRaw('POST / HTTP/1.1'#13#10'Host: t'#13#10 +
              'Transfer-Encoding: chunked'#13#10#13#10);
    C.ReadResponse(Head, Body);
    Check(Pos('HTTP/1.1 501', Head) = 1, 'chunked gir 501');
    C.Close;

    { Arenaen skal flate ut under last, ikke vokse per request. }
    Check(C.Connect(Port), 'kobler til for lasttest');
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
    CheckEqI(Reserved2, Reserved1, 'arenaen vokser ikke under vedvarende last');
    Check(Server.TotalArenaHighWater < 64 * 1024,
      'toppforbruket per request holder seg lite');
    { 13 gyldige requests over, så 50 + 1 + 500 her. De to avviste (400 og
      501) telles ikke, fordi de aldri nådde en handler. }
    CheckEqI(Server.TotalRequests, 565, 'alle gyldige requests ble talt');
    C.Close;
  finally
    Server.Free;
    H.Free;
  end;
end;

begin
  { Denne suiten tester ikke loggen, og ende-til-ende-delen kaster med
    vilje i /sprekk. Without dette havner en ERROR-linje midt i utskriften og
    ser ut som en feil i testen. }
  SetLogLevel(llNone);
  WriteLn('Askr — testsuite for fase 1, steg 1');

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
  TestJsonSkriv;
  TestJsonLes;
  TestInertia;
  TestRuter;
  TestValidering;
  TestBinding;
  TestNornSchema;
  TestNornNavn;
  TestCache;
  TestModellLivskvalitet;
  TestQueue;
  TestSqlite;
  TestEndToEnd;

  WriteLn;
  WriteLn(Format('%d ok, %d failed', [Passed, Failed]));
  if Failed > 0 then
    Halt(1);
end.
