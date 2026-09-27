{ The test sandbox, shared by the SQLite, Postgres and MySQL suites.

  It drives Askr.Testing's own runner: three tests registered, run, and
  the database looked at afterwards. The one that matters is MySQL's: a
  CREATE TABLE there commits the transaction the test was in, the
  rollback afterwards takes back nothing, and the rows the test wrote
  stay. The sandbox cannot prevent that. What it must do is say so, on
  that test, rather than let the next test find a row it did not write.

  Each suite defines SandboxStart(Name) and SandboxOk(What, Cond) before
  including it, and calls SandboxPart with an open connection. }

var
  SbConn: TDbConnection;

procedure SbExec(const Sql: string);
var
  A: TArena;
begin
  A := TArena.Create(4096);
  try
    SbConn.Exec(A, Sql);
  finally
    A.Free;
  end;
end;

function SbCount(const Table: string): Int64;
var
  A: TArena;
begin
  A := TArena.Create(4096);
  try
    Result := SbConn.Exec(A, 'SELECT count(*) FROM ' + Table).AsInt64(0, 0);
  finally
    A.Free;
  end;
end;

procedure SbWrites;
begin
  SbExec('INSERT INTO sb_items (id, name) VALUES (1, ''written'')');
  AssertEqual(SbCount('sb_items'), 1, 'the test sees its own row');
end;

procedure SbSeesNothing;
begin
  { The same id as the test before: a leak would be a unique violation
    here, not merely a count. }
  AssertEqual(SbCount('sb_items'), 0, 'the test before left nothing');
  SbExec('INSERT INTO sb_items (id, name) VALUES (1, ''again'')');
end;

procedure SbCommitsByHand;
begin
  SbExec('INSERT INTO sb_items (id, name) VALUES (2, ''committed'')');
  SbConn.Commit;
end;

{ MySQL only: DDL commits the transaction it is in. }
procedure SbDdl;
begin
  SbExec('INSERT INTO sb_items (id, name) VALUES (3, ''before the ddl'')');
  SbExec('CREATE TABLE sb_extra (id INTEGER PRIMARY KEY)');
  SbExec('DROP TABLE sb_extra');
end;

procedure SbAfterTheLeak;
begin
  AssertTrue(True, 'a test after a leak runs in a sandbox of its own');
end;

procedure SandboxPart(C: TDbConnection);
var
  Failures, Expected: Integer;
  DdlSaid: Boolean;
begin
  SandboxStart('the test sandbox: a rolled-back transaction per test');
  SbConn := C;
  SbExec('DROP TABLE IF EXISTS sb_items');
  SbExec('CREATE TABLE sb_items (id INTEGER PRIMARY KEY, name VARCHAR(40) NOT NULL)');

  ClearTests;
  Sandbox(C);
  Test('writes a row', @SbWrites);
  Test('sees none of it', @SbSeesNothing);
  Test('commits by hand', @SbCommitsByHand);
  Expected := 1;
  if C.Dialect = sdMySql then
  begin
    Test('runs DDL', @SbDdl);
    Inc(Expected);
  end;
  Test('runs after the leak', @SbAfterTheLeak);
  Failures := RunTests;
  DdlSaid := Pos('MySQL', LastFailure) > 0;
  StopSandbox;

  SandboxOk('the tests that left nothing passed, and each that committed failed',
    Failures = Expected);
  SandboxOk('it named what happened', Pos('committed', LastFailure) > 0);
  if C.Dialect = sdMySql then
    SandboxOk('and on MySQL, that DDL is the likeliest reason', DdlSaid);
  SandboxOk('the rows the commits let through are still there, as it said',
    SbCount('sb_items') = Expected);
  SandboxOk('and no sandbox transaction is left open', not C.InTransaction);
  SbExec('DROP TABLE sb_items');
  ClearTests;
end;
