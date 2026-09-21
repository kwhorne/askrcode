{ MySQL-tester.

  Kjører mot en ekte server. Without en, hopper suiten over seg selv og sier
  hvorfor — den melder ikke grønt på noe den ikke har prøvd.

    ./askr db:up        # starter MySQL 8.4 på port 3308
    ./askr mysql        # bygger og kjører denne

  DSN kan overstyres med ASKR_MYSQL_DSN. }
program askr_mysql_tests;

{$mode Delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Clock,
  Classes,
  Askr.Urd.Driver, Askr.Urd.MySql, Askr.Urd.Pool,
  Askr.Norn.Schema, Askr.Norn.Migration, Askr.Norn.Introspect,
  Askr.Queue, Askr.Queue.Db;

type
  { Én migrasjon som rører alt introspeksjonen skal kjenne igjen:
    autonøkkel, tekst, boolsk, penger, dato, fremmednøkkel og to indekser. }
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
  Bestatt: Integer = 0;
  Feilet: Integer = 0;
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

procedure LikeI(const What: string; Forventet, Fikk: Int64);
begin
  Like(What, IntToStr(Forventet), IntToStr(Fikk));
end;

{ Count_ prepared statements serveren har åpne akkurat nå. }
function OpenStatements_(C: TDbConnection; A: TArena): Int64;
var
  R: TDbResult;
begin
  R := C.Exec(A, 'SHOW GLOBAL STATUS LIKE ''Prepared_stmt_count''');
  if R.RowCount = 0 then
    Exit(-1);
  Result := R.AsInt64(0, 1);
end;

procedure Skjema(C: TDbConnection; A: TArena);
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

{ Poolen brukes fra worker-tråder i en ekte app, så det er der driveren
  faktisk lever. En forbindelse går aldri til to tråder samtidig — poolen
  garanterer det — men den kan godt gå til en annen tråd enn den som åpnet
  den, og det er nettopp det denne testen utsetter den for. }
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
        { Arenaen frigjør leiet gjennom Defer. }
        A.Free;
      end;
    end;
  except
    on E: Exception do
      FErr := E.ClassName + ': ' + E.Message;
  end;
end;

{$I queue_db_conc.inc}

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
  Start('pool og tråder');
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
      WriteLn('        feil fra en tråd: ', Err);
    Ok('ingen tråd feilet', Err = '');
    { 4 tråder x sum(2..51) }
    Fasit := Int64(Traader) * ((Int64(Runder) * (Runder + 1)) div 2 + Runder);
    LikeI('alle svarene stemmer', Fasit, Sum);
    LikeI('200 leier totalt', Traader * Runder, Int64(P.AcquiredTotal));
    Ok('poolen holdt seg innenfor grensen', P.LiveCount <= 3);
    WriteLn('        forbindelser created_at: ', P.CreatedTotal,
            '  forkastet: ', P.DiscardedTotal);
  finally
    P.Free;
  end;
end;

procedure NornDelen(C: TDbConnection; A: TArena);
var
  M: TMigrator;
  Skjema: TDbSchema;
  T: TDbTable;
  Kol: TDbColumn;
  I: Integer;
  FantIndeks: Boolean;
begin
  Start('norn: migrasjon');
  C.Exec(A, 'DROP TABLE IF EXISTS norn_order');
  C.Exec(A, 'DROP TABLE IF EXISTS norn_customer');
  C.Exec(A, 'DROP TABLE IF EXISTS askr_migrations');

  RegisterMigration(TCreateShop);
  M := TMigrator.Create(C);
  try
    LikeI('én migrasjon venter', 1, M.PendingCount);
    LikeI('én ble kjørt', 1, M.Up);
    LikeI('ingen venter etterpå', 0, M.PendingCount);
  finally
    M.Free;
  end;

  Start('norn: introspeksjon');
  Skjema := IntrospectSchema(C);
  try
    Ok('fant norn_customer', Skjema.Table('norn_customer') <> nil);
    Ok('fant norn_order', Skjema.Table('norn_order') <> nil);

    T := Skjema.Table('norn_customer');
    Like('primærnøkkelen er id', 'id', T.PrimaryKey);
    LikeI('seks kolonner', 6, T.ColumnCount);

    Kol := T.Column(T.IndexOfColumn('id'));
    Like('id blir Int64', 'TColInt64', ColAliasFor(Kol.SqlType, Kol.Scale));
    Ok('id er primærnøkkel', Kol.IsPrimaryKey);

    Kol := T.Column(T.IndexOfColumn('name'));
    Like('varchar blir streng', 'TColStr', ColAliasFor(Kol.SqlType, Kol.Scale));
    LikeI('lengden er med', 190, Kol.MaxLength);
    Ok('name er ikke nullbar', not Kol.Nullable);

    Kol := T.Column(T.IndexOfColumn('active'));
    Like('tinyint(1) blir boolsk', 'TColBool',
      ColAliasFor(Kol.SqlType, Kol.Scale));
    Like('og Pascal-typen er Boolean', 'Boolean',
      PascalTypeFor(Kol.SqlType, Kol.Scale));

    Kol := T.Column(T.IndexOfColumn('balance'));
    Like('decimal(12,2) blir Currency', 'TColCurrency',
      ColAliasFor(Kol.SqlType, Kol.Scale));
    LikeI('skalaen leses', 2, Kol.Scale);
    Ok('balance er nullbar', Kol.Nullable);

    Kol := T.Column(T.IndexOfColumn('last_seen'));
    Like('datetime blir TDateTime', 'TColDateTime',
      ColAliasFor(Kol.SqlType, Kol.Scale));

    Ok('email er indeksert', T.IsIndexed('email'));
    Ok('name er indeksert', T.IsIndexed('name'));
    FantIndeks := False;
    for I := 0 to T.IndexCount - 1 do
      if T.IndexAt(I).IsPrimary then
        FantIndeks := True;
    Ok('primærnøkkelen er med blant indeksene', FantIndeks);
    FantIndeks := False;
    for I := 0 to T.IndexCount - 1 do
      if T.IndexAt(I).IsUnique and (not T.IndexAt(I).IsPrimary) then
        FantIndeks := True;
    Ok('unik-indeksen på email er markert unik', FantIndeks);

    T := Skjema.Table('norn_order');
    LikeI('én fremmednøkkel', 1, T.ForeignKeyCount);
    if T.ForeignKeyCount > 0 then
    begin
      Like('peker på riktig kolonne', 'customer_id', T.ForeignKey(0).Column);
      Like('peker på riktig tabell', 'norn_customer', T.ForeignKey(0).RefTable);
      Like('peker på riktig kolonne i den', 'id', T.ForeignKey(0).RefColumn);
    end;
    Ok('created_at finnes', T.HasColumn('created_at'));
  finally
    Skjema.Free;
  end;

  Start('norn: tilbakerulling');
  M := TMigrator.Create(C);
  try
    LikeI('én rullet tilbake', 1, M.Down(1));
  finally
    M.Free;
  end;
  Skjema := IntrospectSchema(C);
  try
    Ok('norn_customer er borte', Skjema.Table('norn_customer') = nil);
    Ok('norn_order er borte', Skjema.Table('norn_order') = nil);
  finally
    Skjema.Free;
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
  V: Currency;
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
    Start('forbindelse');
    Ok('lever', C.IsAlive);
    Ok('dialekten er MySQL', C.Dialect = sdMySql);
    Ok('RETURNING finnes ikke', not C.SupportsReturning);
    R := C.Exec(A, 'SELECT VERSION()');
    WriteLn('        server: ', R.Value(0, 0).ToString,
            '   klient: ', MySqlClientVersion);

    Skjema(C, A);

    Start('innsetting og id');
    Id := C.InsertGetId(A,
      'INSERT INTO askr_customer (name, email, balance) VALUES (?, ?, ?)',
      [DbParam(A, 'Ada'), DbParam(A, 'ada@example.com'),
       DbParam(A, Currency(1234.50))], 'id');
    Ok('fikk en id tilbake', Id > 0);
    Id2 := C.InsertGetId(A,
      'INSERT INTO askr_customer (name, email, balance) VALUES (?, ?, ?)',
      [DbParam(A, 'Bo'), DbParam(A, 'bo@example.com'), DbNull], 'id');
    LikeI('neste id er én mer', Id + 1, Id2);

    Start('lesing');
    R := C.ExecParams(A, 'SELECT name, balance, note, active FROM askr_customer ' +
      'WHERE id = ?', [DbParam(A, Id)]);
    LikeI('én rad', 1, R.RowCount);
    LikeI('fire kolonner', 4, R.FieldCount);
    Like('kolonnenavn', 'balance', R.FieldName(1).ToString);
    Like('navnet', 'Ada', R.Value(0, 'name').ToString);
    Ok('balance leses som Currency',
      SqlToCurrency(R.Value(0, 'balance'), V) and (V = 1234.50));
    Ok('NULL er NULL', R.IsNull(0, 'note'));
    Ok('tom streng er ikke NULL for active', not R.IsNull(0, 'active'));
    Ok('boolsk leses', SqlToBool(R.Value(0, 'active'), B) and B);

    R := C.ExecParams(A, 'SELECT balance FROM askr_customer WHERE id = ?',
      [DbParam(A, Id2)]);
    Ok('NULL-kolonne uten verdi', R.IsNull(0, 0));

    Start('tekst og tegnsett');
    { utf8mb4 er hele poenget: MySQLs «utf8» klarer ikke firebyte-tegn. }
    Text_ := 'Blåbærsyltetøy 🫐 — ¥€$';
    C.ExecParams(A, 'UPDATE askr_customer SET note = ? WHERE id = ?',
      [DbParam(A, Text_), DbParam(A, Id)]);
    R := C.ExecParams(A, 'SELECT note FROM askr_customer WHERE id = ?',
      [DbParam(A, Id)]);
    Like('firebyte-tegn overlever tur-retur', Text_, R.Value(0, 0).ToString);

    Text_ := 'he said "hi"; DROP TABLE x; -- ' + #39 + 'og' + #39;
    C.ExecParams(A, 'UPDATE askr_customer SET note = ? WHERE id = ?',
      [DbParam(A, Text_), DbParam(A, Id)]);
    R := C.ExecParams(A, 'SELECT note FROM askr_customer WHERE id = ?',
      [DbParam(A, Id)]);
    Like('anførselstegn og semikolon er data, ikke SQL', Text_,
      R.Value(0, 0).ToString);

    Start('flyttall og regnede kolonner');
    { Denne delen finnes fordi den fanget en ekte feil: en DOUBLE kommer
      binært over prepared-protokollen, og en tidligere variant av
      resultatlesningen ga tom verdi for alt som ikke var tekst. Tabellene
      over skjulte det, fordi VARCHAR, DECIMAL og BIGINT sendes som tekst. }
    C.ExecParams(A, 'UPDATE askr_customer SET weight = ? WHERE id = ?',
      [DbParam(A, '72.5'), DbParam(A, Id)]);
    R := C.ExecParams(A, 'SELECT weight FROM askr_customer WHERE id = ?',
      [DbParam(A, Id)]);
    Ok('DOUBLE-kolonne kommer tilbake med verdi', R.Value(0, 0).Len > 0);
    Ok('og lar seg lese som flyttall',
      SqlToFloat(R.Value(0, 0), F) and (Abs(F - 72.5) < 0.0001));

    R := C.ExecParams(A, 'SELECT ? + ?',
      [DbParam(A, Int64(3)), DbParam(A, Int64(4))]);
    LikeI('regnet uttrykk uten tabell', 7, R.AsInt64(0, 0));

    R := C.ExecParams(A, 'SELECT AVG(balance) FROM askr_customer WHERE id IN (?, ?)',
      [DbParam(A, Id), DbParam(A, Id2)]);
    Ok('aggregat over DECIMAL gir verdi', R.Value(0, 0).Len > 0);

    { Lengre enn det faste bufferet på 192 bytes — tvinger andre runde. }
    Text_ := '';
    for I := 1 to 200 do
      Text_ := Text_ + 'æ';   { 400 bytes i UTF-8 }
    C.ExecParams(A, 'UPDATE askr_customer SET note = ? WHERE id = ?',
      [DbParam(A, Text_), DbParam(A, Id)]);
    R := C.ExecParams(A, 'SELECT note FROM askr_customer WHERE id = ?',
      [DbParam(A, Id)]);
    Like('lang tekst hentes i andre runde', Text_, R.Value(0, 0).ToString);

    Start('dato');
    R := C.ExecParams(A, 'SELECT created_at FROM askr_customer WHERE id = ?',
      [DbParam(A, Id)]);
    Ok('DATETIME lar seg lese', SqlToDateTime(R.Value(0, 0), D) and (D > 40000));

    Start('berørte rader');
    R := C.ExecParams(A, 'UPDATE askr_customer SET name = ? WHERE id = ?',
      [DbParam(A, 'Ada L.'), DbParam(A, Id)]);
    LikeI('én rad endret', 1, R.AffectedRows);
    { CLIENT_FOUND_ROWS: en oppdatering uten faktisk endring skal fortsatt
      melde at raden ble truffet. }
    R := C.ExecParams(A, 'UPDATE askr_customer SET name = ? WHERE id = ?',
      [DbParam(A, 'Ada L.'), DbParam(A, Id)]);
    LikeI('uendret oppdatering teller likevel raden', 1, R.AffectedRows);
    R := C.ExecParams(A, 'UPDATE askr_customer SET name = ? WHERE id = ?',
      [DbParam(A, 'x'), DbParam(A, Int64(999999))]);
    LikeI('ingen treff gir null', 0, R.AffectedRows);

    Start('feil som skal kjennes igjen');
    Err := '';
    try
      C.ExecParams(A,
        'INSERT INTO askr_customer (name, email) VALUES (?, ?)',
        [DbParam(A, 'Kopi'), DbParam(A, 'ada@example.com')]);
    except
      on E: EDbError do
      begin
        Err := E.SqlState;
        Ok('unik-brudd kjennes igjen', E.IsUniqueViolation);
      end;
    end;
    Like('oversatt til 23505', '23505', Err);

    Err := '';
    try
      C.ExecParams(A, 'INSERT INTO askr_order (customer_id, amount) VALUES (?, ?)',
        [DbParam(A, Int64(999999)), DbParam(A, Currency(10))]);
    except
      on E: EDbError do
      begin
        Err := E.SqlState;
        Ok('fremmednøkkelbrudd kjennes igjen', E.IsForeignKeyViolation);
      end;
    end;
    Like('oversatt til 23503', '23503', Err);

    Start('transaksjoner');
    C.StartTransaction;
    Ok('vet at den er i en transaksjon', C.InTransaction);
    C.ExecParams(A, 'INSERT INTO askr_customer (name, email) VALUES (?, ?)',
      [DbParam(A, 'Midlertidig'), DbParam(A, 'midl@example.com')]);
    C.Rollback;
    Ok('ute av transaksjonen igjen', not C.InTransaction);
    R := C.ExecParams(A, 'SELECT count(*) FROM askr_customer WHERE email = ?',
      [DbParam(A, 'midl@example.com')]);
    LikeI('rollback fjernet raden', 0, R.AsInt64(0, 0));

    C.StartTransaction;
    C.ExecParams(A, 'INSERT INTO askr_customer (name, email) VALUES (?, ?)',
      [DbParam(A, 'Varig'), DbParam(A, 'varig@example.com')]);
    C.Commit;
    R := C.ExecParams(A, 'SELECT count(*) FROM askr_customer WHERE email = ?',
      [DbParam(A, 'varig@example.com')]);
    LikeI('commit beholdt raden', 1, R.AsInt64(0, 0));

    Start('statement-cache');
    ForPrep := C.PreparedCount;
    ForHits := C.CacheHits;
    for I := 1 to 20 do
      C.ExecParams(A, 'SELECT name FROM askr_customer WHERE id = ?',
        [DbParam(A, Id)]);
    LikeI('samme spørring forberedes én gang', 1, C.PreparedCount - ForPrep);
    LikeI('resten traff cachen', 19, C.CacheHits - ForHits);

    { Serverens eget tall, ikke vårt. Without dette kunne cachetellerne våre
      vært riktige mens statements hopet seg opp på serveren — og det var
      nettopp det som skjedde før statements uten cache ble lukket. }
    ForApne := OpenStatements_(C, A);
    C.CacheLimit := 0;
    ForPrep := C.PreparedCount;
    for I := 1 to 50 do
      C.ExecParams(A, 'SELECT email FROM askr_customer WHERE id = ?',
        [DbParam(A, Id)]);
    LikeI('cachen av: forberedes hver gang', 50, C.PreparedCount - ForPrep);
    LikeI('men ingen blir liggende åpne på serveren', 0,
      OpenStatements_(C, A) - ForApne);
    C.CacheLimit := 64;

    ForApne := OpenStatements_(C, A);
    for I := 1 to 50 do
      C.ExecParams(A, 'SELECT name FROM askr_customer WHERE email = ?',
        [DbParam(A, 'ada@example.com')]);
    LikeI('med cache: nøyaktig ett står åpent', 1,
      OpenStatements_(C, A) - ForApne);

    Start('mange rader');
    C.Exec(A, 'DELETE FROM askr_customer WHERE email LIKE ''bulk%''');
    C.StartTransaction;
    for I := 1 to 500 do
      C.ExecParams(A,
        'INSERT INTO askr_customer (name, email, balance) VALUES (?, ?, ?)',
        [DbParam(A, 'Bulk ' + IntToStr(I)),
         DbParam(A, 'bulk' + IntToStr(I) + '@example.com'),
         DbParam(A, Currency(I) / 4)]);
    C.Commit;
    R := C.ExecParams(A, 'SELECT id, name, balance FROM askr_customer ' +
      'WHERE email LIKE ? ORDER BY id', [DbParam(A, 'bulk%')]);
    LikeI('500 rader tilbake', 500, R.RowCount);
    Like('første rad', 'Bulk 1', R.Value(0, 'name').ToString);
    Like('siste rad', 'Bulk 500', R.Value(499, 'name').ToString);
    Ok('desimalen på rad 400 stemmer',
      SqlToCurrency(R.Value(399, 'balance'), V) and (V = 100.0));
    Ok('alle verdiene ligger i arenaen',
      A.Owns(R.Value(0, 'name').Data) and A.Owns(R.Value(499, 'name').Data));

    Start('hva cachen er verdt');
    { Et måltall, ikke en påstand. Tidsgrenser i en suite blir flakete på en
      lastet maskin, men «prepared statements med cache» er tom tale uten
      et tall bak. }
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

    WriteLn('        2000 spørringer: ', Without, ' ms uten cache, ',
            With_, ' ms med');
    Ok('cachen gjorde det ikke tregere', With_ <= Without + (Without div 4));

    Start('tomt resultat');
    R := C.ExecParams(A, 'SELECT name FROM askr_customer WHERE id = ?',
      [DbParam(A, Int64(-1))]);
    Ok('ingen rader', R.IsEmpty);
    LikeI('men kolonnen er der', 1, R.FieldCount);

    Start('identifikatorer og plassholdere');
    B2.Init(A);
    C.AppendIdentStr(B2, 'tabell`name');
    Like('backtick siteres, og backtick inni dobles',
      '`tabell``name`', B2.ToStr.ToString);
    B2.Init(A);
    C.AppendPlaceholder(B2, 1);
    C.AppendPlaceholder(B2, 2);
    Like('plassholdere er spørsmålstegn', '??', B2.ToStr.ToString);
    R := C.Exec(A, 'SELECT `name` FROM `askr_customer` LIMIT 1');
    Ok('backtick-sitert spørring virker', R.RowCount = 1);

    C.Exec(A, 'DROP TABLE IF EXISTS askr_order');
    C.Exec(A, 'DROP TABLE IF EXISTS askr_customer');

    NornDelen(C, A);
  finally
    C.Free;
    A.Free;
  end;
  PoolDelen;
  QueuePart(Dsn);
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
    WriteLn('HOPPET OVER: MySQL-klientbiblioteket finnes ikke her.');
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
        WriteLn('HOPPET OVER: ingen MySQL-server å snakke med.');
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
