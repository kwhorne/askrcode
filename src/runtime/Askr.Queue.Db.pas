{ Askr.Queue.Db — jobber som overlever at prosessen dør.

  Køen i `Askr.Queue` ligger i prosessen. Det er riktig for det meste: ingen
  Redis, ingen supervisor, ingen Horizon. Men jobbene forsvinner ved en
  omstart, og en velkomst-e-post som aldri ble sendt fordi noen rullet ut en
  ny versjon er ikke en ytelsesdetalj — det er data som er borte.

  Dette lageret legger jobbene i databasen appen allerede har. Ingen ny
  tjeneste, og transaksjonen som lagret ordren kan være den samme som la
  jobben i kø.

  **Utførelsen er den samme.** `TQueue` og workerne er uendret; det eneste
  som byttes er hvor jobbene ligger. Et eget worker-løp for varige jobber
  ville gitt to sett regler for backoff, forsøkstelling og arena-levetid,
  og de to ville drevet fra hverandre.

  Tre ting som er verdt å vite:

    * **Payloaden lagres som tekst.** I praksis JSON, som er det jobber
      sender. Rå bytes avvises med en gang i stedet for å bli ødelagt av
      tegnsettkonvertering på vei inn i en TEXT-kolonne.
    * **En reservert jobb slippes igjen etter et tidsavbrudd.** Dør
      prosessen midt i en jobb, blir den liggende reservert for alltid uten
      det. Standard er fem minutter.
    * **`SKIP LOCKED` brukes der dialekten har det.** Postgres og MySQL 8
      lar to workere hente hver sin jobb uten å vente på hverandre. SQLite
      har det ikke, men har bare én skriver, og der er en umiddelbar
      transaksjon nok. }
unit Askr.Queue.Db;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, SyncObjs,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Clock,
  Askr.Urd.Driver, Askr.Urd.Pool,
  Askr.Norn.Schema, Askr.Norn.Introspect,
  Askr.Queue;

const
  DefaultJobsTable = 'askr_jobs';
  DefaultFailedTable = 'askr_failed_jobs';
  { Where_ lenge en jobb får være reservert før noen andre kan ta den. Dette
    er ikke en tidsfrist for jobben — det er hvor lenge vi venter før vi
    antar at workeren som tok den er borte. }
  DefaultVisibilityMs = 5 * 60 * 1000;

type
  EQueueDbError = class(Exception);

  TDbJobStore = class(TJobStore)
  private
    FPool: TDbPool;
    FOwnsPool: Boolean;
    FDialect: TSqlDialect;
    FJobsTable: string;
    FFailedTable: string;
    FVisibilityMs: Int64;
    FPollMs: Integer;
    FLock: TCriticalSection;
    { Name_ på denne prosessens workere i reserved_by. To_ diagnostikk: en
      rad som har stått reservert i en time sier hvem som tok den. }
    FOwner: string;
    function SkipLocked: Boolean;
    procedure FrigiForlatte(C: TDbConnection; A: TArena);
  public
    { Åpner sin egen pool mot DSN-en. }
    constructor Create(const Dsn: string; AMaxConnections: Integer = 4); overload;
    { Parts_ pool med appen. Poolen må tåle minst én forbindelse per
      køworker — ellers står workerne og venter på hverandre. }
    constructor Create(APool: TDbPool; AOwnsPool: Boolean = False); overload;
    destructor Destroy; override;

    { Storage tabellene hvis de ikke finnes. Trygg å kalle ved hver oppstart.
      Kalles ikke av seg selv: en app som kjører migrasjoner vil ha
      kontroll på når skjemaet endres. }
    procedure EnsureSchema;
    { Count_ jobber som har gitt opp. To_ et statusendepunkt. }
    function FailedCount: Int64;
    { Tømmer feiltabellen. }
    procedure ClearFailed;
    { Legger de feilede tilbake i køen. After_ at det som var galt er rettet. }
    function RetryFailed: Integer;

    procedure Push(const JobName: string; Data: PByte; Len: SizeInt;
      DelayMs: Int64); override;
    function Reserve(out J: TReservedJob): Boolean; override;
    procedure Complete(var J: TReservedJob); override;
    procedure Retry(var J: TReservedJob; DelayMs: Int64); override;
    procedure Fail(var J: TReservedJob; const Reason: string); override;
    procedure Drop(var J: TReservedJob; const Reason: string); override;
    function Pending: Integer; override;
    function Durable: Boolean; override;
    function PollIntervalMs: Integer; override;

    property JobsTable: string read FJobsTable write FJobsTable;
    property FailedTable: string read FFailedTable write FFailedTable;
    property VisibilityMs: Int64 read FVisibilityMs write FVisibilityMs;
    property Poll: Integer read FPollMs write FPollMs;
  end;

