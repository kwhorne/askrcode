{ Askr.Console — kommandoene appen svarer på selv.

  `askr migrate` kan ikke kjøres av verktøyet. Migrasjonene er Pascal-kode
  som er kompilert inn i appbinæren, og det samme gjelder rutene, jobbene,
  planen og modellene. Verktøyet vet ikke hva som står der; det eneste det
  kan gjøre er å be binæren om å gjøre det.

  Derfor: `askr <noe>` kjører `app --noe`, og denne uniten er det som tar
  imot flagget i den andre enden.

  **Kommandoene ligger her, ikke i den genererte app.lpr.** Et prosjekt
  laget i fjor skal få nye kommandoer ved å bygge på nytt, ikke ved å
  scaffolde om. Alt en app.lpr trenger er én linje:

      if RunConsole then Exit;

  Den returnerer True når den håndterte noe, og da skal appen avslutte i
  stedet for å starte serveren. Før dette leste den genererte app.lpr
  `ParamStr(1)` som portnummer, og `askr migrate` startet webserveren på
  port 8080 i stedet for å migrere. Det var ikke en liten feil — det gjorde
  hele migrasjonsverktøyet utilgjengelig fra et ferskt prosjekt.

  ## What som med vilje ikke finnes

  Laravel har `optimize`, `config:cache`, `route:cache`, `view:cache` og
  `clear-compiled`. De finnes fordi PHP tolker kildekoden på nytt ved hver
  request, og cachen er det som sparer det. I Askr **er** binæren cachen.
  Kommandoene ville vært seremoni uten virkning.

  `vendor:publish`, `package:discover` og `install:*` hører til Composer.
  `tinker` krever en tolk for Pascal-uttrykk og er utsatt med vilje. }
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
  { En seeder er en klasse som fyller databasen. Samme form som en
    migrasjon: registrer den, og verktøyet finner den. }
  TSeeder = class
  public
    class function Name: string; virtual;
    procedure Run(Conn: TDbConnection); virtual; abstract;
  end;
  TSeederClass = class of TSeeder;

procedure RegisterSeeder(S: TSeederClass);
function RegisteredSeeders: TList;

{ Appen sier hvor databasen er. Without den kan ingen av db-kommandoene
  gjøre noe, og da sier de fra i stedet for å feile halvveis. }
procedure SetConsoleDsn(const Dsn: string);
{ Ruteren, køen, planen og cachen settes av appen når den har dem. Det som
  ikke er satt, sier kommandoen fra om. }
procedure SetConsoleRouter(R: TRouter);

{ Kjører kommandoen i ParamStr(1) hvis det er en. True betyr «håndtert,
  ikke start serveren». Exit-koden settes med Halt inne i kommandoen når
  noe gikk galt. }
function RunConsole: Boolean;

{ Vedlikeholdsmodus. `askr down` skriver en fil; denne middlewaren er det
  som gjør at fila betyr noe.

  Fila og ikke et flagg i minnet, fordi `askr down` er en annen prosess enn
  serveren — og fordi modusen skal overleve en omstart. Statiske filer
  registreres før denne hvis de skal serveres uansett. }
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

{ Ja/nei i en statusutskrift. Skrevet ut fordi IfThen uten StrUtils eller
  Math i uses treffer en generisk deklarasjon og gir «Generics without
  specialization» — en feilmelding som ikke sier hva som er galt. }
function BoolAnswer(B: Boolean; const Ja, Nei: string): string;
begin
  if B then
    Result := Ja
  else
    Result := Nei;
end;

{ De omgivende køen, planen og cachen kaster når de ikke er satt, og
  meldingene deres sier hva som mangler. Kommandoene her fanger dem i
  stedet for å la et stakkspor stå som svar på «askr queue:status». }
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

{ Et flagg på formen --step=3 eller --step 3. }
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
  { Første argument som ikke er et flagg, etter kommandoen selv. }
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
      { DSN-en kan ha passord i seg og skrives aldri ut. Skjemaet alene
        sier nok til å finne feilen. }
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
        { Kjørt, men fila er borte. Det er en tilstand man vil vite om. }
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

