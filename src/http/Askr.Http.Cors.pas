{ Askr.Http.Cors — who else may call this, from a browser.

  CORS is not a lock. It is a browser telling a page on one origin what it
  may do with a reply from another, and nothing else honours it: curl
  ignores it, a server ignores it, and so does anything that is not a
  browser. **It is not an access control**, and a route that must not be
  reached by some callers needs a guard, not a header.

  What it does control is real all the same: whether a page on
  https://app.example may read what your API answers, and whether the
  browser will attach the caller's cookies while asking.

  CLOSED UNLESS SOMEBODY SAYS OTHERWISE

  With no origin allowed, no CORS header is written at all, and a browser
  refuses to hand the reply to the page. That is the same rule as
  robots.txt and as a gate that does not exist: the state you land in
  without deciding anything has to be the narrow one, because the
  dangerous configuration is the one nobody thought about.

  ORIGINS MATCH EXACTLY

  `https://example.com.evil.example` starts with `https://example.com`,
  so a prefix test lets it in. Askr.WebAuthn learned this from a mutation
  test that showed its own vectors could not see the mistake, and the
  same rule applies here for the same reason. There is no pattern
  matching and no wildcard subdomain: an origin is a string, and it is
  either on the list or it is not.

  `*` AND CREDENTIALS CANNOT BOTH BE ASKED FOR

  A browser refuses `Access-Control-Allow-Origin: *` together with
  `Access-Control-Allow-Credentials: true` -- so a server that sends both
  has a configuration that reads as "anyone, with cookies" and behaves as
  "nobody". That is the worst kind of wrong: it looks generous and it
  fails. `AllowCredentials` after `AllowAnyOrigin` raises rather than
  letting that stand. }
unit Askr.Http.Cors;

{$mode Delphi}{$H+}

interface

uses
  SysUtils,
  Askr.Core.Text,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response, Askr.Http.Router;

type
  ECorsError = class(Exception);

  TCors = class
  private
    FOrigins: array of string;
    FAny: Boolean;
    FCredentials: Boolean;
    FMethods: string;
    FHeaders: string;
    FExpose: string;
    FMaxAge: Integer;
    function Allowed(const Origin: string): Boolean;
  public
    constructor Create;

    { One origin, matched exactly: scheme, host and port as the browser
      writes them, with no trailing slash. Call it once per origin. }
    function AllowOrigin(const Origin: string): TCors;
    { Any origin at all. Cannot be combined with AllowCredentials. }
    function AllowAnyOrigin: TCors;
    { The methods a cross-origin caller may use. GET, HEAD and POST are
      what a browser will try without asking; anything else needs to be
      listed. }
    function AllowMethods(const Methods: array of string): TCors;
    { The request headers it may send. Authorization is the one an API
      needs and the one a browser will not send without being told. }
    function AllowHeaders(const Headers: array of string): TCors;
    { The response headers the page is allowed to read. Without this a
      browser hands the page the body and a handful of headers and hides
      the rest -- including anything of your own. }
    function ExposeHeaders(const Headers: array of string): TCors;
    { Cookies and HTTP auth travel with the request. Raises after
      AllowAnyOrigin, because a browser refuses that pair. }
    function AllowCredentials: TCors;
    { How long a browser may cache the preflight answer. }
    function MaxAge(Seconds: Integer): TCors;

    { The header value for this request's Origin, or '' when it is not
      allowed. Exposed so a test, or an application doing its own
      handling, can ask without a server. }
    function OriginFor(Req: TRequest): string;
    function HasPolicy: Boolean;
    { Back to closed, with the defaults. For a test, and for an
      application that rebuilds its policy. }
    procedure Reset;
  end;

{ The policy. One per process, configured at startup. }
function Cors: TCors;

