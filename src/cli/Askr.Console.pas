{ Askr.Console — the commands the app answers itself.

  `askr migrate` cannot be run by the tool. The migrations are Pascal code
  compiled into the app binary, and the same goes for the routes, the jobs,
  the schedule and the models. The tool does not know what is in them; the
  only thing it can do is ask the binary to do it.

  So: `askr <something>` runs `app --something`, and this unit is what
  receives the flag at the other end.

  **The commands live here, not in the generated app.lpr.** A project made
  last year is to get new commands by rebuilding, not by scaffolding again.
  All an app.lpr needs is one line:

      if RunConsole then Exit;

  It returns True when it handled something, and then the app is to exit
  instead of starting the server. Before this the generated app.lpr read
  `ParamStr(1)` as a port number, and `askr migrate` started the web server
  on port 8080 instead of migrating. That was not a small bug — it made the
  whole migration tool unreachable from a fresh project.

  ## What deliberately does not exist

  Laravel has `optimize`, `config:cache`, `route:cache`, `view:cache` and
  `clear-compiled`. They exist because PHP interprets the source again on
  every request, and the cache is what saves that. In Askr the binary **is**
  the cache. The commands would have been ceremony without effect.

  `vendor:publish`, `package:discover` and `install:*` belong to Composer.
  `tinker` requires an interpreter for Pascal expressions and is deferred on
  purpose. }
unit Askr.Console;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, TypInfo,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Clock, Askr.Core.Env,
  Askr.Core.Config, Askr.Core.Log, Askr.Core.Crypto,
  Askr.Urd.Driver, Askr.Norn.Schema, Askr.Norn.Migration,
  Askr.Norn.Introspect, Askr.Norn.Codegen,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response, Askr.Http.Router,
  Askr.Queue, Askr.Scheduler, Askr.Cache;

type
  { A seeder is a class that fills the database. The same shape as a
    migration: register it, and the tool finds it. }
  TSeeder = class
  public
    class function Name: string; virtual;
    procedure Run(Conn: TDbConnection); virtual; abstract;
  end;
  TSeederClass = class of TSeeder;

procedure RegisterSeeder(S: TSeederClass);
function RegisteredSeeders: TList;

{ The app says where the database is. Without it none of the db commands
  can do anything, and then they say so instead of failing halfway. }
procedure SetConsoleDsn(const Dsn: string);
{ The router, the queue, the schedule and the cache are set by the app
  when it has them. Whatever is not set, the command says so. }
procedure SetConsoleRouter(R: TRouter);

{ Runs the command in ParamStr(1) if there is one. True means "handled,
  do not start the server". The exit code is set with Halt inside the
  command when something went wrong. }
function RunConsole: Boolean;

{ Maintenance mode. `askr down` writes a file; this middleware is what
  makes the file mean anything.

  A file and not a flag in memory, because `askr down` is a different
  process from the server — and because the mode has to survive a restart.
  Static files are registered before this one if they are to be served
  regardless. }
procedure UseMaintenance(R: TRouter);
function InMaintenance: Boolean;

{ All_ kommandoene, til `askr list`. }
function ConsoleCommands: TStringArray;

implementation

var
  GSeeders: TList = nil;
  GDsn: string = '';
  GRouter: TRouter = nil;

{ ------------------------------------------------------------ seedere -- }

class function TSeeder.Name: string;
begin
  Result := ClassName;
end;

procedure RegisterSeeder(S: TSeederClass);
begin
  if GSeeders = nil then
    GSeeders := TList.Create;
  GSeeders.Add(Pointer(S));
end;

function RegisteredSeeders: TList;
begin
  if GSeeders = nil then
    GSeeders := TList.Create;
  Result := GSeeders;
end;

procedure SetConsoleDsn(const Dsn: string);
begin
  GDsn := Dsn;
end;

procedure SetConsoleRouter(R: TRouter);
begin
  GRouter := R;
end;

{ ----------------------------------------------------------- hjelpere -- }

