{ A generic method inside a generic class.
  3.2.2: Declaration of generic inside another generic is not allowed. }
unit p1_generic_in_generic;
{$mode Delphi}{$H+}
interface
type
  TQ<M: class> = class
  public
    function Where<T>(const V: T): TQ<M>;
  end;
implementation
function TQ<M>.Where<T>(const V: T): TQ<M>;
begin
  Result := Self;
end;
end.
