{ Askr.Queue.Db — jobs that survive the process dying.

  The queue in `Askr.Queue` lives in the process. That is right for most
  things: no Redis, no supervisor, no Horizon. But the jobs vanish on a
  restart, and a welcome email that was never sent because somebody
  deployed a new version is not a performance detail — it is data that is
  gone.

  This store puts the jobs in the database the app already has. No new
  service, and the transaction that saved the order can be the same one
  that queued the job.

  **The execution is the same.** `TQueue` and the workers are unchanged;
  the only thing swapped is where the jobs live. A separate worker loop
  for durable jobs would give two sets of rules for backoff, attempt
  counting and arena lifetime, and the two would drift apart.

  Three things worth knowing:

    * **The payload is stored as text.** In practice JSON, which is what
      jobs send. Raw bytes are refused immediately rather than being
      corrupted by character set conversion on the way into a TEXT
      column.
    * **A reserved job is released again after a timeout.** If the process
      dies mid-job it would otherwise stay reserved forever. The default
      is five minutes.
    * **`SKIP LOCKED` is used where the dialect has it.** Postgres and
      MySQL 8 let two workers each take a job without waiting for each
      other. SQLite does not have it, but has only one writer, and there
      an immediate transaction is enough. }
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
  DefaultBatchesTable = 'askr_job_batches';
  { How long a job may stay reserved before somebody else can take it.
    This is not a deadline for the job — it is how long we wait before
    assuming the worker that took it is gone. }
  DefaultVisibilityMs = 5 * 60 * 1000;

type
  EQueueDbError = class(Exception);

  { Called between the SELECT that found a job and the UPDATE that takes
    it. For the test only: it is the one way to put another connection's
    write in that window every time. }
  TClaimHook = procedure(C: TDbConnection);

  TDbJobStore = class(TJobStore)
  private
    FPool: TDbPool;
    FOwnsPool: Boolean;
    FDialect: TSqlDialect;
    FJobsTable: string;
    FFailedTable: string;
    FBatchesTable: string;
    FVisibilityMs: Int64;
    FPollMs: Integer;
    FLock: TCriticalSection;
    { The name of this process's workers in reserved_by. For diagnostics: a
      row that has been reserved for an hour says who took it. }
    FOwner: string;
    FBeforeClaim: TClaimHook;
    function SkipLocked: Boolean;
    procedure ReleaseAbandoned(C: TDbConnection; A: TArena);
  public
    { Opens its own pool against the DSN. }
    constructor Create(const Dsn: string; AMaxConnections: Integer = 4); overload;
    { Shares a pool with the app. The pool has to tolerate at least one
      connection per queue worker — otherwise the workers sit waiting for
      each other. }
    constructor Create(APool: TDbPool; AOwnsPool: Boolean = False); overload;
    destructor Destroy; override;

    { Creates the tables if they do not exist. Safe to call at every
      startup. Not called by itself: an app that runs migrations wants
      control over when the schema changes. }
    procedure EnsureSchema;
    { How many jobs have given up. For a status endpoint. }
    function FailedCount: Int64;
    { Empties the failed-jobs table. }
    procedure ClearFailed;
    { Puts the failed ones back in the queue. After whatever was wrong has
      been fixed. }
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

    procedure CreateBatch(const Id, Name: string; Total: Integer;
      const Callbacks: TBatchCallbacks); override;
    function SettleBatchJob(const Id: string; Failed: Boolean): TJobSpecs; override;
    function FindBatch(const Id: string; out State: TBatchState): Boolean; override;
    procedure CancelBatch(const Id: string); override;

    property JobsTable: string read FJobsTable write FJobsTable;
    property FailedTable: string read FFailedTable write FFailedTable;
    property BatchesTable: string read FBatchesTable write FBatchesTable;
    property BeforeClaim: TClaimHook read FBeforeClaim write FBeforeClaim;
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
  FBatchesTable := DefaultBatchesTable;
  FVisibilityMs := DefaultVisibilityMs;
  { 250 ms, not 20. An idle worker asks the database every time it wakes,
    and four workers at 20 ms is 200 queries a second against an empty
    table. }
  FPollMs := 250;
  FLock := TCriticalSection.Create;
  FOwner := Format('%s:%d', [ExtractFileName(ParamStr(0)), GetProcessID]);

  { The dialect has to be known before the first query, and it can only
    be read off a connection. }
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
  { SQLite has no SKIP LOCKED, and does not need it: it has one writer,
    and the immediate transaction in Reserve serialises the claim. }
  Result := FDialect in [sdPostgres, sdMySql];
