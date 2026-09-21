{ Tester for kjøretidsdelene av fase 2, skrevet med Askr.Testing.

  Denne fila er også demonstrasjonen av rammeverket: ruteren testes uten
  socket, databasen er sqlite::memory:, og arenaen hevdes om direkte. }
program AskrRuntimeTests;

{$mode Delphi}{$H+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  SysUtils, Classes, StrUtils, Sockets, BaseUnix,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Clock, Askr.Core.Json,
  Askr.Core.Env, Askr.Core.Config, Askr.Core.Log,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response, Askr.Http.Router,
  Askr.Http.Welcome, Askr.Http.Server, Askr.Http.Client,
  Askr.Urd.Driver, Askr.Urd.Model, Askr.Urd.Query, Askr.Urd.Sqlite,
  Askr.Core.Crypto,
  Askr.Urd.Pool,
  Askr.Queue, Askr.Queue.Db, Askr.Scheduler, Askr.Session, Askr.Csrf,
  Askr.Auth, Askr.Mail, Askr.Mail.Resend, Askr.Ai, Askr.Inertia,
  Askr.Testing,
  Askr.Core.Version, Askr.Image, Askr.Image.Vips;

{ -------------------------------------------------------------- versjon -- }

{ En utgivelse er ett tall over to økosystemer: Pascal-kilden og
  @askrcode/lauf på npm. Driver de fra hverandre, får man en komponent
  hvis klienthalvdel ikke passer serverhalvdelen, og ingenting sier fra
  før noe slutter å virke. Det HADDE drevet: CLI-en sto på 0.6.0 mens
  package.json sto på 0.1.0. Denne testen er grunnen til at det ikke kan
  skje igjen. }
procedure TestLaufFoelgerRammeverket;
var
  F: TStringList;
  I, A, B: Integer;
  Linje, Fant, Sti: string;
begin
  Fant := '';
  { Kjøres fra repo-rota av ./askr test. Finner vi ikke fila, er det
    ikke en grunn til å påstå at versjonene stemmer. }
  Sti := 'frontend/lauf/package.json';
  AssertTrue(FileExists(Sti), 'package.json finnes (kjør fra repo-rota)');
  F := TStringList.Create;
  try
    F.LoadFromFile(Sti);
    for I := 0 to F.Count - 1 do
    begin
      Linje := Trim(F[I]);
      if Pos('"version"', Linje) <> 1 then
        Continue;
      A := Pos(':', Linje);
      A := Pos('"', Linje, A);
      B := Pos('"', Linje, A + 1);
      Fant := Copy(Linje, A + 1, B - A - 1);
      Break;
    end;
  finally
    F.Free;
  end;
  AssertEqual(Fant, AskrVersion,
    'frontend/lauf/package.json må ha samme versjon som Askr.Core.Version');
end;

procedure TestSemVerSammenligning;
begin
  AssertTrue(CompareSemVer('0.6.0', '0.7.0') < 0, '0.6.0 < 0.7.0');
  AssertTrue(CompareSemVer('0.10.0', '0.9.0') > 0, '0.10.0 > 0.9.0 (ikke tekst)');
  AssertEqual(CompareSemVer('1.2.3', 'v1.2.3'), 0, 'v-prefiks er samme versjon');
  { Semver-regelen som er lett å bomme på: rc kommer FØR utgivelsen. }
  AssertTrue(CompareSemVer('0.7.0-rc.1', '0.7.0') < 0, 'rc før utgivelsen');
  AssertTrue(not ParseSemVer('ikke-en-versjon').Valid, 'søppel er ugyldig');
  AssertTrue(not ParseSemVer('1.2.3.4').Valid, 'fire ledd er ikke semver');

  { npm-regelen for nullmajor: ^0.6.0 låser minor, fordi et
    nullmajor-prosjekt bryter ting i minor. }
  AssertTrue(SatisfiesRange('0.6.3', '^0.6.0'), '0.6.3 passer ^0.6.0');
  AssertTrue(not SatisfiesRange('0.7.0', '^0.6.0'), '0.7.0 passer ikke ^0.6.0');
  AssertTrue(SatisfiesRange('1.9.0', '^1.2.0'), '1.9.0 passer ^1.2.0');
  AssertTrue(not SatisfiesRange('0.5.0', '^0.6.0'), 'eldre passer aldri');
  AssertTrue(SatisfiesRange('0.6.9', '~0.6.0'), '~ låser major.minor');
  AssertTrue(not SatisfiesRange('0.7.0', '~0.6.0'), '~ slipper ikke minor');
end;

{ ------------------------------------------------------------ scheduler -- }

var
  Q: TQueue;
  S: TScheduler;

procedure IngenJobb(const Ctx: TJobContext);
begin
end;

procedure SchedulerOppsett;
begin
  Q := TQueue.Create(1, 1);
  Q.Handle('a', @IngenJobb);
  Q.Handle('b', @IngenJobb);
  S := TScheduler.Create(Q);
end;

procedure SchedulerRydd;
begin
  S.Free;
  Q.Free;
end;

procedure TestIntervall;
begin
  SchedulerOppsett;
  try
    S.EverySeconds(10, 'a');
    AssertEqual(S.Count, 1, 'én oppføring');
    { Første kjøring er om ti sekunder, ikke nå. }
    AssertEqual(S.Tick(UnixNow), 0, 'ikke forfalt ennå');
    AssertEqual(S.Tick(UnixNow + 10), 1, 'forfalt etter ti sekunder');
    AssertEqual(S.Tick(UnixNow + 10), 0, 'ikke to ganger på samme tikk');
    AssertEqual(S.Tick(UnixNow + 20), 1, 'og så igjen');
    AssertEqual(Q.Pending, 2, 'to jobber havnet på køen');
  finally
    SchedulerRydd;
  end;
end;

procedure TestDaglig;
var
  Naa: Int64;
  Kjort, I: Integer;
begin
  SchedulerOppsett;
  try
    S.DailyAt(3, 30, 'a');
    Naa := UnixNow;
    Kjort := 0;
    { Ett døgn, time for time: nøyaktig én kjøring. }
    for I := 0 to 24 do
      Kjort := Kjort + S.Tick(Naa + Int64(I) * 3600);
    AssertEqual(Kjort, 1, 'daglig jobb kjørte én gang på et døgn');
  finally
    SchedulerRydd;
  end;
end;

procedure TestUkentlig;
var
  Naa: Int64;
  Kjort, I: Integer;
begin
  SchedulerOppsett;
  try
    S.WeeklyAt(dowMonday, 8, 0, 'a');
    Naa := UnixNow;
    Kjort := 0;
    for I := 0 to 7 * 24 do
      Kjort := Kjort + S.Tick(Naa + Int64(I) * 3600);
    AssertEqual(Kjort, 1, 'ukentlig jobb kjørte én gang på en uke');
  finally
    SchedulerRydd;
  end;
end;

procedure TestHoppOverNaarKoenVenter;
var
  Naa: Int64;
begin
  SchedulerOppsett;
  try
    S.EverySeconds(1, 'a');
    S.SkipWhenPending;
    Naa := UnixNow;
    S.Tick(Naa + 1);
    AssertEqual(Q.Pending, 1, 'første kjøring havnet på køen');
    { Jobben ligger fortsatt der, så neste skal hoppes over. }
    S.Tick(Naa + 2);
    AssertEqual(Q.Pending, 1, 'stabler seg ikke oppå en jobb som venter');
  finally
    SchedulerRydd;
  end;
end;

procedure TestBeskrivelse;
var
  L: TStringList;
begin
  SchedulerOppsett;
  L := TStringList.Create;
  try
    S.EveryMinutes(5, 'rydd-opp');
    S.DailyAt(3, 30, 'nattjobb');
    S.Describe(L);
    AssertEqual(L.Count, 2, 'to linjer');
    AssertContains(L.Text, 'every 5 minutes', 'intervall beskrives lesbart');
    AssertContains(L.Text, 'daily at 03:30', 'daglig beskrives lesbart');
  finally
    L.Free;
    SchedulerRydd;
  end;
end;

{ -------------------------------------------------------------- sesjoner -- }

var
  Store: TSessionStore;
  KlientKake: string;

function LagReq(A: TArena; const Kake: string): TRequest;
var
  Prev: TArena;
  Head: string;
begin
  Head := 'GET / HTTP/1.1'#13#10'Host: t';
  if Kake <> '' then
    Head := Head + #13#10'Cookie: askr_session=' + Kake;
  Prev := UseArena(A);
  try
    Result := TRequest.Create;
    Result.ParseHead(StrDup(A, Head), DefaultMaxBodyBytes);
  finally
    UseArena(Prev);
  end;
end;

function KakeFra(R: TResponse; A: TArena): string;
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

procedure TestSesjonRundtur;
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
    { Første request: ingen kake, ny sesjon. }
    Req := LagReq(A, '');
    Sess := Store.Start(Req);
    AssertTrue(Sess.IsNew, 'ny sesjon uten kake');
    AssertEqual(Length(Sess.Id), 32, 'id er 32 hex-tegn');
    Sess.Put('bruker', 'knut');
    R := Respond(200);
    Store.Commit(Sess, R);
    KlientKake := KakeFra(R, A);
    AssertEqual(Length(KlientKake), 32, 'kaka ble satt');

    { Andre request: samme kake, samme data. }
    A.Reset;
    Req := LagReq(A, KlientKake);
    Sess := Store.Start(Req);
    AssertFalse(Sess.IsNew, 'sesjonen ble gjenopptatt');
    AssertEqual(Sess.Get('bruker'), 'knut', 'verdien overlevde');
    AssertEqual(Store.Resumed, 1, 'telt som gjenopptatt');

    { En ukjent kake gir en ny sesjon, ikke en feil. }
    A.Reset;
    Req := LagReq(A, '00000000000000000000000000000000');
    Sess := Store.Start(Req);
    AssertTrue(Sess.IsNew, 'ukjent id gir ny sesjon');
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
  Kake: string;
begin
  Store := TSessionStore.Create(3600);
  A := TArena.Create(16 * 1024);
  Prev := UseArena(A);
  try
    Req := LagReq(A, '');
    Sess := Store.Start(Req);
    Sess.Flash('suksess', 'Lagret');
    AssertFalse(Sess.HasFlash('suksess'),
      'det man skriver er ikke lesbart i samme request');
    R := Respond(200);
    Store.Commit(Sess, R);
    Kake := KakeFra(R, A);

    { Neste request: nå er den lesbar. }
    A.Reset;
    Req := LagReq(A, Kake);
    Sess := Store.Start(Req);
    AssertTrue(Sess.HasFlash('suksess'), 'lesbar i neste request');
    AssertEqual(Sess.GetFlash('suksess'), 'Lagret', 'riktig verdi');
    R := Respond(200);
    Store.Commit(Sess, R);

    { Og borte i den etter. }
    A.Reset;
    Req := LagReq(A, Kake);
    Sess := Store.Start(Req);
    AssertFalse(Sess.HasFlash('suksess'), 'borte i tredje request');
  finally
    UseArena(Prev);
    A.Free;
    Store.Free;
  end;
end;

{ Enhver flash-nøkkel skal ut i Inertia-payloaden, ikke bare én bestemt.

  Vakten i BuildPayload spurte før etter nøkkelen 'suksess' bokstavelig talt,
  mens WriteFlashInto skriver alle nøkler unntatt _errors. En app som gjorde
  Session.Flash('error', ...) — slik det genererte auth-stillaset gjør — fikk
  meldingen stille forkastet. Testen bruker med vilje en annen nøkkel enn den
  som sto der. }
procedure TestInertiaFlashUansettNokkel;
var
  A: TArena;
  PrevA: TArena;
  PrevR: TRequest;
  PrevS: TSession;
  Req: TRequest;
  Sess: TSession;
  R: TResponse;
  Kake, Body: string;

  function InertiaReq(const MedKake: string): TRequest;
  var
    P: TArena;
  begin
    P := UseArena(A);
    try
      Result := TRequest.Create;
      Result.ParseHead(StrDup(A, 'GET / HTTP/1.1'#13#10'Host: t'#13#10 +
        'X-Inertia: true' +
        IfThen(MedKake <> '', #13#10'Cookie: askr_session=' + MedKake, '')),
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

    { Skriv en flash under en annen nøkkel enn 'suksess'. }
    Req := LagReq(A, '');
    Sess := Store.Start(Req);
    Sess.Flash('error', 'That link is no longer valid.');
    R := Respond(200);
    Store.Commit(Sess, R);
    Kake := KakeFra(R, A);

    { Neste request: den skal være med i payloaden. }
    A.Reset;
    Req := InertiaReq(Kake);
    UseRequest(Req);
    Sess := Store.Start(Req);
    UseSession(Sess);
    AssertTrue(Sess.HasAnyFlash, 'sesjonen har en lesbar flash');
    Body := Inertia('Home', ['x', Int64(1)]).Body.ToString;
    AssertContains(Body, '"error":"That link is no longer valid."',
      'en flash under en annen nøkkel enn suksess kommer med');

    { Og vakten skal fortsatt vokte: uten flash og uten feil, ingen
      flash-nøkkel i det hele tatt. }
    A.Reset;
    UseSession(nil);
    Req := InertiaReq('');
    UseRequest(Req);
    Sess := Store.Start(Req);
    UseSession(Sess);
    AssertFalse(Sess.HasAnyFlash, 'ny sesjon har ingen flash');
    Body := Inertia('Home', ['x', Int64(1)]).Body.ToString;
    AssertNotContains(Body, '"flash"',
      'uten flash skrives ikke flash-objektet');

    { _errors teller ikke som en melding — den er en egen prop. }
    A.Reset;
    UseSession(nil);
    Req := LagReq(A, '');
    Sess := Store.Start(Req);
    Sess.FlashErrorsJson(Str('{"name":"is required"}'));
    R := Respond(302);
    Store.Commit(Sess, R);
    Kake := KakeFra(R, A);

    A.Reset;
    Req := InertiaReq(Kake);
    UseRequest(Req);
    Sess := Store.Start(Req);
    UseSession(Sess);
    AssertFalse(Sess.HasAnyFlash,
      'valideringsfeil er ikke en flash-melding');
    AssertTrue(Sess.HasErrors, 'men de er der som feil');
    Body := Inertia('Home', ['x', Int64(1)]).Body.ToString;
    AssertContains(Body, '"errors"', 'og de kommer ut som errors');
  finally
    UseSession(PrevS);
    UseRequest(PrevR);
    UseArena(PrevA);
    A.Free;
    Store.Free;
  end;
end;

{ Sesjonen må ikke overleve requesten som en threadvar.

  Den lever i request-arenaen og forsvinner ved Reset. Blir den stående,
  ser neste request på den workeren en peker inn i minne arenaen har
  gjenbrukt — og da leser den et objekt som ikke finnes lenger.

  Utgangen som slapp forbi var den vanligste av dem alle: en anonym
  besøkende som starter en sesjon uten å skrive til den. Den ble oppdaget
  som EAccessViolation da en nettleser hentet en css-fil rett etter en
  side på samme tilkobling, på et ekte nettsted bygget med rammeverket.
  Den store fila fikk en ny arenablokk og gikk stille forbi; den lille
  havnet oppå det gamle objektet.

  Testen går gjennom ruteren, altså den veien en ekte request går. }
function TomHandler(Req: TRequest): TResponse;
begin
  Result := RespondText('ok');
end;

function SkrivOgSvar(Req: TRequest): TResponse;
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

    { 1. Anonym besøkende: sesjonen startes og skrives aldri til. Den skal
         verken lagres eller få en kake — og den skal ikke bli stående. }
    Req := LagReq(A, '');
    Res := R.Handle(Req);
    AssertStatus(Res, 200, 'requesten gikk gjennom');
    AssertNil(CurrentSession,
      'en sesjon ingen skrev til blir ikke stående etter requesten');

    { 2. Og en som ble skrevet til, ryddes også. }
    A.Reset;
    Req := LagReq(A, '');
    R.Free;
    R := TRouter.Create;
    UseSessions(R);
    R.Get('/', SkrivOgSvar);
    Res := R.Handle(Req);
    AssertNil(CurrentSession, 'også når den ble lagret');
    AssertTrue(KakeFra(Res, A) <> '', 'og den fikk en kake');
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
  Kake: string;
begin
  Store := TSessionStore.Create(3600);
  A := TArena.Create(16 * 1024);
  Prev := UseArena(A);
  try
    Req := LagReq(A, '');
    Sess := Store.Start(Req);
    Sess.FlashErrorsJson(Str('{"name":"is required"}'));
    R := Respond(302);
    Store.Commit(Sess, R);
    Kake := KakeFra(R, A);

    { Dette er avviket fra steg 5, lukket: feilene overlever omdirigeringen. }
    A.Reset;
    Req := LagReq(A, Kake);
    Sess := Store.Start(Req);
    AssertTrue(Sess.HasErrors, 'feilene overlevde omdirigeringen');
    AssertContains(Sess.ErrorsJson, 'is required', 'med innholdet i behold');
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

procedure TestMeldingRendres;
var
  Msg: TMailMessage;
  Raw: string;
begin
  NullT := TNullTransport.Create;
  M := TMailer.Create(NullT, True);
  try
    M.SetDefaultFrom('ingen-svar@gets.no', 'Askr');
    Msg := M.Message_
      .AddTo('kh@gets.no', 'Knut W. Hørne')
      .Subject('Kvittering')
      .Text('Takk for bestillingen.');
    M.Send(Msg);

    Raw := NullT.LastMessage;
    AssertContains(Raw, 'From: "Askr" <ingen-svar@gets.no>', 'avsender');
    AssertContains(Raw, 'To: "Knut W. Hørne" <kh@gets.no>', 'mottaker');
    AssertContains(Raw, 'Subject: Kvittering', 'emne');
    AssertContains(Raw, 'Content-Type: text/plain; charset=utf-8', 'type');
    AssertContains(Raw, 'Takk for bestillingen.', 'innhold');
    AssertContains(Raw, 'Message-ID: <', 'message-id');
    AssertEqual(M.Sent, 1, 'talt som sendt');
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
      .Subject('Begge deler')
      .Text('ren tekst')
      .Html('<p>html</p>'));
    Raw := NullT.LastMessage;
    AssertContains(Raw, 'multipart/alternative', 'multipart når begge er satt');
    AssertContains(Raw, 'ren tekst', 'tekstdelen');
    AssertContains(Raw, '<p>html</p>', 'html-delen');
  finally
    M.Free;
  end;
end;

procedure TestBccSkjulesIHodet;
var
  Raw: string;
  Mottakere: TStringArray;
  Msg: TMailMessage;
begin
  NullT := TNullTransport.Create;
  M := TMailer.Create(NullT, True);
  try
    Msg := M.Message_.From('a@b.no').AddTo('c@d.no')
      .Bcc('skjult@e.no').Subject('x').Text('y');
    Mottakere := Msg.AllRecipients;
    AssertEqual(Length(Mottakere), 2, 'bcc er med i mottakerlista');
    M.Send(Msg, False);
    Raw := NullT.LastMessage;
    AssertNotContains(Raw, 'skjult@e.no', 'men ikke i hodet');
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
    AssertTrue(Kastet, 'melding uten avsender avvises');
  finally
    Msg.Free;
    M.Free;
  end;
end;

{ ------------------------------------------------------------- resend -- }

{ Transporten får aldri lov til å sende noe ekte her. Alt går gjennom
  TFakeResendHttp, som tar vare på JSON-en og svarer med det testen la i
  kø — samme grep som TFakeAiTransport. }
function NyResend(out H: TFakeResendHttp): TResendTransport;
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
  T := NyResend(H);
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

    AssertEqual(H.Sent.Count, 1, 'én forespørsel');
    J := H.Sent[0];
    AssertContains(J, '"from":"\"Example, Inc.\" <orders@example.com>"',
      'avsender med sitert navn');
    AssertContains(J, '"to":["\"Ada Lovelace\" <customer@example.com>"]',
      'to er en liste');
    AssertContains(J, '"cc":["sales@example.com"]', 'cc');
    AssertContains(J, '"bcc":["audit@example.com"]', 'bcc');
    AssertContains(J, '"subject":"Your order"', 'emne');
    AssertContains(J, '"html":"<p>Thank you.</p>"', 'html');
    AssertContains(J, '"text":"Thank you."', 'tekst');
    AssertEqual(H.LastUrl, 'https://api.resend.com/emails', 'endepunkt');
    AssertEqual(H.LastApiKey, 're_test_nokkel', 'nøkkelen gis til HTTP-laget');
    AssertEqual(T.LastId, '49a3999c-0ce1-4ea6-ab68-afcd6dc2e794',
      'id-en fra svaret');
    AssertEqual(T.Count, 1, 'talt som sendt');
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
  T := NyResend(H);
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
      'reply_to blir et eget felt, som liste');
    AssertContains(J, '"headers":{"X-Entity-Ref-ID":"42"}',
      'andre hoder havner i headers');
    { Resend avviser Reply-To som fritt hode. Står den begge steder, er
      det tilfeldig hvilken som vinner. }
    AssertNotContains(J, '"headers":{"Reply-To"',
      'reply-to står ikke også i headers');
  finally
    T.Free;
  end;
end;

procedure TestResendIngenHoder;
var
  T: TResendTransport;
  H: TFakeResendHttp;
begin
  T := NyResend(H);
  try
    H.Queue('{"id":"x"}', 200);
    T.Send(TMailMessage.Create.From('a@example.com').AddTo('b@example.com')
      .Subject('s').Text('t'));
    { Et tomt headers-objekt er ikke feil, men det sier at vi skriver ut
      nøkler vi ikke har noe å fylle. }
    AssertNotContains(H.Sent[0], '"headers"',
      'ingen headers-nøkkel uten hoder');
    AssertNotContains(H.Sent[0], '"cc"', 'ingen cc uten cc');
    AssertNotContains(H.Sent[0], '"html"', 'ingen html uten html');
  finally
    T.Free;
  end;
end;

procedure TestResendIdempotens;
var
  T: TResendTransport;
  H: TFakeResendHttp;
  Foerste: string;
begin
  T := NyResend(H);
  try
    H.Queue('{"id":"x"}', 200);
    T.Send(TMailMessage.Create.From('a@example.com').AddTo('b@example.com')
      .Subject('s').Text('t').Idempotency('order-1001-receipt'));
    AssertEqual(H.LastIdempotency, 'order-1001-receipt',
      'kallerens nøkkel brukes som den er');

    H.Queue('{"id":"y"}', 200);
    T.Send(TMailMessage.Create.From('a@example.com').AddTo('b@example.com')
      .Subject('s').Text('t'));
    Foerste := H.LastIdempotency;
    AssertTrue(Foerste <> '', 'uten egen nøkkel brukes message-id-en');
    AssertTrue(Foerste <> 'order-1001-receipt',
      'og den er ikke forrige melding sin');
  finally
    T.Free;
  end;
end;

procedure TestResendSammeMeldingSammeNoekkel;
var
  T: TResendTransport;
  H: TFakeResendHttp;
  M: TMailMessage;
  A, B: string;
begin
  { Det som gjør et gjenforsøk trygt: samme melding må gi samme nøkkel.
    Gjør den ikke det, får mottakeren to eposter av én jobb. }
  T := NyResend(H);
  M := TMailMessage.Create.From('a@example.com').AddTo('b@example.com')
    .Subject('s').Text('t');
  try
    H.Queue('{"id":"x"}', 200);
    T.Send(M);
    A := H.LastIdempotency;
    H.Queue('{"id":"x"}', 200);
    T.Send(M);
    B := H.LastIdempotency;
    AssertEqual(A, B, 'samme melding gir samme idempotensnøkkel');
  finally
    M.Free;
    T.Free;
  end;
end;

procedure TestResendFeil;
var
  T: TResendTransport;
  H: TFakeResendHttp;
  Status: Integer;
  Navn: string;
  KanProeves, Kastet: Boolean;
begin
  T := NyResend(H);
  try
    H.Queue('{"statusCode":422,"message":"Invalid `to` field.",' +
      '"name":"validation_error"}', 422);
    Kastet := False;
    Status := 0;
    Navn := '';
    KanProeves := True;
    try
      T.Send(TMailMessage.Create.From('a@example.com')
        .AddTo('b@example.com').Subject('s').Text('t'));
    except
      on E: EResendError do
      begin
        Kastet := True;
        Status := E.Status;
        Navn := E.Name_;
        KanProeves := E.Retryable;
        AssertContains(E.Message, 'Invalid `to` field.',
          'providerens egen tekst kommer med');
        AssertContains(E.Message, 'validation_error', 'og typen');
      end;
    end;
    AssertTrue(Kastet, '422 kaster');
    AssertEqual(Status, 422, 'status');
    AssertEqual(Navn, 'validation_error', 'typen slik API-et skriver den');
    AssertTrue(not KanProeves, 'en valideringsfeil prøves ikke om igjen');
    AssertEqual(T.Count, 0, 'og telles ikke som sendt');
  finally
    T.Free;
  end;
end;

procedure TestResendRateLimit;
var
  T: TResendTransport;
  H: TFakeResendHttp;
  KanProeves: Boolean;
begin
  T := NyResend(H);
  try
    H.Queue('{"message":"Too many requests.",' +
      '"name":"rate_limit_exceeded"}', 429);
    KanProeves := False;
    try
      T.Send(TMailMessage.Create.From('a@example.com')
        .AddTo('b@example.com').Subject('s').Text('t'));
    except
      on E: EResendError do
        KanProeves := E.Retryable;
    end;
    AssertTrue(KanProeves, 'rate limit kan prøves om igjen');

    { Kvote er ikke det samme. Den går ikke over innenfor noen backoff en
      kø har, og skal til feiltabellen der noen ser den. }
    H.Queue('{"message":"Daily quota reached.",' +
      '"name":"daily_quota_exceeded"}', 429);
    KanProeves := True;
    try
      T.Send(TMailMessage.Create.From('a@example.com')
        .AddTo('b@example.com').Subject('s').Text('t'));
    except
      on E: EResendError do
        KanProeves := E.Retryable;
    end;
    AssertTrue(not KanProeves, 'kvote prøves ikke om igjen');

    H.Queue('{"message":"Something went wrong.",' +
      '"name":"application_error"}', 500);
    KanProeves := False;
    try
      T.Send(TMailMessage.Create.From('a@example.com')
        .AddTo('b@example.com').Subject('s').Text('t'));
    except
      on E: EResendError do
        KanProeves := E.Retryable;
    end;
    AssertTrue(KanProeves, '5xx kan prøves om igjen');
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
  { Feltet har hatt flere navn over tid, og en feilside kan være HTML.
    Ingen av delene skal gi en tom feilmelding. }
  T := NyResend(H);
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
    AssertContains(Msg, 'invalid_parameter', 'error_type leses også');

    H.Queue('<html><body>502 Bad Gateway</body></html>', 502);
    Msg := '';
    try
      T.Send(TMailMessage.Create.From('a@example.com')
        .AddTo('b@example.com').Subject('s').Text('t'));
    except
      on E: EResendError do
        Msg := E.Message;
    end;
    AssertContains(Msg, '502', 'statusen kommer med når kroppen ikke er JSON');
    AssertContains(Msg, 'Bad Gateway', 'og det serveren faktisk skrev');
  finally
    T.Free;
  end;
end;

procedure TestResendTomKropp;
var
  T: TResendTransport;
  H: TFakeResendHttp;
  Kastet: Boolean;
begin
  T := NyResend(H);
  try
    Kastet := False;
    try
      T.Send(TMailMessage.Create.From('a@example.com')
        .AddTo('b@example.com').Subject('s'));
    except
      on E: EMailError do
        Kastet := True;
    end;
    AssertTrue(Kastet, 'melding uten tekst og html avvises før nettverket');
    AssertEqual(H.Sent.Count, 0, 'og ingenting ble sendt');
  finally
    T.Free;
  end;
end;

procedure TestResendLekkerIkkeNoekkel;
var
  T: TResendTransport;
  H: TFakeResendHttp;
begin
  T := NyResend(H);
  try
    AssertNotContains(T.Describe, 're_test_nokkel',
      'Describe viser ikke nøkkelen');
    AssertContains(T.Describe, 'resend', 'men sier hvilken transport det er');
  finally
    T.Free;
  end;
end;

procedure TestMailFraConfig;
const
  Katalog = 'askr-mailcfg-test.tmp';
var
  T: TMailTransport;
  L: TStringList;
  Kastet: Boolean;
  Msg: string;
begin
  { Standarden er loggfila. Uten den ville et prosjekt uten oppsett
    forsøkt å sende ekte post i utvikling. }
  T := MailFromConfig;
  try
    AssertTrue(T is TLogTransport, 'uten oppsett er transporten log');
  finally
    T.Free;
  end;

  ForceDirectories(Katalog);
  L := TStringList.Create;
  try
    L.Add('[mail]');
    L.Add('transport = "sendgrid"');
    L.SaveToFile(Katalog + PathDelim + 'askr.toml');
  finally
    L.Free;
  end;

  Kastet := False;
  Msg := '';
  ClearConfig;
  try
    LoadConfig(Katalog);
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
    DeleteFile(Katalog + PathDelim + 'askr.toml');
    RemoveDir(Katalog);
  end;

  { Ikke et stille fall tilbake til log. En stavefeil i produksjon ville
    da sett ut som at posten gikk ut. }
  AssertTrue(Kastet, 'et ukjent transportnavn kaster');
  AssertContains(Msg, 'sendgrid', 'feilen sier hva som ble bedt om');
  AssertContains(Msg, 'resend',
    'og lista nevner resend, som er linket inn her');
end;

{ En server som tar vare på hele requesten og svarer som Resend.

  Den finnes fordi TFakeResendHttp hopper over nettopp det laget som
  setter headerne på lufta: en mutasjon som slettet Idempotency-Key kom
  gjennom hele suiten uten at noe sa fra. Her leses byte-ene som faktisk
  ble sendt. }
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
  Svar: string;
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
    Svar := '{"id":"ekko-1"}';
    Svar := 'HTTP/1.1 200 OK'#13#10 +
      'Content-Type: application/json'#13#10 +
      'Content-Length: ' + IntToStr(Length(Svar)) + #13#10 +
      'Connection: close'#13#10#13#10 + Svar;
    fpSend(S, PChar(Svar), Length(Svar), 0);
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
      AssertEqual(T.LastId, 'ekko-1', 'id-en leses ut av et ekte svar');
    finally
      T.Free;
    end;
    Srv.WaitFor;
    R := Srv.Request;

    AssertContains(R, 'POST /emails HTTP/1.1', 'metode og sti');
    { Det avgjørende: begge headerne skal faktisk ligge i byte-ene. }
    AssertContains(R, 'Authorization: Bearer re_hemmelig_nokkel',
      'nøkkelen går som Bearer');
    AssertContains(R, 'Idempotency-Key: job-77',
      'idempotensnøkkelen står i hodet, ikke bare i koden');
    AssertContains(R, 'Content-Type: application/json', 'innholdstypen');
    AssertContains(R, '"subject":"s"', 'kroppen kom med');
  finally
    Srv.Free;
  end;
end;

{ En SMTP-server som sier hva den kan og skriver ned samtalen.

  Den finnes for AUTH-stien. Passordet går over denne forbindelsen, og
  det er den ene koden i mailuniten der en feil ikke bare gir en epost
  som ikke kommer fram — den gir bort passordet. }
type
  TSmtpEkkoServer = class(TThread)
  private
    FLytt: TSocket;
    FPort: Word;
    FSamtale: string;
    FAuthLinje: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const AAuthLinje: string);
    property Port: Word read FPort;
    property Samtale: string read FSamtale;
  end;

constructor TSmtpEkkoServer.Create(const AAuthLinje: string);
var
  Addr: TInetSockAddr;
  Len: TSockLen;
  Ja: Integer;
begin
  FAuthLinje := AAuthLinje;
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
  Linje: string;
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
  Linje := '';
  repeat
    N := fpRecv(S, @C, 1, 0);
    if N <= 0 then
      Break;
    if C = #13 then
      Continue;
    if C <> #10 then
    begin
      Linje := Linje + C;
      Continue;
    end;

    FSamtale := FSamtale + Linje + #10;

    if IData then
    begin
      if Linje = '.' then
      begin
        IData := False;
        Si('250 2.0.0 Ok: queued');
      end;
    end
    else if Copy(UpperCase(Linje), 1, 4) = 'EHLO' then
    begin
      Si('250-ekko.example');
      if FAuthLinje <> '' then
        Si('250-' + FAuthLinje);
      Si('250 SIZE 35651584');
    end
    else if Copy(UpperCase(Linje), 1, 4) = 'AUTH' then
    begin
      if Copy(UpperCase(Linje), 1, 10) = 'AUTH LOGIN' then
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
    else if Copy(UpperCase(Linje), 1, 4) = 'QUIT' then
    begin
      Si('221 Bye');
      Break;
    end
    else if Copy(UpperCase(Linje), 1, 4) = 'DATA' then
    begin
      IData := True;
      Si('354 End data with <CR><LF>.<CR><LF>');
    end
    else
      Si('250 2.1.0 Ok');
    Linje := '';
  until False;
  CloseSocket(S);
  CloseSocket(FLytt);
end;

procedure SendMedAuth(Srv: TSmtpEkkoServer; const Bruker, Passord: string;
  Tillat: Boolean);
var
  T: TSmtpTransport;
  Msg: TMailMessage;
begin
  T := TSmtpTransport.Create('127.0.0.1', Srv.Port, smtpPlain);
  Msg := TMailMessage.Create;
  try
    T.AllowPlainAuth := Tillat;
    T.Credentials(Bruker, Passord);
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
    SendMedAuth(Srv, 'resend', 're_hemmelig', True);
    Srv.WaitFor;
    { SASL PLAIN er #0bruker#0passord i base64. Regnet ut for hånd her,
      slik at testen sjekker kodingen og ikke bare gjentar koden. }
    AssertContains(Srv.Samtale, 'AUTH PLAIN AHJlc2VuZAByZV9oZW1tZWxpZw==',
      'AUTH PLAIN med riktig SASL-koding');
    AssertContains(Srv.Samtale, 'MAIL FROM:<a@example.com>',
      'og sendingen fortsetter etterpå');
  finally
    Srv.Free;
  end;
end;

procedure TestSmtpAuthLogin;
var
  Srv: TSmtpEkkoServer;
begin
  { Bare LOGIN tilbudt. Uten denne grenen ville et eldre relé fått AUTH
    PLAIN det ikke forstår. }
  Srv := TSmtpEkkoServer.Create('AUTH LOGIN');
  try
    SendMedAuth(Srv, 'bruker', 'passord', True);
    Srv.WaitFor;
    AssertContains(Srv.Samtale, 'AUTH LOGIN', 'faller til LOGIN');
    AssertNotContains(Srv.Samtale, 'AUTH PLAIN',
      'og prøver ikke PLAIN den ikke tilbyr');
    AssertContains(Srv.Samtale, 'YnJ1a2Vy', 'brukernavnet i base64');
    AssertContains(Srv.Samtale, 'cGFzc29yZA==', 'passordet i base64');
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
  { Det viktigste i hele AUTH-stien: passordet skal ikke gå i klartekst
    med mindre noen har sagt det eksplisitt. }
  Srv := TSmtpEkkoServer.Create('AUTH PLAIN LOGIN');
  Kastet := False;
  Msg := '';
  try
    try
      SendMedAuth(Srv, 'bruker', 'passord', False);
    except
      on E: EMailError do
      begin
        Kastet := True;
        Msg := E.Message;
      end;
    end;
    AssertTrue(Kastet, 'AUTH over klartekst stoppes');
    AssertContains(Msg, 'in the clear', 'og sier hvorfor');
    AssertNotContains(Msg, 'passord', 'uten å gjenta passordet');
    AssertNotContains(Srv.Samtale, 'AUTH', 'ingenting ble sendt');
  finally
    Srv.Free;
  end;
end;

procedure TestSmtpAuthUkjentMekanisme;
var
  Srv: TSmtpEkkoServer;
  Kastet: Boolean;
begin
  { XOAUTH2-LOGIN inneholder «LOGIN» som delstreng. Et rått søk ville
    sagt ja og sendt AUTH LOGIN til en server som ikke har den. }
  Srv := TSmtpEkkoServer.Create('AUTH XOAUTH2-LOGIN CRAM-MD5');
  Kastet := False;
  try
    try
      SendMedAuth(Srv, 'bruker', 'passord', True);
    except
      on E: EMailError do
        Kastet := True;
    end;
    AssertTrue(Kastet, 'ingen mekanisme vi kan er en feil, ikke et forsøk');
    AssertNotContains(Srv.Samtale, 'AUTH LOGIN',
      'delstrengen XOAUTH2-LOGIN teller ikke som LOGIN');
  finally
    Srv.Free;
  end;
end;

procedure TestSmtpUtenBruker;
var
  Srv: TSmtpEkkoServer;
begin
  { Ingen brukernavn: ingen AUTH, og ingen klage. En relé på loopback
    vil ofte ikke ha noen. }
  Srv := TSmtpEkkoServer.Create('AUTH PLAIN LOGIN');
  try
    SendMedAuth(Srv, '', '', False);
    Srv.WaitFor;
    AssertNotContains(Srv.Samtale, 'AUTH', 'ingen AUTH uten brukernavn');
    AssertContains(Srv.Samtale, 'MAIL FROM:', 'men posten går');
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
    function Lagre(Req: TRequest): TResponse;
  end;

function TDemoCtrl.Index(Req: TRequest): TResponse;
begin
  Result := RespondJson('{"liste":[1,2,3]}');
end;

function TDemoCtrl.Vis(Req: TRequest): TResponse;
begin
  Result := RespondText('id=' + Req.Param('id').ToString);
end;

function TDemoCtrl.Lagre(Req: TRequest): TResponse;
begin
  Result := RespondText('fikk ' + IntToStr(Req.Body.Len) + ' bytes', 201);
end;

var
  DemoR: TRouter;
  DemoC: TDemoCtrl;
  Klient: TTestClient;

{ Velkomstsiden er det første noen ser av et nytt prosjekt, og den skal
  virke uten npm, uten nett og uten filer ved siden av binæren. Brekker den
  stille, merkes det først når noen prøver rammeverket for første gang. }
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
  Kropp: string;
begin
  VelkomstC := TVelkomstCtrl.Create;
  VelkomstR := TRouter.Create;
  VelkomstR.Get('/', VelkomstC.Index);
  VelkomstR.Get('/fiendtlig', VelkomstC.Fiendtlig);
  with TTestClient.Create(VelkomstR) do
  try
    R := Get('/');
    AssertStatus(R, 200, 'velkomstsiden svarer');
    Kropp := R.Body.ToString;
    AssertTrue(Pos('<!doctype html>', Kropp) = 1, 'er et HTML-dokument');
    AssertTrue(Pos('shop', Kropp) > 0, 'prosjektnavnet står i den');

    { Avlesningen skal være ekte tall fra arenaen, ikke plassholdere. }
    AssertTrue(Pos('This request', Kropp) > 0, 'arena-avlesningen er med');
    AssertTrue(Pos('this worker reserved once', Kropp) > 0,
      'målebjelken er forklart');
    { Bjelkebreddene må være gyldig CSS uansett locale — et komma her ville
      gjort dem ugyldige på en maskin med norske innstillinger. }
    AssertTrue(Pos('--w:', Kropp) > 0, 'bjelken har en bredde');
    AssertTrue(Pos(',%', Kropp) = 0, 'bredden bruker punktum, ikke komma');
    { Siden er det første et internasjonalt publikum ser, og skal være
      på engelsk. }
    AssertTrue(Pos('lang="en"', Kropp) > 0, 'siden er merket engelsk');

    { Ingenting hentes utenfra. En maskin uten nett skal se det samme. }
    AssertTrue(Pos('http://', Kropp) = 0, 'ingen eksterne ressurser');
    AssertTrue(Pos('https://', Kropp) = 0, 'heller ikke over https');
    AssertTrue(Pos('<script', Kropp) = 0, 'ingen skript');

    { Både lyst og mørkt tema, og den skal kunne leses på en telefon. }
    AssertTrue(Pos('prefers-color-scheme', Kropp) > 0, 'begge temaer');
    AssertTrue(Pos('name="viewport"', Kropp) > 0, 'viewport-meta');

    { Navnet er brukerkontrollert og må escapes. }
    R := Get('/fiendtlig');
    Kropp := R.Body.ToString;
    AssertTrue(Pos('&lt;script&gt;', Kropp) > 0, 'prosjektnavnet escapes');
    AssertTrue(Pos('<script', Kropp) = 0, 'og slipper ikke gjennom rått');
  finally
    Free;
    VelkomstR.Free;
    VelkomstC.Free;
  end;
end;

{ .env er der hemmeligheter havner. To ting må holde uansett hva som ellers
  endres: ekte miljøvariabler skal vinne over fila, og ingen feilmelding
  skal inneholde en verdi. }
procedure TestEnv;
const
  Fil = 'askr-env-test.tmp';
var
  L: TStringList;
  Feil, Navn: string;
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
    L.SaveToFile(Fil);
  finally
    L.Free;
  end;

  ClearEnv;
  try
    LoadEnv(Fil);

    AssertEqual(Env('SIMPLE'), 'hello', 'enkel verdi');
    AssertEqual(Env('EXPORTED'), 'yes', 'export-prefiks strippes');
    AssertEqual(Env('QUOTED'), 'a b  c', 'anførselstegn beholder mellomrom');
    AssertEqual(Env('ESCAPED'), 'line1'#10'line2', 'escapes i doble fnutter');
    AssertEqual(Env('LITERAL'), 'raw \n stays',
      'enkle fnutter er bokstavelige');
    AssertEqual(Env('TRAILING'), 'value', 'kommentar etter verdien kuttes');
    AssertEqual(Env('HASHPASS'), 'pa#ssword',
      'en # uten mellomrom foran er en del av verdien');
    AssertEqual(Env('EMPTY'), '', 'tom verdi');
    AssertEqual(Env('PATH_LIKE'), '/usr/local/bin', 'sti med skråstreker');
    AssertEqual(Env('SPACED_KEY'), 'spaced', 'mellomrom rundt = tåles');

    AssertEqual(EnvInt('NUMBER'), 42, 'EnvInt');
    AssertEqual(EnvInt('MISSING', 7), 7, 'EnvInt med standardverdi');
    AssertTrue(EnvBool('FLAG'), 'EnvBool leser true');
    AssertFalse(EnvBool('OFFFLAG'), 'EnvBool leser no som usann');
    AssertTrue(EnvBool('MISSING', True), 'EnvBool med standardverdi');
    AssertEqual(Env('MISSING', 'fallback'), 'fallback', 'Env med standardverdi');

    AssertTrue(EnvHas('EMPTY'), 'EnvHas ser en tom verdi');
    AssertFalse(EnvHas('NOT_THERE'), 'EnvHas ser ikke det som ikke finnes');

    { Det avgjørende: miljøet vinner. En verdi satt av systemd eller docker
      skal aldri kunne overstyres av en fil som ligger igjen i katalogen. }
    AssertEqual(Env('HOME') <> '', True, 'HOME finnes i miljøet');
    AssertEqual(Env('SIMPLE'), 'hello', 'fila brukes når miljøet er tomt');

    { EnvOrFail skal være trygg å la stå i et stakkspor. }
    Feil := '';
    try
      EnvOrFail('NOT_THERE');
    except
      on E: EEnvError do Feil := E.Message;
    end;
    AssertTrue(Pos('NOT_THERE', Feil) > 0, 'feilen nevner nøkkelen');
    AssertTrue(Pos('hello', Feil) = 0, 'og lekker ingen verdier');
    AssertTrue(Pos('pa#ssword', Feil) = 0, 'heller ikke passordet');
    AssertTrue(Pos(Fil, Feil) > 0, 'men sier hvor det ble lett');

    AssertEqual(EnvOrFail('SIMPLE'), 'hello', 'EnvOrFail gir verdien når den finnes');
    { EnvKeys gir navn, ikke verdier — den er til diagnostikk og skal kunne
      skrives ut uten å lekke noe. }
    Navn := '';
    for I := 0 to High(EnvKeys) do
      Navn := Navn + EnvKeys[I] + ' ';
    AssertTrue(Pos('SIMPLE', Navn) > 0, 'EnvKeys nevner SIMPLE');
    AssertTrue(Pos('HASHPASS', Navn) > 0, 'EnvKeys nevner HASHPASS');
    AssertTrue(Pos('pa#ssword', Navn) = 0, 'men ingen verdier');
  finally
    ClearEnv;
    DeleteFile(Fil);
  end;
end;

procedure TestKlientMotRuter;
var
  R: TResponse;
begin
  DemoC := TDemoCtrl.Create;
  DemoR := TRouter.Create;
  DemoR.Get('/ting', DemoC.Index);
  DemoR.Get('/ting/:id', DemoC.Vis);
  DemoR.Post('/ting', DemoC.Lagre);
  Klient := TTestClient.Create(DemoR);
  try
    R := Klient.Get('/ting');
    AssertStatus(R, 200, 'GET /ting');
    AssertEqual(R.Body.ToString, '{"liste":[1,2,3]}', 'kroppen');

    R := Klient.Get('/ting/42');
    AssertEqual(R.Body.ToString, 'id=42', 'ruteparameter');

    R := Klient.Post('/ting', '{"a":1}');
    AssertStatus(R, 201, 'POST gir 201');
    AssertEqual(R.Body.ToString, 'fikk 7 bytes', 'kroppen kom fram');

    R := Klient.Delete('/ting');
    AssertStatus(R, 405, 'ukjent metode gir 405');

    R := Klient.Get('/finnes-ikke');
    AssertStatus(R, 404, 'ukjent sti gir 404');
  finally
    Klient.Free;
    DemoR.Free;
    DemoC.Free;
  end;
end;

{ Kjøres av AssertArenaStable. }
procedure EnRequest;
begin
  Klient.Get('/ting/7');
end;

procedure TestArenaFlaterUt;
begin
  DemoC := TDemoCtrl.Create;
  DemoR := TRouter.Create;
  DemoR.Get('/ting/:id', DemoC.Vis);
  Klient := TTestClient.Create(DemoR);
  try
    AssertArenaStable(Klient.Arena, @EnRequest, 300,
      'arenaen flater ut over 300 requests');
  finally
    Klient.Free;
    DemoR.Free;
    DemoC.Free;
  end;
end;


{ ----------------------------------------------------------------- CSRF -- }

type
  { Et skjemaendepunkt og et webhook-endepunkt. GET-handleren returnerer
    tokenet i kroppen, slik en ekte side ville lagt det i et skjult felt —
    tokenet lages først når noe spør etter det. }
  TCsrfCtl = class
    function Vis(Req: TRequest): TResponse;
    function Lagre(Req: TRequest): TResponse;
    function Webhook(Req: TRequest): TResponse;
  end;

function TCsrfCtl.Vis(Req: TRequest): TResponse;
begin
  Result := RespondText(CsrfToken, 200);
end;

function TCsrfCtl.Lagre(Req: TRequest): TResponse;
begin
  Result := RespondText('lagret', 200);
end;

function TCsrfCtl.Webhook(Req: TRequest): TResponse;
begin
  Result := RespondText('mottatt', 200);
end;

{ Plukker én navngitt Set-Cookie ut av svaret. Returnerer hele direktivet,
  ikke bare verdien, slik at HttpOnly kan sjekkes. }
function SetCookieLinje(R: TResponse; A: TArena; const Navn: string): string;
var
  B: TStrBuilder;
  Raw: string;
  P, Slutt: Integer;
begin
  B.Init(A, 8192);
  R.WriteTo(B, False, False);
  Raw := B.ToString;
  P := Pos('Set-Cookie: ' + Navn + '=', Raw);
  if P = 0 then
    Exit('');
  Inc(P, Length('Set-Cookie: '));
  Slutt := P;
  while (Slutt <= Length(Raw)) and (Raw[Slutt] <> #13) do
    Inc(Slutt);
  Result := Copy(Raw, P, Slutt - P);
end;

function KakeVerdi(const Linje: string): string;
var
  P, Q3: Integer;
begin
  P := Pos('=', Linje);
  if P = 0 then
    Exit('');
  Inc(P);
  Q3 := P;
  while (Q3 <= Length(Linje)) and (Linje[Q3] <> ';') do
    Inc(Q3);
  Result := Copy(Linje, P, Q3 - P);
end;

function AntallSetCookie(R: TResponse; A: TArena): Integer;
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
  CsrfUnntakSatt: Boolean = False;

{ Bygger en app med sesjoner og CSRF koblet på, slik en ekte app gjør det:
  SetSessions, UseSessions, UseCsrf. }
procedure CsrfOppsett;
begin
  { Unntakslista er global og skal bare skrives én gang. Å registrere den
    på nytt for hver test ville ikke gjort skade, men en liste som vokser
    for hver oppsett er ikke det noen vil lese i en feilsøking. }
  if not CsrfUnntakSatt then
  begin
    CsrfExempt('/webhooks/*');
    CsrfUnntakSatt := True;
  end;
  SetSessions(TSessionStore.Create(3600));
  CsrfC := TCsrfCtl.Create;
  CsrfR := TRouter.Create;
  CsrfR.Get('/form', CsrfC.Vis);
  CsrfR.Post('/form', CsrfC.Lagre);
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

{ Henter en sesjon med et token i, og gir tilbake både kaka og tokenet.
  Det er nøyaktig det en nettleser gjør når den laster siden med skjemaet. }
procedure HentTokenOgKake(out Kake, Token: string);
var
  Res: TResponse;
begin
  Res := CsrfK.Get('/form');
  Token := Res.Body.ToString;
  Kake := KakeVerdi(SetCookieLinje(Res, CsrfK.Arena, 'askr_session'));
end;

procedure TestCsrfAvviserUtenToken;
var
  Res: TResponse;
  Kake, Token: string;
begin
  CsrfOppsett;
  try
    HentTokenOgKake(Kake, Token);

    { GET sjekkes aldri: den skal per definisjon ikke endre noe. }
    Res := CsrfK.WithHeader('Cookie', 'askr_session=' + Kake).Get('/form');
    AssertEqual(Res.StatusCode, 200, 'GET slipper gjennom uten token');

    Res := CsrfK.WithHeader('Cookie', 'askr_session=' + Kake)
      .Post('/form', '{}');
    AssertEqual(Res.StatusCode, 419, 'POST uten token avvises');

    Res := CsrfK.WithHeader('Cookie', 'askr_session=' + Kake)
      .WithHeader('X-CSRF-Token', 'helt feil').Post('/form', '{}');
    AssertEqual(Res.StatusCode, 419, 'POST med feil token avvises');

    { Uten sesjon finnes det ingenting å sammenligne med. Da er svaret nei —
      ikke «ja, for det er ingen forventning». }
    Res := CsrfK.WithHeader('X-CSRF-Token', Token).Post('/form', '{}');
    AssertEqual(Res.StatusCode, 419, 'riktig token uten sesjon avvises');
  finally
    CsrfRydd;
  end;
end;

procedure TestCsrfGodtarAlleTreKilder;
var
  Res: TResponse;
  Kake, Token: string;
begin
  CsrfOppsett;
  try
    HentTokenOgKake(Kake, Token);
    AssertTrue(Token <> '', 'tokenet ble laget');
    AssertTrue(Kake <> '', 'sesjonskaka ble satt');

    { 1. Skjemafeltet, som et vanlig HTML-skjema sender det. }
    Res := CsrfK.WithHeader('Cookie', 'askr_session=' + Kake)
      .Post('/form', '_token=' + Token,
        'application/x-www-form-urlencoded');
    AssertEqual(Res.StatusCode, 200, 'skjemafeltet _token godtas');

    { 2. X-CSRF-Token, som fetch og XHR legger på selv. }
    Res := CsrfK.WithHeader('Cookie', 'askr_session=' + Kake)
      .WithHeader('X-CSRF-Token', Token).Post('/form', '{}');
    AssertEqual(Res.StatusCode, 200, 'headeren X-CSRF-Token godtas');

    { 3. X-XSRF-Token, som axios og Inertia speiler fra XSRF-TOKEN-kaka. }
    Res := CsrfK.WithHeader('Cookie', 'askr_session=' + Kake)
      .WithHeader('X-XSRF-Token', Token).Post('/form', '{}');
    AssertEqual(Res.StatusCode, 200, 'headeren X-XSRF-Token godtas');
  finally
    CsrfRydd;
  end;
end;

procedure TestCsrfTokenetErStabiltOgPerSesjon;
var
  Res: TResponse;
  Kake1, Token1, Kake2, Token2: string;
begin
  CsrfOppsett;
  try
    HentTokenOgKake(Kake1, Token1);

    { Samme sesjon, nytt kall: samme token. Et token som byttet for hver
      request ville gjort hver åpen fane ugyldig. }
    Res := CsrfK.WithHeader('Cookie', 'askr_session=' + Kake1).Get('/form');
    AssertEqual(Res.Body.ToString, Token1, 'samme sesjon gir samme token');

    { Ny sesjon: nytt token — og det gamle skal ikke virke der. }
    HentTokenOgKake(Kake2, Token2);
    AssertTrue(Kake1 <> Kake2, 'to sesjoner');
    AssertTrue(Token1 <> Token2, 'og to ulike tokens');

    Res := CsrfK.WithHeader('Cookie', 'askr_session=' + Kake2)
      .WithHeader('X-CSRF-Token', Token1).Post('/form', '{}');
    AssertEqual(Res.StatusCode, 419,
      'et token fra en annen sesjon avvises');
  finally
    CsrfRydd;
  end;
end;

procedure TestCsrfUnntakForWebhooks;
var
  Res: TResponse;
begin
  CsrfOppsett;
  try
    { Et webhook kommer fra en tredjepart som umulig kan ha tokenet. Unntaket
      er et hull man lager med vilje, og derfor testes det at det finnes —
      og at det ikke gjelder mer enn stien det ble skrevet for. }
    Res := CsrfK.Post('/webhooks/stripe', '{}');
    AssertEqual(Res.StatusCode, 200, 'unntatt sti slipper gjennom');

    Res := CsrfK.Post('/form', '{}');
    AssertEqual(Res.StatusCode, 419, 'men resten er fortsatt beskyttet');
  finally
    CsrfRydd;
  end;
end;

procedure TestCsrfKakeneLeverSideOmSide;
var
  Res: TResponse;
  Sesjon, Xsrf: string;
  Kake, Token: string;
begin
  CsrfOppsett;
  try
    HentTokenOgKake(Kake, Token);
    Res := CsrfK.WithHeader('Cookie', 'askr_session=' + Kake).Get('/form');

    { Før AddHeader lot responsen siste verdi vinne per headernavn, og den
      andre kaka ville skrevet over den første. To kaker i ett svar er hele
      grunnen til at CSRF trengte den endringen. }
    AssertEqual(AntallSetCookie(Res, CsrfK.Arena), 2,
      'begge kakene står i svaret');

    Sesjon := SetCookieLinje(Res, CsrfK.Arena, 'askr_session');
    Xsrf := SetCookieLinje(Res, CsrfK.Arena, 'XSRF-TOKEN');
    AssertTrue(Sesjon <> '', 'sesjonskaka er der');
    AssertTrue(Xsrf <> '', 'XSRF-kaka er der');

    { Sesjonskaka er det som autentiserer, og JavaScript skal ikke nå den.
      XSRF-kaka er bare en kopi av noe som uansett står i sidens markup, og
      må kunne leses for at axios skal kunne speile den tilbake. }
    AssertTrue(Pos('HttpOnly', Sesjon) > 0, 'sesjonskaka er HttpOnly');
    AssertEqual(Pos('HttpOnly', Xsrf), 0, 'XSRF-kaka er lesbar for JS');
    AssertEqual(KakeVerdi(Xsrf), Token, 'XSRF-kaka bærer tokenet');
  finally
    CsrfRydd;
  end;
end;


{ ----------------------------------------------------------------- auth -- }

type
  { Appens brukermodell. Poenget er nettopp at rammeverket ikke kjenner
    den: det lagrer en id som tekst, og appen slår opp resten. }
  TBruker = class
    Navn: string;
    ErAdmin: Boolean;
  end;

  TAuthCtl = class
    function HvemErJeg(Req: TRequest): TResponse;
    function LoggInn(Req: TRequest): TResponse;
    function LoggInnHusk(Req: TRequest): TResponse;
    function LoggUt(Req: TRequest): TResponse;
    function Port(Req: TRequest): TResponse;
    function Skjult(Req: TRequest): TResponse;
    function Ta(Req: TRequest): TResponse;
  end;

var
  Brukere: array[0..1] of TBruker;
  LastOppKalt: Integer = 0;

function FinnBruker(const AId: string): TObject;
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
  { En gate ser bare id-en og ressursen. Alt annet er appens sak. }
  Result := UserId = '1';
end;

function ErAdminGate(const UserId: string; Resource: TObject): Boolean;
var
  B: TObject;
begin
  B := FinnBruker(UserId);
  Result := (B <> nil) and TBruker(B).ErAdmin;
end;

function TAuthCtl.HvemErJeg(Req: TRequest): TResponse;
var
  Svar: string;
begin
  if Askr.Auth.Check then
    Svar := 'inne:' + Askr.Auth.Id
  else
    Svar := 'ute';
  Result := RespondText(Svar, 200);
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
  Svar: string;
begin
  Svar := '';
  if Allows('edit') then Svar := Svar + 'edit ';
  if Allows('admin') then Svar := Svar + 'admin ';
  if Allows('finnes-ikke') then Svar := Svar + 'ukjent ';
  if User <> nil then Svar := Svar + 'user:' + TBruker(User).Navn;
  Result := RespondText(Trim(Svar), 200);
end;

function TAuthCtl.Skjult(Req: TRequest): TResponse;
begin
  Result := RespondText('hemmelig', 200);
end;

{ Skriver til sesjonen, og tvinger den dermed til å bli lagret. En sesjon
  ingen har skrevet til får verken plass i lageret eller en kake — og uten
  en ekte sesjon før innlogging tester ikke fikseringstesten noe. }
function TAuthCtl.Ta(Req: TRequest): TResponse;
begin
  CurrentSession.Put('handlekurv', '3');
  Result := RespondText('tatt', 200);
end;

var
  AuthR: TRouter;
  AuthC: TAuthCtl;
  AuthK: TTestClient;

procedure AuthOppsett(MedKrav: Boolean);
begin
  SetAppKey('Zm9vYmFyYmF6cXV1eGZvb2JhcmJhenF1dXhhYmM9');
  SetSessions(TSessionStore.Create(3600));
  SetUserLoader(FinnBruker);
  DefineGate('edit', KanRedigere);
  DefineGate('admin', ErAdminGate);

  AuthC := TAuthCtl.Create;
  AuthR := TRouter.Create;
  AuthR.Get('/me', AuthC.HvemErJeg);
  AuthR.Post('/login', AuthC.LoggInn);
  AuthR.Post('/login-husk', AuthC.LoggInnHusk);
  AuthR.Post('/logout', AuthC.LoggUt);
  AuthR.Get('/gate', AuthC.Port);
  AuthR.Get('/skjult', AuthC.Skjult);
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
  Result := KakeVerdi(SetCookieLinje(R, AuthK.Arena, 'askr_session'));
end;

procedure TestAuthInnOgUt;
var
  Res: TResponse;
  Kake1, Kake2: string;
begin
  AuthOppsett(False);
  try
    Res := AuthK.Get('/me');
    AssertEqual(Res.Body.ToString, 'ute', 'ingen er logget inn');
    AssertEqual(Sesjonskake(Res), '',
      'en sesjon ingen skrev til lagres ikke');

    { En ekte sesjon før innlogging — det er den som skal byttes ut. }
    Res := AuthK.Get('/touch');
    Kake1 := Sesjonskake(Res);
    AssertTrue(Kake1 <> '', 'en sesjon det ble skrevet til får en kake');

    Res := AuthK.WithHeader('Cookie', 'askr_session=' + Kake1)
      .Post('/login', 'id=1', 'application/x-www-form-urlencoded');
    Kake2 := Sesjonskake(Res);

    { Session fixation: id-en MÅ være en annen etter innlogging. Uten dette
      ville en angriper som fikk satt kaka di på forhånd vært innlogget
      som deg. }
    AssertTrue(Kake2 <> Kake1, 'sesjons-id-en ble byttet ved innlogging');
    AssertTrue(Kake2 <> '', 'og en ny ble satt');

    Res := AuthK.WithHeader('Cookie', 'askr_session=' + Kake2).Get('/me');
    AssertEqual(Res.Body.ToString, 'inne:1', 'brukeren er logget inn');

    { Den gamle id-en skal ikke lenger gi tilgang. }
    Res := AuthK.WithHeader('Cookie', 'askr_session=' + Kake1).Get('/me');
    AssertEqual(Res.Body.ToString, 'ute', 'den gamle id-en er død');

    Res := AuthK.WithHeader('Cookie', 'askr_session=' + Kake2)
      .Post('/logout', '');
    Kake1 := Sesjonskake(Res);
    Res := AuthK.WithHeader('Cookie', 'askr_session=' + Kake1).Get('/me');
    AssertEqual(Res.Body.ToString, 'ute', 'utlogget');
  finally
    AuthRydd;
  end;
end;

procedure TestAuthHuskMeg;
var
  Res: TResponse;
  Kake, Husk, Tuklet: string;
begin
  AuthOppsett(False);
  try
    Res := AuthK.Get('/touch');
    Kake := Sesjonskake(Res);
    Res := AuthK.WithHeader('Cookie', 'askr_session=' + Kake)
      .Post('/login-husk', 'id=2', 'application/x-www-form-urlencoded');
    Husk := KakeVerdi(SetCookieLinje(Res, AuthK.Arena, 'askr_remember'));
    AssertTrue(Husk <> '', 'husk-kaka ble satt');
    AssertTrue(Pos('.', Husk) > 0, 'den er signert');

    { Uten sesjonskake — som etter at nettleseren er lukket — men med
      husk-kaka: brukeren skal komme inn igjen. }
    Res := AuthK.WithHeader('Cookie', 'askr_remember=' + Husk).Get('/me');
    AssertEqual(Res.Body.ToString, 'inne:2', 'husk-kaka logget inn igjen');

    { Og den skal gi en fersk sesjon, ikke gjenbruke noen. }
    AssertTrue(Sesjonskake(Res) <> '', 'en ny sesjon ble startet');

    { Tuklet signatur: avvises. Dette er hele grunnen til at kaka er
      signert — uten det kunne hvem som helst skrevet «1|...» selv. }
    Tuklet := StringReplace(Husk, '2|', '1|', []);
    Res := AuthK.WithHeader('Cookie', 'askr_remember=' + Tuklet).Get('/me');
    AssertEqual(Res.Body.ToString, 'ute', 'tuklet husk-kake avvises');

    { Utløpt, men korrekt signert. Utløpet står inne i det signerte nettopp
      for at en klient som beholder kaka for lenge ikke skal komme inn. }
    Tuklet := Sign('2|' + IntToStr(UnixNow - 60));
    Res := AuthK.WithHeader('Cookie', 'askr_remember=' + Tuklet).Get('/me');
    AssertEqual(Res.Body.ToString, 'ute', 'utløpt husk-kake avvises');

    { Utlogging sletter kaka. }
    Res := AuthK.WithHeader('Cookie', 'askr_remember=' + Husk)
      .Post('/logout', '');
    AssertTrue(Pos('Max-Age=0',
      SetCookieLinje(Res, AuthK.Arena, 'askr_remember')) > 0,
      'utlogging sletter husk-kaka');
  finally
    AuthRydd;
  end;
end;

procedure TestAuthGates;
var
  Res: TResponse;
  Kake: string;
begin
  AuthOppsett(False);
  try
    { Ingen innlogget: alt er nei. }
    Res := AuthK.Get('/gate');
    AssertEqual(Res.Body.ToString, '', 'uten innlogging gir gatene nei');

    Res := AuthK.Get('/touch');
    Kake := Sesjonskake(Res);
    Res := AuthK.WithHeader('Cookie', 'askr_session=' + Kake)
      .Post('/login', 'id=1', 'application/x-www-form-urlencoded');
    Kake := Sesjonskake(Res);

    Res := AuthK.WithHeader('Cookie', 'askr_session=' + Kake).Get('/gate');
    { Bruker 1 kan redigere og er admin. «finnes-ikke» er ikke definert, og
      en udefinert gate skal svare nei — en stavefeil skal stenge døra. }
    AssertEqual(Res.Body.ToString, 'edit admin user:Ada',
      'gatene svarer, og en ukjent gate svarer nei');
    AssertTrue(GateExists('edit'), 'gaten finnes');
    AssertFalse(GateExists('finnes-ikke'), 'og en annen gjør ikke');

    { Bruker 2 er ikke admin og kan ikke redigere. }
    Res := AuthK.Get('/touch');
    Kake := Sesjonskake(Res);
    Res := AuthK.WithHeader('Cookie', 'askr_session=' + Kake)
      .Post('/login', 'id=2', 'application/x-www-form-urlencoded');
    Kake := Sesjonskake(Res);
    Res := AuthK.WithHeader('Cookie', 'askr_session=' + Kake).Get('/gate');
    AssertEqual(Res.Body.ToString, 'user:Grace',
      'en annen bruker får nei på begge');
  finally
    AuthRydd;
  end;
end;

procedure TestAuthRequire;
var
  Res: TResponse;
  Kake: string;
begin
  AuthOppsett(True);
  try
    { En vanlig nettleser skal til innloggingssiden. }
    Res := AuthK.Get('/skjult');
    AssertEqual(Res.StatusCode, 302, 'uten innlogging blir det omdirigering');
    AssertEqual(Res.HeaderValue('Location'), '/login', 'til innloggingen');

    { En Inertia-klient ville fulgt omdirigeringen og fått HTML der den
      ventet JSON. 401 er det den kan gjøre noe med. }
    Res := AuthK.WithHeader('X-Inertia', 'true').Get('/skjult');
    AssertEqual(Res.StatusCode, 401, 'en Inertia-request får 401');

    Res := AuthK.WithHeader('Accept', 'application/json').Get('/skjult');
    AssertEqual(Res.StatusCode, 401, 'og en JSON-request også');

    { Innlogget slipper gjennom. Innloggingsruten er selv bak kravet her,
      så sesjonen må lages via en request som ikke er det — /login er en
      POST, og RequireAuth stenger også den. Derfor logges det inn med
      en klient uten kravet. }
    AuthRydd;
    AuthOppsett(False);
    Res := AuthK.Get('/touch');
    Kake := Sesjonskake(Res);
    Res := AuthK.WithHeader('Cookie', 'askr_session=' + Kake)
      .Post('/login', 'id=1', 'application/x-www-form-urlencoded');
    Kake := Sesjonskake(Res);
    Res := AuthK.WithHeader('Cookie', 'askr_session=' + Kake).Get('/skjult');
    AssertEqual(Res.Body.ToString, 'hemmelig', 'innlogget slipper gjennom');
  finally
    AuthRydd;
  end;
end;

procedure TestAuthBrukeroppslagCaches;
var
  Res: TResponse;
  Kake: string;
  Foer: Integer;
begin
  AuthOppsett(False);
  try
    Res := AuthK.Get('/touch');
    Kake := Sesjonskake(Res);
    Res := AuthK.WithHeader('Cookie', 'askr_session=' + Kake)
      .Post('/login', 'id=1', 'application/x-www-form-urlencoded');
    Kake := Sesjonskake(Res);

    { /gate kaller User og admin-gaten, som begge slår opp brukeren.
      Loaderen skal kalles én gang for User — admin-gaten gjør sitt eget
      oppslag med vilje, for å vise at en gate kan det. }
    Foer := LastOppKalt;
    Res := AuthK.WithHeader('Cookie', 'askr_session=' + Kake).Get('/gate');
    AssertEqual(Res.StatusCode, 200, 'siden svarte');
    AssertTrue(LastOppKalt - Foer <= 2,
      'brukeren slås ikke opp på nytt for hvert kall');
  finally
    AuthRydd;
  end;
end;


{ ------------------------------------------------------- logg og config -- }

{ Det finnes ingen bærbar måte å sette en miljøvariabel som FPCs
  GetEnvironmentVariable ser. libc-ens setenv virker på Darwin og **ikke**
  på Linux, der RTL-en leser envp fra oppstart. Derfor testes «miljøet
  vinner» mot en variabel som allerede står der — HOME — i stedet for mot
  en testen setter selv. }
function LagFil(const Sti: string; const Linjer: array of string): Boolean;
var
  L: TStringList;
  I: Integer;
begin
  L := TStringList.Create;
  try
    for I := 0 to High(Linjer) do
      L.Add(Linjer[I]);
    L.SaveToFile(Sti);
    Result := True;
  finally
    L.Free;
  end;
end;

var
  LoggLinjer: TStringList;

{ Egen destinasjon, slik at testen kan lese linjene i stedet for å måtte
  fange stderr. Det er også demonstrasjonen av at SetLogSink virker. }
procedure SamleLinje(const Line: string);
begin
  LoggLinjer.Add(Line);
end;

procedure LoggOppsett;
begin
  LoggLinjer := TStringList.Create;
  SetLogSink(SamleLinje);
  SetLogLevel(llDebug);
  SetLogFormat(lfText);
end;

procedure LoggRydd;
begin
  SetLogSink(nil);
  SetLogLevel(llInfo);
  SetLogFormat(lfText);
  LoggLinjer.Free;
end;

procedure TestLoggNivaa;
begin
  LoggOppsett;
  try
    SetLogLevel(llWarn);
    LogDebug('d');
    LogInfo('i');
    LogWarn('w');
    LogError('e');
    AssertEqual(LoggLinjer.Count, 2, 'bare warn og error slapp gjennom');
    AssertTrue(Pos('WARN', LoggLinjer[0]) > 0, 'nivået står i linja');
    AssertTrue(Pos('ERROR', LoggLinjer[1]) > 0, 'og for error også');

    AssertFalse(LogEnabled(llInfo), 'LogEnabled sier nei under terskelen');
    AssertTrue(LogEnabled(llError), 'og ja over');

    { llNone er ikke et nivå å logge på, det er et tak. }
    LoggLinjer.Clear;
    SetLogLevel(llNone);
    LogError('selv ikke denne');
    AssertEqual(LoggLinjer.Count, 0, 'llNone slår loggen helt av');
  finally
    LoggRydd;
  end;
end;

procedure TestLoggTekstformat;
var
  L: string;
begin
  LoggOppsett;
  try
    LogInfo('request', ['method', 'GET', 'path', '/a b', 'status', 200]);
    AssertEqual(LoggLinjer.Count, 1, 'én linje');
    L := LoggLinjer[0];
    AssertTrue(Pos('INFO', L) > 0, 'nivå');
    AssertTrue(Pos('request', L) > 0, 'melding');
    AssertTrue(Pos('method=GET', L) > 0, 'felt uten mellomrom står usitert');
    { En verdi med mellomrom må siteres, ellers leses den som to felter. }
    AssertTrue(Pos('path="/a b"', L) > 0, 'verdi med mellomrom siteres');
    AssertTrue(Pos('status=200', L) > 0, 'tall');
    { Tidsstempelet er ISO 8601 i UTC. Lokaltid ville gjort loggen
      usorterbar to ganger i året. }
    AssertTrue(Pos('T', L) > 0, 'tidsstempel med T');
    AssertTrue(Pos('Z ', L) > 0, 'og Z for UTC');

    { Et felt uten verdi skal ikke velte noe. }
    LoggLinjer.Clear;
    LogInfo('rar', ['alene']);
    AssertEqual(LoggLinjer.Count, 1, 'nøkkel uten verdi logges likevel');
  finally
    LoggRydd;
  end;
end;

procedure TestLoggJson;
var
  L: string;
begin
  LoggOppsett;
  try
    SetLogFormat(lfJson);
    LogInfo('request', ['method', 'GET', 'status', 200, 'ok', True,
      'ms', Int64(17)]);
    L := LoggLinjer[0];
    AssertTrue(Pos('"level":"info"', L) > 0, 'nivå som felt');
    AssertTrue(Pos('"msg":"request"', L) > 0, 'melding som felt');
    AssertTrue(Pos('"method":"GET"', L) > 0, 'streng siteres');
    { Tall og boolske skal stå usitert, ellers kan ingen regne på dem. }
    AssertTrue(Pos('"status":200', L) > 0, 'tall står usitert');
    AssertTrue(Pos('"ms":17', L) > 0, 'og int64 også');
    AssertTrue(Pos('"ok":true', L) > 0, 'boolsk står usitert');
    AssertEqual(L[1], '{', 'linja er et JSON-objekt');
    AssertEqual(L[Length(L)], '}', 'og den er lukket');

    { Anførselstegn og linjeskift i en verdi må escapes, ellers er linja
      ikke lenger JSON — og en logginnsamler forkaster hele filen. }
    LoggLinjer.Clear;
    LogWarn('rar', ['tekst', 'han sa "hei"' + #10 + 'og gikk']);
    L := LoggLinjer[0];
    AssertTrue(Pos('\"hei\"', L) > 0, 'anførselstegn escapes');
    AssertTrue(Pos('\n', L) > 0, 'linjeskift escapes');
    AssertEqual(Pos(#10, L), 0, 'og det er ingen ekte linjeskift igjen');
  finally
    LoggRydd;
  end;
end;

procedure TestLoggException;
var
  L: string;
begin
  LoggOppsett;
  try
    SetLogFormat(lfJson);
    try
      raise EConfigError.Create('noe gikk galt');
    except
      on E: Exception do
        LogException(E, 'while saving', ['id', 7]);
    end;
    AssertEqual(LoggLinjer.Count, 1, 'én linje');
    L := LoggLinjer[0];
    { Klassen og meldingen er egne felter, ikke fritekst. Det er
      forskjellen på å kunne gruppere på feiltype og å måtte grep-e. }
    AssertTrue(Pos('"class":"EConfigError"', L) > 0, 'klassen er et felt');
    AssertTrue(Pos('"error":"noe gikk galt"', L) > 0, 'meldingen er et felt');
    AssertTrue(Pos('"msg":"while saving"', L) > 0, 'konteksten er meldingen');
    AssertTrue(Pos('"id":7', L) > 0, 'og kallerens felter er med');
  finally
    LoggRydd;
  end;
end;

procedure TestLoggTilFil;
var
  Sti: string;
  L: TStringList;
begin
  Sti := '.build/logg-test.log';
  DeleteFile(Sti);
  try
    SetLogLevel(llInfo);
    SetLogFormat(lfText);
    SetLogFile(Sti);
    LogInfo('til fil', ['n', 1]);
    LogInfo('og en til', ['n', 2]);
    { Filen lukkes når destinasjonen byttes, og da er alt skrevet. }
    SetLogFile('');

    L := TStringList.Create;
    try
      L.LoadFromFile(Sti);
      AssertEqual(L.Count, 2, 'begge linjene havnet i fila');
      AssertTrue(Pos('n=1', L[0]) > 0, 'første linje');
      AssertTrue(Pos('n=2', L[1]) > 0, 'andre linje');
    finally
      L.Free;
    end;

    { Å åpne på nytt skal legge til, ikke slette. En omstart skal ikke
      viske ut forrige kjørings logg. }
    SetLogFile(Sti);
    LogInfo('etter omstart');
    SetLogFile('');
    L := TStringList.Create;
    try
      L.LoadFromFile(Sti);
      AssertEqual(L.Count, 3, 'den tredje ble lagt til');
    finally
      L.Free;
    end;
  finally
    SetLogFile('');
    DeleteFile(Sti);
  end;
end;

procedure TestConfigLag;
var
  L: TStringList;
  Mappe: string;
begin
  Mappe := '.build/cfg-test';
  ForceDirectories(Mappe);
  L := TStringList.Create;
  try
    L.Add('name = "demo"');
    L.Add('units = "app"');
    L.Add('[app]');
    L.Add('port = 8080');
    L.Add('tom =');
    L.SaveToFile(Mappe + '/askr.toml');
    L.Clear;
    L.Add('APP_PORT=9000');
    L.Add('DATABASE_URL=sqlite:demo.db');
    { HOME står allerede i miljøet. Ved å sette den til noe annet her, blir
      fila og miljøet uenige — og da kan det testes hvem som vinner. }
    L.Add('HOME=/helt/feil');
    L.SaveToFile(Mappe + '/.env');
  finally
    L.Free;
  end;

  try
    ClearConfig;
    LoadConfig(Mappe);

    AssertEqual(Cfg('name'), 'demo', 'toppnivå fra askr.toml');
    { .env slår askr.toml: app.port slås opp som APP_PORT, og den står i
      .env med 9000 mens fila sier 8080. }
    AssertEqual(CfgInt('app.port'), 9000, '.env vinner over askr.toml');
    AssertTrue(CfgSource('app.port') = csDotEnv, 'og kilden sier det');
    AssertEqual(Cfg('units'), 'app', 'nøkkel uten seksjon');
    AssertEqual(CfgInt('app.backend_port', 8081), 8081,
      'standardverdien når ingen har satt noe');
    AssertEqual(Cfg('database.url'), 'sqlite:demo.db',
      'punktum blir understrek i miljønavnet');

    { En nøkkel med tom verdi skal finnes, ikke forsvinne. Det er nettopp
      der TStringList.Values oppfører seg ulikt på 3.2.2 og 3.3.1. }
    AssertTrue(CfgHas('app.tom'), 'tom verdi i askr.toml finnes likevel');

    { Ekte miljøvariabler vinner over begge filene. Dette er den regelen
      hele laget hviler på: en utrulling skal kunne sette noe uten at en
      fil i repoet endres. }
    AssertTrue(GetEnvironmentVariable('HOME') <> '',
      'HOME finnes i miljøet');
    AssertEqual(Cfg('home'), GetEnvironmentVariable('HOME'),
      'miljøet vinner over .env');
    AssertTrue(CfgSource('home') = csEnvironment, 'og kilden sier det');

    AssertEqual(EnvNameFor('app.backend_port'), 'APP_BACKEND_PORT',
      'nøkkelnavn til miljønavn');

    { CfgOrFail nevner nøkkelen og miljøvariabelen, aldri en verdi. }
    try
      CfgOrFail('finnes.ikke');
      AssertTrue(False, 'CfgOrFail skulle kastet');
    except
      on E: EConfigError do
      begin
        AssertTrue(Pos('finnes.ikke', E.Message) > 0, 'nøkkelen nevnes');
        AssertTrue(Pos('FINNES_IKKE', E.Message) > 0,
          'og miljøvariabelen som ville satt den');
        AssertEqual(Pos('sqlite:demo.db', E.Message), 0,
          'ingen verdi lekker ut');
      end;
    end;
  finally
    ClearConfig;
    DeleteFile(Mappe + '/askr.toml');
    DeleteFile(Mappe + '/.env');
    RemoveDir(Mappe);
  end;
end;

procedure TestConfigRapport;
var
  L: TStringList;
  Mappe, Rapport: string;
begin
  Mappe := '.build/cfg-rapport';
  ForceDirectories(Mappe);
  L := TStringList.Create;
  try
    L.Add('DATABASE_URL=postgresql://bruker:hemmelig@host/db');
    L.Add('APP_ENV=local');
    L.Add('MAIL_FROM=post@example.com');
    L.SaveToFile(Mappe + '/.env');
  finally
    L.Free;
  end;

  try
    ClearConfig;
    LoadConfig(Mappe);

    { Uten --values skal rapporten være trygg å lime inn hvor som helst. }
    Rapport := ConfigReport(False);
    AssertTrue(Pos('DATABASE_URL', Rapport) > 0, 'nøkkelen står der');
    AssertEqual(Pos('hemmelig', Rapport), 0, 'men ingen verdi');
    AssertEqual(Pos('post@example.com', Rapport), 0, 'heller ikke denne');

    { Med --values vises verdier, men ikke de som ser ut som hemmeligheter. }
    Rapport := ConfigReport(True);
    AssertTrue(Pos('post@example.com', Rapport) > 0,
      'en ufarlig verdi vises');
    AssertEqual(Pos('hemmelig', Rapport), 0,
      'men en DSN med passord i er fortsatt skjult');
    AssertTrue(Pos('(hidden)', Rapport) > 0, 'og det står at den er det');

    AssertTrue(LooksSecret('DATABASE_URL'), 'URL regnes som hemmelig');
    AssertTrue(LooksSecret('APP_KEY'), 'og KEY');
    AssertTrue(LooksSecret('smtp_password'), 'og PASSWORD');
    AssertFalse(LooksSecret('APP_ENV'), 'men ikke APP_ENV');
  finally
    ClearConfig;
    DeleteFile(Mappe + '/.env');
    RemoveDir(Mappe);
  end;
end;

procedure TestMiljoe;
const
  Fil = '.build/miljoe-test/.env';
var
  Mappe: string;
begin
  Mappe := '.build/miljoe-test';
  ForceDirectories(Mappe);
  try
    { APP_ENV settes i .env og ikke i prosessens miljø, fordi det siste
      ikke lar seg gjøre bærbart. Env() leser begge, så laget som testes
      er det samme. }
    ClearEnv;
    LagFil(Fil, ['# tom']);
    LoadEnv(Fil);
    AssertEqual(AppEnv, 'local', 'uten APP_ENV er vi lokale');
    AssertTrue(IsLocal, 'og IsLocal sier det');
    AssertFalse(IsProduction, 'ikke produksjon');

    ClearEnv;
    LagFil(Fil, ['APP_ENV=production']);
    LoadEnv(Fil);
    AssertTrue(IsProduction, 'production');
    AssertFalse(IsLocal, 'og da ikke lokal');

    ClearEnv;
    LagFil(Fil, ['APP_ENV=prod']);
    LoadEnv(Fil);
    AssertTrue(IsProduction, 'prod er det samme');

    ClearEnv;
    LagFil(Fil, ['APP_ENV=TESTING']);
    LoadEnv(Fil);
    AssertTrue(IsTesting, 'testing, uansett kasus');

    { RequireEnv nevner alle som mangler på én gang, og ingen verdier.
      Poenget er tidspunktet: uten den oppdages en manglende nøkkel på
      første request som trenger den. }
    ClearEnv;
    LagFil(Fil, ['FINNES=ja']);
    LoadEnv(Fil);
    try
      RequireEnv(['FINNES', 'MANGLER_EN', 'MANGLER_TO']);
      AssertTrue(False, 'RequireEnv skulle kastet');
    except
      on E: EEnvError do
      begin
        AssertTrue(Pos('MANGLER_EN', E.Message) > 0, 'første som mangler');
        AssertTrue(Pos('MANGLER_TO', E.Message) > 0, 'og den andre');
        AssertEqual(Pos('FINNES', E.Message), 0,
          'den som fantes nevnes ikke');
        AssertEqual(Pos('ja', E.Message), 0, 'og ingen verdi lekker ut');
      end;
    end;
    RequireEnv(['FINNES']);
  finally
    ClearEnv;
    DeleteFile(Fil);
    RemoveDir(Mappe);
  end;
end;


{ -------------------------------------------------------- varig kø -- }

var
  VarigLaas: TRTLCriticalSection;
  VarigKjort: Integer;
  VarigSiste: string;
  VarigSkalFeile: Boolean;

procedure VarigJobb(const Ctx: TJobContext);
begin
  EnterCriticalSection(VarigLaas);
  try
    Inc(VarigKjort);
    VarigSiste := Ctx.Payload.ToString;
  finally
    LeaveCriticalSection(VarigLaas);
  end;
  if VarigSkalFeile then
    raise Exception.Create('med vilje');
end;

function VarigDsn: string;
begin
  Result := 'sqlite:.build/queue-test.db';
end;

function NyttLager: TDbJobStore;
begin
  Result := TDbJobStore.Create(VarigDsn, 4);
  { Rask poll, ellers venter testen et kvart sekund per jobb. En ekte app
    vil ikke ha 10 ms — det er 400 spørringer i sekundet mot en tom tabell
    med fire workere. }
  Result.Poll := 10;
  Result.EnsureSchema;
end;

procedure VarigOppsett;
begin
  DeleteFile('.build/queue-test.db');
  DeleteFile('.build/queue-test.db-wal');
  DeleteFile('.build/queue-test.db-shm');
  ForceDirectories('.build');
  VarigKjort := 0;
  VarigSiste := '';
  VarigSkalFeile := False;
end;

procedure VarigRydd;
begin
  DeleteFile('.build/queue-test.db');
  DeleteFile('.build/queue-test.db-wal');
  DeleteFile('.build/queue-test.db-shm');
end;

{ Det hele dreier seg om: jobben skal fortsatt være der etter at prosessen
  som la den inn er borte. }
procedure TestVarigOverleverOmstart;
var
  Lager: TDbJobStore;
  Q: TQueue;
begin
  VarigOppsett;
  try
    { «Første kjøring»: legg inn tre jobber, og avslutt uten å kjøre dem. }
    Lager := NyttLager;
    Q := TQueue.Create(Lager, 2, 3, True);
    try
      AssertTrue(Q.Durable, 'køen sier fra at den er varig');
      Q.Push('varig', 'en');
      Q.Push('varig', 'to');
      Q.Push('varig', 'tre');
      AssertEqual(Q.Pending, 3, 'tre jobber i tabellen');
    finally
      { Ingen Start, ingen drain: dette er en prosess som dør. }
      Q.Free;
    end;

    { «Andre kjøring»: en ny prosess, nytt lager, samme fil. }
    Lager := NyttLager;
    Q := TQueue.Create(Lager, 2, 3, True);
    try
      AssertEqual(Q.Pending, 3, 'jobbene overlevde at køen ble borte');
      Q.Handle('varig', @VarigJobb);
      Q.Start;
      AssertTrue(Q.WaitUntilEmpty(10000), 'og de kjørte nå');
      Sleep(100);
      EnterCriticalSection(VarigLaas);
      try
        AssertEqual(VarigKjort, 3, 'alle tre, én gang hver');
      finally
        LeaveCriticalSection(VarigLaas);
      end;
      Q.Stop(True);
    finally
      Q.Free;
    end;
  finally
    VarigRydd;
  end;
end;

procedure TestVarigFeilerOgGirOpp;
var
  Lager: TDbJobStore;
  Q: TQueue;
begin
  VarigOppsett;
  try
    Lager := NyttLager;
    Q := TQueue.Create(Lager, 1, 2, False);
    try
      VarigSkalFeile := True;
      Q.Handle('varig', @VarigJobb);
      Q.Start;
      Q.Push('varig', 'dette går galt');
      AssertTrue(Q.WaitUntilEmpty(10000), 'jobben ga seg til slutt');
      Sleep(150);
      Q.Stop(False);

      AssertEqual(Q.Failed, 1, 'talt som feilet');
      { Forsøkstelleren ligger i raden, ikke i minnet — den skal overleve
        at prosessen dør midt i. }
      EnterCriticalSection(VarigLaas);
      try
        AssertEqual(VarigKjort, 2, 'to forsøk, som MaxAttempts sier');
      finally
        LeaveCriticalSection(VarigLaas);
      end;

      { En jobb som har gitt opp flyttes, den slettes ikke. Den er det
        eneste sporet av at noe skulle ha skjedd og ikke gjorde det. }
      AssertEqual(Lager.FailedCount, 1, 'den ligger i feiltabellen');

      { Og den kan legges tilbake når det som var galt er rettet. }
      VarigSkalFeile := False;
      VarigKjort := 0;
      AssertEqual(Lager.RetryFailed, 1, 'RetryFailed flyttet den tilbake');
      AssertEqual(Lager.FailedCount, 0, 'feiltabellen er tom');
      AssertEqual(Q.Pending, 1, 'og jobben står i køen igjen');

      Q.Start;
      AssertTrue(Q.WaitUntilEmpty(10000), 'den kjørte');
      Sleep(100);
      EnterCriticalSection(VarigLaas);
      try
        AssertEqual(VarigSiste, 'dette går galt',
          'med payloaden i behold');
      finally
        LeaveCriticalSection(VarigLaas);
      end;
      Q.Stop(True);
    finally
      Q.Free;
      Lager.Free;
    end;
  finally
    VarigRydd;
  end;
end;

procedure TestVarigUkjentJobb;
var
  Lager: TDbJobStore;
  Q: TQueue;
begin
  VarigOppsett;
  try
    Lager := NyttLager;
    Q := TQueue.Create(Lager, 1, 3, False);
    try
      Q.Start;
      Q.Push('finnes-ikke', 'data');
      AssertTrue(Q.WaitUntilEmpty(10000), 'jobben ble tatt ut av køen');
      Sleep(100);
      Q.Stop(False);
      AssertEqual(Q.Dropped, 1, 'talt som forkastet');
      { En app som har mistet en Handle-linje skal kunne se hva som lå der.
        I minnekøen forsvinner den; her ligger den igjen. }
      AssertEqual(Lager.FailedCount, 1,
        'en jobb uten handler havner i feiltabellen, ikke i intet');
    finally
      Q.Free;
      Lager.Free;
    end;
  finally
    VarigRydd;
  end;
end;

procedure TestVarigForsinkelseOgBinaert;
var
  Lager: TDbJobStore;
  Q: TQueue;
  Feil: string;
begin
  VarigOppsett;
  try
    Lager := NyttLager;
    Q := TQueue.Create(Lager, 1, 3, False);
    try
      Q.Handle('varig', @VarigJobb);
      Q.Start;
      Q.Push('varig', 'senere', 2);
      Sleep(300);
      EnterCriticalSection(VarigLaas);
      try
        AssertEqual(VarigKjort, 0, 'forsinket jobb kjører ikke med en gang');
      finally
        LeaveCriticalSection(VarigLaas);
      end;
      AssertEqual(Q.Pending, 1, 'den ligger fortsatt i tabellen');
      Q.Stop(False);

      { Rå bytes avvises med en gang. Å la dem gå videre gir enten en
        ødelagt jobb eller en driverfeil langt unna den som skrev den. }
      Feil := '';
      try
        Q.Push('varig', 'a'#0'b');
      except
        on E: Exception do Feil := E.Message;
      end;
      AssertTrue(Pos('NUL byte', Feil) > 0,
        'nullbyte i payloaden avvises, og meldingen sier hvorfor');
      AssertTrue(Pos('varig', Feil) > 0, 'og hvilken jobb det gjaldt');
    finally
      Q.Free;
      Lager.Free;
    end;
  finally
    VarigRydd;
  end;
end;

{ En worker som dør midt i en jobb etterlater raden reservert. Uten at noen
  slipper den igjen, ville jobben blitt liggende for alltid. }
procedure TestVarigForlattReservasjon;
var
  Lager: TDbJobStore;
  C: TDbConnection;
  A: TArena;
  J: TReservedJob;
begin
  VarigOppsett;
  A := TArena.Create(8 * 1024);
  try
    Lager := NyttLager;
    try
      Lager.Push('varig', PByte(PChar('data')), 4, 0);

      { Reserver, og gjør den aldri opp — som om prosessen døde her. }
      AssertTrue(Lager.Reserve(J), 'jobben ble reservert');
      AssertEqual(J.Name, 'varig', 'riktig jobb');
      AssertFalse(Lager.Reserve(J), 'ingen andre får den mens den er tatt');

      { Sett reservasjonen langt tilbake i tid, slik tiden ville gjort. }
      C := OpenDbConnection(VarigDsn);
      try
        C.Exec(A, 'UPDATE askr_jobs SET reserved_at = 1');
      finally
        C.Free;
      end;

      AssertTrue(Lager.Reserve(J),
        'en forlatt reservasjon slippes og jobben kan tas igjen');
      Lager.Complete(J);
      AssertEqual(Lager.Pending, 0, 'og da er den borte');
    finally
      Lager.Free;
    end;
  finally
    A.Free;
    VarigRydd;
  end;
end;


{ ------------------------------------------------------- HTTP-klient -- }

type
  { En server å ringe. Alt klienten skal klare — chunked, omdirigering,
    lang kropp, statuskoder — kommer herfra, slik at testene ikke trenger
    nett. }
  TEkkoServer = class
    function Handle(Req: TRequest): TResponse;
  end;

var
  KlientPort: Word;
  StroemBiter: Integer;
  StroemTekst: string;
  EkkoH: TEkkoServer;
  EkkoSrv: TAskrServer;
  EkkoOpts: TServerOptions;

function TEkkoServer.Handle(Req: TRequest): TResponse;
var
  I: Integer;
  Stor: string;
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
    Stor := '';
    for I := 1 to 3000 do
      Stor := Stor + StringOfChar('x', 99) + #10;
    Exit(RespondText(Stor));
  end;

  if Req.Path.EqualsStr('/borte') then
    Exit(RespondText('nei', 404));

  Result := RespondText('ukjent', 404);
end;

{ En liten server som svarer chunked. Askrs egen server gjør det ikke —
  den setter alltid Content-Length — så uten denne er hele chunked-stien i
  klienten udekket. Og det er den stien enhver ekte server bruker når den
  ikke vet lengden på forhånd, altså nesten alltid for et strømmet API. }
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
  Svar, Bit: string;
  I: Integer;
  Buf: array[0..1023] of Byte;
begin
  while not Terminated do
  begin
    S := fpAccept(FLytt, nil, nil);
    if S < 0 then
      Break;
    { Les requesten og kast den — hva som spørres om er ikke poenget. }
    fpRecv(S, @Buf[0], SizeOf(Buf), 0);

    Svar := 'HTTP/1.1 200 OK'#13#10 +
      'Content-Type: text/plain'#13#10 +
      'Transfer-Encoding: chunked'#13#10 +
      'Connection: close'#13#10#13#10;
    { Fem biter, og den siste inneholder en CRLF for å vise at innholdet
      ikke forveksles med rammeverket rundt. }
    for I := 1 to 5 do
    begin
      if I = 5 then
        Bit := 'siste'#13#10'linje'
      else
        Bit := StringOfChar(Chr(Ord('A') + I - 1), 1000);
      { Størrelsen er heksadesimal. En bit med utvidelse etter semikolon
        er lovlig, og den fjerde har en for å vise at den hoppes over. }
      if I = 4 then
        Svar := Svar + Format('%x;noe=her'#13#10'%s'#13#10, [Length(Bit), Bit])
      else
        Svar := Svar + Format('%x'#13#10'%s'#13#10, [Length(Bit), Bit]);
    end;
    Svar := Svar + '0'#13#10#13#10;
    fpSend(S, PChar(Svar), Length(Svar), 0);
    CloseSocket(S);
  end;
  CloseSocket(FLytt);
end;

procedure TestKlientChunked;
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
    AssertEqual(R.Status, 200, 'chunked svar har status');
    AssertEqual(R.Header('Transfer-Encoding'), 'chunked',
      'og serveren sa at den sendte chunked');

    Ventet := '';
    for I := 1 to 4 do
      Ventet := Ventet + StringOfChar(Chr(Ord('A') + I - 1), 1000);
    Ventet := Ventet + 'siste'#13#10'linje';
    AssertEqual(Length(R.Body), Length(Ventet),
      'alle bitene satt sammen igjen');
    AssertEqual(R.Body, Ventet, 'og i riktig rekkefølge, byte for byte');
    { Rammeverket rundt bitene skal ikke havne i kroppen. }
    AssertEqual(Pos('3e8', R.Body), 0, 'størrelseslinjene er borte');
    AssertEqual(Pos('noe=her', R.Body), 0, 'og utvidelsen også');
  finally
    K.Free;
    Srv.Terminate;
    { Én request til, slik at accept slipper løs og tråden kan avslutte. }
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

{ Navneoppslag mot /etc/hosts. Den stien er GetHostByName, ikke DNS, og
  den skal virke overalt — også der det ikke finnes en navnetjener. }
procedure TestKlientLocalhost;
var
  K: THttpClient;
  R: THttpResponse;
begin
  K := THttpClient.Create;
  try
    R := K.Get(Format('http://localhost:%d/hei', [KlientPort]));
    AssertEqual(R.Status, 200, 'localhost slås opp i /etc/hosts');
    AssertEqual(R.Body, 'hei', 'og svaret kom fram');
  finally
    K.Free;
  end;
end;

function SamleBit(const Chunk: string): Boolean;
begin
  Inc(StroemBiter);
  StroemTekst := StroemTekst + Chunk;
  Result := True;
end;

function StoppEtterFoerste(const Chunk: string): Boolean;
begin
  Inc(StroemBiter);
  StroemTekst := StroemTekst + Chunk;
  { False betyr «slutt å lese». Det er slik en SSE-lytter melder seg av. }
  Result := False;
end;

procedure TestKlientUrl;
var
  Sch, Host, Sti: string;
  Port: Word;
begin
  AssertTrue(ParseUrl('https://api.example.com/v1/messages', Sch, Host,
    Port, Sti), 'en vanlig https-adresse');
  AssertEqual(Sch, 'https', 'skjema');
  AssertEqual(Host, 'api.example.com', 'vert');
  AssertEqual(Port, 443, 'https gir 443 uten at porten står der');
  AssertEqual(Sti, '/v1/messages', 'sti');

  ParseUrl('http://localhost:8080', Sch, Host, Port, Sti);
  AssertEqual(Port, 8080, 'porten leses');
  AssertEqual(Sti, '/', 'tom sti blir /');

  ParseUrl('http://x.no?a=1', Sch, Host, Port, Sti);
  AssertEqual(Sti, '/?a=1', 'query uten sti får / foran');

  { Fragmentet er nettleserens, ikke serverens, og skal aldri sendes. }
  ParseUrl('http://x.no/side#del', Sch, Host, Port, Sti);
  AssertEqual(Sti, '/side', 'fragmentet sendes ikke');

  { Brukerinfo i adressen ignoreres i stedet for å bli sendt videre. }
  ParseUrl('https://bruker:pass@x.no/a', Sch, Host, Port, Sti);
  AssertEqual(Host, 'x.no', 'brukerinfo hører ikke til verten');

  AssertFalse(ParseUrl('ftp://x.no/a', Sch, Host, Port, Sti),
    'ftp er ikke http');
  AssertFalse(ParseUrl('bare en tekst', Sch, Host, Port, Sti),
    'og en tekst uten skjema er ingen adresse');

  AssertEqual(UrlEncodeValue('a b&c=d'), 'a%20b%26c%3Dd',
    'prosentkoding');
  AssertEqual(UrlEncodeValue('abc-_.~'), 'abc-_.~',
    'de ureserverte tegnene står');
end;

procedure TestKlientMotEgenServer;
var
  K: THttpClient;
  R: THttpResponse;
  Base: string;
begin
  K := THttpClient.Create;
  Base := Format('http://127.0.0.1:%d', [KlientPort]);
  try
    R := K.Get(Base + '/hei');
    AssertEqual(R.Status, 200, 'GET svarte 200');
    AssertEqual(R.Body, 'hei', 'og med riktig kropp');
    AssertTrue(R.Ok, 'Ok er sann for 200');
    AssertTrue(R.Header('Content-Type') <> '', 'headerne kom med');
    { Headeroppslag skal ignorere kasus, slik HTTP sier. }
    AssertEqual(R.Header('content-TYPE'), R.Header('Content-Type'),
      'headernavn er ikke kasusfølsomme');

    R := K.Post(Base + '/ekko', '{"a":1}');
    AssertEqual(R.Status, 200, 'POST svarte');
    AssertEqual(R.Body, '{"a":1}', 'kroppen kom fram og tilbake');
    AssertEqual(R.Header('X-Method'), 'POST', 'metoden var POST');
    AssertTrue(R.IsJson, 'svaret er JSON');

    R := K.Put(Base + '/ekko', 'p');
    AssertEqual(R.Header('X-Method'), 'PUT', 'PUT');
    R := K.Patch(Base + '/ekko', 'p');
    AssertEqual(R.Header('X-Method'), 'PATCH', 'PATCH');
    R := K.Delete(Base + '/ekko');
    AssertEqual(R.Header('X-Method'), 'DELETE', 'DELETE');

    K.WithHeader('X-Prove', 'verdi').WithBearer('hemmelig-token');
    R := K.Get(Base + '/hode');
    AssertEqual(R.Body, 'verdi|Bearer hemmelig-token',
      'headerne fra klienten ble sendt');
    K.ClearHeaders;

    R := K.Get(Base + '/borte');
    AssertEqual(R.Status, 404, '404 er et svar, ikke en exception');
    AssertFalse(R.Ok, 'og Ok er usann');

    { En kropp som ikke får plass i én lesning. }
    R := K.Get(Base + '/stor');
    AssertEqual(Length(R.Body), 300000, 'et stort svar leses helt');

    AssertTrue(R.ElapsedMs >= 0, 'tiden måles');
  finally
    K.Free;
  end;
end;

procedure TestKlientOmdirigering;
var
  K: THttpClient;
  R: THttpResponse;
  Base, Feil: string;
begin
  K := THttpClient.Create;
  Base := Format('http://127.0.0.1:%d', [KlientPort]);
  try
    R := K.Get(Base + '/flytt');
    AssertEqual(R.Status, 200, 'omdirigeringen ble fulgt');
    AssertEqual(R.Body, 'hei', 'og vi endte riktig sted');
    AssertEqual(R.Redirects, 1, 'én omdirigering telt');

    { 302 blir GET. 307 beholder metoden og kroppen — det er hele grunnen
      til at 307 finnes. }
    R := K.Post(Base + '/flytt-307', 'kroppen', 'text/plain');
    AssertEqual(R.Header('X-Method'), 'POST', '307 beholder metoden');
    AssertEqual(R.Body, 'kroppen', 'og kroppen');

    { En kjede som ikke tar slutt skal stoppe, ikke henge. }
    Feil := '';
    try
      K.Get(Base + '/evig');
    except
      on E: EHttpClientError do Feil := E.Message;
    end;
    AssertTrue(Pos('Too many redirects', Feil) > 0,
      'en evig omdirigering stoppes');

    { Med MaxRedirects = 0 returneres 302-svaret som det er. }
    K.MaxRedirects := 0;
    R := K.Get(Base + '/flytt');
    AssertEqual(R.Status, 302, 'uten å følge ser man selve omdirigeringen');
    AssertEqual(R.Header('Location'), '/hei', 'og Location');
  finally
    K.Free;
  end;
end;

procedure TestKlientStroemming;
var
  K: THttpClient;
  R: THttpResponse;
  Base: string;
begin
  K := THttpClient.Create;
  Base := Format('http://127.0.0.1:%d', [KlientPort]);
  try
    StroemBiter := 0;
    StroemTekst := '';
    R := K.Stream('GET', Base + '/stor', '', '', @SamleBit);
    AssertEqual(R.Status, 200, 'strømmet svar har fortsatt status');
    AssertEqual(R.Body, '', 'kroppen samles ikke opp når den strømmes');
    AssertEqual(Length(StroemTekst), 300000, 'men callbacken fikk alt');
    AssertTrue(StroemBiter > 1, 'og den fikk det i flere biter');

    { False fra callbacken skal stoppe lesingen. }
    StroemBiter := 0;
    StroemTekst := '';
    R := K.Stream('GET', Base + '/stor', '', '', @StoppEtterFoerste);
    AssertEqual(StroemBiter, 1, 'callbacken kan si stopp');
    AssertTrue(Length(StroemTekst) < 300000, 'og da leses ikke resten');
  finally
    K.Free;
  end;
end;

procedure TestKlientFeil;
var
  K: THttpClient;
  Feil: string;
begin
  K := THttpClient.Create;
  try
    Feil := '';
    try
      K.Get('ftp://example.com/x');
    except
      on E: EHttpClientError do Feil := E.Message;
    end;
    AssertTrue(Pos('not an http', Feil) > 0,
      'en adresse som ikke er http avvises med en gang');

    { En port ingen lytter på. Meldingen skal si hvor. }
    Feil := '';
    K.ConnectTimeoutMs := 2000;
    try
      K.Get('http://127.0.0.1:9/finnes-ikke');
    except
      on E: EHttpClientError do Feil := E.Message;
    end;
    AssertTrue(Pos('127.0.0.1', Feil) > 0,
      'en forbindelse som ikke går opp nevner verten');

    Feil := '';
    try
      K.Get('http://ingen-slik-vert.invalid/x');
    except
      on E: EHttpClientError do Feil := E.Message;
    end;
    AssertTrue(Pos('resolve', Feil) > 0, 'og et navn som ikke finnes');

    { Taket på svarstørrelse er en sperre, ikke en optimalisering. }
    K.MaxResponseBytes := 1000;
    Feil := '';
    try
      K.Get(Format('http://127.0.0.1:%d/stor', [KlientPort]));
    except
      on E: EHttpClientError do Feil := E.Message;
    end;
    AssertTrue(Pos('exceeded', Feil) > 0, 'et for stort svar avvises');
  finally
    K.Free;
  end;
end;


{ --------------------------------------------------------------- AI -- }

var
  AiBiter: TStringList;
  AiVerktoeyKall: Integer;
  AiSisteArg: string;

function AiSamle(const Delta: string): Boolean;
begin
  AiBiter.Add(Delta);
  Result := True;
end;

function AiStopp(const Delta: string): Boolean;
begin
  AiBiter.Add(Delta);
  Result := False;
end;

function VaerVerktoey(const InputJson: string): string;
begin
  Inc(AiVerktoeyKall);
  AiSisteArg := InputJson;
  Result := '{"temp_c": 7, "sky": "regn"}';
end;

function SprekkVerktoey(const InputJson: string): string;
begin
  Result := '';
  raise Exception.Create('verktøyet feilet');
end;

function NyKlient(out F: TFakeAiTransport): TAiClient;
begin
  Result := TAiClient.Create('test-nokkel');
  F := TFakeAiTransport.Create;
  Result.UseTransport(F, True);
end;

{ Et svar slik API-et sender det. }
function AiSvar(const Tekst: string): string;
begin
  Result := '{"id":"msg_1","type":"message","role":"assistant",' +
    '"model":"claude-opus-5","content":[{"type":"text","text":"' +
    Tekst + '"}],"stop_reason":"end_turn",' +
    '"usage":{"input_tokens":12,"output_tokens":34}}';
end;

procedure TestAiRequestform;
var
  K: TAiClient;
  F: TFakeAiTransport;
  Sendt: string;
begin
  K := NyKlient(F);
  try
    F.Enqueue(AiSvar('hei'));
    AssertEqual(K.Ask('si hei'), 'hei', 'det enkleste kallet virker');

    Sendt := F.Sent[0];
    { Formen på requesten er det eneste vi kan holde fast uten en nøkkel,
      og da skal den holdes fast nøyaktig. }
    AssertTrue(Pos('"model":"claude-opus-5"', Sendt) > 0,
      'standardmodellen er claude-opus-5');
    AssertTrue(Pos('"max_tokens":4096', Sendt) > 0, 'max_tokens er med');
    AssertTrue(Pos('"role":"user"', Sendt) > 0, 'meldingen har rolle');
    AssertTrue(Pos('"content":"si hei"', Sendt) > 0, 'og innhold');
    { Uten stream skal feltet ikke være der i det hele tatt. }
    AssertEqual(Pos('"stream"', Sendt), 0, 'ingen stream på et vanlig kall');
    AssertEqual(Pos('"thinking"', Sendt), 0, 'og ingen thinking når den er av');
    AssertEqual(Pos('"temperature"', Sendt), 0,
      'ingen temperature når den ikke er satt');

    { System, temperatur og modell settes av appen. }
    K.System_ := 'Du er kort.';
    K.Model := 'claude-haiku-4-5';
    K.SetTemperature(0.2);
    K.MaxTokens := 100;
    F.Enqueue(AiSvar('ok'));
    K.Ask('noe');
    Sendt := F.Sent[1];
    AssertTrue(Pos('"system":"Du er kort."', Sendt) > 0, 'system er med');
    AssertTrue(Pos('"model":"claude-haiku-4-5"', Sendt) > 0,
      'modellen kan byttes');
    AssertTrue(Pos('"temperature":0.2', Sendt) > 0, 'temperature er med');
    AssertTrue(Pos('"max_tokens":100', Sendt) > 0, 'max_tokens kan settes');

    { Dette er fella som er verdt en egen test: den gamle formen med
      budget_tokens avvises med 400 av modellene her. }
    K.Thinking := atAdaptive;
    F.Enqueue(AiSvar('ok'));
    K.Ask('noe');
    Sendt := F.Sent[2];
    AssertTrue(Pos('"thinking":{"type":"adaptive"}', Sendt) > 0,
      'tenkning sendes som adaptive');
    AssertEqual(Pos('budget_tokens', Sendt), 0,
      'og aldri med budget_tokens');
  finally
    K.Free;
  end;
end;

procedure TestAiSvarOgFeil;
var
  K: TAiClient;
  F: TFakeAiTransport;
  R: TAiResponse;
  Feil: string;
  E: EAiError;
begin
  K := NyKlient(F);
  try
    F.Enqueue(AiSvar('svaret'));
    R := K.Send([UserMsg('spørsmål')]);
    AssertEqual(R.Text, 'svaret', 'teksten plukkes ut');
    AssertEqual(R.StopReason, 'end_turn', 'stop_reason');
    AssertEqual(R.Model, 'claude-opus-5', 'modellen svaret kom fra');
    AssertEqual(R.Usage.InputTokens, 12, 'input-tokens telles');
    AssertEqual(R.Usage.OutputTokens, 34, 'output-tokens også');
    AssertFalse(R.WantsTool, 'ingen verktøykall');

    { Flere tekstblokker settes sammen. }
    F.Enqueue('{"content":[{"type":"text","text":"en "},' +
      '{"type":"text","text":"to"}],"stop_reason":"end_turn"}');
    R := K.Send([UserMsg('x')]);
    AssertEqual(R.Text, 'en to', 'flere tekstblokker settes sammen');

    { Tenkeblokker holdes for seg. }
    F.Enqueue('{"content":[{"type":"thinking","thinking":"hmm"},' +
      '{"type":"text","text":"svar"}],"stop_reason":"end_turn"}');
    R := K.Send([UserMsg('x')]);
    AssertEqual(R.Thinking, 'hmm', 'tenkningen er for seg');
    AssertEqual(R.Text, 'svar', 'og teksten for seg');

    { En feil fra API-et skal bli en EAiError med type og status, ikke en
      tom streng kalleren må gjette om. }
    F.Enqueue('{"type":"error","error":{"type":"rate_limit_error",' +
      '"message":"Number of requests has exceeded your rate limit"}}', 429);
    Feil := '';
    E := nil;
    try
      K.Ask('x');
    except
      on Ex: EAiError do
      begin
        Feil := Ex.Message;
        AssertEqual(Ex.Status, 429, 'statusen er med');
        { Kind er typen slik API-et skriver den, uten pynt: kallende kode
          skal kunne sammenligne på den for å avgjøre om den skal prøve
          igjen. }
        AssertEqual(Ex.Kind, 'rate_limit_error', 'og Anthropics feiltype');
      end;
    end;
    AssertTrue(Pos('rate limit', Feil) > 0, 'meldingen er API-ets egen');

    { Et svar som ikke er JSON skal si det, ikke krasje et sted lenger inne. }
    F.Enqueue('<html>503 fra en proxy</html>', 503);
    Feil := '';
    try
      K.Ask('x');
    except
      on Ex: EAiError do Feil := Ex.Message;
    end;
    AssertTrue(Pos('503', Feil) > 0, 'en HTML-feilside gir en lesbar feil');
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
  K := NyKlient(F);
  AiBiter := TStringList.Create;
  try
    Sse :=
      'event: message_start'#10 +
      'data: {"type":"message_start","message":{"usage":{"input_tokens":5}}}'#10 +
      #10 +
      ': en holdepuls'#10 +
      'data: {"type":"content_block_delta","index":0,' +
      '"delta":{"type":"text_delta","text":"Hei"}}'#10 +
      'data: {"type":"content_block_delta","index":0,' +
      '"delta":{"type":"text_delta","text":" der"}}'#10 +
      'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},' +
      '"usage":{"output_tokens":9}}'#10 +
      'data: [DONE]'#10;
    F.EnqueueStream(Sse);

    R := K.Stream('si hei', @AiSamle);
    AssertEqual(AiBiter.Count, 2, 'to tekstbiter gjennom callbacken');
    AssertEqual(AiBiter[0], 'Hei', 'første bit');
    AssertEqual(AiBiter[1], ' der', 'andre bit');
    AssertEqual(R.Text, 'Hei der', 'og hele teksten er samlet i svaret');
    AssertEqual(R.StopReason, 'end_turn', 'stop_reason fra message_delta');
    AssertEqual(R.Usage.InputTokens, 5, 'input-tokens fra message_start');
    AssertEqual(R.Usage.OutputTokens, 9, 'output-tokens fra message_delta');
    AssertTrue(Pos('"stream":true', F.Sent[0]) > 0,
      'requesten ba om strømming');

    { Callbacken skal kunne si stopp. }
    AiBiter.Clear;
    F.EnqueueStream(Sse);
    R := K.Stream('si hei', @AiStopp);
    AssertEqual(AiBiter.Count, 1, 'callbacken stoppet etter første bit');
  finally
    AiBiter.Free;
    K.Free;
  end;
end;

procedure TestAiVerktoey;
var
  K: TAiClient;
  F: TFakeAiTransport;
  R: TAiResponse;
  Sendt, Feil: string;
begin
  K := NyKlient(F);
  try
    AiVerktoeyKall := 0;
    AiSisteArg := '';
    K.AddTool('vaer', 'Slår opp været på et sted',
      '{"type":"object","properties":{"sted":{"type":"string"}},' +
      '"required":["sted"]}', @VaerVerktoey);
    AssertEqual(K.ToolCount, 1, 'verktøyet er registrert');

    { Første svar ber om verktøyet, andre svarer ferdig. }
    F.Enqueue('{"content":[{"type":"text","text":"Jeg sjekker."},' +
      '{"type":"tool_use","id":"tu_1","name":"vaer",' +
      '"input":{"sted":"Oslo"}}],"stop_reason":"tool_use"}');
    F.Enqueue(AiSvar('Det regner i Oslo.'));

    R := K.RunTools('hvordan er været i Oslo');
    AssertEqual(AiVerktoeyKall, 1, 'verktøyet ble kalt én gang');
    { Argumentene kommer som JSON-tekst — bare verktøyet vet hvilke felter
      det har, så rammeverket gir dem videre som de er. }
    AssertTrue(Pos('"sted":"Oslo"', AiSisteArg) > 0,
      'og fikk argumentene fra modellen');
    AssertTrue(Pos('Det regner', R.Text) > 0, 'og løkka kom til et svar');

    { Verktøyet skal stå i requesten med skjemaet sitt. }
    Sendt := F.Sent[0];
    AssertTrue(Pos('"name":"vaer"', Sendt) > 0, 'verktøyet er med');
    AssertTrue(Pos('"input_schema":{"type":"object"', Sendt) > 0,
      'og skjemaet sendes som det er');

    { Andre runde må ha resultatet med, som en tool_result-blokk i en
      user-melding. Det er den vanligste feilen når man bygger løkka selv. }
    Sendt := F.Sent[1];
    AssertTrue(Pos('"type":"tool_result"', Sendt) > 0,
      'resultatet sendes som tool_result');
    AssertTrue(Pos('"tool_use_id":"tu_1"', Sendt) > 0,
      'og peker tilbake med id');
    AssertTrue(Pos('temp_c', Sendt) > 0, 'med det verktøyet returnerte');

    { Et verktøy som kaster skal ikke ta ned løkka — modellen får feilen. }
    K.ClearTools;
    K.AddTool('sprekk', 'Feiler alltid', '{"type":"object"}',
      @SprekkVerktoey);
    F.Enqueue('{"content":[{"type":"tool_use","id":"tu_2",' +
      '"name":"sprekk","input":{}}],"stop_reason":"tool_use"}');
    F.Enqueue(AiSvar('Jeg fikk en feil.'));
    R := K.RunTools('prøv');
    AssertTrue(Pos('Jeg fikk en feil', R.Text) > 0,
      'et verktøy som kaster stopper ikke løkka');
    AssertTrue(Pos('"is_error":true', F.Sent[3]) > 0,
      'og feilen merkes som feil');

    { Et verktøy modellen finner på skal heller ikke velte noe. }
    F.Enqueue('{"content":[{"type":"tool_use","id":"tu_3",' +
      '"name":"finnes-ikke","input":{}}],"stop_reason":"tool_use"}');
    F.Enqueue(AiSvar('Beklager.'));
    R := K.RunTools('prøv');
    AssertTrue(Pos('no such tool', F.Sent[5]) > 0,
      'et ukjent verktøy blir en beskjed til modellen');

    { Løkka har et tak. }
    K.MaxTurns := 2;
    K.ClearTools;
    K.AddTool('vaer', 'x', '{"type":"object"}', @VaerVerktoey);
    F.Enqueue('{"content":[{"type":"tool_use","id":"a","name":"vaer",' +
      '"input":{}}],"stop_reason":"tool_use"}');
    F.Enqueue('{"content":[{"type":"tool_use","id":"b","name":"vaer",' +
      '"input":{}}],"stop_reason":"tool_use"}');
    Feil := '';
    try
      K.RunTools('gå i ring');
    except
      on E: EAiError do Feil := E.Message;
    end;
    AssertTrue(Pos('did not finish within 2 turns', Feil) > 0,
      'en løkke som ikke tar slutt stoppes');
  finally
    K.Free;
  end;
end;

procedure TestAiStrukturert;
var
  K: TAiClient;
  F: TFakeAiTransport;
  Svar, Sendt, Feil: string;
begin
  K := NyKlient(F);
  try
    F.Enqueue('{"content":[{"type":"tool_use","id":"t","name":"respond",' +
      '"input":{"navn":"Ada","alder":36,"aktiv":true}}],' +
      '"stop_reason":"tool_use"}');
    Svar := K.Structured('hvem er hun',
      '{"type":"object","properties":{"navn":{"type":"string"},' +
      '"alder":{"type":"integer"}},"required":["navn"]}');

    { Resultatet er JSON, ikke prosa. }
    AssertTrue(Pos('"navn":"Ada"', Svar) > 0, 'feltene kom tilbake');
    AssertTrue(Pos('"alder":36', Svar) > 0, 'også tallene');
    AssertTrue(Pos('"aktiv":true', Svar) > 0, 'og boolske');

    Sendt := F.Sent[0];
    { Det er tool_choice som gjør at svaret blir strukturert og ikke prosa
      ved siden av. }
    AssertTrue(Pos('"tool_choice":{"type":"tool","name":"respond"}', Sendt) > 0,
      'modellen tvinges til verktøyet');

    { Structured skal ikke endre klienten den ble kalt på. }
    AssertEqual(K.ToolCount, 0, 'verktøyene er som før etterpå');

    { Svarer modellen med tekst likevel, skal det være en feil og ikke en
      tom streng kalleren må gjette om. }
    F.Enqueue(AiSvar('Hun heter Ada.'));
    Feil := '';
    try
      K.Structured('hvem', '{"type":"object"}');
    except
      on E: EAiError do Feil := E.Message;
    end;
    AssertTrue(Pos('instead of the requested structure', Feil) > 0,
      'prosa i stedet for struktur er en feil');
  finally
    K.Free;
  end;
end;

{ ------------------------------------------------------------------ main -- }

{ ------------------------------------------------------------- bilder -- }

function BildeFil(const Navn: string): TBytes;
var
  F: TFileStream;
  Sti: string;
  B: TBytes;
begin
  B := nil;
  Result := B;
  Sti := 'tests/vectors/images/' + Navn;
  if not FileExists(Sti) then
    Exit;
  F := TFileStream.Create(Sti, fmOpenRead);
  try
    SetLength(B, F.Size);
    if F.Size > 0 then
      F.ReadBuffer(B[0], F.Size);
    Result := B;
  finally
    F.Free;
  end;
end;

function FmtNavn(F: TImageFormat): string;
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
  S, Navn, Fmt: string;
  Inf: TImageInfo;
begin
  Gale := 0;
  L := TStringList.Create;
  try
    if not FileExists('tests/vectors/images/expected.txt') then
    begin
      AssertTrue(False, 'bildefixturene finnes (kjør fra repo-rota)');
      Exit;
    end;
    L.LoadFromFile('tests/vectors/images/expected.txt');
    for I := 0 to L.Count - 1 do
    begin
      S := Trim(L[I]);
      if (S = '') or (S[1] = '#') then
        Continue;
      K := Pos(' ', S); Navn := Copy(S, 1, K - 1);
      S := Trim(Copy(S, K + 1, Length(S)));
      K := Pos(' ', S); Fmt := Copy(S, 1, K - 1);
      S := Trim(Copy(S, K + 1, Length(S)));
      K := Pos(' ', S); W := StrToIntDef(Copy(S, 1, K - 1), -1);
      S := Trim(Copy(S, K + 1, Length(S)));
      K := Pos(' ', S); H := StrToIntDef(Copy(S, 1, K - 1), -1);
      A := StrToIntDef(Trim(Copy(S, K + 1, Length(S))), 0);

      Inf := ReadImageInfo('tests/vectors/images/' + Navn);
      if FmtNavn(Inf.Format) <> Fmt then Inc(Gale);
      if (W > 0) and ((Inf.Width <> W) or (Inf.Height <> H)) then Inc(Gale);
      if (A = 1) <> Inf.Animated then Inc(Gale);
    end;
  finally
    L.Free;
  end;
  AssertEqual(Gale, 0, 'format og dimensjoner leses uten å dekode');
end;

procedure TestBildeSikkerhet;
var
  D: TBytes;
begin
  { Den viktigste enkeltsjekken i uniten: en fil som heter .jpg og er
    HTML er en lagret XSS-vektor hvis den serveres tilbake. }
  D := BildeFil('nope.jpg');
  AssertTrue(SniffFormat(D) = ifUnknown, 'HTML forkledd som .jpg er ikke et bilde');
  AssertTrue(not ExtensionMatches('nope.jpg', D), 'og endelsen avsløres');

  D := BildeFil('jpeg_320x240.jpg');
  AssertTrue(ExtensionMatches('a.jpg', D), 'ekte jpeg matcher .jpg');
  AssertTrue(ExtensionMatches('a.jpeg', D), '.jpeg regnes som det samme');
  AssertTrue(not ExtensionMatches('a.png', D), 'men ikke .png');
  AssertTrue(not ExtensionMatches('a.jpg', BildeFil('tom.png')),
    'en tom fil er ingenting');
end;

procedure TestExifStripping;
var
  D, Ut: TBytes;
  Inf: TImageInfo;
begin
  D := BildeFil('jpeg_exif_gps.jpg');
  AssertEqual(JpegOrientation(D), 6, 'orienteringen leses fra EXIF');
  AssertTrue(Pos('Askr Test', TEncoding.ASCII.GetString(D)) > 0,
    'EXIF står i fila før stripping');

  AssertTrue(StripJpegMetadata(D, Ut), 'strippingen lykkes');
  AssertTrue(Pos('Askr Test', TEncoding.ASCII.GetString(Ut)) = 0,
    'EXIF er borte etterpå');
  AssertTrue(Length(Ut) < Length(D), 'og fila er mindre');
  AssertTrue(SniffFormat(Ut) = ifJpeg, 'men fortsatt en jpeg');
  Inf := ReadImageInfo(Ut);
  AssertTrue((Inf.Width = 800) and (Inf.Height = 600), 'med dimensjonene i behold');

  AssertEqual(JpegOrientation(BildeFil('jpeg_orient3.jpg')), 3,
    'orientering 3 leses også');
  AssertEqual(JpegOrientation(BildeFil('jpeg_320x240.jpg')), 0,
    'uten EXIF er orienteringen 0');
  AssertTrue(not StripJpegMetadata(BildeFil('png_320x240.png'), Ut),
    'en png kan ikke strippes som jpeg');
end;

procedure TestVips;
var
  Inn, Ut: TBytes;
  Inf: TImageInfo;
begin
  if not VipsAvailable then
  begin
    { Ikke en feil. libvips er en valgfri avhengighet, og suiten sier
      hvorfor den hopper i stedet for å tie. }
    WriteLn('    (hoppet over: ', Copy(VipsError, 1, 48), '…)');
    AssertTrue(VipsError <> '', 'og feilen sier hva som mangler');
    Exit;
  end;

  Inn := BildeFil('jpeg_1920x1080.jpg');
  Ut := ResizeImage(Inn, 320, 0, ifJpeg, 80);
  Inf := ReadImageInfo(Ut);
  AssertEqual(Inf.Width, 320, 'skalert til oppgitt bredde');
  AssertEqual(Inf.Height, 180, 'høyden følger forholdet');
  AssertTrue(Length(Ut) < Length(Inn), 'og fila er mindre');

  Ut := ResizeImage(Inn, 200, 200, ifJpeg, 80, fmCover);
  Inf := ReadImageInfo(Ut);
  AssertTrue((Inf.Width = 200) and (Inf.Height = 200),
    'cover fyller boksen nøyaktig');

  Ut := ResizeImage(Inn, 200, 200, ifJpeg, 80, fmInside);
  Inf := ReadImageInfo(Ut);
  AssertTrue((Inf.Width = 200) and (Inf.Height < 200),
    'inside fyller den ikke');

  AssertTrue(SniffFormat(ResizeImage(Inn, 100, 0, ifPng)) = ifPng,
    'jpeg blir png');
  AssertTrue(SniffFormat(ResizeImage(Inn, 100, 0, ifWebp, 75)) = ifWebp,
    'jpeg blir webp');
  AssertTrue(Length(ResizeImage(Inn, 600, 0, ifJpeg, 30)) <
             Length(ResizeImage(Inn, 600, 0, ifJpeg, 95)),
    'lavere kvalitet gir mindre fil');

  { Oppskalering er aldri det noen ba om. }
  AssertEqual(ReadImageInfo(ResizeImage(BildeFil('jpeg_320x240.jpg'),
    2000, 0, ifJpeg, 80)).Width, 320, 'skalerer aldri opp');

  { libvips strippes også, gjennom strip=true i formatstrengen. }
  Ut := ResizeImage(BildeFil('jpeg_exif_gps.jpg'), 200, 0, ifJpeg, 80);
  AssertTrue(Pos('Askr Test', TEncoding.ASCII.GetString(Ut)) = 0,
    'EXIF overlever ikke en skalering');

  Inf := ReadImageInfo(ConvertImage(BildeFil('png_320x240.png'), ifWebp, 80));
  AssertTrue((Inf.Width = 320) and (Inf.Height = 240) and (Inf.Format = ifWebp),
    'konvertering beholder størrelsen');
end;
begin
  Group('Scheduler');
  Group('Bilder');
  Test('format og dimensjoner uten å dekode', @TestBildeHoder);
  Test('en fil som lyver om hva den er, avsløres', @TestBildeSikkerhet);
  Test('EXIF og GPS fjernes uten å røre pikslene', @TestExifStripping);
  Test('skalering og konvertering (libvips)', @TestVips);

  Test('lauf har samme versjon som rammeverket', @TestLaufFoelgerRammeverket);
  Test('semver sammenlignes som tall, ikke som tekst', @TestSemVerSammenligning);
  Test('intervall kjører når det forfaller', @TestIntervall);
  Test('daglig kjører én gang per døgn', @TestDaglig);
  Test('ukentlig kjører én gang per uke', @TestUkentlig);
  Test('hopper over når køen venter', @TestHoppOverNaarKoenVenter);
  Test('planen kan leses', @TestBeskrivelse);

  Group('Varig kø');
  Test('jobbene overlever en omstart', @TestVarigOverleverOmstart);
  Test('feilet jobb havner i feiltabellen og kan legges tilbake',
    @TestVarigFeilerOgGirOpp);
  Test('jobb uten handler forsvinner ikke', @TestVarigUkjentJobb);
  Test('forsinkelse, og binært avvises', @TestVarigForsinkelseOgBinaert);
  Test('forlatt reservasjon slippes', @TestVarigForlattReservasjon);

  Group('Sesjoner');
  Test('rundtur med kake', @TestSesjonRundtur);
  Test('flash lever nøyaktig én request', @TestFlashLeverEnRequest);
  Test('valideringsfeil overlever omdirigering',
    @TestValideringsfeilOverlevererOmdirigering);
  Test('Inertia tar med flash uansett nøkkel', @TestInertiaFlashUansettNokkel);
  Test('sesjonen lekker ikke ut av requesten',
    @TestSesjonenLekkerIkkeUtAvRequesten);

  Group('CSRF');
  Test('avviser uten token', @TestCsrfAvviserUtenToken);
  Test('godtar felt, X-CSRF-Token og X-XSRF-Token',
    @TestCsrfGodtarAlleTreKilder);
  Test('tokenet er stabilt og bundet til sesjonen',
    @TestCsrfTokenetErStabiltOgPerSesjon);
  Test('unntak for webhooks', @TestCsrfUnntakForWebhooks);
  Test('sesjonskaka og XSRF-kaka lever side om side',
    @TestCsrfKakeneLeverSideOmSide);

  Group('Auth');
  Test('innlogging bytter sesjons-id, utlogging tømmer', @TestAuthInnOgUt);
  Test('husk meg er signert, utløper og kan slettes', @TestAuthHuskMeg);
  Test('gates svarer nei som standard', @TestAuthGates);
  Test('RequireAuth omdirigerer, men gir 401 til JSON', @TestAuthRequire);
  Test('brukeren slås opp én gang per request',
    @TestAuthBrukeroppslagCaches);

  Group('Logg');
  Test('nivåer filtrerer', @TestLoggNivaa);
  Test('tekstformat siterer når det trengs', @TestLoggTekstformat);
  Test('json er gyldig, med tall som tall', @TestLoggJson);
  Test('exception blir egne felter', @TestLoggException);
  Test('fil åpnes for tillegg', @TestLoggTilFil);

  Group('Konfigurasjon');
  Test('miljø vinner over .env vinner over askr.toml', @TestConfigLag);
  Test('rapporten viser ikke hemmeligheter', @TestConfigRapport);
  Test('APP_ENV og RequireEnv', @TestMiljoe);

  Group('HTTP-klient');
  Test('URL-er deles riktig', @TestKlientUrl);
  Test('mot Askrs egen server', @TestKlientMotEgenServer);
  Test('omdirigering følges, og stoppes', @TestKlientOmdirigering);
  Test('strømming, og callbacken kan si stopp', @TestKlientStroemming);
  Test('chunked settes sammen igjen', @TestKlientChunked);
  Test('localhost slås opp i /etc/hosts', @TestKlientLocalhost);
  Test('feilene sier hva som var galt', @TestKlientFeil);

  Group('AI');
  Test('requesten har riktig form', @TestAiRequestform);
  Test('svar plukkes fra hverandre, feil blir feil', @TestAiSvarOgFeil);
  Test('SSE settes sammen, callbacken kan stoppe', @TestAiStroemming);
  Test('verktøyløkka kjører, feiler pent og har tak', @TestAiVerktoey);
  Test('strukturert utdata tvinges gjennom et verktøy',
    @TestAiStrukturert);

  Group('Mail');
  Test('melding rendres som RFC 5322', @TestMeldingRendres);
  Test('tekst og html blir multipart', @TestMultipart);
  Test('bcc er mottaker, men ikke i hodet', @TestBccSkjulesIHodet);
  Test('melding uten avsender avvises', @TestManglerAvsender);
  Test('transporten velges av mail.transport', @TestMailFraConfig);
  Test('SMTP AUTH PLAIN kodes som SASL sier', @TestSmtpAuthPlain);
  Test('SMTP faller til AUTH LOGIN når PLAIN ikke tilbys',
    @TestSmtpAuthLogin);
  Test('passordet går aldri i klartekst uten at noen har sagt det',
    @TestSmtpAuthKreverKryptering);
  Test('en mekanisme vi ikke kan, er en feil', @TestSmtpAuthUkjentMekanisme);
  Test('uten brukernavn sendes ingen AUTH', @TestSmtpUtenBruker);

  Group('Resend');
  Test('forespørselen har riktig form', @TestResendForm);
  Test('reply-to blir et eget felt, andre hoder blir headers',
    @TestResendReplyTo);
  Test('felter uten innhold skrives ikke ut', @TestResendIngenHoder);
  Test('idempotensnøkkelen sendes med', @TestResendIdempotens);
  Test('samme melding gir samme nøkkel over et gjenforsøk',
    @TestResendSammeMeldingSammeNoekkel);
  Test('en feil blir EResendError med status og type', @TestResendFeil);
  Test('rate limit kan prøves om igjen, kvote kan ikke',
    @TestResendRateLimit);
  Test('ukjent feilform gir fortsatt en brukbar melding',
    @TestResendUkjentFeilform);
  Test('melding uten kropp avvises før nettverket', @TestResendTomKropp);
  Test('nøkkelen står ikke i Describe', @TestResendLekkerIkkeNoekkel);
  Test('headerne ligger i byte-ene på lufta', @TestResendPaaLufta);

  Group('Testklienten');
  Test('ruter, parametre og kropp uten socket', @TestKlientMotRuter);
  Test('arenaen flater ut', @TestArenaFlaterUt);
  Test('velkomstsiden svarer uten byggesteg', @TestVelkomstside);
  Test('.env leses, og miljøet vinner over den', @TestEnv);

  InitCriticalSection(VarigLaas);

  { Serveren klienttestene ringer. Port 0 lar kjernen velge, slik at
    suitene kan kjøre parallelt uten å krangle om porter — samme grep som
    ende-til-ende-delen i askr_tests. }
  EkkoH := TEkkoServer.Create;
  EkkoOpts := DefaultServerOptions;
  EkkoOpts.Port := 0;
  EkkoOpts.Workers := 2;
  EkkoSrv := TAskrServer.Create(EkkoOpts);
  EkkoSrv.SetHandler(EkkoH.Handle);
  EkkoSrv.Start;
  KlientPort := EkkoSrv.BoundPort;

  Brukere[0] := TBruker.Create;
  Brukere[0].Navn := 'Ada';
  Brukere[0].ErAdmin := True;
  Brukere[1] := TBruker.Create;
  Brukere[1].Navn := 'Grace';
  Brukere[1].ErAdmin := False;

  WriteLn('Askr — kjøretidstester (skrevet med Askr.Testing)');
  { Serveren stoppes ikke her: RunTestsAndHalt kaller Halt, og prosessen
    tar den med seg. Å rydde etter Halt er ikke mulig uansett. }
  RunTestsAndHalt;
end.
