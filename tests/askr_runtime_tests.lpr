{ Tests for the runtime parts of phase 2, written with Askr.Testing.

  This file is also the demonstration of the framework: the router is
  tested without a socket, the database is sqlite::memory:, and the arena
  is asserted about directly. }
program AskrRuntimeTests;

{$mode Delphi}{$H+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  SysUtils, Classes, StrUtils, Sockets, BaseUnix,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Clock, Askr.Core.Json,
  Askr.Core.Env, Askr.Core.Config, Askr.Core.Log, Askr.Core.Url,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response, Askr.Http.Router,
  Askr.Http.Welcome, Askr.Http.Server, Askr.Http.Client,
  Askr.Http.Cors, Askr.Http.RateLimit, Askr.OpenApi,
  Askr.Urd.Driver, Askr.Urd.Model, Askr.Urd.Query, Askr.Urd.Sqlite,
  Askr.Urd.Bind, Askr.Urd.Json,
  Askr.Core.Crypto,
  Askr.Urd.Pool,
  Askr.Queue, Askr.Queue.Db, Askr.Scheduler, Askr.Session, Askr.Csrf,
  Askr.Auth, Askr.Auth.Token, Askr.Mail, Askr.Mail.Resend, Askr.Ai, Askr.Inertia,
  Askr.Testing,
  Askr.Core.Version, Askr.Image, Askr.Image.Vips, Askr.Cli.Diag, Askr.Cli.Mcp, Askr.Cli.Docs, Askr.Cli.Fields, Askr.Cli.Scaffold, Askr.Cli.Plan, Askr.Cli.Resource, Askr.Norn.Schema, Askr.Norn.Introspect, Askr.Norn.Codegen, Askr.Http.Robots, Askr.Http.Sitemap,
  DOM, XMLRead;

{ -------------------------------------------------------------- versjon -- }

{ A release is one number across two ecosystems: the Pascal source and
  @askrcode/lauf on npm. If they drift apart you get a component whose
  client half does not fit the server half, and nothing says so until
  something stops working. They HAD drifted: the CLI said 0.6.0 while
  package.json said 0.1.0. This test is the reason it cannot happen
  again. }
procedure TestLaufFoelgerRammeverket;
var
  F: TStringList;
  I, A, B: Integer;
  Line_, Fant, Path_: string;
begin
  Fant := '';
  { Run from the repository root by ./askr test. If we cannot find the
    file, that is not a reason to claim the versions match. }
  Path_ := 'frontend/lauf/package.json';
  AssertTrue(FileExists(Path_), 'package.json exists (run from the repository root)');
  F := TStringList.Create;
  try
    F.LoadFromFile(Path_);
    for I := 0 to F.Count - 1 do
    begin
      Line_ := Trim(F[I]);
      if Pos('"version"', Line_) <> 1 then
        Continue;
      A := Pos(':', Line_);
      A := Pos('"', Line_, A);
      B := Pos('"', Line_, A + 1);
      Fant := Copy(Line_, A + 1, B - A - 1);
      Break;
    end;
  finally
    F.Free;
  end;
  AssertEqual(Fant, AskrVersion,
    'frontend/lauf/package.json must have the same version as Askr.Core.Version');
end;

procedure TestSemVerSammenligning;
begin
  AssertTrue(CompareSemVer('0.6.0', '0.7.0') < 0, '0.6.0 < 0.7.0');
  AssertTrue(CompareSemVer('0.10.0', '0.9.0') > 0, '0.10.0 > 0.9.0 (not as text)');
  AssertEqual(CompareSemVer('1.2.3', 'v1.2.3'), 0, 'a v prefix is the same version');
  { The semver rule that is easy to get wrong: rc comes BEFORE the
    release. }
  AssertTrue(CompareSemVer('0.7.0-rc.1', '0.7.0') < 0, 'rc before the release');
  AssertTrue(not ParseSemVer('not-a-version').Valid, 'rubbish is invalid');
  AssertTrue(not ParseSemVer('1.2.3.4').Valid, 'four parts is not semver');

  { The npm rule for a zero major: ^0.6.0 locks the minor, because a
    zero-major project breaks things in a minor. }
  AssertTrue(SatisfiesRange('0.6.3', '^0.6.0'), '0.6.3 passer ^0.6.0');
  AssertTrue(not SatisfiesRange('0.7.0', '^0.6.0'), '0.7.0 passer ikke ^0.6.0');
  AssertTrue(SatisfiesRange('1.9.0', '^1.2.0'), '1.9.0 passer ^1.2.0');
  AssertTrue(not SatisfiesRange('0.5.0', '^0.6.0'), 'older never satisfies');
  AssertTrue(SatisfiesRange('0.6.9', '~0.6.0'), '~ locks major.minor');
  AssertTrue(not SatisfiesRange('0.7.0', '~0.6.0'), '~ slipper ikke minor');
end;

{ ------------------------------------------------------------ scheduler -- }

var
  Q: TQueue;
  S: TScheduler;

procedure NoJob(const Ctx: TJobContext);
begin
end;

procedure SchedulerSetup;
begin
  Q := TQueue.Create(1, 1);
  Q.Handle('a', @NoJob);
  Q.Handle('b', @NoJob);
  S := TScheduler.Create(Q);
end;

procedure SchedulerRydd;
begin
  S.Free;
  Q.Free;
end;

procedure TestIntervall;
begin
  SchedulerSetup;
  try
    S.EverySeconds(10, 'a');
    AssertEqual(S.Count, 1, 'one entry');
    { The first run is in ten seconds, not now. }
    AssertEqual(S.Tick(UnixNow), 0, 'not due yet');
    AssertEqual(S.Tick(UnixNow + 10), 1, 'due after ten seconds');
    AssertEqual(S.Tick(UnixNow + 10), 0, 'not twice on the same tick');
    AssertEqual(S.Tick(UnixNow + 20), 1, 'and then again');
    AssertEqual(Q.Pending, 2, 'two jobs landed on the queue');
  finally
    SchedulerRydd;
  end;
end;

procedure TestDaglig;
var
  Now_: Int64;
  Ran, I: Integer;
begin
  SchedulerSetup;
  try
    S.DailyAt(3, 30, 'a');
    Now_ := UnixNow;
    Ran := 0;
    { One day, hour by hour: exactly one run. }
    for I := 0 to 24 do
      Ran := Ran + S.Tick(Now_ + Int64(I) * 3600);
    AssertEqual(Ran, 1, 'a daily job ran once in a day');
  finally
    SchedulerRydd;
  end;
end;

procedure TestUkentlig;
var
  Now_: Int64;
  Ran, I: Integer;
begin
  SchedulerSetup;
  try
    S.WeeklyAt(dowMonday, 8, 0, 'a');
    Now_ := UnixNow;
    Ran := 0;
    for I := 0 to 7 * 24 do
      Ran := Ran + S.Tick(Now_ + Int64(I) * 3600);
    AssertEqual(Ran, 1, 'a weekly job ran once in a week');
  finally
    SchedulerRydd;
  end;
end;

procedure TestHoppOverNaarKoenVenter;
var
  Now_: Int64;
begin
  SchedulerSetup;
  try
    S.EverySeconds(1, 'a');
    S.SkipWhenPending;
    Now_ := UnixNow;
    S.Tick(Now_ + 1);
    AssertEqual(Q.Pending, 1, 'the first run landed on the queue');
    { The job is still there, so the next one is to be skipped. }
    S.Tick(Now_ + 2);
    AssertEqual(Q.Pending, 1, 'does not stack on top of a job that is waiting');
  finally
    SchedulerRydd;
  end;
end;

procedure TestBeskrivelse;
var
  L: TStringList;
begin
  SchedulerSetup;
  L := TStringList.Create;
  try
    S.EveryMinutes(5, 'clean-up');
    S.DailyAt(3, 30, 'nattjobb');
    S.Describe(L);
    AssertEqual(L.Count, 2, 'to linjer');
    AssertContains(L.Text, 'every 5 minutes', 'an interval is described readably');
    AssertContains(L.Text, 'daily at 03:30', 'daily is described readably');
  finally
    L.Free;
    SchedulerRydd;
  end;
end;

{ -------------------------------------------------------------- sesjoner -- }

var
  Store: TSessionStore;
  ClientCookie: string;

function MakeReq(A: TArena; const Cookie_: string): TRequest;
var
  Prev: TArena;
  Head: string;
begin
  Head := 'GET / HTTP/1.1'#13#10'Host: t';
  if Cookie_ <> '' then
    Head := Head + #13#10'Cookie: askr_session=' + Cookie_;
  Prev := UseArena(A);
  try
    Result := TRequest.Create;
    Result.ParseHead(StrDup(A, Head), DefaultMaxBodyBytes);
  finally
    UseArena(Prev);
  end;
end;

function CookieFrom(R: TResponse; A: TArena): string;
var
  B: TStrBuilder;
  Raw: string;
  P, Q2: Integer;
begin
  B.Init(A, 1024);
  R.WriteTo(B, False, False);
  Raw := B.ToString;
  P := Pos('askr_session=', Raw);
  if P = 0 then
    Exit('');
  Inc(P, Length('askr_session='));
  Q2 := P;
  while (Q2 <= Length(Raw)) and (Raw[Q2] <> ';') do
    Inc(Q2);
  Result := Copy(Raw, P, Q2 - P);
end;

procedure TestSessionRoundTrip;
var
  A: TArena;
  Prev: TArena;
  Req: TRequest;
  Sess: TSession;
  R: TResponse;
begin
  Store := TSessionStore.Create(3600);
  A := TArena.Create(16 * 1024);
  Prev := UseArena(A);
  try
    { The first request: no cookie, a new session. }
    Req := MakeReq(A, '');
    Sess := Store.Start(Req);
    AssertTrue(Sess.IsNew, 'a new session with no cookie');
    AssertEqual(Length(Sess.Id), 32, 'id er 32 hex-tegn');
    Sess.Put('bruker', 'knut');
    R := Respond(200);
    Store.Commit(Sess, R);
    ClientCookie := CookieFrom(R, A);
    AssertEqual(Length(ClientCookie), 32, 'the cookie was set');

    { The second request: the same cookie, the same data. }
    A.Reset;
    Req := MakeReq(A, ClientCookie);
    Sess := Store.Start(Req);
    AssertFalse(Sess.IsNew, 'the session was resumed');
    AssertEqual(Sess.Get('bruker'), 'knut', 'the value survived');
    AssertEqual(Store.Resumed, 1, 'counted as resumed');

    { En ukjent kake gir en ny sesjon, ikke en feil. }
    A.Reset;
    Req := MakeReq(A, '00000000000000000000000000000000');
    Sess := Store.Start(Req);
    AssertTrue(Sess.IsNew, 'an unknown id gives a new session');
  finally
    UseArena(Prev);
    A.Free;
    Store.Free;
  end;
end;

procedure TestFlashLeverEnRequest;
var
  A: TArena;
  Prev: TArena;
  Req: TRequest;
  Sess: TSession;
  R: TResponse;
  Cookie_: string;
begin
  Store := TSessionStore.Create(3600);
  A := TArena.Create(16 * 1024);
  Prev := UseArena(A);
  try
    Req := MakeReq(A, '');
    Sess := Store.Start(Req);
    Sess.Flash('suksess', 'Stored');
    AssertFalse(Sess.HasFlash('suksess'),
      'what you write is not readable in the same request');
    R := Respond(200);
    Store.Commit(Sess, R);
    Cookie_ := CookieFrom(R, A);

    { The next request: now it is readable. }
    A.Reset;
    Req := MakeReq(A, Cookie_);
    Sess := Store.Start(Req);
    AssertTrue(Sess.HasFlash('suksess'), 'readable in the next request');
    AssertEqual(Sess.GetFlash('suksess'), 'Stored', 'the right value');
    R := Respond(200);
    Store.Commit(Sess, R);

    { And gone in the one after. }
    A.Reset;
    Req := MakeReq(A, Cookie_);
    Sess := Store.Start(Req);
    AssertFalse(Sess.HasFlash('suksess'), 'gone in the third request');
  finally
    UseArena(Prev);
    A.Free;
    Store.Free;
  end;
end;

{ Every flash key is to reach the Inertia payload, not only one
  particular one.

  The guard in BuildPayload used to ask for the key 'suksess' literally,
  while WriteFlashInto writes every key except _errors. An app that did
  Session.Flash('error', ...) — as the generated auth scaffolding does —
  had the message silently discarded. The test deliberately uses a
  different key from the one that was there. }
procedure TestInertiaFlashUansettNokkel;
var
  A: TArena;
  PrevA: TArena;
  PrevR: TRequest;
  PrevS: TSession;
  Req: TRequest;
  Sess: TSession;
  R: TResponse;
  Cookie_, Body: string;

  function InertiaReq(const WithCookie_: string): TRequest;
  var
    P: TArena;
  begin
    P := UseArena(A);
    try
      Result := TRequest.Create;
      Result.ParseHead(StrDup(A, 'GET / HTTP/1.1'#13#10'Host: t'#13#10 +
        'X-Inertia: true' +
        IfThen(WithCookie_ <> '', #13#10'Cookie: askr_session=' + WithCookie_, '')),
        DefaultMaxBodyBytes);
    finally
      UseArena(P);
    end;
  end;

begin
  Store := TSessionStore.Create(3600);
  A := TArena.Create(32 * 1024);
  PrevA := UseArena(A);
  PrevR := UseRequest(nil);
  PrevS := UseSession(nil);
  try
    TInertia.SetVersion('t');

    { Set a flash under a key other than 'suksess'. }
    Req := MakeReq(A, '');
    Sess := Store.Start(Req);
    Sess.Flash('error', 'That link is no longer valid.');
    R := Respond(200);
    Store.Commit(Sess, R);
    Cookie_ := CookieFrom(R, A);

    { The next request: it is to be in the payload. }
    A.Reset;
    Req := InertiaReq(Cookie_);
    UseRequest(Req);
    Sess := Store.Start(Req);
    UseSession(Sess);
    AssertTrue(Sess.HasAnyFlash, 'the session has a readable flash');
    Body := Inertia('Home', ['x', Int64(1)]).Body.ToString;
    AssertContains(Body, '"error":"That link is no longer valid."',
      'a flash under a key other than suksess comes along');

    { And the guard is to keep guarding: with no flash and no errors, no
      flash key at all. }
    A.Reset;
    UseSession(nil);
    Req := InertiaReq('');
    UseRequest(Req);
    Sess := Store.Start(Req);
    UseSession(Sess);
    AssertFalse(Sess.HasAnyFlash, 'a new session has no flash');
    Body := Inertia('Home', ['x', Int64(1)]).Body.ToString;
    AssertNotContains(Body, '"flash"',
      'with no flash the flash object is not written');

    { _errors does not count as a message — it is a prop of its own. }
    A.Reset;
    UseSession(nil);
    Req := MakeReq(A, '');
    Sess := Store.Start(Req);
    Sess.FlashErrorsJson(Str('{"name":"is required"}'));
    R := Respond(302);
    Store.Commit(Sess, R);
    Cookie_ := CookieFrom(R, A);

    A.Reset;
    Req := InertiaReq(Cookie_);
    UseRequest(Req);
    Sess := Store.Start(Req);
    UseSession(Sess);
    AssertFalse(Sess.HasAnyFlash,
      'a validation error is not a flash message');
    AssertTrue(Sess.HasErrors, 'but they are there as errors');
    Body := Inertia('Home', ['x', Int64(1)]).Body.ToString;
    AssertContains(Body, '"errors"', 'and they come out as errors');
  finally
    UseSession(PrevS);
    UseRequest(PrevR);
    UseArena(PrevA);
    A.Free;
    Store.Free;
  end;
end;

{ The session must not outlive the request as a threadvar.

  It lives in the request arena and disappears on Reset. If it is left
  standing, the next request on that worker sees a pointer into memory the
  arena has reused — and then it reads an object that no longer exists.

  The exit that slipped past was the most common of them all: an anonymous
  visitor who starts a session without writing to it. It was found as an
  EAccessViolation when a browser fetched a css file right after a page on
  the same connection, on a real site built with the framework. The large
  file got a new arena block and went quietly past; the small one landed on
  top of the old object.

  The test goes through the router, that is, the way a real request
  goes. }
function TomHandler(Req: TRequest): TResponse;
begin
  Result := RespondText('ok');
end;

function WriteAndReply(Req: TRequest): TResponse;
begin
  CurrentSession.Put('x', '1');
  Result := RespondText('ok');
end;

procedure TestSesjonenLekkerIkkeUtAvRequesten;
var
  A: TArena;
  Prev: TArena;
  PrevS: TSession;
  R: TRouter;
  Req: TRequest;
  Res: TResponse;
begin
  Store := TSessionStore.Create(3600);
  SetSessions(Store);
  A := TArena.Create(16 * 1024);
  Prev := UseArena(A);
  PrevS := UseSession(nil);
  R := TRouter.Create;
  try
    UseSessions(R);
    R.Get('/', TomHandler);

    { 1. An anonymous visitor: the session is started and never written
      to. It is to be neither stored nor given a cookie — and it must
      not be left standing. }
    Req := MakeReq(A, '');
    Res := R.Handle(Req);
    AssertStatus(Res, 200, 'the request went through');
    AssertNil(CurrentSession,
      'a session nobody wrote to is not left standing after the request');

    { 2. And one that was written to is cleaned up as well. }
    A.Reset;
    Req := MakeReq(A, '');
    R.Free;
    R := TRouter.Create;
    UseSessions(R);
    R.Get('/', WriteAndReply);
    Res := R.Handle(Req);
    AssertNil(CurrentSession, 'also when it was stored');
    AssertTrue(CookieFrom(Res, A) <> '', 'and it got a cookie');
  finally
    R.Free;
    UseSession(PrevS);
    UseArena(Prev);
    A.Free;
    Store.Free;
  end;
end;

procedure TestValideringsfeilOverlevererOmdirigering;
var
  A: TArena;
  Prev: TArena;
  Req: TRequest;
  Sess: TSession;
  R: TResponse;
  Cookie_: string;
begin
  Store := TSessionStore.Create(3600);
  A := TArena.Create(16 * 1024);
  Prev := UseArena(A);
  try
    Req := MakeReq(A, '');
    Sess := Store.Start(Req);
    Sess.FlashErrorsJson(Str('{"name":"is required"}'));
    R := Respond(302);
    Store.Commit(Sess, R);
    Cookie_ := CookieFrom(R, A);

    { Dette er avviket fra steg 5, lukket: feilene overlever omdirigeringen. }
    A.Reset;
    Req := MakeReq(A, Cookie_);
    Sess := Store.Start(Req);
    AssertTrue(Sess.HasErrors, 'the errors survived the redirect');
    AssertContains(Sess.ErrorsJson, 'is required', 'with the content intact');
  finally
    UseArena(Prev);
    A.Free;
    Store.Free;
  end;
end;

{ -------------------------------------------------------- api-tokens -- }

{ The gate for token authentication.

  The database is a **file**, not sqlite::memory:, because one of the
  claims is about what is on disk: the token that was just issued must not
  be anywhere in it. A sweep for something absent proves nothing on its
  own -- an empty file passes, and so does a path with a typo in it -- so
  the sweep also requires the hash to be present. That is the difference
  between measuring and hoping, and the same mistake was made once
  already in the hydration check. }
type
  TTokCtl = class
  public
    function Me(Req: TRequest): TResponse;
    function ReadOrders(Req: TRequest): TResponse;
    function WriteOrders(Req: TRequest): TResponse;
    function Which(Req: TRequest): TResponse;
    function Strict(Req: TRequest): TResponse;
  end;

function TTokCtl.Me(Req: TRequest): TResponse;
begin
  if Check then
    Result := RespondText('user:' + Id)
  else
    Result := RespondText('out');
end;

{ TokenAllows rather than AuthorizeScope: the raising form is checked
  directly below, and the status it turns into is measured over a real
  socket in askr_tests -- the test client has no server to do that
  mapping. }
function TTokCtl.ReadOrders(Req: TRequest): TResponse;
begin
  if not TokenAllows('orders:read') then
    Exit(ErrorResponse(403));
  Result := RespondText('read');
end;

function TTokCtl.WriteOrders(Req: TRequest): TResponse;
begin
  if not TokenAllows('orders:write') then
    Exit(ErrorResponse(403));
  Result := RespondText('write');
end;

function TTokCtl.Which(Req: TRequest): TResponse;
begin
  Result := RespondText(CurrentToken.Name_);
end;

{ The raising form, and both of the statuses it can raise. The handler
  catches and answers, because the test client has no server to do the
  mapping -- that mapping is measured over a socket in askr_tests. }
function TTokCtl.Strict(Req: TRequest): TResponse;
begin
  try
    AuthorizeScope('orders:write');
  except
    on E: EAuthError do
      Exit(ErrorResponse(E.HttpStatus));
  end;
  Result := RespondText('wrote');
end;

function FileBytes(const Path_: string): string;
var
  F: TFileStream;
begin
  Result := '';
  F := TFileStream.Create(Path_, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, F.Size);
    if F.Size > 0 then
      F.ReadBuffer(Result[1], F.Size);
  finally
    F.Free;
  end;
end;

procedure TestApiTokens;
const
  Folder = '.build/token-test';
  DbFile = '.build/token-test/tokens.sqlite';
var
  C: TDbConnection;
  R: TRouter;
  Ctl: TTokCtl;
  K: TTestClient;
  A: TArena;
  Res: TResponse;
  Full, ReadOnly_, Star, Doomed, Stale, NoScope, Raw, Tweaked: string;
  One_, Two_: string;
  RateR: TRouter;
  RateK: TTestClient;
  T: TApiToken;
  Tokens: TApiTokens;
  I, Forbidden_: Integer;
begin
  ForceDirectories(Folder);
  DeleteFile(DbFile);

  C := OpenDbConnection('sqlite:' + DbFile);
  UseDb(C);
  Ctl := nil;
  R := nil;
  K := nil;
  try
    EnsureTokenSchema(C);
    { Twice is a no-op. The durable queue learned this the hard way:
      CREATE INDEX IF NOT EXISTS does not exist in MySQL, so the check
      has to come first rather than the DDL being idempotent. }
    EnsureTokenSchema(C);

    Full := IssueToken(C, '7', 'ci', ['orders:read', 'orders:write']);
    ReadOnly_ := IssueToken(C, '7', 'reader', ['orders:read']);
    Star := IssueToken(C, '7', 'everything', ['*']);
    Doomed := IssueToken(C, '7', 'to be revoked', ['orders:read']);
    Stale := IssueToken(C, '7', 'to expire', ['orders:read'], 60);
    NoScope := IssueToken(C, '9', 'no scopes at all', []);

    AssertEqual(Copy(Full, 1, 5), 'askr_',
      'a token is recognisable for what it is');
    AssertEqual(Length(Full), Length(TokenPrefix) + 43,
      '32 bytes, base64url, unpadded');
    AssertTrue(Full <> ReadOnly_, 'two tokens are not the same token');

    A := TArena.Create(8 * 1024);
    try
      { Revoked, and expired by moving the expiry into the past. A test
        may write SQL; waiting a minute is not a test. }
      C.Exec(A, 'UPDATE api_tokens SET revoked_at = 1 ' +
        'WHERE name = ' + QuotedStr('to be revoked'));
      C.Exec(A, 'UPDATE api_tokens SET expires_at = 1 ' +
        'WHERE name = ' + QuotedStr('to expire'));
    finally
      A.Free;
    end;

    { --- the sweep ------------------------------------------------- }

    { Closed first, so everything is on disk and nothing is sitting in a
      write-ahead log nobody is looking at. }
    UseDb(nil);
    C.Free;
    C := nil;
    Raw := FileBytes(DbFile);

    { The control. Without it the assertions below are also true of an
      empty file, a missing file, and a path with a typo in it. }
    AssertTrue(Pos(Sha256Hex(Full), Raw) > 0,
      'the sweep is reading the right file: the hash is in it');

    AssertEqual(Pos(Full, Raw), 0, 'the token itself is not on disk');
    AssertEqual(Pos(ReadOnly_, Raw), 0, 'nor the second');
    AssertEqual(Pos(Star, Raw), 0, 'nor the third');
    AssertEqual(Pos(Doomed, Raw), 0, 'nor the revoked one');
    AssertEqual(Pos(Stale, Raw), 0, 'nor the expired one');
    AssertEqual(Pos(NoScope, Raw), 0, 'nor the one with no scopes');
    { Not even a fragment. A stored prefix column would put one there,
      which is the argument for not having one. }
    AssertEqual(Pos(Copy(Full, Length(TokenPrefix) + 1, 12), Raw), 0,
      'not even the first twelve characters of one');

    { --- lookups --------------------------------------------------- }

    C := OpenDbConnection('sqlite:' + DbFile);
    UseDb(C);

    AssertTrue(FindToken(C, Full, T), 'a live token is found');
    AssertEqual(T.UserId, '7', 'and says whose it is');
    AssertEqual(T.Name_, 'ci', 'and what it was called');

    AssertFalse(FindToken(C, Doomed, T), 'a revoked token is not usable');
    AssertTrue(T.State = tsRevoked, 'and the server knows why');
    AssertFalse(FindToken(C, Stale, T), 'an expired token is not usable');
    AssertTrue(T.State = tsExpired, 'and the server knows why');

    AssertFalse(FindToken(C, 'askr_' + StringOfChar('A', 43), T),
      'a token that was never issued is not found');
    AssertTrue(T.State = tsNone, 'and there is nothing to say about it');
    AssertFalse(FindToken(C, 'not-a-token', T),
      'nor is something that is not one at all');

    { The wrong length never reaches the table at all -- every token has
      exactly one shape, so the check turns nothing real away. }
    AssertFalse(FindToken(C, Full + 'x', T), 'a longer string is not it');
    AssertFalse(FindToken(C, Copy(Full, 1, Length(Full) - 1), T),
      'nor a shorter one');

    { Right shape, one character different. This one does reach the hash
      lookup, and has to miss: a comparison anywhere in the chain that
      settled for a prefix would let it through. }
    Tweaked := Full;
    if Tweaked[Length(Tweaked)] = 'A' then
      Tweaked[Length(Tweaked)] := 'B'
    else
      Tweaked[Length(Tweaked)] := 'A';
    AssertFalse(FindToken(C, Tweaked, T),
      'one character different is a different token');

    { --- through the router ---------------------------------------- }

    Ctl := TTokCtl.Create;
    R := TRouter.Create;
    R.Get('/me', Ctl.Me);
    R.Get('/orders', Ctl.ReadOrders);
    R.Post('/orders', Ctl.WriteOrders);
    R.Get('/which', Ctl.Which);
    R.Get('/strict', Ctl.Strict);
    UseTokenAuth(R);
    { CSRF on the same router, and after the token, because every POST
      below has to get past it.

      A request that authenticated with a header is not what CSRF
      defends against -- no other site can set an Authorization header on
      a request to us. Without the exemption every one of those POSTs is
      a 419, so the assertions below are the proof that it works. There
      are no sessions wired up here at all, which is why the last check
      in this block is a 419 and has to be. }
    UseCsrf(R);
    K := TTestClient.Create(R);

    Res := K.Get('/me');
    AssertEqual(Res.Body.ToString, 'out', 'no token, nobody signed in');

    Res := K.WithHeader('Authorization', 'Bearer ' + Full).Get('/me');
    AssertEqual(Res.Body.ToString, 'user:7', 'a token signs the request in');

    { **Never from the query string.** There is no code that reads one,
      and this is what says so. It passes trivially today, and that is
      the point: it fails the day somebody adds the convenience. A query
      string ends up in access logs, in Referer on every outbound link,
      in browser history, and in whatever somebody pastes into a chat. }
    Res := K.Get('/me?token=' + Full);
    AssertEqual(Res.Body.ToString, 'out',
      'a token in the query string is not a credential');
    Res := K.Get('/me?access_token=' + Full);
    AssertEqual(Res.Body.ToString, 'out', 'under any name');
    Res := K.WithHeader('X-Api-Key', Full).Get('/me');
    AssertEqual(Res.Body.ToString, 'out',
      'and there is one header, not several');

    { The identity must not outlive the request. The threadvar holding it
      does not die with the arena the way an arena object does, so it is
      cleared by Arena.Defer, which runs when the next request on this
      worker resets the arena. Get this wrong and the next caller is
      served as somebody else -- quietly, and only sometimes. }
    Res := K.Get('/me');
    AssertEqual(Res.Body.ToString, 'out',
      'the next request is not still signed in');

    Res := K.WithHeader('Authorization', 'Bearer ' + Full).Get('/which');
    AssertEqual(Res.Body.ToString, 'ci', 'the handler can see which token');
    Res := K.Get('/which');
    AssertEqual(Res.Body.ToString, '', 'and that is gone next time too');

    { --- what a bad token gets ------------------------------------- }

    Res := K.WithHeader('Authorization', 'Bearer ' + Doomed).Get('/me');
    AssertStatus(Res, 401, 'a revoked token is refused');
    AssertContains(Res.HeaderValue('WWW-Authenticate'), 'Bearer',
      'with the header the bearer scheme refuses by');
    AssertNotContains(Res.Body.ToString, 'revoked',
      'and the body does not say the token was ever real');

    Res := K.WithHeader('Authorization', 'Bearer ' + Stale).Get('/me');
    AssertStatus(Res, 401, 'an expired token is refused');
    Res := K.WithHeader('Authorization',
      'Bearer askr_' + StringOfChar('A', 43)).Get('/me');
    AssertStatus(Res, 401, 'and one that never existed');
    AssertNotContains(Res.Body.ToString, 'askr_',
      'and the reply does not echo what was sent');

    { A credential that is offered and does not work is an error in
      itself. Treating it as an anonymous request would surface later,
      somewhere else, as a 403 or a 404. }
    Res := K.WithHeader('Authorization', 'Bearer ' + Doomed).Get('/orders');
    AssertStatus(Res, 401, 'a bad token stops the request, not the handler');

    { --- scopes ---------------------------------------------------- }

    Res := K.WithHeader('Authorization', 'Bearer ' + Full).Get('/orders');
    AssertEqual(Res.Body.ToString, 'read', 'a scope it has');
    Res := K.WithHeader('Authorization', 'Bearer ' + Full).Post('/orders', '{}');
    AssertEqual(Res.Body.ToString, 'write', 'and the other one');

    Res := K.WithHeader('Authorization', 'Bearer ' + ReadOnly_).Get('/orders');
    AssertEqual(Res.Body.ToString, 'read', 'a read token reads');
    Res := K.WithHeader('Authorization', 'Bearer ' + ReadOnly_)
      .Post('/orders', '{}');
    AssertStatus(Res, 403, 'and is refused the write');

    Res := K.WithHeader('Authorization', 'Bearer ' + Star).Post('/orders', '{}');
    AssertEqual(Res.Body.ToString, 'write', 'a star is every scope');

    { And a browser is still protected. The exemption is for a credential
      the caller carried, not for anything that skipped the session. }
    Res := K.Post('/orders', '{}');
    AssertStatus(Res, 419, 'a POST with no credential still needs a token');

    { A token issued with no scopes is not a master key. Somebody will
      write IssueToken(..., []) meaning everything; this is what they
      get. }
    Res := K.WithHeader('Authorization', 'Bearer ' + NoScope).Get('/orders');
    AssertStatus(Res, 403, 'no scopes means no scopes');

    { Nobody signed in at all is also no. Otherwise a handler carrying
      only a scope check would be open to anyone.

      The request above has to be made first. Without it the last token
      seen is still in the threadvar, and the assertion passes because
      that token happens to have no scopes -- green for the wrong
      reason, which a mutation found. }
    Res := K.Get('/me');
    AssertEqual(Res.Body.ToString, 'out', 'nobody is signed in now');
    AssertFalse(TokenAllows('orders:read'),
      'and then no scope is allowed either');

    { **401 and 403 are not two words for the same refusal.**

      401 says the request carried no credential and the caller should
      send one; 403 says they did and it is not enough. A client told 403
      when it should have been told 401 does not know to authenticate,
      and stops there.

      AuthorizeScope refused an anonymous caller with 403 until a gate
      driving a real API caught it -- and the test written with it
      asserted the wrong one, so nothing else could have. }
    Res := K.Get('/strict');
    AssertStatus(Res, 401, 'nobody signed in is a 401, not a 403');

    Res := K.WithHeader('Authorization', 'Bearer ' + ReadOnly_).Get('/strict');
    AssertStatus(Res, 403,
      'a credential that does not carry the scope is a 403');

    Res := K.WithHeader('Authorization', 'Bearer ' + Star).Get('/strict');
    AssertEqual(Res.Body.ToString, 'wrote', 'and one that does gets through');

    { The 401 says which scheme to answer with. RFC 9110 asks for it,
      and it is the only way a client learns there is a bearer scheme
      here at all. }
    Res := K.Get('/strict');
    AssertEqual(Res.HeaderValue('WWW-Authenticate'), 'Bearer',
      'a bare 401 carries the challenge');
    Res := K.WithHeader('Authorization', 'Bearer ' + Doomed).Get('/strict');
    AssertContains(Res.HeaderValue('WWW-Authenticate'), 'invalid_token',
      'and a refused token keeps the more specific one');

    Forbidden_ := 0;
    try
      AuthorizeScope('orders:write');
    except
      on E: EUnauthenticated do
      begin
        Forbidden_ := E.HttpStatus;
        AssertEqual(E.PublicDetail, '',
          'and says nothing to the caller about what they nearly got');
      end;
    end;
    AssertEqual(Forbidden_, 401,
      'and outside a request, with nobody signed in, it is 401');

    { --- last used, and revoking ----------------------------------- }

    Tokens := TokensFor(C, '7');
    AssertEqual(Length(Tokens), 5, 'the list is that one user''s tokens');
    for I := 0 to High(Tokens) do
      AssertEqual(Pos('askr_', Tokens[I].Scopes + Tokens[I].Name_), 0,
        'and carries nothing that looks like a token');

    AssertTrue(FindToken(C, Full, T), 'still live');
    AssertTrue(T.LastUsedAt > 0, 'and it has been used');

    AssertTrue(RevokeToken(C, T.Id), 'revoking says it revoked something');
    AssertFalse(FindToken(C, Full, T), 'a revoked token stops working');
    { And says so when it did not. The console prints a success on True
      and an error on False, and a command that reports a revocation that
      did not happen is worse than one that fails. }
    AssertFalse(RevokeToken(C, T.Id), 'revoking it twice revokes nothing');
    AssertFalse(RevokeToken(C, 99999), 'nor does revoking one that is not there');
    Res := K.WithHeader('Authorization', 'Bearer ' + Full).Get('/me');
    AssertStatus(Res, 401, 'immediately, on the next request');

    { Five tokens for this user, two of them already revoked -- the one
      backdated with SQL and the one revoked a moment ago. The guard on
      the UPDATE is what makes it three and not five, and it is also what
      keeps the first revocation time rather than overwriting it. }
    AssertEqual(RevokeTokensFor(C, '7'), 3,
      'revoking everything skips the ones already revoked');
    AssertFalse(FindToken(C, Star, T), 'and the rest stop working');
    AssertTrue(FindToken(C, NoScope, T),
      'while another user''s token is untouched');

    { --- a limit per credential, not per office ------------------- }

    { Two tokens for the same user, from the same address. Keyed on the
      address they would share one bucket, which is a limit on a company
      rather than on a caller; keyed on the token they do not.

      A second router, because the one above has already spent a few
      hundred requests. UseRateLimit goes after UseTokenAuth: before it
      there is no token to key on yet, and every caller would fall back
      to their address. }
    One_ := IssueToken(C, '7', 'first', ['*']);
    Two_ := IssueToken(C, '7', 'second', ['*']);

    RateR := TRouter.Create;
    RateR.Get('/me', Ctl.Me);
    UseTokenAuth(RateR);
    UseRateLimit(RateR);
    RateLimit.Off;
    RateLimit.PerMinute(60).Burst(2).KeyBy(@TokenRateKey);
    RateLimit.Clear;
    RateK := TTestClient.Create(RateR);
    try
      AssertEqual(RateK.WithHeader('Authorization', 'Bearer ' + One_)
        .Get('/me').StatusCode, 200, 'the first token asks once');
      AssertEqual(RateK.WithHeader('Authorization', 'Bearer ' + One_)
        .Get('/me').StatusCode, 200, 'and twice');
      AssertEqual(RateK.WithHeader('Authorization', 'Bearer ' + One_)
        .Get('/me').StatusCode, 429, 'and is over its limit');

      AssertEqual(RateK.WithHeader('Authorization', 'Bearer ' + Two_)
        .Get('/me').StatusCode, 200,
        'the other token has its own allowance');
      AssertEqual(RateK.WithHeader('Authorization', 'Bearer ' + Two_)
        .Get('/me').StatusCode, 200, 'to spend');
      AssertEqual(RateK.WithHeader('Authorization', 'Bearer ' + Two_)
        .Get('/me').StatusCode, 429, 'and then it too is over');

      { With no token at all the fallback is the address, which in this
        client is one shared key -- so the anonymous caller is limited
        as well, rather than being the one way round the limit. }
      AssertEqual(RateK.Get('/me').StatusCode, 200,
        'an anonymous caller has an allowance too');
      AssertEqual(RateK.Get('/me').StatusCode, 200, 'of the same size');
      AssertEqual(RateK.Get('/me').StatusCode, 429, 'and no more');
    finally
      RateLimit.Off;
      RateK.Free;
      RateR.Free;
    end;

  finally
    K.Free;
    R.Free;
    Ctl.Free;
    UseDb(nil);
    if C <> nil then
      C.Free;
  end;
end;

{ ------------------------------------------------------------- cors -- }

type
  TCorsCtl = class
  public
    function Ping(Req: TRequest): TResponse;
    function Guarded(Req: TRequest): TResponse;
    function Varying(Req: TRequest): TResponse;
  end;

function TCorsCtl.Ping(Req: TRequest): TResponse;
begin
  Result := RespondText('pong');
end;

{ A route that refuses. CORS headers have to be on this too, or the page
  that called it is told nothing except that something went wrong. }
function TCorsCtl.Guarded(Req: TRequest): TResponse;
begin
  Result := ErrorResponse(401);
end;

{ A reply that already varies on something else. }
function TCorsCtl.Varying(Req: TRequest): TResponse;
begin
  Result := RespondText('vary').WithHeader('Vary', 'X-Inertia');
end;

procedure TestCors;
var
  R: TRouter;
  Ctl: TCorsCtl;
  K: TTestClient;
  Res: TResponse;
  Raised_: Boolean;
begin
  Cors.Reset;
  Ctl := TCorsCtl.Create;
  R := TRouter.Create;
  R.Get('/ping', Ctl.Ping);
  R.Get('/guarded', Ctl.Guarded);
  R.Get('/varying', Ctl.Varying);
  UseCors(R);
  K := TTestClient.Create(R);
  try
    { Closed until somebody says otherwise. Not one header, not even
      Vary: with no policy there is nothing this reply depends on the
      origin for. }
    Res := K.WithHeader('Origin', 'https://app.example').Get('/ping');
    AssertEqual(Res.Body.ToString, 'pong', 'the route still answers');
    AssertEqual(Res.HeaderValue('Access-Control-Allow-Origin'), '',
      'with no policy, nothing is allowed');
    AssertEqual(Res.HeaderValue('Vary'), '', 'and nothing varies');

    Cors.AllowOrigin('https://app.example');

    Res := K.WithHeader('Origin', 'https://app.example').Get('/ping');
    AssertEqual(Res.HeaderValue('Access-Control-Allow-Origin'),
      'https://app.example', 'an origin on the list is allowed');
    AssertContains(Res.HeaderValue('Vary'), 'Origin',
      'and the reply says it depends on who asked');

    { **Exactly, never by prefix.** This one starts with the allowed
      origin and is a different site. Askr.WebAuthn was caught by a
      mutation test on the same shape, with the same vectors missing
      it. }
    Res := K.WithHeader('Origin', 'https://app.example.evil.example')
      .Get('/ping');
    AssertEqual(Res.HeaderValue('Access-Control-Allow-Origin'), '',
      'an origin that merely starts with it is not it');
    AssertContains(Res.HeaderValue('Vary'), 'Origin',
      'and the reply still says it varies, or a cache serves this to ' +
      'the allowed origin');

    Res := K.WithHeader('Origin', 'https://evil.example').Get('/ping');
    AssertEqual(Res.HeaderValue('Access-Control-Allow-Origin'), '',
      'nor is one that has nothing to do with it');
    Res := K.WithHeader('Origin', 'http://app.example').Get('/ping');
    AssertEqual(Res.HeaderValue('Access-Control-Allow-Origin'), '',
      'and the scheme is part of an origin');
    Res := K.Get('/ping');
    AssertEqual(Res.HeaderValue('Access-Control-Allow-Origin'), '',
      'a request with no origin gets no header');

    { A reply that already varies keeps what it had. }
    Res := K.WithHeader('Origin', 'https://app.example').Get('/varying');
    AssertContains(Res.HeaderValue('Vary'), 'X-Inertia', 'the old Vary stays');
    AssertContains(Res.HeaderValue('Vary'), 'Origin', 'and Origin is added');

    { On an error too. A page that cannot read the 401 is a page whose
      developer has no idea what went wrong. }
    Res := K.WithHeader('Origin', 'https://app.example').Get('/guarded');
    AssertStatus(Res, 401, 'the guard still refuses');
    AssertEqual(Res.HeaderValue('Access-Control-Allow-Origin'),
      'https://app.example', 'and the headers are on the refusal');

    { The preflight. }
    Res := K.WithHeader('Origin', 'https://app.example')
      .WithHeader('Access-Control-Request-Method', 'DELETE')
      .Send('OPTIONS', '/ping');
    AssertStatus(Res, 204, 'a preflight is answered without a body');
    AssertEqual(Res.Body.ToString, '', 'and with no body');
    AssertContains(Res.HeaderValue('Access-Control-Allow-Methods'), 'GET',
      'saying which methods');
    AssertContains(Res.HeaderValue('Access-Control-Allow-Headers'),
      'Content-Type', 'and which headers');
    AssertTrue(Res.HeaderValue('Access-Control-Max-Age') <> '',
      'and how long it may be cached');
    AssertContains(Res.HeaderValue('Vary'), 'Origin',
      'and a preflight varies on the origin like everything else');

    { From an origin that is not allowed: still 204, and no headers. The
      browser stops there, and a 403 would tell a script which origins
      are on the list. }
    Res := K.WithHeader('Origin', 'https://evil.example')
      .WithHeader('Access-Control-Request-Method', 'DELETE')
      .Send('OPTIONS', '/ping');
    AssertStatus(Res, 204, 'a preflight from elsewhere is answered too');
    AssertEqual(Res.HeaderValue('Access-Control-Allow-Origin'), '',
      'but allows nothing');
    AssertEqual(Res.HeaderValue('Access-Control-Allow-Methods'), '',
      'and names no methods');
    AssertContains(Res.HeaderValue('Vary'), 'Origin',
      'and still varies, or a cache hands this answer to the allowed one');

    { An OPTIONS that is not a preflight belongs to the application. }
    Res := K.WithHeader('Origin', 'https://app.example').Send('OPTIONS', '/ping');
    AssertStatus(Res, 405,
      'an OPTIONS without a requested method is an ordinary request');

    { Credentials: the origin is echoed, never '*', because that pair is
      the only one a browser accepts. }
    Cors.Reset;
    Cors.AllowOrigin('https://app.example').AllowCredentials;
    Res := K.WithHeader('Origin', 'https://app.example').Get('/ping');
    AssertEqual(Res.HeaderValue('Access-Control-Allow-Origin'),
      'https://app.example', 'with credentials the origin is echoed back');
    AssertEqual(Res.HeaderValue('Access-Control-Allow-Credentials'), 'true',
      'and credentials are allowed');

    { **The pair that cannot be asked for.** A browser refuses it, so a
      server that sends both reads as "anyone, with cookies" and behaves
      as "nobody". }
    Raised_ := False;
    try
      Cors.AllowAnyOrigin;
    except
      on E: ECorsError do
        Raised_ := True;
    end;
    AssertTrue(Raised_, 'any origin after credentials is refused');

    Cors.Reset;
    Cors.AllowAnyOrigin;
    Raised_ := False;
    try
      Cors.AllowCredentials;
    except
      on E: ECorsError do
        Raised_ := True;
    end;
    AssertTrue(Raised_, 'and credentials after any origin, the other way');

    Res := K.WithHeader('Origin', 'https://anywhere.example').Get('/ping');
    AssertEqual(Res.HeaderValue('Access-Control-Allow-Origin'), '*',
      'without credentials, any origin is a star');
    AssertEqual(Res.HeaderValue('Access-Control-Allow-Credentials'), '',
      'and no credentials are offered');

    { Two ways of writing an origin that would never match anything. }
    Cors.Reset;
    Raised_ := False;
    try
      Cors.AllowOrigin('https://app.example/');
    except
      on E: ECorsError do
        Raised_ := True;
    end;
    AssertTrue(Raised_, 'a trailing slash is refused, not quietly kept');
    Raised_ := False;
    try
      Cors.AllowOrigin('*');
    except
      on E: ECorsError do
        Raised_ := True;
    end;
    AssertTrue(Raised_, 'and a star belongs in AllowAnyOrigin');
  finally
    Cors.Reset;
    K.Free;
    R.Free;
    Ctl.Free;
  end;
end;

{ ------------------------------------------------------- rate limiting -- }

{ A key the test can steer. In an application this would be the caller's
  address or their token -- never a header they write, which is the whole
  argument against X-Forwarded-For. }
function TestRateKey(Req: TRequest): string;
begin
  Result := Req.Header('x-test-key').ToString;
  if Result = '' then
    Result := '-';
end;

{ N keys that all land in the same slot. The hash is a pure function of
  the key, so this is exactly what somebody trying to get round the
  limiter would compute -- which is why it is the case worth testing. }
function SameSlotKeys(N: Integer): TStringArray;
var
  Counts: array of Integer;
  I, Want: Integer;
  K: string;
begin
  Result := nil;
  SetLength(Counts, RateSlots);
  Want := -1;
  { One pass to find a slot that enough keys hash to. }
  for I := 1 to 200000 do
  begin
    K := 'c' + IntToStr(I);
    Inc(Counts[RateHash(K) mod RateSlots]);
    if Counts[RateHash(K) mod RateSlots] >= N then
    begin
      Want := Integer(RateHash(K) mod RateSlots);
      Break;
    end;
  end;
  if Want < 0 then
    Exit;
  for I := 1 to 200000 do
  begin
    K := 'c' + IntToStr(I);
    if Integer(RateHash(K) mod RateSlots) = Want then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := K;
      if Length(Result) = N then
        Exit;
    end;
  end;
end;

procedure TestRateLimiting;
var
  R: TRouter;
  Ctl: TCorsCtl;
  K: TTestClient;
  Res: TResponse;
  I, Allowed_: Integer;
  Used: Integer;
  Colliding: TStringArray;
begin
  RateLimit.Off;
  Ctl := TCorsCtl.Create;
  R := TRouter.Create;
  R.Get('/ping', Ctl.Ping);
  UseRateLimit(R);
  K := TTestClient.Create(R);
  try
    { Off until somebody sets a number. }
    for I := 1 to 20 do
      Res := K.Get('/ping');
    AssertEqual(Res.Body.ToString, 'pong', 'unconfigured, nothing is limited');
    AssertEqual(Res.HeaderValue('X-RateLimit-Limit'), '',
      'and nothing is claimed about a limit');

    RateLimit.PerMinute(60).Burst(3).KeyBy(@TestRateKey);
    RateLimit.Clear;

    Res := K.WithHeader('X-Test-Key', 'a').Get('/ping');
    AssertEqual(Res.Body.ToString, 'pong', 'the first goes through');
    AssertEqual(Res.HeaderValue('X-RateLimit-Limit'), '3', 'the limit is said');
    AssertEqual(Res.HeaderValue('X-RateLimit-Remaining'), '2',
      'and what is left');
    K.WithHeader('X-Test-Key', 'a').Get('/ping');
    Res := K.WithHeader('X-Test-Key', 'a').Get('/ping');
    AssertEqual(Res.HeaderValue('X-RateLimit-Remaining'), '0',
      'the bucket empties');

    Res := K.WithHeader('X-Test-Key', 'a').Get('/ping');
    AssertStatus(Res, 429, 'the fourth is refused');
    AssertTrue(StrToIntDef(Res.HeaderValue('Retry-After'), 0) >= 1,
      'with a Retry-After of at least a second');
    AssertEqual(Res.HeaderValue('X-RateLimit-Remaining'), '0',
      'and nothing left');

    { A machine client gets the refusal in the shape it can read. }
    Res := K.WithHeader('X-Test-Key', 'a')
      .WithHeader('Accept', 'application/json').Get('/ping');
    AssertStatus(Res, 429, 'still refused');
    AssertContains(Res.HeaderValue('Content-Type'), 'application/problem+json',
      'as a problem document');
    AssertContains(Res.Body.ToString, '"status":429', 'with the status in it');

    { **A different key is a different bucket.** Without this the limit
      is on the server, not on the caller, and one busy client stops
      everybody. }
    Res := K.WithHeader('X-Test-Key', 'b').Get('/ping');
    AssertEqual(Res.Body.ToString, 'pong', 'somebody else is unaffected');

    { **X-Forwarded-For is not read.** The default key is the address the
      connection came from. A header the client writes would let anybody
      pick a new key on every request and never be limited at all -- a
      limiter you can opt out of is worse than none, because it is
      believed. Here the key function is the default one and the header
      changes on every call. }
    RateLimit.Off;
    RateLimit.PerMinute(60).Burst(2).KeyBy(@RemoteAddrKey);
    RateLimit.Clear;
    Allowed_ := 0;
    for I := 1 to 6 do
    begin
      Res := K.WithHeader('X-Forwarded-For', '10.0.0.' + IntToStr(I)).Get('/ping');
      if Res.StatusCode = 200 then
        Inc(Allowed_);
    end;
    AssertEqual(Allowed_, 2,
      'a new X-Forwarded-For on every request buys nothing');

    { Refill. A hundred a second, a bucket of one: after fifty
      milliseconds there is a token again, with a wide margin either
      side. }
    RateLimit.Off;
    RateLimit.PerMinute(6000).Burst(1).KeyBy(@TestRateKey);
    RateLimit.Clear;
    Res := K.WithHeader('X-Test-Key', 'r').Get('/ping');
    AssertEqual(Res.Body.ToString, 'pong', 'the one token is spent');
    Res := K.WithHeader('X-Test-Key', 'r').Get('/ping');
    AssertStatus(Res, 429, 'and the next is refused');
    { A hundred a second means a token is back in ten milliseconds, so
      the honest number of seconds to wait is a fraction of one. It is
      rounded up to a whole second rather than down to zero: a
      Retry-After of 0 says "now", and a client that obeys it spins. }
    AssertTrue(StrToIntDef(Res.HeaderValue('Retry-After'), 0) >= 1,
      'and told to wait at least a second, never zero');
    Sleep(50);
    Res := K.WithHeader('X-Test-Key', 'r').Get('/ping');
    AssertEqual(Res.Body.ToString, 'pong', 'the bucket refills with time');

    { **Memory does not grow with traffic.** Ten thousand distinct keys
      through a table of four thousand slots: the table is the size it
      was, and the caller who keeps asking keeps their slot, because
      they are the reason the limiter exists. }
    RateLimit.Off;
    RateLimit.PerMinute(60).Burst(2).KeyBy(@TestRateKey);
    RateLimit.Clear;
    K.WithHeader('X-Test-Key', 'hot').Get('/ping');
    K.WithHeader('X-Test-Key', 'hot').Get('/ping');
    for I := 1 to 10000 do
    begin
      K.WithHeader('X-Test-Key', 'flood-' + IntToStr(I)).Get('/ping');
      if (I mod 100) = 0 then
        { The hot key is asked for throughout, so it is never the least
          recently used of its slots. }
        K.WithHeader('X-Test-Key', 'hot').Get('/ping');
    end;
    Used := RateLimit.SlotsUsed;
    AssertTrue(Used <= RateSlots,
      'the table has a ceiling and ten thousand keys did not raise it');
    Res := K.WithHeader('X-Test-Key', 'hot').Get('/ping');
    AssertStatus(Res, 429,
      'and the caller who kept asking is still over their limit');

    { **Taking a slot over must not hand out a fresh allowance.**

      The hash is a pure function of the key, so anybody can work out
      keys that land in the same few slots as their own. If a displaced
      slot were refilled, spending eight of those would drop your own
      bucket and give you a new one -- a way round the limiter that costs
      eight requests.

      So: nine keys that collide, a bucket of one each. The first eight
      fill the probe window and empty their buckets. The ninth has
      nowhere free to go and takes one of them over -- and has to inherit
      an empty bucket, not be handed a full one. }
    RateLimit.Off;
    RateLimit.PerMinute(60).Burst(1).KeyBy(@TestRateKey);
    RateLimit.Clear;
    Colliding := SameSlotKeys(RateProbe + 1);
    AssertEqual(Length(Colliding), RateProbe + 1,
      'nine keys that hash to the same slot were found');
    for I := 0 to RateProbe - 1 do
      AssertEqual(K.WithHeader('X-Test-Key', Colliding[I]).Get('/ping')
        .StatusCode, 200, 'each of the first eight spends its one token');
    for I := 0 to RateProbe - 1 do
      AssertEqual(K.WithHeader('X-Test-Key', Colliding[I]).Get('/ping')
        .StatusCode, 429, 'and is then over');
    Res := K.WithHeader('X-Test-Key', Colliding[RateProbe]).Get('/ping');
    AssertStatus(Res, 429,
      'the ninth inherits an empty bucket rather than a new one');

    { And the other half: when the window is not all exhausted, the slot
      taken over is the **least constrained** of them -- whoever has the
      most left is least in need of it. Displacing the emptiest instead
      would punish a newcomer for somebody else's flooding, and would
      forget the one entry that is actually doing work.

      A bucket of two. The first key spends both; the other seven spend
      one each and keep one. The ninth then has to inherit one of the
      ones with something left, not the empty one. }
    RateLimit.Off;
    RateLimit.PerMinute(60).Burst(2).KeyBy(@TestRateKey);
    RateLimit.Clear;
    K.WithHeader('X-Test-Key', Colliding[0]).Get('/ping');
    K.WithHeader('X-Test-Key', Colliding[0]).Get('/ping');
    AssertEqual(K.WithHeader('X-Test-Key', Colliding[0]).Get('/ping')
      .StatusCode, 429, 'the first key is empty');
    for I := 1 to RateProbe - 1 do
      AssertEqual(K.WithHeader('X-Test-Key', Colliding[I]).Get('/ping')
        .StatusCode, 200, 'the others keep one each');
    Res := K.WithHeader('X-Test-Key', Colliding[RateProbe]).Get('/ping');
    AssertStatus(Res, 200,
      'a newcomer takes over a slot with something left, not the empty one');
    Res := K.WithHeader('X-Test-Key', Colliding[RateProbe]).Get('/ping');
    AssertStatus(Res, 429, 'and has only what it inherited');
    Res := K.WithHeader('X-Test-Key', Colliding[0]).Get('/ping');
    AssertStatus(Res, 429,
      'while the caller who spent theirs is still remembered');
  finally
    RateLimit.Off;
    K.Free;
    R.Free;
    Ctl.Free;
  end;
end;

function ProblemMember(const Body_, Path_: string): string; overload;
var
  A: TArena;
  Root, V: PJsonValue;
  ErrAt: SizeInt;
  Rest, Key: string;
  P: Integer;
begin
  A := TArena.Create(64 * 1024);
  try
    if not JsonParse(A, StrDup(A, Body_), Root, ErrAt) then
      Exit('<not json>');
    V := Root;
    Rest := Path_;
    while Rest <> '' do
    begin
      P := Pos('.', Rest);
      if P = 0 then
      begin
        Key := Rest;
        Rest := '';
      end
      else
      begin
        Key := Copy(Rest, 1, P - 1);
        Rest := Copy(Rest, P + 1, MaxInt);
      end;
      V := JsonMember(V, Key);
    end;
    Result := JsonAsString(V);
  finally
    A.Free;
  end;
end;

function ProblemMember(R: TResponse; const Path_: string): string; overload;
begin
  Result := ProblemMember(R.Body.ToString, Path_);
end;

{ True when the document parses at all. A payload nobody can parse is the
  one failure a substring check never notices. }
function IsJson(const Body_: string): Boolean;
var
  A: TArena;
  Root: PJsonValue;
  ErrAt: SizeInt;
begin
  A := TArena.Create(64 * 1024);
  try
    Result := JsonParse(A, StrDup(A, Body_), Root, ErrAt);
  finally
    A.Free;
  end;
end;

{ Every link inside docs/ goes somewhere.

  There are forty pages now and they refer to each other constantly --
  the API layer alone is six pages that only make sense together. A
  reference to a page that was renamed, or to a section that was
  rewritten, is worse than no reference: it reads as an answer and ends
  in a 404. Nothing else would notice, because the documentation is
  prose and prose compiles.

  Only links **within** docs/ are checked. An http link needs a network
  and would make the suite depend on somebody else's uptime, and a `../`
  link points into the repository, which the docs site does not
  serve. }
function AnchorOf(const Heading: string): string;
var
  I: Integer;
  C: Char;
  S: string;
begin
  { GitHub's rule, which is what every markdown reader follows: lower
    case, spaces to hyphens, and everything that is not a letter, a
    digit or a hyphen dropped. }
  S := LowerCase(Trim(Heading));
  Result := '';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if C = ' ' then
      Result := Result + '-'
    else if ((C >= 'a') and (C <= 'z')) or ((C >= '0') and (C <= '9')) or
            (C = '-') then
      Result := Result + C;
  end;
end;

procedure TestDocLinks;
var
  Pages: TDocPages;
  Anchors: TStringList;
  Body, Line, Target, Path_, Anchor: string;
  F: TStringList;
  I, J, P, Q, Bar: Integer;
  Broken: Integer;
  Checked: Integer;
begin
  AssertTrue(DirectoryExists('docs'),
    'docs/ is there (run from the repository root)');

  Pages := DocPages('docs');
  AssertTrue(Length(Pages) > 20, 'the pages are found');

  { Every heading on every page, as "page.md#anchor". }
  Anchors := TStringList.Create;
  F := TStringList.Create;
  try
    Anchors.Sorted := True;
    Anchors.Duplicates := dupIgnore;
    for I := 0 to High(Pages) do
    begin
      F.LoadFromFile('docs/' + Pages[I]);
      Anchors.Add(Pages[I]);
      for J := 0 to F.Count - 1 do
      begin
        Line := F[J];
        if Copy(Line, 1, 1) <> '#' then
          Continue;
        while (Line <> '') and (Line[1] = '#') do
          System.Delete(Line, 1, 1);
        Anchors.Add(Pages[I] + '#' + AnchorOf(Line));
      end;
    end;

    Broken := 0;
    Checked := 0;
    for I := 0 to High(Pages) do
    begin
      F.LoadFromFile('docs/' + Pages[I]);
      Body := F.Text;
      P := Pos('](', Body);
      while P > 0 do
      begin
        Q := PosEx(')', Body, P + 2);
        if Q = 0 then
          Break;
        Target := Copy(Body, P + 2, Q - P - 2);
        P := PosEx('](', Body, Q);

        if (Copy(Target, 1, 4) = 'http') or (Copy(Target, 1, 3) = '../') or
           (Target = '') then
          Continue;

        Bar := Pos('#', Target);
        if Bar = 0 then
        begin
          Path_ := Target;
          Anchor := '';
        end
        else
        begin
          Path_ := Copy(Target, 1, Bar - 1);
          Anchor := Copy(Target, Bar + 1, MaxInt);
        end;
        { A bare #anchor means a section of this same page. }
        if Path_ = '' then
          Path_ := Pages[I];

        Inc(Checked);
        if Anchor = '' then
        begin
          if Anchors.IndexOf(Path_) < 0 then
          begin
            Inc(Broken);
            Fail(Format('%s links to a page that is not there: %s',
              [Pages[I], Target]));
          end;
        end
        else if Anchors.IndexOf(Path_ + '#' + Anchor) < 0 then
        begin
          Inc(Broken);
          Fail(Format('%s links to a section that is not there: %s',
            [Pages[I], Target]));
        end;
      end;
    end;

    { The count matters: with nothing to check, "nothing is broken" is
      true of an empty directory and of a bug in the scanner. }
    AssertTrue(Checked > 40,
      Format('there are links to check (%d found)', [Checked]));
    AssertEqual(Broken, 0, 'and every one of them resolves');
  finally
    F.Free;
    Anchors.Free;
  end;
end;

{ -------------------------------------------------------- field specs -- }

{ `name:type` into a model and a migration. What is accepted, what each
  becomes, and -- the larger half -- what is refused and why. }
function SpecRefused(const Arg: string; out Msg: string): Boolean;
begin
  Msg := '';
  try
    ParseFields([Arg]);
    Result := False;
  except
    on E: EFieldSpec do
    begin
      Msg := E.Message;
      Result := True;
    end;
  end;
end;

{ The version a new migration gets. Two `askr make model` in the same
  second used to get the same one, and the migrator ran the second's DDL
  and then failed to record it. The gate for the generators found it only
  because the two happened to land in one second -- so the rule is held
  here, where the clock does not decide. }
{ EmptyIsNull on a name that is not there, or on something that is not a
  string. A setting that silently did nothing would look like it worked,
  and the column would go on being '' where it should be NULL. }
type
  TEmptyTypo = class(TModel)
  private
    FId: Int64;
    FNote: string;
  published
    property Id: Int64 read FId write FId;
    property Note: string read FNote write FNote;
  public
    class procedure Describe(S: TSchema); override;
  end;

  TEmptyOnNumber = class(TModel)
  private
    FId: Int64;
    FQty: Int64;
  published
    property Id: Int64 read FId write FId;
    property Qty: Int64 read FQty write FQty;
  public
    class procedure Describe(S: TSchema); override;
  end;

  TEmptyRight = class(TModel)
  private
    FId: Int64;
    FNote: string;
  published
    property Id: Int64 read FId write FId;
    property Note: string read FNote write FNote;
  public
    class procedure Describe(S: TSchema); override;
  end;

class procedure TEmptyTypo.Describe(S: TSchema);
begin
  S.Table('empty_typos');
  S.EmptyIsNull('Notes');
end;

class procedure TEmptyOnNumber.Describe(S: TSchema);
begin
  S.Table('empty_numbers');
  S.EmptyIsNull('Qty');
end;

class procedure TEmptyRight.Describe(S: TSchema);
begin
  S.Table('empty_rights');
  S.EmptyIsNull('Note');
end;

type
  { A date that may be unset, and one the rules require. }
  TDated = class(TModel)
  private
    FId: Int64;
    FSeenAt: TDateTime;
    FBorn: TDateTime;
  published
    property Id: Int64 read FId write FId;
    property SeenAt: TDateTime read FSeenAt write FSeenAt;
    property Born: TDateTime read FBorn write FBorn;
  public
    class procedure Describe(S: TSchema); override;
    procedure Rules(V: TValidator); override;
  end;

class procedure TDated.Describe(S: TSchema);
begin
  S.Table('dateds');
end;

procedure TDated.Rules(V: TValidator);
begin
  V.Field('Born').Required;
end;

{ An unset date, three ways: as text from a form, as JSON out, and to the
  rules. Zero is what an unset TDateTime is; JSON wrote it as a real date,
  1899-12-30. The rules already read it as blank, and this holds that. }
procedure TestUnsetDates;
var
  A: TArena;
  D: TDated;
  V: TDateTime;
  W: TJsonWriter;
  Json: string;
begin
  AssertTrue(SqlToDateTime(Str('2026-01-02 03:04:05'), V) and
    (FormatDateTime('yyyy-mm-dd hh:nn:ss', V) = '2026-01-02 03:04:05'),
    'a date with seconds');
  { What <input type="datetime-local"> sends whenever the seconds are
    zero. It used to be refused, and FillInto then kept the old value
    without a word. }
  AssertTrue(SqlToDateTime(Str('2026-01-02T03:04'), V) and
    (FormatDateTime('yyyy-mm-dd hh:nn:ss', V) = '2026-01-02 03:04:00'),
    'a date and time without seconds, as a browser sends it');
  AssertTrue(SqlToDateTime(Str('2026-01-02'), V), 'a date alone');
  AssertFalse(SqlToDateTime(Str('2026-01-02T03'), V), 'but not an hour alone');
  AssertFalse(SqlToDateTime(Str('2026-01-02T03:04:5'), V),
    'nor half a second');
  AssertFalse(SqlToDateTime(Str('2026-01-02T03-04'), V),
    'nor a dash where the colon goes');

  A := TArena.Create(16 * 1024);
  UseArena(A);
  try
    D := TDated.Create;
    D.Born := EncodeDate(2026, 1, 2);
    W.Init(A, 256);
    WriteModel(W, D);
    Json := W.ToStr.ToString;
    AssertContains(Json, '"seen_at":null', 'an unset date goes out as null');
    AssertNotContains(Json, '1899', 'and not as the day zero happens to be');
    AssertContains(Json, '"born":"2026-01-02 00:00:00"', 'a set one as its text');

    AssertTrue(D.Validate, 'a set date satisfies Required');
    D.Born := 0;
    AssertFalse(D.Validate, 'an unset one does not');
    AssertTrue(D.Errors.Has('born'), 'and the error is on the column');
  finally
    UseArena(nil);
    A.Free;
  end;
end;

procedure TestEmptyIsNull;
var
  Msg: string;
begin
  Msg := '';
  try
    TEmptyTypo.Meta;
  except
    on E: EModelError do
      Msg := E.Message;
  end;
  AssertContains(Msg, 'Notes', 'a property that is not there is named');

  Msg := '';
  try
    TEmptyOnNumber.Meta;
  except
    on E: EModelError do
      Msg := E.Message;
  end;
  AssertContains(Msg, 'string', 'and a number is refused, saying what it is for');

  AssertTrue(TEmptyRight.Meta.Columns[TEmptyRight.Meta.IndexOfProp('Note')]
    .EmptyIsNull, 'a string property is marked');
  AssertFalse(TEmptyRight.Meta.Columns[TEmptyRight.Meta.IndexOfProp('Id')]
    .EmptyIsNull, 'and only that one');
end;

procedure TestNextVersion;
const
  Root = '.build/nextversion-test';
var
  L: TStringList;
  V: string;
begin
  ForceDirectories(Root + '/database');
  DeleteFile(Root + '/database/App.Migrations.Later.pas');
  AssertEqual(Length(NextVersion(Root)), 14, 'a version is fourteen digits');
  AssertTrue(NextVersion(Root) >= Stamp, 'and not earlier than now');

  { A migration already in the project with a version later than now --
    written by hand, or by a clock that was ahead. The next one has to come
    after it, not at "now". }
  L := TStringList.Create;
  try
    L.Add('unit App.Migrations.Later;');
    L.Add('class function TLater.Version: string;');
    L.Add('begin');
    L.Add('  Result := ''99990101000000'';');
    L.Add('end;');
    L.SaveToFile(Root + '/database/App.Migrations.Later.pas');
  finally
    L.Free;
  end;
  V := NextVersion(Root);
  AssertEqual(V, '99990101000001',
    'the next version comes after the highest one there is');
  AssertTrue(V <> '99990101000000', 'and is never the same as one');
end;

procedure TestFieldSpecs;
var
  F: TFieldSpecs;
  Msg: string;
begin
  F := ParseFields(['name:string(60)', 'notes:text?', 'qty:int',
    'active:bool', 'price:money', 'seen_at:datetime?', 'born:date',
    'maker:references', 'address2:string']);
  AssertEqual(Length(F), 9, 'every argument became a field');

  AssertEqual(F[0].Column, 'name', 'the column is the name as given');
  AssertEqual(F[0].Prop, 'Name', 'and the property its Pascal form');
  AssertEqual(F[0].Length, 60, 'with the length it was given');
  AssertEqual(MigrationLineOf(F[0]), 'Text(''name'', 60);', 'into the migration');
  AssertEqual(RuleLineOf(F[0]), 'V.Field(''Name'').Required.MaxLen(60);',
    'and a rule that says what the column already says');

  AssertTrue(F[1].Nullable, 'a trailing ? is nullable');
  AssertEqual(MigrationLineOf(F[1]), 'Text(''notes'').Nullable;',
    'and says so in the migration');
  AssertEqual(RuleLineOf(F[1]), '', 'and is not required');

  { A NOT NULL number or boolean is not Required. Zero and false are
    values; Required would refuse the one value nobody thinks of as
    missing. }
  AssertEqual(RuleLineOf(F[2]), '', 'an int is not required for being NOT NULL');
  AssertEqual(RuleLineOf(F[3]), '', 'nor is a bool');
  AssertEqual(PascalTypeOf(F[4]), 'Currency', 'money is Currency, not a Double');
  AssertEqual(PascalTypeOf(F[5]), 'TDateTime', 'a datetime is a TDateTime');
  { A NOT NULL date is required: a zero TDateTime is written as NULL, and
    against NOT NULL that is a constraint error -- a 500 where a 422 is
    the right answer. }
  AssertEqual(RuleLineOf(F[6]), 'V.Field(''Born'').Required;',
    'a NOT NULL date is required, or it becomes a constraint error');

  AssertEqual(F[7].Column, 'maker_id', 'a reference is the thing plus _id');
  AssertEqual(F[7].RefTable, 'makers', 'pointing at its table');
  AssertEqual(MigrationLineOf(F[7]), 'ForeignKey(''maker_id'', ''makers'');',
    'as a foreign key');
  { Every reference, nullable or not: no table has a row 0. }
  AssertEqual(DescribeLineOf(F[7]), 'S.ZeroIsNull(''MakerId'');',
    'and zero is no row, to the database and to JSON');
  AssertEqual(F[8].Prop, 'Address2', 'a digit in a name is kept');

  { A NOT NULL json is required: '' is not JSON, so the database would
    refuse it with an error a long way from the form. }
  F := ParseFields(['meta:json', 'extra:json?']);
  AssertEqual(RuleLineOf(F[0]), 'V.Field(''Meta'').Required;',
    'a NOT NULL json is required, or the database refuses it');
  AssertEqual(DescribeLineOf(F[0]), '', 'and needs no EmptyIsNull');
  AssertEqual(DescribeLineOf(F[1]), 'S.EmptyIsNull(''Extra'');',
    'a nullable json has its empty written as NULL');

  { Nothing is inferred from a name. }
  F := ParseFields(['email:string']);
  AssertEqual(RuleLineOf(F[0]), 'V.Field(''Email'').Required.MaxLen(255);',
    'a column called email is not therefore an email');

  { ---- refused ---- }
  AssertTrue(SpecRefused('name:strng', Msg), 'an unknown type is refused');
  AssertContains(Msg, 'string', 'and the message lists the ones there are');
  AssertTrue(SpecRefused('name', Msg), 'a name with no type is refused');
  AssertTrue(SpecRefused('qty:int(4)', Msg), 'a length on anything but string');
  AssertTrue(SpecRefused('name:string(0)', Msg), 'a length of zero');
  AssertTrue(SpecRefused('name:string(x)', Msg), 'a length that is not a number');
  AssertTrue(SpecRefused('Name:string', Msg), 'a column name with a capital');
  AssertTrue(SpecRefused('first-name:string', Msg), 'or a hyphen');
  AssertTrue(SpecRefused('id:int', Msg), 'id, which every model has');
  AssertTrue(SpecRefused('created_at:datetime', Msg),
    'created_at, which comes with the timestamps');
  AssertTrue(SpecRefused('maker_id:references', Msg),
    'a reference written as its column');
  AssertContains(Msg, 'maker:references', 'and it says how to write it');

  { **The Label_ bug, both halves.** A keyword cannot be a property, and
    the usual escape -- a trailing underscore -- makes the model map to a
    column the migration never made. It happened here by hand once. }
  AssertTrue(SpecRefused('label:string', Msg), 'a Pascal keyword is refused');
  AssertContains(Msg, 'label_', 'and it says what would have gone wrong');
  AssertTrue(SpecRefused('type:string', Msg), 'type too');

  { And a name that does not come back as itself. The model does this
    conversion at run time, with Urd's SnakeCase; the check uses the same
    function, not a copy of it. }
  AssertTrue(SpecRefused('abc_2x:string', Msg),
    'a name that snake_cases back to something else is refused');
  AssertContains(Msg, 'abc2x', 'naming what the model would have used');

  Msg := '';
  try
    ParseFields(['name:string', 'name:text']);
  except
    on E: EFieldSpec do
      Msg := E.Message;
  end;
  AssertContains(Msg, 'twice', 'a column given twice is refused');
end;

{ -------------------------------------------------------- resource plan -- }

{ A table read into what a resource needs. One table with every case the
  plan has to handle in it -- a keyword for a column name, a secret, a
  default, a blob, a reference to a table that is gone, a boolean from
  before SQLite declared them -- and the tables that cannot be resources
  at all. }
function PlanHas(const Lines: TStringArray; const S: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(Lines) do
    if Lines[I] = S then
      Exit(True);
  Result := False;
end;

function NoteMentions(const P: TResourcePlan; const S: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(P.Notes) do
    if Pos(S, P.Notes[I]) > 0 then
      Exit(True);
  Result := False;
end;

procedure TestResourcePlan;
var
  C: TDbConnection;
  A: TArena;
  S: TDbSchema;
  P: TResourcePlan;
  I: Integer;
  Col: TPlanColumn;
  Lines: TStringArray;
  B: TSchemaBuilder;
  Ddl: string;

  function ColOf(const Name_: string): TPlanColumn;
  var
    K: Integer;
  begin
    K := PlanColumnIndex(P, Name_);
    AssertTrue(K >= 0, 'the plan has ' + Name_);
    Result := P.Columns[K];
  end;

begin
  { What SQLite is told to call them now. }
  B := TSchemaBuilder.Create(sdSqlite);
  try
    with B.Create('probe') do
    begin
      Id;
      Bool('flag');
      Json('doc');
      Uuid('ref');
    end;
    Ddl := B.ToSql[0];
  finally
    B.Free;
  end;
  AssertContains(Ddl, '"flag" BOOLEAN', 'SQLite declares a boolean as BOOLEAN');
  AssertContains(Ddl, '"doc" JSON TEXT', 'JSON as JSON TEXT, keeping TEXT affinity');
  AssertContains(Ddl, '"ref" UUID', 'and a UUID as UUID');

  AssertEqual(MemberName('until'), 'Until_', 'until is a keyword to askr schema now');
  AssertEqual(MemberName('string'), 'String_', 'so is string');
  AssertEqual(MemberName('with'), 'With_', 'and with');

  A := TArena.Create(64 * 1024);
  C := OpenDbConnection('sqlite::memory:');
  try
    C.Exec(A, 'CREATE TABLE makers (id INTEGER PRIMARY KEY, name VARCHAR(80) NOT NULL)');
    C.Exec(A, 'CREATE TABLE gadgets (' +
      'id INTEGER PRIMARY KEY, ' +
      'name VARCHAR(60) NOT NULL, ' +
      'notes TEXT, ' +
      'qty INTEGER NOT NULL, ' +
      'active BOOLEAN NOT NULL, ' +
      'is_old INTEGER NOT NULL, ' +
      'price NUMERIC(12,2) NOT NULL, ' +
      'ratio REAL NOT NULL, ' +
      'seen_at DATETIME, ' +
      'born DATE NOT NULL, ' +
      'meta JSON TEXT, ' +
      'tag UUID, ' +
      'status VARCHAR(20) NOT NULL DEFAULT ''new'', ' +
      '"type" VARCHAR(10), ' +
      'password_hash VARCHAR(255) NOT NULL, ' +
      'photo BLOB, ' +
      'maker_id BIGINT NOT NULL REFERENCES makers(id), ' +
      'ghost_id BIGINT REFERENCES ghosts(id), ' +
      'created_at DATETIME NOT NULL, ' +
      'updated_at DATETIME NOT NULL, ' +
      'deleted_at DATETIME)');
    C.Exec(A, 'CREATE TABLE parts (id INTEGER PRIMARY KEY, ' +
      'gadget_id BIGINT REFERENCES gadgets(id), sku VARCHAR(10))');
    C.Exec(A, 'CREATE TABLE nokeys (a INTEGER, b TEXT)');
    C.Exec(A, 'CREATE TABLE twokeys (a INTEGER, b INTEGER, PRIMARY KEY (a, b))');
    C.Exec(A, 'CREATE TABLE textkeys (code TEXT PRIMARY KEY, name TEXT)');

    S := IntrospectSchema(C);
    try
      P := PlanResource(S, 'Gadget');
      AssertEqual(Length(P.Problems), 0, 'gadgets can be a resource');
      AssertEqual(P.Table, 'gadgets', 'Gadget is read from gadgets');
      AssertEqual(P.PrimaryKey, 'id', 'with id as its key');

      Col := ColOf('name');
      AssertTrue(Col.Field.Kind = ftString, 'a VARCHAR is a string');
      { SQLite reports only the text VARCHAR(60). The length is read out of
        it here and not in the introspection, where it would have changed
        every SQLite table's fingerprint on upgrade. }
      AssertEqual(Col.Field.Length, 60, 'with its length, read out of the declared type');
      AssertEqual(Col.Member, 'Name', 'and the typed constant askr schema writes for it');
      AssertEqual(Col.ColAlias, 'TColStr', 'of the type askr schema gives it');

      AssertTrue(ColOf('active').Field.Kind = ftBool, 'BOOLEAN is a bool');
      AssertEqual(ColOf('active').ColAlias, 'TColBool', 'and askr schema says so too now');
      AssertTrue(ColOf('is_old').Field.Kind = ftInt,
        'an INTEGER from before stays a number: nothing in the schema says otherwise');
      AssertTrue(NoteMentions(P, 'is_old'), 'but the plan points it out');
      AssertTrue(ColOf('price').Field.Kind = ftMoney, 'NUMERIC(12,2) is money');
      AssertTrue(ColOf('meta').Field.Kind = ftJson, 'JSON TEXT is json');
      AssertTrue(ColOf('tag').Field.Kind = ftUuid, 'UUID is a uuid');
      AssertTrue(ColOf('born').Field.Kind = ftDate, 'DATE is a date');
      AssertTrue(ColOf('seen_at').Field.Kind = ftDateTime, 'DATETIME a datetime');

      { A keyword for a column name. The property takes the underscore the
        typed constant takes, and Describe maps it, because SnakeCase of
        Type_ is not type. This is the Label_ bug, handled rather than
        refused: the table exists, and refusing it helps nobody. }
      Col := ColOf('type');
      AssertEqual(Col.Field.Prop, 'Type_', 'a keyword column gets an underscore');
      AssertEqual(Col.Member, 'Type_', 'the same one the typed constant has');
      AssertFalse(Col.MapsByName, 'and does not map back by name');
      Lines := DescribeLinesOf(P);
      AssertTrue(PlanHas(Lines, 'S.Column(''Type_'', ''type'');'),
        'so Describe maps it by hand');

      Lines := RuleLinesOf(P);
      AssertTrue(PlanHas(Lines, 'V.Field(''Name'').Required.MaxLen(60);'),
        'the rule the schema states');
      AssertTrue(PlanHas(Lines, 'V.Field(''MakerId'').Required;'),
        'a NOT NULL reference is required');
      { A database default is not what an insert through the model gets
        -- a model writes every column it maps -- so the column is not
        Required; the form starts with the default instead. }
      AssertTrue(PlanHas(Lines, 'V.Field(''Status'').MaxLen(20);'),
        'a column with a default is not required, but keeps its length');
      AssertTrue(NoteMentions(P, 'status'), 'and the plan says why');
      AssertFalse(PlanHas(Lines, 'V.Field(''Qty'').Required;'),
        'a NOT NULL number is not required: zero is a number');

      Lines := DescribeLinesOf(P);
      AssertTrue(PlanHas(Lines, 'S.EmptyIsNull(''Notes'');'),
        'a nullable text is NULL when it is empty');
      AssertTrue(PlanHas(Lines, 'S.EmptyIsNull(''Meta'');'), 'so is a nullable json');
      AssertTrue(PlanHas(Lines, 'S.Timestamps;'), 'the timestamps are recognised');
      AssertTrue(PlanHas(Lines, 'S.SoftDeletes;'), 'and deleted_at');

      { **A secret is hidden.** The one guess in the plan, made in the
        direction whose failure is loud. }
      Col := ColOf('password_hash');
      AssertTrue(Col.LooksSecret, 'password_hash looks like a secret');
      AssertFalse(Col.Editable, 'and is not in the form');
      AssertFalse(Col.Listed, 'or the list');
      AssertFalse(Col.Searchable, 'or searched');
      AssertTrue(PlanHas(HiddenColumnsOf(P), 'password_hash'),
        'and is hidden from JSON');
      AssertFalse(PlanHas(RuleLinesOf(P), 'V.Field(''PasswordHash'').Required.MaxLen(255);'),
        'and has no rule a form would have to satisfy');

      AssertFalse(ColOf('photo').Editable, 'a blob is not a form field');
      AssertFalse(ColOf('photo').Listed, 'or a column in a list');
      AssertTrue(NoteMentions(P, 'photo'), 'and the plan says so');

      AssertFalse(ColOf('created_at').Editable, 'a timestamp is not edited');
      AssertFalse(ColOf('deleted_at').Listed, 'and deleted_at is not listed');
      AssertFalse(ColOf('id').Editable, 'nor is the key');
      AssertTrue(ColOf('id').Sortable, 'though it can be sorted by');
      AssertFalse(ColOf('notes').Listed, 'a long text is not a list column');
      AssertTrue(ColOf('notes').Searchable, 'but it is searched');
      AssertFalse(ColOf('active').Sortable, 'a bool is not sortable: TQuery has no order for one');

      { References. }
      AssertTrue(ColOf('maker_id').Field.Kind = ftReferences, 'maker_id is a reference');
      AssertEqual(ColOf('maker_id').Field.RefTable, 'makers', 'to makers');
      AssertTrue(ColOf('ghost_id').Field.Kind <> ftReferences,
        'a key pointing at a table that is not there is not a relation');
      AssertTrue(NoteMentions(P, 'ghosts'), 'and the plan says where it pointed');

      AssertEqual(Length(P.Relations), 2, 'one relation each way');
      for I := 0 to High(P.Relations) do
        if P.Relations[I].Kind = prBelongsTo then
        begin
          AssertEqual(P.Relations[I].Name, 'Maker', 'belongs to Maker');
          AssertEqual(P.Relations[I].Model, 'Maker', 'the model TMaker');
          AssertEqual(P.Relations[I].ForeignKey, 'maker_id', 'by maker_id');
        end
        else
        begin
          AssertEqual(P.Relations[I].Name, 'Parts', 'has many Parts');
          AssertEqual(P.Relations[I].Model, 'Part', 'of TPart');
          AssertEqual(P.Relations[I].ForeignKey, 'gadget_id', 'by parts.gadget_id');
        end;

      AssertEqual(P.DefaultSort, 'name', 'sorted by its first string column');
      AssertContains(PlanText(P), 'Hidden from JSON', 'the dry run says what it hid');

      { ---- what cannot be a resource ---- }
      P := PlanResource(S, 'Widget');
      AssertTrue(Length(P.Problems) = 1, 'a table that is not there is a problem');
      AssertContains(P.Problems[0], 'widgets', 'naming the table it looked for');
      AssertContains(P.Problems[0], 'gadgets', 'and the ones there are');

      P := PlanResource(S, 'Nokey', 'nokeys');
      AssertTrue((Length(P.Problems) > 0) and (Pos('no primary key', P.Problems[0]) > 0),
        'a table with no key cannot be a resource');
      P := PlanResource(S, 'Twokey', 'twokeys');
      AssertTrue((Length(P.Problems) > 0) and (Pos('2 columns', P.Problems[0]) > 0),
        'nor one whose key is two columns');
      P := PlanResource(S, 'Textkey', 'textkeys');
      AssertTrue((Length(P.Problems) > 0) and (Pos('whole number', P.Problems[0]) > 0),
        'nor one whose key is text');

      AssertEqual(SingularOf('makers'), 'maker', 'makers comes from maker');
      AssertEqual(SingularOf('categories'), 'category', 'categories from category');
      AssertEqual(SingularOf('boxes'), 'box', 'boxes from box');
      AssertEqual(SingularOf('people'), '', 'and people from nothing the rule makes');
    finally
      S.Free;
    end;
  finally
    C.Free;
    A.Free;
  end;
end;

{ ------------------------------------------------------ zero is null -- }

type
  TPart = class(TModel)
  private
    FId: Int64;
    FName: string;
    FMakerId: Int64;
  published
    property Id: Int64 read FId write FId;
    property Name: string read FName write FName;
    property MakerId: Int64 read FMakerId write FMakerId;
  public
    class procedure Describe(S: TSchema); override;
    procedure Rules(V: TValidator); override;
  end;

  TPartOnString = class(TModel)
  private
    FId: Int64;
    FName: string;
  published
    property Id: Int64 read FId write FId;
    property Name: string read FName write FName;
  public
    class procedure Describe(S: TSchema); override;
  end;

class procedure TPart.Describe(S: TSchema);
begin
  S.Table('zero_parts');
  S.ZeroIsNull('MakerId');
end;

procedure TPart.Rules(V: TValidator);
begin
  V.Field('MakerId').Required;
end;

class procedure TPartOnString.Describe(S: TSchema);
begin
  S.Table('zero_strings');
  S.ZeroIsNull('Name');
end;

{ A reference to no row. Pascal has no null Int64, so without this a
  nullable reference could not be NULL: an empty select wrote 0, a foreign
  key to a row that does not exist. Required refusing 0 is IsBlank's, and
  is held here so that it stays so. }
procedure TestZeroIsNull;
var
  A: TArena;
  C: TDbConnection;
  P: TPart;
  W: TJsonWriter;
  Msg: string;
begin
  A := TArena.Create(32 * 1024);
  UseArena(A);
  C := OpenDbConnection('sqlite::memory:');
  UseDb(C);
  try
    C.Exec(A, 'CREATE TABLE zero_parts (id INTEGER PRIMARY KEY, name TEXT, ' +
      'maker_id BIGINT)');
    P := TPart.Create;
    P.Name := 'loose';
    AssertFalse(P.Validate, 'zero is blank to Required');
    AssertTrue(P.Errors.Has('maker_id'), 'and the error is on the column');
    P.Save;
    AssertEqual(C.Exec(A, 'SELECT count(*) FROM zero_parts WHERE maker_id IS NULL')
      .AsInt64(0, 0), 1, 'zero is written as NULL');
    W.Init(A, 256);
    WriteModel(W, P);
    AssertContains(W.ToStr.ToString, '"maker_id":null', 'and goes out as null');

    P.MakerId := 7;
    AssertTrue(P.Validate, 'a real id satisfies Required');
    W.Init(A, 256);
    WriteModel(W, P);
    AssertContains(W.ToStr.ToString, '"maker_id":7', 'and goes out as itself');

    Msg := '';
    try
      TPartOnString.Meta;
    except
      on E: EModelError do
        Msg := E.Message;
    end;
    AssertContains(Msg, 'integer', 'ZeroIsNull on a string is refused, saying what it is for');
  finally
    UseDb(nil);
    UseArena(nil);
    C.Free;
    A.Free;
  end;
end;

{ ------------------------------------------------------- make resource -- }

function TextOf(const F: TGenFiles; const Suffix: string): string;
var
  I: Integer;
begin
  for I := 0 to High(F) do
    if Copy(F[I].Path, Length(F[I].Path) - Length(Suffix) + 1, MaxInt) = Suffix then
      Exit(F[I].Content);
  Result := '';
end;

{ The files make resource writes, held against what they have to be:
  typed columns, only the form's fields filled from a request, no secret
  anywhere a client sees, and a select only where there is a model to
  query it with. The gate builds and runs them; this says why. }
procedure TestResourceFiles;
const
  Root = '.build/resource-test';
var
  A: TArena;
  C: TDbConnection;
  S: TDbSchema;
  P, Locked: TResourcePlan;
  Parents: TParentInfos;
  F: TGenFiles;
  Ctl, Fields, Index_, Show, Test_, Model, Api: string;
  PC: TPlanColumn;
  L: TStringList;
begin
  ForceDirectories(Root + '/app/Models');
  DeleteFile(Root + '/app/Models/App.Models.Maker.pas');
  A := TArena.Create(64 * 1024);
  C := OpenDbConnection('sqlite::memory:');
  try
    C.Exec(A, 'CREATE TABLE makers (id INTEGER PRIMARY KEY, name VARCHAR(80) NOT NULL)');
    C.Exec(A, 'CREATE TABLE gadgets (id INTEGER PRIMARY KEY, ' +
      'name VARCHAR(60) NOT NULL, qty INTEGER NOT NULL, ' +
      'status VARCHAR(20) NOT NULL DEFAULT ''new'', ' +
      'api_token VARCHAR(64), "type" VARCHAR(10), ' +
      'maker_id BIGINT NOT NULL REFERENCES makers(id), ' +
      'created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL)');
    C.Exec(A, 'CREATE TABLE locks (id INTEGER PRIMARY KEY, ' +
      'name VARCHAR(20) NOT NULL, password_hash VARCHAR(255) NOT NULL)');
    S := IntrospectSchema(C);
    try
      P := PlanResource(S, 'Gadget');

      { Without a model for makers, maker_id is a number. }
      Parents := ParentsOf(S, P, Root);
      AssertEqual(Length(Parents), 1, 'one table to point at');
      AssertFalse(Parents[0].Available, 'with no model for it, there is no select');
      F := ResourceFiles(P, Parents, True, True, False);
      AssertContains(TextOf(F, 'Fields.svelte'),
        'label="Maker" required description="The id of a row in makers"',
        'and the field is a number that says what it is');

      L := TStringList.Create;
      try
        L.Text := 'unit App.Models.Maker;';
        L.SaveToFile(Root + '/app/Models/App.Models.Maker.pas');
      finally
        L.Free;
      end;
      Parents := ParentsOf(S, P, Root);
      AssertTrue(Parents[0].Available, 'with one, there is');
      AssertEqual(Parents[0].LabelColumn, 'name', 'labelled by its first string');

      F := ResourceFiles(P, Parents, True, True, True);
      Ctl := TextOf(F, 'App.Http.GadgetsController.pas');
      Fields := TextOf(F, 'Fields.svelte');
      Index_ := TextOf(F, 'Index.svelte');
      Show := TextOf(F, 'Show.svelte');
      Test_ := TextOf(F, 'App.Tests.Gadgets.pas');
      Model := TextOf(F, 'App.Models.Gadget.pas');
      AssertTrue((Ctl <> '') and (Fields <> '') and (Index_ <> '') and (Show <> '') and
        (Test_ <> '') and (Model <> '') and (TextOf(F, 'Add.svelte') <> '') and
        (TextOf(F, 'Edit.svelte') <> ''), 'every file is written');

      { The controller. }
      AssertContains(Ctl, 'Req.FillInto(M, [Gadgets.Name.Name,',
        'a request fills only the fields the form has, by typed column');
      AssertNotContains(Ctl, 'Gadgets.ApiToken.Name', 'never the secret');
      AssertNotContains(Ctl, 'Gadgets.CreatedAt.Name', 'nor a timestamp');
      AssertNotContains(Ctl, 'Req.FillInto(M);', 'and never everything the model maps');
      AssertContains(Ctl, 'G.Sortable(''name'', Gadgets.Name);',
        'a list sorts by typed column');
      AssertContains(Ctl, 'Gadgets.Type_.Name', 'a keyword column by its escaped member');
      AssertContains(Ctl, '.OrderBy(Makers.Name)', 'and the select is ordered by its label');
      AssertNotContains(Ctl, 'function Create(', 'no method hides the constructor');
      AssertNotContains(Ctl, 'function Destroy(', 'nor the destructor');
      AssertContains(Ctl, 'R.Put(''/gadgets/:id'', Ctl.Update);', 'the routes are all there');
      AssertContains(Ctl, 'R.Delete(''/gadgets/:id'', Ctl.Remove);', 'the delete too');

      { The form. }
      AssertContains(Fields, '<Field name="name" label="Name" required>',
        'a required field says so');
      AssertNotContains(Fields, 'name="status" label="Status" required',
        'a column with a default is not required');
      AssertContains(Fields, 'status: ''new'',', 'and starts from the default');
      AssertNotContains(Fields, 'api_token', 'the secret is not in the form');
      AssertNotContains(Fields, 'created_at', 'nor a timestamp');
      AssertContains(Fields, '<Select placeholder="Choose a maker">', 'a reference is a select');
      AssertContains(Fields, 'maker_id: r.maker_id == null ? '''' : String(r.maker_id)',
        'whose value is text, as its options are');

      { The list and the page. }
      AssertContains(Index_, 'align: ''right''', 'a number is aligned the way DataGrid knows');
      AssertNotContains(Index_, 'api_token', 'the secret is not a column');
      AssertNotContains(Show, 'api_token', 'nor on the page');
      AssertContains(Show, 'maker ? shown(maker.name)', 'the page names the maker');

      { The model, for a table that had none. }
      AssertContains(Model, 'S.Column(''Type_'', ''type'');', 'a keyword is mapped by hand');
      AssertContains(Model, 'H.Add(Gadgets.ApiToken);', 'the secret is hidden from JSON');
      AssertContains(Model, 'S.ZeroIsNull(''MakerId'');', 'zero is no maker');

      { --api. }
      Api := TextOf(F, 'App.Http.GadgetsApiController.pas');
      AssertContains(Api, 'AuthorizeScope(''gadgets:read'');', 'reading needs a scope');
      AssertContains(Api, 'AuthorizeScope(''gadgets:write'');', 'and writing another');
      AssertContains(Api, 'Req.FillInto(M, [Gadgets.Name.Name,',
        'a program fills only the same fields as the form');
      AssertContains(Api, 'R.Patch(''/api/gadgets/:id'', Ctl.Update);',
        'a change is a PATCH: what is not sent is left alone');
      AssertNotContains(Api, 'R.Put(', 'and not a PUT, which would mean the whole row');
      AssertContains(Api, 'Exit(ValidationProblem(M.Errors));', 'a refusal is a problem document');
      AssertContains(Api, 'Problem(404,', 'and so is a row that is not there');
      AssertContains(Api, 'G.ListResponse(', 'a list is the envelope');
      AssertContains(Api, '.NoContent.Secured(''gadgets:write'');', 'a delete is described as 204');
      AssertContains(Api, 'Result := Respond(204);', 'and answers it');
      AssertContains(Api, 'D.Patch(''/api/gadgets/:id'')', 'every route is described next to it');
      Test_ := TextOf(F, 'App.Tests.GadgetsApi.pas');
      AssertContains(Test_, '@TestTokens', 'the API test asks without a token and with too little of one');
      AssertContains(Test_, 'Writer.Send(''PATCH''', 'and changes a row with PATCH');
      AssertContains(Test_, '''"api_token"''', 'and looks for the secret in what it reads back');

      { The test. }
      Test_ := TextOf(F, 'App.Tests.Gadgets.pas');
      AssertContains(Test_, '@TestUpdate', 'the test edits');
      AssertContains(Test_, '"created_at":"2001-01-01 00:00:00"',
        'with a forged created_at in the body');
      AssertContains(Test_, 'P0.Name := ''Sample'';', 'and makes the maker first');

      { A table whose NOT NULL secret the form cannot set: the test does
        not pretend to write. }
      Locked := PlanResource(S, 'Lock');
      AssertFalse(Locked.CanCreate, 'a NOT NULL secret with no default means no create');
      F := ResourceFiles(Locked, nil, True, True, False);
      AssertNotContains(TextOf(F, 'App.Tests.Locks.pas'), '@TestStore',
        'so the test does not try');
      AssertContains(TextOf(F, 'App.Tests.Locks.pas'), 'Nothing that writes is tested',
        'and says why');

      { Defaults, as each database reports them. }
      PC := P.Columns[PlanColumnIndex(P, 'status')];
      PC.DefaultExpr := '''new''::character varying';
      AssertEqual(DefaultLiteral(PC), '''new''', 'Postgres');
      PC.DefaultExpr := 'new';
      AssertEqual(DefaultLiteral(PC), '''new''', 'MySQL, unquoted');
      PC.DefaultExpr := '''it''''s''';
      AssertEqual(DefaultLiteral(PC), '''it\''s''', 'a quote, escaped for JavaScript');
      PC.DefaultExpr := 'CURRENT_TIMESTAMP';
      AssertEqual(DefaultLiteral(PC), '', 'a function is left to the database');
      PC := P.Columns[PlanColumnIndex(P, 'qty')];
      PC.DefaultExpr := '0';
      AssertEqual(DefaultLiteral(PC), '0', 'a number as a number');
      PC.DefaultExpr := 'nextval(''x'')';
      AssertEqual(DefaultLiteral(PC), '', 'and a sequence is not one');
    finally
      S.Free;
    end;
  finally
    C.Free;
    A.Free;
  end;
end;

{ ----------------------------------------------------------- openapi -- }

{ A model with something in it that never leaves the process. The
  document has to leave it out for the same reason the serialiser does,
  and from the same place -- otherwise the document is a list of column
  names to go looking for. }
type
  TApiPage = class(TModel)
  private
    FId: Int64;
    FSlug: string;
    FWords: Int64;
    FPrice: Currency;
    FPublishedAt: TDateTime;
    FDraft: Boolean;
    FEditKey: string;
  published
    property Id: Int64 read FId write FId;
    property Slug: string read FSlug write FSlug;
    property Words: Int64 read FWords write FWords;
    property Price: Currency read FPrice write FPrice;
    property PublishedAt: TDateTime read FPublishedAt write FPublishedAt;
    property Draft: Boolean read FDraft write FDraft;
    property EditKey: string read FEditKey write FEditKey;
  public
    class procedure Describe(S: TSchema); override;
    class procedure HideFromJson(H: TJsonHidden); override;
  end;

  TOaCtl = class
  public
    function Index(Req: TRequest): TResponse;
    function Show(Req: TRequest): TResponse;
    function Store(Req: TRequest): TResponse;
    function Secret(Req: TRequest): TResponse;
  end;

const
  { What `askr schema` would generate. Written out here because the test
    has no database; the point is that the names are typed constants. }
  ApiPages: record
    Id: TColInt64;
    Slug: TColStr;
    EditKey: TColStr;
  end = (
    Id: (Name: 'id'; Table: 'api_pages');
    Slug: (Name: 'slug'; Table: 'api_pages');
    EditKey: (Name: 'edit_key'; Table: 'api_pages'));

class procedure TApiPage.Describe(S: TSchema);
begin
  S.Table('api_pages');
end;

class procedure TApiPage.HideFromJson(H: TJsonHidden);
begin
  H.Add(ApiPages.EditKey);
end;

function TOaCtl.Index(Req: TRequest): TResponse;
begin
  Result := RespondText('index');
end;

function TOaCtl.Show(Req: TRequest): TResponse;
begin
  Result := RespondText('show');
end;

function TOaCtl.Store(Req: TRequest): TResponse;
begin
  Result := RespondText('store');
end;

function TOaCtl.Secret(Req: TRequest): TResponse;
begin
  Result := RespondText('secret');
end;

procedure OaDoc(D: TOpenApi);
begin
  D.Title('Docs API').Version('2.1').Covers('/api');
  D.Get('/api/pages').Summary('Every page')
   .ReturnsList(TApiPage).Secured('pages:read');
  D.Get('/api/pages/:id').Summary('One page')
   .Returns(TApiPage).Secured('pages:read');
  D.Post('/api/pages').Summary('Write one')
   .Body(TApiPage).Returns(TApiPage, 201).Secured('pages:write');
end;

{ The same, with a path nobody registered. }
procedure OaDocGhost(D: TOpenApi);
begin
  D.Title('Docs API').Covers('/api');
  D.Get('/api/pages').ReturnsList(TApiPage);
  D.Get('/api/pages/:id').Returns(TApiPage);
  D.Post('/api/pages').Body(TApiPage);
  D.Delete('/api/pages/:id').Summary('There is no such route');
end;

{ And one that says nothing about which paths are the API. }
procedure OaDocUncovered(D: TOpenApi);
begin
  D.Title('Docs API');
  D.Get('/api/pages').ReturnsList(TApiPage);
end;

{ ------------------------------------------------- columns the model owns -- }

type
  { The key, the timestamps and deleted_at are the model's. }
  TOwnedNote = class(TModel)
  private
    FId: Int64;
    FTitle: string;
    FCreatedAt: TDateTime;
    FUpdatedAt: TDateTime;
    FDeletedAt: TDateTime;
  published
    property Id: Int64 read FId write FId;
    property Title: string read FTitle write FTitle;
    property CreatedAt: TDateTime read FCreatedAt write FCreatedAt;
    property UpdatedAt: TDateTime read FUpdatedAt write FUpdatedAt;
    property DeletedAt: TDateTime read FDeletedAt write FDeletedAt;
  public
    class procedure Describe(S: TSchema); override;
  end;

class procedure TOwnedNote.Describe(S: TSchema);
begin
  S.Table('owned_notes');
  S.Timestamps;
  S.SoftDeletes;
end;

procedure OwnedDoc(D: TOpenApi);
begin
  D.Title('Owned').Version('1').Covers('/api');
  D.Post('/api/notes').Body(TOwnedNote).Returns(TOwnedNote, 201);
end;

{ **What a request may set, and what the document says it may.** One
  rule, TModelMeta.IsManaged, asked by FillInto and by the OpenAPI
  document. Before, the one-argument FillInto set created_at from a body
  that carried it, and the document listed created_at in the request. }
procedure TestOwnedColumns;
var
  A, PrevA: TArena;
  Req: TRequest;
  N: TOwnedNote;
  D: TOpenApi;
  Json_, Msg: string;
begin
  A := TArena.Create(32 * 1024);
  PrevA := UseArena(A);
  try
    Req := TRequest.Create;
    Req.ParseHead(StrDup(A, 'POST /api/notes HTTP/1.1'#13#10'Host: t'#13#10 +
      'Content-Type: application/json'#13#10'Content-Length: 120'), DefaultMaxBodyBytes);
    Req.SetBody(StrDup(A, '{"id":9,"title":"Kept","created_at":"2001-01-01 00:00:00",' +
      '"updated_at":"2001-01-01 00:00:00","deleted_at":"2001-01-01 00:00:00"}'));
    N := TOwnedNote.Create;
    Req.FillInto(N);
    AssertEqual(N.Title, 'Kept', 'a column of the request''s is filled');
    AssertTrue((N.CreatedAt = 0) and (N.UpdatedAt = 0),
      'the timestamps are the model''s, whatever the body says');
    AssertTrue(N.DeletedAt = 0, 'and so is deleted_at');
    AssertEqual(N.Id, 0, 'as the key always was');

    Msg := '';
    try
      Req.FillInto(N, ['title', 'created_at']);
    except
      on E: EModelError do
        Msg := E.Message;
    end;
    AssertContains(Msg, 'created_at', 'naming one to fill is refused, and says which');
  finally
    UseArena(PrevA);
    A.Free;
  end;

  D := TOpenApi.Create;
  try
    OwnedDoc(D);
    Json_ := D.ToJson;
    AssertEqual(ProblemMember(Json_,
      'components.schemas.OwnedNoteInput.properties.title.type'), 'string',
      'the request body has the column a request sets');
    { .example and not .type: a date's type is a list, and ProblemMember
      reads a list as '' -- so an assertion on .type was true either way.
      The mutation that put created_at back in the request found it. }
    AssertEqual(ProblemMember(Json_,
      'components.schemas.OwnedNote.properties.created_at.example'),
      '2026-09-22 13:00:00', 'the date''s example is what these read');
    AssertEqual(ProblemMember(Json_,
      'components.schemas.OwnedNoteInput.properties.created_at.example'), '',
      'and not created_at');
    AssertEqual(ProblemMember(Json_,
      'components.schemas.OwnedNoteInput.properties.deleted_at.example'), '',
      'nor deleted_at');
    AssertEqual(ProblemMember(Json_,
      'components.schemas.OwnedNote.properties.created_at.readOnly'), 'true',
      'going out, created_at is there and marked readOnly');
    AssertEqual(ProblemMember(Json_,
      'components.schemas.OwnedNote.properties.id.readOnly'), 'true',
      'and so is the key');
    AssertEqual(ProblemMember(Json_,
      'components.schemas.OwnedNote.properties.title.readOnly'), '',
      'and a column a request sets is not');
  finally
    D.Free;
  end;
end;

procedure TestOpenApi;
var
  R: TRouter;
  Ctl: TOaCtl;
  D: TOpenApi;
  Json_: string;
  Problems_: TStringArray;
  I: Integer;
  Found: Boolean;
begin
  Ctl := TOaCtl.Create;
  R := TRouter.Create;
  R.Get('/api/pages', Ctl.Index);
  R.Get('/api/pages/:id', Ctl.Show);
  R.Post('/api/pages', Ctl.Store);
  { Outside the covered paths, so nothing has to describe it. }
  R.Get('/dashboard', Ctl.Secret);
  try
    RateLimit.Off;

    D := TOpenApi.Create;
    try
      OaDoc(D);
      Json_ := D.ToJson;

      AssertTrue(IsJson(Json_), 'the document is JSON');
      AssertEqual(ProblemMember(Json_, 'openapi'), '3.1.0', 'and says which');
      AssertEqual(ProblemMember(Json_, 'info.title'), 'Docs API', 'with a title');
      AssertEqual(ProblemMember(Json_, 'info.version'), '2.1', 'and a version');

      { The path is written OpenAPI's way, not the router's. }
      AssertContains(Json_, '"/api/pages/{id}"',
        'a route parameter becomes a path template');
      AssertEqual(Pos('/api/pages/:id', Json_), 0,
        'and the router''s own spelling does not leak in');

      AssertEqual(ProblemMember(Json_,
        'paths./api/pages.get.summary'), 'Every page', 'the summary is there');
      AssertEqual(ProblemMember(Json_,
        'paths./api/pages.post.responses.201.description'), 'Created',
        'and the status the operation said it answers with');

      { **The schema comes from the model''s own metadata.** }
      AssertContains(Json_, '"slug"', 'a column is a property');
      AssertEqual(ProblemMember(Json_,
        'components.schemas.ApiPage.properties.words.type'), 'integer',
        'an integer column is an integer');
      AssertEqual(ProblemMember(Json_,
        'components.schemas.ApiPage.properties.draft.type'), 'boolean',
        'a boolean is a boolean');
      AssertEqual(ProblemMember(Json_,
        'components.schemas.ApiPage.properties.price.type'), 'number',
        'and money is a number');

      { **And it leaves out what the serialiser leaves out.** A document
        that listed a hidden column would be a list of things to go
        looking for. }
      AssertEqual(Pos('edit_key', Json_), 0,
        'a column hidden from JSON is not in the document either');

      { **A date is not declared as one.** DateTimeToSql writes
        `2026-09-22 13:00:00` -- a space, and no zone -- which is not
        RFC 3339. A generated client told otherwise would build a parser
        that fails on every row. }
      { And it may be null: an unset date goes out as null, and nothing
        in a model says which of its dates are never unset. }
      AssertContains(Json_, '"published_at":{"type":["string","null"]',
        'a datetime goes out as a string, or as null when it is unset');
      AssertEqual(ProblemMember(Json_,
        'components.schemas.ApiPage.properties.published_at.format'), '',
        'and is not claimed to be RFC 3339');

      { The input shape is not the output shape: a request never fills a
        generated primary key. }
      AssertEqual(ProblemMember(Json_,
        'components.schemas.ApiPageInput.properties.slug.type'), 'string',
        'the input schema has the ordinary columns');
      AssertEqual(ProblemMember(Json_,
        'components.schemas.ApiPageInput.properties.id.type'), '',
        'and not the primary key');

      { The list envelope, described as it is written. }
      AssertEqual(ProblemMember(Json_,
        'components.schemas.ApiPageList.properties.data.type'), 'array',
        'a list answers with an array');
      AssertEqual(ProblemMember(Json_,
        'components.schemas.ApiPageList.properties.data.items.$ref'),
        '#/components/schemas/ApiPage', 'of the model');
      AssertEqual(ProblemMember(Json_,
        'components.schemas.ApiPageList.properties.meta.properties.total.type'),
        'integer', 'with a total');

      { A list gets exactly the query parameters TGrid.Read reads. }
      AssertContains(Json_, '"name":"page"', 'page is a query parameter');
      AssertContains(Json_, '"name":"per"', 'and per');
      AssertContains(Json_, '"name":"sort"', 'and sort');
      AssertContains(Json_, '"name":"q"', 'and the search');

      { The errors the framework answers by itself, and only those. }
      AssertEqual(ProblemMember(Json_,
        'paths./api/pages.get.responses.401.content.' +
        'application/problem+json.schema.$ref'),
        '#/components/schemas/Problem',
        'a secured operation answers 401 with a problem document');
      AssertTrue(ProblemMember(Json_,
        'paths./api/pages.get.responses.403.description') <> '',
        'and 403 when it names a scope');
      AssertTrue(ProblemMember(Json_,
        'paths./api/pages.post.responses.422.description') <> '',
        'an operation with a body answers 422');
      AssertEqual(ProblemMember(Json_,
        'paths./api/pages.get.responses.422.description'), '',
        'and one without a body does not');
      AssertTrue(ProblemMember(Json_,
        'paths./api/pages/{id}.get.responses.404.description') <> '',
        'a path with a parameter answers 404');
      AssertEqual(ProblemMember(Json_,
        'paths./api/pages.get.responses.429.description'), '',
        'and there is no 429 while the limiter is off');

      AssertEqual(ProblemMember(Json_,
        'components.securitySchemes.bearerAuth.scheme'), 'bearer',
        'the security scheme is a bearer token');

      { **Both directions agree.** }
      Problems_ := D.Problems(R);
      if Length(Problems_) > 0 then
        for I := 0 to High(Problems_) do
          Fail('unexpected drift: ' + Problems_[I]);
      AssertEqual(Length(Problems_), 0, 'the document and the routes agree');
    finally
      D.Free;
    end;

    { The document follows what is actually wired up. }
    RateLimit.PerMinute(60);
    D := TOpenApi.Create;
    try
      OaDoc(D);
      Json_ := D.ToJson;
      AssertTrue(ProblemMember(Json_,
        'paths./api/pages.get.responses.429.description') <> '',
        'with the limiter running, 429 is in the document');
    finally
      D.Free;
      RateLimit.Off;
    end;

    { --- drift, both ways ------------------------------------------ }

    { A path described that is not a route. }
    D := TOpenApi.Create;
    try
      OaDocGhost(D);
      Problems_ := D.Problems(R);
      Found := False;
      for I := 0 to High(Problems_) do
        if Pos('DELETE /api/pages/:id', Problems_[I]) > 0 then
          Found := True;
      AssertTrue(Found, 'a described path that is not a route is reported');
    finally
      D.Free;
    end;

    { And the other way: a route under a covered path that nothing
      describes. One direction alone lets the other half rot. }
    R.Delete('/api/pages/:id', Ctl.Secret);
    D := TOpenApi.Create;
    try
      OaDoc(D);
      Problems_ := D.Problems(R);
      Found := False;
      for I := 0 to High(Problems_) do
        if (Pos('DELETE /api/pages/:id', Problems_[I]) > 0) and
           (Pos('nothing describes it', Problems_[I]) > 0) then
          Found := True;
      AssertTrue(Found, 'a route nobody described is reported too');
    finally
      D.Free;
    end;

    { A delete answers 204 with nothing in it. Returns would claim a
      body, and Answers would claim an error. }
    D := TOpenApi.Create;
    try
      OaDoc(D);
      D.Delete('/api/pages/:id').Summary('Remove one').NoContent;
      Json_ := D.ToJson;
      AssertEqual(ProblemMember(Json_,
        'paths./api/pages/{id}.delete.responses.204.description'), 'No Content',
        'NoContent is a 204');
      AssertEqual(ProblemMember(Json_,
        'paths./api/pages/{id}.delete.responses.204.content'), '',
        'with no body');
      AssertEqual(ProblemMember(Json_,
        'paths./api/pages/{id}.delete.responses.200.description'), '',
        'and not a 200 as well');
    finally
      D.Free;
    end;

    { A route outside the covered paths is nobody''s business. }
    D := TOpenApi.Create;
    try
      OaDoc(D);
      D.Delete('/api/pages/:id').Summary('now described');
      Problems_ := D.Problems(R);
      Found := False;
      for I := 0 to High(Problems_) do
        if Pos('/dashboard', Problems_[I]) > 0 then
          Found := True;
      AssertFalse(Found, 'a route outside the API is not asked about');
      AssertEqual(Length(Problems_), 0, 'and then nothing is left over');
    finally
      D.Free;
    end;

    { Saying nothing about which paths are the API is itself a problem:
      half a check that looks like a whole one. }
    D := TOpenApi.Create;
    try
      OaDocUncovered(D);
      Problems_ := D.Problems(R);
      Found := False;
      for I := 0 to High(Problems_) do
        if Pos('which paths are the API', Problems_[I]) > 0 then
          Found := True;
      AssertTrue(Found, 'a document that covers nothing says so');
    finally
      D.Free;
    end;
  finally
    RateLimit.Off;
    R.Free;
    Ctl.Free;
  end;
end;

{ ------------------------------------------------- what an error looks like -- }

{ The same routes, asked by a browser and by a program.

  A redirect with the errors in a flash is a browser mechanism from end to
  end: it needs somewhere to keep them between two requests, and a client
  that follows the redirect and then reads the page it lands on. An API
  client does neither. Before this it got a 302 to a page it never asked
  for, followed it, and the errors it needed went into a flash it never
  read -- so the failure arrived as a 200 with a sign-up form in it.

  The handler is the same either way. A controller that had to ask who is
  calling before it could report a validation failure would end up asking
  in every action, and one of them would forget. }
type
  TApiSignup = class(TModel)
  private
    FEmail: string;
    FDisplayName: string;
  published
    property Email: string read FEmail write FEmail;
    { Two words on purpose. Rules are written with the property name,
      errors come back keyed on the column -- and a one-word field cannot
      tell the two apart. }
    property DisplayName: string read FDisplayName write FDisplayName;
  public
    class procedure Describe(S: TSchema); override;
    procedure Rules(V: TValidator); override;
  end;

  TNegCtl = class
  public
    function Signup(Req: TRequest): TResponse;
    function OnlyGet(Req: TRequest): TResponse;
  end;

class procedure TApiSignup.Describe(S: TSchema);
begin
  S.Table('api_signups');
end;

procedure TApiSignup.Rules(V: TValidator);
begin
  V.Field('Email').Required.Email;
  V.Field('DisplayName').Required;
end;

function TNegCtl.Signup(Req: TRequest): TResponse;
var
  M: TApiSignup;
begin
  M := Req.Arena.New<TApiSignup>;
  Req.FillInto(M);
  if not M.Validate then
    Exit(BackWithErrors(M.Errors, '/signup'));
  Result := RespondText('saved');
end;

function TNegCtl.OnlyGet(Req: TRequest): TResponse;
begin
  Result := RespondText('yes');
end;

var
  NegR: TRouter;
  NegC: TNegCtl;
  NegK: TTestClient;

{ One member of a problem document, read through the real parser. A
  substring check would pass on a body that is not JSON at all, and that
  is exactly what is being ruled out. }
procedure NegSetup;
begin
  SetAppKey('Zm9vYmFyYmF6cXV1eGZvb2JhcmJhenF1dXhhYmM9');
  SetSessions(TSessionStore.Create(3600));
  NegC := TNegCtl.Create;
  NegR := TRouter.Create;
  NegR.Post('/signup', NegC.Signup);
  NegR.Get('/only-get', NegC.OnlyGet);
  UseSessions(NegR);
  NegK := TTestClient.Create(NegR);
end;

procedure NegRydd;
var
  Store_: TSessionStore;
begin
  NegK.Free;
  NegR.Free;
  NegC.Free;
  Store_ := Sessions;
  SetSessions(nil);
  Store_.Free;
  SetAppKey('');
end;

procedure TestApiErrorNegotiation;
var
  R: TResponse;
begin
  NegSetup;
  try
    { A browser posting a form. Unchanged: a redirect, and the errors go
      in the flash for the page it lands on. }
    R := NegK.WithHeader('Accept', 'text/html')
      .Post('/signup', 'email=&display_name=',
            'application/x-www-form-urlencoded');
    AssertEqual(R.StatusCode div 100, 3, 'a browser is still redirected');
    AssertEqual(R.HeaderValue('Location'), '/signup', 'back where it came from');

    { The same handler, asked by a program. }
    R := NegK.WithHeader('Accept', 'application/json')
      .Post('/signup', '{"email":"not-an-email"}');
    AssertStatus(R, 422, 'a JSON client gets 422, not a redirect');
    AssertEqual(R.HeaderValue('Location'), '',
      'and is not sent anywhere else');
    AssertContains(R.HeaderValue('Content-Type'), 'application/problem+json',
      'as a problem document');
    AssertEqual(ProblemMember(R, 'status'), '422', 'with the status in it');
    AssertEqual(ProblemMember(R, 'title'), 'Unprocessable Content',
      'and the title');

    { Keyed on the column name. Rules are written with the property name
      -- DisplayName -- and this is the one field where the two differ, so
      a mapping that quietly used the property name would show up here and
      nowhere else. }
    AssertEqual(ProblemMember(R, 'errors.display_name'),
      'display_name is required', 'the errors are keyed on the column');
    AssertEqual(ProblemMember(R, 'errors.email'),
      'email is not a valid email address', 'and every failing field is in');
    AssertEqual(ProblemMember(R, 'errors.DisplayName'), '',
      'not on the property name');
    AssertNotContains(R.Body.ToString, '<', 'no markup anywhere in it');

    { An Inertia client is neither of the two. It follows the redirect and
      reads props.errors off the page it lands on, which is the flash
      working as designed -- and it sends Accept: application/json while
      doing it. Answering that with 422 would break every Inertia form. }
    R := NegK.WithHeader('Accept', 'application/json')
      .WithHeader('X-Inertia', 'true')
      .Post('/signup', '{"email":""}');
    AssertEqual(R.StatusCode div 100, 3, 'an Inertia post is still a redirect');

    { The router answers 405 and 404 itself, and those negotiate too. }
    R := NegK.WithHeader('Accept', 'application/json').Post('/only-get', '{}');
    AssertStatus(R, 405, 'the wrong method is 405');
    AssertContains(R.HeaderValue('Content-Type'), 'application/problem+json',
      'as a problem document');
    AssertEqual(ProblemMember(R, 'title'), 'Method Not Allowed', 'titled');

    R := NegK.Post('/only-get', '{}', 'application/x-www-form-urlencoded');
    AssertEqual(R.Body.ToString, 'Method Not Allowed',
      'and a browser gets the text it always got');

    R := NegK.WithHeader('Accept', 'application/json').Get('/nowhere');
    AssertStatus(R, 404, 'a route that does not exist is 404');
    AssertEqual(ProblemMember(R, 'title'), 'Not Found', 'titled');
  finally
    NegRydd;
  end;
end;

{ ------------------------------------------------------------------ mail -- }

var
  NullT: TNullTransport;
  M: TMailer;

procedure TestMessageRenders;
var
  Msg: TMailMessage;
  Raw: string;
begin
  NullT := TNullTransport.Create;
  M := TMailer.Create(NullT, True);
  try
    M.SetDefaultFrom('no-reply@example.com', 'Askr');
    Msg := M.Message_
      .AddTo('ada@example.com', 'Ada Lovelace')
      .Subject('Kvittering')
      .Text('Thank you for your order.');
    M.Send(Msg);

    Raw := NullT.LastMessage;
    AssertContains(Raw, 'From: "Askr" <no-reply@example.com>', 'avsender');
    AssertContains(Raw, 'To: "Ada Lovelace" <ada@example.com>', 'the recipient');
    AssertContains(Raw, 'Subject: Kvittering', 'emne');
    AssertContains(Raw, 'Content-Type: text/plain; charset=utf-8', 'type');
    AssertContains(Raw, 'Thank you for your order.', 'innhold');
    AssertContains(Raw, 'Message-ID: <', 'message-id');
    AssertEqual(M.Sent, 1, 'counted as sent');
  finally
    M.Free;
  end;
end;

procedure TestMultipart;
var
  Raw: string;
begin
  NullT := TNullTransport.Create;
  M := TMailer.Create(NullT, True);
  try
    M.Send(M.Message_
      .From('a@b.no')
      .AddTo('c@d.no')
      .Subject('Both')
      .Text('plain text')
      .Html('<p>html</p>'));
    Raw := NullT.LastMessage;
    AssertContains(Raw, 'multipart/alternative', 'multipart when both are set');
    AssertContains(Raw, 'plain text', 'tekstdelen');
    AssertContains(Raw, '<p>html</p>', 'html-delen');
  finally
    M.Free;
  end;
end;

procedure TestBccSkjulesIHodet;
var
  Raw: string;
  Recipients: TStringArray;
  Msg: TMailMessage;
begin
  NullT := TNullTransport.Create;
  M := TMailer.Create(NullT, True);
  try
    Msg := M.Message_.From('a@b.no').AddTo('c@d.no')
      .Bcc('skjult@e.no').Subject('x').Text('y');
    Recipients := Msg.AllRecipients;
    AssertEqual(Length(Recipients), 2, 'bcc is in the recipient list');
    M.Send(Msg, False);
    Raw := NullT.LastMessage;
    AssertNotContains(Raw, 'skjult@e.no', 'but not in the head');
    Msg.Free;
  finally
    M.Free;
  end;
end;

procedure TestManglerAvsender;
var
  Msg: TMailMessage;
  Kastet: Boolean;
begin
  NullT := TNullTransport.Create;
  M := TMailer.Create(NullT, True);
  Msg := TMailMessage.Create;
  Kastet := False;
  try
    Msg.AddTo('c@d.no').Subject('x').Text('y');
    try
      Msg.Render;
    except
      on EMailError do
        Kastet := True;
    end;
    AssertTrue(Kastet, 'a message with no sender is rejected');
  finally
    Msg.Free;
    M.Free;
  end;
end;

{ ------------------------------------------------------------- resend -- }

{ The transport is never allowed to send anything real here. Everything
  goes through TFakeResendHttp, which keeps the JSON and answers with what
  the test queued — the same move as TFakeAiTransport. }
function NewResend(out H: TFakeResendHttp): TResendTransport;
begin
  H := TFakeResendHttp.Create;
  Result := TResendTransport.Create('re_test_nokkel');
  Result.UseHttp(H, True);
end;

procedure TestResendForm;
var
  T: TResendTransport;
  H: TFakeResendHttp;
  J: string;
begin
  T := NewResend(H);
  try
    H.Queue('{"id":"49a3999c-0ce1-4ea6-ab68-afcd6dc2e794"}', 200);
    T.Send(TMailMessage.Create
      .From('orders@example.com', 'Example, Inc.')
      .AddTo('customer@example.com', 'Ada Lovelace')
      .Cc('sales@example.com')
      .Bcc('audit@example.com')
      .Subject('Your order')
      .Text('Thank you.')
      .Html('<p>Thank you.</p>'));

    AssertEqual(H.Sent.Count, 1, 'one request');
    J := H.Sent[0];
    AssertContains(J, '"from":"\"Example, Inc.\" <orders@example.com>"',
      'a sender with a quoted name');
    AssertContains(J, '"to":["\"Ada Lovelace\" <customer@example.com>"]',
      'to er en liste');
    AssertContains(J, '"cc":["sales@example.com"]', 'cc');
    AssertContains(J, '"bcc":["audit@example.com"]', 'bcc');
    AssertContains(J, '"subject":"Your order"', 'emne');
    AssertContains(J, '"html":"<p>Thank you.</p>"', 'html');
    AssertContains(J, '"text":"Thank you."', 'tekst');
    AssertEqual(H.LastUrl, 'https://api.resend.com/emails', 'endepunkt');
    AssertEqual(H.LastApiKey, 're_test_nokkel', 'the key is handed to the HTTP layer');
    AssertEqual(T.LastId, '49a3999c-0ce1-4ea6-ab68-afcd6dc2e794',
      'id-en fra svaret');
    AssertEqual(T.Count, 1, 'counted as sent');
  finally
    T.Free;
  end;
end;

procedure TestResendReplyTo;
var
  T: TResendTransport;
  H: TFakeResendHttp;
  J: string;
begin
  T := NewResend(H);
  try
    H.Queue('{"id":"x"}', 200);
    T.Send(TMailMessage.Create
      .From('a@example.com')
      .AddTo('b@example.com')
      .Subject('s')
      .Text('t')
      .Header('Reply-To', 'one@example.com, two@example.com')
      .Header('X-Entity-Ref-ID', '42'));

    J := H.Sent[0];
    AssertContains(J, '"reply_to":["one@example.com","two@example.com"]',
      'reply_to becomes its own field, as a list');
    AssertContains(J, '"headers":{"X-Entity-Ref-ID":"42"}',
      'other heads land in headers');
    { Resend rejects Reply-To as a free header. If it is in both places,
      which one wins is arbitrary. }
    AssertNotContains(J, '"headers":{"Reply-To"',
      'reply-to is not also in headers');
  finally
    T.Free;
  end;
end;

procedure TestResendIngenHoder;
var
  T: TResendTransport;
  H: TFakeResendHttp;
begin
  T := NewResend(H);
  try
    H.Queue('{"id":"x"}', 200);
    T.Send(TMailMessage.Create.From('a@example.com').AddTo('b@example.com')
      .Subject('s').Text('t'));
    { An empty headers object is not wrong, but it says we are writing out
      keys we have nothing to fill. }
    AssertNotContains(H.Sent[0], '"headers"',
      'no headers key without heads');
    AssertNotContains(H.Sent[0], '"cc"', 'no cc without cc');
    AssertNotContains(H.Sent[0], '"html"', 'no html without html');
  finally
    T.Free;
  end;
end;

procedure TestResendIdempotens;
var
  T: TResendTransport;
  H: TFakeResendHttp;
  FirstByte: string;
begin
  T := NewResend(H);
  try
    H.Queue('{"id":"x"}', 200);
    T.Send(TMailMessage.Create.From('a@example.com').AddTo('b@example.com')
      .Subject('s').Text('t').Idempotency('order-1001-receipt'));
    AssertEqual(H.LastIdempotency, 'order-1001-receipt',
      'the caller''s key is used as it is');

    H.Queue('{"id":"y"}', 200);
    T.Send(TMailMessage.Create.From('a@example.com').AddTo('b@example.com')
      .Subject('s').Text('t'));
    FirstByte := H.LastIdempotency;
    AssertTrue(FirstByte <> '', 'with no key of its own the message id is used');
    AssertTrue(FirstByte <> 'order-1001-receipt',
      'and it is not the previous message''s');
  finally
    T.Free;
  end;
end;

procedure TestResendSameMessageSameKey;
var
  T: TResendTransport;
  H: TFakeResendHttp;
  M: TMailMessage;
  A, B: string;
begin
  { What makes a retry safe: the same message has to give the same key. If
    it does not, the recipient gets two emails from one job. }
  T := NewResend(H);
  M := TMailMessage.Create.From('a@example.com').AddTo('b@example.com')
    .Subject('s').Text('t');
  try
    H.Queue('{"id":"x"}', 200);
    T.Send(M);
    A := H.LastIdempotency;
    H.Queue('{"id":"x"}', 200);
    T.Send(M);
    B := H.LastIdempotency;
    AssertEqual(A, B, 'the same message gives the same idempotency key');
  finally
    M.Free;
    T.Free;
  end;
end;

procedure TestResendErrors;
var
  T: TResendTransport;
  H: TFakeResendHttp;
  Status: Integer;
  Name_: string;
  CanRetry, Kastet: Boolean;
begin
  T := NewResend(H);
  try
    H.Queue('{"statusCode":422,"message":"Invalid `to` field.",' +
      '"name":"validation_error"}', 422);
    Kastet := False;
    Status := 0;
    Name_ := '';
    CanRetry := True;
    try
      T.Send(TMailMessage.Create.From('a@example.com')
        .AddTo('b@example.com').Subject('s').Text('t'));
    except
      on E: EResendError do
      begin
        Kastet := True;
        Status := E.Status;
        Name_ := E.Name_;
        CanRetry := E.Retryable;
        AssertContains(E.Message, 'Invalid `to` field.',
          'the provider''s own text comes along');
        AssertContains(E.Message, 'validation_error', 'og typen');
      end;
    end;
    AssertTrue(Kastet, '422 kaster');
    AssertEqual(Status, 422, 'status');
    AssertEqual(Name_, 'validation_error', 'the type the way the API writes it');
    AssertTrue(not CanRetry, 'a validation error is not retried');
    AssertEqual(T.Count, 0, 'and is not counted as sent');
  finally
    T.Free;
  end;
end;

procedure TestResendRateLimit;
var
  T: TResendTransport;
  H: TFakeResendHttp;
  CanRetry: Boolean;
begin
  T := NewResend(H);
  try
    H.Queue('{"message":"Too many requests.",' +
      '"name":"rate_limit_exceeded"}', 429);
    CanRetry := False;
    try
      T.Send(TMailMessage.Create.From('a@example.com')
        .AddTo('b@example.com').Subject('s').Text('t'));
    except
      on E: EResendError do
        CanRetry := E.Retryable;
    end;
    AssertTrue(CanRetry, 'a rate limit can be retried');

    { A quota is not the same. It does not clear within any backoff a queue
      has, and belongs in the failed table where somebody sees it. }
    H.Queue('{"message":"Daily quota reached.",' +
      '"name":"daily_quota_exceeded"}', 429);
    CanRetry := True;
    try
      T.Send(TMailMessage.Create.From('a@example.com')
        .AddTo('b@example.com').Subject('s').Text('t'));
    except
      on E: EResendError do
        CanRetry := E.Retryable;
    end;
    AssertTrue(not CanRetry, 'a quota is not retried');

    H.Queue('{"message":"Something went wrong.",' +
      '"name":"application_error"}', 500);
    CanRetry := False;
    try
      T.Send(TMailMessage.Create.From('a@example.com')
        .AddTo('b@example.com').Subject('s').Text('t'));
    except
      on E: EResendError do
        CanRetry := E.Retryable;
    end;
    AssertTrue(CanRetry, '5xx can be retried');
  finally
    T.Free;
  end;
end;

procedure TestResendUkjentFeilform;
var
  T: TResendTransport;
  H: TFakeResendHttp;
  Msg: string;
begin
  { The field has had several names over time, and an error page can be
    HTML. Neither is to give an empty error message. }
  T := NewResend(H);
  try
    H.Queue('{"message":"nope","error_type":"invalid_parameter"}', 422);
    Msg := '';
    try
      T.Send(TMailMessage.Create.From('a@example.com')
        .AddTo('b@example.com').Subject('s').Text('t'));
    except
      on E: EResendError do
        Msg := E.Message;
    end;
    AssertContains(Msg, 'invalid_parameter', 'error_type is read too');

    H.Queue('<html><body>502 Bad Gateway</body></html>', 502);
    Msg := '';
    try
      T.Send(TMailMessage.Create.From('a@example.com')
        .AddTo('b@example.com').Subject('s').Text('t'));
    except
      on E: EResendError do
        Msg := E.Message;
    end;
    AssertContains(Msg, '502', 'the status comes along when the body is not JSON');
    AssertContains(Msg, 'Bad Gateway', 'and what the server actually wrote');
  finally
    T.Free;
  end;
end;

procedure TestResendEmptyBody;
var
  T: TResendTransport;
  H: TFakeResendHttp;
  Kastet: Boolean;
begin
  T := NewResend(H);
  try
    Kastet := False;
    try
      T.Send(TMailMessage.Create.From('a@example.com')
        .AddTo('b@example.com').Subject('s'));
    except
      on E: EMailError do
        Kastet := True;
    end;
    AssertTrue(Kastet, 'a message with no text and no html is rejected before the network');
    AssertEqual(H.Sent.Count, 0, 'and nothing was sent');
  finally
    T.Free;
  end;
end;

procedure TestResendLekkerIkkeNoekkel;
var
  T: TResendTransport;
  H: TFakeResendHttp;
begin
  T := NewResend(H);
  try
    AssertNotContains(T.Describe, 're_test_nokkel',
      'Describe does not show the key');
    AssertContains(T.Describe, 'resend', 'but says which transport it is');
  finally
    T.Free;
  end;
end;

procedure TestMailFraConfig;
const
  Directory = 'askr-mailcfg-test.tmp';
var
  T: TMailTransport;
  L: TStringList;
  Kastet: Boolean;
  Msg: string;
begin
  { The default is the log file. Without it a project with no setup would
    have tried to send real mail in development. }
  T := MailFromConfig;
  try
    AssertTrue(T is TLogTransport, 'with no setup the transport is log');
  finally
    T.Free;
  end;

  ForceDirectories(Directory);
  L := TStringList.Create;
  try
    L.Add('[mail]');
    L.Add('transport = "sendgrid"');
    L.SaveToFile(Directory + PathDelim + 'askr.toml');
  finally
    L.Free;
  end;

  Kastet := False;
  Msg := '';
  ClearConfig;
  try
    LoadConfig(Directory);
    try
      T := MailFromConfig;
      T.Free;
    except
      on E: EMailError do
      begin
        Kastet := True;
        Msg := E.Message;
      end;
    end;
  finally
    ClearConfig;
    DeleteFile(Directory + PathDelim + 'askr.toml');
    RemoveDir(Directory);
  end;

  { Not a silent fall back to log. A typo in production would then have
    looked like the mail going out. }
  AssertTrue(Kastet, 'an unknown transport name raises');
  AssertContains(Msg, 'sendgrid', 'the error says what was asked for');
  AssertContains(Msg, 'resend',
    'and the list mentions resend, which is linked in here');
end;

{ A server that keeps the whole request and answers the way Resend does.

  It exists because TFakeResendHttp skips exactly the layer that puts the
  headers on the wire: a mutation that deleted Idempotency-Key went through
  the entire suite with nothing to say so. Here the bytes that were
  actually sent are read. }
type
  TResendEkkoServer = class(TThread)
  private
    FLytt: TSocket;
    FPort: Word;
    FRequest: string;
  protected
    procedure Execute; override;
  public
    constructor Create;
    property Port: Word read FPort;
    property Request: string read FRequest;
  end;

constructor TResendEkkoServer.Create;
var
  Addr: TInetSockAddr;
  Len: TSockLen;
  Ja: Integer;
begin
  FLytt := fpSocket(AF_INET, SOCK_STREAM, 0);
  Ja := 1;
  fpSetSockOpt(FLytt, SOL_SOCKET, SO_REUSEADDR, @Ja, SizeOf(Ja));
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_addr.s_addr := HToNL($7F000001);
  Addr.sin_port := 0;
  fpBind(FLytt, @Addr, SizeOf(Addr));
  fpListen(FLytt, 4);
  Len := SizeOf(Addr);
  fpGetSockName(FLytt, @Addr, @Len);
  FPort := NToHS(Addr.sin_port);
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TResendEkkoServer.Execute;
var
  S: TSocket;
  Reply: string;
  N: ssize_t;
  Buf: array[0..8191] of Byte;
begin
  S := fpAccept(FLytt, nil, nil);
  if S >= 0 then
  begin
    N := fpRecv(S, @Buf[0], SizeOf(Buf), 0);
    if N > 0 then
    begin
      SetLength(FRequest, N);
      Move(Buf[0], FRequest[1], N);
    end;
    Reply := '{"id":"ekko-1"}';
    Reply := 'HTTP/1.1 200 OK'#13#10 +
      'Content-Type: application/json'#13#10 +
      'Content-Length: ' + IntToStr(Length(Reply)) + #13#10 +
      'Connection: close'#13#10#13#10 + Reply;
    fpSend(S, PChar(Reply), Length(Reply), 0);
    CloseSocket(S);
  end;
  CloseSocket(FLytt);
end;

procedure TestResendPaaLufta;
var
  Srv: TResendEkkoServer;
  T: TResendTransport;
  R: string;
begin
  Srv := TResendEkkoServer.Create;
  try
    T := TResendTransport.Create('re_hemmelig_nokkel');
    try
      T.BaseUrl := 'http://127.0.0.1:' + IntToStr(Srv.Port);
      T.Send(TMailMessage.Create.From('a@example.com')
        .AddTo('b@example.com').Subject('s').Text('t')
        .Idempotency('job-77'));
      AssertEqual(T.LastId, 'ekko-1', 'the id is read out of a real reply');
    finally
      T.Free;
    end;
    Srv.WaitFor;
    R := Srv.Request;

    AssertContains(R, 'POST /emails HTTP/1.1', 'the method and the path');
    { The decisive part: both headers are to actually be in the bytes. }
    AssertContains(R, 'Authorization: Bearer re_hemmelig_nokkel',
      'the key goes as a Bearer');
    AssertContains(R, 'Idempotency-Key: job-77',
      'the idempotency key is in the head, not only in the code');
    AssertContains(R, 'Content-Type: application/json', 'innholdstypen');
    AssertContains(R, '"subject":"s"', 'the body came along');
  finally
    Srv.Free;
  end;
end;

{ An SMTP server that says what it can do and writes down the
  conversation.

  It exists for the AUTH path. The password goes over this connection, and
  it is the one piece of code in the mail unit where a mistake does not
  merely give an email that does not arrive — it gives away the
  password. }
type
  TSmtpEkkoServer = class(TThread)
  private
    FLytt: TSocket;
    FPort: Word;
    FTranscript: string;
    FAuthLine: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const AAuthLine: string);
    property Port: Word read FPort;
    property Transcript: string read FTranscript;
  end;

constructor TSmtpEkkoServer.Create(const AAuthLine: string);
var
  Addr: TInetSockAddr;
  Len: TSockLen;
  Ja: Integer;
begin
  FAuthLine := AAuthLine;
  FLytt := fpSocket(AF_INET, SOCK_STREAM, 0);
  Ja := 1;
  fpSetSockOpt(FLytt, SOL_SOCKET, SO_REUSEADDR, @Ja, SizeOf(Ja));
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_addr.s_addr := HToNL($7F000001);
  Addr.sin_port := 0;
  fpBind(FLytt, @Addr, SizeOf(Addr));
  fpListen(FLytt, 4);
  Len := SizeOf(Addr);
  fpGetSockName(FLytt, @Addr, @Len);
  FPort := NToHS(Addr.sin_port);
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TSmtpEkkoServer.Execute;
var
  S: TSocket;
  Line_: string;
  C: Char;
  N: ssize_t;
  IData: Boolean;
  AuthSteg: Integer;

  procedure Si(const Sv: string);
  var
    Ut: string;
  begin
    Ut := Sv + #13#10;
    fpSend(S, PChar(Ut), Length(Ut), 0);
  end;

begin
  S := fpAccept(FLytt, nil, nil);
  if S < 0 then
  begin
    CloseSocket(FLytt);
    Exit;
  end;
  Si('220 ekko.example ESMTP');
  IData := False;
  AuthSteg := 0;
  Line_ := '';
  repeat
    N := fpRecv(S, @C, 1, 0);
    if N <= 0 then
      Break;
    if C = #13 then
      Continue;
    if C <> #10 then
    begin
      Line_ := Line_ + C;
      Continue;
    end;

    FTranscript := FTranscript + Line_ + #10;

    if IData then
    begin
      if Line_ = '.' then
      begin
        IData := False;
        Si('250 2.0.0 Ok: queued');
      end;
    end
    else if Copy(UpperCase(Line_), 1, 4) = 'EHLO' then
    begin
      Si('250-ekko.example');
      if FAuthLine <> '' then
        Si('250-' + FAuthLine);
      Si('250 SIZE 35651584');
    end
    else if Copy(UpperCase(Line_), 1, 4) = 'AUTH' then
    begin
      if Copy(UpperCase(Line_), 1, 10) = 'AUTH LOGIN' then
      begin
        AuthSteg := 1;
        Si('334 VXNlcm5hbWU6');
      end
      else
        Si('235 2.7.0 Authentication successful');
    end
    else if AuthSteg = 1 then
    begin
      AuthSteg := 2;
      Si('334 UGFzc3dvcmQ6');
    end
    else if AuthSteg = 2 then
    begin
      AuthSteg := 0;
      Si('235 2.7.0 Authentication successful');
    end
    else if Copy(UpperCase(Line_), 1, 4) = 'QUIT' then
    begin
      Si('221 Bye');
      Break;
    end
    else if Copy(UpperCase(Line_), 1, 4) = 'DATA' then
    begin
      IData := True;
      Si('354 End data with <CR><LF>.<CR><LF>');
    end
    else
      Si('250 2.1.0 Ok');
    Line_ := '';
  until False;
  CloseSocket(S);
  CloseSocket(FLytt);
end;

procedure SendWithAuth(Srv: TSmtpEkkoServer; const User_, Passord: string;
  Tillat: Boolean);
var
  T: TSmtpTransport;
  Msg: TMailMessage;
begin
  T := TSmtpTransport.Create('127.0.0.1', Srv.Port, smtpPlain);
  Msg := TMailMessage.Create;
  try
    T.AllowPlainAuth := Tillat;
    T.Credentials(User_, Passord);
    Msg.From('a@example.com').AddTo('b@example.com').Subject('s').Text('t');
    T.Send(Msg);
  finally
    Msg.Free;
    T.Free;
  end;
end;

procedure TestSmtpAuthPlain;
var
  Srv: TSmtpEkkoServer;
begin
  Srv := TSmtpEkkoServer.Create('AUTH PLAIN LOGIN');
  try
    SendWithAuth(Srv, 'resend', 're_hemmelig', True);
    Srv.WaitFor;
    { SASL PLAIN is #0user#0password in base64. Worked out by hand here, so
      that the test checks the encoding rather than repeating the code. }
    AssertContains(Srv.Transcript, 'AUTH PLAIN AHJlc2VuZAByZV9oZW1tZWxpZw==',
      'AUTH PLAIN with the right SASL encoding');
    AssertContains(Srv.Transcript, 'MAIL FROM:<a@example.com>',
      'and the send continues afterwards');
  finally
    Srv.Free;
  end;
end;

procedure TestSmtpAuthLogin;
var
  Srv: TSmtpEkkoServer;
begin
  { Only LOGIN offered. Without this branch an older relay would have got
    an AUTH PLAIN it does not understand. }
  Srv := TSmtpEkkoServer.Create('AUTH LOGIN');
  try
    SendWithAuth(Srv, 'bruker', 'passord', True);
    Srv.WaitFor;
    AssertContains(Srv.Transcript, 'AUTH LOGIN', 'faller til LOGIN');
    AssertNotContains(Srv.Transcript, 'AUTH PLAIN',
      'and does not try the PLAIN it does not offer');
    AssertContains(Srv.Transcript, 'YnJ1a2Vy', 'brukernavnet i base64');
    AssertContains(Srv.Transcript, 'cGFzc29yZA==', 'passordet i base64');
  finally
    Srv.Free;
  end;
end;

procedure TestSmtpAuthKreverKryptering;
var
  Srv: TSmtpEkkoServer;
  Kastet: Boolean;
  Msg: string;
begin
  { The most important thing in the whole AUTH path: the password must not
    go in the clear unless somebody has said so explicitly. }
  Srv := TSmtpEkkoServer.Create('AUTH PLAIN LOGIN');
  Kastet := False;
  Msg := '';
  try
    try
      SendWithAuth(Srv, 'bruker', 'passord', False);
    except
      on E: EMailError do
      begin
        Kastet := True;
        Msg := E.Message;
      end;
    end;
    AssertTrue(Kastet, 'AUTH over cleartext is stopped');
    AssertContains(Msg, 'in the clear', 'and says why');
    AssertNotContains(Msg, 'passord', 'without repeating the password');
    AssertNotContains(Srv.Transcript, 'AUTH', 'nothing was sent');
  finally
    Srv.Free;
  end;
end;

procedure TestSmtpAuthUkjentMekanisme;
var
  Srv: TSmtpEkkoServer;
  Kastet: Boolean;
begin
  { XOAUTH2-LOGIN contains "LOGIN" as a substring. A raw search would have
    said yes and sent AUTH LOGIN to a server that does not have it. }
  Srv := TSmtpEkkoServer.Create('AUTH XOAUTH2-LOGIN CRAM-MD5');
  Kastet := False;
  try
    try
      SendWithAuth(Srv, 'bruker', 'passord', True);
    except
      on E: EMailError do
        Kastet := True;
    end;
    AssertTrue(Kastet, 'no mechanism we can do is an error, not an attempt');
    AssertNotContains(Srv.Transcript, 'AUTH LOGIN',
      'the substring XOAUTH2-LOGIN does not count as LOGIN');
  finally
    Srv.Free;
  end;
end;

procedure TestSmtpWithoutUser;
var
  Srv: TSmtpEkkoServer;
begin
  { No username: no AUTH, and no complaint. A relay on loopback often has
    none. }
  Srv := TSmtpEkkoServer.Create('AUTH PLAIN LOGIN');
  try
    SendWithAuth(Srv, '', '', False);
    Srv.WaitFor;
    AssertNotContains(Srv.Transcript, 'AUTH', 'no AUTH without a username');
    AssertContains(Srv.Transcript, 'MAIL FROM:', 'but the mail goes');
  finally
    Srv.Free;
  end;
end;

{ ------------------------------------------- testklienten mot en ruter -- }

type
  TDemoCtrl = class
  public
    function Index(Req: TRequest): TResponse;
    function Vis(Req: TRequest): TResponse;
    function Save(Req: TRequest): TResponse;
  end;

function TDemoCtrl.Index(Req: TRequest): TResponse;
begin
  Result := RespondJson('{"liste":[1,2,3]}');
end;

function TDemoCtrl.Vis(Req: TRequest): TResponse;
begin
  Result := RespondText('id=' + Req.Param('id').ToString);
end;

function TDemoCtrl.Save(Req: TRequest): TResponse;
begin
  Result := RespondText('got ' + IntToStr(Req.Body.Len) + ' bytes', 201);
end;

var
  DemoR: TRouter;
  DemoC: TDemoCtrl;
  Client: TTestClient;

{ The welcome page is the first thing anybody sees of a new project, and
  it has to work without npm, without a network and without files next to
  the binary. If it breaks quietly, it is noticed the first time somebody
  tries the framework. }
type
  TVelkomstCtrl = class
  public
    function Index(Req: TRequest): TResponse;
    function Fiendtlig(Req: TRequest): TResponse;
  end;

function TVelkomstCtrl.Index(Req: TRequest): TResponse;
begin
  Result := WelcomePage(Req, 'shop');
end;

{ Prosjektnavnet kommer fra kommandolinja og er brukerkontrollert. }
function TVelkomstCtrl.Fiendtlig(Req: TRequest): TResponse;
begin
  Result := WelcomePage(Req, '<script>alert(1)</script>');
end;

var
  VelkomstR: TRouter;
  VelkomstC: TVelkomstCtrl;

procedure TestVelkomstside;
var
  R: TResponse;
  Body_: string;
begin
  VelkomstC := TVelkomstCtrl.Create;
  VelkomstR := TRouter.Create;
  VelkomstR.Get('/', VelkomstC.Index);
  VelkomstR.Get('/fiendtlig', VelkomstC.Fiendtlig);
  with TTestClient.Create(VelkomstR) do
  try
    R := Get('/');
    AssertStatus(R, 200, 'the welcome page answers');
    Body_ := R.Body.ToString;
    AssertTrue(Pos('<!doctype html>', Body_) = 1, 'er et HTML-dokument');
    AssertTrue(Pos('shop', Body_) > 0, 'the project name is in it');

    { The readout is to be real numbers from the arena, not
      placeholders. }
    AssertTrue(Pos('This request', Body_) > 0, 'the arena readout is there');
    AssertTrue(Pos('this worker reserved once', Body_) > 0,
      'the gauge is explained');
    { The bar widths have to be valid CSS whatever the locale — a comma
      here would make them invalid on a machine with Norwegian
      settings. }
    AssertTrue(Pos('--w:', Body_) > 0, 'the bar has a width');
    AssertTrue(Pos(',%', Body_) = 0, 'the width uses a full stop, not a comma');
    { The page is the first thing an international audience sees, and is to
      be in English. }
    AssertTrue(Pos('lang="en"', Body_) > 0, 'the page is marked as English');

    { Nothing is fetched from outside. A machine with no network is to see
      the same thing. }
    AssertTrue(Pos('http://', Body_) = 0, 'no external resources');
    AssertTrue(Pos('https://', Body_) = 0, 'nor over https');
    AssertTrue(Pos('<script', Body_) = 0, 'no scripts');

    { Both light and dark theme, and it has to be readable on a phone. }
    AssertTrue(Pos('prefers-color-scheme', Body_) > 0, 'both themes');
    AssertTrue(Pos('name="viewport"', Body_) > 0, 'viewport-meta');

    { The name is user-controlled and has to be escaped. }
    R := Get('/fiendtlig');
    Body_ := R.Body.ToString;
    AssertTrue(Pos('&lt;script&gt;', Body_) > 0, 'the project name is escaped');
    AssertTrue(Pos('<script', Body_) = 0, 'and does not pass through raw');
  finally
    Free;
    VelkomstR.Free;
    VelkomstC.Free;
  end;
end;

{ .env is where secrets end up. Two things have to hold whatever else
  changes: real environment variables win over the file, and no error
  message contains a value. }
procedure TestEnv;
const
  FileName_ = 'askr-env-test.tmp';
var
  L: TStringList;
  Err, Name_: string;
  I: Integer;
begin
  L := TStringList.Create;
  try
    L.Add('# en kommentar');
    L.Add('');
    L.Add('SIMPLE=hello');
    L.Add('export EXPORTED=yes');
    L.Add('QUOTED="a b  c"');
    L.Add('ESCAPED="line1\nline2"');
    L.Add('LITERAL=''raw \n stays''');
    L.Add('TRAILING=value   # a comment');
    L.Add('HASHPASS=pa#ssword');
    L.Add('EMPTY=');
    L.Add('NUMBER=42');
    L.Add('FLAG=true');
    L.Add('OFFFLAG=no');
    L.Add('PATH_LIKE=/usr/local/bin');
    L.Add('SPACED_KEY = spaced');
    L.SaveToFile(FileName_);
  finally
    L.Free;
  end;

  ClearEnv;
  try
    LoadEnv(FileName_);

    AssertEqual(Env('SIMPLE'), 'hello', 'a simple value');
    AssertEqual(Env('EXPORTED'), 'yes', 'an export prefix is stripped');
    AssertEqual(Env('QUOTED'), 'a b  c', 'quotes keep the spaces');
    AssertEqual(Env('ESCAPED'), 'line1'#10'line2', 'escapes in double quotes');
    AssertEqual(Env('LITERAL'), 'raw \n stays',
      'single quotes are literal');
    AssertEqual(Env('TRAILING'), 'value', 'a comment after the value is cut');
    AssertEqual(Env('HASHPASS'), 'pa#ssword',
      'a # with no space before it is part of the value');
    AssertEqual(Env('EMPTY'), '', 'tom verdi');
    AssertEqual(Env('PATH_LIKE'), '/usr/local/bin', 'a path with slashes');
    AssertEqual(Env('SPACED_KEY'), 'spaced', 'spaces around = are tolerated');

    AssertEqual(EnvInt('NUMBER'), 42, 'EnvInt');
    AssertEqual(EnvInt('MISSING', 7), 7, 'EnvInt with a default');
    AssertTrue(EnvBool('FLAG'), 'EnvBool reads true');
    AssertFalse(EnvBool('OFFFLAG'), 'EnvBool reads no as false');
    AssertTrue(EnvBool('MISSING', True), 'EnvBool with a default');
    AssertEqual(Env('MISSING', 'fallback'), 'fallback', 'Env with a default');

    AssertTrue(EnvHas('EMPTY'), 'EnvHas sees an empty value');
    AssertFalse(EnvHas('NOT_THERE'), 'EnvHas does not see what is not there');

    { The decisive part: the environment wins. A value set by systemd or
      docker must never be overridable by a file left lying in the
      directory. }
    AssertEqual(Env('HOME') <> '', True, 'HOME is in the environment');
    AssertEqual(Env('SIMPLE'), 'hello', 'the file is used when the environment is empty');

    { EnvOrFail is to be safe to leave in a stack trace. }
    Err := '';
    try
      EnvOrFail('NOT_THERE');
    except
      on E: EEnvError do Err := E.Message;
    end;
    AssertTrue(Pos('NOT_THERE', Err) > 0, 'the error names the key');
    AssertTrue(Pos('hello', Err) = 0, 'and leaks no values');
    AssertTrue(Pos('pa#ssword', Err) = 0, 'nor the password');
    AssertTrue(Pos(FileName_, Err) > 0, 'but says where it looked');

    AssertEqual(EnvOrFail('SIMPLE'), 'hello', 'EnvOrFail gives the value when it is there');
    { EnvKeys gives names, not values — it is for diagnostics and has to be
      printable without leaking anything. }
    Name_ := '';
    for I := 0 to High(EnvKeys) do
      Name_ := Name_ + EnvKeys[I] + ' ';
    AssertTrue(Pos('SIMPLE', Name_) > 0, 'EnvKeys mentions SIMPLE');
    AssertTrue(Pos('HASHPASS', Name_) > 0, 'EnvKeys mentions HASHPASS');
    AssertTrue(Pos('pa#ssword', Name_) = 0, 'but no values');
  finally
    ClearEnv;
    DeleteFile(FileName_);
  end;
end;

procedure TestClientAgainstRouter;
var
  R: TResponse;
begin
  DemoC := TDemoCtrl.Create;
  DemoR := TRouter.Create;
  DemoR.Get('/ting', DemoC.Index);
  DemoR.Get('/ting/:id', DemoC.Vis);
  DemoR.Post('/ting', DemoC.Save);
  Client := TTestClient.Create(DemoR);
  try
    R := Client.Get('/ting');
    AssertStatus(R, 200, 'GET /ting');
    AssertEqual(R.Body.ToString, '{"liste":[1,2,3]}', 'kroppen');

    R := Client.Get('/ting/42');
    AssertEqual(R.Body.ToString, 'id=42', 'ruteparameter');

    R := Client.Post('/ting', '{"a":1}');
    AssertStatus(R, 201, 'POST gir 201');
    AssertEqual(R.Body.ToString, 'got 7 bytes', 'the body arrived');

    R := Client.Delete('/ting');
    AssertStatus(R, 405, 'an unknown method gives 405');

    R := Client.Get('/finnes-ikke');
    AssertStatus(R, 404, 'an unknown path gives 404');
  finally
    Client.Free;
    DemoR.Free;
    DemoC.Free;
  end;
end;

{ Run by AssertArenaStable. }
procedure EnRequest;
begin
  Client.Get('/ting/7');
end;

procedure TestArenaFlaterUt;
begin
  DemoC := TDemoCtrl.Create;
  DemoR := TRouter.Create;
  DemoR.Get('/ting/:id', DemoC.Vis);
  Client := TTestClient.Create(DemoR);
  try
    AssertArenaStable(Client.Arena, @EnRequest, 300,
      'the arena levels off over 300 requests');
  finally
    Client.Free;
    DemoR.Free;
    DemoC.Free;
  end;
end;


{ ----------------------------------------------------------------- CSRF -- }

type
  { A form endpoint and a webhook endpoint. The GET handler returns the
    token in the body, the way a real page would put it in a hidden field —
    the token is made only when something asks for it. }
  TCsrfCtl = class
    function Vis(Req: TRequest): TResponse;
    function Save(Req: TRequest): TResponse;
    function Webhook(Req: TRequest): TResponse;
    { An Inertia page that asks for nothing, and a reply that is not a
      page at all. }
    function InertiaPage(Req: TRequest): TResponse;
    function Plain(Req: TRequest): TResponse;
  end;

type
  { A handler that refuses, and one that breaks. }
  TRefuseCtl = class
    function Refuse(Req: TRequest): TResponse;
    function Break_(Req: TRequest): TResponse;
  end;

function TRefuseCtl.Refuse(Req: TRequest): TResponse;
begin
  raise EForbidden.Create('Not authorized: scope things:write');
end;

function TRefuseCtl.Break_(Req: TRequest): TResponse;
begin
  raise Exception.Create('a real fault');
end;

{ **A refusal a handler raises is an answer, and the after-filters run.**
  The router answers it now, so a test sees the 403 the server would send
  -- before, it came out of the test as an exception. A real fault still
  raises, and the filters ran on the way out: ReleaseDb is one, and every
  refusal used to keep its pooled connection. }
var
  AfterRuns: Integer;

function CountAfter(Req: TRequest; Res: TResponse): TResponse;
begin
  Inc(AfterRuns);
  Result := Res;
end;

procedure TestClientAnswersRefusals;
var
  R: TRouter;
  C: TRefuseCtl;
  K: TTestClient;
  Res: TResponse;
  Raised: Boolean;
begin
  C := TRefuseCtl.Create;
  R := TRouter.Create;
  R.Get('/refuse', C.Refuse);
  R.Get('/break', C.Break_);
  R.After(@CountAfter);
  K := TTestClient.Create(R);
  try
    AfterRuns := 0;
    Res := K.Get('/refuse');
    AssertEqual(Res.StatusCode, 403, 'a refusal is a 403, not an exception');
    AssertEqual(AfterRuns, 1, 'and the after-filters ran on it');
    AssertNotContains(Res.Body.ToString, 'things:write',
      'and its message stays out of the reply, as on the server');
    Res := K.WithHeader('Accept', 'application/json').Get('/refuse');
    AssertContains(Res.HeaderValue('Content-Type'), 'application/problem+json',
      'a program gets a problem document');
    Raised := False;
    try
      K.Get('/break');
    except
      on E: Exception do
        Raised := E.Message = 'a real fault';
    end;
    AssertTrue(Raised, 'a real fault still raises');
    AssertEqual(AfterRuns, 3, 'after the filters ran on the way out');
  finally
    K.Free;
    R.Free;
    C.Free;
  end;
end;

function TCsrfCtl.InertiaPage(Req: TRequest): TResponse;
begin
  Result := Inertia('Things/Add', []);
end;

function TCsrfCtl.Plain(Req: TRequest): TResponse;
begin
  Result := RespondText('ok', 200);
end;

function TCsrfCtl.Vis(Req: TRequest): TResponse;
begin
  Result := RespondText(CsrfToken, 200);
end;

function TCsrfCtl.Save(Req: TRequest): TResponse;
begin
  Result := RespondText('lagret', 200);
end;

function TCsrfCtl.Webhook(Req: TRequest): TResponse;
begin
  Result := RespondText('mottatt', 200);
end;

{ Picks one named Set-Cookie out of the reply. Returns the whole
  directive, not only the value, so that HttpOnly can be checked. }
function SetCookieLine(R: TResponse; A: TArena; const Name_: string): string;
var
  B: TStrBuilder;
  Raw: string;
  P, Slutt: Integer;
begin
  B.Init(A, 8192);
  R.WriteTo(B, False, False);
  Raw := B.ToString;
  P := Pos('Set-Cookie: ' + Name_ + '=', Raw);
  if P = 0 then
    Exit('');
  Inc(P, Length('Set-Cookie: '));
  Slutt := P;
  while (Slutt <= Length(Raw)) and (Raw[Slutt] <> #13) do
    Inc(Slutt);
  Result := Copy(Raw, P, Slutt - P);
end;

function CookieValue(const Line_: string): string;
var
  P, Q3: Integer;
begin
  P := Pos('=', Line_);
  if P = 0 then
    Exit('');
  Inc(P);
  Q3 := P;
  while (Q3 <= Length(Line_)) and (Line_[Q3] <> ';') do
    Inc(Q3);
  Result := Copy(Line_, P, Q3 - P);
end;

function SetCookieCount(R: TResponse; A: TArena): Integer;
var
  B: TStrBuilder;
  Raw: string;
  P: Integer;
begin
  B.Init(A, 8192);
  R.WriteTo(B, False, False);
  Raw := B.ToString;
  Result := 0;
  P := Pos('Set-Cookie: ', Raw);
  while P > 0 do
  begin
    Inc(Result);
    P := PosEx('Set-Cookie: ', Raw, P + 1);
  end;
end;

var
  CsrfR: TRouter;
  CsrfC: TCsrfCtl;
  CsrfK: TTestClient;
  CsrfExemptSet: Boolean = False;

{ Builds an app with sessions and CSRF wired up, the way a real app does
  it: SetSessions, UseSessions, UseCsrf. }
procedure CsrfSetup;
begin
  { The exception list is global and is to be written only once.
    Registering it again for every test would do no harm, but a list that
    grows with each setup is not what anybody wants to read while
    debugging. }
  if not CsrfExemptSet then
  begin
    CsrfExempt('/webhooks/*');
    CsrfExemptSet := True;
  end;
  SetSessions(TSessionStore.Create(3600));
  CsrfC := TCsrfCtl.Create;
  CsrfR := TRouter.Create;
  CsrfR.Get('/form', CsrfC.Vis);
  CsrfR.Post('/form', CsrfC.Save);
  CsrfR.Post('/webhooks/stripe', CsrfC.Webhook);
  CsrfR.Get('/page', CsrfC.InertiaPage);
  CsrfR.Get('/plain', CsrfC.Plain);
  UseSessions(CsrfR);
  UseCsrf(CsrfR);
  CsrfK := TTestClient.Create(CsrfR);
end;

procedure CsrfRydd;
var
  Store: TSessionStore;
begin
  CsrfK.Free;
  CsrfR.Free;
  CsrfC.Free;
  Store := Sessions;
  SetSessions(nil);
  Store.Free;
end;

{ Fetches a session with a token in it, and gives back both the cookie
  and the token. That is exactly what a browser does when it loads the page
  with the form. }
procedure FetchTokenAndCookie(out Cookie_, Token: string);
var
  Res: TResponse;
begin
  Res := CsrfK.Get('/form');
  Token := Res.Body.ToString;
  Cookie_ := CookieValue(SetCookieLine(Res, CsrfK.Arena, 'askr_session'));
end;

procedure TestCsrfAvviserUtenToken;
var
  Res: TResponse;
  Cookie_, Token: string;
begin
  CsrfSetup;
  try
    FetchTokenAndCookie(Cookie_, Token);

    { GET is never checked: by definition it is not to change anything. }
    Res := CsrfK.WithHeader('Cookie', 'askr_session=' + Cookie_).Get('/form');
    AssertEqual(Res.StatusCode, 200, 'GET passes without a token');

    Res := CsrfK.WithHeader('Cookie', 'askr_session=' + Cookie_)
      .Post('/form', '{}');
    AssertEqual(Res.StatusCode, 419, 'POST without a token is rejected');

    Res := CsrfK.WithHeader('Cookie', 'askr_session=' + Cookie_)
      .WithHeader('X-CSRF-Token', 'helt feil').Post('/form', '{}');
    AssertEqual(Res.StatusCode, 419, 'POST with a wrong token is rejected');
    AssertEqual(Res.Body.ToString, 'CSRF token missing or invalid.',
      'and told in the words it has always used');

    { The same rejection, asked for by a program. 419 is not in any RFC --
      it is what the Inertia client recognises and reloads on -- but the
      body still has to be something a program can read, and the rule
      about not saying what was expected is unchanged. }
    Res := CsrfK.WithHeader('Cookie', 'askr_session=' + Cookie_)
      .WithHeader('Accept', 'application/json').Post('/form', '{}');
    AssertEqual(Res.StatusCode, 419, 'a JSON client is rejected too');
    AssertContains(Res.HeaderValue('Content-Type'), 'application/problem+json',
      'as a problem document');
    AssertNotContains(Res.Body.ToString, Token,
      'and the expected token is still not in it');

    { Without a session there is nothing to compare against. Then the
      answer is no — not "yes, because there is no expectation". }
    Res := CsrfK.WithHeader('X-CSRF-Token', Token).Post('/form', '{}');
    AssertEqual(Res.StatusCode, 419, 'the right token with no session is rejected');
  finally
    CsrfRydd;
  end;
end;

procedure TestCsrfGodtarAlleTreKilder;
var
  Res: TResponse;
  Cookie_, Token: string;
begin
  CsrfSetup;
  try
    FetchTokenAndCookie(Cookie_, Token);
    AssertTrue(Token <> '', 'the token was made');
    AssertTrue(Cookie_ <> '', 'the session cookie was set');

    { 1. The form field, the way an ordinary HTML form sends it. }
    Res := CsrfK.WithHeader('Cookie', 'askr_session=' + Cookie_)
      .Post('/form', '_token=' + Token,
        'application/x-www-form-urlencoded');
    AssertEqual(Res.StatusCode, 200, 'the form field _token is accepted');

    { 2. X-CSRF-Token, which fetch and XHR add themselves. }
    Res := CsrfK.WithHeader('Cookie', 'askr_session=' + Cookie_)
      .WithHeader('X-CSRF-Token', Token).Post('/form', '{}');
    AssertEqual(Res.StatusCode, 200, 'the header X-CSRF-Token is accepted');

    { 3. X-XSRF-Token, which axios and Inertia mirror from the XSRF-TOKEN
      cookie. }
    Res := CsrfK.WithHeader('Cookie', 'askr_session=' + Cookie_)
      .WithHeader('X-XSRF-Token', Token).Post('/form', '{}');
    AssertEqual(Res.StatusCode, 200, 'the header X-XSRF-Token is accepted');
  finally
    CsrfRydd;
  end;
end;

procedure TestCsrfTokenStablePerSession;
var
  Res: TResponse;
  Cookie1, Token1, Cookie2, Token2: string;
begin
  CsrfSetup;
  try
    FetchTokenAndCookie(Cookie1, Token1);

    { The same session, a new call: the same token. A token that changed on
      every request would invalidate every open tab. }
    Res := CsrfK.WithHeader('Cookie', 'askr_session=' + Cookie1).Get('/form');
    AssertEqual(Res.Body.ToString, Token1, 'the same session gives the same token');

    { A new session: a new token — and the old one must not work there. }
    FetchTokenAndCookie(Cookie2, Token2);
    AssertTrue(Cookie1 <> Cookie2, 'to sesjoner');
    AssertTrue(Token1 <> Token2, 'and two different tokens');

    Res := CsrfK.WithHeader('Cookie', 'askr_session=' + Cookie2)
      .WithHeader('X-CSRF-Token', Token1).Post('/form', '{}');
    AssertEqual(Res.StatusCode, 419,
      'a token from another session is rejected');
  finally
    CsrfRydd;
  end;
end;

procedure TestCsrfUnntakForWebhooks;
var
  Res: TResponse;
begin
  CsrfSetup;
  try
    { A webhook comes from a third party that cannot possibly have the
      token. The exception is a hole made on purpose, and that is why it is
      tested that it exists — and that it does not apply beyond the path it
      was written for. }
    Res := CsrfK.Post('/webhooks/stripe', '{}');
    AssertEqual(Res.StatusCode, 200, 'an excepted path passes');

    Res := CsrfK.Post('/form', '{}');
    AssertEqual(Res.StatusCode, 419, 'but the rest is still protected');
  finally
    CsrfRydd;
  end;
end;

procedure TestCsrfCookiesSideBySide;
var
  Res: TResponse;
  Session_, Xsrf: string;
  Cookie_, Token: string;
begin
  CsrfSetup;
  try
    FetchTokenAndCookie(Cookie_, Token);
    Res := CsrfK.WithHeader('Cookie', 'askr_session=' + Cookie_).Get('/form');

    { Before AddHeader the response let the last value win per header name,
      and the second cookie would have overwritten the first. Two cookies
      in one reply is the whole reason CSRF needed that change. }
    AssertEqual(SetCookieCount(Res, CsrfK.Arena), 2,
      'both cookies are in the reply');

    Session_ := SetCookieLine(Res, CsrfK.Arena, 'askr_session');
    Xsrf := SetCookieLine(Res, CsrfK.Arena, 'XSRF-TOKEN');
    AssertTrue(Session_ <> '', 'the session cookie is there');
    AssertTrue(Xsrf <> '', 'XSRF-kaka er der');

    { The session cookie is what authenticates, and JavaScript must not
      reach it. The XSRF cookie is only a copy of something that is in the
      page's markup anyway, and has to be readable for axios to mirror it
      back. }
    AssertTrue(Pos('HttpOnly', Session_) > 0, 'the session cookie is HttpOnly');
    AssertEqual(Pos('HttpOnly', Xsrf), 0, 'XSRF-kaka er lesbar for JS');
    AssertEqual(CookieValue(Xsrf), Token, 'the XSRF cookie carries the token');
  finally
    CsrfRydd;
  end;
end;

{ **An Inertia page makes the token.** The client sends only what the
  XSRF-TOKEN cookie holds, and the cookie is set only once the token
  exists. Before this nothing on an Inertia page asked for it, so a new
  visitor's first POST from a Lauf <Form> answered 419 -- and the client
  meets 419 by reloading, which asked for nothing either. Found by
  driving a generated resource in Chrome. }
procedure TestCsrfInertiaPage;
var
  Res: TResponse;
  Session_, Xsrf: string;
begin
  CsrfSetup;
  try
    Res := CsrfK.AsInertia.Get('/page');
    AssertEqual(Res.StatusCode, 200, 'the page answers');
    Xsrf := CookieValue(SetCookieLine(Res, CsrfK.Arena, 'XSRF-TOKEN'));
    Session_ := CookieValue(SetCookieLine(Res, CsrfK.Arena, 'askr_session'));
    AssertTrue(Xsrf <> '', 'a first visit to an Inertia page gets the XSRF cookie');
    AssertTrue(Session_ <> '', 'and the session it belongs to');

    Res := CsrfK.WithHeader('Cookie', 'askr_session=' + Session_)
      .WithHeader('X-XSRF-Token', Xsrf).AsInertia.Post('/form', '{}');
    AssertEqual(Res.StatusCode, 200,
      'so the POST the Inertia client then makes is accepted');

    { The full page, the first request of all, does the same. }
    Res := CsrfK.Get('/page');
    AssertTrue(SetCookieLine(Res, CsrfK.Arena, 'XSRF-TOKEN') <> '',
      'the HTML shell of a first visit sets it too');

    { And what is not a page still costs nothing. }
    Res := CsrfK.Get('/plain');
    AssertEqual(SetCookieCount(Res, CsrfK.Arena), 0,
      'a reply that is not a page makes no token and no session');
  finally
    CsrfRydd;
  end;
end;

{ ----------------------------------------------------------------- auth -- }

type
  { The app's user model. The point is precisely that the framework does
    not know it: it stores an id as text, and the app looks up the
    rest. }
  TUser = class
    Name_: string;
    ErAdmin: Boolean;
  end;

  TAuthCtl = class
    function HvemErJeg(Req: TRequest): TResponse;
    function LoggInn(Req: TRequest): TResponse;
    function LoggInnHusk(Req: TRequest): TResponse;
    function LoggUt(Req: TRequest): TResponse;
    function Port(Req: TRequest): TResponse;
    function Hidden(Req: TRequest): TResponse;
    function Ta(Req: TRequest): TResponse;
  end;

var
  Brukere: array[0..1] of TUser;
  LastOppKalt: Integer = 0;

function FindUser(const AId: string): TObject;
begin
  Inc(LastOppKalt);
  if AId = '1' then
    Exit(Brukere[0]);
  if AId = '2' then
    Exit(Brukere[1]);
  Result := nil;
end;

function KanRedigere(const UserId: string; Resource: TObject): Boolean;
begin
  { A gate sees only the id and the resource. Everything else is the app's
    business. }
  Result := UserId = '1';
end;

function ErAdminGate(const UserId: string; Resource: TObject): Boolean;
var
  B: TObject;
begin
  B := FindUser(UserId);
  Result := (B <> nil) and TUser(B).ErAdmin;
end;

function TAuthCtl.HvemErJeg(Req: TRequest): TResponse;
var
  Reply: string;
begin
  if Askr.Auth.Check then
    Reply := 'inne:' + Askr.Auth.Id
  else
    Reply := 'out';
  Result := RespondText(Reply, 200);
end;

function TAuthCtl.LoggInn(Req: TRequest): TResponse;
begin
  Askr.Auth.Login(Req.Form('id').ToString);
  Result := RespondText('ok', 200);
end;

function TAuthCtl.LoggInnHusk(Req: TRequest): TResponse;
begin
  Askr.Auth.Login(Req.Form('id').ToString, True);
  Result := RespondText('ok', 200);
end;

function TAuthCtl.LoggUt(Req: TRequest): TResponse;
begin
  Askr.Auth.Logout;
  Result := RespondText('ok', 200);
end;

function TAuthCtl.Port(Req: TRequest): TResponse;
var
  Reply: string;
begin
  Reply := '';
  if Allows('edit') then Reply := Reply + 'edit ';
  if Allows('admin') then Reply := Reply + 'admin ';
  if Allows('does-not-exist') then Reply := Reply + 'ukjent ';
  if User <> nil then Reply := Reply + 'user:' + TUser(User).Name_;
  Result := RespondText(Trim(Reply), 200);
end;

function TAuthCtl.Hidden(Req: TRequest): TResponse;
begin
  Result := RespondText('hemmelig', 200);
end;

{ Writes to the session, and so forces it to be stored. A session nobody
  has written to gets neither a slot in the store nor a cookie — and
  without a real session before signing in, the fixation test tests
  nothing. }
function TAuthCtl.Ta(Req: TRequest): TResponse;
begin
  CurrentSession.Put('handlekurv', '3');
  Result := RespondText('tatt', 200);
end;

var
  AuthR: TRouter;
  AuthC: TAuthCtl;
  AuthK: TTestClient;

procedure AuthSetup(MedKrav: Boolean);
begin
  SetAppKey('Zm9vYmFyYmF6cXV1eGZvb2JhcmJhenF1dXhhYmM9');
  SetSessions(TSessionStore.Create(3600));
  SetUserLoader(FindUser);
  DefineGate('edit', KanRedigere);
  DefineGate('admin', ErAdminGate);

  AuthC := TAuthCtl.Create;
  AuthR := TRouter.Create;
  AuthR.Get('/me', AuthC.HvemErJeg);
  AuthR.Post('/login', AuthC.LoggInn);
  AuthR.Post('/login-husk', AuthC.LoggInnHusk);
  AuthR.Post('/logout', AuthC.LoggUt);
  AuthR.Get('/gate', AuthC.Port);
  AuthR.Get('/skjult', AuthC.Hidden);
  AuthR.Get('/touch', AuthC.Ta);
  UseSessions(AuthR);
  UseAuth(AuthR);
  if MedKrav then
    RequireAuth(AuthR, '/login');
  AuthK := TTestClient.Create(AuthR);
end;

procedure AuthRydd;
var
  Store: TSessionStore;
begin
  AuthK.Free;
  AuthR.Free;
  AuthC.Free;
  Store := Sessions;
  SetSessions(nil);
  Store.Free;
  SetAppKey('');
end;

function Sesjonskake(R: TResponse): string;
begin
  Result := CookieValue(SetCookieLine(R, AuthK.Arena, 'askr_session'));
end;

procedure TestAuthInnOgUt;
var
  Res: TResponse;
  Cookie1, Cookie2: string;
begin
  AuthSetup(False);
  try
    Res := AuthK.Get('/me');
    AssertEqual(Res.Body.ToString, 'out', 'nobody is signed in');
    AssertEqual(Sesjonskake(Res), '',
      'a session nobody wrote to is not stored');

    { A real session before signing in — that is the one to be replaced. }
    Res := AuthK.Get('/touch');
    Cookie1 := Sesjonskake(Res);
    AssertTrue(Cookie1 <> '', 'a session that was written to gets a cookie');

    Res := AuthK.WithHeader('Cookie', 'askr_session=' + Cookie1)
      .Post('/login', 'id=1', 'application/x-www-form-urlencoded');
    Cookie2 := Sesjonskake(Res);

    { Session fixation: the id MUST be a different one after signing in.
      Without this an attacker who got your cookie set beforehand would be
      signed in as you. }
    AssertTrue(Cookie2 <> Cookie1, 'the session id was changed on sign-in');
    AssertTrue(Cookie2 <> '', 'and a new one was set');

    Res := AuthK.WithHeader('Cookie', 'askr_session=' + Cookie2).Get('/me');
    AssertEqual(Res.Body.ToString, 'inne:1', 'the user is signed in');

    { The old id must no longer give access. }
    Res := AuthK.WithHeader('Cookie', 'askr_session=' + Cookie1).Get('/me');
    AssertEqual(Res.Body.ToString, 'out', 'the old id is dead');

    Res := AuthK.WithHeader('Cookie', 'askr_session=' + Cookie2)
      .Post('/logout', '');
    Cookie1 := Sesjonskake(Res);
    Res := AuthK.WithHeader('Cookie', 'askr_session=' + Cookie1).Get('/me');
    AssertEqual(Res.Body.ToString, 'out', 'utlogget');
  finally
    AuthRydd;
  end;
end;

procedure TestAuthHuskMeg;
var
  Res: TResponse;
  Cookie_, Husk, Tuklet: string;
begin
  AuthSetup(False);
  try
    Res := AuthK.Get('/touch');
    Cookie_ := Sesjonskake(Res);
    Res := AuthK.WithHeader('Cookie', 'askr_session=' + Cookie_)
      .Post('/login-husk', 'id=2', 'application/x-www-form-urlencoded');
    Husk := CookieValue(SetCookieLine(Res, AuthK.Arena, 'askr_remember'));
    AssertTrue(Husk <> '', 'the remember cookie was set');
    AssertTrue(Pos('.', Husk) > 0, 'den er signert');

    { Without a session cookie — as after the browser has been closed — but
      with the remember cookie: the user is to get back in. }
    Res := AuthK.WithHeader('Cookie', 'askr_remember=' + Husk).Get('/me');
    AssertEqual(Res.Body.ToString, 'inne:2', 'the remember cookie signed in again');

    { And it is to give a fresh session, not reuse one. }
    AssertTrue(Sesjonskake(Res) <> '', 'a new session was started');

    { A tampered signature: rejected. This is the whole reason the cookie is
      signed — without it anybody could have written "1|..." themselves. }
    Tuklet := StringReplace(Husk, '2|', '1|', []);
    Res := AuthK.WithHeader('Cookie', 'askr_remember=' + Tuklet).Get('/me');
    AssertEqual(Res.Body.ToString, 'out', 'a tampered remember cookie is rejected');

    { Expired, but correctly signed. The expiry is inside the signed part
      precisely so that a client which keeps the cookie too long does not
      get in. }
    Tuklet := Sign('2|' + IntToStr(UnixNow - 60));
    Res := AuthK.WithHeader('Cookie', 'askr_remember=' + Tuklet).Get('/me');
    AssertEqual(Res.Body.ToString, 'out', 'an expired remember cookie is rejected');

    { Utlogging sletter kaka. }
    Res := AuthK.WithHeader('Cookie', 'askr_remember=' + Husk)
      .Post('/logout', '');
    AssertTrue(Pos('Max-Age=0',
      SetCookieLine(Res, AuthK.Arena, 'askr_remember')) > 0,
      'signing out clears the remember cookie');
  finally
    AuthRydd;
  end;
end;

procedure TestAuthGates;
var
  Res: TResponse;
  Cookie_: string;
  Status_: Integer;
begin
  AuthSetup(False);
  try
    { Ingen innlogget: alt er nei. }
    Res := AuthK.Get('/gate');
    AssertEqual(Res.Body.ToString, '', 'with nobody signed in the gates say no');

    Res := AuthK.Get('/touch');
    Cookie_ := Sesjonskake(Res);
    Res := AuthK.WithHeader('Cookie', 'askr_session=' + Cookie_)
      .Post('/login', 'id=1', 'application/x-www-form-urlencoded');
    Cookie_ := Sesjonskake(Res);

    Res := AuthK.WithHeader('Cookie', 'askr_session=' + Cookie_).Get('/gate');
    { User 1 can edit and is an admin. "does-not-exist" is not defined, and
      an undefined gate is to answer no — a typo is to close the door. }
    AssertEqual(Res.Body.ToString, 'edit admin user:Ada',
      'the gates answer, and an unknown gate says no');
    AssertTrue(GateExists('edit'), 'the gate is there');
    AssertFalse(GateExists('does-not-exist'), 'and another one is not');

    { User 2 is not an admin and cannot edit. }
    Res := AuthK.Get('/touch');
    Cookie_ := Sesjonskake(Res);
    Res := AuthK.WithHeader('Cookie', 'askr_session=' + Cookie_)
      .Post('/login', 'id=2', 'application/x-www-form-urlencoded');
    Cookie_ := Sesjonskake(Res);
    Res := AuthK.WithHeader('Cookie', 'askr_session=' + Cookie_).Get('/gate');
    AssertEqual(Res.Body.ToString, 'user:Grace',
      'another user gets no on both');

    { **Authorize tells the two refusals apart.** Signed in and not
      allowed is a 403; nobody signed in at all is a 401, because the
      caller can do something about that one and a 403 does not tell
      them to. The gate says no either way, so the difference has to be
      looked at separately -- which is why it was wrong here until an
      API gate drove it. }
    Status_ := 0;
    try
      Authorize('admin');
    except
      on E: EAuthError do
        Status_ := E.HttpStatus;
    end;
    AssertEqual(Status_, 401,
      'outside a request, with nobody signed in, it is a 401');
  finally
    AuthRydd;
  end;
end;

procedure TestAuthRequire;
var
  Res: TResponse;
  Cookie_: string;
begin
  AuthSetup(True);
  try
    { An ordinary browser is to go to the sign-in page. }
    Res := AuthK.Get('/skjult');
    AssertEqual(Res.StatusCode, 302, 'with nobody signed in it is a redirect');
    AssertEqual(Res.HeaderValue('Location'), '/login', 'til innloggingen');

    { An Inertia client would have followed the redirect and got HTML
      where it expected JSON. 401 is what it can act on. }
    Res := AuthK.WithHeader('X-Inertia', 'true').Get('/skjult');
    AssertEqual(Res.StatusCode, 401, 'an Inertia request gets 401');

    Res := AuthK.WithHeader('X-Inertia', 'true').Get('/skjult');
    AssertContains(Res.HeaderValue('Content-Type'), 'text/plain',
      'as text, because its client reads the status and not the body');

    Res := AuthK.WithHeader('Accept', 'application/json').Get('/skjult');
    AssertEqual(Res.StatusCode, 401, 'and a JSON request too');
    AssertContains(Res.HeaderValue('Content-Type'), 'application/problem+json',
      'as a problem document, like every other error it can be handed');
    AssertEqual(Res.HeaderValue('Location'), '',
      'and never a redirect to a sign-in page');

    { Signed in, it passes. The sign-in route is itself behind the
      requirement here, so the session has to be made through a request
      that is not — /login is a POST, and RequireAuth closes that too.
      Hence signing in with a client without the requirement. }
    AuthRydd;
    AuthSetup(False);
    Res := AuthK.Get('/touch');
    Cookie_ := Sesjonskake(Res);
    Res := AuthK.WithHeader('Cookie', 'askr_session=' + Cookie_)
      .Post('/login', 'id=1', 'application/x-www-form-urlencoded');
    Cookie_ := Sesjonskake(Res);
    Res := AuthK.WithHeader('Cookie', 'askr_session=' + Cookie_).Get('/skjult');
    AssertEqual(Res.Body.ToString, 'hemmelig', 'signed in, it passes');
  finally
    AuthRydd;
  end;
end;

procedure TestAuthBrukeroppslagCaches;
var
  Res: TResponse;
  Cookie_: string;
  Before: Integer;
begin
  AuthSetup(False);
  try
    Res := AuthK.Get('/touch');
    Cookie_ := Sesjonskake(Res);
    Res := AuthK.WithHeader('Cookie', 'askr_session=' + Cookie_)
      .Post('/login', 'id=1', 'application/x-www-form-urlencoded');
    Cookie_ := Sesjonskake(Res);

    { /gate calls User and the admin gate, both of which look the user up.
      The loader is to be called once for User — the admin gate does its
      own lookup on purpose, to show that a gate can. }
    Before := LastOppKalt;
    Res := AuthK.WithHeader('Cookie', 'askr_session=' + Cookie_).Get('/gate');
    AssertEqual(Res.StatusCode, 200, 'the page answered');
    AssertTrue(LastOppKalt - Before <= 2,
      'the user is not looked up again for every call');
  finally
    AuthRydd;
  end;
end;


{ ------------------------------------------------------- logg og config -- }

{ There is no portable way to set an environment variable that FPC's
  GetEnvironmentVariable sees. libc's setenv works on Darwin and **not** on
  Linux, where the RTL reads envp from start-up. So "the environment wins"
  is tested against a variable that is already there — HOME — rather than
  against one the test sets itself. }
function MakeFile(const Path_: string; const Lines: array of string): Boolean;
var
  L: TStringList;
  I: Integer;
begin
  L := TStringList.Create;
  try
    for I := 0 to High(Lines) do
      L.Add(Lines[I]);
    L.SaveToFile(Path_);
    Result := True;
  finally
    L.Free;
  end;
end;

var
  LogLines: TStringList;

{ Its own sink, so that the test can read the lines rather than having
  to capture stderr. It is also the demonstration that SetLogSink works. }
procedure CollectLine(const Line: string);
begin
  LogLines.Add(Line);
end;

procedure LogSetup;
begin
  LogLines := TStringList.Create;
  SetLogSink(CollectLine);
  SetLogLevel(llDebug);
  SetLogFormat(lfText);
end;

procedure LoggRydd;
begin
  SetLogSink(nil);
  SetLogLevel(llInfo);
  SetLogFormat(lfText);
  LogLines.Free;
end;

procedure TestLoggNivaa;
begin
  LogSetup;
  try
    SetLogLevel(llWarn);
    LogDebug('d');
    LogInfo('i');
    LogWarn('w');
    LogError('e');
    AssertEqual(LogLines.Count, 2, 'only warn and error got through');
    AssertTrue(Pos('WARN', LogLines[0]) > 0, 'the level is in the line');
    AssertTrue(Pos('ERROR', LogLines[1]) > 0, 'and for error too');

    AssertFalse(LogEnabled(llInfo), 'LogEnabled says no below the threshold');
    AssertTrue(LogEnabled(llError), 'og ja over');

    { llNone is not a level to log at, it is a ceiling. }
    LogLines.Clear;
    SetLogLevel(llNone);
    LogError('not even this one');
    AssertEqual(LogLines.Count, 0, 'llNone turns the log off entirely');
  finally
    LoggRydd;
  end;
end;

procedure TestLoggTekstformat;
var
  L: string;
begin
  LogSetup;
  try
    LogInfo('request', ['method', 'GET', 'path', '/a b', 'status', 200]);
    AssertEqual(LogLines.Count, 1, 'én linje');
    L := LogLines[0];
    AssertTrue(Pos('INFO', L) > 0, 'the level');
    AssertTrue(Pos('request', L) > 0, 'melding');
    AssertTrue(Pos('method=GET', L) > 0, 'a field with no space is unquoted');
    { A value with a space has to be quoted, or it is read as two
      fields. }
    AssertTrue(Pos('path="/a b"', L) > 0, 'a value with a space is quoted');
    AssertTrue(Pos('status=200', L) > 0, 'tall');
    { The timestamp is ISO 8601 in UTC. Local time would make the log
      unsortable twice a year. }
    AssertTrue(Pos('T', L) > 0, 'a timestamp with a T');
    AssertTrue(Pos('Z ', L) > 0, 'og Z for UTC');

    { A field with no value must not knock anything over. }
    LogLines.Clear;
    LogInfo('rar', ['alene']);
    AssertEqual(LogLines.Count, 1, 'a key with no value is logged anyway');
  finally
    LoggRydd;
  end;
end;

procedure TestLoggJson;
var
  L: string;
begin
  LogSetup;
  try
    SetLogFormat(lfJson);
    LogInfo('request', ['method', 'GET', 'status', 200, 'ok', True,
      'ms', Int64(17)]);
    L := LogLines[0];
    AssertTrue(Pos('"level":"info"', L) > 0, 'the level as a field');
    AssertTrue(Pos('"msg":"request"', L) > 0, 'the message as a field');
    AssertTrue(Pos('"method":"GET"', L) > 0, 'streng siteres');
    { Numbers and booleans are to be unquoted, or nobody can compute with
      them. }
    AssertTrue(Pos('"status":200', L) > 0, 'numbers are unquoted');
    AssertTrue(Pos('"ms":17', L) > 0, 'and int64 too');
    AssertTrue(Pos('"ok":true', L) > 0, 'a boolean is unquoted');
    AssertEqual(L[1], '{', 'linja er et JSON-objekt');
    AssertEqual(L[Length(L)], '}', 'and it is closed');

    { Quotes and line breaks in a value have to be escaped, or the line is
      no longer JSON — and a log collector discards the whole file. }
    LogLines.Clear;
    LogWarn('rar', ['tekst', 'han sa "hei"' + #10 + 'og gikk']);
    L := LogLines[0];
    AssertTrue(Pos('\"hei\"', L) > 0, 'quotes are escaped');
    AssertTrue(Pos('\n', L) > 0, 'line breaks are escaped');
    AssertEqual(Pos(#10, L), 0, 'and no real line break is left');
  finally
    LoggRydd;
  end;
end;

procedure TestLoggException;
var
  L: string;
begin
  LogSetup;
  try
    SetLogFormat(lfJson);
    try
      raise EConfigError.Create('something went wrong');
    except
      on E: Exception do
        LogException(E, 'while saving', ['id', 7]);
    end;
    AssertEqual(LogLines.Count, 1, 'én linje');
    L := LogLines[0];
    { The class and the message are separate fields, not free text. That is
      the difference between being able to group by error type and having
      to grep. }
    AssertTrue(Pos('"class":"EConfigError"', L) > 0, 'klassen er et felt');
    AssertTrue(Pos('"error":"something went wrong"', L) > 0, 'meldingen er et felt');
    AssertTrue(Pos('"msg":"while saving"', L) > 0, 'the context is the message');
    AssertTrue(Pos('"id":7', L) > 0, 'and the caller''s fields are there');
  finally
    LoggRydd;
  end;
end;

procedure TestLogToFile;
var
  Path_: string;
  L: TStringList;
begin
  Path_ := '.build/logg-test.log';
  DeleteFile(Path_);
  try
    SetLogLevel(llInfo);
    SetLogFormat(lfText);
    SetLogFile(Path_);
    LogInfo('til fil', ['n', 1]);
    LogInfo('and one more', ['n', 2]);
    { The file is closed when the sink is changed, and then everything is
      written. }
    SetLogFile('');

    L := TStringList.Create;
    try
      L.LoadFromFile(Path_);
      AssertEqual(L.Count, 2, 'both lines landed in the file');
      AssertTrue(Pos('n=1', L[0]) > 0, 'the first line');
      AssertTrue(Pos('n=2', L[1]) > 0, 'andre linje');
    finally
      L.Free;
    end;

    { Reopening is to append, not truncate. A restart must not wipe out the
      previous run's log. }
    SetLogFile(Path_);
    LogInfo('after a restart');
    SetLogFile('');
    L := TStringList.Create;
    try
      L.LoadFromFile(Path_);
      AssertEqual(L.Count, 3, 'the third was appended');
    finally
      L.Free;
    end;
  finally
    SetLogFile('');
    DeleteFile(Path_);
  end;
end;

procedure TestConfigLayers;
var
  L: TStringList;
  Folder: string;
begin
  Folder := '.build/cfg-test';
  ForceDirectories(Folder);
  L := TStringList.Create;
  try
    L.Add('name = "demo"');
    L.Add('units = "app"');
    L.Add('[app]');
    L.Add('port = 8080');
    L.Add('tom =');
    L.SaveToFile(Folder + '/askr.toml');
    L.Clear;
    L.Add('APP_PORT=9000');
    L.Add('DATABASE_URL=sqlite:demo.db');
    { HOME is already in the environment. By setting it to something else
      here, the file and the environment disagree — and then it can be
      tested which one wins. }
    L.Add('HOME=/helt/feil');
    L.SaveToFile(Folder + '/.env');
  finally
    L.Free;
  end;

  try
    ClearConfig;
    LoadConfig(Folder);

    AssertEqual(Cfg('name'), 'demo', 'top level from askr.toml');
    { .env beats askr.toml: app.port is looked up as APP_PORT, and that is
      in .env with 9000 while the file says 8080. }
    AssertEqual(CfgInt('app.port'), 9000, '.env vinner over askr.toml');
    AssertTrue(CfgSource('app.port') = csDotEnv, 'and the source says so');
    AssertEqual(Cfg('units'), 'app', 'a key with no section');
    AssertEqual(CfgInt('app.backend_port', 8081), 8081,
      'the default when nobody has set anything');
    AssertEqual(Cfg('database.url'), 'sqlite:demo.db',
      'a full stop becomes an underscore in the environment name');

    { A key with an empty value is to be there, not disappear. That is
      precisely where TStringList.Values behaves differently on 3.2.2 and
      3.3.1. }
    AssertTrue(CfgHas('app.tom'), 'an empty value in askr.toml is there anyway');

    { Real environment variables win over both files. This is the rule the
      whole layer rests on: a deployment has to be able to set something
      without a file in the repository changing. }
    AssertTrue(GetEnvironmentVariable('HOME') <> '',
      'HOME is in the environment');
    AssertEqual(Cfg('home'), GetEnvironmentVariable('HOME'),
      'the environment beats .env');
    AssertTrue(CfgSource('home') = csEnvironment, 'and the source says so');

    AssertEqual(EnvNameFor('app.backend_port'), 'APP_BACKEND_PORT',
      'a key name to an environment name');

    { CfgOrFail names the key and the environment variable, never a
      value. }
    try
      CfgOrFail('does.not.exist');
      AssertTrue(False, 'CfgOrFail should have raised');
    except
      on E: EConfigError do
      begin
        AssertTrue(Pos('does.not.exist', E.Message) > 0, 'the key is named');
        AssertTrue(Pos('DOES_NOT_EXIST', E.Message) > 0,
          'and the environment variable that would set it');
        AssertEqual(Pos('sqlite:demo.db', E.Message), 0,
          'no value leaks out');
      end;
    end;
  finally
    ClearConfig;
    DeleteFile(Folder + '/askr.toml');
    DeleteFile(Folder + '/.env');
    RemoveDir(Folder);
  end;
end;

procedure TestConfigReport;
var
  L: TStringList;
  Folder, Report: string;
begin
  Folder := '.build/cfg-rapport';
  ForceDirectories(Folder);
  L := TStringList.Create;
  try
    L.Add('DATABASE_URL=postgresql://user:secret@host/db');
    L.Add('APP_ENV=local');
    L.Add('MAIL_FROM=post@example.com');
    L.SaveToFile(Folder + '/.env');
  finally
    L.Free;
  end;

  try
    ClearConfig;
    LoadConfig(Folder);

    { Without --values the report is to be safe to paste anywhere. }
    Report := ConfigReport(False);
    AssertTrue(Pos('DATABASE_URL', Report) > 0, 'the key is there');
    AssertEqual(Pos('hemmelig', Report), 0, 'but no value');
    AssertEqual(Pos('post@example.com', Report), 0, 'nor this one');

    { With --values the values are shown, but not the ones that look like
      secrets. }
    Report := ConfigReport(True);
    AssertTrue(Pos('post@example.com', Report) > 0,
      'a harmless value is shown');
    AssertEqual(Pos('hemmelig', Report), 0,
      'but a DSN with a password in it is still hidden');
    AssertTrue(Pos('(hidden)', Report) > 0, 'and it says that it is');

    AssertTrue(LooksSecret('DATABASE_URL'), 'URL counts as a secret');
    AssertTrue(LooksSecret('APP_KEY'), 'og KEY');
    AssertTrue(LooksSecret('smtp_password'), 'og PASSWORD');
    AssertFalse(LooksSecret('APP_ENV'), 'but not APP_ENV');
  finally
    ClearConfig;
    DeleteFile(Folder + '/.env');
    RemoveDir(Folder);
  end;
end;

procedure TestMiljoe;
const
  FileName_ = '.build/miljoe-test/.env';
var
  Folder: string;
begin
  Folder := '.build/miljoe-test';
  ForceDirectories(Folder);
  try
    { APP_ENV is set in .env and not in the process environment, because
      the latter cannot be done portably. Env() reads both, so the layer
      under test is the same. }
    ClearEnv;
    MakeFile(FileName_, ['# tom']);
    LoadEnv(FileName_);
    AssertEqual(AppEnv, 'local', 'without APP_ENV we are local');
    AssertTrue(IsLocal, 'and IsLocal says so');
    AssertFalse(IsProduction, 'not production');

    ClearEnv;
    MakeFile(FileName_, ['APP_ENV=production']);
    LoadEnv(FileName_);
    AssertTrue(IsProduction, 'production');
    AssertFalse(IsLocal, 'and so not local');

    ClearEnv;
    MakeFile(FileName_, ['APP_ENV=prod']);
    LoadEnv(FileName_);
    AssertTrue(IsProduction, 'prod is the same');

    ClearEnv;
    MakeFile(FileName_, ['APP_ENV=TESTING']);
    LoadEnv(FileName_);
    AssertTrue(IsTesting, 'testing, whatever the case');

    { RequireEnv names every missing one at once, and no values. The point
      is the timing: without it a missing key is found on the first request
      that needs it. }
    ClearEnv;
    MakeFile(FileName_, ['FINNES=ja']);
    LoadEnv(FileName_);
    try
      RequireEnv(['FINNES', 'MANGLER_EN', 'MANGLER_TO']);
      AssertTrue(False, 'RequireEnv should have raised');
    except
      on E: EEnvError do
      begin
        AssertTrue(Pos('MANGLER_EN', E.Message) > 0, 'the first one missing');
        AssertTrue(Pos('MANGLER_TO', E.Message) > 0, 'and the second one');
        AssertEqual(Pos('FINNES', E.Message), 0,
          'the one that was there is not named');
        AssertEqual(Pos('ja', E.Message), 0, 'and no value leaks out');
      end;
    end;
    RequireEnv(['FINNES']);
  finally
    ClearEnv;
    DeleteFile(FileName_);
    RemoveDir(Folder);
  end;
end;


{ --------------------------------------------------- the durable queue -- }

var
  DurableLock: TRTLCriticalSection;
  DurableRan: Integer;
  DurableLast: string;
  DurableShouldFail: Boolean;

procedure DurableJob(const Ctx: TJobContext);
begin
  EnterCriticalSection(DurableLock);
  try
    Inc(DurableRan);
    DurableLast := Ctx.Payload.ToString;
  finally
    LeaveCriticalSection(DurableLock);
  end;
  if DurableShouldFail then
    raise Exception.Create('on purpose');
end;

function DurableDsn: string;
begin
  Result := 'sqlite:.build/queue-test.db';
end;

function NewStore: TDbJobStore;
begin
  Result := TDbJobStore.Create(DurableDsn, 4);
  { A fast poll, or the test waits a quarter of a second per job. A real
    app will not want 10 ms — that is 400 queries a second against an empty
    table with four workers. }
  Result.Poll := 10;
  Result.EnsureSchema;
end;

procedure DurableSetup;
begin
  DeleteFile('.build/queue-test.db');
  DeleteFile('.build/queue-test.db-wal');
  DeleteFile('.build/queue-test.db-shm');
  ForceDirectories('.build');
  DurableRan := 0;
  DurableLast := '';
  DurableShouldFail := False;
end;

procedure DurableClean;
begin
  DeleteFile('.build/queue-test.db');
  DeleteFile('.build/queue-test.db-wal');
  DeleteFile('.build/queue-test.db-shm');
end;

{ What it all turns on: the job is to still be there after the process
  that queued it is gone. }
procedure TestDurableSurvivesRestart;
var
  Storage: TDbJobStore;
  Q: TQueue;
begin
  DurableSetup;
  try
    { "The first run": queue three jobs, and exit without running them. }
    Storage := NewStore;
    Q := TQueue.Create(Storage, 2, 3, True);
    try
      AssertTrue(Q.Durable, 'the queue says it is durable');
      Q.Push('durable', 'en');
      Q.Push('durable', 'to');
      Q.Push('durable', 'tre');
      AssertEqual(Q.Pending, 3, 'three jobs in the table');
    finally
      { No Start, no drain: this is a process that dies. }
      Q.Free;
    end;

    { "The second run": a new process, a new store, the same file. }
    Storage := NewStore;
    Q := TQueue.Create(Storage, 2, 3, True);
    try
      AssertEqual(Q.Pending, 3, 'the jobs survived the queue going away');
      Q.Handle('durable', @DurableJob);
      Q.Start;
      AssertTrue(Q.WaitUntilEmpty(10000), 'and they ran now');
      Sleep(100);
      EnterCriticalSection(DurableLock);
      try
        AssertEqual(DurableRan, 3, 'all three, once each');
      finally
        LeaveCriticalSection(DurableLock);
      end;
      Q.Stop(True);
    finally
      Q.Free;
    end;
  finally
    DurableClean;
  end;
end;

procedure TestDurableFailsAndGivesUp;
var
  Storage: TDbJobStore;
  Q: TQueue;
begin
  DurableSetup;
  try
    Storage := NewStore;
    Q := TQueue.Create(Storage, 1, 2, False);
    try
      DurableShouldFail := True;
      Q.Handle('durable', @DurableJob);
      Q.Start;
      Q.Push('durable', 'this will go wrong');
      AssertTrue(Q.WaitUntilEmpty(10000), 'the job gave up in the end');
      Sleep(150);
      Q.Stop(False);

      AssertEqual(Q.Failed, 1, 'counted as failed');
      { The attempt counter is in the row, not in memory — it is to survive
        the process dying halfway. }
      EnterCriticalSection(DurableLock);
      try
        AssertEqual(DurableRan, 2, 'two attempts, as MaxAttempts says');
      finally
        LeaveCriticalSection(DurableLock);
      end;

      { A job that has given up is moved, not deleted. It is the only trace
        that something was supposed to happen and did not. }
      AssertEqual(Storage.FailedCount, 1, 'it is in the failed table');

      { And it can be put back once whatever was wrong has been fixed. }
      DurableShouldFail := False;
      DurableRan := 0;
      AssertEqual(Storage.RetryFailed, 1, 'RetryFailed moved it back');
      AssertEqual(Storage.FailedCount, 0, 'feiltabellen er tom');
      AssertEqual(Q.Pending, 1, 'and the job is in the queue again');

      Q.Start;
      AssertTrue(Q.WaitUntilEmpty(10000), 'it ran');
      Sleep(100);
      EnterCriticalSection(DurableLock);
      try
        AssertEqual(DurableLast, 'this will go wrong',
          'with the payload intact');
      finally
        LeaveCriticalSection(DurableLock);
      end;
      Q.Stop(True);
    finally
      Q.Free;
      Storage.Free;
    end;
  finally
    DurableClean;
  end;
end;

procedure TestDurableUnknownJob;
var
  Storage: TDbJobStore;
  Q: TQueue;
begin
  DurableSetup;
  try
    Storage := NewStore;
    Q := TQueue.Create(Storage, 1, 3, False);
    try
      Q.Start;
      Q.Push('does-not-exist', 'data');
      AssertTrue(Q.WaitUntilEmpty(10000), 'the job was taken off the queue');
      Sleep(100);
      Q.Stop(False);
      AssertEqual(Q.Dropped, 1, 'counted as dropped');
      { An app that has lost a Handle line is to be able to see what was
        there. In the memory queue it disappears; here it is left
        behind. }
      AssertEqual(Storage.FailedCount, 1,
        'a job with no handler lands in the failed table, not in nothing');
    finally
      Q.Free;
      Storage.Free;
    end;
  finally
    DurableClean;
  end;
end;

procedure TestDurableDelayAndBinary;
var
  Storage: TDbJobStore;
  Q: TQueue;
  Err: string;
begin
  DurableSetup;
  try
    Storage := NewStore;
    Q := TQueue.Create(Storage, 1, 3, False);
    try
      Q.Handle('durable', @DurableJob);
      Q.Start;
      Q.Push('durable', 'senere', 2);
      Sleep(300);
      EnterCriticalSection(DurableLock);
      try
        AssertEqual(DurableRan, 0, 'a delayed job does not run at once');
      finally
        LeaveCriticalSection(DurableLock);
      end;
      AssertEqual(Q.Pending, 1, 'it is still in the table');
      Q.Stop(False);

      { Raw bytes are rejected at once. Letting them through gives either a
        corrupt job or a driver error a long way from whoever wrote
        it. }
      Err := '';
      try
        Q.Push('durable', 'a'#0'b');
      except
        on E: Exception do Err := E.Message;
      end;
      AssertTrue(Pos('NUL byte', Err) > 0,
        'a zero byte in the payload is rejected, and the message says why');
      AssertTrue(Pos('durable', Err) > 0, 'and which job it was');
    finally
      Q.Free;
      Storage.Free;
    end;
  finally
    DurableClean;
  end;
end;

{ A worker that dies halfway through a job leaves the row reserved.
  Without somebody releasing it again, the job would lie there forever. }
procedure TestDurableAbandonedReservation;
var
  Storage: TDbJobStore;
  C: TDbConnection;
  A: TArena;
  J: TReservedJob;
begin
  DurableSetup;
  A := TArena.Create(8 * 1024);
  try
    Storage := NewStore;
    try
      Storage.Push('durable', PByte(PChar('data')), 4, 0);

      { Reserve it, and never settle it — as if the process died here. }
      AssertTrue(Storage.Reserve(J), 'the job was reserved');
      AssertEqual(J.Name, 'durable', 'the right job');
      AssertFalse(Storage.Reserve(J), 'nobody else gets it while it is taken');

      { Put the reservation far back in time, the way time would have. }
      C := OpenDbConnection(DurableDsn);
      try
        C.Exec(A, 'UPDATE askr_jobs SET reserved_at = 1');
      finally
        C.Free;
      end;

      AssertTrue(Storage.Reserve(J),
        'an abandoned reservation is released and the job can be taken again');
      Storage.Complete(J);
      AssertEqual(Storage.Pending, 0, 'and then it is gone');
    finally
      Storage.Free;
    end;
  finally
    A.Free;
    DurableClean;
  end;
end;


{ ------------------------------------------------------- HTTP-klient -- }

type
  { A server to call. Everything the client has to handle — chunked,
    redirects, a long body, status codes — comes from here, so that the
    tests need no network. }
  TEkkoServer = class
    function Handle(Req: TRequest): TResponse;
  end;

var
  ClientPort: Word;
  StreamChunks: Integer;
  StreamText: string;
  EkkoH: TEkkoServer;
  EkkoSrv: TAskrServer;
  EkkoOpts: TServerOptions;

function TEkkoServer.Handle(Req: TRequest): TResponse;
var
  I: Integer;
  Big: string;
begin
  if Req.Path.EqualsStr('/hei') then
    Exit(RespondText('hei'));

  if Req.Path.EqualsStr('/ekko') then
    Exit(Respond(200)
      .WithContentType('application/json')
      .WithHeader('X-Method', Askr.Http.Types.MethodName(Req.Method))
      .WithBody(Req.Body));

  if Req.Path.EqualsStr('/hode') then
    Exit(RespondText(Req.Header('X-Prove').ToString + '|' +
      Req.Header('Authorization').ToString));

  if Req.Path.EqualsStr('/flytt') then
    Exit(Redirect('/hei', 302));

  if Req.Path.EqualsStr('/flytt-307') then
    Exit(Redirect('/ekko', 307));

  if Req.Path.EqualsStr('/evig') then
    Exit(Redirect('/evig', 302));

  if Req.Path.EqualsStr('/stor') then
  begin
    { 300 kB, nok til at svaret kommer i flere lesninger. }
    Big := '';
    for I := 1 to 3000 do
      Big := Big + StringOfChar('x', 99) + #10;
    Exit(RespondText(Big));
  end;

  if Req.Path.EqualsStr('/borte') then
    Exit(RespondText('nei', 404));

  Result := RespondText('ukjent', 404);
end;

{ A small server that answers chunked. Askr's own server does not — it
  always sets Content-Length — so without this the whole chunked path in
  the client is uncovered. And that is the path every real server uses when
  it does not know the length in advance, which is nearly always for a
  streamed API. }
type
  TChunkedServer = class(TThread)
  private
    FLytt: TSocket;
    FPort: Word;
  protected
    procedure Execute; override;
  public
    constructor Create;
    property Port: Word read FPort;
  end;

constructor TChunkedServer.Create;
var
  Addr: TInetSockAddr;
  Len: TSockLen;
  Ja: Integer;
begin
  FLytt := fpSocket(AF_INET, SOCK_STREAM, 0);
  Ja := 1;
  fpSetSockOpt(FLytt, SOL_SOCKET, SO_REUSEADDR, @Ja, SizeOf(Ja));
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_addr.s_addr := HToNL($7F000001);
  Addr.sin_port := 0;
  fpBind(FLytt, @Addr, SizeOf(Addr));
  fpListen(FLytt, 4);
  Len := SizeOf(Addr);
  fpGetSockName(FLytt, @Addr, @Len);
  FPort := NToHS(Addr.sin_port);
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TChunkedServer.Execute;
var
  S: TSocket;
  Reply, Chunk: string;
  I: Integer;
  Buf: array[0..1023] of Byte;
begin
  while not Terminated do
  begin
    S := fpAccept(FLytt, nil, nil);
    if S < 0 then
      Break;
    { Read the request and throw it away — what is asked for is not the
      point. }
    fpRecv(S, @Buf[0], SizeOf(Buf), 0);

    Reply := 'HTTP/1.1 200 OK'#13#10 +
      'Content-Type: text/plain'#13#10 +
      'Transfer-Encoding: chunked'#13#10 +
      'Connection: close'#13#10#13#10;
    { Five chunks, and the last contains a CRLF to show that the content is
      not confused with the framing around it. }
    for I := 1 to 5 do
    begin
      if I = 5 then
        Chunk := 'siste'#13#10'linje'
      else
        Chunk := StringOfChar(Chr(Ord('A') + I - 1), 1000);
      { The size is hexadecimal. A chunk with an extension after a
        semicolon is legal, and the fourth has one to show that it is
        skipped. }
      if I = 4 then
        Reply := Reply + Format('%x;ext=here'#13#10'%s'#13#10, [Length(Chunk), Chunk])
      else
        Reply := Reply + Format('%x'#13#10'%s'#13#10, [Length(Chunk), Chunk]);
    end;
    Reply := Reply + '0'#13#10#13#10;
    fpSend(S, PChar(Reply), Length(Reply), 0);
    CloseSocket(S);
  end;
  CloseSocket(FLytt);
end;

procedure TestClientChunked;
var
  Srv: TChunkedServer;
  K: THttpClient;
  R: THttpResponse;
  Ventet: string;
  I: Integer;
begin
  Srv := TChunkedServer.Create;
  K := THttpClient.Create;
  try
    R := K.Get(Format('http://127.0.0.1:%d/', [Srv.Port]));
    AssertEqual(R.Status, 200, 'a chunked reply has a status');
    AssertEqual(R.Header('Transfer-Encoding'), 'chunked',
      'and the server said it sent chunked');

    Ventet := '';
    for I := 1 to 4 do
      Ventet := Ventet + StringOfChar(Chr(Ord('A') + I - 1), 1000);
    Ventet := Ventet + 'siste'#13#10'linje';
    AssertEqual(Length(R.Body), Length(Ventet),
      'all the chunks put back together');
    AssertEqual(R.Body, Ventet, 'and in the right order, byte for byte');
    { The framing around the chunks must not end up in the body. }
    AssertEqual(Pos('3e8', R.Body), 0, 'the size lines are gone');
    AssertEqual(Pos('ext=here', R.Body), 0, 'and the extension too');
  finally
    K.Free;
    Srv.Terminate;
    { One more request, so that accept lets go and the thread can
      finish. }
    try
      K := THttpClient.Create;
      K.ConnectTimeoutMs := 500;
      K.Get(Format('http://127.0.0.1:%d/', [Srv.Port]));
      K.Free;
    except
      on Exception do ;
    end;
    Srv.WaitFor;
    Srv.Free;
  end;
end;

{ Name lookup against /etc/hosts. That path is GetHostByName, not DNS,
  and it has to work everywhere — including where there is no name
  server. }
procedure TestClientLocalhost;
var
  K: THttpClient;
  R: THttpResponse;
begin
  K := THttpClient.Create;
  try
    R := K.Get(Format('http://localhost:%d/hei', [ClientPort]));
    AssertEqual(R.Status, 200, 'localhost resolves through /etc/hosts');
    AssertEqual(R.Body, 'hei', 'and the reply arrived');
  finally
    K.Free;
  end;
end;

function CollectChunk(const Chunk: string): Boolean;
begin
  Inc(StreamChunks);
  StreamText := StreamText + Chunk;
  Result := True;
end;

function StoppEtterFoerste(const Chunk: string): Boolean;
begin
  Inc(StreamChunks);
  StreamText := StreamText + Chunk;
  { False means "stop reading". That is how an SSE listener
    unsubscribes. }
  Result := False;
end;

procedure TestClientUrl;
var
  Sch, Host, Path_: string;
  Port: Word;
begin
  AssertTrue(ParseUrl('https://api.example.com/v1/messages', Sch, Host,
    Port, Path_), 'an ordinary https address');
  AssertEqual(Sch, 'https', 'skjema');
  AssertEqual(Host, 'api.example.com', 'vert');
  AssertEqual(Port, 443, 'https gives 443 without the port being there');
  AssertEqual(Path_, '/v1/messages', 'sti');

  ParseUrl('http://localhost:8080', Sch, Host, Port, Path_);
  AssertEqual(Port, 8080, 'the port is read');
  AssertEqual(Path_, '/', 'an empty path becomes /');

  ParseUrl('http://x.no?a=1', Sch, Host, Port, Path_);
  AssertEqual(Path_, '/?a=1', 'a query with no path gets a / in front');

  { The fragment is the browser's, not the server's, and must never be
    sent. }
  ParseUrl('http://x.no/side#del', Sch, Host, Port, Path_);
  AssertEqual(Path_, '/side', 'the fragment is not sent');

  { User info in the address is ignored rather than passed on. }
  ParseUrl('https://bruker:pass@x.no/a', Sch, Host, Port, Path_);
  AssertEqual(Host, 'x.no', 'user info does not belong to the host');

  AssertFalse(ParseUrl('ftp://x.no/a', Sch, Host, Port, Path_),
    'ftp is not http');
  AssertFalse(ParseUrl('bare en tekst', Sch, Host, Port, Path_),
    'and text with no scheme is no address');

  AssertEqual(UrlEncodeValue('a b&c=d'), 'a%20b%26c%3Dd',
    'prosentkoding');
  AssertEqual(UrlEncodeValue('abc-_.~'), 'abc-_.~',
    'the unreserved characters stand');
end;

procedure TestClientAgainstOwnServer;
var
  K: THttpClient;
  R: THttpResponse;
  Base: string;
begin
  K := THttpClient.Create;
  Base := Format('http://127.0.0.1:%d', [ClientPort]);
  try
    R := K.Get(Base + '/hei');
    AssertEqual(R.Status, 200, 'GET svarte 200');
    AssertEqual(R.Body, 'hei', 'and with the right body');
    AssertTrue(R.Ok, 'Ok er sann for 200');
    AssertTrue(R.Header('Content-Type') <> '', 'the headers came along');
    { Header lookup is to ignore case, the way HTTP says. }
    AssertEqual(R.Header('content-TYPE'), R.Header('Content-Type'),
      'header names are not case-sensitive');

    R := K.Post(Base + '/ekko', '{"a":1}');
    AssertEqual(R.Status, 200, 'POST svarte');
    AssertEqual(R.Body, '{"a":1}', 'the body went there and back');
    AssertEqual(R.Header('X-Method'), 'POST', 'the method was POST');
    AssertTrue(R.IsJson, 'svaret er JSON');

    R := K.Put(Base + '/ekko', 'p');
    AssertEqual(R.Header('X-Method'), 'PUT', 'PUT');
    R := K.Patch(Base + '/ekko', 'p');
    AssertEqual(R.Header('X-Method'), 'PATCH', 'PATCH');
    R := K.Delete(Base + '/ekko');
    AssertEqual(R.Header('X-Method'), 'DELETE', 'DELETE');

    K.WithHeader('X-Prove', 'value').WithBearer('secret-token');
    R := K.Get(Base + '/hode');
    AssertEqual(R.Body, 'value|Bearer secret-token',
      'the headers from the client were sent');
    K.ClearHeaders;

    R := K.Get(Base + '/borte');
    AssertEqual(R.Status, 404, '404 is an answer, not an exception');
    AssertFalse(R.Ok, 'og Ok er usann');

    { A body that does not fit in one read. }
    R := K.Get(Base + '/stor');
    AssertEqual(Length(R.Body), 300000, 'a large reply is read in full');

    AssertTrue(R.ElapsedMs >= 0, 'the time is measured');
  finally
    K.Free;
  end;
end;

procedure TestClientRedirect;
var
  K: THttpClient;
  R: THttpResponse;
  Base, Err: string;
begin
  K := THttpClient.Create;
  Base := Format('http://127.0.0.1:%d', [ClientPort]);
  try
    R := K.Get(Base + '/flytt');
    AssertEqual(R.Status, 200, 'the redirect was followed');
    AssertEqual(R.Body, 'hei', 'and we ended up in the right place');
    AssertEqual(R.Redirects, 1, 'én omdirigering telt');

    { 302 becomes GET. 307 keeps the method and the body — that is the
      whole reason 307 exists. }
    R := K.Post(Base + '/flytt-307', 'kroppen', 'text/plain');
    AssertEqual(R.Header('X-Method'), 'POST', '307 beholder metoden');
    AssertEqual(R.Body, 'kroppen', 'og kroppen');

    { A chain that never ends is to stop, not hang. }
    Err := '';
    try
      K.Get(Base + '/evig');
    except
      on E: EHttpClientError do Err := E.Message;
    end;
    AssertTrue(Pos('Too many redirects', Err) > 0,
      'an endless redirect is stopped');

    { With MaxRedirects = 0 the 302 reply is returned as it is. }
    K.MaxRedirects := 0;
    R := K.Get(Base + '/flytt');
    AssertEqual(R.Status, 302, 'without following you see the redirect itself');
    AssertEqual(R.Header('Location'), '/hei', 'og Location');
  finally
    K.Free;
  end;
end;

procedure TestClientStreaming;
var
  K: THttpClient;
  R: THttpResponse;
  Base: string;
begin
  K := THttpClient.Create;
  Base := Format('http://127.0.0.1:%d', [ClientPort]);
  try
    StreamChunks := 0;
    StreamText := '';
    R := K.Stream('GET', Base + '/stor', '', '', @CollectChunk);
    AssertEqual(R.Status, 200, 'a streamed reply still has a status');
    AssertEqual(R.Body, '', 'the body is not collected when it is streamed');
    AssertEqual(Length(StreamText), 300000, 'but the callback got it all');
    AssertTrue(StreamChunks > 1, 'and it got it in several chunks');

    { False fra callbacken skal stoppe lesingen. }
    StreamChunks := 0;
    StreamText := '';
    R := K.Stream('GET', Base + '/stor', '', '', @StoppEtterFoerste);
    AssertEqual(StreamChunks, 1, 'the callback can say stop');
    AssertTrue(Length(StreamText) < 300000, 'and then the rest is not read');
  finally
    K.Free;
  end;
end;

procedure TestClientErrors;
var
  K: THttpClient;
  Err: string;
begin
  K := THttpClient.Create;
  try
    Err := '';
    try
      K.Get('ftp://example.com/x');
    except
      on E: EHttpClientError do Err := E.Message;
    end;
    AssertTrue(Pos('not an http', Err) > 0,
      'an address that is not http is rejected at once');

    { A port nobody is listening on. The message is to say where. }
    Err := '';
    K.ConnectTimeoutMs := 2000;
    try
      K.Get('http://127.0.0.1:9/does-not-exist');
    except
      on E: EHttpClientError do Err := E.Message;
    end;
    AssertTrue(Pos('127.0.0.1', Err) > 0,
      'a connection that does not come up names the host');

    Err := '';
    try
      K.Get('http://no-such-host.invalid/x');
    except
      on E: EHttpClientError do Err := E.Message;
    end;
    AssertTrue(Pos('resolve', Err) > 0, 'and a name that does not exist');

    { The cap on reply size is a stop, not an optimization. }
    K.MaxResponseBytes := 1000;
    Err := '';
    try
      K.Get(Format('http://127.0.0.1:%d/stor', [ClientPort]));
    except
      on E: EHttpClientError do Err := E.Message;
    end;
    AssertTrue(Pos('exceeded', Err) > 0, 'a reply that is too large is rejected');
  finally
    K.Free;
  end;
end;


{ --------------------------------------------------------------- AI -- }

var
  AiChunks: TStringList;
  AiVerktoeyKall: Integer;
  AiLastArg: string;

function AiCollect(const Delta: string): Boolean;
begin
  AiChunks.Add(Delta);
  Result := True;
end;

function AiStop(const Delta: string): Boolean;
begin
  AiChunks.Add(Delta);
  Result := False;
end;

function VaerVerktoey(const InputJson: string): string;
begin
  Inc(AiVerktoeyKall);
  AiLastArg := InputJson;
  Result := '{"temp_c": 7, "sky": "rain"}';
end;

function BoomTool(const InputJson: string): string;
begin
  Result := '';
  raise Exception.Create('the tool failed');
end;

function NewClient(out F: TFakeAiTransport): TAiClient;
begin
  Result := TAiClient.Create('test-nokkel');
  F := TFakeAiTransport.Create;
  Result.UseTransport(F, True);
end;

{ A reply the way the API sends it. }
function AiReply(const Text_: string): string;
begin
  Result := '{"id":"msg_1","type":"message","role":"assistant",' +
    '"model":"claude-opus-5","content":[{"type":"text","text":"' +
    Text_ + '"}],"stop_reason":"end_turn",' +
    '"usage":{"input_tokens":12,"output_tokens":34}}';
end;

procedure TestAiRequestform;
var
  K: TAiClient;
  F: TFakeAiTransport;
  Sendt: string;
begin
  K := NewClient(F);
  try
    F.Enqueue(AiReply('hei'));
    AssertEqual(K.Ask('si hei'), 'hei', 'the simplest call works');

    Sendt := F.Sent[0];
    { The shape of the request is the only thing we can hold down without
      a key, and then it is to be held down exactly. }
    AssertTrue(Pos('"model":"claude-opus-5"', Sendt) > 0,
      'standardmodellen er claude-opus-5');
    AssertTrue(Pos('"max_tokens":4096', Sendt) > 0, 'max_tokens is there');
    AssertTrue(Pos('"role":"user"', Sendt) > 0, 'the message has a role');
    AssertTrue(Pos('"content":"si hei"', Sendt) > 0, 'og innhold');
    { Without stream the field is not to be there at all. }
    AssertEqual(Pos('"stream"', Sendt), 0, 'no stream on an ordinary call');
    AssertEqual(Pos('"thinking"', Sendt), 0, 'and no thinking when it is off');
    AssertEqual(Pos('"temperature"', Sendt), 0,
      'no temperature when it is not set');

    { The system prompt, the temperature and the model are set by the
      app. }
    K.System_ := 'Du er kort.';
    K.Model := 'claude-haiku-4-5';
    K.SetTemperature(0.2);
    K.MaxTokens := 100;
    F.Enqueue(AiReply('ok'));
    K.Ask('noe');
    Sendt := F.Sent[1];
    AssertTrue(Pos('"system":"Du er kort."', Sendt) > 0, 'system er med');
    AssertTrue(Pos('"model":"claude-haiku-4-5"', Sendt) > 0,
      'the model can be changed');
    AssertTrue(Pos('"temperature":0.2', Sendt) > 0, 'temperature er med');
    AssertTrue(Pos('"max_tokens":100', Sendt) > 0, 'max_tokens can be set');

    { This is the trap worth a test of its own: the old form with
      budget_tokens is rejected with a 400 by the models here. }
    K.Thinking := atAdaptive;
    F.Enqueue(AiReply('ok'));
    K.Ask('noe');
    Sendt := F.Sent[2];
    AssertTrue(Pos('"thinking":{"type":"adaptive"}', Sendt) > 0,
      'thinking is sent as adaptive');
    AssertEqual(Pos('budget_tokens', Sendt), 0,
      'and never with budget_tokens');
  finally
    K.Free;
  end;
end;

procedure TestAiReplyAndError;
var
  K: TAiClient;
  F: TFakeAiTransport;
  R: TAiResponse;
  Err: string;
  E: EAiError;
begin
  K := NewClient(F);
  try
    F.Enqueue(AiReply('svaret'));
    R := K.Send([UserMsg('a question')]);
    AssertEqual(R.Text, 'svaret', 'the text is picked out');
    AssertEqual(R.StopReason, 'end_turn', 'stop_reason');
    AssertEqual(R.Model, 'claude-opus-5', 'the model the reply came from');
    AssertEqual(R.Usage.InputTokens, 12, 'input tokens are counted');
    AssertEqual(R.Usage.OutputTokens, 34, 'output tokens too');
    AssertFalse(R.WantsTool, 'no tool calls');

    { More tekstblokker settes sammen. }
    F.Enqueue('{"content":[{"type":"text","text":"en "},' +
      '{"type":"text","text":"to"}],"stop_reason":"end_turn"}');
    R := K.Send([UserMsg('x')]);
    AssertEqual(R.Text, 'en to', 'several text blocks are joined');

    { Tenkeblokker holdes for seg. }
    F.Enqueue('{"content":[{"type":"thinking","thinking":"hmm"},' +
      '{"type":"text","text":"an answer"}],"stop_reason":"end_turn"}');
    R := K.Send([UserMsg('x')]);
    AssertEqual(R.Thinking, 'hmm', 'tenkningen er for seg');
    AssertEqual(R.Text, 'an answer', 'and the text on its own');

    { An error from the API is to become an EAiError with a type and a
      status, not an empty string the caller has to guess about. }
    F.Enqueue('{"type":"error","error":{"type":"rate_limit_error",' +
      '"message":"Number of requests has exceeded your rate limit"}}', 429);
    Err := '';
    E := nil;
    try
      K.Ask('x');
    except
      on Ex: EAiError do
      begin
        Err := Ex.Message;
        AssertEqual(Ex.Status, 429, 'the status is there');
        { Kind is the type the way the API writes it, unadorned: calling
          code is to be able to compare against it to decide whether to
          try again. }
        AssertEqual(Ex.Kind, 'rate_limit_error', 'and Anthropic''s error type');
      end;
    end;
    AssertTrue(Pos('rate limit', Err) > 0, 'the message is the API''s own');

    { A reply that is not JSON is to say so, not crash somewhere further
      in. }
    F.Enqueue('<html>503 fra en proxy</html>', 503);
    Err := '';
    try
      K.Ask('x');
    except
      on Ex: EAiError do Err := Ex.Message;
    end;
    AssertTrue(Pos('503', Err) > 0, 'an HTML error page gives a readable error');
  finally
    K.Free;
  end;
end;

procedure TestAiStroemming;
var
  K: TAiClient;
  F: TFakeAiTransport;
  R: TAiResponse;
  Sse: string;
begin
  K := NewClient(F);
  AiChunks := TStringList.Create;
  try
    Sse :=
      'event: message_start'#10 +
      'data: {"type":"message_start","message":{"usage":{"input_tokens":5}}}'#10 +
      #10 +
      ': en holdepuls'#10 +
      'data: {"type":"content_block_delta","index":0,' +
      '"delta":{"type":"text_delta","text":"Hi"}}'#10 +
      'data: {"type":"content_block_delta","index":0,' +
      '"delta":{"type":"text_delta","text":" there"}}'#10 +
      'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},' +
      '"usage":{"output_tokens":9}}'#10 +
      'data: [DONE]'#10;
    F.EnqueueStream(Sse);

    R := K.Stream('say hi', @AiCollect);
    AssertEqual(AiChunks.Count, 2, 'two text chunks through the callback');
    AssertEqual(AiChunks[0], 'Hi', 'the first chunk');
    AssertEqual(AiChunks[1], ' there', 'the second chunk');
    AssertEqual(R.Text, 'Hi there', 'and the whole text is collected in the reply');
    AssertEqual(R.StopReason, 'end_turn', 'stop_reason from message_delta');
    AssertEqual(R.Usage.InputTokens, 5, 'input tokens from message_start');
    AssertEqual(R.Usage.OutputTokens, 9, 'output tokens from message_delta');
    AssertTrue(Pos('"stream":true', F.Sent[0]) > 0,
      'the request asked for streaming');

    { The callback has to be able to say stop. }
    AiChunks.Clear;
    F.EnqueueStream(Sse);
    R := K.Stream('say hi', @AiStop);
    AssertEqual(AiChunks.Count, 1, 'the callback stopped after the first chunk');
  finally
    AiChunks.Free;
    K.Free;
  end;
end;

{ How many times Needle is in S. }
function Occurs(const S, Needle: string): Integer;
var
  P, At_: Integer;
begin
  Result := 0;
  At_ := 1;
  repeat
    P := PosEx(Needle, S, At_);
    if P = 0 then
      Break;
    Inc(Result);
    At_ := P + Length(Needle);
  until False;
end;

procedure TestAiVerktoey;
var
  K: TAiClient;
  F: TFakeAiTransport;
  R: TAiResponse;
  Sendt, Err: string;
begin
  K := NewClient(F);
  try
    AiVerktoeyKall := 0;
    AiLastArg := '';
    K.AddTool('weather', 'Looks up the weather in a place',
      '{"type":"object","properties":{"place":{"type":"string"}},' +
      '"required":["place"]}', @VaerVerktoey);
    AssertEqual(K.ToolCount, 1, 'the tool is registered');

    { The first reply asks for the tool, the second answers for good. }
    F.Enqueue('{"content":[{"type":"text","text":"Jeg sjekker."},' +
      '{"type":"tool_use","id":"tu_1","name":"weather",' +
      '"input":{"place":"Oslo"}}],"stop_reason":"tool_use"}');
    F.Enqueue(AiReply('It is raining in Oslo.'));

    R := K.RunTools('what is the weather in Oslo');
    AssertEqual(AiVerktoeyKall, 1, 'the tool was called once');
    { The arguments come as JSON text — only the tool knows which fields
      it has, so the framework passes them on as they are. }
    AssertTrue(Pos('"place":"Oslo"', AiLastArg) > 0,
      'and got the arguments from the model');
    AssertTrue(Pos('It is raining', R.Text) > 0, 'and the loop reached an answer');

    { The tool is to be in the request with its schema. }
    Sendt := F.Sent[0];
    AssertTrue(Pos('"name":"weather"', Sendt) > 0, 'the tool is there');
    AssertTrue(Pos('"input_schema":{"type":"object"', Sendt) > 0,
      'and the schema is sent as it is');

    { The second round has to carry the result, as a tool_result block in
      a user message. That is the most common mistake when you build the
      loop yourself. }
    Sendt := F.Sent[1];
    AssertTrue(Pos('"type":"tool_result"', Sendt) > 0,
      'the result is sent as tool_result');
    AssertTrue(Pos('"tool_use_id":"tu_1"', Sendt) > 0,
      'and points back with an id');
    AssertTrue(Pos('temp_c', Sendt) > 0, 'with what the tool returned');

    { And the half a fake could not tell me was missing.

      The assistant turn has to go back carrying the tool_use blocks it
      asked with. Without them the API refuses the results that follow --
      `each tool_result block must have a corresponding tool_use block in
      the previous message` -- and this suite was green the whole time,
      because it checked the shape I believed in rather than the one the
      API requires. Found by a real call, not by reading.

      The order matters as much as the presence: the tool_use has to be
      in the message BEFORE the tool_result, not merely somewhere. }
    AssertTrue(Pos('"type":"tool_use"', Sendt) > 0,
      'the assistant turn carries the tool_use block it asked with');
    AssertTrue(Pos('"type":"tool_use"', Sendt) <
               Pos('"type":"tool_result"', Sendt),
      'and it comes before the result that answers it');
    AssertTrue(Pos('"id":"tu_1"', Sendt) > 0,
      'with the same id the result points back to');

    { A tool that raises must not take down the loop — the model gets the
      error. }
    K.ClearTools;
    K.AddTool('boom', 'Always fails', '{"type":"object"}',
      @BoomTool);
    F.Enqueue('{"content":[{"type":"tool_use","id":"tu_2",' +
      '"name":"boom","input":{}}],"stop_reason":"tool_use"}');
    F.Enqueue(AiReply('I got an error.'));
    R := K.RunTools('try');
    AssertTrue(Pos('I got an error', R.Text) > 0,
      'a tool that raises does not stop the loop');
    AssertTrue(Pos('"is_error":true', F.Sent[3]) > 0,
      'and the error is marked as an error');

    { A tool the model invents must not knock anything over either. }
    F.Enqueue('{"content":[{"type":"tool_use","id":"tu_3",' +
      '"name":"finnes-ikke","input":{}}],"stop_reason":"tool_use"}');
    F.Enqueue(AiReply('Beklager.'));
    R := K.RunTools('try');
    AssertTrue(Pos('no such tool', F.Sent[5]) > 0,
      'an unknown tool becomes a message to the model');

    { The loop has a cap. }
    K.MaxTurns := 2;
    K.ClearTools;
    K.AddTool('weather', 'x', '{"type":"object"}', @VaerVerktoey);
    F.Enqueue('{"content":[{"type":"tool_use","id":"a","name":"weather",' +
      '"input":{}}],"stop_reason":"tool_use"}');
    F.Enqueue('{"content":[{"type":"tool_use","id":"b","name":"weather",' +
      '"input":{}}],"stop_reason":"tool_use"}');
    Err := '';
    try
      K.RunTools('go in circles');
    except
      on E: EAiError do Err := E.Message;
    end;
    AssertTrue(Pos('did not finish within 2 turns', Err) > 0,
      'a loop that never ends is stopped');

    { Two tools in one turn, which is ordinary and is where the other half
      of the same bug lives: every result has to be in ONE user message.
      One message each puts all but the first out of reach of the
      assistant turn they answer, and the API refuses them.

      A single-tool round cannot show this -- the first version of this
      test had only one, and a mutation that dropped every result but the
      first went straight through it. }
    AiVerktoeyKall := 0;
    F.Enqueue('{"content":[' +
      '{"type":"tool_use","id":"tu_a","name":"weather",' +
      '"input":{"place":"Oslo"}},' +
      '{"type":"tool_use","id":"tu_b","name":"weather",' +
      '"input":{"place":"Bergen"}}],"stop_reason":"tool_use"}');
    F.Enqueue(AiReply('Rain in both.'));
    R := K.RunTools('weather in Oslo and Bergen');
    AssertEqual(AiVerktoeyKall, 2, 'both tools ran');

    { The last request the fake saw: the one carrying both results. }
    Sendt := F.Sent[F.Sent.Count - 1];
    AssertTrue(Pos('"tool_use_id":"tu_a"', Sendt) > 0, 'the first result');
    AssertTrue(Pos('"tool_use_id":"tu_b"', Sendt) > 0, 'and the second');
    { Both inside the same message: there is exactly one user turn after
      the assistant one, so counting the roles is the check. }
    AssertEqual(Occurs(Sendt, '"role":"user"'), 2,
      'and they are in one user message, not one each');

  finally
    K.Free;
  end;
end;

procedure TestAiStrukturert;
var
  K: TAiClient;
  F: TFakeAiTransport;
  Reply, Sendt, Err: string;
begin
  K := NewClient(F);
  try
    F.Enqueue('{"content":[{"type":"tool_use","id":"t","name":"respond",' +
      '"input":{"name":"Ada","age":36,"active":true}}],' +
      '"stop_reason":"tool_use"}');
    Reply := K.Structured('who is she',
      '{"type":"object","properties":{"name":{"type":"string"},' +
      '"age":{"type":"integer"}},"required":["name"]}');

    { The result is JSON, not prose. }
    AssertTrue(Pos('"name":"Ada"', Reply) > 0, 'the fields came back');
    AssertTrue(Pos('"age":36', Reply) > 0, 'the numbers too');
    AssertTrue(Pos('"active":true', Reply) > 0, 'and booleans');

    Sendt := F.Sent[0];
    { It is tool_choice that makes the answer structured and not prose
      alongside it. }
    AssertTrue(Pos('"tool_choice":{"type":"tool","name":"respond"}', Sendt) > 0,
      'the model is forced to the tool');

    { Structured must not change the client it was called on. }
    AssertEqual(K.ToolCount, 0, 'the tools are as before afterwards');

    { If the model answers with text anyway, that is to be an error and not
      an empty string the caller has to guess about. }
    F.Enqueue(AiReply('Hun heter Ada.'));
    Err := '';
    try
      K.Structured('hvem', '{"type":"object"}');
    except
      on E: EAiError do Err := E.Message;
    end;
    AssertTrue(Pos('instead of the requested structure', Err) > 0,
      'prose instead of structure is an error');
  finally
    K.Free;
  end;
end;

{ ------------------------------------------------------------------ main -- }

{ ------------------------------------------------------------- bilder -- }

function ImageFile(const Name_: string): TBytes;
var
  F: TFileStream;
  Path_: string;
  B: TBytes;
begin
  B := nil;
  Result := B;
  Path_ := 'tests/vectors/images/' + Name_;
  if not FileExists(Path_) then
    Exit;
  F := TFileStream.Create(Path_, fmOpenRead);
  try
    SetLength(B, F.Size);
    if F.Size > 0 then
      F.ReadBuffer(B[0], F.Size);
    Result := B;
  finally
    F.Free;
  end;
end;

function FmtName(F: TImageFormat): string;
begin
  case F of
    ifJpeg: Result := 'jpeg';
    ifPng:  Result := 'png';
    ifGif:  Result := 'gif';
    ifWebp: Result := 'webp';
    ifBmp:  Result := 'bmp';
    ifAvif: Result := 'avif';
    ifTiff: Result := 'tiff';
    ifSvg:  Result := 'svg';
  else
    Result := 'unknown';
  end;
end;

procedure TestBildeHoder;
var
  L: TStringList;
  I, K, W, H, A, Gale: Integer;
  S, Name_, Fmt: string;
  Inf: TImageInfo;
begin
  Gale := 0;
  L := TStringList.Create;
  try
    if not FileExists('tests/vectors/images/expected.txt') then
    begin
      AssertTrue(False, 'the image fixtures exist (run from the repository root)');
      Exit;
    end;
    L.LoadFromFile('tests/vectors/images/expected.txt');
    for I := 0 to L.Count - 1 do
    begin
      S := Trim(L[I]);
      if (S = '') or (S[1] = '#') then
        Continue;
      K := Pos(' ', S); Name_ := Copy(S, 1, K - 1);
      S := Trim(Copy(S, K + 1, Length(S)));
      K := Pos(' ', S); Fmt := Copy(S, 1, K - 1);
      S := Trim(Copy(S, K + 1, Length(S)));
      K := Pos(' ', S); W := StrToIntDef(Copy(S, 1, K - 1), -1);
      S := Trim(Copy(S, K + 1, Length(S)));
      K := Pos(' ', S); H := StrToIntDef(Copy(S, 1, K - 1), -1);
      A := StrToIntDef(Trim(Copy(S, K + 1, Length(S))), 0);

      Inf := ReadImageInfo('tests/vectors/images/' + Name_);
      if FmtName(Inf.Format) <> Fmt then Inc(Gale);
      if (W > 0) and ((Inf.Width <> W) or (Inf.Height <> H)) then Inc(Gale);
      if (A = 1) <> Inf.Animated then Inc(Gale);
    end;
  finally
    L.Free;
  end;
  AssertEqual(Gale, 0, 'format and dimensions are read without decoding');
end;

procedure TestBildeSikkerhet;
var
  D: TBytes;
begin
  { The single most important check in the unit: a file called .jpg that
    is HTML is a stored XSS vector if it is served back. }
  D := ImageFile('nope.jpg');
  AssertTrue(SniffFormat(D) = ifUnknown, 'HTML disguised as .jpg is not an image');
  AssertTrue(not ExtensionMatches('nope.jpg', D), 'and the extension is exposed');

  D := ImageFile('jpeg_320x240.jpg');
  AssertTrue(ExtensionMatches('a.jpg', D), 'a real jpeg matches .jpg');
  AssertTrue(ExtensionMatches('a.jpeg', D), '.jpeg counts as the same');
  AssertTrue(not ExtensionMatches('a.png', D), 'but not .png');
  AssertTrue(not ExtensionMatches('a.jpg', ImageFile('tom.png')),
    'an empty file is nothing');
end;

procedure TestExifStripping;
var
  D, Ut: TBytes;
  Inf: TImageInfo;
begin
  D := ImageFile('jpeg_exif_gps.jpg');
  AssertEqual(JpegOrientation(D), 6, 'the orientation is read from EXIF');
  AssertTrue(Pos('Askr Test', TEncoding.ASCII.GetString(D)) > 0,
    'EXIF is in the file before stripping');

  AssertTrue(StripJpegMetadata(D, Ut), 'the stripping succeeds');
  AssertTrue(Pos('Askr Test', TEncoding.ASCII.GetString(Ut)) = 0,
    'EXIF is gone afterwards');
  AssertTrue(Length(Ut) < Length(D), 'and the file is smaller');
  AssertTrue(SniffFormat(Ut) = ifJpeg, 'but still a jpeg');
  Inf := ReadImageInfo(Ut);
  AssertTrue((Inf.Width = 800) and (Inf.Height = 600), 'with the dimensions intact');

  AssertEqual(JpegOrientation(ImageFile('jpeg_orient3.jpg')), 3,
    'orientation 3 is read too');
  AssertEqual(JpegOrientation(ImageFile('jpeg_320x240.jpg')), 0,
    'without EXIF the orientation is 0');
  AssertTrue(not StripJpegMetadata(ImageFile('png_320x240.png'), Ut),
    'a png cannot be stripped as a jpeg');
end;

procedure TestVips;
var
  Inn, Ut: TBytes;
  Inf: TImageInfo;
begin
  if not VipsAvailable then
  begin
    { Not a failure. libvips is an optional dependency, and the suite says
      why it skips rather than staying quiet. }
    WriteLn('    (hoppet over: ', Copy(VipsError, 1, 48), '…)');
    AssertTrue(VipsError <> '', 'and the error says what is missing');
    Exit;
  end;

  Inn := ImageFile('jpeg_1920x1080.jpg');
  Ut := ResizeImage(Inn, 320, 0, ifJpeg, 80);
  Inf := ReadImageInfo(Ut);
  AssertEqual(Inf.Width, 320, 'resized to the given width');
  AssertEqual(Inf.Height, 180, 'the height follows the ratio');
  AssertTrue(Length(Ut) < Length(Inn), 'and the file is smaller');

  Ut := ResizeImage(Inn, 200, 200, ifJpeg, 80, fmCover);
  Inf := ReadImageInfo(Ut);
  AssertTrue((Inf.Width = 200) and (Inf.Height = 200),
    'cover fills the box exactly');

  Ut := ResizeImage(Inn, 200, 200, ifJpeg, 80, fmInside);
  Inf := ReadImageInfo(Ut);
  AssertTrue((Inf.Width = 200) and (Inf.Height < 200),
    'inside does not fill it');

  AssertTrue(SniffFormat(ResizeImage(Inn, 100, 0, ifPng)) = ifPng,
    'jpeg becomes png');
  AssertTrue(SniffFormat(ResizeImage(Inn, 100, 0, ifWebp, 75)) = ifWebp,
    'jpeg becomes webp');
  AssertTrue(Length(ResizeImage(Inn, 600, 0, ifJpeg, 30)) <
             Length(ResizeImage(Inn, 600, 0, ifJpeg, 95)),
    'lower quality gives a smaller file');

  { Upscaling is never what anybody asked for. }
  AssertEqual(ReadImageInfo(ResizeImage(ImageFile('jpeg_320x240.jpg'),
    2000, 0, ifJpeg, 80)).Width, 320, 'never upscales');

  { libvips strips too, through strip=true in the format string. }
  Ut := ResizeImage(ImageFile('jpeg_exif_gps.jpg'), 200, 0, ifJpeg, 80);
  AssertTrue(Pos('Askr Test', TEncoding.ASCII.GetString(Ut)) = 0,
    'EXIF does not survive a resize');

  Inf := ReadImageInfo(ConvertImage(ImageFile('png_320x240.png'), ifWebp, 80));
  AssertTrue((Inf.Width = 320) and (Inf.Height = 240) and (Inf.Format = ifWebp),
    'conversion keeps the size');
end;
{ ------------------------------------------ compiler diagnostics -- }

{ A premise test, and it comes before the MCP server rather than after it.

  The whole value of a `build` tool is that an agent can verify instead of
  claiming, and that rests on one thing: fpc's diagnostics parse into
  file, line, column and severity. So the premise is written down first,
  against real captured output rather than against what the format is
  remembered to be.

  The vectors in tests/vectors/fpcdiag/ were produced by compiling three
  deliberately broken fixtures with three toolchains: 3.2.2 on aarch64,
  3.2.2 on x86_64, and 3.3.1 trunk on aarch64. **The positioned lines are
  byte-identical across all three**, which is the premise. Message text is
  not: 3.2.2 writes `function header doesn't match` where trunk writes
  `Function header doesn't match`. Nothing here may depend on wording. }
procedure TestDiagFormat;
var
  T: Integer;
  Toolchains: array[0..2] of string = (
    'fpc322-aarch64', 'fpc322-amd64', 'fpc331-darwin');
  Raw: TStringList;

  function Load(const Fixture, Tool: string): string;
  var
    Path_: string;
  begin
    Result := '';
    Path_ := 'tests/vectors/fpcdiag/' + Fixture + '.' + Tool + '.txt';
    if not FileExists(Path_) then
      Exit;
    Raw.LoadFromFile(Path_);
    Result := Raw.Text;
  end;

  { Only the ones with a position. The unpositioned Hints about fpc.cfg and
    the `returned an error exitcode` line are real diagnostics and are
    parsed, but they carry no location and are not what a caller shows. }
  function Positioned(const D: TDiagArray): TDiagArray;
  var
    I, N: Integer;
    R: TDiagArray;
  begin
    R := nil;
    SetLength(R, Length(D));
    N := 0;
    for I := 0 to High(D) do
      if D[I].FileName_ <> '' then
      begin
        R[N] := D[I];
        Inc(N);
      end;
    SetLength(R, N);
    Result := R;
  end;

var
  D: TDiagArray;
  Src: string;
begin
  Raw := TStringList.Create;
  try
    if Load('errors', 'fpc322-aarch64') = '' then
    begin
      AssertTrue(False,
        'the diagnostic vectors exist (run from the repository root)');
      Exit;
    end;

    for T := 0 to High(Toolchains) do
    begin
      { ---- several errors, and the summary line with no column ---- }
      Src := Load('errors', Toolchains[T]);
      AssertTrue(Src <> '', Toolchains[T] + ': errors vector loaded');
      D := Positioned(ParseDiagnostics(Src));
      AssertEqual(Length(D), 4, Toolchains[T] + ': four positioned lines');

      { How many defects there are, as opposed to how many error-level
        lines fpc printed. errors.pas has three, and fpc then says so in a
        summary that is error-level itself — so counting lines gives six.
        A column separates a defect from a summary, and it does so on
        every one of these vectors. An agent told `6 errors` for three
        mistakes goes looking for three that are not there. }
      AssertEqual(CountDefects(ParseDiagnostics(Src)), 3,
        Toolchains[T] + ': three defects, not six error-level lines');

      AssertEqual(D[0].FileName_, 'errors.pas', Toolchains[T] + ': the file');
      AssertEqual(D[0].Line, 18, Toolchains[T] + ': the line');
      AssertEqual(D[0].Col, 8, Toolchains[T] + ': the column');
      AssertTrue(D[0].Severity = dsError, Toolchains[T] + ': the severity');

      AssertEqual(D[1].Line, 19, Toolchains[T] + ': the second line');
      AssertEqual(D[2].Line, 20, Toolchains[T] + ': the third');

      { The shape that has no column. Getting this wrong means either
        dropping the line or reading 24 as a column. }
      AssertEqual(D[3].Line, 24, Toolchains[T] + ': a line without a column');
      AssertEqual(D[3].Col, 0, Toolchains[T] + ': and the column is 0');
      AssertTrue(D[3].Severity = dsFatal, Toolchains[T] + ': and it is fatal');

      AssertTrue(HasErrors(ParseDiagnostics(Src)),
        Toolchains[T] + ': errors stop the build');

      { ---- one fatal syntax error, no summary ---- }
      Src := Load('syntax', Toolchains[T]);
      D := Positioned(ParseDiagnostics(Src));
      AssertEqual(Length(D), 1, Toolchains[T] + ': one positioned line');
      AssertEqual(D[0].Line, 11, Toolchains[T] + ': the syntax error line');
      AssertEqual(D[0].Col, 14, Toolchains[T] + ': and its column');
      AssertTrue(D[0].Severity = dsFatal, Toolchains[T] + ': it is fatal');
      { A syntax error is Fatal, not Error, and it is still one defect. The
        two lines after it are fpc stopping, and have no column. }
      AssertEqual(CountDefects(ParseDiagnostics(Src)), 1,
        Toolchains[T] + ': one defect, though three error-level lines');

      { ---- a build that SUCCEEDS while saying things ---- }
      Src := Load('warnings', Toolchains[T]);
      D := Positioned(ParseDiagnostics(Src));
      AssertEqual(Length(D), 3, Toolchains[T] + ': three positioned lines');
      AssertTrue(D[0].Severity = dsWarning, Toolchains[T] + ': a warning');
      AssertTrue(D[1].Severity = dsNote, Toolchains[T] + ': a note');
      AssertTrue(D[2].Severity = dsHint, Toolchains[T] + ': a hint');

      { The distinction the exit code alone cannot make. A build that emits
        notes still produced a binary, and calling that a failure would be
        wrong in the most common case there is. }
      AssertTrue(not HasErrors(ParseDiagnostics(Src)),
        Toolchains[T] + ': warnings and notes do not stop the build');
    end;

    { `Target OS: Darwin for AArch64` has a word before a colon and is not a
      diagnostic. Neither is the banner, `Compiling …`, or the tallies. If
      the severity were taken as "whatever stands before the colon", the
      target line would come through as one. }
    D := ParseDiagnostics(
      'Free Pascal Compiler version 3.2.2+dfsg-20 [2023/03/30] for aarch64'#10 +
      'Copyright (c) 1993-2021 by Florian Klaempfl and others'#10 +
      'Target OS: Darwin for AArch64'#10 +
      'Compiling tests/vectors/fpcdiag/warnings.pas'#10 +
      'Assembling warnings'#10 +
      '25 lines compiled, 0.0 sec'#10 +
      '1 warning(s) issued'#10);
    AssertEqual(Length(D), 0, 'the banner and the tallies are not diagnostics');

    { An unpositioned severity is a diagnostic and is kept. Dropping it
      would mean dropping by message text, which is the one thing this
      parser must not do. }
    D := ParseDiagnostics('Fatal: Compilation aborted'#10);
    AssertEqual(Length(D), 1, 'an unpositioned severity is kept');
    AssertEqual(D[0].Line, 0, 'with no line');
    AssertEqual(D[0].FileName_, '', 'and no file');
  finally
    Raw.Free;
  end;
end;

{ ------------------------------------------------ the MCP server -- }

{ The protocol, driven without a process — the same reason the router is
  tested without a socket. What a process adds is the transport and the
  purity of stdout, and that is `./askr mcp:check`.

  These are the shapes a client actually sends. A server that answers
  `initialize` and nothing else looks like it works right up until the
  client asks for the tool list. }
{ What crawlers are told, and the one thing the default has to get right.

  A missing robots.txt means "index everything" -- that is what a crawler
  assumes on a 404. So the dangerous state is not a wrong file but no file,
  on a staging site nobody thought about, and the first sign of it is the
  unreleased pages showing up in somebody's search results.

  The assertion that matters is therefore not that production is open. It
  is that **everything else is closed, without anybody opting in.** }
procedure TestRobots;
var
  Folder: string;
  L: TStringList;

  procedure WithEnv(const EnvLine, UrlLine: string);
  begin
    L := TStringList.Create;
    try
      if EnvLine <> '' then
        L.Add(EnvLine);
      if UrlLine <> '' then
        L.Add(UrlLine);
      L.SaveToFile(Folder + '/.env');
    finally
      L.Free;
    end;
    ClearConfig;
    LoadConfig(Folder);
  end;

begin
  Folder := '.build/cfg-robots';
  ForceDirectories(Folder);

  WithEnv('APP_ENV=production', 'APP_URL=https://example.com');
  AssertContains(RobotsText, 'User-agent: *', 'production names the agents');
  AssertContains(RobotsText, 'Disallow:'#10,
    'and disallows nothing, which is how you say all of it');
  AssertNotContains(RobotsText, 'Disallow: /',
    'it is not closed');
  AssertContains(RobotsText, 'Sitemap: https://example.com/sitemap.xml',
    'and points at the sitemap, absolutely');

  { Without an origin there is nowhere truthful to get an absolute URL
    from -- not the request. So the line is left out rather than guessed. }
  WithEnv('APP_ENV=production', '');
  AssertNotContains(RobotsText, 'Sitemap:',
    'no app.url, no Sitemap line');
  AssertNotContains(RobotsText, 'Disallow: /',
    'but production is still open');

  { The three that have to be closed, and the third is the one that
    matters: nothing configured at all. }
  WithEnv('APP_ENV=local', 'APP_URL=https://example.com');
  AssertContains(RobotsText, 'Disallow: /', 'local is closed');
  WithEnv('APP_ENV=staging', 'APP_URL=https://example.com');
  AssertContains(RobotsText, 'Disallow: /', 'staging is closed');
  WithEnv('', '');
  AssertContains(RobotsText, 'Disallow: /',
    'and a server with no configuration at all is closed, not open');

  { The environment is named, because the question this file is asked is
    "why is my site not indexed" and the answer is nearly always that the
    environment is not what somebody thought. }
  WithEnv('APP_ENV=staging', '');
  AssertContains(RobotsText, 'staging', 'and it says which environment');

  ClearConfig;
end;

{ The sitemap, judged by a real XML parser.

  A `&` in a URL is the ordinary case -- one query parameter is enough --
  and an unescaped one makes the whole document malformed, not just that
  entry. A crawler that cannot parse it reads none of it.

  So the assertions go through fcl-xml rather than through Pos(). A
  pattern match is my idea of what XML is; a parser is XML. It is the same
  move as reading a link's protocol out of the browser rather than out of
  a regular expression. }
procedure TestSitemap;
var
  Folder, Xml: string;
  L: TStringList;

  { True when the text parses as XML at all. }
  function Parses(const S: string; out Root: string): Boolean;
  var
    D: TXMLDocument;
    Stream: TStringStream;
  begin
    Result := False;
    Root := '';
    D := nil;
    Stream := TStringStream.Create(S);
    try
      try
        ReadXMLFile(D, Stream);
        Root := string(D.DocumentElement.NodeName);
        Result := True;
      except
        on E: Exception do
          Result := False;
      end;
    finally
      D.Free;
      Stream.Free;
    end;
  end;

  { The text of every <loc> in the document, one per line. }
  function Locs(const S: string): string;
  var
    D: TXMLDocument;
    Stream: TStringStream;
    List_: TDOMNodeList;
    I: Integer;
  begin
    Result := '';
    D := nil;
    Stream := TStringStream.Create(S);
    try
      ReadXMLFile(D, Stream);
      List_ := D.DocumentElement.GetElementsByTagName('loc');
      for I := 0 to List_.Count - 1 do
        Result := Result + string(List_[I].TextContent) + #10;
    finally
      D.Free;
      Stream.Free;
    end;
  end;

var
  S: TSitemap;
  Root: string;
begin
  Folder := '.build/cfg-sitemap';
  ForceDirectories(Folder);
  L := TStringList.Create;
  try
    L.Add('APP_ENV=production');
    L.Add('APP_URL=https://example.com');
    L.SaveToFile(Folder + '/.env');
  finally
    L.Free;
  end;
  ClearConfig;
  LoadConfig(Folder);

  S := TSitemap.Create;
  try
    S.Add('/').Add('/docs/queries').Add('/about', EncodeDate(2026, 9, 22));
    AssertEqual(S.Count, 3, 'three entries');
    AssertEqual(S.PartCount, 1, 'in one document');

    Xml := S.RootXml;
    AssertTrue(Parses(Xml, Root), 'the document parses as XML');
    AssertEqual(Root, 'urlset', 'and it is a urlset');

    { Absolute, and from app.url. A sitemap of relative URLs is refused by
      crawlers, and the only other source of an origin is the request --
      the one place it must never come from. }
    AssertContains(Locs(Xml), 'https://example.com/docs/queries',
      'the paths came out absolute');
    AssertNotContains(Locs(Xml), #10'/', 'and none of them relative');

    AssertContains(Xml, '<lastmod>2026-09-22T00:00:00+00:00</lastmod>',
      'lastmod is W3C datetime in UTC');
    { Two of the three had none. A lastmod of "now" on every build tells a
      crawler nothing except that you do not know. }
    AssertEqual(Length(Xml) - Length(StringReplace(Xml, '<lastmod>', '',
      [rfReplaceAll])), Length('<lastmod>'),
      'and is left out where there is none -- exactly one of the three');
  finally
    S.Free;
  end;

  { The one that decides whether the document is readable at all. }
  S := TSitemap.Create;
  try
    S.Add('/search?q=a&b=2&c=<3>');
    Xml := S.RootXml;
    AssertTrue(Parses(Xml, Root),
      'a URL with & and < in it still parses');
    AssertContains(Xml, '&amp;', 'because it was escaped');
    AssertContains(Locs(Xml), 'https://example.com/search?q=a&b=2&c=<3>',
      'and the parser gives the original back');
  finally
    S.Free;
  end;

  { Over the limit is not a large sitemap, it is a rejected one, so it
    splits and an index goes in front. 50 001 entries is slow to build but
    it is the only way to know the boundary is where it is said to be. }
  S := TSitemap.Create;
  try
    while S.Count < MaxSitemapUrls do
      S.Add('/p/' + IntToStr(S.Count));
    AssertEqual(S.PartCount, 1, 'exactly at the limit is still one part');
    S.Add('/one-more');
    AssertEqual(S.PartCount, 2, 'one past it becomes two');

    Xml := S.RootXml;
    AssertTrue(Parses(Xml, Root), 'the index parses');
    AssertEqual(Root, 'sitemapindex', 'and it is an index, not a urlset');
    AssertContains(Locs(Xml), 'https://example.com/sitemap/1',
      'pointing at the parts');
    AssertContains(Locs(Xml), 'https://example.com/sitemap/2', 'both of them');

    AssertTrue(Parses(S.PartXml(2), Root), 'and part two parses');
    AssertEqual(Root, 'urlset', 'as a urlset');
    AssertContains(Locs(S.PartXml(2)), '/one-more',
      'holding what did not fit in part one');
  finally
    S.Free;
  end;

  ClearConfig;
end;

{ The docs tools, against this repository's own docs/.

  The property that matters is not that a search finds things — it is what
  it does with a name that does not exist. `Back.WithErrors` is the wrong
  name for `BackWithErrors`, and it is a mistake that was actually made
  here: it is one of the four wrong signatures in the first draft of docs/,
  caught by reading the source rather than the prose.

  An agent that asks about it must be told there is no such thing. A search
  that ignored punctuation would match it against the real name and hand
  back a page that reads as confirmation, and the agent would write the
  wrong call with documentation apparently behind it. So both directions
  are asserted, and the second is the one worth keeping. }
{ The origin an application answers on, and the one thing that must never
  feed it.

  Every absolute URL a site emits names an origin, and the request cannot
  be asked what it is: `Host` is a header the client writes. A canonical
  built from it hands a search engine the attacker's domain; a reset link
  built from it hands over the token. The end-to-end half of this is in
  askr_tests, which drives a real socket with a forged Host -- here is the
  unit, where the property is structural: there is no request to take it
  from. }
procedure TestAppUrl;
var
  Folder: string;
  L: TStringList;

  procedure WithEnv(const Line: string);
  begin
    L := TStringList.Create;
    try
      L.Add('APP_ENV=local');
      if Line <> '' then
        L.Add(Line);
      L.SaveToFile(Folder + '/.env');
    finally
      L.Free;
    end;
    ClearConfig;
    LoadConfig(Folder);
  end;

begin
  Folder := '.build/cfg-url';
  ForceDirectories(Folder);

  { Not set: empty, not guessed. A caller that can do without an absolute
    URL leaves it out; the second-best guess available is the request. }
  WithEnv('');
  AssertEqual(AppUrl, '', 'no app.url gives no origin');
  AssertEqual(AbsoluteUrl('/docs'), '', 'and no absolute URL');

  WithEnv('APP_URL=https://example.com');
  AssertEqual(AppUrl, 'https://example.com', 'a plain origin comes back');
  AssertEqual(AbsoluteUrl('/docs'), 'https://example.com/docs', 'joined');
  AssertEqual(AbsoluteUrl('docs'), 'https://example.com/docs',
    'with or without the leading slash');
  AssertEqual(AbsoluteUrl('/docs/'), 'https://example.com/docs',
    'and no trailing one');
  AssertEqual(AbsoluteUrl(''), 'https://example.com', 'the origin itself');
  AssertEqual(AbsoluteUrl('/'), 'https://example.com', 'and for "/" too');

  { A trailing slash is what a browser shows, so it is normalised rather
    than refused. Case is normalised because a canonical URL differing only
    in case is a second URL to a crawler. }
  WithEnv('APP_URL=HTTPS://Example.COM/');
  AssertEqual(AppUrl, 'https://example.com',
    'scheme and host are lowercased, the trailing slash dropped');

  WithEnv('APP_URL=http://localhost:8080');
  AssertEqual(AppUrl, 'http://localhost:8080', 'a port is kept');
  AssertEqual(AbsoluteUrl('/a'), 'http://localhost:8080/a', 'and joined');

  { A value somebody typed and got wrong says so once, loudly, rather than
    producing links that are wrong where nobody looks. }
  AssertTrue(UrlProblem('example.com') <> '', 'no scheme is a problem');
  AssertTrue(UrlProblem('https://') <> '', 'no host is a problem');
  AssertTrue(Pos('sub-path', UrlProblem('https://example.com/app')) > 0,
    'a path is refused, and says why');
  AssertTrue(UrlProblem('https://example.com?a=1') <> '',
    'so is a query');
  AssertEqual(UrlProblem('https://example.com'), '', 'a good one is fine');
  AssertEqual(UrlProblem(''), '', 'and so is nothing at all');

  WithEnv('APP_URL=example.com');
  try
    AppUrl;
    AssertTrue(False, 'a bad app.url raises');
  except
    on E: EUrlError do
      AssertTrue(Pos('example.com', E.Message) > 0,
        'and the message shows the value');
  end;

  { OrFail is for the places where a missing origin is the bug: a sitemap,
    a link in an email. It names the key and the environment variable, as
    CfgOrFail does. }
  WithEnv('');
  try
    AppUrlOrFail;
    AssertTrue(False, 'OrFail refuses when it is not set');
  except
    on E: EUrlError do
    begin
      AssertTrue(Pos('APP_URL', E.Message) > 0, 'naming the variable');
      AssertTrue(Pos('Host', E.Message) > 0, 'and saying why not the request');
    end;
  end;

  { The link in a reset email refuses rather than coming out relative. An
    empty href looks like a link and is not one. }
  try
    AbsoluteUrlOrFail('/reset-password/abc');
    AssertTrue(False, 'an absolute URL with no origin refuses');
  except
    on E: EUrlError do
      AssertTrue(Pos('APP_URL', E.Message) > 0, 'and says which key');
  end;

  ClearConfig;
end;

procedure TestDocsSearchAndRead;
var
  Dir, Text_, Err: string;
  Hits: TDocHits;
  Total, I: Integer;
  Pages: TDocPages;
  Found: Boolean;
begin
  Dir := 'docs';
  AssertTrue(DirectoryExists(Dir),
    'docs/ is there (run from the repository root)');

  Pages := DocPages(Dir);
  AssertTrue(Length(Pages) > 20, 'the pages are found');
  AssertTrue(Pages[0] < Pages[1], 'and come back sorted');

  { The real name is in the docs, more than once and on more than one
    page. Without this the assertion below would pass on an empty
    directory. }
  Hits := DocSearch(Dir, 'BackWithErrors', 100, Total);
  AssertTrue(Total >= 5, 'the real name is found');
  Found := False;
  for I := 0 to High(Hits) do
    if Hits[I].Page = 'validation.md' then
      Found := True;
  AssertTrue(Found, 'including on validation.md');

  { The one that matters, asserted as the property rather than as the
    absence of one string. Every hit must actually contain what was asked
    for: a fuzzy search is exactly a search that returns lines which do
    not. Stated this way it keeps holding when the docs themselves start
    talking about the wrong name. }
  Hits := DocSearch(Dir, 'Back.WithErrors', 100, Total);
  AssertEqual(Total, 0, 'the name that does not exist is not found');
  for I := 0 to High(Hits) do
    AssertContains(LowerCase(Hits[I].Text_), 'back.witherrors',
      'and no hit would be one that merely looks like it');

  { Case does not matter — an agent writes what it remembers. }
  DocSearch(Dir, 'backwitherrors', 100, Total);
  AssertTrue(Total >= 5, 'but case does not matter');

  { A hit carries the heading it sits under, because that is what
    DocRead takes. A position an agent cannot follow is half an answer. }
  Hits := DocSearch(Dir, 'session flash', 100, Total);
  AssertTrue(Total > 0, 'a phrase with a space is found');
  Found := False;
  for I := 0 to High(Hits) do
    if Hits[I].Heading <> '' then
      Found := True;
  AssertTrue(Found, 'and at least one hit names its section');

  { Limit truncates the list but not the count. "3 of 47" is true;
    "3" while quietly holding 44 more is not. }
  Hits := DocSearch(Dir, 'the', 3, Total);
  AssertEqual(Length(Hits), 3, 'the limit truncates');
  AssertTrue(Total > 3, 'but the total is still the total');

  AssertTrue(DocRead(Dir, 'validation.md', '', Text_, Err),
    'a page reads');
  AssertContains(Text_, '# Validation', 'and it is the right one');

  AssertTrue(DocRead(Dir, 'validation', '', Text_, Err),
    'the .md is optional');
  AssertTrue(DocRead(Dir, 'VALIDATION.MD', '', Text_, Err),
    'and case does not matter');

  AssertTrue(DocRead(Dir, 'validation', 'Across a redirect', Text_, Err),
    'a section reads');
  AssertContains(Text_, '## Across a redirect', 'starting at its heading');
  AssertNotContains(Text_, '## Why it lives in the model unit',
    'and stopping at the next one');
  AssertNotContains(Text_, '# Validation'#10, 'without the page title');

  { A page name is text an agent wrote. It is matched against the listing
    of what is there, so a traversal cannot name a file — it does not
    equal any entry. }
  AssertFalse(DocRead(Dir, '../README.md', '', Text_, Err),
    'a path cannot escape docs/');
  AssertFalse(DocRead(Dir, '../../etc/passwd', '', Text_, Err),
    'nor reach outside the repository');
  AssertFalse(DocRead(Dir, 'no-such-page', '', Text_, Err),
    'an unknown page is refused');
  AssertContains(Err, 'validation.md',
    'and the refusal lists what there is');

  AssertFalse(DocRead(Dir, 'validation', 'No such section', Text_, Err),
    'an unknown section is refused');
  AssertContains(Err, 'Across a redirect',
    'and that refusal lists the sections');
end;

procedure TestMcpProtocol;
var
  A: TArena;
  R: string;

  function Call_(const Line_: string): string;
  begin
    A.Reset;
    Result := McpHandle(A, Line_);
  end;

begin
  A := TArena.Create(16 * 1024);
  try
    R := Call_('{"jsonrpc":"2.0","id":1,"method":"initialize","params":' +
      '{"protocolVersion":"2025-06-18","capabilities":{},' +
      '"clientInfo":{"name":"probe","version":"1"}}}');
    AssertContains(R, '"id":1', 'the id comes back');
    AssertContains(R, '"jsonrpc":"2.0"', 'and the envelope');
    AssertContains(R, '"protocolVersion":"2025-06-18"',
      'the version the client asked for');
    AssertContains(R, '"serverInfo"', 'the server names itself');
    AssertContains(R, AskrVersion, 'with the framework version');
    AssertContains(R, '"tools"', 'and declares the tools capability');

    { Declaring a capability we do not serve is worse than declaring none:
      the client then calls a method that answers -32601. }
    AssertEqual(Pos('"resources"', R), 0, 'and nothing it cannot serve');
    AssertEqual(Pos('"prompts"', R), 0, 'nor prompts');

    { A notification has no id and gets no reply at all. Answer one and the
      client matches it to a request it never sent. }
    R := Call_('{"jsonrpc":"2.0","method":"notifications/initialized"}');
    AssertEqual(R, '', 'a notification gets no reply');

    R := Call_('{"jsonrpc":"2.0","id":2,"method":"tools/list"}');
    AssertContains(R, '"tools":[]', 'the tool list is empty for now');
    AssertContains(R, '"id":2', 'and carries its own id');

    R := Call_('{"jsonrpc":"2.0","id":3,"method":"ping"}');
    AssertContains(R, '"result":{}', 'ping answers');

    { A string id echoed back as a number is a different id, and the client
      will not match it. }
    R := Call_('{"jsonrpc":"2.0","id":"abc","method":"ping"}');
    AssertContains(R, '"id":"abc"', 'a string id stays a string');

    R := Call_('{"jsonrpc":"2.0","id":4,"method":"tools/call","params":' +
      '{"name":"nope","arguments":{}}}');
    AssertContains(R, '"error"', 'an unknown tool is an error');
    AssertContains(R, 'nope', 'and the error names it');

    R := Call_('{"jsonrpc":"2.0","id":5,"method":"no/such"}');
    AssertContains(R, '-32601', 'an unknown method is -32601');

    { The client sent something that is not JSON at all. The reply has to
      be JSON anyway, or the transport is finished. }
    R := Call_('{not json');
    AssertContains(R, '-32700', 'unparseable input is -32700');
    AssertContains(R, '"id":null', 'with a null id');

    AssertEqual(Call_(''), '', 'a blank line is not a message');
  finally
    A.Free;
  end;
end;

begin
  Group('Scheduler');
  Group('MCP');
  Test('the handshake, the tool list and the error shapes', @TestMcpProtocol);

  Group('The public origin');
  Test('app.url is configuration, never the request', @TestAppUrl);

  Group('Crawlers');
  Test('the sitemap is valid XML, absolute, and split at the limit',
    @TestSitemap);
  Test('robots.txt is closed unless the environment is production',
    @TestRobots);

  Group('Docs');
  Test('search is exact, and a name that does not exist is not found',
    @TestDocsSearchAndRead);
  Test('every link inside docs/ goes somewhere', @TestDocLinks);

  Group('Compiler diagnostics');
  Test('fpc diagnostics parse the same on every compiler and architecture',
    @TestDiagFormat);

  Group('Bilder');
  Test('format and dimensions without decoding', @TestBildeHoder);
  Test('a file that lies about what it is, is caught', @TestBildeSikkerhet);
  Test('EXIF and GPS are removed without touching the pixels', @TestExifStripping);
  Test('resizing and conversion (libvips)', @TestVips);

  Test('lauf has the same version as the framework', @TestLaufFoelgerRammeverket);
  Test('semver is compared as numbers, not as text', @TestSemVerSammenligning);
  Test('an interval runs when it falls due', @TestIntervall);
  Test('daily runs once a day', @TestDaglig);
  Test('weekly runs once a week', @TestUkentlig);
  Test('skips when the queue is still waiting', @TestHoppOverNaarKoenVenter);
  Test('the schedule can be read', @TestBeskrivelse);

  Group('The durable queue');
  Test('the jobs survive a restart', @TestDurableSurvivesRestart);
  Test('a failed job lands in the failed table and can be put back',
    @TestDurableFailsAndGivesUp);
  Test('a job with no handler does not disappear', @TestDurableUnknownJob);
  Test('a delay, and binary is rejected', @TestDurableDelayAndBinary);
  Test('an abandoned reservation is released', @TestDurableAbandonedReservation);

  Group('Sesjoner');
  Test('a round trip with a cookie', @TestSessionRoundTrip);
  Test('flash lives exactly one request', @TestFlashLeverEnRequest);
  Test('validation errors survive a redirect',
    @TestValideringsfeilOverlevererOmdirigering);
  Test('Inertia carries flash whatever the key', @TestInertiaFlashUansettNokkel);
  Test('the session does not leak out of the request',
    @TestSesjonenLekkerIkkeUtAvRequesten);

  Group('API tokens');
  Test('hashed at rest, scoped, revocable, and never from a URL',
    @TestApiTokens);

  Group('Field specs');
  Test('name:type into a model and a migration, and what is refused',
    @TestFieldSpecs);
  Test('a new migration never shares a version with one that is there',
    @TestNextVersion);
  Test('EmptyIsNull marks a string, and refuses anything else',
    @TestEmptyIsNull);

  Group('Unset dates');
  Test('an unset date is blank to a form, to JSON and to the rules',
    @TestUnsetDates);

  Group('Columns the model owns');
  Test('a request does not set them, and the document says so', @TestOwnedColumns);

  Group('Zero is null');
  Test('a reference to no row is NULL, null and blank', @TestZeroIsNull);

  Group('make resource');
  Test('what it writes, held against what it has to be', @TestResourceFiles);

  Group('Resource plan');
  Test('a table read into a resource, and the tables that cannot be one',
    @TestResourcePlan);

  Group('OpenAPI');
  Test('generated from the models and the routes, and checked against both',
    @TestOpenApi);

  Group('CORS');
  Test('closed until somebody says otherwise, and matched exactly',
    @TestCors);

  Group('Rate limiting');
  Test('a bucket per caller, refilled, with a ceiling on the table',
    @TestRateLimiting);

  Group('What an error looks like');
  Test('a machine client is never given a page, and never a redirect',
    @TestApiErrorNegotiation);

  Group('CSRF');
  Test('rejects without a token', @TestCsrfAvviserUtenToken);
  Test('accepts a field, X-CSRF-Token and X-XSRF-Token',
    @TestCsrfGodtarAlleTreKilder);
  Test('the token is stable and bound to the session',
    @TestCsrfTokenStablePerSession);
  Test('an exception for webhooks', @TestCsrfUnntakForWebhooks);
  Test('the session cookie and the XSRF cookie live side by side',
    @TestCsrfCookiesSideBySide);
  Test('an Inertia page makes the token, so a form from it is accepted',
    @TestCsrfInertiaPage);
  Test('a refusal a handler raises is an answer, and the after-filters run',
    @TestClientAnswersRefusals);

  Group('Auth');
  Test('signing in changes the session id, signing out clears it', @TestAuthInnOgUt);
  Test('remember me is signed, expires and can be cleared', @TestAuthHuskMeg);
  Test('gates answer no by default', @TestAuthGates);
  Test('RequireAuth redirects, but gives 401 to JSON', @TestAuthRequire);
  Test('the user is looked up once per request',
    @TestAuthBrukeroppslagCaches);

  Group('Logg');
  Test('levels filter', @TestLoggNivaa);
  Test('the text format quotes when it has to', @TestLoggTekstformat);
  Test('the json is valid, with numbers as numbers', @TestLoggJson);
  Test('an exception becomes its own fields', @TestLoggException);
  Test('a file is opened for appending', @TestLogToFile);

  Group('Konfigurasjon');
  Test('the environment beats .env beats askr.toml', @TestConfigLayers);
  Test('the report does not show secrets', @TestConfigReport);
  Test('APP_ENV and RequireEnv', @TestMiljoe);

  Group('HTTP-klient');
  Test('URLs are split correctly', @TestClientUrl);
  Test('against Askr''s own server', @TestClientAgainstOwnServer);
  Test('a redirect is followed, and stopped', @TestClientRedirect);
  Test('streaming, and the callback can say stop', @TestClientStreaming);
  Test('chunked is put back together', @TestClientChunked);
  Test('localhost resolves through /etc/hosts', @TestClientLocalhost);
  Test('the errors say what was wrong', @TestClientErrors);

  Group('AI');
  Test('the request has the right shape', @TestAiRequestform);
  Test('replies are taken apart, errors become errors', @TestAiReplyAndError);
  Test('SSE is reassembled, the callback can stop it', @TestAiStroemming);
  Test('the tool loop runs, fails gracefully and has a cap', @TestAiVerktoey);
  Test('structured output is forced through a tool',
    @TestAiStrukturert);

  Group('Mail');
  Test('a message renders as RFC 5322', @TestMessageRenders);
  Test('text and html become multipart', @TestMultipart);
  Test('bcc is a recipient, but not in the head', @TestBccSkjulesIHodet);
  Test('a message with no sender is rejected', @TestManglerAvsender);
  Test('the transport is chosen by mail.transport', @TestMailFraConfig);
  Test('SMTP AUTH PLAIN is encoded the way SASL says', @TestSmtpAuthPlain);
  Test('SMTP falls back to AUTH LOGIN when PLAIN is not offered',
    @TestSmtpAuthLogin);
  Test('the password never goes in the clear unless somebody said so',
    @TestSmtpAuthKreverKryptering);
  Test('a mechanism we cannot do is an error', @TestSmtpAuthUkjentMekanisme);
  Test('with no username no AUTH is sent', @TestSmtpWithoutUser);

  Group('Resend');
  Test('the request has the right shape', @TestResendForm);
  Test('reply-to becomes its own field, other heads become headers',
    @TestResendReplyTo);
  Test('fields with no content are not written out', @TestResendIngenHoder);
  Test('the idempotency key is sent along', @TestResendIdempotens);
  Test('the same message gives the same key across a retry',
    @TestResendSameMessageSameKey);
  Test('an error becomes EResendError with a status and a type', @TestResendErrors);
  Test('a rate limit can be retried, a quota cannot',
    @TestResendRateLimit);
  Test('an unknown error shape still gives a usable message',
    @TestResendUkjentFeilform);
  Test('a message with no body is rejected before the network', @TestResendEmptyBody);
  Test('the key is not in Describe', @TestResendLekkerIkkeNoekkel);
  Test('the headers are in the bytes on the wire', @TestResendPaaLufta);

  Group('The test client');
  Test('routes, parameters and a body without a socket', @TestClientAgainstRouter);
  Test('the arena levels off', @TestArenaFlaterUt);
  Test('the welcome page answers with no build step', @TestVelkomstside);
  Test('.env is read, and the environment wins over it', @TestEnv);

  InitCriticalSection(DurableLock);

  { The server the client tests call. Port 0 lets the kernel choose, so
    that the suites can run in parallel without fighting over ports — the
    same move as the end-to-end part of askr_tests. }
  EkkoH := TEkkoServer.Create;
  EkkoOpts := DefaultServerOptions;
  EkkoOpts.Port := 0;
  EkkoOpts.Workers := 2;
  EkkoSrv := TAskrServer.Create(EkkoOpts);
  EkkoSrv.SetHandler(EkkoH.Handle);
  EkkoSrv.Start;
  ClientPort := EkkoSrv.BoundPort;

  Brukere[0] := TUser.Create;
  Brukere[0].Name_ := 'Ada';
  Brukere[0].ErAdmin := True;
  Brukere[1] := TUser.Create;
  Brukere[1].Name_ := 'Grace';
  Brukere[1].ErAdmin := False;

  WriteLn('Askr — runtime tests (written with Askr.Testing)');
  { The server is not stopped here: RunTestsAndHalt calls Halt, and the
    process takes it with it. Cleaning up after Halt is not possible
    anyway. }
  RunTestsAndHalt;
end.
