{ Generisk metode inne i en generisk klasse.
  3.2.2: Declaration of generic inside another generic is not allowed. }
unit p1_generisk_i_generisk;
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
