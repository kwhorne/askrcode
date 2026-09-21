{ Askr.Http.Request — parsing av HTTP/1.1-request inn i arenaen.

  Parseren kopierer ingenting. Verten leser bytes inn i ett sammenhengende
  buffer i request-arenaen, og alle felter her er utsnitt (TStr) inn i det
  bufferet. Når verten kaller Arena.Reset forsvinner både bufferet og
  requesten i én operasjon.

  Det som bevisst ikke støttes i fase 1: chunked transfer-encoding, obsolete
  line folding, og pipelining utover én request om gangen per tilkobling.
  De to første avvises eksplisitt i stedet for å tolkes feil. }
unit Askr.Http.Request;

{$mode Delphi}{$H+}
{ Header-tabellen er en sammenhengende blokk i arenaen og indekseres med
  peker-aritmetikk. }
{$POINTERMATH ON}

interface

uses
  SysUtils, Askr.Core.Arena, Askr.Core.Text, Askr.Http.Types,
  Askr.Http.Multipart;

type
  TParseState = (
    psOk,
    psNeedMore,           { hele hodet er ikke lest ennå }
    psBadRequest,         { 400 }
    psUriTooLong,         { 414 }
    psHeadersTooLarge,    { 431 }
    psBodyTooLarge,       { 413 }
    psUnsupportedVersion, { 505 }
    psNotImplemented      { 501 — chunked }
  );

  TRequest = class(TArenaObject)
  private
    FMethod: THttpMethod;
    FMethodStr: TStr;
    FTarget: TStr;
    FRawPath: TStr;
    FPath: TStr;
    FQueryString: TStr;
    FVersionMinor: Integer;
    FHeaders: PHttpHeader;
    FHeaderCount: Integer;
    FContentLength: Int64;
    FKeepAlive: Boolean;
    FBody: TStr;
    FRemoteAddr: TStr;
    FParams: PHttpHeader;
    FParamCount: Integer;
    FParamCapacity: Integer;
    { Multipart parses høyst én gang per request. Cachen ligger på
      requesten selv, ikke i en trådlokal tabell: TRequest lages på nytt
      for hver request, så feltet er ferskt uten at noen må rydde det. }
    FMultipart: TMultipartForm;
    FMultipartDone: Boolean;
    function ParseRequestLine(const Line: TStr): TParseState;
    function ParseHeaderLines(const Block: TStr; LineCount: Integer): TParseState;
    function ApplyHeaders(MaxBody: Int64): TParseState;
  public
    { Raw er hodet uten den avsluttende tomme linjen. MaxBody håndheves mot
      Content-Length før verten begynner å lese kroppen, slik at en for stor
      request avvises uten å bli lest inn. }
    function ParseHead(const Raw: TStr; MaxBody: Int64): TParseState;
    procedure SetBody(const ABody: TStr);
    procedure SetRemoteAddr(const AAddr: TStr);

    function Header(const AName: string): TStr;
    function HasHeader(const AName: string): Boolean;
    function HeaderAt(Index: Integer): PHttpHeader;

    { Ruteparametre. Settes av ruteren når et mønster matcher. }
    procedure SetParam(const AName: string; const AValue: TStr);
    procedure ClearParams;
    function Param(const AName: string): TStr;
    function HasParam(const AName: string): Boolean;
    function IntParam(const AName: string; Default: Int64 = 0): Int64;
    property ParamCount: Integer read FParamCount;

    function Query(const AName: string): TStr;
    function HasQuery(const AName: string): Boolean;
    { Leser fra kroppen. Dekker både application/x-www-form-urlencoded og
      de vanlige feltene i en multipart/form-data — et skjema med en fil i
      skal ikke gjøre de andre feltene utilgjengelige. }
    function Form(const AName: string): TStr;
    function HasForm(const AName: string): Boolean;
    function ContentType: TStr;
    function IsJson: Boolean;
    function IsMultipart: Boolean;

    { Hele den delte kroppen. Parses første gang noe spør, og bare da.
      `Ok` er False når kroppen ikke lot seg dele — da er 400 svaret. }
    function Multipart: TMultipartForm;
    { Én opplastet fil. `IsEmpty` er True når feltet ikke fantes eller
      brukeren ikke valgte noen fil. }
    function Upload(const AName: string): TUploadedFile;
    { All_ filene under samme navn, som i `<input type="file" multiple>`. }
    function Uploads(const AName: string): TUploadedFiles;

    property Method: THttpMethod read FMethod;
    property MethodStr: TStr read FMethodStr;
    property Target: TStr read FTarget;
    { Prosentdekodet sti. Dette er det ruteren matcher mot. }
    property Path: TStr read FPath;
    property RawPath: TStr read FRawPath;
    property QueryString: TStr read FQueryString;
    property VersionMinor: Integer read FVersionMinor;
    property HeaderCount: Integer read FHeaderCount;
    property ContentLength: Int64 read FContentLength;
    property KeepAlive: Boolean read FKeepAlive write FKeepAlive;
    { ?page=N, klemt til minst 1. Finnes fordi paginering er det vanligste
      stedet en query-parameter blir til et tall. }
    function Page: Integer;
    function IntQuery(const AName: string; Default: Int64 = 0): Int64;

    property Body: TStr read FBody;
    property RemoteAddr: TStr read FRemoteAddr;
  end;

