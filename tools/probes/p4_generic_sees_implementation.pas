{ A generic method that references a symbol from the implementation
  section.
  3.2.2: Global Generic template references static symtable. }
unit p4_generic_sees_implementation;
{$mode Delphi}{$H+}
interface
type
  TQ<M: class> = class
  public
    function Name_: string;
  end;
implementation
function OnlyHere: string;
begin
  Result := 'hidden';
end;
function TQ<M>.Name_: string;
begin
  Result := OnlyHere;
end;
end.
