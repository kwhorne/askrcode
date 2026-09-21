{ Askr.Http.Response — the response object and its serialisation.

  The response is built in the request arena like everything else, and
  serialised into one contiguous buffer before the host writes to the
  socket. One write per response means fewer syscalls than writing head
  and body separately, and it lets a small response go out in a single TCP
  segment. }
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

    { The builders return Self, so they chain:
      Result := Respond(201).WithHeader('Location', Url).WithJson(Payload); }
    function Status(ACode: Integer): TResponse;
    function WithHeader(const AName, AValue: string): TResponse; overload;
    function WithHeader(const AName: string; const AValue: TStr): TResponse; overload;
    { Adds without replacing. Only for headers that may legally repeat —
      Set-Cookie is the one that matters in practice. For anything else
      two identical header names are a mistake by the caller, and
      WithHeader is the one to use. }
    function AddHeader(const AName, AValue: string): TResponse;
    { One Set-Cookie. Further calls give further cookies, as the protocol
      allows. HttpOnly and SameSite=Lax are the defaults because the
      alternative is remembering them; `ReadableByJs` turns HttpOnly off
      for the cookies a frontend is actually meant to read, such as
      XSRF-TOKEN. MaxAge < 0 gives a session cookie, 0 deletes. }
    function WithCookie(const AName, AValue: string; MaxAge: Integer = -1;
      Secure: Boolean = False; ReadableByJs: Boolean = False;
      const SameSite: string = 'Lax'; const Path: string = '/'): TResponse;
    function WithContentType(const AValue: string): TResponse;
    { The first value for the name, or an empty string. After-filters need
      to see what the handler set — a filter that can only write is half
      a filter. With several Set-Cookie headers it gives the first; for
      that purpose there are HeaderCount and HeaderAt. }
    function HeaderValue(const AName: string): string;
    function HeaderAt(Index: Integer): PHttpHeader;
    function WithBody(const ABody: TStr): TResponse; overload;
    function WithBody(const ABody: string): TResponse; overload;

    { Writes the status line, the headers and the body into B.
      ConnectionClose drives the Connection header; HeadOnly leaves the
      body out but keeps Content-Length, as HEAD requires. }
    procedure WriteTo(var B: TStrBuilder; ConnectionClose, HeadOnly: Boolean);

    { True when the status code by definition has no body. }
    function BodyForbidden: Boolean;

    property StatusCode: Integer read FStatus;
    property Body: TStr read FBody;
    property HeaderCount: Integer read FHeaderCount;
  end;

{ All of these allocate in the ambient arena (see Askr.Core.Arena). }
function Respond(AStatus: Integer = 200): TResponse;
function RespondText(const S: string; AStatus: Integer = 200): TResponse;
function RespondHtml(const S: string; AStatus: Integer = 200): TResponse;
function RespondJson(const S: string; AStatus: Integer = 200): TResponse;
function Redirect(const Location: string; AStatus: Integer = 302): TResponse;
function NoContent: TResponse;

implementation

const
  { Sent with every response. Can be turned off on the server. }
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
  { The same header name twice is nearly always a mistake by the caller,
    and for Location or Content-Type it is actively harmful. The last value
    wins. Set-Cookie is the exception that may legally repeat, and it has
    AddHeader and WithCookie. }
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
  Cookie_: string;
begin
  Cookie_ := AName + '=' + AValue + '; Path=' + Path;
  if MaxAge >= 0 then
    Cookie_ := Cookie_ + '; Max-Age=' + IntToStr(MaxAge);
  if not ReadableByJs then
    Cookie_ := Cookie_ + '; HttpOnly';
  if SameSite <> '' then
    Cookie_ := Cookie_ + '; SameSite=' + SameSite;
  if Secure then
    Cookie_ := Cookie_ + '; Secure';
  Result := AddHeader('Set-Cookie', Cookie_);
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
  { Copied into the arena: the caller's string may be a temporary. }
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

