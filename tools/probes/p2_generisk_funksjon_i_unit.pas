{ Generisk frittstående funksjon eksportert fra en unit.
  3.2.2: deklarasjon og implementasjon får ulike navn på typeparameteren.
  Dette er proben som avgjør om Query<TCustomer> er mulig. }
unit p2_generisk_funksjon_i_unit;
{$mode Delphi}{$H+}
interface
type
  TBoks<M: class> = class
  public
    Klasse: TClass;
  end;
function Boks<M: class>: TBoks<M>;
implementation
function Boks<M: class>: TBoks<M>;
begin
  Result := TBoks<M>.Create;
  Result.Klasse := M;
end;
end.
