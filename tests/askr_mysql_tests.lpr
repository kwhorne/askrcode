{ MySQL tests.

  Runs against a real server. Without one, the suite skips itself and says
  why — it does not report green on something it has not tried.

    ./askr db:up        # starts MySQL 8.4 on port 3308
    ./askr mysql        # builds and runs this

  The DSN can be overridden with ASKR_MYSQL_DSN. }
program askr_mysql_tests;

{$mode Delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Clock,
  Classes,
  Askr.Urd.Driver, Askr.Urd.MySql, Askr.Urd.Pool,
  Askr.Norn.Schema, Askr.Norn.Migration, Askr.Norn.Introspect,
  Askr.Queue, Askr.Queue.Db,
  Askr.Core.Json, Askr.Session, Askr.Session.Db, Askr.Urd.Model, Askr.Urd.Query, Askr.Urd.Json;

type
  { One migration that touches everything the introspection has to
    recognise: an auto key, text, boolean, money, a date, a foreign key
    and two indexes. }
  TCreateShop = class(TMigration)
    class function Version: string; override;
    procedure Up(S: TSchemaBuilder); override;
    procedure Down(S: TSchemaBuilder); override;
  end;

class function TCreateShop.Version: string;
begin
  Result := '20260919120000';
end;

procedure TCreateShop.Up(S: TSchemaBuilder);
var
  T: TTableBuilder;
begin
  T := S.Create('norn_customer');
  T.Id;
  T.Text('name', 190);
  T.Text('email', 190).Unique;
  T.Bool('active');
  T.Money('balance').Nullable;
  T.Timestamp('last_seen').Nullable;
  T.Index(['name']);

  T := S.Create('norn_order');
  T.Id;
  T.ForeignKey('customer_id', 'norn_customer');
  T.Money('amount');
  T.Timestamps;
end;

procedure TCreateShop.Down(S: TSchemaBuilder);
begin
  S.Drop('norn_order');
  S.Drop('norn_customer');
end;

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

{ How many prepared statements the server has open right now. }
function OpenStatements_(C: TDbConnection; A: TArena): Int64;
var
  R: TDbResult;
begin
  R := C.Exec(A, 'SHOW GLOBAL STATUS LIKE ''Prepared_stmt_count''');
  if R.RowCount = 0 then
    Exit(-1);
  Result := R.AsInt64(0, 1);
end;

procedure Schema_(C: TDbConnection; A: TArena);
begin
  C.Exec(A, 'DROP TABLE IF EXISTS askr_order');
  C.Exec(A, 'DROP TABLE IF EXISTS askr_customer');
  C.Exec(A,
    'CREATE TABLE askr_customer (' +
    '  id BIGINT AUTO_INCREMENT PRIMARY KEY,' +
    '  name VARCHAR(190) NOT NULL,' +
    '  email VARCHAR(190) NOT NULL UNIQUE,' +
    '  balance DECIMAL(12,2) NULL,' +
    '  active TINYINT(1) NOT NULL DEFAULT 1,' +
    '  note TEXT NULL,' +
    '  weight DOUBLE NULL,' +
    '  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP' +
    ') ENGINE=InnoDB DEFAULT CHARSET=utf8mb4');
  C.Exec(A,
    'CREATE TABLE askr_order (' +
    '  id BIGINT AUTO_INCREMENT PRIMARY KEY,' +
    '  customer_id BIGINT NOT NULL,' +
    '  amount DECIMAL(12,2) NOT NULL,' +
    '  CONSTRAINT fk_order_customer FOREIGN KEY (customer_id)' +
    '    REFERENCES askr_customer(id)' +
    ') ENGINE=InnoDB DEFAULT CHARSET=utf8mb4');
end;

{ The pool is used from worker threads in a real app, so that is where
  the driver actually lives. A connection never goes to two threads at once
  — the pool guarantees that — but it can well go to a different thread
  from the one that opened it, and that is exactly what this test puts it
  through. }
type
  TPoolTraad = class(TThread)
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

constructor TPoolTraad.Create(APool: TDbPool; ARunder: Integer);
begin
  FPool := APool;
  FRunder := ARunder;
  inherited Create(False);
end;

procedure TPoolTraad.Execute;
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
        R := C.ExecParams(A, 'SELECT ? + ?',
          [DbParam(A, Int64(I)), DbParam(A, Int64(1))]);
        Inc(FSum, R.AsInt64(0, 0));
      finally
        { The arena releases the lease through Defer. }
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
  T: array[0..Traader - 1] of TPoolTraad;
  I: Integer;
  Sum, Fasit: Int64;
  Err: string;
begin
  Start('pool and threads');
  P := TDbPool.Create(Dsn, 3);
  try
    for I := 0 to Traader - 1 do
      T[I] := TPoolTraad.Create(P, Runder);
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
    { 4 threads x sum(2..51) }
    Fasit := Int64(Traader) * ((Int64(Runder) * (Runder + 1)) div 2 + Runder);
    LikeI('every answer is right', Fasit, Sum);
    LikeI('200 leases in total', Traader * Runder, Int64(P.AcquiredTotal));
    Ok('the pool stayed within its limit', P.LiveCount <= 3);
    WriteLn('        forbindelser created_at: ', P.CreatedTotal,
            '  forkastet: ', P.DiscardedTotal);
  finally
    P.Free;
  end;
end;

procedure NornDelen(C: TDbConnection; A: TArena);
var
  M: TMigrator;
  Schema_: TDbSchema;
  T: TDbTable;
  Kol: TDbColumn;
  I: Integer;
  FantIndeks: Boolean;
begin
  Start('norn: migration');
  C.Exec(A, 'DROP TABLE IF EXISTS norn_order');
  C.Exec(A, 'DROP TABLE IF EXISTS norn_customer');
  C.Exec(A, 'DROP TABLE IF EXISTS askr_migrations');

  RegisterMigration(TCreateShop);
  M := TMigrator.Create(C);
  try
    LikeI('one migration is pending', 1, M.PendingCount);
    LikeI('one was run', 1, M.Up);
    LikeI('none is pending afterwards', 0, M.PendingCount);
  finally
    M.Free;
  end;

  Start('norn: introspection');
  Schema_ := IntrospectSchema(C);
  try
    Ok('found norn_customer', Schema_.Table('norn_customer') <> nil);
    Ok('found norn_order', Schema_.Table('norn_order') <> nil);

    T := Schema_.Table('norn_customer');
    Like('the primary key is id', 'id', T.PrimaryKey);
    LikeI('six columns', 6, T.ColumnCount);

    Kol := T.Column(T.IndexOfColumn('id'));
    Like('id becomes Int64', 'TColInt64', ColAliasFor(Kol.SqlType, Kol.Scale));
    Ok('id is the primary key', Kol.IsPrimaryKey);

    Kol := T.Column(T.IndexOfColumn('name'));
    Like('varchar becomes a string', 'TColStr', ColAliasFor(Kol.SqlType, Kol.Scale));
    LikeI('the length is there', 190, Kol.MaxLength);
    Ok('name is not nullable', not Kol.Nullable);

    Kol := T.Column(T.IndexOfColumn('active'));
    Like('tinyint(1) becomes boolean', 'TColBool',
      ColAliasFor(Kol.SqlType, Kol.Scale));
    Like('and the Pascal type is Boolean', 'Boolean',
      PascalTypeFor(Kol.SqlType, Kol.Scale));

    Kol := T.Column(T.IndexOfColumn('balance'));
    Like('decimal(12,2) becomes Currency', 'TColCurrency',
      ColAliasFor(Kol.SqlType, Kol.Scale));
    LikeI('the scale is read', 2, Kol.Scale);
    Ok('balance is nullable', Kol.Nullable);

    Kol := T.Column(T.IndexOfColumn('last_seen'));
    Like('datetime becomes TDateTime', 'TColDateTime',
      ColAliasFor(Kol.SqlType, Kol.Scale));

    Ok('email is indexed', T.IsIndexed('email'));
    Ok('name is indexed', T.IsIndexed('name'));
    FantIndeks := False;
    for I := 0 to T.IndexCount - 1 do
      if T.IndexAt(I).IsPrimary then
        FantIndeks := True;
    Ok('the primary key is among the indexes', FantIndeks);
    FantIndeks := False;
    for I := 0 to T.IndexCount - 1 do
      if T.IndexAt(I).IsUnique and (not T.IndexAt(I).IsPrimary) then
        FantIndeks := True;
    Ok('the unique index on email is marked unique', FantIndeks);

    T := Schema_.Table('norn_order');
    LikeI('one foreign key', 1, T.ForeignKeyCount);
    if T.ForeignKeyCount > 0 then
    begin
      Like('points at the right column', 'customer_id', T.ForeignKey(0).Column);
      Like('points at the right table', 'norn_customer', T.ForeignKey(0).RefTable);
      Like('points at the right column in it', 'id', T.ForeignKey(0).RefColumn);
    end;
    Ok('created_at is there', T.HasColumn('created_at'));
  finally
    Schema_.Free;
  end;

  Start('norn: rollback');
  M := TMigrator.Create(C);
  try
    LikeI('one was rolled back', 1, M.Down(1));
  finally
    M.Free;
  end;
  Schema_ := IntrospectSchema(C);
  try
    Ok('norn_customer is gone', Schema_.Table('norn_customer') = nil);
    Ok('norn_order is gone', Schema_.Table('norn_order') = nil);
  finally
    Schema_.Free;
  end;
  C.Exec(A, 'DROP TABLE IF EXISTS askr_migrations');
end;

procedure Run_;
var
  C: TMySqlConnection;
  A: TArena;
  R: TDbResult;
  Id, Id2: Int64;
  Err, Text_: string;
  V, Money: Currency;
  D: TDateTime;
  B: Boolean;
  I: Integer;
  ForPrep, ForHits: Int64;
  B2: TStrBuilder;
  F: Double;
  T0, Without, With_, ForApne: Int64;
begin
  A := TArena.Create;
  C := TMySqlConnection.Create(Dsn);
  try
    Start('connection');
    Ok('alive', C.IsAlive);
    Ok('the dialect is MySQL', C.Dialect = sdMySql);
    Ok('RETURNING does not exist', not C.SupportsReturning);
    R := C.Exec(A, 'SELECT VERSION()');
    WriteLn('        server: ', R.Value(0, 0).ToString,
            '   klient: ', MySqlClientVersion);

    Schema_(C, A);

    Start('insert and id');
    Money := 1234.50;
    Id := C.InsertGetId(A,
      'INSERT INTO askr_customer (name, email, balance) VALUES (?, ?, ?)',
      [DbParam(A, 'Ada'), DbParam(A, 'ada@example.com'),
       DbParam(A, Money)], 'id');
    Ok('got an id back', Id > 0);
    Id2 := C.InsertGetId(A,
      'INSERT INTO askr_customer (name, email, balance) VALUES (?, ?, ?)',
      [DbParam(A, 'Bo'), DbParam(A, 'bo@example.com'), DbNull], 'id');
    LikeI('the next id is one more', Id + 1, Id2);

    Start('reading');
    R := C.ExecParams(A, 'SELECT name, balance, note, active FROM askr_customer ' +
      'WHERE id = ?', [DbParam(A, Id)]);
    LikeI('one row', 1, R.RowCount);
    LikeI('four columns', 4, R.FieldCount);
    Like('column names', 'balance', R.FieldName(1).ToString);
    Like('the name', 'Ada', R.Value(0, 'name').ToString);
    Ok('balance is read as Currency',
      SqlToCurrency(R.Value(0, 'balance'), V) and (V = 1234.50));
    Ok('NULL is NULL', R.IsNull(0, 'note'));
    Ok('an empty string is not NULL for active', not R.IsNull(0, 'active'));
    Ok('boolean is read', SqlToBool(R.Value(0, 'active'), B) and B);

    R := C.ExecParams(A, 'SELECT balance FROM askr_customer WHERE id = ?',
      [DbParam(A, Id2)]);
    Ok('a NULL column with no value', R.IsNull(0, 0));

    Start('text and character sets');
    { utf8mb4 er hele poenget: MySQLs «utf8» klarer ikke firebyte-tegn. }
    Text_ := 'Blåbærsyltetøy 🫐 — ¥€$';
    C.ExecParams(A, 'UPDATE askr_customer SET note = ? WHERE id = ?',
      [DbParam(A, Text_), DbParam(A, Id)]);
    R := C.ExecParams(A, 'SELECT note FROM askr_customer WHERE id = ?',
      [DbParam(A, Id)]);
    Like('four-byte characters survive the round trip', Text_, R.Value(0, 0).ToString);

    Text_ := 'he said "hi"; DROP TABLE x; -- ' + #39 + 'og' + #39;
    C.ExecParams(A, 'UPDATE askr_customer SET note = ? WHERE id = ?',
      [DbParam(A, Text_), DbParam(A, Id)]);
    R := C.ExecParams(A, 'SELECT note FROM askr_customer WHERE id = ?',
      [DbParam(A, Id)]);
    Like('quotes and semicolons are data, not SQL', Text_,
      R.Value(0, 0).ToString);

    Start('floats and computed columns');
    { This part exists because it caught a real bug: a DOUBLE comes over
      the prepared protocol in binary, and an earlier version of the
      result reading gave an empty value for everything that was not
      text. The tables above hid it, because VARCHAR, DECIMAL and BIGINT
      are sent as text. }
    C.ExecParams(A, 'UPDATE askr_customer SET weight = ? WHERE id = ?',
      [DbParam(A, '72.5'), DbParam(A, Id)]);
    R := C.ExecParams(A, 'SELECT weight FROM askr_customer WHERE id = ?',
      [DbParam(A, Id)]);
    Ok('a DOUBLE column comes back with a value', R.Value(0, 0).Len > 0);
    Ok('and can be read as a float',
      SqlToFloat(R.Value(0, 0), F) and (Abs(F - 72.5) < 0.0001));

    R := C.ExecParams(A, 'SELECT ? + ?',
      [DbParam(A, Int64(3)), DbParam(A, Int64(4))]);
    LikeI('a computed expression with no table', 7, R.AsInt64(0, 0));

    R := C.ExecParams(A, 'SELECT AVG(balance) FROM askr_customer WHERE id IN (?, ?)',
      [DbParam(A, Id), DbParam(A, Id2)]);
    Ok('an aggregate over DECIMAL gives a value', R.Value(0, 0).Len > 0);

    { Longer than the fixed 192-byte buffer — forces a second round. }
    Text_ := '';
    for I := 1 to 200 do
      Text_ := Text_ + 'æ';   { 400 bytes in UTF-8 }
    C.ExecParams(A, 'UPDATE askr_customer SET note = ? WHERE id = ?',
      [DbParam(A, Text_), DbParam(A, Id)]);
    R := C.ExecParams(A, 'SELECT note FROM askr_customer WHERE id = ?',
      [DbParam(A, Id)]);
    Like('long text is fetched in the second round', Text_, R.Value(0, 0).ToString);

    Start('dates');
    R := C.ExecParams(A, 'SELECT created_at FROM askr_customer WHERE id = ?',
      [DbParam(A, Id)]);
    Ok('DATETIME can be read', SqlToDateTime(R.Value(0, 0), D) and (D > 40000));

    Start('affected rows');
    R := C.ExecParams(A, 'UPDATE askr_customer SET name = ? WHERE id = ?',
      [DbParam(A, 'Ada L.'), DbParam(A, Id)]);
    LikeI('one row changed', 1, R.AffectedRows);
    { CLIENT_FOUND_ROWS: an update with no actual change is to still
      report that the row was matched. }
    R := C.ExecParams(A, 'UPDATE askr_customer SET name = ? WHERE id = ?',
      [DbParam(A, 'Ada L.'), DbParam(A, Id)]);
    LikeI('an unchanged update still counts the row', 1, R.AffectedRows);
    R := C.ExecParams(A, 'UPDATE askr_customer SET name = ? WHERE id = ?',
      [DbParam(A, 'x'), DbParam(A, Int64(999999))]);
    LikeI('no match gives null', 0, R.AffectedRows);

    Start('errors that are to be recognised');
    Err := '';
    try
      C.ExecParams(A,
        'INSERT INTO askr_customer (name, email) VALUES (?, ?)',
        [DbParam(A, 'Kopi'), DbParam(A, 'ada@example.com')]);
    except
      on E: EDbError do
      begin
        Err := E.SqlState;
        Ok('a unique violation is recognised', E.IsUniqueViolation);
      end;
    end;
    Like('translated to 23505', '23505', Err);

    Err := '';
    try
      Money := 10;
      C.ExecParams(A, 'INSERT INTO askr_order (customer_id, amount) VALUES (?, ?)',
        [DbParam(A, Int64(999999)), DbParam(A, Money)]);
    except
      on E: EDbError do
      begin
        Err := E.SqlState;
        Ok('a foreign key violation is recognised', E.IsForeignKeyViolation);
      end;
    end;
    Like('translated to 23503', '23503', Err);

    Start('transactions');
    C.StartTransaction;
    Ok('knows it is in a transaction', C.InTransaction);
    C.ExecParams(A, 'INSERT INTO askr_customer (name, email) VALUES (?, ?)',
      [DbParam(A, 'Midlertidig'), DbParam(A, 'midl@example.com')]);
    C.Rollback;
    Ok('out of the transaction again', not C.InTransaction);
    R := C.ExecParams(A, 'SELECT count(*) FROM askr_customer WHERE email = ?',
      [DbParam(A, 'midl@example.com')]);
    LikeI('rollback removed the row', 0, R.AsInt64(0, 0));

    C.StartTransaction;
    C.ExecParams(A, 'INSERT INTO askr_customer (name, email) VALUES (?, ?)',
      [DbParam(A, 'Varig'), DbParam(A, 'varig@example.com')]);
    C.Commit;
    R := C.ExecParams(A, 'SELECT count(*) FROM askr_customer WHERE email = ?',
      [DbParam(A, 'varig@example.com')]);
    LikeI('commit kept the row', 1, R.AsInt64(0, 0));

    Start('the statement cache');
    ForPrep := C.PreparedCount;
    ForHits := C.CacheHits;
    for I := 1 to 20 do
      C.ExecParams(A, 'SELECT name FROM askr_customer WHERE id = ?',
        [DbParam(A, Id)]);
    LikeI('the same query is prepared once', 1, C.PreparedCount - ForPrep);
    LikeI('the rest hit the cache', 19, C.CacheHits - ForHits);

    { The server's own number, not ours. Without this our cache counters
      could be right while statements piled up on the server — and that is
      exactly what happened before uncached statements were closed. }
    ForApne := OpenStatements_(C, A);
    C.CacheLimit := 0;
    ForPrep := C.PreparedCount;
    for I := 1 to 50 do
      C.ExecParams(A, 'SELECT email FROM askr_customer WHERE id = ?',
        [DbParam(A, Id)]);
    LikeI('the cache off: prepared every time', 50, C.PreparedCount - ForPrep);
    LikeI('but none is left open on the server', 0,
      OpenStatements_(C, A) - ForApne);
    C.CacheLimit := 64;

    ForApne := OpenStatements_(C, A);
    for I := 1 to 50 do
      C.ExecParams(A, 'SELECT name FROM askr_customer WHERE email = ?',
        [DbParam(A, 'ada@example.com')]);
    LikeI('with the cache: exactly one is open', 1,
      OpenStatements_(C, A) - ForApne);

    Start('many rows');
    C.Exec(A, 'DELETE FROM askr_customer WHERE email LIKE ''bulk%''');
    C.StartTransaction;
    for I := 1 to 500 do
    begin
      { Assigned, never cast: Currency(I) is a reinterpretation of the
        scaled Int64 on x86_64, not a conversion. }
      Money := I;
      Money := Money / 4;
      C.ExecParams(A,
        'INSERT INTO askr_customer (name, email, balance) VALUES (?, ?, ?)',
        [DbParam(A, 'Bulk ' + IntToStr(I)),
         DbParam(A, 'bulk' + IntToStr(I) + '@example.com'),
         DbParam(A, Money)]);
    end;
    C.Commit;
    R := C.ExecParams(A, 'SELECT id, name, balance FROM askr_customer ' +
      'WHERE email LIKE ? ORDER BY id', [DbParam(A, 'bulk%')]);
    LikeI('500 rows back', 500, R.RowCount);
    Like('the first row', 'Bulk 1', R.Value(0, 'name').ToString);
    Like('the last row', 'Bulk 500', R.Value(499, 'name').ToString);
    Ok('the decimal on row 400 is right',
      SqlToCurrency(R.Value(399, 'balance'), V) and (V = 100.0));
    Ok('all the values are in the arena',
      A.Owns(R.Value(0, 'name').Data) and A.Owns(R.Value(499, 'name').Data));

    Start('what the cache is worth');
    { A measurement, not an assertion. Time limits in a suite go flaky on
      a loaded machine, but "prepared statements with a cache" is empty
      talk without a number behind it. }
    C.CacheLimit := 0;
    C.FlushStatementCache;
    T0 := MonotonicMs;
    for I := 1 to 2000 do
      C.ExecParams(A, 'SELECT count(*) FROM askr_customer WHERE name = ?',
        [DbParam(A, 'Bulk ' + IntToStr(I))]);
    Without := MonotonicMs - T0;

    C.CacheLimit := 64;
    C.FlushStatementCache;
    T0 := MonotonicMs;
    for I := 1 to 2000 do
      C.ExecParams(A, 'SELECT count(*) FROM askr_customer WHERE name = ?',
        [DbParam(A, 'Bulk ' + IntToStr(I))]);
    With_ := MonotonicMs - T0;

    WriteLn('        2000 queries: ', Without, ' ms without the cache, ',
            With_, ' ms with');
    Ok('the cache did not make it slower', With_ <= Without + (Without div 4));

    Start('an empty result');
    R := C.ExecParams(A, 'SELECT name FROM askr_customer WHERE id = ?',
      [DbParam(A, Int64(-1))]);
    Ok('no rows', R.IsEmpty);
    LikeI('but the column is there', 1, R.FieldCount);

    Start('identifiers and placeholders');
    B2.Init(A);
    C.AppendIdentStr(B2, 'tabell`name');
    Like('a backtick is quoted, and a backtick inside is doubled',
      '`tabell``name`', B2.ToStr.ToString);
    B2.Init(A);
    C.AppendPlaceholder(B2, 1);
    C.AppendPlaceholder(B2, 2);
    Like('placeholders are question marks', '??', B2.ToStr.ToString);
    R := C.Exec(A, 'SELECT `name` FROM `askr_customer` LIMIT 1');
    Ok('a backtick-quoted query works', R.RowCount = 1);

    C.Exec(A, 'DROP TABLE IF EXISTS askr_order');
    C.Exec(A, 'DROP TABLE IF EXISTS askr_customer');

    NornDelen(C, A);
  finally
    C.Free;
    A.Free;
  end;
  PoolDelen;
  QueuePart(Dsn);
  PivotDelen;
  SessionRacePart(Dsn);
end;

begin
  Dsn := GetEnvironmentVariable('ASKR_MYSQL_DSN');
  if Dsn = '' then
    Dsn := 'mysql://askr:askr@127.0.0.1:3308/askr_dev';

  WriteLn('askr — MySQL');
  WriteLn('dsn: ', Dsn);

  if not MySqlAvailable then
  begin
    WriteLn;
    WriteLn('SKIPPED: the MySQL client library is not here.');
    try
      TMySqlConnection.Create(Dsn);
    except
      on E: Exception do WriteLn('  ', E.Message);
    end;
    Halt(0);
  end;
  WriteLn('bibliotek: ', MySqlLibraryName);

  try
    Run_;
  except
    on E: EDbError do
      if Pos('Could not connect', E.Message) > 0 then
      begin
        WriteLn;
        WriteLn('SKIPPED: no MySQL server to talk to.');
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