procedure Si(const S: string); forward;
procedure Err(const S: string); forward;

{ Yes/no in a status printout. Written out because IfThen without StrUtils
  or Math in uses hits a generic declaration and gives "Generics without
  specialization" — an error message that does not say what is wrong. }
function BoolAnswer(B: Boolean; const Ja, Nei: string): string;
begin
  if B then
    Result := Ja
  else
    Result := Nei;
end;

{ The surrounding queue, schedule and cache raise when they are not set,
  and their messages say what is missing. The commands here catch them
  rather than letting a stack trace stand as the answer to "askr
  queue:status". }
function HasQueue: Boolean;
begin
  Result := True;
  try
    Queue;
  except
    on E: Exception do
    begin
      Err(E.Message);
      Result := False;
    end;
  end;
end;

function HasSchedule: Boolean;
begin
  Result := True;
  try
    Schedule;
  except
    on E: Exception do
    begin
      Err(E.Message);
      Result := False;
    end;
  end;
end;

function HasCache: Boolean;
begin
  Result := True;
  try
    Cache;
  except
    on E: Exception do
    begin
      Err(E.Message);
      Result := False;
    end;
  end;
end;

procedure Si(const S: string);
begin
  WriteLn(S);
  Flush(Output);
end;

procedure Err(const S: string);
begin
  WriteLn(ErrOutput, S);
  Flush(ErrOutput);
end;

{ A flag of the form --step=3 or --step 3. }
function FlagValue(const Name_: string; Standard: Integer): Integer;
var
  I: Integer;
  P: string;
begin
  Result := Standard;
  for I := 1 to ParamCount do
  begin
    P := ParamStr(I);
    if Copy(P, 1, Length(Name_) + 3) = '--' + Name_ + '=' then
      Exit(StrToIntDef(Copy(P, Length(Name_) + 4, MaxInt), Standard));
    if (P = '--' + Name_) and (I < ParamCount) then
      Exit(StrToIntDef(ParamStr(I + 1), Standard));
  end;
end;

function HasFlag(const Name_: string): Boolean;
var
  I: Integer;
begin
  for I := 1 to ParamCount do
    if ParamStr(I) = '--' + Name_ then
      Exit(True);
  Result := False;
end;

function Arg(Index: Integer): string;
var
  I, N: Integer;
begin
  { The first argument that is not a flag, after the command itself. }
  N := 0;
  for I := 2 to ParamCount do
    if Copy(ParamStr(I), 1, 2) <> '--' then
    begin
      Inc(N);
      if N = Index then
        Exit(ParamStr(I));
    end;
  Result := '';
end;

function OpenDb: TDbConnection;
begin
  if GDsn = '' then
  begin
    Err('No database is configured. Call SetConsoleDsn in app.lpr, or ' +
      'set DATABASE_URL.');
    Halt(1);
  end;
  try
    Result := OpenDbConnection(GDsn);
  except
    on E: Exception do
    begin
      { The DSN may have a password in it and is never printed. The schema
        alone says enough to find the problem. }
      Err(Format('Could not connect to the %s database: %s',
        [DsnScheme(GDsn), E.Message]));
      Halt(1);
      Result := nil;
    end;
  end;
end;

procedure LogLine(const Line: string);
begin
  Si('  ' + Line);
end;

{ ------------------------------------------------------- migrasjoner -- }

procedure CmdMigrate(Steps: Integer);
var
  C: TDbConnection;
  M: TMigrator;
  N: Integer;
begin
  C := OpenDb;
  M := TMigrator.Create(C);
  try
    M.OnLog := LogLine;
    N := M.Up(Steps);
    if N = 0 then
      Si('Nothing to migrate.')
    else
      Si(Format('%d migration(s) applied.', [N]));
  finally
    M.Free;
    C.Free;
  end;
end;

procedure CmdMigrateStatus;
var
  C: TDbConnection;
  M: TMigrator;
  Info: TMigrationInfoArray;
  I: Integer;
  Mark: string;
begin
  C := OpenDb;
  M := TMigrator.Create(C);
  try
    Info := M.Status;
    if Length(Info) = 0 then
    begin
      Si('No migrations are registered.');
      Exit;
    end;
    Si(Format('%-18s %-10s %s', ['Version', 'State', 'Title']));
    for I := 0 to High(Info) do
    begin
      if Info[I].Applied and Info[I].Registered then
        Mark := 'applied'
      else if Info[I].Applied then
        { Run, but the file is gone. That is a state you want to know
          about. }
        Mark := 'MISSING'
      else
        Mark := 'pending';
      Si(Format('%-18s %-10s %s',
        [Info[I].Version, Mark, Info[I].Title]));
    end;
    Si('');
    Si(Format('%d pending.', [M.PendingCount]));
  finally
    M.Free;
    C.Free;
  end;
end;

procedure CmdRollback(Steps: Integer);
var
  C: TDbConnection;
  M: TMigrator;
  N: Integer;
begin
  C := OpenDb;
  M := TMigrator.Create(C);
  try
    M.OnLog := LogLine;
    N := M.Down(Steps);
    if N = 0 then
      Si('Nothing to roll back.')
    else
      Si(Format('%d migration(s) rolled back.', [N]));
  finally
    M.Free;
    C.Free;
  end;
end;

{ Drops every table in the schema, not only the ones Norn knows about. A
  migrate:fresh that left something standing would have given a database
  that looks empty and is not. }
function DropAllTables(C: TDbConnection; A: TArena): Integer;
var
  S: TDbSchema;
  I: Integer;
  B: TStrBuilder;
begin
  Result := 0;
  S := IntrospectSchema(C);
  try
    for I := 0 to S.TableCount - 1 do
    begin
      B.Init(A, 128);
      B.Append('DROP TABLE IF EXISTS ');
      C.AppendIdentStr(B, S.TableAt(I).Name);
      { CASCADE in Postgres; MySQL and SQLite sort the order out themselves
        when foreign keys are switched off, but dropping in reverse order
        is unreliable. }
      if C.Dialect = sdPostgres then
        B.Append(' CASCADE');
      try
        C.Exec(A, B.ToString);
        Inc(Result);
      except
        on EDbError do
          { A table that could not be dropped because another one points at
            it is taken in the next round. }
          ;
      end;
    end;
    { A second round for what was tied up. }
    for I := 0 to S.TableCount - 1 do
    begin
      B.Init(A, 128);
      B.Append('DROP TABLE IF EXISTS ');
      C.AppendIdentStr(B, S.TableAt(I).Name);
      if C.Dialect = sdPostgres then
        B.Append(' CASCADE');
      try
        C.Exec(A, B.ToString);
      except
        on EDbError do ;
      end;
    end;
  finally
    S.Free;
  end;
end;

procedure CmdDbWipe(Quiet: Boolean);
var
  C: TDbConnection;
  A: TArena;
  N: Integer;
begin
  if IsProduction and not HasFlag('force') then
  begin
    { The one command that deletes everything must not be runnable in
      production by accident. }
    Err('Refusing to wipe the database with APP_ENV=production. ' +
      'Pass --force if that is really what you want.');
    Halt(1);
  end;
  C := OpenDb;
  A := TArena.Create(64 * 1024);
  try
    if C.Dialect = sdMySql then
      C.Exec(A, 'SET FOREIGN_KEY_CHECKS = 0');
    if C.Dialect = sdSqlite then
      C.Exec(A, 'PRAGMA foreign_keys = OFF');
    N := DropAllTables(C, A);
    if C.Dialect = sdMySql then
      C.Exec(A, 'SET FOREIGN_KEY_CHECKS = 1');
    if C.Dialect = sdSqlite then
      C.Exec(A, 'PRAGMA foreign_keys = ON');
    if not Quiet then
      Si(Format('Dropped %d table(s).', [N]));
  finally
    A.Free;
    C.Free;
  end;
end;

procedure CmdMigrateFresh(WithSeed: Boolean); forward;
procedure CmdSeed(const Only: string); forward;

procedure CmdMigrateFresh(WithSeed: Boolean);
begin
  CmdDbWipe(True);
  Si('Dropped all tables.');
  CmdMigrate(0);
  if WithSeed then
    CmdSeed('');
end;

procedure CmdMigrateReset;
begin
  { All of them, not only the last ones. 0 to Down means nothing, so the
    number has to be large enough to cover everything that has been
    run. }
  CmdRollback(MaxInt);
end;

procedure CmdMigrateRefresh(WithSeed: Boolean);
begin
  CmdMigrateReset;
  CmdMigrate(0);
  if WithSeed then
    CmdSeed('');
end;

{ ------------------------------------------------------------ seeding -- }

procedure CmdSeed(const Only: string);
var
  C: TDbConnection;
  L: TList;
  I, N: Integer;
  S: TSeeder;
  Cls: TSeederClass;
begin
  L := RegisteredSeeders;
  if L.Count = 0 then
  begin
    Si('No seeders are registered. Create one with: askr make seeder <Name>');
    Exit;
  end;
  C := OpenDb;
  N := 0;
  try
    for I := 0 to L.Count - 1 do
    begin
      Cls := TSeederClass(L[I]);
      if (Only <> '') and not SameText(Cls.Name, Only) then
        Continue;
      Si('  seed  ' + Cls.Name);
      S := Cls.Create;
      try
        S.Run(C);
        Inc(N);
      finally
        S.Free;
      end;
    end;
  finally
    C.Free;
  end;
  if (Only <> '') and (N = 0) then
  begin
    Err('No seeder named "' + Only + '".');
    Halt(1);
  end;
  Si(Format('%d seeder(s) ran.', [N]));
end;

{ ---------------------------------------------------------- databasen -- }

procedure CmdDbShow;
var
  C: TDbConnection;
  A: TArena;
  S: TDbSchema;
  I: Integer;
  T: TDbTable;
begin
  C := OpenDb;
  A := TArena.Create(128 * 1024);
  try
    { The schema, not the DSN: it may have a password in it. }
    Si('Driver     ' + DsnScheme(GDsn));
    Si('Dialect    ' + GetEnumName(TypeInfo(TSqlDialect), Ord(C.Dialect)));
    Si('');
    S := IntrospectSchema(C);
    try
      Si(Format('%-28s %8s %8s', ['Table', 'Columns', 'Indexes']));
      for I := 0 to S.TableCount - 1 do
      begin
        T := S.TableAt(I);
        Si(Format('%-28s %8d %8d',
          [T.Name, T.ColumnCount, T.IndexCount]));
      end;
      Si('');
      Si(Format('%d table(s).', [S.TableCount]));
    finally
      S.Free;
    end;
  finally
    A.Free;
    C.Free;
  end;
end;

procedure CmdDbTable(const Name_: string);
var
  C: TDbConnection;
  S: TDbSchema;
  T: TDbTable;
  I: Integer;
  Col: TDbColumn;
  Fk: TDbForeignKey;
  Mark: string;
begin
  if Name_ = '' then
  begin
    Err('Usage: askr db:table <name>');
    Halt(1);
  end;
  C := OpenDb;
  try
    S := IntrospectSchema(C);
    try
      T := S.Table(Name_);
      if T = nil then
      begin
        Err('No table named "' + Name_ + '".');
        Halt(1);
      end;
      Si('Table  ' + T.Name);
      Si('');
      Si(Format('%-24s %-20s %-8s %s',
        ['Column', 'Type', 'Null', 'Pascal']));
      for I := 0 to T.ColumnCount - 1 do
      begin
        Col := T.Column(I);
        Mark := '';
        if Col.Nullable then
          Mark := 'yes'
        else
          Mark := 'no';
        if Col.Name = T.PrimaryKey then
          Mark := Mark + '  (pk)';
        Si(Format('%-24s %-20s %-8s %s',
          [Col.Name, Col.SqlType, Mark,
           PascalTypeFor(Col.SqlType, Col.Scale)]));
      end;
      if T.IndexCount > 0 then
      begin
        Si('');
        Si('Indexes');
        for I := 0 to T.IndexCount - 1 do
          if T.IndexAt(I).IsUnique then
            Si('  ' + T.IndexAt(I).Name + '  (unique)')
          else
            Si('  ' + T.IndexAt(I).Name);
      end;
      if T.ForeignKeyCount > 0 then
      begin
        Si('');
        Si('Foreign keys');
        for I := 0 to T.ForeignKeyCount - 1 do
        begin
          Fk := T.ForeignKey(I);
          Si(Format('  %s -> %s.%s',
            [Fk.Column, Fk.RefTable, Fk.RefColumn]));
        end;
      end;
    finally
      S.Free;
    end;
  finally
    C.Free;
  end;
end;

procedure CmdSchema;
var
  C: TDbConnection;
  S: TDbSchema;
  Opts: TCodegenOptions;
  Filer: TGeneratedFiles;
  Changed: TStringArray;
  I: Integer;
begin
  C := OpenDb;
  try
    S := IntrospectSchema(C);
    try
      Opts := DefaultCodegenOptions;
      Opts.OutputDir := Cfg('schema.dir', 'app/Schema');
      Filer := GenerateSources(S, Opts);
      Changed := WriteSources(Filer, Opts);
      for I := 0 to High(Filer) do
        Si('  ' + Opts.OutputDir + '/' + Filer[I].FileName);
      Si('');
      { WriteSources leaves unchanged files alone, so that timestamps and
        incremental compilation are not disturbed — and gives back only the
        names of the ones that were actually written. }
      Si(Format('%d file(s), %d changed.', [Length(Filer), Length(Changed)]));
    finally
      S.Free;
    end;
  finally
    C.Free;
  end;
end;

{ ------------------------------------------------------------- queue -- }

procedure RequiresQueue;
begin
  if not HasQueue then
    Halt(1);
end;

procedure CmdQueueWork;
var
  Before: QWord;
begin
  RequiresQueue;
  Si(Format('Queue worker started (%d workers, %s).',
    [Queue.Workers, BoolAnswer(Queue.Durable, 'durable', 'in-process')]));
  Queue.Start;
  Before := 0;
  { Runs until somebody interrupts. A separate process for the queue is
    not necessary in Askr — the app can do both — but it exists for whoever
    wants to keep them apart. }
  while True do
  begin
    Sleep(1000);
    if Queue.Processed <> Before then
    begin
      Before := Queue.Processed;
      LogInfo('queue', ['processed', Int64(Queue.Processed),
        'failed', Int64(Queue.Failed), 'pending', Queue.Pending]);
    end;
  end;
end;

procedure CmdQueueStatus;
begin
  RequiresQueue;
  Si(Format('Pending    %d', [Queue.Pending]));
  Si(Format('Processed  %d', [Queue.Processed]));
  Si(Format('Retried    %d', [Queue.Retried]));
  Si(Format('Failed     %d', [Queue.Failed]));
  Si(Format('Dropped    %d', [Queue.Dropped]));
  Si(Format('Durable    %s', [BoolAnswer(Queue.Durable, 'yes', 'no')]));
end;

{ -------------------------------------------------------- scheduler -- }

procedure CmdScheduleList;
var
  L: TStringList;
  I: Integer;
begin
  if not HasSchedule then
    Halt(1);
  L := TStringList.Create;
  try
    Schedule.Describe(L);
    if L.Count = 0 then
      Si('The schedule is empty.')
    else
      for I := 0 to L.Count - 1 do
        Si('  ' + L[I]);
  finally
    L.Free;
  end;
end;

procedure CmdScheduleRun;
var
  N: Integer;
begin
  if not HasSchedule then
    Halt(1);
  RequiresQueue;
  { One tick. The scheduler pushes to the queue and never runs anything
    itself, so the jobs run off the queue afterwards. }
  N := Schedule.Tick;
  Queue.Start;
  Queue.WaitUntilEmpty(60000);
  Si(Format('%d job(s) dispatched.', [N]));
end;

{ ------------------------------------------------------------- cache -- }

procedure CmdCacheClear;
begin
  if not HasCache then
    Halt(1);
  Cache.Flush;
  Si('Cache cleared.');
end;

{ ----------------------------------------------------- vedlikehold -- }

function MaintenanceFile: string;
begin
  Result := '.askr-down';
end;

function InMaintenance: Boolean;
begin
  Result := FileExists(MaintenanceFile);
end;

type
  TMaintenance = class
    class function Check(Req: TRequest): TResponse;
  end;

class function TMaintenance.Check(Req: TRequest): TResponse;
begin
  if not InMaintenance then
    Exit(nil);
  { 503 with Retry-After, not 200 with a message: a search engine and a
    load balancer are both to understand that this is temporary. }
  Result := RespondText('Service Unavailable', 503)
    .WithHeader('Retry-After', '60');
end;

procedure UseMaintenance(R: TRouter);
begin
  R.Use(TMaintenance.Check);
end;

procedure CmdDown;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Add(IsoTimestampNow);
    L.SaveToFile(MaintenanceFile);
  finally
    L.Free;
  end;
  { A file, not a flag in memory: it is to apply to any process that starts
    afterwards, and it is to survive a restart. }
  Si('The application is now in maintenance mode.');
end;

procedure CmdUp;
begin
  if FileExists(MaintenanceFile) then
    DeleteFile(MaintenanceFile);
  Si('The application is live.');
end;

{ --------------------------------------------------------------- om -- }

procedure CmdAbout;
begin
  Si('Application');
  Si('  Environment   ' + AppEnv);
  Si('  Debug         ' + BoolAnswer(not IsProduction, 'yes', 'no'));
  Si('  Maintenance   ' + BoolAnswer(FileExists(MaintenanceFile), 'ON', 'off'));
  Si('  Log level     ' + LogLevelName(LogLevel));
  if ConfigFile <> '' then
    Si('  askr.toml     ' + ConfigFile);
  if EnvFile <> '' then
    Si('  .env          ' + EnvFile);
  Si('  App key       ' + BoolAnswer(HasAppKey, 'set', 'MISSING'));
  Si('');
  Si('Database');
  if GDsn = '' then
    Si('  Driver        not configured')
  else
    Si('  Driver        ' + DsnScheme(GDsn));
  Si('');
  Si('Runtime');
  if GRouter <> nil then
    Si(Format('  Routes        %d', [GRouter.Count]))
  else
    Si('  Routes        not registered');
  try
    Si(Format('  Queue         %d workers, %s',
      [Queue.Workers, BoolAnswer(Queue.Durable, 'durable', 'in-process')]));
  except
    on Exception do Si('  Queue         not configured');
  end;
  try
    Si(Format('  Schedule      %d entries', [Schedule.Count]));
  except
    on Exception do Si('  Schedule      not configured');
  end;
  try
    Cache.Has('x');
    Si('  Cache         in-process');
  except
    on Exception do Si('  Cache         not configured');
  end;
end;

procedure CmdRoutes;
var
  L: TStringList;
  I: Integer;
begin
  if GRouter = nil then
  begin
    Err('No router is registered. Call SetConsoleRouter in app.lpr.');
    Halt(1);
  end;
  L := TStringList.Create;
  try
    GRouter.Describe(L);
    for I := 0 to L.Count - 1 do
      Si(L[I]);
    Si('');
    Si(Format('%d route(s).', [GRouter.Count]));
  finally
    L.Free;
  end;
end;

{ ------------------------------------------------------------- tabell -- }

type
  TCommand = record
    Name_: string;
    Help: string;
  end;

const
  Commands: array[0..21] of TCommand = (
    (Name_: 'about';            Help: 'what this app is configured with'),
    (Name_: 'routes';           Help: 'the routing table'),
    (Name_: 'migrate';          Help: 'run pending migrations'),
    (Name_: 'migrate:status';   Help: 'what has run and what has not'),
    (Name_: 'migrate:rollback'; Help: 'roll back the last batch (--step=N)'),
    (Name_: 'migrate:reset';    Help: 'roll back everything'),
    (Name_: 'migrate:fresh';    Help: 'drop all tables, then migrate (--seed)'),
    (Name_: 'migrate:refresh';  Help: 'reset, then migrate (--seed)'),
    (Name_: 'db:seed';          Help: 'run the seeders (--class=Name)'),
    (Name_: 'db:show';          Help: 'tables in the database'),
    (Name_: 'db:table';         Help: 'columns, indexes and keys of one table'),
    (Name_: 'db:wipe';          Help: 'drop every table (--force in production)'),
    (Name_: 'schema';           Help: 'generate typed columns from the database'),
    (Name_: 'queue:work';       Help: 'run the queue until interrupted'),
    (Name_: 'queue:status';     Help: 'counters for the queue'),
    (Name_: 'schedule:list';    Help: 'the schedule'),
    (Name_: 'schedule:run';     Help: 'dispatch what is due, once'),
    (Name_: 'cache:clear';      Help: 'empty the cache'),
    (Name_: 'down';             Help: 'maintenance mode on'),
    (Name_: 'up';               Help: 'maintenance mode off'),
    (Name_: 'env';              Help: 'the current environment'),
    (Name_: 'list';             Help: 'these commands'));

function ConsoleCommands: TStringArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Commands));
  for I := Low(Commands) to High(Commands) do
    Result[I] := Commands[I].Name_;
