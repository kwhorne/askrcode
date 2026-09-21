{ Uses the code Norn has just generated.

  This is the point of all of step 3. The column constants below are not
  written by hand — they are read out of the actual schema and generated.
  That this program compiles is the proof that the generated names and
  types are right.

  Try changing Customers.Balance to Customers.Balanse, or comparing it
  with a string. Both are compile errors. }
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
  Err: Integer = 0;

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

procedure Si(const Etikett, Value_: string);
var
  Pad: string;
begin
  Pad := Etikett;
  while Length(Pad) < 30 do
    Pad := Pad + ' ';
  WriteLn('  ', Pad, Value_);
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
  Items: TModelList<TCustomer>;
  I, J, Order: Integer;
begin
  WriteLn('Askr — using the generated schema');
  WriteLn;

  C := OpenDbConnection(Dsn);
  A := TArena.Create(64 * 1024);
  PrevA := UseArena(A);
  PrevDb := UseDb(C);
  try
    WriteLn('Generert av Norn');
    Si('the fingerprint in the manifest', SchemaAvtrykk);
    Si('a column from the generated unit',
      string(Customers.Balance.Table) + '.' + string(Customers.Balance.Name));
    Expect(string(Customers.Balance.Name) = 'balance',
      'the column name came from the database');
    Expect(string(Orders.CustomerId.Name) = 'customer_id',
      'snake_case was kept in SQL, PascalCase in Pascal');
    WriteLn;

    WriteLn('Manifestet');
    Expect(ColumnExists('customers', 'email'), 'ColumnExists finner email');
    { The manifest is to say no to something that does not exist, not only
      yes to what does. Before the domain became English this column was
      called "epost", and this line caught that the manifest was not simply
      answering yes to everything. }
    Expect(not ColumnExists('customers', 'e_mail'),
      'and not a column that does not exist');
    Expect(IsIndexed('customers', 'created_at'), 'created_at is indexed');
    Expect(not IsIndexed('customers', 'balance'), 'balance is not');
    Si('PascalType for balance', PascalTypeOf('customers', 'balance'));
    Expect(PascalTypeOf('customers', 'balance') = 'Currency',
      'NUMERIC(12,2) became Currency');
    Expect(PascalTypeOf('customers', 'created_at') = 'TDateTime',
      'TIMESTAMPTZ became TDateTime');
    WriteLn;

    WriteLn('A typed query against generated columns');
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

    Items := TQuery<TCustomer>.New
      .Where(Customers.Balance, GT, 150)
      .Where(Customers.Email, Like, '%@gets.no')
      .OrderBy(Customers.Balance, Desc)
      .Preload(['Orders'])
      .Get;
    Expect(Items.Count = 4, 'fire customers over 150');
    Expect(Items[0].Balance = 500, 'sorted descending');
    Order := 0;
    for I := 0 to Items.Count - 1 do
      Order := Order + Items[I].Orders.Count;
    Expect(Order = 2 + 3 + 4 + 5, 'eager loading against the generated schema');

    Expect(TQuery<TCustomer>.New.Where(Customers.Active, Eq, True).Count = 3,
      'the boolean column was generated correctly');
    Expect(TQuery<TOrder>.New.Where(Orders.Status, Eq, 'new').Count = 15,
      'a text column in the other table');
    Expect(TQuery<TOrder>.New.Where(Orders.Total, GTE, 30).Count = 6,
      'NUMERIC is compared as Currency');
  finally
    UseDb(PrevDb);
    UseArena(PrevA);
    A.Free;
    C.Free;
  end;

  WriteLn;
  if Err = 0 then
    WriteLn('Generated code compiles and works against the database it came from.')
  else
  begin
    WriteLn(Err, ' feil.');
    Halt(1);
  end;
end.
