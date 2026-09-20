{ Askr.Http.Response — responsobjekt og serialisering.

  Responsen bygges i request-arenaen som alt annet, og serialiseres til ett
  sammenhengende buffer før verten skriver til socketen. Én write per respons
  gir færre syscalls enn å skrive hode og kropp hver for seg, og gjør at små
  responser går ut i ett TCP-segment. }
unit Askr.Http.Response;

{$mode Delphi}{$H+}
{$POINTERMATH ON}

interface

uses
  SysUtils, Askr.Core.Arena, Askr.Core.Text, Askr.Core.Clock, Askr.Http.Types;

type
  TResponse = class(TArenaObject)
  private
    FStatus: Integer;
    FHeaders: PHttpHeader;
    FHeaderCount: Integer;
    FHeaderCap: Integer;
    FBody: TStr;
    procedure GrowHeaders;
    function IndexOfHeader(const AName: string): Integer;
  public
    constructor Create(AStatus: Integer = 200);

    { Byggerne returnerer Self, så de kan kjedes:
        Result := Respond(201).WithHeader('Location', Url).WithJson(Payload); }
    function Status(ACode: Integer): TResponse;
    function WithHeader(const AName, AValue: string): TResponse; overload;
    function WithHeader(const AName: string; const AValue: TStr): TResponse; overload;
    { Legger til uten å erstatte. Bare for headere som lovlig kan gjentas —
      Set-Cookie er den som betyr noe i praksis. For alt annet er to like
      headernavn en feil hos kalleren, og WithHeader er den som skal brukes. }
    function AddHeader(const AName, AValue: string): TResponse;
    { Én Set-Cookie. Flere kall gir flere kaker, slik protokollen tillater.
      HttpOnly og SameSite=Lax er standard fordi alternativet er å huske
      dem; `ReadableByJs` slår av HttpOnly for de kakene en frontend faktisk
      skal lese, som XSRF-TOKEN. MaxAge < 0 gir en sesjonskake, 0 sletter. }
    function WithCookie(const AName, AValue: string; MaxAge: Integer = -1;
      Secure: Boolean = False; ReadableByJs: Boolean = False;
      const SameSite: string = 'Lax'; const Path: string = '/'): TResponse;
    function WithContentType(const AValue: string): TResponse;
    { Første verdi for navnet, eller tom streng. Etterfiltre trenger å
      kunne se hva handleren satte — en filtrering som bare kan skrive er
      halv. Med flere Set-Cookie gir den den første; til det formålet
      finnes HeaderCount og HeaderAt. }
    function HeaderValue(const AName: string): string;
    function HeaderAt(Index: Integer): PHttpHeader;
    function WithBody(const ABody: TStr): TResponse; overload;
    function WithBody(const ABody: string): TResponse; overload;

    { Skriver statuslinje, headere og kropp inn i B.
      ConnectionClose styrer Connection-headeren; HeadOnly utelater kroppen
      men beholder Content-Length, slik HEAD krever. }
    procedure WriteTo(var B: TStrBuilder; ConnectionClose, HeadOnly: Boolean);

    { True når statuskoden per definisjon ikke har kropp. }
    function BodyForbidden: Boolean;

    property StatusCode: Integer read FStatus;
    property Body: TStr read FBody;
    property HeaderCount: Integer read FHeaderCount;
  end;

{ Alle disse allokerer i den omgivende arenaen (se Askr.Core.Arena). }
function Respond(AStatus: Integer = 200): TResponse;
function RespondText(const S: string; AStatus: Integer = 200): TResponse;
function RespondHtml(const S: string; AStatus: Integer = 200): TResponse;
function RespondJson(const S: string; AStatus: Integer = 200): TResponse;
function Redirect(const Location: string; AStatus: Integer = 302): TResponse;
function NoContent: TResponse;

implementation

const
  { Sendes med hver respons. Kan slås av på serveren. }
  ServerToken = 'Askr';

constructor TResponse.Create(AStatus: Integer);
begin
  inherited Create;
  FStatus := AStatus;
  FHeaderCap := 8;
  FHeaders := PHttpHeader(Arena.Alloc(PtrUInt(FHeaderCap) * SizeOf(THttpHeader)));
  FHeaderCount := 0;
end;

procedure TResponse.GrowHeaders;
var
  NewCap: Integer;
  NewPtr: PHttpHeader;
begin
  NewCap := FHeaderCap * 2;
  NewPtr := PHttpHeader(Arena.Alloc(PtrUInt(NewCap) * SizeOf(THttpHeader)));
  Move(FHeaders^, NewPtr^, PtrUInt(FHeaderCount) * SizeOf(THttpHeader));
  FHeaders := NewPtr;
  FHeaderCap := NewCap;
end;

