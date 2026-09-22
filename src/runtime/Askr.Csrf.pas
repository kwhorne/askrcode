{ Askr.Csrf — protection against cross-site request forgery.

  The attack: a page on another domain makes your browser send a POST to
  this app. The browser attaches the session cookie all by itself, because
  that is what cookies do, and the server sees a perfectly legitimate
  request from a signed-in user. Without a countermeasure, every form in
  the app is an endpoint anybody can call on the user's behalf.

  The countermeasure is a secret that lives in the **session** and has to
  be sent along in the **request**. Another domain can make the browser
  send the cookie, but it cannot read your session and therefore cannot
  guess the token.

  The token is accepted in three places, in this order:

    1. the form field `_token`      — ordinary HTML forms
    2. the header `X-CSRF-Token`    — fetch/XHR that adds it itself
    3. the header `X-XSRF-Token`    — axios and Inertia, which read the
                                      `XSRF-TOKEN` cookie and mirror it here

  The third is why `UseCsrf` also sets an `XSRF-TOKEN` cookie that
  JavaScript is allowed to read. That is safe: that cookie is not what
  authenticates anyone — the session cookie is still HttpOnly — and its
  value is compared against the one in the session, which another domain
  cannot reach.

  GET, HEAD and OPTIONS are not checked. By definition they change
  nothing, and an app that changes state in a GET has a bigger problem
  than CSRF. }
unit Askr.Csrf;

{$mode Delphi}{$H+}

interface

uses
  SysUtils,
  Askr.Core.Text, Askr.Core.Crypto,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response, Askr.Http.Router,
  Askr.Session, Askr.Auth;

const
  { The key the token lives under in the session. The underscore marks it
    as the framework's, not the app's. }
  CsrfSessionKey = '_csrf';
  { The field a form sends it in. The same name Laravel uses, because
    that is what people already have in their fingers. }
  CsrfFieldName = '_token';
  CsrfHeaderName = 'X-CSRF-Token';
  CsrfCookieName = 'XSRF-TOKEN';

  { 419 Page Expired is in no RFC — it is Laravel's, and the Inertia
    client recognises it and reloads the page rather than showing an
    error. That is the right behaviour: an expired token usually means the
    user has had the tab open too long, not that somebody is attacking
    them. A plain 403 would be a dead end. }
  CsrfFailStatus = 419;

{ The token for this request's session. Created the first time it is
  asked for and then kept in the session. Raises if there is no session —
  a CSRF token with no session to bind it to protects nothing, and
  returning an empty string would make that mistake invisible. }
function CsrfToken: string;

{ Hidden felt til et HTML-skjema. Skrives rett inn i markupen:

  <form method="post">
    <%= CsrfField %>
    ... }
function CsrfField: string;

{ Checks a request without answering it. For code that wants to make the
  decision itself. `UseCsrf` uses it. }
function CsrfValid(Req: TRequest): Boolean;

{ True for the methods that are checked. GET, HEAD and OPTIONS are
  exempt. }
function CsrfMethodNeedsCheck(M: THttpMethod): Boolean;

{ Exempt a path from the check. For webhooks, which come from a third
  party that cannot possibly have the token, and which have to be
  authenticated another way — a signature in a header. The pattern matches
  either exactly or with a trailing `*`: `/webhooks/*`.

  This is a hole you make on purpose, and that is why it has to be written
  down. }
procedure CsrfExempt(const PathPattern: string);
function CsrfIsExempt(const Path: TStr): Boolean;

{ Wires the protection onto the router: a middleware that refuses a
  request without a valid token, and an after-filter that sets the
  XSRF-TOKEN cookie.

  Requires the sessions to be wired up first — CSRF without a session is
  meaningless, and `UseCsrf` says so immediately rather than letting every
  request through. }
procedure UseCsrf(R: TRouter);

implementation

var
  GExempt: array of string;

function CsrfMethodNeedsCheck(M: THttpMethod): Boolean;
begin
  Result := M in [hmPost, hmPut, hmPatch, hmDelete];
end;

procedure CsrfExempt(const PathPattern: string);
begin
  SetLength(GExempt, Length(GExempt) + 1);
  GExempt[High(GExempt)] := PathPattern;
end;

function CsrfIsExempt(const Path: TStr): Boolean;
var
  I: Integer;
  P, M: string;
begin
  P := Path.ToString;
  for I := 0 to High(GExempt) do
  begin
    M := GExempt[I];
    if (M <> '') and (M[Length(M)] = '*') then
    begin
      if Copy(P, 1, Length(M) - 1) = Copy(M, 1, Length(M) - 1) then
        Exit(True);
    end
    else if P = M then
      Exit(True);
  end;
  Result := False;
end;

function CsrfToken: string;
var
  S: TSession;