{ Sletter alle tabeller i skjemaet, ikke bare de Norn kjenner. En
  migrate:fresh som lot noe stå ville gitt en database som ser tom ut og
  ikke er det. }
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
      { CASCADE i Postgres; MySQL og SQLite ordner rekkefølgen selv når
        fremmednøkler slås av, men å droppe i omvendt rekkefølge er
        upålitelig. }
      if C.Dialect = sdPostgres then
        B.Append(' CASCADE');
      try
        C.Exec(A, B.ToString);
        Inc(Result);
      except
        on EDbError do
          { En tabell som ikke lot seg droppe fordi en annen peker på den
            tas i neste runde. }
          ;
      end;
    end;
    { Andre runde for det som var bundet. }
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

procedure CmdDbWipe(Stille: Boolean);
var
  C: TDbConnection;
  A: TArena;
  N: Integer;
begin
  if IsProduction and not HasFlag('force') then
  begin
    { Den ene kommandoen som sletter alt skal ikke kunne kjøres i
      produksjon ved et uhell. }
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
    if not Stille then
      Si(Format('Dropped %d table(s).', [N]));
  finally
    A.Free;
    C.Free;
  end;
end;

procedure CmdMigrateFresh(WithSeed: Boolean); forward;
procedure CmdSeed(const Bare: string); forward;

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
  { All_, ikke bare de siste. 0 til Down betyr ingenting, så tallet må
    være stort nok til å dekke alt som er kjørt. }
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

procedure CmdSeed(const Bare: string);
var
  C: TDbConnection;
  L: TList;
  I, N: Integer;
  S: TSeeder;
  Kl: TSeederClass;
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
      Kl := TSeederClass(L[I]);
      if (Bare <> '') and not SameText(Kl.Name, Bare) then
        Continue;
      Si('  seed  ' + Kl.Name);
      S := Kl.Create;
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
  if (Bare <> '') and (N = 0) then
  begin
    Err('No seeder named "' + Bare + '".');
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
    { Skjemaet, ikke DSN-en: den kan ha passord i seg. }
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
  Endret: TStringArray;
  I: Integer;
begin
  C := OpenDb;
  try
    S := IntrospectSchema(C);
    try
      Opts := DefaultCodegenOptions;
      Opts.OutputDir := Cfg('schema.dir', 'app/Schema');
      Filer := GenerateSources(S, Opts);
      Endret := WriteSources(Filer, Opts);
      for I := 0 to High(Filer) do
        Si('  ' + Opts.OutputDir + '/' + Filer[I].FileName);
      Si('');
      { WriteSources rører ikke filer som er uendret, slik at tidsstempler
        og inkrementell kompilering ikke forstyrres — og gir tilbake bare
        navnene på dem som faktisk ble skrevet. }
      Si(Format('%d file(s), %d changed.', [Length(Filer), Length(Endret)]));
    finally
      S.Free;
    end;
  finally
    C.Free;
  end;
end;

{ ---------------------------------------------------------------- kø -- }

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
  { Kjører til noen avbryter. En egen prosess for køen er ikke nødvendig
    i Askr — appen kan gjøre begge deler — men den finnes for den som vil
    skille dem. }
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
  { Ett tikk. Scheduleren dytter til køen og utfører aldri noe selv, så
    jobbene kjører av køen etterpå. }
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

function VedlikeholdsFil: string;
begin
  Result := '.askr-down';
end;

function InMaintenance: Boolean;
begin
  Result := FileExists(VedlikeholdsFil);
end;

type
  TVedlikehold = class
    class function Check(Req: TRequest): TResponse;
  end;

