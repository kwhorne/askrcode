unit Hello.Migrations.Greetings;

{$mode Delphi}{$H+}

interface

implementation

uses
  Askr.Norn.Schema, Askr.Norn.Migration;

type
  TCreateGreetings = class(TMigration)
  public
    class function Version: string; override;
    procedure Up(S: TSchemaBuilder); override;
    procedure Down(S: TSchemaBuilder); override;
  end;

class function TCreateGreetings.Version: string;
begin
  Result := 'hello:20260101000000';
end;

procedure TCreateGreetings.Up(S: TSchemaBuilder);
begin
  with S.Create('hello_greetings') do
  begin
    Id;
    Text('text', 200);
  end;
end;

procedure TCreateGreetings.Down(S: TSchemaBuilder);
begin
  S.Drop('hello_greetings');
end;

initialization
  RegisterMigration(TCreateGreetings);

end.