begin
  S := CurrentSession;
  if S = nil then
    raise ESessionError.Create(
      'CSRF needs a session. Call UseSessions before UseCsrf, or ' +
      'SetSessions and UseSession if you wire the request yourself.');
  Result := S.Get(CsrfSessionKey);
  if Result = '' then
  begin
    { 32 bytes from the kernel's CSPRNG, base64url. A token that can be
      guessed is not a token. }
    Result := RandomToken(32);
    S.Put(CsrfSessionKey, Result);
  end;
end;

{ The token is base64url and by construction contains nothing that needs
  escaping. It is escaped anyway: the day somebody changes the encoding, a
  form field must not become a hole. }
function AttrEscape(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    case S[I] of
      '&': Result := Result + '&amp;';
      '<': Result := Result + '&lt;';
      '>': Result := Result + '&gt;';
      '"': Result := Result + '&quot;';
      '''': Result := Result + '&#39;';
    else
      Result := Result + S[I];
    end;
end;

function CsrfField: string;
begin
  Result := '<input type="hidden" name="' + CsrfFieldName + '" value="' +
    AttrEscape(CsrfToken) + '">';
end;

{ Looks for the token wherever the client may have put it. None of the
  places is authoritative on its own — it is the comparison against the
  session that decides. }
function TokenFromRequest(Req: TRequest): string;
var
  V: TStr;
begin
  V := Req.Form(CsrfFieldName);
  if not V.IsEmpty then
    Exit(V.ToString);
  V := Req.Header(CsrfHeaderName);
  if not V.IsEmpty then
    Exit(V.ToString);
  { axios and Inertia read the XSRF-TOKEN cookie and send it back
    here. }
  V := Req.Header('X-XSRF-Token');
  if not V.IsEmpty then
    Exit(V.ToString);
  Result := '';
end;

function CsrfValid(Req: TRequest): Boolean;
var
  S: TSession;
  Expected, Got: string;
begin
  if not CsrfMethodNeedsCheck(Req.Method) then
    Exit(True);
  if CsrfIsExempt(Req.Path) then
    Exit(True);

  { A request that authenticated with a credential it carried itself --
    an API token in a header -- is not what CSRF defends against.

    The whole attack is a browser being made to send a request it did not
    mean to, with the cookie it carries everywhere. An Authorization
    header is not carried everywhere: no other site can set one on a
    request to us, which is exactly why the header exists. Requiring a
    CSRF token as well would ask an API client for something it has no
    way to obtain, and every POST with a valid token would be a 419.

    This is why UseTokenAuth has to be registered before UseCsrf. The
    other way round, CSRF answers before the token is read and the
    exemption never applies. }
  if IsRequestIdentity then
    Exit(True);

  S := CurrentSession;
  if S = nil then
    Exit(False);

  Expected := S.Get(CsrfSessionKey);
  { No token in the session means the user has never been given a form by
    us. Then there is nothing to compare against, and the answer is
    no. }
  if Expected = '' then
    Exit(False);

  Got := TokenFromRequest(Req);
  if Got = '' then
    Exit(False);

  { Constant time. An ordinary `=` stops at the first differing
    character, and the time it takes leaks how far a guess got. }
  Result := ConstantTimeEquals(Expected, Got);
end;

type
  { The middleware and the filter are function pointers. Pascal has no
    closures, so the state — none, here — would have had to be global
    anyway; a class with class methods is the shape the rest of Askr
    uses. }
  TCsrfGuard = class
    class function Check(Req: TRequest): TResponse;
    class function SetCookie(Req: TRequest; Res: TResponse): TResponse;
  end;

class function TCsrfGuard.Check(Req: TRequest): TResponse;
begin
  if CsrfValid(Req) then
    Exit(nil);
  { The message says what is wrong without revealing what was expected.
    "Token mismatch" with the correct token in the text has been a real
    vulnerability in other frameworks. }
  Result := ErrorResponse(CsrfFailStatus, 'CSRF token missing or invalid.');
end;

class function TCsrfGuard.SetCookie(Req: TRequest; Res: TResponse): TResponse;
var
  S: TSession;
  Token: string;
begin
  Result := Res;
  S := CurrentSession;
  if S = nil then
    Exit;
  Token := S.Get(CsrfSessionKey);
  { The cookie is set only when the token already exists. Creating one
    here would give every single request — static files and health checks
    included — a write to the session, and so a session per anonymous
    visitor. }
  if Token = '' then
    Exit;
  { ReadableByJs: this is the one cookie the frontend is meant to read. It
    is not what authenticates anyone. }
  Res.WithCookie(CsrfCookieName, Token, Sessions.Lifetime,
    Sessions.Secure, True);
end;

procedure UseCsrf(R: TRouter);
begin
  { Sessions raises by itself if no store is set, and the message there
    says what needs saying. The call is here so the error comes at startup
    and not at the first POST. }
  Sessions;
  R.Use(TCsrfGuard.Check);
  R.After(TCsrfGuard.SetCookie);
end;

end.
