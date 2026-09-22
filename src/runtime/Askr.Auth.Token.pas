{ Askr.Auth.Token — API tokens: a credential a program can hold.

  A session is a browser mechanism. It needs a cookie, the cookie needs a
  CSRF token beside it, and the whole arrangement assumes something that
  stores cookies and follows redirects. A program has none of that, and
  giving it a session would mean giving it every weakness of one.

  So: a bearer token, in the header the standard names for it.

      Authorization: Bearer askr_kZ3n...

  The token resolves to a user id and `LoginForRequest` makes it this
  request's identity. From there `Check`, `Id`, `User` and every gate work
  exactly as they do for a browser -- an application does not write its
  authorisation twice.

  WHAT IS STORED, AND WHAT IS NOT

  **The token itself is never stored.** The row holds `sha256(token)` as
  hex, and the plaintext is returned once, by `IssueToken`, and never
  again. A database that leaks gives an attacker no usable credential;
  the gate for this is a sweep of the database file for the token that
  was just issued.

  **The hash is a bare SHA-256, with no salt and no key, and that is a
  decision.** A salt defends a low-entropy secret against a precomputed
  table. This secret is 32 bytes from the system CSPRNG -- there is no
  table to precompute and no dictionary to try, so a salt would buy
  nothing and would cost the thing that matters: the lookup being one
  indexed equality instead of a scan. An HMAC under APP_KEY was
  considered and rejected for a different reason -- rotating APP_KEY is
  something operators are told they may do, and it already signs everyone
  out; making it also kill every API token silently widens that blast
  radius.

  **There is no stored prefix column.** The usual argument for one is
  matching a token found in a log or a public repository back to a row --
  but hashing the string you found and looking it up does that exactly,
  with no part of any secret kept. What a prefix would otherwise buy is
  telling two tokens apart in a list, and `name` already does that. So
  nothing here holds a fragment of a live credential.

  `askr_` is on the front of every token so that a secret scanner has
  something to key on, and so that a token in a paste is recognisable for
  what it is. It is fixed framework-wide: a per-application prefix would
  mean no scanner rule could cover Askr at all.

  NEVER FROM THE QUERY STRING

  There is no code here that reads a token from the URL, and there is a
  test that says so. A query string goes into access logs, into `Referer`
  on every outbound link, into browser history and into the URL somebody
  pastes into a chat. Every one of those is a place a credential is then
  kept by someone who never agreed to keep it. It is the convenience that
  cannot be added safely later, which is why the absence is guarded. }
unit Askr.Auth.Token;

{$mode Delphi}{$H+}

interface

uses
  SysUtils,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Clock, Askr.Core.Crypto,
  Askr.Core.Log,
  Askr.Http.Request, Askr.Http.Response, Askr.Http.Router,
  Askr.Urd.Driver, Askr.Norn.Schema, Askr.Norn.Introspect,
  Askr.Auth;

type
  ETokenError = class(EAuthError);

  { Why a token cannot be used. Known to the server, never to the client:
    telling a caller that a token is *revoked* rather than unknown tells
    them the token existed. }
  TTokenState = (tsNone, tsActive, tsRevoked, tsExpired);

  TApiToken = record
    Id: Int64;
    UserId: string;
    Name_: string;
    { Space separated. '*' means everything. Empty means nothing, which
      is why IssueToken with no scopes gives a token that fails every
      scope check rather than a master key. }
    Scopes: string;
    CreatedAt: Int64;     { unix ms }
    LastUsedAt: Int64;    { 0 = never used }
    ExpiresAt: Int64;     { 0 = never expires }
    RevokedAt: Int64;     { 0 = live }
    State: TTokenState;
  end;

  TApiTokens = array of TApiToken;

const
  { Fixed for every Askr application. See the header. }
  TokenPrefix = 'askr_';
  { 32 bytes of CSPRNG output, base64url, unpadded: 43 characters after
    the prefix. }
  TokenBytes = 32;
  DefaultTokenTable = 'api_tokens';
  { last_used_at is written at most this often per token. Without the
    guard every authenticated request is also a write. }
  TokenTouchMs = 60 * 1000;