implementation

uses
  Askr.Core.Log;

{ ------------------------------------------------------------ oppsett -- }

constructor TDbJobStore.Create(const Dsn: string; AMaxConnections: Integer);
begin
  Create(TDbPool.Create(Dsn, AMaxConnections), True);
end;

constructor TDbJobStore.Create(APool: TDbPool; AOwnsPool: Boolean);
var
  A: TArena;
  C: TDbConnection;
begin
  inherited Create;
  if APool = nil then
    raise EQueueDbError.Create('A database job store needs a pool.');
  FPool := APool;
  FOwnsPool := AOwnsPool;
  FJobsTable := DefaultJobsTable;
  FFailedTable := DefaultFailedTable;
  FVisibilityMs := DefaultVisibilityMs;
  { 250 ms, ikke 20. En worker uten arbeid spør databasen hver gang den
    våkner, og fire workere på 20 ms er 200 spørringer i sekundet mot en
    tom tabell. }
  FPollMs := 250;
  FLock := TCriticalSection.Create;
  FOwner := Format('%s:%d', [ExtractFileName(ParamStr(0)), GetProcessID]);

  { Dialekten må vites før første spørring, og den kan bare leses av en
    forbindelse. }
  A := TArena.Create(4 * 1024);
  try
    C := FPool.Acquire;
    try
      FDialect := C.Dialect;
    finally
      FPool.Release(C);
    end;
  finally
    A.Free;
  end;
end;

destructor TDbJobStore.Destroy;
begin
  FLock.Free;
  if FOwnsPool then
    FPool.Free;
  inherited Destroy;
end;

function TDbJobStore.Durable: Boolean;
begin
  Result := True;
end;

function TDbJobStore.PollIntervalMs: Integer;
begin
  Result := FPollMs;
end;

function TDbJobStore.SkipLocked: Boolean;
begin
  { SQLite har ikke SKIP LOCKED, og trenger det ikke: den har én skriver,
    og en umiddelbar transaksjon serialiserer uttaket. }
  Result := FDialect in [sdPostgres, sdMySql];
end;

procedure TDbJobStore.EnsureSchema;
var
  S: TSchemaBuilder;
  T: TTableBuilder;
  Setninger: TStringArray;
  I: Integer;
  A: TArena;
  C: TDbConnection;
  Skjema: TDbSchema;
  Finnes: Boolean;
begin
  { Check først, i stedet for å la DDL-en være idempotent. `CREATE TABLE IF
    NOT EXISTS` finnes i alle tre, men `CREATE INDEX IF NOT EXISTS` finnes
    ikke i MySQL — og uten sjekken feilet andre oppstart på indeksen. Å
    svelge «already exists» i stedet ville skjult ekte feil. }
  A := TArena.Create(64 * 1024);
  try
    C := FPool.Acquire;
    try
      Skjema := IntrospectSchema(C);
      Finnes := (Skjema.Table(FJobsTable) <> nil) and
                (Skjema.Table(FFailedTable) <> nil);
      Skjema.Free;
    finally
      FPool.Release(C);
    end;
  finally
    A.Free;
  end;
  if Finnes then
    Exit;

  S := TSchemaBuilder.Create(FDialect);
  try
    T := S.Create(FJobsTable);
    T.IfNotExists := True;
    T.Id;
    T.Text('name', 128);
    T.Text('payload');
    T.Int('attempts').Default(0);
    { Tidspunktene er unix-millisekunder, ikke TIMESTAMP. More prosesser
      deler tabellen, og et heltall betyr det samme uansett hvilken
      tidssone den enkelte serveren tror den står i. }
    T.BigInt('available_at');
    T.BigInt('reserved_at').Nullable;
    T.Text('reserved_by', 128).Nullable;
    T.BigInt('created_at');
    { Uttaket sorterer på available_at innenfor det som ikke er reservert.
      Without indeksen blir hver poll en full skanning. }
    T.Index(['available_at']);

    T := S.Create(FFailedTable);
    T.IfNotExists := True;
    T.Id;
    T.Text('name', 128);
    T.Text('payload');
    T.Int('attempts');
    T.Text('error');
    T.BigInt('failed_at');

    Setninger := S.ToSql;
  finally
    S.Free;
  end;

  A := TArena.Create(8 * 1024);
  try
    C := FPool.Acquire;
    try
      for I := 0 to High(Setninger) do
        C.Exec(A, Setninger[I]);
    finally
      FPool.Release(C);
    end;
  finally
    A.Free;
  end;
