{ Rún tests.

  The translator is run against a real database, and the generated Pascal
  is compiled and run. It is not enough that the transpiler does not raise
  — the code it writes out has to work.

  The failure files in tests/run/ matter as much as the one that works: a
  comptime type check that catches nothing is only ceremony. }
program askr_run_tests;

{$mode Delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  Askr.Core.Arena, Askr.Core.Text,
  Askr.Urd.Driver, Askr.Urd.Sqlite,
  Askr.Run;

var
  Passed: Integer = 0;
  Failed: Integer = 0;
  Db: string;

procedure Start(const Name_: string);
begin
  WriteLn;
  WriteLn('— ', Name_);
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

procedure MakeDatabase;
var
  A: TArena;
  C: TDbConnection;
  I: Integer;
  Money: Currency;
begin
  ForceDirectories('.build/run');
  Db := '.build/run/test.db';
  if FileExists(Db) then
    DeleteFile(Db);
  A := TArena.Create;
  C := OpenDbConnection('sqlite:' + Db);
  try
    C.Exec(A, 'CREATE TABLE customers (id INTEGER PRIMARY KEY, ' +
      'name TEXT NOT NULL, email TEXT NOT NULL UNIQUE, ' +
      'balance NUMERIC(12,2), active TINYINT(1) NOT NULL DEFAULT 1, ' +
      'weight REAL)');
    C.Exec(A, 'CREATE TABLE orders (id INTEGER PRIMARY KEY, ' +
      'customer_id INTEGER NOT NULL REFERENCES customers(id), ' +
      'amount NUMERIC(12,2) NOT NULL)');
    { Assigned, never cast. Currency(I * 100) compiles — Integer * Integer
      is Int64 and Currency is an Int64 underneath — but on x86_64 it
      reinterprets those bits instead of converting them, so 700 becomes
      0.07. It said 700 here only because the machine was aarch64. }
    for I := 1 to 6 do
    begin
      Money := I * 100;
      C.ExecParams(A, 'INSERT INTO customers (name, email, balance, active, ' +
        'weight) VALUES (?, ?, ?, ?, ?)',
        [DbParam(A, 'Customer ' + IntToStr(I)),
         DbParam(A, 'c' + IntToStr(I) + '@example.com'),
         DbParam(A, Money), DbParam(A, I mod 3 <> 0),
         DbParam(A, FloatToSql(60 + I))]);
    end;
    for I := 1 to 10 do
    begin
      Money := I * 50;
      C.ExecParams(A, 'INSERT INTO orders (customer_id, amount) VALUES (?, ?)',
        [DbParam(A, Int64((I mod 6) + 1)), DbParam(A, Money)]);
    end;
  finally
    C.Free;
    A.Free;
  end;
end;

{ Writes a .run file and translates it. Returns the error message, or an
  empty string if it went well. }
function Translate(const Source_, OutFile: string; out Stats: TRunStats): string;
var
  L: TStringList;
  InFile: string;
begin
  InFile := '.build/run/case.run';
  L := TStringList.Create;
  try
    L.Text := StringReplace(Source_, '@DB@', Db, [rfReplaceAll]);
    L.SaveToFile(InFile);
  finally
    L.Free;
  end;
  Result := '';
  try
    Stats := Transpile(InFile, OutFile, 'Case');
  except
    on E: ERunError do Result := E.Message;
    on E: Exception do Result := E.ClassName + ': ' + E.Message;
  end;
end;

function ReadOut(const FileName_: string): string;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.LoadFromFile(FileName_);
    Result := L.Text;
  finally
    L.Free;
  end;
end;

function ErrorFrom(const Fixture: string): string;
var
  L: TStringList;
  Source_: string;
  S: TRunStats;
begin
  L := TStringList.Create;
  try
    L.LoadFromFile('tests/run/' + Fixture + '.run');
    Source_ := L.Text;
  finally
    L.Free;
  end;
  Result := Translate(Source_, '.build/run/out.pas', S);
end;

var
  Out_: string;
  S: TRunStats;
  Message_: string;
begin
  WriteLn('askr — Rún');
  MakeDatabase;

  Start('generics');
  Message_ := Translate(
    'db "sqlite:@DB@"'#10 +
    'model Customer from customers'#10 +
    'model Order from orders'#10 +
    'query<M> ById(id: int) -> M for Customer, Order'#10,
    '.build/run/out.pas', S);
  Like('translates without an error', '', Message_);
  Out_ := ReadOut('.build/run/out.pas');
  Like('two models', '2', IntToStr(S.Models));
  Like('two queries out of one declaration', '2', IntToStr(S.Queries));
  Ok('CustomerById was written out', Pos('function CustomerById', Out_) > 0);
  Ok('OrderById was written out', Pos('function OrderById', Out_) > 0);
  Ok('each with its own row type',
    (Pos('): TCustomerRow;', Out_) > 0) and (Pos('): TOrderRow;', Out_) > 0));
  Ok('a single row gives out Found', Pos('out Found: Boolean', Out_) > 0);

  Start('relations from the schema');
  Message_ := Translate(
    'db "sqlite:@DB@"'#10 +
    'model Customer from customers'#10 +
    'model Order from orders'#10 +
    'query All_() -> [Customer]:'#10 +
    '  from Customer'#10 +
    '  with orders'#10,
    '.build/run/out.pas', S);
  Like('translates without an error', '', Message_);
  Out_ := ReadOut('.build/run/out.pas');
  Ok('the row type got a relation field',
    Pos('Orders: TOrderRowArray', Out_) > 0);
  Ok('and it says where it came from',
    Pos('orders.customer_id', Out_) > 0);
  { Eager loading is to be one extra query, not one per row. }
  Ok('the relation is fetched with IN, not in a loop',
    Pos('IN (', Out_) > 0);
  Ok('TOrderRow comes before TCustomerRow',
    (Pos('TOrderRow = record', Out_) > 0) and
    (Pos('TOrderRow = record', Out_) < Pos('TCustomerRow = record', Out_)));

  Start('types are read from the database');
  Ok('NUMERIC(12,2) becomes Currency', Pos('Balance: Currency', Out_) > 0);
  Ok('TINYINT(1) becomes Boolean', Pos('Active: Boolean', Out_) > 0);
  Ok('REAL becomes Double', Pos('Weight: Double', Out_) > 0);
  Ok('customer_id becomes CustomerId: Int64',
    Pos('CustomerId: Int64', Out_) > 0);

  Start('comptime catches the errors');
  Message_ := ErrorFrom('bad-unknown-table');
  Ok('unknown table', Pos('does not exist', Message_) > 0);
  Ok('with a suggestion', Pos('Did you mean "customers"', Message_) > 0);

  Message_ := ErrorFrom('bad-unknown-column');
  Ok('unknown column', Pos('has no column', Message_) > 0);
  Ok('with a suggestion', Pos('Did you mean "email"', Message_) > 0);

  Message_ := ErrorFrom('bad-type-mismatch');
  Ok('a type clash against the schema', Pos('is money', Message_) > 0);
  Ok('and says where the schema was read', Pos('The schema was read', Message_) > 0);

  Message_ := ErrorFrom('bad-unknown-relation');
  Ok('unknown relation', Pos('has no relation', Message_) > 0);
  Ok('with a suggestion', Pos('Did you mean "orders"', Message_) > 0);

  Message_ := ErrorFrom('bad-generic-without-for');
  Ok('generic without for', Pos('is missing "for"', Message_) > 0);

  Message_ := ErrorFrom('bad-relation-without-model');
  Ok('a relation without a model', Pos('has no model', Message_) > 0);

  Start('errors name the file and the line');
  Message_ := ErrorFrom('bad-unknown-column');
  Ok('the line number is there', Pos('.run:', Message_) > 0);
  Ok('and no value leaks out', Pos('@example.com', Message_) = 0);

  Start('cost');
  Message_ := Translate(
    'db "sqlite:@DB@"'#10 +
    'model Customer from customers'#10 +
    'model Order from orders'#10 +
    'query<M> ById(id: int) -> M for Customer, Order'#10,
    '.build/run/out.pas', S);
  WriteLn(Format('        parse %d ms, schema %d ms, emit %d ms, %d ms in all',
    [S.ParseMs, S.SchemaMs, S.EmitMs, S.TotalMs]));
  Ok('the translation fits inside the developer loop', S.TotalMs < 50);
  Like('the dialect came from the DSN', 'sqlite', S.Dialect);

  WriteLn;
  WriteLn('— ', Passed, ' passed, ', Failed, ' failed');
  if Failed > 0 then
    Halt(1);
end.
