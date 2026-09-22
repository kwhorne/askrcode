{ Askr.Testing — the test framework the PRD lists.

  A generic assertion library would not have been worth a unit of its own.
  What makes this worth having is the three things that are specific to
  Askr:

    * **The router is tested without a socket.** TTestClient builds a
      TRequest in memory and calls the router directly. No ports, no
      waiting, no flaky tests — and the whole path through middleware,
      routing, controller and response is covered.
    * **The database is sqlite::memory:.** The migrations run per test. No
      server to start, no cleanup to forget.
    * **The arena can be asserted about.** AssertArenaStable runs
      something a few hundred times and requires the arena to stop
      growing. That is the claim the whole project rests on, and apps
      should be testing it too — not just the framework.

  The shape is deliberately flat. A hierarchical suite with fixtures and
  inheritance is more machinery than a test needs, and it makes error
  messages harder to read. }
unit Askr.Testing;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Clock,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response, Askr.Http.Router,
  Askr.Urd.Driver, Askr.Urd.Model;

type
  ETestFailure = class(Exception);

  TTestProc = procedure;

  { Builds a request in memory and runs it through the router. }
  TTestClient = class
  private
    FRouter: TRouter;
    FArena: TArena;
    FHeaders: TStringList;
    function Run(const Method, Path, Body, ContentType: string): TResponse;
  public
    constructor Create(ARouter: TRouter);
    destructor Destroy; override;

    { Headers that go along on the next call, and only that one. }
    function WithHeader(const Name_, Value: string): TTestClient;
    { Sets X-Inertia, so the response is JSON rather than the HTML
      shell. }
    function AsInertia: TTestClient;

    { Any method at all, for the ones with no shorthand -- OPTIONS, and
      whatever an application invents. }
    function Send(const Method, Path: string; const Body: string = '';
      const ContentType: string = 'application/json'): TResponse;

    function Get(const Path: string): TResponse;
    function Post(const Path, Body: string;
      const ContentType: string = 'application/json'): TResponse;
    function Put(const Path, Body: string;
      const ContentType: string = 'application/json'): TResponse;
    function Delete(const Path: string): TResponse;

    property Arena: TArena read FArena;
  end;

{ Registrering. Gruppen er bare en overskrift i utskriften. }
procedure Group(const Name: string);
procedure Test(const Name: string; P: TTestProc);

{ Assertions. All of them raise ETestFailure, which the runner
  catches. }
procedure AssertTrue(Cond: Boolean; const What: string);
procedure AssertFalse(Cond: Boolean; const What: string);
procedure AssertEqual(const Actual, Expected, What: string); overload;
procedure AssertEqual(Actual, Expected: Int64; const What: string); overload;
procedure AssertEqual(Actual, Expected: Currency; const What: string); overload;
procedure AssertEqual(Actual, Expected: Boolean; const What: string); overload;
procedure AssertContains(const Haystack, Needle, What: string);
procedure AssertNotContains(const Haystack, Needle, What: string);
procedure AssertNotNil(Obj: TObject; const What: string);
procedure AssertNil(Obj: TObject; const What: string);
procedure AssertStatus(R: TResponse; Expected: Integer; const What: string);
procedure Fail(const What: string);

{ Askr-specific: runs P that many times, with a Reset between, and
  requires the arena to stop asking the OS for more memory. Warms up
  first, because the first rounds always grow. }
procedure AssertArenaStable(A: TArena; P: TTestProc; Iterations: Integer = 200;
  const What: string = 'arenaen flater ut');

{ Databasen for testene: sqlite::memory:, ny per kall. }
function UseTestDatabase: TDbConnection;
procedure CloseTestDatabase;

{ Runs everything registered. Returns the number of failures; 0 means
  green. }
function RunTests: Integer;
{ Runs and exits the process with the right exit code. }
procedure RunTestsAndHalt;

implementation

uses
  Askr.Urd.Sqlite;

type
  TTestEntry = record
    GroupName: string;
    Name_: string;
    Proc: TTestProc;
  end;

var
  GTests: array of TTestEntry;
  GGroup: string = '';
  GAsserts: Integer = 0;
  GFailures: Integer = 0;
  GCurrentFailed: Boolean = False;
  GTestDb: TDbConnection = nil;

procedure Group(const Name: string);
begin
  GGroup := Name;
