{ Selve gevinsten: Query<TKunde> kalt fra brukerkode, ikke bare deklarert.
  Krever at p2 kompilerer. }
program p7_kallsted;
{$mode Delphi}{$H+}
uses p2_generisk_funksjon_i_unit;
type
  TKunde = class end;
var
  B: TBoks<TKunde>;
begin
  B := Boks<TKunde>;
  WriteLn('Boks<TKunde> gav: ', B.Klasse.ClassName);
  B.Free;
end.
