{ Generisk frittstående funksjon med standardparameter.
  3.2.2: signaturene matcher ikke. }
unit p5_generisk_standardparameter;
{$mode Delphi}{$H+}
interface
type
  TBoks<M: class> = class end;
function Boks<M: class>(Tall: Integer = 0): TBoks<M>;
implementation
function Boks<M: class>(Tall: Integer = 0): TBoks<M>;
begin
  Result := TBoks<M>.Create;
end;
end.
