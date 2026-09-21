{ Askr.Auth — who is this, and are they allowed?

  Two things that often get conflated:

    * **Authentication** is knowing who somebody is. It lives in the
      session.
    * **Authorisation** is deciding whether they may. It lives in gates.

  Askr does not own your user model. The framework stores one thing — the
  user's id, as text — and lets the app look up the rest itself through a
  loader it registers. That is deliberate: a `TUser` from the framework
  would force a particular schema, a particular table and a particular set
  of columns, and the first thing any real app does is need one more
  column.

  Passwords live in `Askr.Core.Crypto`. This unit never sees a password;
  the app verifies it itself and calls `Login` with an id.

      if VerifyPassword(Req.Form('password').ToString, User.PasswordHash) then
        Login(IntToStr(User.Id));

  It sounds like a detour, but it is the one order that cannot go wrong:
  the framework cannot know which column the hash is in, and an API that
  guessed at that would have to guess at how the user is looked up as
  well. }
unit Askr.Auth;

{$mode Delphi}{$H+}

interface

uses
  SysUtils,
  Askr.Core.Text, Askr.Core.Clock, Askr.Core.Crypto,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response, Askr.Http.Router,
  Askr.Session;

type
  EAuthError = class(Exception);
  { Raised by `Authorize`. The host translates it into a 403. }
  EForbidden = class(EAuthError);

  { The app's lookup from id to user object. Called at most once per
    request; the result is cached for that request. Return nil when the id
    no longer exists — a deleted user with a valid session cookie should
    be signed out, not given an error. }
  TUserLoader = function(const Id: string): TObject;

  { A gate: is this user allowed to do this, to this thing? `Resource` is
    nil for gates that are not about a particular object ("admin",
    "view-dashboard"). }
  TGateFunc = function(const UserId: string; Resource: TObject): Boolean;