end;

{ ------------------------------------------------------------- hjelpere -- }

function Ph(C: TDbConnection; A: TArena; Index: Integer): string;
var
  B: TStrBuilder;
begin
  B.Init(A, 8);
  C.AppendPlaceholder(B, Index);
  Result := B.ToString;
end;

{ Bygger «$1, $2, …» eller «?, ?, …» etter dialekt. }
function Phs(C: TDbConnection; A: TArena; From_, To_: Integer): string;
var
  I: Integer;
begin
  Result := '';
  for I := From_ to To_ do
  begin
    if I > From_ then
      Result := Result + ', ';
    Result := Result + Ph(C, A, I);
  end;
end;

function Sitert(C: TDbConnection; A: TArena; const Name_: string): string;
var
  B: TStrBuilder;
begin
  B.Init(A, Length(Name_) + 4);
  C.AppendIdentStr(B, Name_);
  Result := B.ToString;
end;

{ ------------------------------------------------------------ operasjoner -- }

procedure TDbJobStore.Push(const JobName: string; Data: PByte; Len: SizeInt;
  DelayMs: Int64);
var
  A: TArena;
  C: TDbConnection;
  Sql, Payload: string;
  I: SizeInt;
  Now_: Int64;
begin
  SetLength(Payload, Len);
  if Len > 0 then
    Move(Data^, Payload[1], Len);

  { En nullbyte kan ikke stå i en TEXT-kolonne i noen av de tre. Å oppdage
    det her gir en feil på kallstedet; å la den gå videre gir en jobb som
    er stille ødelagt, eller en driverfeil langt unna den som skrev den. }
  for I := 1 to Length(Payload) do
    if Payload[I] = #0 then
      raise EQueueDbError.CreateFmt(
        'The payload for job "%s" contains a NUL byte. A durable queue ' +
        'stores payloads as text; use JSON or base64 for binary data.',
        [JobName]);

  Now_ := UnixNowMs;
  A := TArena.Create(8 * 1024);
  try
    C := FPool.Acquire;
    try
      Sql := 'INSERT INTO ' + Sitert(C, A, FJobsTable) +
        ' (name, payload, attempts, available_at, created_at) VALUES (' +
        Phs(C, A, 1, 5) + ')';
      C.ExecParams(A, Sql, [
        DbParam(A, JobName),
        DbParam(A, Payload),
        DbParam(A, Int64(0)),
        DbParam(A, Now_ + DelayMs),
        DbParam(A, Now_)]);
    finally
      FPool.Release(C);
    end;
  finally
    A.Free;
  end;
end;

{ Jobs_ som ble reservert og aldri gjort opp. Prosessen som tok dem er
  borte — den ble drept, eller maskinen forsvant. Without dette ville de blitt
  liggende for alltid. }
procedure TDbJobStore.FrigiForlatte(C: TDbConnection; A: TArena);
var
  R: TDbResult;
  Sql: string;
begin
  Sql := 'UPDATE ' + Sitert(C, A, FJobsTable) +
    ' SET reserved_at = NULL, reserved_by = NULL' +
    ' WHERE reserved_at IS NOT NULL AND reserved_at < ' + Ph(C, A, 1);
  R := C.ExecParams(A, Sql, [DbParam(A, UnixNowMs - FVisibilityMs)]);
  if (R <> nil) and (R.AffectedRows > 0) then
    LogWarn('released abandoned jobs',
      ['count', R.AffectedRows, 'table', FJobsTable]);
end;

function TDbJobStore.Reserve(out J: TReservedJob): Boolean;
var
  A: TArena;
  C: TDbConnection;
  R: TDbResult;
  Sql, Payload: string;
  Id: Int64;
  Now_: Int64;
