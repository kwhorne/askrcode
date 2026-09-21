{ Generisk frittstående funksjon eksportert fra en unit.
  3.2.2: deklarasjon og implementasjon får ulike navn på typeparameteren.
  Dette er proben som avgjør om Query<TCustomer> er mulig. }
unit p2_generisk_funksjon_i_unit;
{$mode Delphi}{$H+}
interface
type
  TBox<M: class> = class
  public
    Klasse: TClass;
  end;
function Box<M: class>: TBox<M>;
implementation
function Box<M: class>: TBox<M>;
begin
  Result := TBox<M>.Create;
  Result.Klasse := M;
end;
end.