function TResponse.IndexOfHeader(const AName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to FHeaderCount - 1 do
    if FHeaders[I].Name.SameTextStr(AName) then
      Exit(I);
  Result := -1;
end;

function TResponse.Status(ACode: Integer): TResponse;
begin
  FStatus := ACode;
  Result := Self;
end;

function TResponse.WithHeader(const AName: string; const AValue: TStr): TResponse;
var
  I: Integer;
begin
  { Samme headernavn to ganger er nesten alltid en feil hos kalleren, og for
    Location eller Content-Type er det direkte skadelig. Siste verdi vinner.
    Set-Cookie er unntaket som lovlig kan gjentas, og den har AddHeader og
    WithCookie. }
  I := IndexOfHeader(AName);
  if I >= 0 then
  begin
    FHeaders[I].Value := AValue;
    Exit(Self);
  end;

  if FHeaderCount >= FHeaderCap then
    GrowHeaders;
  FHeaders[FHeaderCount].Name := StrDup(Arena, AName);
  FHeaders[FHeaderCount].Value := AValue;
  Inc(FHeaderCount);
  Result := Self;
end;

function TResponse.WithHeader(const AName, AValue: string): TResponse;
begin
  Result := WithHeader(AName, StrDup(Arena, AValue));
end;

function TResponse.AddHeader(const AName, AValue: string): TResponse;
begin
  if FHeaderCount >= FHeaderCap then
    GrowHeaders;
  FHeaders[FHeaderCount].Name := StrDup(Arena, AName);
  FHeaders[FHeaderCount].Value := StrDup(Arena, AValue);
  Inc(FHeaderCount);
  Result := Self;
end;

function TResponse.WithCookie(const AName, AValue: string; MaxAge: Integer;
  Secure: Boolean; ReadableByJs: Boolean; const SameSite: string;
  const Path: string): TResponse;
var
  Kake: string;
begin
  Kake := AName + '=' + AValue + '; Path=' + Path;
  if MaxAge >= 0 then
    Kake := Kake + '; Max-Age=' + IntToStr(MaxAge);
  if not ReadableByJs then
    Kake := Kake + '; HttpOnly';
  if SameSite <> '' then
    Kake := Kake + '; SameSite=' + SameSite;
  if Secure then
    Kake := Kake + '; Secure';
  Result := AddHeader('Set-Cookie', Kake);
end;

function TResponse.HeaderValue(const AName: string): string;
var
  I: Integer;
begin
  I := IndexOfHeader(AName);
  if I < 0 then
    Exit('');
  Result := FHeaders[I].Value.ToString;
end;

function TResponse.HeaderAt(Index: Integer): PHttpHeader;
begin
  if (Index < 0) or (Index >= FHeaderCount) then
    Exit(nil);
  Result := @FHeaders[Index];
end;

function TResponse.WithContentType(const AValue: string): TResponse;
begin
  Result := WithHeader('Content-Type', AValue);
end;

function TResponse.WithBody(const ABody: TStr): TResponse;
begin
  FBody := ABody;
  Result := Self;
end;

function TResponse.WithBody(const ABody: string): TResponse;
begin
  { Kopieres inn i arenaen: kalleren sin string kan være en temporær. }
  Result := WithBody(StrDup(Arena, ABody));
end;

function TResponse.BodyForbidden: Boolean;
begin
  Result := (FStatus = 204) or (FStatus = 304) or
            ((FStatus >= 100) and (FStatus < 200));
end;

procedure TResponse.WriteTo(var B: TStrBuilder; ConnectionClose, HeadOnly: Boolean);
var
  I: Integer;
  Reason: string;
  NoBody: Boolean;
begin
  NoBody := BodyForbidden;

  B.Reserve(128 + FBody.Len);

  B.Append('HTTP/1.1 ');
  B.AppendInt(FStatus);
  Reason := StatusText(FStatus);
  if Reason <> '' then
  begin
    B.AppendByte(Ord(' '));
    B.Append(Reason);
  end;
  B.AppendCRLF;

  for I := 0 to FHeaderCount - 1 do
  begin
    B.Append(FHeaders[I].Name);
    B.Append(': ');
    B.Append(FHeaders[I].Value);
    B.AppendCRLF;
  end;

  if not NoBody then
  begin
    B.Append('Content-Length: ');
    B.AppendInt(FBody.Len);
    B.AppendCRLF;
  end;

  B.Append('Date: ');
  AppendHttpDateNow(B);
  B.AppendCRLF;

  B.Append('Server: ' + ServerToken);
  B.AppendCRLF;

  if ConnectionClose then
    B.Append('Connection: close')
  else
    B.Append('Connection: keep-alive');
  B.AppendCRLF;

  B.AppendCRLF;

  if not (HeadOnly or NoBody) then
    B.Append(FBody);
end;

function Respond(AStatus: Integer): TResponse;
begin
  Result := TResponse.Create(AStatus);
end;

function RespondText(const S: string; AStatus: Integer): TResponse;
begin
  Result := TResponse.Create(AStatus)
    .WithContentType('text/plain; charset=utf-8')
    .WithBody(S);
end;

function RespondHtml(const S: string; AStatus: Integer): TResponse;
begin
  Result := TResponse.Create(AStatus)
    .WithContentType('text/html; charset=utf-8')
    .WithBody(S);
end;

function RespondJson(const S: string; AStatus: Integer): TResponse;
begin
  Result := TResponse.Create(AStatus)
    .WithContentType('application/json')
    .WithBody(S);
end;

function Redirect(const Location: string; AStatus: Integer): TResponse;
begin
  Result := TResponse.Create(AStatus).WithHeader('Location', Location);
end;

function NoContent: TResponse;
begin
  Result := TResponse.Create(204);
end;

end.