begin
  FillChar(J, SizeOf(J), 0);
  J.Name := '';
  Result := False;

  A := TArena.Create(16 * 1024);
  try
    C := FPool.Acquire;
    try
      FrigiForlatte(C, A);
      Now_ := UnixNowMs;

      { Én transaksjon rundt «finn og ta». To workere som ser den samme
        raden skal ikke begge få den. }
      C.StartTransaction;
      try
        Sql := 'SELECT id, name, payload, attempts FROM ' +
          Sitert(C, A, FJobsTable) +
          ' WHERE reserved_at IS NULL AND available_at <= ' + Ph(C, A, 1) +
          ' ORDER BY available_at, id LIMIT 1';
        if SkipLocked then
          Sql := Sql + ' FOR UPDATE SKIP LOCKED';
        R := C.ExecParams(A, Sql, [DbParam(A, Now_)]);
        if (R = nil) or R.IsEmpty then
        begin
          C.Commit;
          Exit(False);
        end;

        Id := R.AsInt64(0, 0);
        J.Name := R.Value(0, 1).ToString;
        Payload := R.Value(0, 2).ToString;
        J.Attempt := Integer(R.AsInt64(0, 3));

        Sql := 'UPDATE ' + Sitert(C, A, FJobsTable) +
          ' SET reserved_at = ' + Ph(C, A, 1) +
          ', reserved_by = ' + Ph(C, A, 2) +
          ' WHERE id = ' + Ph(C, A, 3) + ' AND reserved_at IS NULL';
        R := C.ExecParams(A, Sql,
          [DbParam(A, Now_), DbParam(A, FOwner), DbParam(A, Id)]);
        { Without SKIP LOCKED kan en annen ha rukket å ta den mellom SELECT
          og UPDATE. Da er AffectedRows null, og vi lar den være. }
        if (R = nil) or (R.AffectedRows = 0) then
        begin
          C.Commit;
          J.Name := '';
          Exit(False);
        end;
        C.Commit;
      except
        C.Rollback;
        raise;
      end;
    finally
      FPool.Release(C);
    end;
  finally
    A.Free;
  end;

  { Payloaden kopieres til heapen, ikke til arenaen: arenaen over dør her,
    og workeren kopierer videre inn i sin egen. Det er den samme grensen
    som i minnelageret. }
  J.Id := Id;
  J.Len := Length(Payload);
  if J.Len > 0 then
  begin
    J.Data := GetMem(J.Len);
    Move(Payload[1], J.Data^, J.Len);
  end;
  J.Token := nil;
  Result := True;
end;

{ Frigjør det workeren fikk. Kalles av hver av de fire avslutningene. }
procedure SlippMinne(var J: TReservedJob);
begin
  if J.Data <> nil then
    FreeMem(J.Data);
  J.Data := nil;
  J.Len := 0;
  J.Name := '';
  J.Id := 0;
end;

procedure TDbJobStore.Complete(var J: TReservedJob);
var
  A: TArena;
  C: TDbConnection;
begin
  A := TArena.Create(4 * 1024);
  try
    C := FPool.Acquire;
    try
      C.ExecParams(A, 'DELETE FROM ' + Sitert(C, A, FJobsTable) +
        ' WHERE id = ' + Ph(C, A, 1), [DbParam(A, J.Id)]);
    finally
      FPool.Release(C);
    end;
  finally
    A.Free;
  end;
  SlippMinne(J);
end;

procedure TDbJobStore.Retry(var J: TReservedJob; DelayMs: Int64);
var
  A: TArena;
  C: TDbConnection;
begin
  A := TArena.Create(4 * 1024);
  try
    C := FPool.Acquire;
    try
      { Reservasjonen slippes og tidspunktet skyves. Forsøkstelleren står i
        raden, ikke i minnet — den skal overleve at prosessen dør midt i. }
      C.ExecParams(A, 'UPDATE ' + Sitert(C, A, FJobsTable) +
        ' SET attempts = attempts + 1, reserved_at = NULL,' +
        ' reserved_by = NULL, available_at = ' + Ph(C, A, 1) +
        ' WHERE id = ' + Ph(C, A, 2),
        [DbParam(A, UnixNowMs + DelayMs), DbParam(A, J.Id)]);
    finally
      FPool.Release(C);
    end;
  finally
    A.Free;
  end;
  SlippMinne(J);
end;

procedure TDbJobStore.Fail(var J: TReservedJob; const Reason: string);
var
  A: TArena;
  C: TDbConnection;
  Payload: string;