const
  { The key the user's id lives under in the session. }
  AuthSessionKey = '_user';
  { The "remember me" cookie. Its own cookie, not the session cookie: it
    has to survive the session expiring, and that is the whole point of
    it. }
  RememberCookieName = 'askr_remember';
  { 30 dager. Lenger enn det er en kake folk har glemt at de har. }
  RememberLifetime = 30 * 24 * 60 * 60;

{ --------------------------------------------------------- innlogging -- }

{ Signs in. The id is the app's own — a primary key as text, a uuid,
  anything at all, as long as the loader understands it.

  The session id is replaced here. Without that, an attacker who managed
  to set your cookie beforehand would be signed in as you afterwards. }
procedure Login(const UserId: string; Remember: Boolean = False);
{ Signs out: clears the session entirely and deletes the "remember me"
  cookie. The whole session, not only the user key — whatever was in there
  belonged to whoever was signed in. }
procedure Logout;

function Check: Boolean;
{ Id-en, eller tom streng. }
function Id: string;
{ The user object from the loader, or nil. Looks up at most once per
  request. }
function User: TObject;

{ The app's lookup. Set once at startup. Without it, Login, Check and Id
  still work — only User does not. }
procedure SetUserLoader(L: TUserLoader);

{ ------------------------------------------------------- autorisasjon -- }

{ Defines a gate. The same name twice replaces the previous one, so an
  app can override a gate from a library. }
procedure DefineGate(const Name: string; F: TGateFunc);
{ Is the signed-in user allowed? False when nobody is signed in, and
  False for a gate that does not exist — a typo in a gate name should shut
  the door, not open it. }
function Allows(const Name: string; Resource: TObject = nil): Boolean;
function Denies(const Name: string; Resource: TObject = nil): Boolean;
{ The same, but raises EForbidden. For code that must not carry on. }
procedure Authorize(const Name: string; Resource: TObject = nil);
function GateExists(const Name: string): Boolean;

{ ---------------------------------------------------------- middleware -- }

{ Restores the sign-in from the "remember me" cookie when the session is
  empty. Has to come after UseSessions. Without it "remember me" does not
  work — the cookie simply sits there and is ignored. }
procedure UseAuth(R: TRouter);

{ Closes everything behind a sign-in from here on. An ordinary request
  is sent to `LoginPath`; an Inertia or JSON request gets a 401, because a
  302 to an HTML page is useless to a client expecting JSON. }
procedure RequireAuth(R: TRouter; const LoginPath: string = '/login');

implementation

var
  GLoader: TUserLoader;
  GGates: array of record
    Name: string;
    Func: TGateFunc;
  end;
  { The loader is called at most once per request. The cache is
    thread-local, like the rest of the request state in Askr. }

threadvar
  GUser: TObject;
  GUserFor: string;

{ --------------------------------------------------------- innlogging -- }

procedure SetUserLoader(L: TUserLoader);
begin
  GLoader := L;
end;

function RequiresSession: TSession;
begin
  Result := CurrentSession;
  if Result = nil then
    raise EAuthError.Create(
      'Authentication needs a session. Call SetSessions and UseSessions ' +
      'before UseAuth.');
end;

{ What is in the "remember me" cookie: an id and an expiry, signed with
  the app key. The value is **readable** — the signature only proves we
  made it. That is fine: a user id is not a secret, and the cookie alone
  grants nothing unless the signature checks out.

  The cookie cannot be revoked individually. For that, the token would
  have to be stored per user in the database, and that needs a column the
  framework cannot know about. It is a real limitation, and it is written
  here rather than being discovered. }
function RememberValue(const UserId: string): string;
begin
  Result := Sign(UserId + '|' + IntToStr(UnixNow + RememberLifetime));
end;

function ReadRemember(const Cookie_: string; out UserId: string): Boolean;
var
  Payload, ExpiryStr: string;
  P: Integer;
  Expiry: Int64;
begin
  UserId := '';
  if Cookie_ = '' then
    Exit(False);
  if not Unsign(Cookie_, Payload) then
    Exit(False);
  P := Pos('|', Payload);
  if P <= 1 then
    Exit(False);
  ExpiryStr := Copy(Payload, P + 1, MaxInt);
  if not TryStrToInt64(ExpiryStr, Expiry) then
    Exit(False);
  { The expiry is inside the signed part, not only in the cookie's
    Max-Age. A client that keeps the cookie longer than we asked must not
    get in. }
  if UnixNow > Expiry then
    Exit(False);
  UserId := Copy(Payload, 1, P - 1);
  Result := UserId <> '';
end;

{ The cookie is set and deleted on the response, and the response only
  exists after the handler has run. The intent is therefore parked
  thread-locally and carried out by the after-filter. }
threadvar
  GSetRemember: string;
  GClearRemember: Boolean;

procedure Login(const UserId: string; Remember: Boolean);
var
  S: TSession;
begin
  if UserId = '' then
    raise EAuthError.Create('Login needs a user id.');
  S := RequiresSession;
  { A new session id the moment the privileges change. This is the whole
    defence against session fixation, and it is one line. }
  Sessions.Regenerate(S);
  S.Put(AuthSessionKey, UserId);
  GUser := nil;
  GUserFor := '';
  if Remember then
    GSetRemember := RememberValue(UserId);
end;

procedure Logout;
var
  S: TSession;
begin
  S := CurrentSession;
  if S <> nil then
  begin
    { The whole session, not only the user key: a shopping cart or a
      half-filled form belonged to whoever was signed in. }
    S.Clear;
    Sessions.Regenerate(S);
  end;
  GUser := nil;
  GUserFor := '';
  GSetRemember := '';
  GClearRemember := True;
end;

function Id: string;
var
  S: TSession;
begin
  S := CurrentSession;
  if S = nil then
    Exit('');
  Result := S.Get(AuthSessionKey);
end;

function Check: Boolean;
begin
  Result := Id <> '';
end;

function User: TObject;
var
  Uid: string;
begin
  Uid := Id;
  if Uid = '' then
  begin
    GUser := nil;
    GUserFor := '';
    Exit(nil);
  end;
  if (GUserFor = Uid) and (GUser <> nil) then
    Exit(GUser);
  if not Assigned(GLoader) then
    raise EAuthError.Create(
      'No user loader is registered. Call SetUserLoader at startup, or ' +
      'use Id instead of User.');
  GUser := GLoader(Uid);
  GUserFor := Uid;
  Result := GUser;
end;

{ ------------------------------------------------------- autorisasjon -- }

function GateIndex(const Name: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(GGates) do
    if SameText(GGates[I].Name, Name) then
      Exit(I);
  Result := -1;
end;

procedure DefineGate(const Name: string; F: TGateFunc);
var
  I: Integer;
begin
  if Name = '' then
    raise EAuthError.Create('A gate needs a name.');
  I := GateIndex(Name);
  if I < 0 then
  begin
    SetLength(GGates, Length(GGates) + 1);
    I := High(GGates);
    GGates[I].Name := Name;
  end;
  GGates[I].Func := F;
end;

function GateExists(const Name: string): Boolean;
begin
  Result := GateIndex(Name) >= 0;
end;

function Allows(const Name: string; Resource: TObject): Boolean;
var
  I: Integer;
  Uid: string;
begin
  Uid := Id;
  if Uid = '' then
    Exit(False);
  I := GateIndex(Name);
  { A gate that does not exist says no. The opposite would turn a typo in
    a gate name into an open door, and that mistake looks like everything
    working. }
  if I < 0 then
    Exit(False);
  Result := GGates[I].Func(Uid, Resource);
end;

function Denies(const Name: string; Resource: TObject): Boolean;
begin
  Result := not Allows(Name, Resource);
end;

procedure Authorize(const Name: string; Resource: TObject);
begin
  if not Allows(Name, Resource) then
    { The message names the gate, not the user or the resource. It ends up
      in a log, and a 403 should not tell anybody what they nearly
      got. }
    raise EForbidden.CreateFmt('Not authorized: %s', [Name]);
end;

{ ---------------------------------------------------------- middleware -- }

type
  TAuthHook = class
    class function Restore(Req: TRequest): TResponse;
    class function WriteCookies(Req: TRequest; Res: TResponse): TResponse;
    class function Require(Req: TRequest): TResponse;
  end;

var
  GLoginPath: string = '/login';

class function TAuthHook.Restore(Req: TRequest): TResponse;
var
  S: TSession;
  Uid: string;
begin
  Result := nil;
  GSetRemember := '';
  GClearRemember := False;
  GUser := nil;
  GUserFor := '';

  S := CurrentSession;
  if S = nil then
    Exit;
  { The cookie is only used when the session is empty. A signed-in
    session always wins — otherwise an old cookie could override a newer
    sign-in. }
  if S.Get(AuthSessionKey) <> '' then
    Exit;

  if not HasAppKey then
    Exit;
  if not ReadRemember(CookieValue(Req, RememberCookieName), Uid) then
    Exit;

  { A new session id here too: this is a sign-in, just without a
    form. }
  Sessions.Regenerate(S);
  S.Put(AuthSessionKey, Uid);
  { The cookie is renewed, so a user who keeps dropping in is not
    suddenly thrown out on day 30. }
  GSetRemember := RememberValue(Uid);
end;

class function TAuthHook.WriteCookies(Req: TRequest; Res: TResponse): TResponse;
begin
  Result := Res;
  if GClearRemember then
    { Max-Age=0 is how a cookie is deleted. The value is set empty as well,
      for a client that keeps it anyway. }
    Res.WithCookie(RememberCookieName, '', 0, Sessions.Secure)
  else if GSetRemember <> '' then
    Res.WithCookie(RememberCookieName, GSetRemember, RememberLifetime,
      Sessions.Secure);
  GSetRemember := '';
  GClearRemember := False;
end;

class function TAuthHook.Require(Req: TRequest): TResponse;
begin
  if Check then
    Exit(nil);
  { An Inertia or JSON client has no use for a 302 to an HTML page: it
    would follow it and get the sign-in page as JSON. A 401 is what the
    client can do something with. }
  if (Req.Header('X-Inertia').Len > 0) or
     (Pos('application/json', Req.Header('Accept').ToString) > 0) then
    Exit(RespondText('Unauthenticated.', 401));
  Result := Redirect(GLoginPath, 302);
end;

procedure UseAuth(R: TRouter);
begin
  Sessions;
  R.Use(TAuthHook.Restore);
  R.After(TAuthHook.WriteCookies);
end;

procedure RequireAuth(R: TRouter; const LoginPath: string);
begin
  GLoginPath := LoginPath;
  R.Use(TAuthHook.Require);
end;

end.
