{ A spike: libpq over the C ABI, with the result in the arena.

  The PRD calls C ABI interop the single biggest risk in the project. This
  program exists to kill it, and to answer what was actually unresolved:
  who owns the rows when destructors never run.

  Run with `./askr spike`. The DSN can be overridden with ASKR_PG_DSN. }
program PgSpike;

{$mode Delphi}{$H+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  SysUtils,
  Askr.Core.Arena, Askr.Core.Text, Askr.Urd.Driver, Askr.Urd.Pg;

var
  Err: Integer = 0;

procedure Si(const Etikett, Value_: string);
var
  Pad: string;
begin
  Pad := Etikett;
  while Length(Pad) < 34 do
    Pad := Pad + ' ';
  WriteLn('  ', Pad, Value_);
end;

procedure Expect(Betingelse: Boolean; const What: string);
begin
  if Betingelse then
    WriteLn('  ok   ', What)
  else
  begin
    Inc(Err);
    WriteLn('  FEIL ', What);
  end;
end;

{ Used to show that Defer really does run on Reset. }
var
  CleanedCount: Integer = 0;

procedure CountCleanup(Data: Pointer);
begin
  Inc(CleanedCount);
end;

function VisNull(R: TDbResult; Row: Integer; const Field_: string): string;
begin
  if R.IsNull(Row, R.IndexOfField(Field_)) then
    Result := '<null>'
  else
    Result := R.Value(Row, Field_).ToString;
end;

function Dsn: string;
begin
  Result := GetEnvironmentVariable('ASKR_PG_DSN');
  if Result = '' then
    Result := 'postgresql://askr:askr@127.0.0.1:5433/askr_dev';
end;

var
  A: TArena;
  C: TPgConnection;
  R: TDbResult;
  I: Integer;
  AfterSetup: PtrUInt;
begin
  WriteLn('Askr — spike: libpq, C-ABI og arena');
  WriteLn;

  { 1. Does the library load at all? }
  WriteLn('Biblioteket');
  Expect(PgAvailable, 'libpq loaded with dlopen');
  if not PgAvailable then
  begin
    WriteLn;
    WriteLn('  Without libpq stopper spiken her. Feilmeldingen fra laster:');
    try
      C := TPgConnection.Create(Dsn);
      C.Free;
    except
      on E: Exception do
        WriteLn('  ', E.Message);
    end;
    Halt(1);
  end;
  Si('lastet fra', PgLibraryName);
  WriteLn;

  A := TArena.Create(64 * 1024);
  try
    { 2. The connection. It is not an arena object — it lives on the
      heap. }
    WriteLn('Forbindelse');
    C := TPgConnection.Create(Dsn);
    try
      Expect(C.IsAlive, 'koblet til');
      Si('serverversjon', IntToStr(C.ServerVersion));
      WriteLn;

      { 3. The simplest thing that can be called a query. }
      WriteLn('SELECT 1');
      R := C.Exec(A, 'SELECT 1 AS ett');
      Expect(R.RowCount = 1, 'én rad');
      Expect(R.FieldCount = 1, 'én kolonne');
      Expect(R.FieldName(0).EqualsStr('ett'), 'the column name came along');
      Expect(R.Value(0, 0).EqualsStr('1'), 'verdien er 1');
      Si('the value as a TStr', R.Value(0, 0).ToString);
      WriteLn;

      { 4. Ekte data: DDL, parametre, UTF-8, NULL og typer. }
      WriteLn('A round trip with parameters');
      C.Exec(A, 'DROP TABLE IF EXISTS spike_customers');
      C.Exec(A,
        'CREATE TABLE spike_customers (' +
        '  id BIGSERIAL PRIMARY KEY,' +
        '  name TEXT NOT NULL,' +
        '  email TEXT UNIQUE,' +
        '  balance NUMERIC(12,2) NOT NULL DEFAULT 0' +
        ')');

      R := C.ExecParams(A,
        'INSERT INTO spike_customers (name, email, balance) ' +
        'VALUES ($1, $2, $3) RETURNING id',
        [DbParam(A, 'Ada Lovelace'), DbParam(A, 'ada@example.com'),
         DbParam(A, '1234.50')]);
      Expect(R.RowCount = 1, 'RETURNING gave the id back');
      Si('ny id', R.Value(0, 'id').ToString);

      C.ExecParams(A,
        'INSERT INTO spike_customers (name, email) VALUES ($1, $2)',
        [DbParam(A, 'Without email'), DbNull]);

      R := C.Exec(A,
        'SELECT id, name, email, balance FROM spike_customers ORDER BY id');
      Expect(R.RowCount = 2, 'to rader');
      Expect(R.Value(0, 'name').EqualsStr('Ada Lovelace'),
        'UTF-8 survived the round trip');
      Expect(R.Value(0, 'balance').EqualsStr('1234.50'),
        'NUMERIC came back without rounding');
      Expect(R.IsNull(1, R.IndexOfField('email')), 'NULL skilles fra tom streng');
      Expect(not R.IsNull(0, R.IndexOfField('email')), 'not-NULL is not NULL');

      WriteLn;
      WriteLn('  rader:');
      for I := 0 to R.RowCount - 1 do
        WriteLn(Format('    id=%s name=%s email=%s balance=%s',
          [R.Value(I, 'id').ToString,
           R.Value(I, 'name').ToString,
           VisNull(R, I, 'email'),
           R.Value(I, 'balance').ToString]));
      WriteLn;

      { 5. An error is to come back as EDbError with a SQLSTATE, not as a
        500. }
      WriteLn('Error handling');
      try
        C.ExecParams(A,
          'INSERT INTO spike_customers (name, email) VALUES ($1, $2)',
          [DbParam(A, 'Duplikat'), DbParam(A, 'ada@example.com')]);
        Expect(False, 'the unique violation should have raised');
      except
        on E: EDbError do
        begin
          Expect(E.SqlState = '23505', 'a unique violation gives SQLSTATE 23505');
          Si('sqlstate', E.SqlState);
        end;
      end;

      try
        C.Exec(A, 'SELECT * FROM finnes_ikke');
        Expect(False, 'the unknown table should have raised');
      except
        on E: EDbError do
          Expect(E.SqlState = '42P01', 'an unknown table gives SQLSTATE 42P01');
      end;

      Expect(C.IsAlive, 'the connection is alive after two errors');
      WriteLn;

      { 6. Transaksjon. }
      WriteLn('Transaksjon');
      C.StartTransaction;
      C.ExecParams(A, 'INSERT INTO spike_customers (name) VALUES ($1)',
        [DbParam(A, 'Rolled back')]);
      R := C.Exec(A, 'SELECT count(*) FROM spike_customers');
      Expect(R.Value(0, 0).EqualsStr('3'), 'the row is visible inside the transaction');
      C.Rollback;
      R := C.Exec(A, 'SELECT count(*) FROM spike_customers');
      Expect(R.Value(0, 0).EqualsStr('2'), 'ROLLBACK removed it again');
      WriteLn;

      { 7. The arena: everything above is in it, and disappears in one
        operation. }
      WriteLn('Arena');
      AfterSetup := A.BytesLive;
      Si('bytes in use after everything above', IntToStr(AfterSetup));
      Si('bytes reserved from the OS', IntToStr(A.BytesReserved));
      Si('blokker', IntToStr(A.BlockCount));

      A.Defer(CountCleanup, nil);
      A.Defer(CountCleanup, nil);
      A.Reset;
      Expect(A.BytesLive = 0, 'Reset released the whole result set');
      Expect(CleanedCount = 2, 'Defer ran the cleanup on Reset');

      { 8. A thousand queries must not make the arena grow. }
      WriteLn;
      WriteLn('A thousand queries');
      for I := 1 to 50 do
      begin
        A.Reset;
        C.ExecParams(A, 'SELECT id, name, email, balance FROM spike_customers WHERE id >= $1',
          [DbParam(A, Int64(0))]);
      end;
      AfterSetup := A.BytesReserved;
      for I := 1 to 1000 do
      begin
        A.Reset;
        C.ExecParams(A, 'SELECT id, name, email, balance FROM spike_customers WHERE id >= $1',
          [DbParam(A, Int64(0))]);
      end;
      Expect(A.BytesReserved = AfterSetup,
        'the arena did not grow over 1000 queries');
      Si('reserved after 1050 queries', IntToStr(A.BytesReserved));
      Si('peak per query', IntToStr(A.HighWaterMark));

      C.Exec(A, 'DROP TABLE IF EXISTS spike_customers');
    finally
      C.Free;
    end;
  finally
    A.Free;
  end;

  WriteLn;
  if Err = 0 then
    WriteLn('The spike holds. The C ABI risk is dead.')
  else
  begin
    WriteLn(Err, ' feil.');
    Halt(1);
  end;
end.