end;

procedure CmdList;
var
  I: Integer;
begin
  Si('Commands this app answers to:');
  Si('');
  for I := Low(Commands) to High(Commands) do
    Si(Format('  %-18s %s', [Commands[I].Name_, Commands[I].Help]));
end;

function RunConsole: Boolean;
var
  K: string;
begin
  Result := False;
  if ParamCount < 1 then
    Exit;
  K := ParamStr(1);
  { The commands arrive as --name from the tool. Without the prefix it is
    the port number, as it always has been. }
  if Copy(K, 1, 2) <> '--' then
    Exit;
  System.Delete(K, 1, 2);
  Result := True;

  if K = 'about' then CmdAbout
  else if K = 'routes' then CmdRoutes
  else if K = 'migrate' then CmdMigrate(FlagValue('step', 0))
  else if K = 'migrate:status' then CmdMigrateStatus
  else if K = 'migrate:rollback' then CmdRollback(FlagValue('step', 1))
  else if K = 'migrate:reset' then CmdMigrateReset
  else if K = 'migrate:fresh' then CmdMigrateFresh(HasFlag('seed'))
  else if K = 'migrate:refresh' then CmdMigrateRefresh(HasFlag('seed'))
  else if K = 'db:seed' then CmdSeed(Arg(1))
  else if K = 'db:show' then CmdDbShow
  else if K = 'db:table' then CmdDbTable(Arg(1))
  else if K = 'db:wipe' then CmdDbWipe(False)
  else if K = 'schema' then CmdSchema
  else if K = 'queue:work' then CmdQueueWork
  else if K = 'queue:status' then CmdQueueStatus
  else if K = 'schedule:list' then CmdScheduleList
  else if K = 'schedule:run' then CmdScheduleRun
  else if K = 'cache:clear' then CmdCacheClear
  else if K = 'down' then CmdDown
  else if K = 'up' then CmdUp
  else if K = 'env' then Si(AppEnv)
  else if K = 'list' then CmdList
  else
  begin
    Err('Unknown command: ' + K);
    Err('Try: askr list');
    Halt(1);
  end;
end;

end.