var
  { Change before EnsureTokenSchema if the name collides with something
    the application already has. }
  TokenTable: string = DefaultTokenTable;

{ ------------------------------------------------------------- skjema -- }

{ Creates the table if it is not there. Asks the introspection first, for
  the same reason the durable queue does: CREATE INDEX IF NOT EXISTS does
  not exist in MySQL. }
procedure EnsureTokenSchema(Db: TDbConnection);

{ ------------------------------------------------------------ tokens -- }

{ Issues a token for a user id -- the application's own id, as text, the
  same one Login takes.

  **The return value is the only time the token exists in readable form.**
  Show it once and store nothing; there is no way to get it back, by
  design.

  Scopes are exact strings. `['*']` is everything. `[]` is nothing, and a
  token with no scopes fails every scope check -- a caller who meant
  "everything" and wrote `[]` finds out immediately rather than getting a
  master key by accident. }
function IssueToken(Db: TDbConnection; const UserId, Name_: string;
  const Scopes: array of string; ExpiresInSeconds: Int64 = 0): string;

{ Looks a plaintext token up. True only for a token that can be used now.

  T is filled in either way when the row exists, so the server can say
  why in its log. Do not put the reason in a reply: an attacker learns
  from "revoked" that the token was real. }
function FindToken(Db: TDbConnection; const Plain: string;
  out T: TApiToken): Boolean;

{ Records that the token was used, at most once per TokenTouchMs. One
  conditional UPDATE, so two workers cannot race each other into two
  writes. }
procedure TouchToken(Db: TDbConnection; TokenId: Int64);

{ True when this call is what revoked it. False when there is no such
  token, or it was already revoked -- the caller can then say so instead
  of reporting a success that did not happen. }
function RevokeToken(Db: TDbConnection; TokenId: Int64): Boolean;
{ Every token belonging to one user. What "sign out everywhere" means for
  a program. }
function RevokeTokensFor(Db: TDbConnection; const UserId: string): Integer;
{ For a list a human reads. Never returns anything secret. }
function TokensFor(Db: TDbConnection; const UserId: string): TApiTokens;

{ --------------------------------------------------------- middleware -- }

{ Reads `Authorization: Bearer` and signs the request in when it names a
  usable token. Needs an ambient database connection, as models do.

  **A token that is present and not usable is a 401, not an anonymous
  request.** A caller who offered a credential and was quietly treated as
  nobody would see the failure later, somewhere else, as a 403 or a 404.

  Register it after UseSessions and **before UseCsrf**: a request that
  authenticated with a header it carried itself is not what CSRF defends
  against, and that exemption is only visible once the token has been
  read.

  The table is created by `askr token:issue`, not here and not at
  startup. An application has to start whether or not its database is up,
  and a DDL on boot would make that untrue. }
procedure UseTokenAuth(R: TRouter);

{ The token this request came in with. State is tsNone when it did not
  come in with one. }
function CurrentToken: TApiToken;
function HasToken: Boolean;

