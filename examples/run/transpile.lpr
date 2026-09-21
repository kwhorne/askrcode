{ The Rún transpiler as a standalone program.

  This is the whole public API: Transpile takes a .run file and writes a
  Pascal unit, and reports what it cost. In a real app it is called by
  `askr build` for every .run file under app/ — this program exists for the
  demo and for measuring. }
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
    WriteLn('usage: transpile <in.run> <out.pas> <unitname>');
    Halt(2);
  end;

  try
    S := Transpile(ParamStr(1), ParamStr(2), ParamStr(3));
  except
    { The error is the point of the language: it is to say the file, the
      line and what was wrong, and it is to come before fpc sees anything
      at all. Halt(1) so that a build script stops. }
    on E: ERunError do
    begin
      WriteLn(ErrOutput, E.Message);
      Halt(1);
    end;
  end;

  WriteLn(Format('%s -> %s', [ParamStr(1), ParamStr(2)]));
  WriteLn(Format('  %d models, %d queries, dialect %s',
    [S.Models, S.Queries, S.Dialect]));
  WriteLn(Format('  parse %d ms, skjema %d ms, utskrift %d ms, i alt %d ms',
    [S.ParseMs, S.SchemaMs, S.EmitMs, S.TotalMs]));
end.
