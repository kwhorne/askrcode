{ Rún-transpileren som frittstående program.

  Dette er hele det offentlige API-et: Transpile tar en .run-fil og skriver
  en Pascal-unit, og forteller hva det kostet. I en ekte app kalles den av
  «askr build» for hver .run-fil under app/ — dette programmet finnes for
  demoen og for å måle. }
program Transpile_;

{$mode Delphi}{$H+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  SysUtils,
  Askr.Run;

var
  S: TRunStats;
begin
  if ParamCount < 3 then
  begin
    WriteLn('bruk: transpile <inn.run> <ut.pas> <unitnavn>');
    Halt(2);
  end;

  try
    S := Transpile(ParamStr(1), ParamStr(2), ParamStr(3));
  except
    { Feilen er poenget med språket: den skal si fil, linje og hva som var
      galt, og den skal komme før fpc får se noe som helst. Halt(1) slik at
      et byggskript stopper. }
    on E: ERunError do
    begin
      WriteLn(ErrOutput, E.Message);
      Halt(1);
    end;
  end;

  WriteLn(Format('%s -> %s', [ParamStr(1), ParamStr(2)]));
  WriteLn(Format('  %d modeller, %d spørringer, dialekt %s',
    [S.Models, S.Queries, S.Dialect]));
  WriteLn(Format('  parse %d ms, skjema %d ms, utskrift %d ms, i alt %d ms',
    [S.ParseMs, S.SchemaMs, S.EmitMs, S.TotalMs]));
end.