{ Is this request allowed to do that?

  Three answers, and the middle one is the one to read twice:

    * Nobody signed in -- no.
    * Signed in by session -- **yes**. A session is not scoped; scopes are
      a property of a token, and asking a browser session about one is
      asking a question that has no answer. A handler that must also keep
      browsers out needs RequireAuth or a gate, which is where that
      decision belongs.
    * Signed in by token -- the token's scopes decide. }
function TokenAllows(const Scope: string): Boolean;
{ The same, but raises EForbidden. }
procedure AuthorizeScope(const Scope: string);

{ The bearer token on this request, or an empty string. Exposed because a
  handler may want to see whether one was offered at all. }
function BearerToken(Req: TRequest): string;

implementation

uses
  Askr.Urd.Model;   { CurrentDb }

threadvar
  GToken: TApiToken;

{ ------------------------------------------------------------ hjelpere -- }

function Ph(C: TDbConnection; A: TArena; Index: Integer): string;
var
  B: TStrBuilder;
begin
  B.Init(A, 8);
  C.AppendPlaceholder(B, Index);
  Result := B.ToString;
end;

function Quoted(C: TDbConnection; A: TArena; const Name_: string): string;
var
  B: TStrBuilder;
begin
  B.Init(A, Length(Name_) + 4);
  C.AppendIdentStr(B, Name_);
  Result := B.ToString;
end;

procedure NeedDb(Db: TDbConnection);
begin
  if Db = nil then
    raise ETokenError.Create(
      'API tokens need a database connection. Pass one, or set an ' +
      'ambient connection with UseDb -- a generated app leases one per ' +
      'request in its middleware.');
end;

procedure ClearToken(var T: TApiToken);
begin
  T.Id := 0;
  T.UserId := '';
  T.Name_ := '';
  T.Scopes := '';
  T.CreatedAt := 0;
  T.LastUsedAt := 0;
  T.ExpiresAt := 0;
  T.RevokedAt := 0;
  T.State := tsNone;
end;

{ ------------------------------------------------------------- skjema -- }

procedure EnsureTokenSchema(Db: TDbConnection);
var
  S: TSchemaBuilder;
  T: TTableBuilder;
  Statements: TStringArray;
  I: Integer;
  A: TArena;
  Schema_: TDbSchema;
  Exists_: Boolean;
begin
  NeedDb(Db);
  A := TArena.Create(64 * 1024);
  try
    Schema_ := IntrospectSchema(Db);
    try
      Exists_ := Schema_.Table(TokenTable) <> nil;
    finally
      Schema_.Free;
    end;
    if Exists_ then
      Exit;

    S := TSchemaBuilder.Create(Db.Dialect);
    try
      T := S.Create(TokenTable);
      T.IfNotExists := True;
      T.Id;
      { Text, not an integer foreign key: the framework does not own the
        user model, so it cannot know that ids are numbers or which table
        they live in. The session stores the id the same way. }
      T.Text('user_id', 64);
      T.Text('name', 128);
      { Hex SHA-256: 64 characters, always. }
      T.Text('token_hash', 64);
      T.Text('scopes');
      { Unix milliseconds, not TIMESTAMP -- the same reason as the durable
        queue: several processes share the table and an integer means the
        same thing whatever time zone each server believes it is in. }
      T.BigInt('created_at');
      T.BigInt('last_used_at').Nullable;
      T.BigInt('expires_at').Nullable;
      T.BigInt('revoked_at').Nullable;
      { The lookup path and the uniqueness constraint in one. Every
        authenticated request is this index. }
      T.UniqueIndex(['token_hash']);
      { Listing and revoking everything for one user. }
      T.Index(['user_id']);
      Statements := S.ToSql;
    finally
      S.Free;
    end;

    for I := 0 to High(Statements) do
      Db.Exec(A, Statements[I]);
  finally
    A.Free;
  end;
end;

{ ------------------------------------------------------------ tokens -- }

function JoinScopes(const Scopes: array of string): string;
var
  I: Integer;
  S: string;
begin
  Result := '';
  for I := 0 to High(Scopes) do
  begin
    S := Trim(Scopes[I]);
    if S = '' then
      Continue;
    { A space is the separator, so it cannot be inside a scope. Rejecting
      it is better than storing a scope that can never be matched. }
    if Pos(' ', S) > 0 then
      raise ETokenError.CreateFmt(
        'A scope cannot contain a space: "%s". Scopes are separated by ' +
        'spaces; use a colon for structure, as in "orders:write".', [S]);
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + S;
  end;
end;

function IssueToken(Db: TDbConnection; const UserId, Name_: string;
  const Scopes: array of string; ExpiresInSeconds: Int64): string;
var
  A: TArena;
  Sql, Plain, ScopeText: string;
  Now_, Expires: Int64;
begin
  NeedDb(Db);
  if Trim(UserId) = '' then
    raise ETokenError.Create('A token needs a user id.');
  if Trim(Name_) = '' then
    raise ETokenError.Create(
      'A token needs a name. It is the only thing that tells two of them ' +
      'apart in a list, because nothing about the token itself is kept.');

  ScopeText := JoinScopes(Scopes);
  Plain := TokenPrefix + Base64UrlEncode(RandomBytes(TokenBytes));
  Now_ := UnixNowMs;
  if ExpiresInSeconds > 0 then
    Expires := Now_ + ExpiresInSeconds * 1000
  else
    Expires := 0;

  A := TArena.Create(8 * 1024);
  try
    Sql := 'INSERT INTO ' + Quoted(Db, A, TokenTable) +
      ' (user_id, name, token_hash, scopes, created_at, expires_at)' +
      ' VALUES (' + Ph(Db, A, 1) + ', ' + Ph(Db, A, 2) + ', ' +
      Ph(Db, A, 3) + ', ' + Ph(Db, A, 4) + ', ' + Ph(Db, A, 5) + ', ' +
      Ph(Db, A, 6) + ')';
    { Sha256Hex of the whole token, prefix included. There is nowhere
      else the plaintext goes. }
    Db.ExecParams(A, Sql, [
      DbParam(A, UserId),
      DbParam(A, Name_),
      DbParam(A, Sha256Hex(Plain)),
      DbParam(A, ScopeText),
      DbParam(A, Now_),
      DbParam(A, Expires)]);
  finally
    A.Free;
  end;
  Result := Plain;
end;

{ Fills a record from a row with the columns in ReadColumns order. }
const
  ReadColumns = 'id, user_id, name, scopes, created_at, last_used_at, ' +
                'expires_at, revoked_at';

procedure ReadRow(R: TDbResult; Row: Integer; var T: TApiToken);
begin
  ClearToken(T);
  T.Id := R.AsInt64(Row, 0);
  T.UserId := R.Value(Row, 1).ToString;
  T.Name_ := R.Value(Row, 2).ToString;
  T.Scopes := R.Value(Row, 3).ToString;
  T.CreatedAt := R.AsInt64(Row, 4);
  if not R.IsNull(Row, 5) then
    T.LastUsedAt := R.AsInt64(Row, 5);
  if not R.IsNull(Row, 6) then
    T.ExpiresAt := R.AsInt64(Row, 6);
  if not R.IsNull(Row, 7) then
    T.RevokedAt := R.AsInt64(Row, 7);

  if T.RevokedAt > 0 then
    T.State := tsRevoked
  else if (T.ExpiresAt > 0) and (T.ExpiresAt <= UnixNowMs) then
    T.State := tsExpired
  else
    T.State := tsActive;
end;

function FindToken(Db: TDbConnection; const Plain: string;
  out T: TApiToken): Boolean;
var
  A: TArena;
  R: TDbResult;
  Sql: string;
begin
  ClearToken(T);
  NeedDb(Db);
  { Cheap reject before a query. A request carrying a JWT, a basic-auth
    string or a stray word does not become a database round trip -- and
    every token this ever issued has exactly this shape, so nothing real
    is turned away by the length check. It also keeps the table out of
    the picture entirely for an application that has never issued one. }
  if Length(Plain) <> Length(TokenPrefix) + 43 then
    Exit(False);
  if Copy(Plain, 1, Length(TokenPrefix)) <> TokenPrefix then
    Exit(False);

  A := TArena.Create(8 * 1024);
  try
    Sql := 'SELECT ' + ReadColumns + ' FROM ' + Quoted(Db, A, TokenTable) +
      ' WHERE token_hash = ' + Ph(Db, A, 1);
    R := Db.ExecParams(A, Sql, [DbParam(A, Sha256Hex(Plain))]);
    if (R = nil) or R.IsEmpty then
      Exit(False);
    ReadRow(R, 0, T);
  finally
    A.Free;
  end;
  Result := T.State = tsActive;
end;

procedure TouchToken(Db: TDbConnection; TokenId: Int64);
var
  A: TArena;
  Sql: string;
  Now_: Int64;
begin
  NeedDb(Db);
  Now_ := UnixNowMs;
  A := TArena.Create(4 * 1024);
  try
    { One statement, and the guard is inside it. Read-then-write would
      let two workers decide to write at the same moment; this way the
      database decides, and the loser updates nothing. }
    Sql := 'UPDATE ' + Quoted(Db, A, TokenTable) +
      ' SET last_used_at = ' + Ph(Db, A, 1) +
      ' WHERE id = ' + Ph(Db, A, 2) +
      ' AND (last_used_at IS NULL OR last_used_at < ' + Ph(Db, A, 3) + ')';
    Db.ExecParams(A, Sql, [
      DbParam(A, Now_),
      DbParam(A, TokenId),
      DbParam(A, Now_ - TokenTouchMs)]);
  finally
    A.Free;
  end;
end;

function RevokeToken(Db: TDbConnection; TokenId: Int64): Boolean;
var
  A: TArena;
  R: TDbResult;
  Sql: string;
begin
  Result := False;
  NeedDb(Db);
  A := TArena.Create(4 * 1024);
  try
    { Marked, not deleted. "This token was revoked on Tuesday" and "this
      token never existed" are different answers to the only question
      anybody asks afterwards, and a deleted row can give only the
      second. The guard keeps the first revocation time. }
    Sql := 'UPDATE ' + Quoted(Db, A, TokenTable) +
      ' SET revoked_at = ' + Ph(Db, A, 1) +
      ' WHERE id = ' + Ph(Db, A, 2) + ' AND revoked_at IS NULL';
    R := Db.ExecParams(A, Sql, [DbParam(A, UnixNowMs), DbParam(A, TokenId)]);
    Result := (R <> nil) and (R.AffectedRows > 0);
  finally
    A.Free;
  end;
end;

function RevokeTokensFor(Db: TDbConnection; const UserId: string): Integer;
var
  A: TArena;
  R: TDbResult;
  Sql: string;
begin
  Result := 0;
  NeedDb(Db);
  A := TArena.Create(4 * 1024);
  try
    Sql := 'UPDATE ' + Quoted(Db, A, TokenTable) +
      ' SET revoked_at = ' + Ph(Db, A, 1) +
      ' WHERE user_id = ' + Ph(Db, A, 2) + ' AND revoked_at IS NULL';
    R := Db.ExecParams(A, Sql, [DbParam(A, UnixNowMs), DbParam(A, UserId)]);
    if (R <> nil) and (R.AffectedRows > 0) then
      Result := Integer(R.AffectedRows);
  finally
    A.Free;
  end;
end;

function TokensFor(Db: TDbConnection; const UserId: string): TApiTokens;
var
  A: TArena;
  R: TDbResult;
  Sql: string;
  I: Integer;
begin
  Result := nil;
  NeedDb(Db);
  A := TArena.Create(32 * 1024);
  try
    Sql := 'SELECT ' + ReadColumns + ' FROM ' + Quoted(Db, A, TokenTable) +
      ' WHERE user_id = ' + Ph(Db, A, 1) + ' ORDER BY id';
    R := Db.ExecParams(A, Sql, [DbParam(A, UserId)]);
    if (R = nil) or R.IsEmpty then
      Exit;
    SetLength(Result, R.RowCount);
    for I := 0 to R.RowCount - 1 do
      ReadRow(R, I, Result[I]);
  finally
    A.Free;
  end;
end;

{ --------------------------------------------------------- middleware -- }

function BearerToken(Req: TRequest): string;
var
  H: string;
begin
  Result := '';
  if Req = nil then
    Exit;
  H := Trim(Req.Header('authorization').ToString);
  { 'Bearer ' and at least one character. }
  if Length(H) < 8 then
    Exit;
  if not SameText(Copy(H, 1, 7), 'Bearer ') then
    Exit;
  Result := Trim(Copy(H, 8, MaxInt));
end;

function CurrentToken: TApiToken;
begin
  Result := GToken;
end;

function HasToken: Boolean;
begin
  Result := GToken.State = tsActive;
end;

function ScopeInList(const List_, Scope: string): Boolean;
var
  Rest, One: string;
  P: Integer;
begin
  Rest := List_;
  while Rest <> '' do
  begin
    P := Pos(' ', Rest);
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
    if One = '' then
      Continue;
    { '*' is the only wildcard there is. 'orders:*' was considered and
      left out: it reads as an obvious extension and then raises a
      question with no obvious answer -- whether the star crosses a colon
      -- at the exact moment somebody is deciding what an admin token may
      do. A token can list as many exact scopes as it likes, which is the
      same reach without the ambiguity. }
    if (One = '*') or (One = Scope) then
      Exit(True);
  end;
  Result := False;
end;

function TokenAllows(const Scope: string): Boolean;
begin
  if not Check then
    Exit(False);
  { Signed in, but not by a token: there is no scope to check against.
    See the interface -- this is the answer that has to be read twice. }
  if GToken.State <> tsActive then
    Exit(True);
  Result := ScopeInList(GToken.Scopes, Scope);
end;

procedure AuthorizeScope(const Scope: string);
begin
  if not TokenAllows(Scope) then
    { The scope is named, nothing else. The message ends up in a log and
      in nobody's reply. }
    raise EForbidden.CreateFmt('Not authorized: scope %s', [Scope]);
end;

function ReasonText(S: TTokenState): string;
begin
  case S of
    tsNone: Result := 'unknown';
    tsActive: Result := 'active';
    tsRevoked: Result := 'revoked';
    tsExpired: Result := 'expired';
  end;
end;

type
  TTokenHook = class
    class function Authenticate(Req: TRequest): TResponse;
  end;

{ RFC 6750 says how a bearer scheme refuses, and it costs one header. A
  client library that knows the standard can tell "your token is wrong"
  from "you did not send one" without parsing prose. }
function Unauthorized_: TResponse;
begin
  Result := ErrorResponse(401, 'The API token is not valid.')
    .WithHeader('WWW-Authenticate',
      'Bearer error="invalid_token", error_description="The API token is not valid."');
end;

class function TTokenHook.Authenticate(Req: TRequest): TResponse;
var
  Plain: string;
  Db: TDbConnection;
  T: TApiToken;
begin
  Result := nil;
  { First, and before anything can fail: whatever this worker was
    carrying from the last request is not this request's. }
  ClearToken(GToken);
  Plain := BearerToken(Req);
  if Plain = '' then
    Exit;

  Db := CurrentDb;
  NeedDb(Db);

  if not FindToken(Db, Plain, T) then
  begin
    { Only a token that is in the table is logged. A token that is not
      tells us nothing and would let anybody fill the log by sending
      words. A token that is there and unusable is the case somebody will
      ask about. }
    if T.State in [tsRevoked, tsExpired] then
      LogInfo('api token refused',
        ['token', T.Id, 'user', T.UserId,
         'reason', ReasonText(T.State)]);
    Exit(Unauthorized_);
  end;

  TouchToken(Db, T.Id);
  GToken := T;
  { No Arena.Defer for this one, unlike the identity in Askr.Auth. The
    first line of this middleware clears it, and this middleware runs on
    every request the router serves -- so the token is set and unset by
    the same piece of code, and a test can see the difference. The
    identity is not like that: Askr.Auth is read by code that has no idea
    whether this middleware ran, and nothing else would ever clear it. A
    second guard that nothing measures is worse than no guard. }
  { Last: this is what makes Check, Id, User and every gate answer. }
  LoginForRequest(T.UserId);
end;

procedure UseTokenAuth(R: TRouter);
begin
  R.Use(TTokenHook.Authenticate);
end;

end.
