{ A generic standalone function with a default parameter.
  3.2.2: the signatures do not match. }
unit p5_generic_default_parameter;
{$mode Delphi}{$H+}
interface
type
  TBox<M: class> = class end;
function Box<M: class>(Number: Integer = 0): TBox<M>;
implementation
function Box<M: class>(Number: Integer = 0): TBox<M>;
begin
  Result := TBox<M>.Create;
end;
end.
