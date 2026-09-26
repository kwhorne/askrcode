{ Postgres tests, weighted towards prepared statements and their cache.

  Runs against a real server. Without one, the suite skips itself and says
  why.

    ./askr db:up     # Postgres on 5433
    ./askr pg

  The DSN can be overridden with ASKR_PG_DSN. }
program askr_pg_tests;

{$mode Delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Clock,
  Askr.Urd.Driver, Askr.Urd.Pg, Askr.Urd.Pool,
  Askr.Queue, Askr.Queue.Db,
  Askr.Core.Json, Askr.Session, Askr.Session.Db, Askr.Norn.Schema, Askr.Urd.Model, Askr.Urd.Query, Askr.Urd.Json;

var
  Passed: Integer = 0;
  Failed: Integer = 0;
  Dsn: string;

procedure Start(const Name: string);
begin
  WriteLn;
  WriteLn('— ', Name);
end;

procedure Ok(const What: string; Value_: Boolean);
begin
  if Value_ then
  begin
    Inc(Passed);
    WriteLn('  ok    ', What);
  end
  else
  begin
    Inc(Failed);
    WriteLn('  FEIL  ', What);
  end;
end;

procedure Like(const What, Expected, Got: string);
begin
  if Expected = Got then
  begin
    Inc(Passed);
    WriteLn('  ok    ', What);
  end
  else
  begin
    Inc(Failed);
    WriteLn('  FEIL  ', What);
    WriteLn('        forventet: ', Expected);
    WriteLn('        fikk:      ', Got);
  end;
end;

procedure LikeI(const What: string; Expected, Got: Int64);
begin
  Like(What, IntToStr(Expected), IntToStr(Got));
end;

{ The server's own view of it. Without this our cache counters could be
  right while nothing was actually prepared. }
function ServerStatements(C: TPgConnection; A: TArena): Int64;
begin
  Result := C.Exec(A, 'SELECT count(*) FROM pg_prepared_statements').AsInt64(0, 0);
end;

procedure Schema_(C: TDbConnection; A: TArena);
begin
  C.Exec(A, 'DROP TABLE IF EXISTS pg_order');
  C.Exec(A, 'DROP TABLE IF EXISTS pg_customer');
  C.Exec(A,
    'CREATE TABLE pg_customer (' +
    '  id BIGSERIAL PRIMARY KEY,' +
    '  name TEXT NOT NULL,' +
    '  email TEXT NOT NULL UNIQUE,' +
    '  balance NUMERIC(12,2),' +
    '  active BOOLEAN NOT NULL DEFAULT TRUE,' +
    '  created_at TIMESTAMPTZ NOT NULL DEFAULT now())');
end;

procedure Run_;
var
  C: TPgConnection;
  A: TArena;
  R: TDbResult;
  Id: Int64;
  I: Integer;
  Money: Currency;
  ForPrep, ForHits, ForServer: Int64;
  Err, Text_: string;
  V: Currency;
  T0, Without, With_: Int64;
begin
  A := TArena.Create;
  C := TPgConnection.Create(Dsn);
  try
    Start('connection');
    Ok('alive', C.IsAlive);
    Ok('the dialect is Postgres', C.Dialect = sdPostgres);
    Ok('RETURNING exists', C.SupportsReturning);
    WriteLn('        server: ', C.ServerVersion);
    C.Exec(A, 'DEALLOCATE ALL');
    Schema_(C, A);

    Start('prepared statements');
    ForPrep := C.PreparedCount;
    ForHits := C.CacheHits;
    ForServer := ServerStatements(C, A);
    for I := 1 to 20 do
      C.ExecParams(A, 'SELECT $1::bigint + $2::bigint',
        [DbParam(A, Int64(I)), DbParam(A, Int64(1))]);
    LikeI('the same query is prepared once', 1, C.PreparedCount - ForPrep);
    LikeI('the rest hit the cache', 19, C.CacheHits - ForHits);
    LikeI('the server has one statement more', 1,
      ServerStatements(C, A) - ForServer);

    R := C.ExecParams(A, 'SELECT $1::bigint + $2::bigint',
      [DbParam(A, Int64(3)), DbParam(A, Int64(4))]);
    LikeI('and the answer is right', 7, R.AsInt64(0, 0));

    Start('the cache off');
    C.CacheLimit := 0;
    ForPrep := C.PreparedCount;
    for I := 1 to 3 do
      C.ExecParams(A, 'SELECT $1::text', [DbParam(A, 'hei')]);
    LikeI('nothing is prepared', 0, C.PreparedCount - ForPrep);
    R := C.ExecParams(A, 'SELECT $1::text', [DbParam(A, 'hei')]);
    Like('but the answer is the same', 'hei', R.Value(0, 0).ToString);
    C.CacheLimit := 64;

    Start('PQprepare survives a rollback');
    { The SQL statement PREPARE is transactional: prepare it inside a
      transaction that is rolled back and it disappears. **PQprepare is
      something else** — it sends a Parse message in the extended
      protocol, and such statements belong to the session, not to the
      transaction. They survive a rollback.

      The difference is worth a test, because it decides whether the cache
      needs to know about transactions at all. It does not. }
    C.FlushStatementCache;
    C.StartTransaction;
    R := C.ExecParams(A, 'SELECT $1::int * 2', [DbParam(A, Int64(21))]);
    LikeI('prepared and run inside the transaction', 42, R.AsInt64(0, 0));
    ForPrep := C.PreparedCount;
    C.Rollback;

    LikeI('the statement is still on the server', 1, ServerStatements(C, A));
    R := C.ExecParams(A, 'SELECT $1::int * 2', [DbParam(A, Int64(21))]);
    LikeI('the same query works afterwards', 42, R.AsInt64(0, 0));
    LikeI('without being prepared again', 0, C.PreparedCount - ForPrep);

    Start('recovery when the statement disappears anyway');
    { The cache can still go stale: something else in the app may run
      DEALLOCATE ALL, and then it points at names the server does not
      know. Here it is done deliberately, behind the cache's back, to show
      that the next call prepares again instead of failing with 26000. }
    ForPrep := C.PreparedCount;
    C.Exec(A, 'DEALLOCATE ALL');
    LikeI('the server is empty', 0, ServerStatements(C, A));
    R := C.ExecParams(A, 'SELECT $1::int * 2', [DbParam(A, Int64(21))]);
    LikeI('the query works anyway', 42, R.AsInt64(0, 0));
    LikeI('because it was prepared again', 1, C.PreparedCount - ForPrep);
    LikeI('and the server has it again', 1, ServerStatements(C, A));

    Start('a statement that fails is evicted');
    C.FlushStatementCache;
    { InsertGetId takes an INSERT without RETURNING; the driver adds
      whatever the dialect needs. }
    Id := C.InsertGetId(A,
      'INSERT INTO pg_customer (name, email) VALUES ($1, $2)',
      [DbParam(A, 'Ada'), DbParam(A, 'ada@example.com')], 'id');
    Ok('got an id', Id > 0);

    Err := '';
    try
      C.ExecParams(A, 'INSERT INTO pg_customer (name, email) VALUES ($1, $2)',
        [DbParam(A, 'Kopi'), DbParam(A, 'ada@example.com')]);
    except
      on E: EDbError do
      begin
        Err := E.SqlState;
        Ok('a unique violation is recognised', E.IsUniqueViolation);
      end;
    end;
    Like('SQLSTATE is 23505', '23505', Err);

    { The same query is to work afterwards, with a different email. }
    Id := C.InsertGetId(A,
      'INSERT INTO pg_customer (name, email) VALUES ($1, $2)',
      [DbParam(A, 'Bo'), DbParam(A, 'bo@example.com')], 'id');
    Ok('the connection is usable after the error', Id > 0);

    Start('the cache has a limit');
    C.FlushStatementCache;
    C.CacheLimit := 4;
    for I := 1 to 10 do
      C.ExecParams(A,
        Format('SELECT $1::bigint + %d', [I]), [DbParam(A, Int64(1))]);
    Ok('the server stays under the limit',
      ServerStatements(C, A) <= 4);
    R := C.ExecParams(A, 'SELECT $1::bigint + 7', [DbParam(A, Int64(1))]);
    LikeI('and the queries still answer correctly', 8, R.AsInt64(0, 0));
    C.CacheLimit := 64;

    Start('values over the prepared path');
    C.FlushStatementCache;
    Money := 1234.50;
    C.ExecParams(A, 'UPDATE pg_customer SET balance = $1 WHERE id = $2',
      [DbParam(A, Money), DbParam(A, Id)]);
    R := C.ExecParams(A,
      'SELECT name, balance, active, created_at FROM pg_customer WHERE id = $1',
      [DbParam(A, Id)]);
    LikeI('one row', 1, R.RowCount);
    Like('column names are kept', 'balance', R.FieldName(1).ToString);
    Ok('NUMERIC is read as Currency',
      SqlToCurrency(R.Value(0, 'balance'), V) and (V = 1234.50));
    Ok('BOOLEAN is read', R.Value(0, 'active').EqualsStr('t'));
    Ok('the values are in the arena', A.Owns(R.Value(0, 'name').Data));

    C.ExecParams(A, 'UPDATE pg_customer SET balance = $1 WHERE id = $2',
      [DbNull, DbParam(A, Id)]);
    R := C.ExecParams(A, 'SELECT balance FROM pg_customer WHERE id = $1',
      [DbParam(A, Id)]);
    Ok('NULL is NULL', R.IsNull(0, 0));

    Text_ := 'Blåbær 🫐 — he said "hi"; DROP TABLE x; --';
    C.ExecParams(A, 'UPDATE pg_customer SET name = $1 WHERE id = $2',
      [DbParam(A, Text_), DbParam(A, Id)]);
    R := C.ExecParams(A, 'SELECT name FROM pg_customer WHERE id = $1',
      [DbParam(A, Id)]);
    Like('text is data, not SQL', Text_, R.Value(0, 0).ToString);

    Start('many rows over the same statement');
    C.Exec(A, 'DELETE FROM pg_customer');
    C.StartTransaction;
    ForPrep := C.PreparedCount;
    for I := 1 to 500 do
    begin
      { Assigned, never cast: Currency(I) is a reinterpretation of the
        scaled Int64 on x86_64, not a conversion. }
      Money := I;
      Money := Money / 4;
      C.ExecParams(A,
        'INSERT INTO pg_customer (name, email, balance) VALUES ($1, $2, $3)',
        [DbParam(A, 'Bulk ' + IntToStr(I)),
         DbParam(A, 'bulk' + IntToStr(I) + '@example.com'),
         DbParam(A, Money)]);
    end;
    C.Commit;
    LikeI('500 inserts, one statement', 1, C.PreparedCount - ForPrep);
    R := C.ExecParams(A,
      'SELECT name, balance FROM pg_customer WHERE email LIKE $1 ORDER BY id',
      [DbParam(A, 'bulk%')]);
    LikeI('500 rows back', 500, R.RowCount);
    Like('the last row', 'Bulk 500', R.Value(499, 'name').ToString);
    Ok('the decimal on row 400 is right',
      SqlToCurrency(R.Value(399, 'balance'), V) and (V = 100.0));

    { The statement was prepared inside the transaction, and this time
      committed — then it is to still be there. }
    ForPrep := C.PreparedCount;
    Money := 1;
    C.ExecParams(A,
      'INSERT INTO pg_customer (name, email, balance) VALUES ($1, $2, $3)',
      [DbParam(A, 'After_'), DbParam(A, 'etter@example.com'),
       DbParam(A, Money)]);
    LikeI('commit keeps the prepared statement', 0,
      C.PreparedCount - ForPrep);

    Start('what the cache is worth');
    { Not an assertion — a measurement. Time limits in a test suite go
      flaky on a loaded machine, but without a number "prepared statements
      with a cache" is only a claim. }
    C.Exec(A, 'DELETE FROM pg_customer WHERE email LIKE ''bulk%''');
    for I := 1 to 200 do
      C.ExecParams(A, 'SELECT count(*) FROM pg_customer WHERE name = $1',
        [DbParam(A, 'Bulk ' + IntToStr(I))]);

    C.CacheLimit := 0;
    C.FlushStatementCache;
    T0 := MonotonicMs;
    for I := 1 to 2000 do
      C.ExecParams(A, 'SELECT count(*) FROM pg_customer WHERE name = $1',
        [DbParam(A, 'Bulk ' + IntToStr(I))]);
    Without := MonotonicMs - T0;

    C.CacheLimit := 64;
    C.FlushStatementCache;
    T0 := MonotonicMs;
    for I := 1 to 2000 do
      C.ExecParams(A, 'SELECT count(*) FROM pg_customer WHERE name = $1',
        [DbParam(A, 'Bulk ' + IntToStr(I))]);
    With_ := MonotonicMs - T0;

    WriteLn('        2000 queries: ', Without, ' ms without the cache, ',
            With_, ' ms with');
    if With_ > 0 then
      WriteLn('        ', (Without * 100) div With_, ' % of the time without it');
    Ok('the cache did not make it slower', With_ <= Without + (Without div 4));

    C.Exec(A, 'DROP TABLE IF EXISTS pg_order');
    C.Exec(A, 'DROP TABLE IF EXISTS pg_customer');
  finally
    C.Free;
    A.Free;
  end;
end;

{ The pool hands connections to different threads. The cache lives on the
  connection, so two threads must never see each other's statement
  names. }
type
  TPgTraad = class(TThread)
  private
    FPool: TDbPool;
    FRunder: Integer;
    FSum: Int64;
    FErr: string;
  protected
    procedure Execute; override;
  public
    constructor Create(APool: TDbPool; ARunder: Integer);
    property Sum: Int64 read FSum;
    property Err: string read FErr;
  end;

constructor TPgTraad.Create(APool: TDbPool; ARunder: Integer);
begin
  FPool := APool;
  FRunder := ARunder;
  inherited Create(False);
end;

procedure TPgTraad.Execute;
var
  A: TArena;
  C: TDbConnection;
  R: TDbResult;
  I: Integer;
begin
  try
    for I := 1 to FRunder do
    begin
      A := TArena.Create(64 * 1024);
      try
        C := FPool.Lease(A);
        R := C.ExecParams(A, 'SELECT $1::bigint + $2::bigint',
          [DbParam(A, Int64(I)), DbParam(A, Int64(1))]);
        Inc(FSum, R.AsInt64(0, 0));
      finally
        A.Free;
      end;
    end;
  except
    on E: Exception do
      FErr := E.ClassName + ': ' + E.Message;
  end;
end;

{$I queue_db_conc.inc}

procedure PivotStart(const Name: string);
begin
  Start(Name);
end;

procedure PivotOk(const What: string; Cond: Boolean);
begin
  Ok(What, Cond);
end;

{$I pivot.inc}

procedure SessionStart(const Name: string);
begin
  Start(Name);
end;

procedure SessionOk(const What: string; Cond: Boolean);
begin
  Ok(What, Cond);
end;

{$I session_db.inc}

procedure PivotDelen;
var
  C: TDbConnection;
begin
  C := OpenDbConnection(Dsn);
  try
    PivotPart(C);
  finally
    C.Free;
  end;
end;

procedure PoolDelen;
const
  Traader = 4;
  Runder = 50;
var
  P: TDbPool;
  T: array[0..Traader - 1] of TPgTraad;
  I: Integer;
  Sum, Fasit: Int64;
  Err: string;
begin
  Start('pool and threads');
  P := TDbPool.Create(Dsn, 3);
  try
    for I := 0 to Traader - 1 do
      T[I] := TPgTraad.Create(P, Runder);
    Sum := 0;
    Err := '';
    for I := 0 to Traader - 1 do
    begin
      T[I].WaitFor;
      Inc(Sum, T[I].Sum);
      if (Err = '') and (T[I].Err <> '') then
        Err := T[I].Err;
      T[I].Free;
    end;
    if Err <> '' then
      WriteLn('        error from a thread: ', Err);
    Ok('no thread failed', Err = '');
    Fasit := Int64(Traader) * ((Int64(Runder) * (Runder + 1)) div 2 + Runder);
    LikeI('every answer is right', Fasit, Sum);
    LikeI('200 leases in total', Traader * Runder, Int64(P.AcquiredTotal));
    Ok('the pool stayed within its limit', P.LiveCount <= 3);
  finally
    P.Free;
  end;
end;

begin
  Dsn := GetEnvironmentVariable('ASKR_PG_DSN');
  if Dsn = '' then
    Dsn := 'postgresql://askr:askr@127.0.0.1:5433/askr_dev';

  WriteLn('askr — Postgres');
  WriteLn('dsn: ', Dsn);

  if not PgAvailable then
  begin
    WriteLn;
    WriteLn('SKIPPED: libpq is not here.');
    Halt(0);
  end;
  WriteLn('bibliotek: ', PgLibraryName);

  try
    Run_;
    PoolDelen;
    QueuePart(Dsn);
    PivotDelen;
    SessionRacePart(Dsn);
  except
    on E: EDbError do
      if (Pos('could not connect', LowerCase(E.Message)) > 0) or
         (Pos('connection refused', LowerCase(E.Message)) > 0) or
         (Pos('could not translate', LowerCase(E.Message)) > 0) then
      begin
        WriteLn;
        WriteLn('SKIPPED: no Postgres server to talk to.');
        WriteLn('  ', E.Message);
        WriteLn('  Start one with ./askr db:up');
        Halt(0);
      end
      else
        raise;
  end;

  WriteLn;
  WriteLn('— ', Passed, ' passed, ', Failed, ' failed');
  if Failed > 0 then
    Halt(1);
end.
