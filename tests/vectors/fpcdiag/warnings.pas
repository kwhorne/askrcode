{ A fixture that compiles successfully but emits a warning, a note and a
  hint. The build tool must not report this as a failure — that distinction
  is the whole reason the severity is parsed rather than the exit code
  alone. }
unit warnings;
{$mode Delphi}{$H+}
interface

function NoResult: Integer;
procedure Unused(Param: Integer);

implementation

function NoResult: Integer;
var
  Never: Integer;
begin
  Never := 1;
end;

procedure Unused(Param: Integer);
begin
end;

end.
