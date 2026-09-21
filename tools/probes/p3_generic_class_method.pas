{ A generic class method on a non-generic class.
  3.2.2: the same mismatch, plus a compiler crash. }
unit p3_generic_class_method;
{$mode Delphi}{$H+}
interface
type
  TBox<M: class> = class
  public
    Cls: TClass;
  end;

  Urd = class
  public
    class function Query<M: class>: TBox<M>; static;
  end;
implementation
class function Urd.Query<M>: TBox<M>;
begin
  Result := TBox<M>.Create;
  Result.Cls := M;
end;
end.
