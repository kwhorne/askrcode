{ Bruker koden Norn nettopp genererte.

  Dette er poenget med hele steg 3. Kolonnekonstantene under er ikke skrevet
  for hånd — de er lest ut av det faktiske skjemaet og generert. At dette
  programmet kompilerer, er beviset på at genererte navn og typer stemmer.

  Prøv å endre Customers.Balance til Customers.Balanse, eller å sammenlikne
  den med en streng. Begge deler er kompileringsfeil. }
program Verify;

{$mode Delphi}{$H+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  SysUtils,
  Askr.Core.Arena,
  Askr.Urd.Driver, Askr.Urd.Pg, Askr.Urd.Model, Askr.Urd.Query,
  App.Schema.Customers, App.Schema.Orders, App.Schema.Manifest;

type
  TOrder = class(TModel)
  private
    FId: Int64;
    FCustomerId: Int64;
    FTotal: Currency;
    FStatus: string;
  published
    property Id: Int64 read FId write FId;
    property CustomerId: Int64 read FCustomerId write FCustomerId;
    property Total: Currency read FTotal write FTotal;
    property Status: string read FStatus write FStatus;
  end;

  TCustomer = class(TModel)
  private
    FId: Int64;
    FName: string;
    FEmail: string;
    FBalance: Currency;
    FActive: Boolean;
  published
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

var
  Feil: Integer = 0;

procedure Krev(Betingelse: Boolean; const Hva: string);
begin
  if Betingelse then
    WriteLn('  ok   ', Hva)
  else
  begin
    Inc(Feil);
    WriteLn('  FEIL ', Hva);
  end;
end;

procedure Si(const Etikett, Verdi: string);
var
  Pad: string;
begin
  Pad := Etikett;
  while Length(Pad) < 30 do
    Pad := Pad + ' ';
  WriteLn('  ', Pad, Verdi);
end;

function Dsn: string;
begin
  Result := GetEnvironmentVariable('ASKR_PG_DSN');
  if Result = '' then
    Result := 'postgresql://askr:askr@127.0.0.1:5433/askr_dev';
end;

var
  C: TDbConnection;
  A: TArena;
  PrevA: TArena;
  PrevDb: TDbConnection;
  K: TCustomer;
  O: TOrder;
  Liste: TModelList<TCustomer>;
  I, J, Order: Integer;
begin
  WriteLn('Askr — bruker generert skjema');
  WriteLn;

  C := OpenDbConnection(Dsn);
  A := TArena.Create(64 * 1024);
  PrevA := UseArena(A);
  PrevDb := UseDb(C);
  try
    WriteLn('Generert av Norn');
    Si('avtrykk i manifestet', SchemaAvtrykk);
    Si('kolonne fra generert unit',
      string(Customers.Balance.Table) + '.' + string(Customers.Balance.Name));
    Krev(string(Customers.Balance.Name) = 'balance',
      'kolonnenavnet kom fra databasen');
    Krev(string(Orders.CustomerId.Name) = 'customer_id',
      'snake_case ble beholdt i SQL, PascalCase i Pascal');
    WriteLn;

    WriteLn('Manifestet');
    Krev(ColumnExists('customers', 'email'), 'ColumnExists finner email');
    { Manifestet skal si nei til noe som ikke finnes, ikke bare ja til det
      som gjør det. Før domenet ble engelsk het denne kolonnen «epost», og
      denne linja fanget at manifestet ikke bare svarte ja på alt. }
    Krev(not ColumnExists('customers', 'e_mail'),
      'og ikke en kolonne som ikke finnes');
    Krev(IsIndexed('customers', 'created_at'), 'created_at er indeksert');
    Krev(not IsIndexed('customers', 'balance'), 'balance er ikke det');
    Si('PascalType for balance', PascalTypeOf('customers', 'balance'));
    Krev(PascalTypeOf('customers', 'balance') = 'Currency',
      'NUMERIC(12,2) ble til Currency');
    Krev(PascalTypeOf('customers', 'created_at') = 'TDateTime',
      'TIMESTAMPTZ ble til TDateTime');
    WriteLn;

    WriteLn('Typet spørring mot genererte kolonner');
    TQuery<TOrder>.New.DeleteAll;
    TQuery<TCustomer>.New.DeleteAll;
    for I := 1 to 5 do
    begin
      K := A.New<TCustomer>;
      K.Name := Format('Customer %d', [I]);
      K.Email := Format('customer%d@gets.no', [I]);
      K.Balance := I * 100;
      K.Active := I mod 2 = 1;
      K.Save;
      for J := 1 to I do
      begin
        O := A.New<TOrder>;
        O.CustomerId := K.Id;
        O.Total := J * 10;
        O.Status := 'new';
        O.Save;
      end;
    end;

    Si('generert SQL', TQuery<TCustomer>.New
      .Where(Customers.Balance, GT, 150)
      .Where(Customers.Email, Like, '%@gets.no')
      .OrderBy(Customers.Balance, Desc)
      .ToSql);

    Liste := TQuery<TCustomer>.New
      .Where(Customers.Balance, GT, 150)
      .Where(Customers.Email, Like, '%@gets.no')
      .OrderBy(Customers.Balance, Desc)
      .Preload(['Orders'])
      .Get;
    Krev(Liste.Count = 4, 'fire customers over 150');
    Krev(Liste[0].Balance = 500, 'sortert synkende');
    Order := 0;
    for I := 0 to Liste.Count - 1 do
      Order := Order + Liste[I].Orders.Count;
    Krev(Order = 2 + 3 + 4 + 5, 'eager loading mot generert skjema');

    Krev(TQuery<TCustomer>.New.Where(Customers.Active, Eq, True).Count = 3,
      'boolean-kolonne generert riktig');
    Krev(TQuery<TOrder>.New.Where(Orders.Status, Eq, 'new').Count = 15,
      'tekstkolonne i den andre tabellen');
    Krev(TQuery<TOrder>.New.Where(Orders.Total, GTE, 30).Count = 6,
      'NUMERIC sammenliknes som Currency');
  finally
    UseDb(PrevDb);
    UseArena(PrevA);
    A.Free;
    C.Free;
  end;

  WriteLn;
  if Feil = 0 then
    WriteLn('Generert kode kompilerer og virker mot databasen den kom fra.')
  else
  begin
    WriteLn(Feil, ' feil.');
    Halt(1);
  end;
end.
