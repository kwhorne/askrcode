{ Storage databasen spiken introspiserer mot. Skjemaet finnes bare her — Rún-
  kilden nevner ingen kolonner, den leser dem. }
program setupdb;

{$mode Delphi}{$H+}

uses
  SysUtils, Askr.Core.Arena, Askr.Core.Text,
  Askr.Urd.Driver, Askr.Urd.Sqlite;

var
  A: TArena;
  C: TDbConnection;
  I, J, Extra: Integer;
  Money: Currency;
begin
  { With_ et tall som argument legges det på så mange ekstra tabeller. Skjemaet
    en ekte app har er ikke to tabeller, og introspeksjonen kjører på hver
    eneste bygging — da må kostnaden måles på noe som likner. }
  Extra := StrToIntDef(ParamStr(1), 0);
  ForceDirectories('.build/run');
  if FileExists('.build/run/shop.db') then
    DeleteFile('.build/run/shop.db');

  A := TArena.Create;
  C := OpenDbConnection('sqlite:.build/run/shop.db');
  try
    C.Exec(A,
      'CREATE TABLE customers (' +
      '  id INTEGER PRIMARY KEY,' +
      '  name TEXT NOT NULL,' +
      '  email TEXT NOT NULL UNIQUE,' +
      '  balance NUMERIC(12,2),' +
      '  active TINYINT(1) NOT NULL DEFAULT 1,' +
      '  weight REAL,' +
      '  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)');
    C.Exec(A,
      'CREATE TABLE orders (' +
      '  id INTEGER PRIMARY KEY,' +
      '  customer_id INTEGER NOT NULL REFERENCES customers(id),' +
      '  amount NUMERIC(12,2) NOT NULL,' +
      '  shipped TINYINT(1) NOT NULL DEFAULT 0)');

    for I := 1 to 12 do
    begin
      Money := I * 100;
      C.ExecParams(A,
        'INSERT INTO customers (name, email, balance, active, weight) ' +
        'VALUES (?, ?, ?, ?, ?)',
        [DbParam(A, 'Customer ' + IntToStr(I)),
         DbParam(A, 'k' + IntToStr(I) + '@example.com'),
         { Assigned, never cast. A typecast into Currency reinterprets
           the scaled Int64 rather than converting: Currency(I * 100) is
           0.07 on x86_64 and 700 on aarch64, and Currency(I) * 100 is
           0.01 on FPC 3.3.1 and 100 on 3.2.2. See CLAUDE.md. }
         DbParam(A, Money),
         DbParam(A, I mod 3 <> 0),
         DbParam(A, FloatToSql(60.5 + I))]);
    end;

    for I := 1 to 20 do
    begin
      Money := I * 37;
      C.ExecParams(A,
        'INSERT INTO orders (customer_id, amount, shipped) VALUES (?, ?, ?)',
        [DbParam(A, Int64((I mod 12) + 1)),
         DbParam(A, Money),
         DbParam(A, I mod 2 = 0)]);
    end;

    for I := 1 to Extra do
    begin
      C.Exec(A, Format(
        'CREATE TABLE tabell_%d (id INTEGER PRIMARY KEY, name TEXT NOT NULL, ' +
        'verdi NUMERIC(12,2), flagg TINYINT(1), maalt TEXT, weight REAL, ' +
        'ref_id INTEGER REFERENCES customers(id))', [I]));
      C.Exec(A, Format(
        'CREATE INDEX tabell_%d_name_idx ON tabell_%d (name)', [I, I]));
      for J := 1 to 3 do
      begin
        Money := J;
        C.ExecParams(A, Format('INSERT INTO tabell_%d (name, verdi) ' +
          'VALUES (?, ?)', [I]),
          [DbParam(A, 'rad'), DbParam(A, Money)]);
      end;
    end;

    WriteLn(Format('setupdb: .build/run/shop.db klar (%d tabeller)',
      [2 + Extra]));
  finally
    C.Free;
    A.Free;
  end;
end.
