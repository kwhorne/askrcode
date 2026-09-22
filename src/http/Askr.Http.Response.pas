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
    { An entity tag, so that a client can ask whether its copy is still
      good. The value is the opaque part WITHOUT quotes -- they are added
      here, because an unquoted ETag is not a valid one and the mistake is
      invisible until some client rejects it.

      Weak means "the same as far as the reader is concerned" rather than
      byte for byte. Use it when the body may differ in ways that do not
      matter; a strong tag promises the bytes. }
    function WithETag(const AValue: string; Weak: Boolean = False): TResponse;
    { Removes every header with this name. Needed because a header can be
      wrong to send rather than merely wrong in value -- an ETag on a
      response that carries a cookie is the case this exists for. }
    function RemoveHeader(const AName: string): TResponse;
    { Turns this into a 304 when the client's If-None-Match matches the
      ETag, and says whether it did. Takes the header value rather than the
      request, so that a response does not have to know what a request is,
      and so that it can be tested without a server.

      **A response that sets a cookie never answers 304, and loses its
      ETag.** A body that comes with a cookie is a body made for one
      client: a page with a CSRF token in it, served from the client's
      cache on a later 304, is a form with a token that has since been
      rotated. The failure is a rejected submit that nobody can reproduce,
      so the guard is here rather than in a rule somebody has to remember.

      Only GET and HEAD are conditional in this sense; the caller checks
      the method. If-None-Match on other methods means something else
      entirely (a precondition, answered with 412), which Askr does not
      do. }
    function NotModifiedIfMatches(const IfNoneMatch: string): Boolean;
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

function TResponse.WithETag(const AValue: string; Weak: Boolean): TResponse;
var
  V: string;
begin
  V := '"' + AValue + '"';
  if Weak then
    V := 'W/' + V;
  Result := WithHeader('ETag', V);
end;

function TResponse.RemoveHeader(const AName: string): TResponse;
var
  I, J: Integer;
begin
  Result := Self;
  I := 0;
  while I < FHeaderCount do
    if FHeaders[I].Name.SameTextStr(AName) then
    begin
      for J := I to FHeaderCount - 2 do
        FHeaders[J] := FHeaders[J + 1];
      Dec(FHeaderCount);
    end
    else
      Inc(I);
end;

{ Does the client's If-None-Match cover Tag?

  The header is a comma-separated list, or the single token `*`. Comparison
  is by weak validator: `W/"x"` and `"x"` are a match for this purpose,
  which is what the specification says for If-None-Match, and is the
  opposite of If-Match. }
function ETagListMatches(const List_, Tag: string): Boolean;
var
  Part, T: string;
  P: Integer;
  Rest: string;

  function Bare(const S: string): string;
  begin
    Result := Trim(S);
    if Copy(Result, 1, 2) = 'W/' then
      Result := Copy(Result, 3, MaxInt);
  end;

begin
  Result := False;
  if (Trim(List_) = '') or (Tag = '') then
    Exit;
  if Trim(List_) = '*' then
    Exit(True);

  T := Bare(Tag);
  Rest := List_;
  repeat
    P := Pos(',', Rest);
    if P > 0 then
    begin
      Part := Copy(Rest, 1, P - 1);
      Rest := Copy(Rest, P + 1, MaxInt);
    end
    else
    begin
      Part := Rest;
      Rest := '';
    end;
    if Bare(Part) = T then
      Exit(True);
  until Rest = '';
end;

function TResponse.NotModifiedIfMatches(const IfNoneMatch: string): Boolean;
var
  Tag: string;
begin
  Result := False;

  { The cookie guard comes first, and takes the ETag with it. Leaving the
    tag in place would only move the problem to the next cache in the
    chain. }
  if HeaderValue('Set-Cookie') <> '' then
  begin
    RemoveHeader('ETag');
    Exit;
  end;

  { Only a 200 becomes a 304. A 404 or a 500 with an ETag is a mistake
    somewhere else, and answering it conditionally would hide it. }
  if FStatus <> 200 then
    Exit;

  Tag := HeaderValue('ETag');
  if Tag = '' then
    Exit;
  if not ETagListMatches(IfNoneMatch, Tag) then
    Exit;

  FStatus := 304;
  FBody := StrEmpty;
  { Content-Type describes a body, and there is no body. The headers a 304
    is required to carry -- ETag, Cache-Control, Date -- stay. }
  RemoveHeader('Content-Type');
  Result := True;
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

