{ Urd ende-til-ende: modeller, pool, typede spørringer og eager loading.

  Dette er steg 2 i fase 1, kjørt mot en ekte Postgres. Kolonnekonstantene
  nederst i type-seksjonen skrives her for hånd; i steg 3 genererer Norn dem
  fra det faktiske skjemaet, og da blir en fjernet kolonne en kompileringsfeil
  overalt der den brukes.

  Kjøres med `./askr urd` (krever `./askr db:up`). }
program UrdDemo;

{$mode Delphi}{$H+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  SysUtils,
  Askr.Core.Arena, Askr.Core.Text,
  Askr.Urd.Driver, Askr.Urd.Pg, Askr.Urd.Pool,
  Askr.Urd.Model, Askr.Urd.Query;

type
  { TOrder må deklareres ferdig før TCustomer: en forward-deklarert klasse kan
    ikke brukes som typeargument til TModelList<M>, fordi constrainten
    M: TModel ikke kan sjekkes mot en ufullstendig type. TOrder trenger på sin
    side bare TCustomer inne i Describe, som implementeres lenger nede. }
  TOrder = class(TModel)
  private
    FId: Int64;
    FCustomerId: Int64;
    FTotal: Currency;
  published
    property Id: Int64 read FId write FId;
    property CustomerId: Int64 read FCustomerId write FCustomerId;
    property Total: Currency read FTotal write FTotal;
  public
    class procedure Describe(S: TSchema); override;
  end;

  TCustomer = class(TModel)
  private
    FId: Int64;
    FName: string;
    FEmail: string;
    FBalance: Currency;
    FActive: Boolean;
  published
    { Eager loading legger barna her. Feltet må hete det samme som relasjonen
      og være published, ellers finner ikke FieldAddress det. Felter må stå
      før properties i samme seksjon. }
    Orders: TModelList<TOrder>;
    property Id: Int64 read FId write FId;
    property Name: string read FName write FName;
    property Email: string read FEmail write FEmail;
    property Balance: Currency read FBalance write FBalance;
    property Active: Boolean read FActive write FActive;
  public
    class procedure Describe(S: TSchema); override;
  end;

class procedure TCustomer.Describe(S: TSchema);
begin
  S.Table('customers');
  S.HasMany('Orders', TOrder, 'customer_id');
end;

class procedure TOrder.Describe(S: TSchema);
begin
  S.Table('orders');
  S.BelongsTo('Customer', TCustomer, 'customer_id');
end;

type
  { GENERERES AV NORN I STEG 3 — skrevet for hånd her. }
  TCustomersColumns = record
    const Id      : TColInt64    = (Name: 'id';      Table: 'customers');
    const Name    : TColStr      = (Name: 'name';    Table: 'customers');
    const Email   : TColStr      = (Name: 'email';   Table: 'customers');
    const Balance : TColCurrency = (Name: 'balance'; Table: 'customers');
    const Active  : TColBool     = (Name: 'active';  Table: 'customers');
  end;

  TOrdersColumns = record
    const Id         : TColInt64    = (Name: 'id';          Table: 'orders');
    const CustomerId : TColInt64    = (Name: 'customer_id'; Table: 'orders');
    const Total      : TColCurrency = (Name: 'total';       Table: 'orders');
  end;

var
  Customers: TCustomersColumns;
  Orders: TOrdersColumns;

var
  Err: Integer = 0;

procedure Si(const Etikett, Value_: string);
var
  Pad: string;
begin
  Pad := Etikett;
  while Length(Pad) < 32 do
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

function Dsn: string;
begin
  Result := GetEnvironmentVariable('ASKR_PG_DSN');
  if Result = '' then
    Result := 'postgresql://askr:askr@127.0.0.1:5433/askr_dev';
end;

procedure LagSkjema(C: TDbConnection; A: TArena);
begin
  C.Exec(A, 'DROP TABLE IF EXISTS orders');
  C.Exec(A, 'DROP TABLE IF EXISTS customers');
  C.Exec(A,
    'CREATE TABLE customers (' +
    ' id BIGSERIAL PRIMARY KEY,' +
    ' name TEXT NOT NULL,' +
    ' email TEXT UNIQUE,' +
    ' balance NUMERIC(12,2) NOT NULL DEFAULT 0,' +
    ' active BOOLEAN NOT NULL DEFAULT true)');
  C.Exec(A,
    'CREATE TABLE orders (' +
    ' id BIGSERIAL PRIMARY KEY,' +
    ' customer_id BIGINT NOT NULL REFERENCES customers(id) ON DELETE CASCADE,' +
    ' total NUMERIC(12,2) NOT NULL DEFAULT 0)');
end;

var
  Pool: TDbPool;
  A: TArena;
  PrevArena: TArena;
  PrevDb: TDbConnection;
  C: TDbConnection;
  K: TCustomer;
  O: TOrder;
  Items: TModelList<TCustomer>;
  I, J, OrderCount: Integer;
  Meta: TModelMeta;
  Reservert: PtrUInt;
  Sql: string;
begin
  WriteLn('Askr — Urd ende-til-ende');
  WriteLn;

  Pool := TDbPool.Create(Dsn, 4);
  A := TArena.Create(64 * 1024);
  PrevArena := UseArena(A);
  try
    { Slik verten kommer til å gjøre det ved starten av hver request: låne en
      forbindelse fra poolen og sette den som omgivende. Begge leveres
      tilbake av Arena.Reset. }
    C := Pool.Lease(A);
    PrevDb := UseDb(C);
    try
      WriteLn('Konvensjoner fra RTTI');
      Meta := TCustomer.Meta;
      Si('tabell', Meta.Table);
      Si('primærnøkkel', Meta.PrimaryKey);
      Si('kolonner', IntToStr(Meta.ColumnCount));
      Expect(Meta.Table = 'customers', 'tabellnavn');
      Expect(Meta.ColumnCount = 5, 'fem kolonner fra published properties');
      Expect(Meta.IndexOfColumn('balance') >= 0, 'Balance ble til balance');
      Expect(TOrder.Meta.IndexOfColumn('customer_id') >= 0,
        'CustomerId ble til customer_id');
      Expect(not Meta.Columns[Meta.PrimaryKeyIndex].Insertable,
        'autonøkkelen skrives ikke ved INSERT');
      WriteLn;

      LagSkjema(C, A);

      WriteLn('Save: INSERT og UPDATE');
      K := A.New<TCustomer>;
      K.Name := 'Knut W. Hørne';
      K.Email := 'kh@gets.no';
      K.Balance := 1234.50;
      K.Active := True;
      K.Save;
      Expect(K.Id > 0, 'INSERT satte primærnøkkelen fra RETURNING');
      Si('ny id', IntToStr(K.Id));
      Expect(K.Persisted, 'modellen vet at den er lagret');

      K.Balance := 99.95;
      K.Save;
      Expect(TQuery<TCustomer>.New.Find(K.Id).Balance = 99.95,
        'andre Save ble en UPDATE, ikke en ny rad');
      Expect(TQuery<TCustomer>.New.Count = 1, 'fortsatt bare én rad');
      WriteLn;

      WriteLn('Typede spørringer');
      for I := 2 to 6 do
      begin
        K := A.New<TCustomer>;
        K.Name := Format('Customer %d', [I]);
        K.Email := Format('customer%d@gets.no', [I]);
        K.Balance := I * 100;
        K.Active := I mod 2 = 0;
        K.Save;
        for J := 1 to I - 1 do
        begin
          O := A.New<TOrder>;
          O.CustomerId := K.Id;
          O.Total := J * 10;
          O.Save;
        end;
      end;

      Sql := TQuery<TCustomer>.New
        .Where(Customers.Balance, GT, 150)
        .Where(Customers.Email, Like, '%@gets.no')
        .OrderBy(Customers.Balance, Desc)
        .Limit(3)
        .ToSql;
      Si('generert SQL', Sql);

      Items := TQuery<TCustomer>.New
        .Where(Customers.Balance, GT, 150)
        .Where(Customers.Email, Like, '%@gets.no')
        .OrderBy(Customers.Balance, Desc)
        .Limit(3)
        .Get;
      Expect(Items.Count = 3, 'Limit virker');
      Expect(Items[0].Balance > Items[1].Balance, 'OrderBy Desc virker');
      Expect(Items[0].Balance = 600, 'høyeste balance først');
      Expect(Items[0].Name = 'Customer 6', 'riktig rad hydrert');

      Expect(TQuery<TCustomer>.New.Where(Customers.Active, Eq, True).Count = 4,
        'boolean-filter');
      Expect(TQuery<TCustomer>.New.WhereIn(Customers.Id, [1, 2, 3]).Count = 3,
        'WhereIn');
      Expect(TQuery<TCustomer>.New.WhereNull(Customers.Email).Count = 0,
        'WhereNull');
      Expect(TQuery<TCustomer>.New.Paginate(2, 2).Count = 2, 'Paginate');
      WriteLn;

      WriteLn('Eager loading');
      Items := TQuery<TCustomer>.New
        .Preload(['Orders'])
        .OrderBy(Customers.Id)
        .Get;
      Expect(Items.Count = 6, 'alle customer');
      OrderCount := 0;
      for I := 0 to Items.Count - 1 do
        if Items[I].Orders <> nil then
          Inc(OrderCount, Items[I].Orders.Count);
      Si('order lastet', IntToStr(OrderCount));
      Expect(OrderCount = 1 + 2 + 3 + 4 + 5, 'alle orders ble fordelt riktig');
      Expect(Items[0].Orders.Count = 0, 'første customer har ingen order');
      Expect(Items[5].Orders.Count = 5, 'siste customer har fem');
      Expect(Items[5].Orders[0].Total > 0, 'barna er hydrert');
      WriteLn;

      WriteLn('Delete');
      K := TQuery<TCustomer>.New.Find(Items[5].Id);
      K.Delete;
      Expect(TQuery<TCustomer>.New.Count = 5, 'raden er borte');
      Expect(TQuery<TOrder>.New.Where(Orders.CustomerId, Eq, Items[5].Id).Count = 0,
        'ON DELETE CASCADE tok orders');
      Expect(TQuery<TCustomer>.New.Where(Customers.Balance, LT, 250).DeleteAll = 2,
        'DeleteAll returnerer antall rader');
      WriteLn;

      WriteLn('Err blir SQLSTATE, ikke 500');
      try
        K := A.New<TCustomer>;
        K.Name := 'Duplikat';
        K.Email := 'customer3@gets.no';
        K.Save;
        Expect(False, 'unik-brudd skulle kastet');
      except
        on E: EDbError do
          Expect(E.IsUniqueViolation, 'unik-brudd gjenkjennes som 23505');
      end;
      WriteLn;
    finally
      UseDb(PrevDb);
    end;

    WriteLn('Pool og arena');
    Si('åpne forbindelser', IntToStr(Pool.LiveCount));
    Si('lånt totalt', IntToStr(Pool.AcquiredTotal));
    Expect(Pool.IdleCount = 0, 'forbindelsen er fortsatt utlånt');

    A.Reset;
    Expect(Pool.IdleCount = 1, 'Arena.Reset shipped forbindelsen tilbake');
    Expect(A.BytesLive = 0, 'og ryddet alt annet');

    { Tusen requests: arenaen og poolen skal flate ut. }
    C := Pool.Lease(A);
    UseDb(C);
    Reservert := 0;
    for I := 1 to 50 do
    begin
      TQuery<TCustomer>.New.OrderBy(Customers.Id).Get;
      A.Reset;
      C := Pool.Lease(A);
      UseDb(C);
    end;
    Reservert := A.BytesReserved;
    for I := 1 to 1000 do
    begin
      TQuery<TCustomer>.New.Preload(['Orders']).OrderBy(Customers.Id).Get;
      A.Reset;
      C := Pool.Lease(A);
      UseDb(C);
    end;
    Expect(A.BytesReserved = Reservert,
      'arenaen vokste ikke over 1000 spørringer med eager loading');
    Si('arena reservert', IntToStr(A.BytesReserved));
    { HighWaterMark gjelder hele kjøringen, og oppsettet over kjørte uten
      Reset. Dette er kostnaden for én request alene. }
    TQuery<TCustomer>.New.Preload(['Orders']).OrderBy(Customers.Id).Get;
    Si('én request med eager loading', IntToStr(A.BytesLive));
    Expect(Pool.CreatedTotal = 1, 'poolen åpnet bare én forbindelse');

    UseDb(nil);
    A.Reset;
  finally
    UseArena(PrevArena);
    A.Free;
    Pool.Free;
  end;

  WriteLn;
  if Err = 0 then
    WriteLn('Steg 2 holder: modeller, pool, typede spørringer og eager loading.')
  else
  begin
    WriteLn(Err, ' feil.');
    Halt(1);
  end;
end.
