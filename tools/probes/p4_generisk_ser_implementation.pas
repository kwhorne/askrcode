{ Generisk metode som refererer et symbol fra implementation-seksjonen.
  3.2.2: Global Generic template references static symtable. }
unit p4_generisk_ser_implementation;
{$mode Delphi}{$H+}
interface
type
  TQ<M: class> = class
  public
    function Navn: string;
  end;
implementation
function BareHer: string;
begin
  Result := 'skjult';
end;
function TQ<M>.Navn: string;
begin
  Result := BareHer;
end;
end.