end;

procedure Test(const Name: string; P: TTestProc);
var
  N: Integer;
begin
  if not Assigned(P) then
    raise ETestFailure.CreateFmt('Test "%s" has no procedure', [Name]);
  N := Length(GTests);
  SetLength(GTests, N + 1);
  GTests[N].GroupName := GGroup;
  GTests[N].Name_ := Name;
  GTests[N].Proc := P;
end;

procedure Fail(const What: string);
begin
  raise ETestFailure.Create(What);
end;

procedure AssertTrue(Cond: Boolean; const What: string);
begin
  Inc(GAsserts);
  if not Cond then
    raise ETestFailure.Create(What);
end;

procedure AssertFalse(Cond: Boolean; const What: string);
begin
  AssertTrue(not Cond, What);
end;

procedure AssertEqual(const Actual, Expected, What: string);
begin
  Inc(GAsserts);
  if Actual <> Expected then
    raise ETestFailure.CreateFmt('%s'#10'         expected: %s'#10 +
      '         got:      %s', [What, Expected, Actual]);
end;

procedure AssertEqual(Actual, Expected: Int64; const What: string);
begin
  Inc(GAsserts);
  if Actual <> Expected then
    raise ETestFailure.CreateFmt('%s — expected %d, got %d',
      [What, Expected, Actual]);
end;

procedure AssertEqual(Actual, Expected: Currency; const What: string);
begin
  Inc(GAsserts);
  if Actual <> Expected then
    raise ETestFailure.CreateFmt('%s — expected %s, got %s',
      [What, CurrencyToSql(Expected), CurrencyToSql(Actual)]);
end;

procedure AssertEqual(Actual, Expected: Boolean; const What: string);
begin
  Inc(GAsserts);
  if Actual <> Expected then
    raise ETestFailure.CreateFmt('%s — expected %s, got %s',
      [What, BoolToStr(Expected, 'True', 'False'),
       BoolToStr(Actual, 'True', 'False')]);
end;

procedure AssertContains(const Haystack, Needle, What: string);
begin
  Inc(GAsserts);
  if Pos(Needle, Haystack) = 0 then
    raise ETestFailure.CreateFmt('%s — did not find "%s"', [What, Needle]);
end;

procedure AssertNotContains(const Haystack, Needle, What: string);
begin
  Inc(GAsserts);
  if Pos(Needle, Haystack) > 0 then
    raise ETestFailure.CreateFmt('%s — found "%s", which should not be there',
      [What, Needle]);
end;

procedure AssertNotNil(Obj: TObject; const What: string);
begin
  AssertTrue(Obj <> nil, What + ' (var nil)');
end;

procedure AssertNil(Obj: TObject; const What: string);
begin
  AssertTrue(Obj = nil, What + ' (var ikke nil)');
end;

procedure AssertStatus(R: TResponse; Expected: Integer; const What: string);
begin
  Inc(GAsserts);
  if R = nil then
    raise ETestFailure.CreateFmt('%s — no response', [What]);
  if R.StatusCode <> Expected then
    raise ETestFailure.CreateFmt('%s — expected %d, got %d',
      [What, Expected, R.StatusCode]);
end;

procedure AssertArenaStable(A: TArena; P: TTestProc; Iterations: Integer;
  const What: string);
var
  I: Integer;
  After_: PtrUInt;
  Warmup_: Integer;
begin
  Inc(GAsserts);
  Warmup_ := Iterations div 4;
  if Warmup_ < 10 then
    Warmup_ := 10;
  for I := 1 to Warmup_ do
  begin
    A.Reset;
    P;
  end;
  After_ := A.BytesReserved;
  for I := 1 to Iterations do
  begin
    A.Reset;
    P;
  end;
  if A.BytesReserved <> After_ then
    raise ETestFailure.CreateFmt(
      '%s — the arena grew from %d to %d bytes over %d rounds',
      [What, After_, A.BytesReserved, Iterations]);
end;

function UseTestDatabase: TDbConnection;
begin
  CloseTestDatabase;
  GTestDb := OpenDbConnection('sqlite::memory:');
  UseDb(GTestDb);
  Result := GTestDb;
end;

procedure CloseTestDatabase;
begin
  if GTestDb <> nil then
  begin
    UseDb(nil);
    FreeAndNil(GTestDb);
  end;
end;