end;

procedure TDbJobStore.EnsureSchema;
var
  S: TSchemaBuilder;
  T: TTableBuilder;
  Statements: TStringArray;
  I: Integer;
  A: TArena;
  C: TDbConnection;
  Schema_: TDbSchema;
  HasJobs, HasFailed, HasBatches: Boolean;
begin
  { Check first, rather than relying on the DDL being idempotent. `CREATE
    TABLE IF NOT EXISTS` exists in all three, but `CREATE INDEX IF NOT
    EXISTS` does not exist in MySQL — and without the check the second
    startup failed on the index. Swallowing "already exists" instead would
    have hidden real errors. }
  A := TArena.Create(64 * 1024);
  try
    C := FPool.Acquire;
    try
      Schema_ := IntrospectSchema(C);
      HasJobs := Schema_.Table(FJobsTable) <> nil;
      HasFailed := Schema_.Table(FFailedTable) <> nil;
      HasBatches := Schema_.Table(FBatchesTable) <> nil;
      Schema_.Free;
    finally
      FPool.Release(C);
    end;
  finally
    A.Free;
  end;
  if HasJobs and HasFailed and HasBatches then
    Exit;

  { Only what is missing: the batches table came in a later release, and
    creating the jobs table's index a second time fails in MySQL. }
  S := TSchemaBuilder.Create(FDialect);
  try
    if not HasJobs then
    begin
    T := S.Create(FJobsTable);
    T.IfNotExists := True;
    T.Id;
    T.Text('name', 128);
    T.Text('payload');
    T.Int('attempts').Default(0);
    { The times are unix milliseconds, not TIMESTAMP. Several processes
      share the table, and an integer means the same thing whatever time
      zone each server believes it is in. }
    T.BigInt('available_at');
    T.BigInt('reserved_at').Nullable;
    T.Text('reserved_by', 128).Nullable;
    T.BigInt('created_at');
    { The claim sorts on available_at among what is not reserved. Without
      the index every poll becomes a full scan. }
    T.Index(['available_at']);
    end;

    if not HasFailed then
    begin
    T := S.Create(FFailedTable);
    T.IfNotExists := True;
    T.Id;
    T.Text('name', 128);
    T.Text('payload');
    T.Int('attempts');
    T.Text('error');
    T.BigInt('failed_at');
    end;

    if not HasBatches then
    begin
      T := S.Create(FBatchesTable);
      T.IfNotExists := True;
      T.Id;
      T.Text('uid', 32).Unique;
      T.Text('name', 128);
      T.Int('total');
      T.Int('pending');
      T.Int('failed').Default(0);
      T.Int('cancelled').Default(0);
      { Set by the one settling that queues OnFailure, so it is queued
        once. }
      T.Int('caught').Default(0);
      T.Text('success_name', 128);
      T.Text('success_payload');
      T.Text('failure_name', 128);
      T.Text('failure_payload');
      T.Text('always_name', 128);
      T.Text('always_payload');
      T.BigInt('created_at');
      { Set by the one settling that finishes the batch. }
      T.BigInt('finished_at').Nullable;
    end;

    Statements := S.ToSql;
  finally
    S.Free;
  end;

  A := TArena.Create(8 * 1024);
  try
    C := FPool.Acquire;
    try
      for I := 0 to High(Statements) do
        C.Exec(A, Statements[I]);
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

{ Builds "$1, $2, ..." or "?, ?, ..." depending on the dialect. }
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

function Quoted(C: TDbConnection; A: TArena; const Name_: string): string;
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

  { A null byte cannot sit in a TEXT column in any of the three. Catching
    it here gives an error at the call site; letting it through gives a
    job that is silently corrupt, or a driver error a long way from
    whoever wrote it. }
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
      Sql := 'INSERT INTO ' + Quoted(C, A, FJobsTable) +
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

{ Jobs that were reserved and never settled. The process that took them
  is gone — it was killed, or the machine disappeared. Without this they
  would stay there forever. }
procedure TDbJobStore.ReleaseAbandoned(C: TDbConnection; A: TArena);
var
  R: TDbResult;
  Sql: string;
begin
  Sql := 'UPDATE ' + Quoted(C, A, FJobsTable) +
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
      ReleaseAbandoned(C, A);
      Now_ := UnixNowMs;

      { One transaction around "find and take". Two workers seeing the same
        row must not both get it.

        In SQLite it has to be IMMEDIATE, which takes the write lock at
        BEGIN. A deferred one reads under a snapshot and asks for the
        lock at the UPDATE, and in WAL mode a worker whose snapshot another
        worker has written past gets SQLITE_BUSY at once -- the busy
        timeout does not wait for that. The comment here said immediate
        for a long time while the code said BEGIN, and each time it
        happened a worker thread died without a word. }
      if FDialect = sdSqlite then
        C.Exec(A, 'BEGIN IMMEDIATE')
      else
        C.StartTransaction;
      try
        Sql := 'SELECT id, name, payload, attempts FROM ' +
          Quoted(C, A, FJobsTable) +
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
        if Assigned(FBeforeClaim) then
          FBeforeClaim(C);

        Sql := 'UPDATE ' + Quoted(C, A, FJobsTable) +
          ' SET reserved_at = ' + Ph(C, A, 1) +
          ', reserved_by = ' + Ph(C, A, 2) +
          ' WHERE id = ' + Ph(C, A, 3) + ' AND reserved_at IS NULL';
        R := C.ExecParams(A, Sql,
          [DbParam(A, Now_), DbParam(A, FOwner), DbParam(A, Id)]);
        { Without SKIP LOCKED another one may have taken it between the
          SELECT and the UPDATE. Then AffectedRows is zero and we leave it
          alone. }
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

  { The payload is copied to the heap, not to the arena: the arena above
    dies here, and the worker copies on into its own. It is the same
    boundary as in the in-process store. }
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

{ Releases what the worker was given. Called by each of the four
  endings. }
procedure FreePayload(var J: TReservedJob);
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
      C.ExecParams(A, 'DELETE FROM ' + Quoted(C, A, FJobsTable) +
        ' WHERE id = ' + Ph(C, A, 1), [DbParam(A, J.Id)]);
    finally
      FPool.Release(C);
    end;
  finally
    A.Free;
  end;
  FreePayload(J);
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
      { The reservation is released and the time pushed out. The attempt
        counter is in the row, not in memory — it has to survive the
        process dying mid-job. }
      C.ExecParams(A, 'UPDATE ' + Quoted(C, A, FJobsTable) +
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
  FreePayload(J);
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
        { Moved, not deleted. A job that has given up is the only trace that
          something should have happened and did not. }
        C.ExecParams(A, 'INSERT INTO ' + Quoted(C, A, FFailedTable) +
          ' (name, payload, attempts, error, failed_at) VALUES (' +
          Phs(C, A, 1, 5) + ')',
          [DbParam(A, J.Name), DbParam(A, Payload),
           DbParam(A, Int64(J.Attempt + 1)), DbParam(A, Reason),
           DbParam(A, UnixNowMs)]);
        C.ExecParams(A, 'DELETE FROM ' + Quoted(C, A, FJobsTable) +
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
  FreePayload(J);
end;

procedure TDbJobStore.Drop(var J: TReservedJob; const Reason: string);
begin
  { No handler registered. It can never run, but it must not disappear
    silently — an app that has lost a Handle line should be able to see
    what was there. }
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
      R := C.Exec(A, 'SELECT count(*) FROM ' + Quoted(C, A, FJobsTable));
      if (R <> nil) and not R.IsEmpty then
        Result := Integer(R.AsInt64(0, 0));
    finally
      FPool.Release(C);
    end;
  finally
    A.Free;
  end;
end;


{ ------------------------------------------------------------- batches -- }

{ Every step of a settling is one conditional UPDATE, and the affected row
  count says who won it. Two workers finishing the last two jobs at once
  both decrement, but only one of them finds pending at nothing and
  finished_at unset -- in all three dialects, without SELECT FOR UPDATE. }

procedure TDbJobStore.CreateBatch(const Id, Name: string; Total: Integer;
  const Callbacks: TBatchCallbacks);
var
  A: TArena;
  C: TDbConnection;
  FinishedParam: TDbParam;
begin
  A := TArena.Create(8 * 1024);
  try
    C := FPool.Acquire;
    try
      { A batch of nothing is finished when it is made. }
      if Total = 0 then
        FinishedParam := DbParam(A, UnixNowMs)
      else
        FinishedParam := DbNull;
      C.ExecParams(A, 'INSERT INTO ' + Quoted(C, A, FBatchesTable) +
        ' (uid, name, total, pending, failed, cancelled, caught, success_name,' +
        ' success_payload, failure_name, failure_payload, always_name,' +
        ' always_payload, created_at, finished_at) VALUES (' + Phs(C, A, 1, 15) + ')',
        [DbParam(A, Id), DbParam(A, Name), DbParam(A, Int64(Total)),
         DbParam(A, Int64(Total)), DbParam(A, Int64(0)), DbParam(A, Int64(0)),
         DbParam(A, Int64(0)),
         DbParam(A, Callbacks.OnSuccess.Name), DbParam(A, Callbacks.OnSuccess.Payload),
         DbParam(A, Callbacks.OnFailure.Name), DbParam(A, Callbacks.OnFailure.Payload),
         DbParam(A, Callbacks.Always.Name), DbParam(A, Callbacks.Always.Payload),
         DbParam(A, UnixNowMs), FinishedParam]);
    finally
      FPool.Release(C);
    end;
  finally
    A.Free;
  end;
end;

procedure AddSpec_(var L: TJobSpecs; const Name, Payload: string);
var
  I: Integer;
begin
  if Name = '' then
    Exit;
  I := Length(L);
  SetLength(L, I + 1);
  L[I].Name := Name;
  L[I].Payload := Payload;
end;

function TDbJobStore.SettleBatchJob(const Id: string; Failed: Boolean): TJobSpecs;
var
  A: TArena;
  C: TDbConnection;
  R: TDbResult;
  Tbl, FailedSet: string;
begin
  Result := nil;
  A := TArena.Create(8 * 1024);
  try
    C := FPool.Acquire;
    try
      Tbl := Quoted(C, A, FBatchesTable);
      FailedSet := '';
      if Failed then
        FailedSet := ', failed = failed + 1';
      { pending > 0: a job run again after it was counted -- put back from
        the failed table -- does not take the count below nothing. }
      R := C.ExecParams(A, 'UPDATE ' + Tbl + ' SET pending = pending - 1' + FailedSet +
        ' WHERE uid = ' + Ph(C, A, 1) + ' AND pending > 0', [DbParam(A, Id)]);
      if (R = nil) or (R.AffectedRows = 0) then
        Exit;
      if Failed then
      begin
        R := C.ExecParams(A, 'UPDATE ' + Tbl + ' SET caught = 1 WHERE uid = ' +
          Ph(C, A, 1) + ' AND caught = 0', [DbParam(A, Id)]);
        if (R <> nil) and (R.AffectedRows > 0) then
        begin
          R := C.ExecParams(A, 'SELECT failure_name, failure_payload FROM ' + Tbl +
            ' WHERE uid = ' + Ph(C, A, 1), [DbParam(A, Id)]);
          if (R <> nil) and not R.IsEmpty then
            AddSpec_(Result, R.Value(0, 0).ToString, R.Value(0, 1).ToString);
        end;
      end;
      R := C.ExecParams(A, 'UPDATE ' + Tbl + ' SET finished_at = ' + Ph(C, A, 1) +
        ' WHERE uid = ' + Ph(C, A, 2) + ' AND pending = 0 AND finished_at IS NULL',
        [DbParam(A, UnixNowMs), DbParam(A, Id)]);
      if (R <> nil) and (R.AffectedRows > 0) then
      begin
        R := C.ExecParams(A, 'SELECT failed, cancelled, success_name, success_payload,' +
          ' always_name, always_payload FROM ' + Tbl + ' WHERE uid = ' + Ph(C, A, 1),
          [DbParam(A, Id)]);
        if (R <> nil) and not R.IsEmpty then
        begin
          if (R.AsInt64(0, 0) = 0) and (R.AsInt64(0, 1) = 0) then
            AddSpec_(Result, R.Value(0, 2).ToString, R.Value(0, 3).ToString);
          AddSpec_(Result, R.Value(0, 4).ToString, R.Value(0, 5).ToString);
        end;
      end;
    finally
      FPool.Release(C);
    end;
  finally
    A.Free;
  end;
end;

function TDbJobStore.FindBatch(const Id: string; out State: TBatchState): Boolean;
var
  A: TArena;
  C: TDbConnection;
  R: TDbResult;
begin
  State := Default(TBatchState);
  Result := False;
  A := TArena.Create(8 * 1024);
  try
    C := FPool.Acquire;
    try
      R := C.ExecParams(A, 'SELECT name, total, pending, failed, cancelled, finished_at FROM ' +
        Quoted(C, A, FBatchesTable) + ' WHERE uid = ' + Ph(C, A, 1), [DbParam(A, Id)]);
      if (R = nil) or R.IsEmpty then
        Exit;
      State.Id := Id;
      State.Name := R.Value(0, 0).ToString;
      State.Total := R.AsInt64(0, 1);
      State.Pending := R.AsInt64(0, 2);
      State.Failed := R.AsInt64(0, 3);
      State.Cancelled := R.AsInt64(0, 4) <> 0;
      State.Finished := not R.IsNull(0, 5);
      Result := True;
    finally
      FPool.Release(C);
    end;
  finally
    A.Free;
  end;
end;

procedure TDbJobStore.CancelBatch(const Id: string);
var
  A: TArena;
  C: TDbConnection;
begin
  A := TArena.Create(4 * 1024);
  try
    C := FPool.Acquire;
    try
      C.ExecParams(A, 'UPDATE ' + Quoted(C, A, FBatchesTable) + ' SET cancelled = 1' +
        ' WHERE uid = ' + Ph(C, A, 1), [DbParam(A, Id)]);
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
      R := C.Exec(A, 'SELECT count(*) FROM ' + Quoted(C, A, FFailedTable));
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
      C.Exec(A, 'DELETE FROM ' + Quoted(C, A, FFailedTable));
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
        Quoted(C, A, FFailedTable) + ' ORDER BY id');
      if (R = nil) or R.IsEmpty then
        Exit(0);
      C.StartTransaction;
      try
        for I := 0 to R.RowCount - 1 do
        begin
          C.ExecParams(A, 'INSERT INTO ' + Quoted(C, A, FJobsTable) +
            ' (name, payload, attempts, available_at, created_at) VALUES (' +
            Phs(C, A, 1, 5) + ')',
            [DbParam(R.Value(I, 1)), DbParam(R.Value(I, 2)),
             DbParam(A, Int64(0)), DbParam(A, Now_), DbParam(A, Now_)]);
          C.ExecParams(A, 'DELETE FROM ' + Quoted(C, A, FFailedTable) +
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
