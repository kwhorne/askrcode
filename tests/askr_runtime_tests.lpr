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
  Askr.Urd.Driver, Askr.Urd.Model, Askr.Urd.Query, Askr.Urd.Sqlite,
  Askr.Core.Crypto,
  Askr.Urd.Pool,
  Askr.Queue, Askr.Queue.Db, Askr.Scheduler, Askr.Session, Askr.Csrf,
  Askr.Auth, Askr.Mail, Askr.Mail.Resend, Askr.Ai, Askr.Inertia,
  Askr.Testing,
  Askr.Core.Version, Askr.Image, Askr.Image.Vips, Askr.Cli.Diag, Askr.Cli.Mcp, Askr.Cli.Docs;

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

    Res := AuthK.WithHeader('Accept', 'application/json').Get('/skjult');
    AssertEqual(Res.StatusCode, 401, 'and a JSON request too');

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

  Group('Docs');
  Test('search is exact, and a name that does not exist is not found',
    @TestDocsSearchAndRead);

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

  Group('CSRF');
  Test('rejects without a token', @TestCsrfAvviserUtenToken);
  Test('accepts a field, X-CSRF-Token and X-XSRF-Token',
    @TestCsrfGodtarAlleTreKilder);
  Test('the token is stable and bound to the session',
    @TestCsrfTokenStablePerSession);
  Test('an exception for webhooks', @TestCsrfUnntakForWebhooks);
  Test('the session cookie and the XSRF cookie live side by side',
    @TestCsrfCookiesSideBySide);

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