{ TTestClient }

constructor TTestClient.Create(ARouter: TRouter);
begin
  inherited Create;
  FRouter := ARouter;
  FArena := TArena.Create(64 * 1024);
  FHeaders := TStringList.Create;
end;

destructor TTestClient.Destroy;
begin
  FHeaders.Free;
  FArena.Free;
  inherited Destroy;
end;

function TTestClient.WithHeader(const Name_, Value: string): TTestClient;
begin
  FHeaders.Values[Name_] := Value;
  Result := Self;
end;

function TTestClient.AsInertia: TTestClient;
begin
  Result := WithHeader('X-Inertia', 'true');
end;

function TTestClient.Run(const Method, Path, Body, ContentType: string): TResponse;
var
  Head: string;
  I: Integer;
  Req: TRequest;
  Prev: TArena;
  PrevReq: TRequest;
begin
  FArena.Reset;

  Head := Format('%s %s HTTP/1.1'#13#10'Host: test', [Method, Path]);
  if Body <> '' then
    Head := Head + #13#10'Content-Type: ' + ContentType +
      #13#10'Content-Length: ' + IntToStr(Length(Body));
  for I := 0 to FHeaders.Count - 1 do
    Head := Head + #13#10 + FHeaders.Names[I] + ': ' +
      FHeaders.ValueFromIndex[I];

  Prev := UseArena(FArena);
  try
    Req := TRequest.Create;
    if Req.ParseHead(StrDup(FArena, Head), DefaultMaxBodyBytes) <> psOk then
      raise ETestFailure.CreateFmt('The test client built an invalid request: %s',
        [Head]);
    if Body <> '' then
      Req.SetBody(StrDup(FArena, Body));

    { The request is made ambient, as the host does, so Inertia and
      similar helpers find it. }
    PrevReq := UseRequest(Req);
    try
      Result := FRouter.Handle(Req);
    finally
      UseRequest(PrevReq);
    end;
  finally
    UseArena(Prev);
  end;

  { Headerne gjelder ett kall. }
  FHeaders.Clear;
end;

function TTestClient.Send(const Method, Path, Body,
  ContentType: string): TResponse;
begin
  Result := Run(Method, Path, Body, ContentType);
end;

function TTestClient.Get(const Path: string): TResponse;
begin
  Result := Run('GET', Path, '', '');
end;

function TTestClient.Post(const Path, Body, ContentType: string): TResponse;
begin
  Result := Run('POST', Path, Body, ContentType);
end;

function TTestClient.Put(const Path, Body, ContentType: string): TResponse;
begin
  Result := Run('PUT', Path, Body, ContentType);
end;

function TTestClient.Delete(const Path: string): TResponse;
begin
  Result := Run('DELETE', Path, '', '');
end;

{ The runner }

function RunTests: Integer;
var
  I: Integer;
  Previous: string;
  T0: Int64;
  Ran: Integer;
begin
  GFailures := 0;
  GAsserts := 0;
  Ran := 0;
  Previous := #0;
  T0 := MonotonicMs;

  for I := 0 to High(GTests) do
  begin
    if GTests[I].GroupName <> Previous then
    begin
      WriteLn;
      WriteLn('  ', GTests[I].GroupName);
      Previous := GTests[I].GroupName;
    end;

    GCurrentFailed := False;
    try
      GTests[I].Proc;
    except
      on E: ETestFailure do
      begin
        GCurrentFailed := True;
        Inc(GFailures);
        WriteLn('    FAIL ', GTests[I].Name_);
        WriteLn('         ', E.Message);
      end;
      on E: Exception do
      begin
        GCurrentFailed := True;
        Inc(GFailures);
        WriteLn('    FAIL ', GTests[I].Name_);
        WriteLn('         unexpected ', E.ClassName, ': ', E.Message);
      end;
    end;
    if not GCurrentFailed then
      WriteLn('    ok   ', GTests[I].Name_);
    Inc(Ran);
  end;

  CloseTestDatabase;

  WriteLn;
  WriteLn(Format('%d tests, %d assertions, %d failures  (%d ms)',
    [Ran, GAsserts, GFailures, MonotonicMs - T0]));
  Result := GFailures;
end;

procedure RunTestsAndHalt;
begin
  if RunTests > 0 then
    Halt(1);
  Halt(0);
end;

end.
