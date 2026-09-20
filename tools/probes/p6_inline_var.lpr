{ Inline variabeldeklarasjon i en for-løkke.
  3.2.2: Illegal expression. }
program p6_inline_var;
{$mode Delphi}{$H+}
begin
  for var I: Integer := 1 to 3 do
    WriteLn(I);
end.
