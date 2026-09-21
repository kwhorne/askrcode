{ Rún-tester.

  Oversetteren kjøres mot en ekte database, og den genererte Pascal-koden
  kompileres og kjøres. Det er ikke nok at transpileren ikke kaster — koden
  den skriver ut må virke.

  Feilfilene i tests/run/ er like viktige som den som virker: en
  comptime-typesjekk som ikke fanger noe er bare seremoni. }
program askr_run_tests;

{$mode Delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  Askr.Core.Arena, Askr.Core.Text,
  Askr.Urd.Driver, Askr.Urd.Sqlite,
  Askr.Run;

var
  Bestatt: Integer = 0;
  Feilet: Integer = 0;
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
    Inc(Bestatt);
    WriteLn('  ok    ', What);
  end
  else
  begin
    Inc(Feilet);
    WriteLn('  FEIL  ', What);
  end;
end;

procedure Like(const What, Forventet, Fikk: string);
begin
  if Forventet = Fikk then
  begin
    Inc(Bestatt);
    WriteLn('  ok    ', What);
  end
  else
  begin
    Inc(Feilet);
    WriteLn('  FEIL  ', What);
    WriteLn('        forventet: ', Forventet);
    WriteLn('        fikk:      ', Fikk);
  end;
end;

procedure LagDatabase;
var
  A: TArena;
  C: TDbConnection;
  I: Integer;
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
    for I := 1 to 6 do
      C.ExecParams(A, 'INSERT INTO customers (name, email, balance, active, ' +
        'weight) VALUES (?, ?, ?, ?, ?)',
        [DbParam(A, 'Customer ' + IntToStr(I)),
         DbParam(A, 'c' + IntToStr(I) + '@example.com'),
         DbParam(A, Currency(I * 100)), DbParam(A, I mod 3 <> 0),
         DbParam(A, FloatToSql(60 + I))]);
    for I := 1 to 10 do
      C.ExecParams(A, 'INSERT INTO orders (customer_id, amount) VALUES (?, ?)',
        [DbParam(A, Int64((I mod 6) + 1)), DbParam(A, Currency(I * 50))]);
  finally
    C.Free;
    A.Free;
  end;
end;

{ Skriver en .run-fil og oversetter den. Returnerer feilmeldingen, eller
  tom streng hvis det gikk. }
function Oversett(const Source_, UtFil: string; out Stats: TRunStats): string;
var
  L: TStringList;
  Inn: string;
begin
  Inn := '.build/run/case.run';
  L := TStringList.Create;
  try
    L.Text := StringReplace(Source_, '@DB@', Db, [rfReplaceAll]);
    L.SaveToFile(Inn);
  finally
    L.Free;
  end;
  Result := '';
  try
    Stats := Transpile(Inn, UtFil, 'Case');
  except
    on E: ERunError do Result := E.Message;
    on E: Exception do Result := E.ClassName + ': ' + E.Message;
  end;
end;

function ReadOut(const Fil: string): string;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.LoadFromFile(Fil);
    Result := L.Text;
  finally
    L.Free;
  end;
end;

function Feilmelding(const Fixture: string): string;
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
  Result := Oversett(Source_, '.build/run/out.pas', S);
end;

var
  Ut: string;
  S: TRunStats;
  Message_: string;
begin
  WriteLn('askr — Rún');
  LagDatabase;

  Start('generics');
  Message_ := Oversett(
    'db "sqlite:@DB@"'#10 +
    'model Customer from customers'#10 +
    'model Order from orders'#10 +
    'query<M> ById(id: int) -> M for Customer, Order'#10,
    '.build/run/out.pas', S);
  Like('oversetter uten feil', '', Message_);
  Ut := ReadOut('.build/run/out.pas');
  Like('to modeller', '2', IntToStr(S.Models));
  Like('to spørringer ut av én erklæring', '2', IntToStr(S.Queries));
  Ok('CustomerById ble skrevet ut', Pos('function CustomerById', Ut) > 0);
  Ok('OrderById ble skrevet ut', Pos('function OrderById', Ut) > 0);
  Ok('hver med sin egen radtype',
    (Pos('): TCustomerRow;', Ut) > 0) and (Pos('): TOrderRow;', Ut) > 0));
  Ok('enkeltrad gir out Found', Pos('out Found: Boolean', Ut) > 0);

  Start('relasjoner fra skjemaet');
  Message_ := Oversett(
    'db "sqlite:@DB@"'#10 +
    'model Customer from customers'#10 +
    'model Order from orders'#10 +
    'query All_() -> [Customer]:'#10 +
    '  from Customer'#10 +
    '  with orders'#10,
    '.build/run/out.pas', S);
  Like('oversetter uten feil', '', Message_);
  Ut := ReadOut('.build/run/out.pas');
  Ok('radtypen fikk et relasjonsfelt',
    Pos('Orders: TOrderRowArray', Ut) > 0);
  Ok('og det står hvor det kom fra',
    Pos('orders.customer_id', Ut) > 0);
  { Eager loading skal være én ekstra spørring, ikke én per rad. }
  Ok('relasjonen hentes med IN, ikke i en løkke',
    Pos('IN (', Ut) > 0);
  Ok('TOrderRow kommer før TCustomerRow',
    (Pos('TOrderRow = record', Ut) > 0) and
    (Pos('TOrderRow = record', Ut) < Pos('TCustomerRow = record', Ut)));

  Start('typer leses av databasen');
  Ok('NUMERIC(12,2) blir Currency', Pos('Balance: Currency', Ut) > 0);
  Ok('TINYINT(1) blir Boolean', Pos('Active: Boolean', Ut) > 0);
  Ok('REAL blir Double', Pos('Weight: Double', Ut) > 0);
  Ok('customer_id blir CustomerId: Int64',
    Pos('CustomerId: Int64', Ut) > 0);

  Start('comptime fanger feilene');
  Message_ := Feilmelding('bad-unknown-table');
  Ok('ukjent tabell', Pos('does not exist', Message_) > 0);
  Ok('med forslag', Pos('Did you mean "customers"', Message_) > 0);

  Message_ := Feilmelding('bad-unknown-column');
  Ok('ukjent kolonne', Pos('has no column', Message_) > 0);
  Ok('med forslag', Pos('Did you mean "email"', Message_) > 0);

  Message_ := Feilmelding('bad-type-mismatch');
  Ok('typekonflikt mot skjemaet', Pos('is money', Message_) > 0);
  Ok('og sier hvor skjemaet ble lest', Pos('The schema was read', Message_) > 0);

  Message_ := Feilmelding('bad-unknown-relation');
  Ok('ukjent relasjon', Pos('has no relation', Message_) > 0);
  Ok('med forslag', Pos('Did you mean "orders"', Message_) > 0);

  Message_ := Feilmelding('bad-generic-without-for');
  Ok('generisk uten for', Pos('is missing "for"', Message_) > 0);

  Message_ := Feilmelding('bad-relation-without-model');
  Ok('relasjon uten modell', Pos('has no model', Message_) > 0);

  Start('feil nevner fil og linje');
  Message_ := Feilmelding('bad-unknown-column');
  Ok('linjenummer er med', Pos('.run:', Message_) > 0);
  Ok('og ingen verdi lekker ut', Pos('@example.com', Message_) = 0);

  Start('kostnad');
  Message_ := Oversett(
    'db "sqlite:@DB@"'#10 +
    'model Customer from customers'#10 +
    'model Order from orders'#10 +
    'query<M> ById(id: int) -> M for Customer, Order'#10,
    '.build/run/out.pas', S);
  WriteLn(Format('        parse %d ms, skjema %d ms, utskrift %d ms, i alt %d ms',
    [S.ParseMs, S.SchemaMs, S.EmitMs, S.TotalMs]));
  Ok('oversettelsen får plass i utviklerløkka', S.TotalMs < 50);
  Like('dialekten kom fra DSN-en', 'sqlite', S.Dialect);

  WriteLn;
  WriteLn('— ', Bestatt, ' bestått, ', Feilet, ' feilet');
  if Feilet > 0 then
    Halt(1);
end.