begin
  SetLength(Payload, J.Len);
  if J.Len > 0 then
    Move(J.Data^, Payload[1], J.Len);

  A := TArena.Create(8 * 1024);
  try
    C := FPool.Acquire;
    try
      C.StartTransaction;
      try
        { Flyttes, ikke slettes. En jobb som har gitt opp er det eneste
          sporet av at noe skulle ha skjedd og ikke gjorde det. }
        C.ExecParams(A, 'INSERT INTO ' + Sitert(C, A, FFailedTable) +
          ' (name, payload, attempts, error, failed_at) VALUES (' +
          Phs(C, A, 1, 5) + ')',
          [DbParam(A, J.Name), DbParam(A, Payload),
           DbParam(A, Int64(J.Attempt + 1)), DbParam(A, Reason),
           DbParam(A, UnixNowMs)]);
        C.ExecParams(A, 'DELETE FROM ' + Sitert(C, A, FJobsTable) +
          ' WHERE id = ' + Ph(C, A, 1), [DbParam(A, J.Id)]);
        C.Commit;
      except
        C.Rollback;
        raise;
      end;
    finally
      FPool.Release(C);
    end;
  finally
    A.Free;
  end;
  SlippMinne(J);
end;

procedure TDbJobStore.Drop(var J: TReservedJob; const Reason: string);
begin
  { Ingen handler registrert. Den kan aldri kjøre, men den skal ikke
    forsvinne i stillhet — en app som har mistet en Handle-linje skal kunne
    se hva som lå der. }
  Fail(J, Reason);
end;

function TDbJobStore.Pending: Integer;
var
  A: TArena;
  C: TDbConnection;
  R: TDbResult;
begin
  Result := 0;
  A := TArena.Create(4 * 1024);
  try
    C := FPool.Acquire;
    try
      R := C.Exec(A, 'SELECT count(*) FROM ' + Sitert(C, A, FJobsTable));
      if (R <> nil) and not R.IsEmpty then
        Result := Integer(R.AsInt64(0, 0));
    finally
      FPool.Release(C);
    end;
  finally
    A.Free;
  end;
end;

function TDbJobStore.FailedCount: Int64;
var
  A: TArena;
  C: TDbConnection;
  R: TDbResult;
begin
  Result := 0;
  A := TArena.Create(4 * 1024);
  try
    C := FPool.Acquire;
    try
      R := C.Exec(A, 'SELECT count(*) FROM ' + Sitert(C, A, FFailedTable));
      if (R <> nil) and not R.IsEmpty then
        Result := R.AsInt64(0, 0);
    finally
      FPool.Release(C);
    end;
  finally
    A.Free;
  end;
end;

procedure TDbJobStore.ClearFailed;
var
  A: TArena;
  C: TDbConnection;
begin
  A := TArena.Create(4 * 1024);
  try
    C := FPool.Acquire;
    try
      C.Exec(A, 'DELETE FROM ' + Sitert(C, A, FFailedTable));
    finally
      FPool.Release(C);
    end;
  finally
    A.Free;
  end;
end;

function TDbJobStore.RetryFailed: Integer;
var
  A: TArena;
  C: TDbConnection;
  R: TDbResult;
  I: Integer;
  Now_: Int64;
begin
  Result := 0;
  Now_ := UnixNowMs;
  A := TArena.Create(64 * 1024);
  try
    C := FPool.Acquire;
    try
      R := C.Exec(A, 'SELECT id, name, payload FROM ' +
        Sitert(C, A, FFailedTable) + ' ORDER BY id');
      if (R = nil) or R.IsEmpty then
        Exit(0);
      C.StartTransaction;
      try
        for I := 0 to R.RowCount - 1 do
        begin
          C.ExecParams(A, 'INSERT INTO ' + Sitert(C, A, FJobsTable) +
            ' (name, payload, attempts, available_at, created_at) VALUES (' +
            Phs(C, A, 1, 5) + ')',
            [DbParam(R.Value(I, 1)), DbParam(R.Value(I, 2)),
             DbParam(A, Int64(0)), DbParam(A, Now_), DbParam(A, Now_)]);
          C.ExecParams(A, 'DELETE FROM ' + Sitert(C, A, FFailedTable) +
            ' WHERE id = ' + Ph(C, A, 1), [DbParam(A, R.AsInt64(I, 0))]);
          Inc(Result);
        end;
        C.Commit;
      except
        C.Rollback;
        raise;
      end;
    finally
      FPool.Release(C);
    end;
  finally
    A.Free;
  end;
end;

end.