{ Omgivende request for gjeldende tråd, etter samme mønster som UseArena og
  UseDb. Verten setter den før den kaller inn i brukerkode, slik at
  hjelpere som Inertia() kan finne den uten å ta den som parameter. }
function CurrentRequest: TRequest;
function UseRequest(R: TRequest): TRequest;

implementation

threadvar
  GCurrentRequest: TRequest;

function CurrentRequest: TRequest;
begin
  Result := GCurrentRequest;
end;

function UseRequest(R: TRequest): TRequest;
begin
  Result := GCurrentRequest;
  GCurrentRequest := R;
end;

function TRequest.IntQuery(const AName: string; Default: Int64): Int64;
begin
  Result := Query(AName).ToIntDef(Default);
end;

function TRequest.Page: Integer;
var
  N: Int64;
begin
  N := IntQuery('page', 1);
  if N < 1 then
    N := 1;
  Result := Integer(N);
end;

function TRequest.ParseRequestLine(const Line: TStr): TParseState;
var
  Rest, Ver: TStr;
  SP1, SP2, Frag: SizeInt;
begin
  if Line.Len > MaxRequestLineBytes then
    Exit(psUriTooLong);

  SP1 := Line.IndexOfByte(Ord(' '));
  if SP1 <= 0 then
    Exit(psBadRequest);
  SP2 := Line.IndexOfByte(Ord(' '), SP1 + 1);
  if SP2 <= SP1 + 1 then
    Exit(psBadRequest);

  FMethodStr := Line.Slice(0, SP1);
  FMethod := MethodFromStr(FMethodStr);
  FTarget := Line.Slice(SP1 + 1, SP2 - SP1 - 1);
  Ver := Line.Slice(SP2 + 1);

  if not Ver.StartsWithStr('HTTP/1.') or (Ver.Len <> 8) then
    Exit(psUnsupportedVersion);
  case (Ver.Data + 7)^ of
    Ord('0'): FVersionMinor := 0;
    Ord('1'): FVersionMinor := 1;
  else
    Exit(psUnsupportedVersion);
  end;

  { Absolute-form (http://host/sti) er lovlig mot proxyer. Vi tar bare stien. }
  if FTarget.StartsWithStr('http://') or FTarget.StartsWithStr('https://') then
  begin
    Rest := FTarget.Slice(FTarget.IndexOfByte(Ord('/'), 8));
    if Rest.Len = 0 then
      Rest := Str('/');
  end
  else
    Rest := FTarget;

  if (Rest.Len = 0) or ((Rest.Data^ <> Ord('/')) and not Rest.EqualsStr('*')) then
    Exit(psBadRequest);

  if not Rest.SplitAt(Ord('?'), FRawPath, FQueryString) then
    FQueryString := StrEmpty;

  { Fragment hører ikke hjemme i en request-target, men klienter sender det.
    Går via lokale variabler: SplitAt ville ellers skrevet over Self midtveis. }
  Frag := FRawPath.IndexOfByte(Ord('#'));
  if Frag >= 0 then
    FRawPath := FRawPath.Slice(0, Frag);
  Frag := FQueryString.IndexOfByte(Ord('#'));
  if Frag >= 0 then
    FQueryString := FQueryString.Slice(0, Frag);

  FPath := UrlDecode(Arena, FRawPath, False);
  Result := psOk;
end;

function TRequest.ParseHeaderLines(const Block: TStr; LineCount: Integer): TParseState;
var
  Rest, Line, N, V: TStr;
  H: PHttpHeader;
begin
  FHeaderCount := 0;
  if LineCount = 0 then
    Exit(psOk);

  FHeaders := PHttpHeader(Arena.Alloc(PtrUInt(LineCount) * SizeOf(THttpHeader)));
  Rest := Block;

  while Rest.Len > 0 do
  begin
    { Siste headerlinje kan mangle avsluttende LF. }
    Rest.SplitAt(10, Line, Rest);
    if (Line.Len > 0) and ((Line.Data + Line.Len - 1)^ = 13) then
      Line := Line.Slice(0, Line.Len - 1);
    if Line.Len = 0 then
      Continue;

    { Obsolete line folding — en headerlinje som starter med whitespace.
      RFC 9112 lar en server avvise dette, og det er tryggere enn å gjette. }
    if (Line.Data^ = Ord(' ')) or (Line.Data^ = 9) then
      Exit(psBadRequest);

    if not Line.SplitAt(Ord(':'), N, V) then
      Exit(psBadRequest);
    { Whitespace mellom feltnavn og kolon er request smuggling-materiale. }
    if (N.Len = 0) or ((N.Data + N.Len - 1)^ <= Ord(' ')) then
      Exit(psBadRequest);

    if FHeaderCount >= LineCount then
      Exit(psBadRequest);
    H := FHeaders + FHeaderCount;
    H^.Name := N;
    H^.Value := V.TrimSpace;
    Inc(FHeaderCount);
  end;
  Result := psOk;
end;

function TRequest.ApplyHeaders(MaxBody: Int64): TParseState;
var
  V: TStr;
  Seen: Boolean;
  I: Integer;
  H: PHttpHeader;
begin
  FContentLength := 0;
  FKeepAlive := FVersionMinor >= 1;
  Seen := False;

  for I := 0 to FHeaderCount - 1 do
  begin
    H := FHeaders + I;
    if H^.Name.SameTextStr('content-length') then
    begin
      { To ulike Content-Length er klassisk smuggling. Avvis. }
      if Seen then
        Exit(psBadRequest);
      Seen := True;
      if not H^.Value.ToInt64(FContentLength) or (FContentLength < 0) then
        Exit(psBadRequest);
      if FContentLength > MaxBody then
        Exit(psBodyTooLarge);
    end
    else if H^.Name.SameTextStr('transfer-encoding') then
      Exit(psNotImplemented)
    else if H^.Name.SameTextStr('connection') then
    begin
      V := H^.Value;
      if V.SameTextStr('close') then
        FKeepAlive := False
      else if V.SameTextStr('keep-alive') then
        FKeepAlive := True;
    end;
  end;

  { HTTP/1.1 krever Host. }
  if (FVersionMinor >= 1) and not HasHeader('host') then
    Exit(psBadRequest);

  Result := psOk;
end;

function TRequest.ParseHead(const Raw: TStr; MaxBody: Int64): TParseState;
var
  Line, Rest: TStr;
  LineCount, I: Integer;
begin
  { Parseren allokerer header-tabellen og dekodet sti i arenaen, så en TRequest
    må være laget innenfor en UseArena-blokk. }
  if Arena = nil then
    raise EArenaError.Create('TRequest.ParseHead: no arena');

  if Raw.Len > MaxHeaderBytes then
    Exit(psHeadersTooLarge);

  FHeaders := nil;
  FHeaderCount := 0;
  FBody := StrEmpty;

  if not Raw.SplitAt(10, Line, Rest) then
    Exit(psBadRequest);
  if (Line.Len > 0) and ((Line.Data + Line.Len - 1)^ = 13) then
    Line := Line.Slice(0, Line.Len - 1);

  Result := ParseRequestLine(Line);
  if Result <> psOk then
    Exit;

  { Teller linjer først, så header-tabellen kan allokeres i nøyaktig riktig
    størrelse i stedet for å vokse. }
  LineCount := 0;
  for I := 0 to Rest.Len - 1 do
    if (Rest.Data + I)^ = 10 then
      Inc(LineCount);
  if (Rest.Len > 0) and ((Rest.Data + Rest.Len - 1)^ <> 10) then
    Inc(LineCount);
  if LineCount > MaxHeaderCount then
    Exit(psHeadersTooLarge);

  Result := ParseHeaderLines(Rest, LineCount);
  if Result <> psOk then
    Exit;

  Result := ApplyHeaders(MaxBody);
end;

procedure TRequest.SetBody(const ABody: TStr);
begin
  FBody := ABody;
end;

procedure TRequest.SetRemoteAddr(const AAddr: TStr);
begin
  FRemoteAddr := AAddr;
end;

function TRequest.Header(const AName: string): TStr;
var
  I: Integer;
  H: PHttpHeader;
begin
  for I := 0 to FHeaderCount - 1 do
  begin
    H := FHeaders + I;
    if H^.Name.SameTextStr(AName) then
      Exit(H^.Value);
  end;
  Result := StrEmpty;
end;

function TRequest.HasHeader(const AName: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to FHeaderCount - 1 do
    if (FHeaders + I)^.Name.SameTextStr(AName) then
      Exit(True);
  Result := False;
end;

function TRequest.HeaderAt(Index: Integer): PHttpHeader;
begin
  if (Index < 0) or (Index >= FHeaderCount) then
    Exit(nil);
  Result := FHeaders + Index;
end;

procedure TRequest.SetParam(const AName: string; const AValue: TStr);
var
  NewCap: Integer;
  NewPtr: PHttpHeader;
  I: Integer;
begin
  for I := 0 to FParamCount - 1 do
    if FParams[I].Name.EqualsStr(AName) then
    begin
      FParams[I].Value := AValue;
      Exit;
    end;

  if FParamCount >= FParamCapacity then
  begin
    if FParamCapacity = 0 then
      NewCap := 8
    else
      NewCap := FParamCapacity * 2;
    NewPtr := PHttpHeader(Arena.AllocZero(
      PtrUInt(NewCap) * SizeOf(THttpHeader)));
    if FParamCount > 0 then
      Move(FParams^, NewPtr^, PtrUInt(FParamCount) * SizeOf(THttpHeader));
    FParams := NewPtr;
    FParamCapacity := NewCap;
  end;
  FParams[FParamCount].Name := StrDup(Arena, AName);
  FParams[FParamCount].Value := AValue;
  Inc(FParamCount);
end;

procedure TRequest.ClearParams;
begin
  { Bufferet beholdes; bare tellingen nullstilles. Ruteren prøver flere
    mønstre per request, og hver av dem skal starte blankt. }
  FParamCount := 0;
end;

function TRequest.Param(const AName: string): TStr;
var
  I: Integer;
begin
  for I := 0 to FParamCount - 1 do
    if FParams[I].Name.EqualsStr(AName) then
      Exit(FParams[I].Value);
  Result := StrEmpty;
end;

function TRequest.HasParam(const AName: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to FParamCount - 1 do
    if FParams[I].Name.EqualsStr(AName) then
      Exit(True);
  Result := False;
end;

function TRequest.IntParam(const AName: string; Default: Int64): Int64;
begin
  Result := Param(AName).ToIntDef(Default);
end;

function TRequest.Query(const AName: string): TStr;
begin
  QueryValue(Arena, FQueryString, AName, Result);
end;

function TRequest.HasQuery(const AName: string): Boolean;
var
  V: TStr;
begin
  Result := QueryValue(Arena, FQueryString, AName, V);
end;

function TRequest.Form(const AName: string): TStr;
begin
  Result := StrEmpty;
  if IsMultipart then
    Exit(Multipart.Value(AName));
  if not ContentType.StartsWithStr('application/x-www-form-urlencoded') then
    Exit;
  QueryValue(Arena, FBody, AName, Result);
end;

function TRequest.HasForm(const AName: string): Boolean;
var
  V: TStr;
begin
  if IsMultipart then
    Exit(Multipart.Has(AName));
  if not ContentType.StartsWithStr('application/x-www-form-urlencoded') then
    Exit(False);
  { Et felt som finnes med tom verdi er noe annet enn et som ikke finnes —
    en avkrysningsboks sender ofte nettopp en tom verdi. }
  Result := QueryValue(Arena, FBody, AName, V);
end;

function TRequest.IsMultipart: Boolean;
begin
  Result := ContentType.StartsWithStr('multipart/form-data');
end;

function TRequest.Multipart: TMultipartForm;
begin
  if not FMultipartDone then
  begin
    FMultipartDone := True;
    if IsMultipart then
      ParseMultipart(Arena, FBody, MultipartBoundary(ContentType), FMultipart)
    else
      FMultipart.Error := mpNoBoundary;
  end;
  Result := FMultipart;
end;

function TRequest.Upload(const AName: string): TUploadedFile;
begin
  Result := Multipart.FileFor(AName);
end;

function TRequest.Uploads(const AName: string): TUploadedFiles;
begin
  Result := Multipart.FilesFor(AName);
end;

function TRequest.ContentType: TStr;
begin
  Result := Header('content-type');
end;

function TRequest.IsJson: Boolean;
var
  CT: TStr;
  P: SizeInt;
begin
  CT := ContentType;
  if CT.StartsWithStr('application/json') then
    Exit(True);
  { Dekker application/ld+json, application/problem+json og resten av +json. }
  P := CT.IndexOfByte(Ord('+'));
  Result := (P >= 0) and CT.Slice(P).StartsWithStr('+json');
end;

end.
