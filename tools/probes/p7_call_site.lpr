{ The payoff itself: Query<TCustomer> called from user code, not merely
  declared. Requires p2 to compile. }
program p7_call_site;
{$mode Delphi}{$H+}
uses p2_generic_function_in_unit;
type
  TCustomer = class end;
var
  B: TBox<TCustomer>;
begin
  B := Box<TCustomer>;
  WriteLn('Box<TCustomer> gave: ', B.Cls.ClassName);
  B.Free;
end.
