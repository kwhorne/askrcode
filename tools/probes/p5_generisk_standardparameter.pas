{ Generisk frittstående funksjon med standardparameter.
  3.2.2: signaturene matcher ikke. }
unit p5_generisk_standardparameter;
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
