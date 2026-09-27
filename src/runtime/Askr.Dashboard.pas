{ Askr.Dashboard -- /_askr: what the app is doing, from inside it.

      UseDashboard(R, Cfg('app.env', 'local') = 'local', DbPool);

  The routes that answered and how long they took, the statements that
  took the time, the jobs by what became of them, mail sent and failed,
  and the pool, the queue and the plugins as they are now. It is
  LiveDashboard's idea on a compiled stack: the numbers come from
  telemetry, which the framework emits whether or not anyone listens,
  and the page is in the binary -- plain HTML with no script, no npm and
  nothing fetched, like the welcome page.

  **Open is for development.** With Open false the page answers only to a
  user the gate askr.dashboard allows, and to everyone else it is a 404 --
  not a 403, which would say there is something here. Without that gate
  defined it answers nobody: a gate that does not exist says no.

      DefineGate('askr.dashboard', @IsAdmin);

  **It shows what the app ran, and that can include values.** A statement
  sent with placeholders is shown as written, without its parameters; one
  an app built with a value spliced into its text is shown with it. That
  is the reason it is closed by default outside development.

  Memory is fixed: fifty recent requests, and at most two hundred routes,
  two hundred statements and a hundred jobs remembered, the rest counted.
  The dashboard's own requests are not in its numbers. }
unit Askr.Dashboard;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, StrUtils, SyncObjs,
  Askr.Core.Text, Askr.Core.Clock, Askr.Core.Telemetry,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response, Askr.Http.Router,
  Askr.Urd.Pool, Askr.Queue, Askr.Auth, Askr.Plugins;

const
  DashboardGate = 'askr.dashboard';
  DashboardPath = '/_askr';

{ The page at /_askr, and the telemetry it is drawn from. Pool is the app's
  pool, for its gauges, and may be nil. Call it once, after UseAuth: the
  gate asks who is signed in. }
procedure UseDashboard(R: TRouter; Open: Boolean; Pool: TDbPool = nil);

{ Forgets what the dashboard has counted, and stops listening. For tests. }
procedure ResetDashboard;

implementation

const
  RecentMax = 50;
  RoutesMax = 200;
  StatementsMax = 200;
  JobsMax = 100;

type
  TRecent = record
    At: Int64;
    Method, Path, Route: string;
    Status: Integer;
    Us: Int64;
  end;

  TTally = record
    Key: string;
    Count, Errors: Int64;
    TotalUs, MaxUs: Int64;
  end;

  TJobTally = record
    Name: string;
    Done, Retry, Failed, Dropped: Int64;
    TotalUs: Int64;
  end;

var
  GLock: TCriticalSection;
  GAttached: Boolean = False;
  GOpen: Boolean = False;
  GPool: TDbPool = nil;
  GStarted: Int64 = 0;
  GRecent: array[0..RecentMax - 1] of TRecent;
  GRecentNext: Integer = 0;
  GRecentCount: Integer = 0;
  GRoutes: TArray<TTally>;
  GStatements: TArray<TTally>;
  GJobs: TArray<TJobTally>;
  GRequests, GQueries, GQueryErrors, GMailSent, GMailFailed: Int64;
  GUncountedRoutes, GUncountedStatements: Int64;

function FindTally(const List: array of TTally; const Key: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(List) do
    if List[I].Key = Key then
      Exit(I);
  Result := -1;
end;

{ Adds one to Key's tally, making a place for it while there is room, and
  counting it as unlisted when there is none. }
procedure AddTally(var List: TArray<TTally>; Max: Integer; const Key: string;
  Us: Int64; IsError: Boolean; var Uncounted: Int64);
var
  I: Integer;
begin
  I := FindTally(List, Key);
  if I < 0 then
  begin
    if Length(List) >= Max then
    begin
      Inc(Uncounted);
      Exit;
    end;
    SetLength(List, Length(List) + 1);
    I := High(List);
    List[I].Key := Key;
  end;
  Inc(List[I].Count);
  if IsError then
    Inc(List[I].Errors);
  Inc(List[I].TotalUs, Us);
  if Us > List[I].MaxUs then
    List[I].MaxUs := Us;
end;

procedure OnRequest(const E: TTelemetryEvent);
var
  R: TRecent;
  Key: string;
begin
  R.Path := E.Field('path');
  { Its own refreshes are not what anybody opened it to see. }
  if (R.Path = DashboardPath) or
     (Copy(R.Path, 1, Length(DashboardPath) + 1) = DashboardPath + '/') then
    Exit;
  R.At := UnixNow;
  R.Method := E.Field('method');
  R.Route := E.Field('route');
  R.Status := StrToIntDef(E.Field('status'), 0);
  R.Us := E.DurationUs;
  if R.Route = '' then
    Key := R.Method + ' (no route)'
  else
    Key := R.Method + ' ' + R.Route;
  GLock.Acquire;
  try
    Inc(GRequests);
    GRecent[GRecentNext] := R;
    GRecentNext := (GRecentNext + 1) mod RecentMax;
    if GRecentCount < RecentMax then
      Inc(GRecentCount);
    AddTally(GRoutes, RoutesMax, Key, R.Us, R.Status >= 500, GUncountedRoutes);
  finally
    GLock.Release;
  end;
end;

procedure OnQuery(const E: TTelemetryEvent);
var
  Failed: Boolean;
begin
  Failed := E.Field('error') <> '';
  GLock.Acquire;
  try
    Inc(GQueries);
    if Failed then
      Inc(GQueryErrors);
    AddTally(GStatements, StatementsMax, E.Field('sql'),
      E.DurationUs, Failed, GUncountedStatements);
  finally
    GLock.Release;
  end;
end;

procedure OnJob(const E: TTelemetryEvent);
var
  I: Integer;
  Name, Outcome: string;
begin
  Name := E.Field('job');
  Outcome := E.Field('outcome');
  GLock.Acquire;
  try
    I := 0;
    while (I <= High(GJobs)) and (GJobs[I].Name <> Name) do
      Inc(I);
    if I > High(GJobs) then
    begin
      if Length(GJobs) >= JobsMax then
        Exit;
      SetLength(GJobs, Length(GJobs) + 1);
      GJobs[I].Name := Name;
    end;
    if Outcome = 'done' then
      Inc(GJobs[I].Done)
    else if Outcome = 'retry' then
      Inc(GJobs[I].Retry)
    else if Outcome = 'failed' then
      Inc(GJobs[I].Failed)
    else if Outcome = 'dropped' then
      Inc(GJobs[I].Dropped);
    Inc(GJobs[I].TotalUs, E.DurationUs);
  finally
    GLock.Release;
  end;
end;

procedure OnMail(const E: TTelemetryEvent);
begin
  GLock.Acquire;
  try
    if E.Field('error') <> '' then
      Inc(GMailFailed)
    else
      Inc(GMailSent);
  finally
    GLock.Release;
  end;
end;

{ ----------------------------------------------------------------- page -- }

function Ms(Us: Int64): string;
begin
  { One decimal below ten milliseconds, whole above: 0.4 ms and 212 ms. }
  if Us < 10000 then
    Result := IntToStr(Us div 1000) + '.' + IntToStr((Us mod 1000) div 100) + ' ms'
  else
    Result := IntToStr(Us div 1000) + ' ms';
end;

function E_(const S: string): string;
begin
  Result := HtmlEscape(S);
end;

procedure SortByTotal(var List: TArray<TTally>);
var
  I, J: Integer;
  T: TTally;
begin
  for I := 1 to High(List) do
  begin
    T := List[I];
    J := I - 1;
    while (J >= 0) and (List[J].TotalUs < T.TotalUs) do
    begin
      List[J + 1] := List[J];
      Dec(J);
    end;
    List[J + 1] := T;
  end;
end;

procedure SortByCount(var List: TArray<TTally>);
var
  I, J: Integer;
  T: TTally;
begin
  for I := 1 to High(List) do
  begin
    T := List[I];
    J := I - 1;
    while (J >= 0) and (List[J].Count < T.Count) do
    begin
      List[J + 1] := List[J];
      Dec(J);
    end;
    List[J + 1] := T;
  end;
end;

const
  Css =
    ':root{color-scheme:light dark;--bg:#fbfbf9;--fg:#1d2126;--muted:#5d646d;' +
    '--line:#dfe1dc;--panel:#ffffff;--bad:#b42318;--ok:#1f7a4a}' +
    '@media (prefers-color-scheme:dark){:root{--bg:#15171a;--fg:#e6e8ea;' +
    '--muted:#9aa1a9;--line:#2c3036;--panel:#1c1f23;--bad:#ff8a80;--ok:#7ad3a1}}' +
    '*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);' +
    'font:14px/1.5 ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif;' +
    'padding:24px 16px}main{max-width:1100px;margin:0 auto}' +
    'h1{font-size:20px;margin:0 0 4px}h2{font-size:15px;margin:32px 0 8px}' +
    'p.sub{color:var(--muted);margin:0}' +
    '.gauges{display:flex;flex-wrap:wrap;gap:12px;margin-top:20px}' +
    '.gauge{background:var(--panel);border:1px solid var(--line);border-radius:6px;' +
    'padding:10px 14px;min-width:140px}.gauge dt{color:var(--muted);font-size:12px}' +
    '.gauge dd{margin:2px 0 0;font-size:18px;font-variant-numeric:tabular-nums}' +
    '.wrap{overflow-x:auto;border:1px solid var(--line);border-radius:6px;background:var(--panel)}' +
    'table{border-collapse:collapse;width:100%}th,td{padding:6px 10px;text-align:left;' +
    'border-bottom:1px solid var(--line);white-space:nowrap}' +
    'th{color:var(--muted);font-weight:500;font-size:12px}' +
    'td.num{text-align:right;font-variant-numeric:tabular-nums}' +
    'td.sql{white-space:normal;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px}' +
    'tr:last-child td{border-bottom:0}.bad{color:var(--bad)}.empty{color:var(--muted);padding:10px}' +
    'a{color:inherit}';

function Page: string;
var
  B: string;
  Routes, Statements: TArray<TTally>;
  Jobs: TArray<TJobTally>;
  Recent: array of TRecent;
  I, K, N: Integer;
  Plugins: TStringArray;
  Requests, Queries, QueryErrors, MailSent, MailFailed, Up: Int64;
  UncountedRoutes, UncountedStatements: Int64;

  procedure A(const S: string);
  begin
    B := B + S;
  end;

  procedure Gauge(const Label_, Value: string);
  begin
    A('<div class="gauge"><dt>' + E_(Label_) + '</dt><dd>' + E_(Value) + '</dd></div>');
  end;

begin
  { A copy under the lock, and the page built from the copy: a slow page
    must not hold up every request that is telemetry-counted meanwhile. }
  GLock.Acquire;
  try
    Routes := Copy(GRoutes);
    Statements := Copy(GStatements);
    Jobs := Copy(GJobs);
    SetLength(Recent, GRecentCount);
    for I := 0 to GRecentCount - 1 do
      Recent[I] := GRecent[(GRecentNext - 1 - I + RecentMax) mod RecentMax];
    Requests := GRequests;
    Queries := GQueries;
    QueryErrors := GQueryErrors;
    MailSent := GMailSent;
    MailFailed := GMailFailed;
    UncountedRoutes := GUncountedRoutes;
    UncountedStatements := GUncountedStatements;
  finally
    GLock.Release;
  end;
  Up := UnixNow - GStarted;

  B := '';
  A('<!doctype html><html lang="en"><head><meta charset="utf-8">');
  A('<meta name="viewport" content="width=device-width,initial-scale=1">');
  A('<meta name="robots" content="noindex">');
  A('<title>Askr dashboard</title><style>' + Css + '</style></head><body><main>');
  A('<h1>Askr dashboard</h1>');
  A('<p class="sub">Since this process started, ' + IntToStr(Up div 60) +
    ' min ago. <a href="' + DashboardPath + '">Refresh</a></p>');

  A('<dl class="gauges">');
  Gauge('Requests', IntToStr(Requests));
  Gauge('Queries', IntToStr(Queries));
  Gauge('Failed queries', IntToStr(QueryErrors));
  Gauge('Mail sent', IntToStr(MailSent));
  Gauge('Mail failed', IntToStr(MailFailed));
  if GPool <> nil then
    Gauge('Pool in use', IntToStr(GPool.LiveCount - GPool.IdleCount) + ' of ' +
      IntToStr(GPool.MaxConnections));
  if HasQueue then
  begin
    Gauge('Jobs pending', IntToStr(Queue.Pending));
    Gauge('Jobs failed', IntToStr(Queue.Failed));
  end;
  A('</dl>');

  { Where the time goes: routes by how often, statements by how long in
    all. A statement that is fast and runs a thousand times a page is the
    one to find, and only the total shows it. }
  SortByCount(Routes);
  A('<h2>Routes</h2><div class="wrap"><table><thead><tr><th>Route</th>' +
    '<th>Requests</th><th>5xx</th><th>Average</th><th>Slowest</th></tr></thead><tbody>');
  if Length(Routes) = 0 then
    A('<tr><td colspan="5" class="empty">No requests yet.</td></tr>');
  for I := 0 to High(Routes) do
    A('<tr><td>' + E_(Routes[I].Key) + '</td><td class="num">' +
      IntToStr(Routes[I].Count) + '</td><td class="num' +
      IfThen(Routes[I].Errors > 0, ' bad', '') + '">' +
      IntToStr(Routes[I].Errors) + '</td><td class="num">' +
      Ms(Routes[I].TotalUs div Routes[I].Count) + '</td><td class="num">' +
      Ms(Routes[I].MaxUs) + '</td></tr>');
  A('</tbody></table></div>');
  if UncountedRoutes > 0 then
    A('<p class="sub">' + IntToStr(UncountedRoutes) +
      ' requests to further routes are counted above but not listed.</p>');

  SortByTotal(Statements);
  N := Length(Statements);
  if N > 20 then
    N := 20;
  A('<h2>Statements, by total time</h2><div class="wrap"><table><thead><tr>' +
    '<th>SQL</th><th>Runs</th><th>Failed</th><th>Total</th><th>Average</th>' +
    '<th>Slowest</th></tr></thead><tbody>');
  if N = 0 then
    A('<tr><td colspan="6" class="empty">No queries yet.</td></tr>');
  for I := 0 to N - 1 do
    A('<tr><td class="sql">' + E_(Statements[I].Key) + '</td><td class="num">' +
      IntToStr(Statements[I].Count) + '</td><td class="num' +
      IfThen(Statements[I].Errors > 0, ' bad', '') + '">' +
      IntToStr(Statements[I].Errors) + '</td><td class="num">' +
      Ms(Statements[I].TotalUs) + '</td><td class="num">' +
      Ms(Statements[I].TotalUs div Statements[I].Count) + '</td><td class="num">' +
      Ms(Statements[I].MaxUs) + '</td></tr>');
  A('</tbody></table></div>');
  if UncountedStatements > 0 then
    A('<p class="sub">' + IntToStr(UncountedStatements) +
      ' runs of further statements are counted above but not listed.</p>');

  A('<h2>Jobs</h2><div class="wrap"><table><thead><tr><th>Job</th><th>Done</th>' +
    '<th>Retried</th><th>Failed</th><th>Dropped</th><th>Average</th></tr></thead><tbody>');
  if Length(Jobs) = 0 then
    A('<tr><td colspan="6" class="empty">No jobs yet.</td></tr>');
  for I := 0 to High(Jobs) do
  begin
    K := Jobs[I].Done + Jobs[I].Retry + Jobs[I].Failed + Jobs[I].Dropped;
    if K = 0 then
      K := 1;
    A('<tr><td>' + E_(Jobs[I].Name) + '</td><td class="num">' +
      IntToStr(Jobs[I].Done) + '</td><td class="num">' + IntToStr(Jobs[I].Retry) +
      '</td><td class="num' + IfThen(Jobs[I].Failed > 0, ' bad', '') + '">' +
      IntToStr(Jobs[I].Failed) + '</td><td class="num">' +
      IntToStr(Jobs[I].Dropped) + '</td><td class="num">' +
      Ms(Jobs[I].TotalUs div K) + '</td></tr>');
  end;
  A('</tbody></table></div>');

  A('<h2>Recent requests</h2><div class="wrap"><table><thead><tr><th>Method</th>' +
    '<th>Path</th><th>Route</th><th>Status</th><th>Time</th></tr></thead><tbody>');
  if Length(Recent) = 0 then
    A('<tr><td colspan="5" class="empty">No requests yet.</td></tr>');
  for I := 0 to High(Recent) do
    A('<tr><td>' + E_(Recent[I].Method) + '</td><td>' + E_(Recent[I].Path) +
      '</td><td>' + E_(Recent[I].Route) + '</td><td class="num' +
      IfThen(Recent[I].Status >= 500, ' bad', '') + '">' +
      IntToStr(Recent[I].Status) + '</td><td class="num">' + Ms(Recent[I].Us) +
      '</td></tr>');
  A('</tbody></table></div>');

  Plugins := StartedPlugins;
  A('<h2>Plugins</h2>');
  if Length(Plugins) = 0 then
    A('<p class="sub">None started.</p>')
  else
  begin
    A('<p class="sub">');
    for I := 0 to High(Plugins) do
    begin
      if I > 0 then
        A(', ');
      A(E_(Plugins[I]));
    end;
    A('</p>');
  end;

  A('</main></body></html>');
  Result := B;
end;

{ ---------------------------------------------------------------- route -- }

function DashboardGuard(Req: TRequest): TResponse;
begin
  if GOpen then
    Exit(nil);
  { Closed: the gate, or nothing -- and nothing is a 404, so a probe
    learns no more than it would from a path that was never there. }
  if GateExists(DashboardGate) and Allows(DashboardGate) then
    Exit(nil);
  Result := ErrorResponse(404);
end;

function DashboardShow(Req: TRequest): TResponse;
begin
  Result := RespondHtml(Page)
    .WithHeader('Cache-Control', 'no-store')
    .WithHeader('X-Robots-Tag', 'noindex');
end;

procedure UseDashboard(R: TRouter; Open: Boolean; Pool: TDbPool);
var
  G: TRouteGroup;
begin
  GOpen := Open;
  GPool := Pool;
  if GStarted = 0 then
    GStarted := UnixNow;
  if not GAttached then
  begin
    AttachTelemetry('askr.request', @OnRequest);
    AttachTelemetry('askr.query', @OnQuery);
    AttachTelemetry('askr.job', @OnJob);
    AttachTelemetry('askr.mail', @OnMail);
    GAttached := True;
  end;
  G := R.Group(DashboardPath);
  G.Use(@DashboardGuard);
  G.Get('/', @DashboardShow);
end;

procedure ResetDashboard;
begin
  if GAttached then
  begin
    DetachTelemetry(@OnRequest);
    DetachTelemetry(@OnQuery);
    DetachTelemetry(@OnJob);
    DetachTelemetry(@OnMail);
    GAttached := False;
  end;
  GLock.Acquire;
  try
    GRoutes := nil;
    GStatements := nil;
    GJobs := nil;
    GRecentNext := 0;
    GRecentCount := 0;
    GRequests := 0;
    GQueries := 0;
    GQueryErrors := 0;
    GMailSent := 0;
    GMailFailed := 0;
    GUncountedRoutes := 0;
    GUncountedStatements := 0;
  finally
    GLock.Release;
  end;
  GStarted := 0;
  GPool := nil;
  GOpen := False;
end;

initialization
  GLock := TCriticalSection.Create;

finalization
  GLock.Free;

end.
