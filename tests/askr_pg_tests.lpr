{ Postgres-tester, med vekt på prepared statements og cachen deres.

  Kjører mot en ekte server. Uten en, hopper suiten over seg selv og sier
  hvorfor.

    ./askr db:up     # Postgres på 5433
    ./askr pg

  DSN kan overstyres med ASKR_PG_DSN. }
program askr_pg_tests;

{$mode Delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Clock,
  Askr.Urd.Driver, Askr.Urd.Pg, Askr.Urd.Pool,
  Askr.Queue, Askr.Queue.Db;

var
  Bestatt: Integer = 0;
  Feilet: Integer = 0;
  Dsn: string;

procedure Start(const Name: string);
begin
  WriteLn;
  WriteLn('— ', Name);
end;

procedure Ok(const Hva: string; Verdi: Boolean);
begin
  if Verdi then
  begin
    Inc(Bestatt);
    WriteLn('  ok    ', Hva);
  end
  else
  begin
    Inc(Feilet);
    WriteLn('  FEIL  ', Hva);
  end;
end;

procedure Like(const Hva, Forventet, Fikk: string);
begin
  if Forventet = Fikk then
  begin
    Inc(Bestatt);
    WriteLn('  ok    ', Hva);
  end
  else
  begin
    Inc(Feilet);
    WriteLn('  FEIL  ', Hva);
    WriteLn('        forventet: ', Forventet);
    WriteLn('        fikk:      ', Fikk);
  end;
end;

procedure LikeI(const Hva: string; Forventet, Fikk: Int64);
begin
  Like(Hva, IntToStr(Forventet), IntToStr(Fikk));
end;

{ Serverens eget syn på saken. Uten denne kunne cachetellerne våre vært
  riktige mens ingenting faktisk var forberedt. }
function ServerStatements(C: TPgConnection; A: TArena): Int64;
begin
  Result := C.Exec(A, 'SELECT count(*) FROM pg_prepared_statements').AsInt64(0, 0);
end;

procedure Skjema(C: TDbConnection; A: TArena);
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

procedure Kjor;
var
  C: TPgConnection;
  A: TArena;
  R: TDbResult;
  Id: Int64;
  I: Integer;
  ForPrep, ForHits, ForServer: Int64;
  Feil, Tekst: string;
  V: Currency;
  T0, Uten, Med: Int64;
begin
  A := TArena.Create;
  C := TPgConnection.Create(Dsn);
  try
    Start('forbindelse');
    Ok('lever', C.IsAlive);
    Ok('dialekten er Postgres', C.Dialect = sdPostgres);
    Ok('RETURNING finnes', C.SupportsReturning);
    WriteLn('        server: ', C.ServerVersion);
    C.Exec(A, 'DEALLOCATE ALL');
    Skjema(C, A);

    Start('prepared statements');
    ForPrep := C.PreparedCount;
    ForHits := C.CacheHits;
    ForServer := ServerStatements(C, A);
    for I := 1 to 20 do
      C.ExecParams(A, 'SELECT $1::bigint + $2::bigint',
        [DbParam(A, Int64(I)), DbParam(A, Int64(1))]);
    LikeI('samme spørring forberedes én gang', 1, C.PreparedCount - ForPrep);
    LikeI('resten traff cachen', 19, C.CacheHits - ForHits);
    LikeI('serveren har ett statement mer', 1,
      ServerStatements(C, A) - ForServer);

    R := C.ExecParams(A, 'SELECT $1::bigint + $2::bigint',
      [DbParam(A, Int64(3)), DbParam(A, Int64(4))]);
    LikeI('og svaret er riktig', 7, R.AsInt64(0, 0));

    Start('cachen av');
    C.CacheLimit := 0;
    ForPrep := C.PreparedCount;
    for I := 1 to 3 do
      C.ExecParams(A, 'SELECT $1::text', [DbParam(A, 'hei')]);
    LikeI('ingenting forberedes', 0, C.PreparedCount - ForPrep);
    R := C.ExecParams(A, 'SELECT $1::text', [DbParam(A, 'hei')]);
    Like('men svaret er det samme', 'hei', R.Value(0, 0).ToString);
    C.CacheLimit := 64;

    Start('PQprepare overlever rollback');
    { SQL-setningen PREPARE er transaksjonell: forberedes den inne i en
      transaksjon som rulles tilbake, forsvinner den. **PQprepare er noe
      annet** — den sender en Parse-melding i den utvidede protokollen, og
      slike statements hører til sesjonen, ikke til transaksjonen. De
      overlever rollback.

      Forskjellen er verdt en test, for den avgjør om cachen trenger å vite
      om transaksjoner i det hele tatt. Den gjør ikke det. }
    C.FlushStatementCache;
    C.StartTransaction;
    R := C.ExecParams(A, 'SELECT $1::int * 2', [DbParam(A, Int64(21))]);
    LikeI('forberedt og kjørt inne i transaksjonen', 42, R.AsInt64(0, 0));
    ForPrep := C.PreparedCount;
    C.Rollback;

    LikeI('statementet står igjen på serveren', 1, ServerStatements(C, A));
    R := C.ExecParams(A, 'SELECT $1::int * 2', [DbParam(A, Int64(21))]);
    LikeI('samme spørring virker etterpå', 42, R.AsInt64(0, 0));
    LikeI('uten å forberedes på nytt', 0, C.PreparedCount - ForPrep);

    Start('gjenoppretting når statementet forsvinner likevel');
    { Cachen kan fortsatt bli utdatert: noe annet i appen kan kjøre
      DEALLOCATE ALL, og da peker den på navn serveren ikke kjenner. Her
      gjøres det med vilje, bak ryggen på cachen, for å vise at neste kall
      forbereder på nytt i stedet for å feile med 26000. }
    ForPrep := C.PreparedCount;
    C.Exec(A, 'DEALLOCATE ALL');
    LikeI('serveren er tom', 0, ServerStatements(C, A));
    R := C.ExecParams(A, 'SELECT $1::int * 2', [DbParam(A, Int64(21))]);
    LikeI('spørringen virker likevel', 42, R.AsInt64(0, 0));
    LikeI('fordi den ble forberedt på nytt', 1, C.PreparedCount - ForPrep);
    LikeI('og serveren har den igjen', 1, ServerStatements(C, A));

    Start('et statement som feiler kastes ut');
    C.FlushStatementCache;
    { InsertGetId tar en INSERT uten RETURNING; driveren legger på det
      dialekten trenger. }
    Id := C.InsertGetId(A,
      'INSERT INTO pg_customer (name, email) VALUES ($1, $2)',
      [DbParam(A, 'Ada'), DbParam(A, 'ada@example.com')], 'id');
    Ok('fikk en id', Id > 0);

    Feil := '';
    try
      C.ExecParams(A, 'INSERT INTO pg_customer (name, email) VALUES ($1, $2)',
        [DbParam(A, 'Kopi'), DbParam(A, 'ada@example.com')]);
    except
      on E: EDbError do
      begin
        Feil := E.SqlState;
        Ok('unik-brudd kjennes igjen', E.IsUniqueViolation);
      end;
    end;
    Like('SQLSTATE er 23505', '23505', Feil);

    { Samme spørring skal virke etterpå, med en annen e-post. }
    Id := C.InsertGetId(A,
      'INSERT INTO pg_customer (name, email) VALUES ($1, $2)',
      [DbParam(A, 'Bo'), DbParam(A, 'bo@example.com')], 'id');
    Ok('forbindelsen er brukbar etter feilen', Id > 0);

    Start('cachen har en grense');
    C.FlushStatementCache;
    C.CacheLimit := 4;
    for I := 1 to 10 do
      C.ExecParams(A,
        Format('SELECT $1::bigint + %d', [I]), [DbParam(A, Int64(1))]);
    Ok('serveren holder seg under grensen',
      ServerStatements(C, A) <= 4);
    R := C.ExecParams(A, 'SELECT $1::bigint + 7', [DbParam(A, Int64(1))]);
    LikeI('og spørringene svarer fortsatt riktig', 8, R.AsInt64(0, 0));
    C.CacheLimit := 64;

    Start('verdier over prepared-veien');
    C.FlushStatementCache;
    C.ExecParams(A, 'UPDATE pg_customer SET balance = $1 WHERE id = $2',
      [DbParam(A, Currency(1234.50)), DbParam(A, Id)]);
    R := C.ExecParams(A,
      'SELECT name, balance, active, created_at FROM pg_customer WHERE id = $1',
      [DbParam(A, Id)]);
    LikeI('én rad', 1, R.RowCount);
    Like('kolonnenavn beholdes', 'balance', R.FieldName(1).ToString);
    Ok('NUMERIC leses som Currency',
      SqlToCurrency(R.Value(0, 'balance'), V) and (V = 1234.50));
    Ok('BOOLEAN leses', R.Value(0, 'active').EqualsStr('t'));
    Ok('verdiene ligger i arenaen', A.Owns(R.Value(0, 'name').Data));

    C.ExecParams(A, 'UPDATE pg_customer SET balance = $1 WHERE id = $2',
      [DbNull, DbParam(A, Id)]);
    R := C.ExecParams(A, 'SELECT balance FROM pg_customer WHERE id = $1',
      [DbParam(A, Id)]);
    Ok('NULL er NULL', R.IsNull(0, 0));

    Tekst := 'Blåbær 🫐 — he said "hi"; DROP TABLE x; --';
    C.ExecParams(A, 'UPDATE pg_customer SET name = $1 WHERE id = $2',
      [DbParam(A, Tekst), DbParam(A, Id)]);
    R := C.ExecParams(A, 'SELECT name FROM pg_customer WHERE id = $1',
      [DbParam(A, Id)]);
    Like('tekst er data, ikke SQL', Tekst, R.Value(0, 0).ToString);

    Start('mange rader over samme statement');
    C.Exec(A, 'DELETE FROM pg_customer');
    C.StartTransaction;
    ForPrep := C.PreparedCount;
    for I := 1 to 500 do
      C.ExecParams(A,
        'INSERT INTO pg_customer (name, email, balance) VALUES ($1, $2, $3)',
        [DbParam(A, 'Bulk ' + IntToStr(I)),
         DbParam(A, 'bulk' + IntToStr(I) + '@example.com'),
         DbParam(A, Currency(I) / 4)]);
    C.Commit;
    LikeI('500 innsettinger, ett statement', 1, C.PreparedCount - ForPrep);
    R := C.ExecParams(A,
      'SELECT name, balance FROM pg_customer WHERE email LIKE $1 ORDER BY id',
      [DbParam(A, 'bulk%')]);
    LikeI('500 rader tilbake', 500, R.RowCount);
    Like('siste rad', 'Bulk 500', R.Value(499, 'name').ToString);
    Ok('desimalen på rad 400 stemmer',
      SqlToCurrency(R.Value(399, 'balance'), V) and (V = 100.0));

    { Statementet ble forberedt inne i transaksjonen, og denne gangen
      committet — da skal det fortsatt finnes. }
    ForPrep := C.PreparedCount;
    C.ExecParams(A,
      'INSERT INTO pg_customer (name, email, balance) VALUES ($1, $2, $3)',
      [DbParam(A, 'Etter'), DbParam(A, 'etter@example.com'),
       DbParam(A, Currency(1))]);
    LikeI('commit beholder det forberedte statementet', 0,
      C.PreparedCount - ForPrep);

    Start('hva cachen er verdt');
    { Ikke en påstand — et måltall. Tidsgrenser i en testsuite blir flakete
      på en lastet maskin, men uten et tall er «prepared statements med
      cache» bare en påstand. }
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
    Uten := MonotonicMs - T0;

    C.CacheLimit := 64;
    C.FlushStatementCache;
    T0 := MonotonicMs;
    for I := 1 to 2000 do
      C.ExecParams(A, 'SELECT count(*) FROM pg_customer WHERE name = $1',
        [DbParam(A, 'Bulk ' + IntToStr(I))]);
    Med := MonotonicMs - T0;

    WriteLn('        2000 spørringer: ', Uten, ' ms uten cache, ',
            Med, ' ms med');
    if Med > 0 then
      WriteLn('        ', (Uten * 100) div Med, ' % av tiden uten cache');
    Ok('cachen gjorde det ikke tregere', Med <= Uten + (Uten div 4));

    C.Exec(A, 'DROP TABLE IF EXISTS pg_order');
    C.Exec(A, 'DROP TABLE IF EXISTS pg_customer');
  finally
    C.Free;
    A.Free;
  end;
end;

{ Poolen gir forbindelser til ulike tråder. Cachen ligger på forbindelsen,
  så to tråder skal aldri se hverandres statementnavn. }
type
  TPgTraad = class(TThread)
  private
    FPool: TDbPool;
    FRunder: Integer;
    FSum: Int64;
    FFeil: string;
  protected
    procedure Execute; override;
  public
    constructor Create(APool: TDbPool; ARunder: Integer);
    property Sum: Int64 read FSum;
    property Feil: string read FFeil;
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
      FFeil := E.ClassName + ': ' + E.Message;
  end;
end;

{$I queue_db_conc.inc}

procedure PoolDelen;
const
  Traader = 4;
  Runder = 50;
var
  P: TDbPool;
  T: array[0..Traader - 1] of TPgTraad;
  I: Integer;
  Sum, Fasit: Int64;
  Feil: string;
begin
  Start('pool og tråder');
  P := TDbPool.Create(Dsn, 3);
  try
    for I := 0 to Traader - 1 do
      T[I] := TPgTraad.Create(P, Runder);
    Sum := 0;
    Feil := '';
    for I := 0 to Traader - 1 do
    begin
      T[I].WaitFor;
      Inc(Sum, T[I].Sum);
      if (Feil = '') and (T[I].Feil <> '') then
        Feil := T[I].Feil;
      T[I].Free;
    end;
    if Feil <> '' then
      WriteLn('        feil fra en tråd: ', Feil);
    Ok('ingen tråd feilet', Feil = '');
    Fasit := Int64(Traader) * ((Int64(Runder) * (Runder + 1)) div 2 + Runder);
    LikeI('alle svarene stemmer', Fasit, Sum);
    LikeI('200 leier totalt', Traader * Runder, Int64(P.AcquiredTotal));
    Ok('poolen holdt seg innenfor grensen', P.LiveCount <= 3);
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
    WriteLn('HOPPET OVER: libpq finnes ikke her.');
    Halt(0);
  end;
  WriteLn('bibliotek: ', PgLibraryName);

  try
    Kjor;
    PoolDelen;
    KoeDelen(Dsn);
  except
    on E: EDbError do
      if (Pos('could not connect', LowerCase(E.Message)) > 0) or
         (Pos('connection refused', LowerCase(E.Message)) > 0) or
         (Pos('could not translate', LowerCase(E.Message)) > 0) then
      begin
        WriteLn;
        WriteLn('HOPPET OVER: ingen Postgres-server å snakke med.');
        WriteLn('  ', E.Message);
        WriteLn('  Start en med ./askr db:up');
        Halt(0);
      end
      else
        raise;
  end;

  WriteLn;
  WriteLn('— ', Bestatt, ' bestått, ', Feilet, ' feilet');
  if Feilet > 0 then
    Halt(1);
end.
