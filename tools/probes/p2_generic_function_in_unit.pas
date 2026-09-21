{ A generic standalone function exported from a unit.
  3.2.2: the declaration and the implementation end up with different
  names for the type parameter.
  This is the probe that decides whether Query<TCustomer> is possible. }
unit p2_generic_function_in_unit;
{$mode Delphi}{$H+}
interface
type
  TBox<M: class> = class
  public
    Cls: TClass;
  end;
function Box<M: class>: TBox<M>;
implementation
function Box<M: class>: TBox<M>;
begin
  Result := TBox<M>.Create;
  Result.Cls := M;
end;
end.