class function TVedlikehold.Check(Req: TRequest): TResponse;
begin
  if not InMaintenance then
    Exit(nil);
  { 503 med Retry-After, ikke 200 med en beskjed: en søkemotor og en
    lastbalanserer skal begge forstå at dette er midlertidig. }
  Result := RespondText('Service Unavailable', 503)
    .WithHeader('Retry-After', '60');
end;

procedure UseMaintenance(R: TRouter);
begin
  R.Use(TVedlikehold.Check);
end;

procedure CmdDown;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Add(IsoTimestampNow);
    L.SaveToFile(VedlikeholdsFil);
  finally
    L.Free;
  end;
  { En fil, ikke en flagg i minnet: den skal gjelde for enhver prosess som
    starter etterpå, og den skal overleve en omstart. }
  Si('The application is now in maintenance mode.');
end;

procedure CmdUp;
begin
  if FileExists(VedlikeholdsFil) then
    DeleteFile(VedlikeholdsFil);
  Si('The application is live.');
end;

{ --------------------------------------------------------------- om -- }

procedure CmdAbout;
begin
  Si('Application');
  Si('  Environment   ' + AppEnv);
  Si('  Debug         ' + BoolAnswer(not IsProduction, 'yes', 'no'));
  Si('  Maintenance   ' + BoolAnswer(FileExists(VedlikeholdsFil), 'ON', 'off'));
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
  TKommando = record
    Name_: string;
    Hjelp: string;
  end;

const
  Kommandoer: array[0..21] of TKommando = (
    (Name_: 'about';            Hjelp: 'what this app is configured with'),
    (Name_: 'routes';           Hjelp: 'the routing table'),
    (Name_: 'migrate';          Hjelp: 'run pending migrations'),
    (Name_: 'migrate:status';   Hjelp: 'what has run and what has not'),
    (Name_: 'migrate:rollback'; Hjelp: 'roll back the last batch (--step=N)'),
    (Name_: 'migrate:reset';    Hjelp: 'roll back everything'),
    (Name_: 'migrate:fresh';    Hjelp: 'drop all tables, then migrate (--seed)'),
    (Name_: 'migrate:refresh';  Hjelp: 'reset, then migrate (--seed)'),
    (Name_: 'db:seed';          Hjelp: 'run the seeders (--class=Name)'),
    (Name_: 'db:show';          Hjelp: 'tables in the database'),
    (Name_: 'db:table';         Hjelp: 'columns, indexes and keys of one table'),
    (Name_: 'db:wipe';          Hjelp: 'drop every table (--force in production)'),
    (Name_: 'schema';           Hjelp: 'generate typed columns from the database'),
    (Name_: 'queue:work';       Hjelp: 'run the queue until interrupted'),
    (Name_: 'queue:status';     Hjelp: 'counters for the queue'),
    (Name_: 'schedule:list';    Hjelp: 'the schedule'),
    (Name_: 'schedule:run';     Hjelp: 'dispatch what is due, once'),
    (Name_: 'cache:clear';      Hjelp: 'empty the cache'),
    (Name_: 'down';             Hjelp: 'maintenance mode on'),
    (Name_: 'up';               Hjelp: 'maintenance mode off'),
    (Name_: 'env';              Hjelp: 'the current environment'),
    (Name_: 'list';             Hjelp: 'these commands'));

function ConsoleCommands: TStringArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Kommandoer));
  for I := Low(Kommandoer) to High(Kommandoer) do
    Result[I] := Kommandoer[I].Name_;
end;

procedure CmdList;
var
  I: Integer;
begin
  Si('Commands this app answers to:');
  Si('');
  for I := Low(Kommandoer) to High(Kommandoer) do
    Si(Format('  %-18s %s', [Kommandoer[I].Name_, Kommandoer[I].Hjelp]));
end;

function RunConsole: Boolean;
var
  K: string;
begin
  Result := False;
  if ParamCount < 1 then
    Exit;
  K := ParamStr(1);
  { Kommandoene kommer som --navn fra verktøyet. Without prefikset er det
    portnummeret, slik det alltid har vært. }
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
