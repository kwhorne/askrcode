{ A fixture that produces several diagnostics with positions, and the
  "There were N errors" summary line. Deliberately broken; nothing compiles
  it except the capture script that made the .txt files beside it. }
unit errors;
{$mode Delphi}{$H+}
interface

function Broken: Integer;

implementation

function Broken: Integer;
var
  S: string;
  I: Integer;
  Unused: Integer;
begin
  S := NoSuchIdentifier;
  I := S;
  Result := Missing(1, 2);
end;

end.
