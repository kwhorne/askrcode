{ The migrations for the demo, in the form the PRD writes them.

  Each migration registers itself in initialization. Putting this unit in
  uses is all it takes for `askr migrate` to see them. }
unit App.Migrations;

{$mode Delphi}{$H+}

interface

uses
  Askr.Norn.Schema, Askr.Norn.Migration;

type
  TCreateCustomers = class(TMigration)
  public
    class function Version: string; override;
    procedure Up(S: TSchemaBuilder); override;
    procedure Down(S: TSchemaBuilder); override;
  end;

  TCreateOrders = class(TMigration)
  public
    class function Version: string; override;
    procedure Up(S: TSchemaBuilder); override;
    procedure Down(S: TSchemaBuilder); override;
  end;

  TAddCustomerActive = class(TMigration)
  public
    class function Version: string; override;
    procedure Up(S: TSchemaBuilder); override;
    procedure Down(S: TSchemaBuilder); override;
  end;

implementation

class function TCreateCustomers.Version: string;
begin
  Result := '20260919120000';
end;

procedure TCreateCustomers.Up(S: TSchemaBuilder);
begin
  with S.Create('customers') do
  begin
    Id;
    Text('name', 120);
    Text('email', 255).Unique;
    Money('balance').Default(0);
    Timestamps;
    Index(['created_at']);
  end;
end;

procedure TCreateCustomers.Down(S: TSchemaBuilder);
begin
  S.Drop('customers');
end;

class function TCreateOrders.Version: string;
begin
  Result := '20260919120500';
end;

procedure TCreateOrders.Up(S: TSchemaBuilder);
begin
  with S.Create('orders') do
  begin
    Id;
    ForeignKey('customer_id', 'customers');
    Money('total').Default(0);
    Text('status', 32).Default('ny');
    Timestamps;
    Index(['customer_id']);
  end;
end;

procedure TCreateOrders.Down(S: TSchemaBuilder);
begin
  S.Drop('orders');
end;

class function TAddCustomerActive.Version: string;
begin
  Result := '20260919121000';
end;

procedure TAddCustomerActive.Up(S: TSchemaBuilder);
begin
  with S.Alter('customers') do
    Bool('active').Default(True);
end;

procedure TAddCustomerActive.Down(S: TSchemaBuilder);
begin
  with S.Alter('customers') do
    DropColumn('active');
end;

initialization
  RegisterMigration(TCreateCustomers);
  RegisterMigration(TCreateOrders);
  RegisterMigration(TAddCustomerActive);

end.
