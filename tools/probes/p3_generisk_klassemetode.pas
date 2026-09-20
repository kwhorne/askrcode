{ Generisk klassemetode på en ikke-generisk klasse.
  3.2.2: samme mismatch, og kompilatorkrasj. }
unit p3_generisk_klassemetode;
{$mode Delphi}{$H+}
interface
type
  TBoks<M: class> = class
  public
    Klasse: TClass;
  end;

  Urd = class
  public
    class function Query<M: class>: TBoks<M>; static;
  end;
implementation
class function Urd.Query<M>: TBoks<M>;
begin
  Result := TBoks<M>.Create;
  Result.Klasse := M;
end;
end.