{ Answers preflights and adds the headers to everything else.

  Register it **first**, before the rate limiter and before
  authentication: a preflight carries no credentials by design -- the
  browser strips them -- so anything that refuses a request without one
  would refuse every preflight, and the actual request would never be
  sent. It is also not a request the caller made, so it should not spend
  anybody's rate limit. }
procedure UseCors(R: TRouter);

implementation

var
  GCors: TCors = nil;

function Cors: TCors;
begin
  if GCors = nil then
    GCors := TCors.Create;
  Result := GCors;
end;

constructor TCors.Create;
begin
  inherited Create;
  { The methods a browser sends without asking first. Anything else has
    to be listed, which is the point of a preflight. }
  FMethods := 'GET, HEAD, POST';
  FHeaders := 'Content-Type';
  FMaxAge := 600;
end;

procedure TCors.Reset;
begin
  FOrigins := nil;
  FAny := False;
  FCredentials := False;
  FMethods := 'GET, HEAD, POST';
  FHeaders := 'Content-Type';
  FExpose := '';
  FMaxAge := 600;
end;

function TCors.AllowOrigin(const Origin: string): TCors;
var
  O: string;
begin
  Result := Self;
  O := Trim(Origin);
  if O = '' then
    Exit;
  if O = '*' then
    raise ECorsError.Create(
      'AllowOrigin(''*'') is not the way to open this up. Call ' +
      'AllowAnyOrigin, which also refuses to be combined with ' +
      'AllowCredentials -- a browser rejects that pair, so a server that ' +
      'sends both looks open and answers nobody.');
  { A trailing slash is the commonest way to write an origin that then
    never matches, because a browser never sends one. }
  if O[Length(O)] = '/' then
    raise ECorsError.CreateFmt(
      'An origin has no trailing slash: %s. A browser sends ' +
      '"https://app.example", so that is what has to be on the list.',
      [O]);
  SetLength(FOrigins, Length(FOrigins) + 1);
  FOrigins[High(FOrigins)] := O;
end;

function TCors.AllowAnyOrigin: TCors;
begin
  Result := Self;
  if FCredentials then
    raise ECorsError.Create(
      'AllowAnyOrigin cannot follow AllowCredentials. A browser refuses ' +
      '"*" together with credentials, so the pair would read as "anyone, ' +
      'with cookies" and behave as "nobody". List the origins instead.');
  FAny := True;
end;

function TCors.AllowCredentials: TCors;
begin
  Result := Self;
  if FAny then
    raise ECorsError.Create(
      'AllowCredentials cannot follow AllowAnyOrigin. A browser refuses ' +
      '"*" together with credentials, so the pair would read as "anyone, ' +
      'with cookies" and behave as "nobody". List the origins instead.');
  FCredentials := True;
end;

function Join(const Parts: array of string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Parts) do
  begin
    if Trim(Parts[I]) = '' then
      Continue;
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + Trim(Parts[I]);
  end;
end;

function TCors.AllowMethods(const Methods: array of string): TCors;
begin
  Result := Self;
  FMethods := Join(Methods);
end;

function TCors.AllowHeaders(const Headers: array of string): TCors;
begin
  Result := Self;
  FHeaders := Join(Headers);
end;

function TCors.ExposeHeaders(const Headers: array of string): TCors;
begin
  Result := Self;
  FExpose := Join(Headers);
end;

function TCors.MaxAge(Seconds: Integer): TCors;
begin
  Result := Self;
  if Seconds < 0 then
    Seconds := 0;
  FMaxAge := Seconds;
end;

function TCors.HasPolicy: Boolean;
begin
  Result := FAny or (Length(FOrigins) > 0);
end;

function TCors.Allowed(const Origin: string): Boolean;
var
  I: Integer;
begin
  if Origin = '' then
    Exit(False);
  if FAny then
    Exit(True);
  { Exactly, and case sensitively for everything after the scheme. An
    origin is not a URL to be normalised; it is the string the browser
    sends, and anything cleverer here is somewhere for
    https://example.com.evil.example to get in. }
  for I := 0 to High(FOrigins) do
    if FOrigins[I] = Origin then
      Exit(True);
  Result := False;
end;

function TCors.OriginFor(Req: TRequest): string;
var
  O: string;
begin
  Result := '';
  if (Req = nil) or not HasPolicy then
    Exit;
  O := Trim(Req.Header('origin').ToString);
  if not Allowed(O) then
    Exit;
  { '*' when any origin is allowed, and the origin itself otherwise.

    There is no case here for "any origin, with credentials": a browser
    refuses that pair, so AllowAnyOrigin and AllowCredentials refuse each
    other at configuration time. Guarding for it again here would be code
    for a state that cannot be reached, which reads as if it could. }
  if FAny then
    Result := '*'
  else
    Result := O;
end;

{ ---------------------------------------------------------- middleware -- }

type
  TCorsHook = class
    class function Handle(Req: TRequest): TResponse;
    class function Decorate(Req: TRequest; Res: TResponse): TResponse;
  end;

procedure AddHeaders(C: TCors; Res: TResponse; const Origin: string);
begin
  Res.WithHeader('Access-Control-Allow-Origin', Origin);
  if C.FCredentials then
    Res.WithHeader('Access-Control-Allow-Credentials', 'true');
  if C.FExpose <> '' then
    Res.WithHeader('Access-Control-Expose-Headers', C.FExpose);
end;

{ Vary: Origin on every reply that could have carried a CORS header,
  including the ones where the origin was not allowed and no header was
  written.

  A cache in front of this sees one reply and serves it to everybody. The
  same URL answers differently depending on who asked, so without Vary an
  intermediary hands a page from one origin the headers meant for
  another -- or, just as bad, hands a browser a cached reply with no CORS
  headers on it at all and the page silently cannot read it. The same
  mistake as Vary: X-Inertia, and it shows up the same way: only behind
  a cache, and only sometimes. }
procedure AddVary(Res: TResponse);
var
  Have: string;
begin
  Have := Res.HeaderValue('Vary');
  if Have = '' then
    Res.WithHeader('Vary', 'Origin')
  else if Pos('Origin', Have) = 0 then
    Res.WithHeader('Vary', Have + ', Origin');
end;

class function TCorsHook.Handle(Req: TRequest): TResponse;
var
  C: TCors;
  Origin: string;
begin
  Result := nil;
  C := Cors;
  if not C.HasPolicy then
    Exit;

  { A preflight is an OPTIONS carrying Access-Control-Request-Method. An
    OPTIONS without it is an ordinary request and belongs to the
    application. }
  if (Req.Method = hmOptions) and
     (Req.Header('access-control-request-method').Len > 0) then
  begin
    Origin := C.OriginFor(Req);
    { 204 either way. A preflight from an origin that is not allowed gets
      no CORS headers, and the browser stops there -- which is the answer.
      Refusing with a 403 would say the same thing less clearly and would
      tell a script which origins are on the list. }
    Result := Respond(204);
    { Only the headers a preflight adds. Vary, the origin and the
      credentials flag come from the after-filter, which runs on this
      reply too: a filter runs even when middleware short-circuited, and
      that is the whole reason it does. Writing them here as well would
      be a second copy of the rule for a cache to get wrong. }
    if Origin <> '' then
    begin
      Result.WithHeader('Access-Control-Allow-Methods', C.FMethods);
      if C.FHeaders <> '' then
        Result.WithHeader('Access-Control-Allow-Headers', C.FHeaders);
      Result.WithHeader('Access-Control-Max-Age', IntToStr(C.FMaxAge));
    end;
    Exit;
  end;
end;

class function TCorsHook.Decorate(Req: TRequest; Res: TResponse): TResponse;
var
  C: TCors;
  Origin: string;
begin
  Result := Res;
  C := Cors;
  if (Res = nil) or not C.HasPolicy then
    Exit;
  AddVary(Res);
  Origin := C.OriginFor(Req);
  if Origin <> '' then
    AddHeaders(C, Res, Origin);
end;

procedure UseCors(R: TRouter);
begin
  R.Use(TCorsHook.Handle);
  { An after-filter, so the headers are on every reply -- including a 401
    from a guard and a 500 from a handler. A page that cannot read the
    error is a page whose developer has no idea what went wrong. }
  R.After(TCorsHook.Decorate);
end;

end.
