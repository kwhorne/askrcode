{ The plan `./askr make:check` holds against a spec.

  `askr make model` turns a spec into a table. `askr make resource` will
  turn a table into a model. The two must meet: read back from the live
  database, the table has to give the same types, the same rules and the
  same Describe lines the spec gave. That is what this checks, against
  whichever database DATABASE_URL names, with the spec on the command
  line exactly as make model had it.

  It is a program of the framework's, not of the scaffolded app's:
  Askr.Cli.Plan is part of the tool and is not on an app's unit path.

  ONE EXCEPTION, STATED

  MySQL has no UUID type. A uuid is CHAR(36) there, and CHAR(36) reads
  back as string(36) -- which is what it is. The check for that one
  column on that one database is that the plan says so in a note, not
  that it guesses. }
program plancheck;

{$mode Delphi}{$H+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  SysUtils, Classes,
  Askr.Core.Arena, Askr.Core.Env,
  Askr.Urd.Driver, Askr.Urd.Sqlite, Askr.Urd.Pg, Askr.Urd.MySql,
  Askr.Norn.Introspect, Askr.Cli.Fields, Askr.Cli.Plan;

var
  Fails: Integer = 0;

procedure Check(Cond: Boolean; const What: string; const Got: string = '');
begin
  if Cond then
    WriteLn('  ok    ', What)
  else
  begin
    WriteLn('  FAIL  ', What);
    if Got <> '' then
      WriteLn('        got: ', Got);
    Inc(Fails);
  end;
end;

function Has(const Lines: TStringArray; const S: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(Lines) do
    if Lines[I] = S then
      Exit(True);
  Result := False;
end;

function NoteMentions(const P: TResourcePlan; const S: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(P.Notes) do
    if Pos(S, P.Notes[I]) > 0 then
      Exit(True);
  Result := False;
end;

function Joined(const Lines: TStringArray): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Lines) do
    Result := Result + Lines[I] + ' ';
end;

(* The Describe and Rules lines of a generated model, trimmed. A line in
   a comment -- the commented-out S.SoftDeletes -- is not one. *)
function ModelLinesIn(const Path: string): TStringArray;
var
  L: TStringList;
  I: Integer;
  T: string;
begin
  Result := nil;
  if not FileExists(Path) then
    Exit;
  L := TStringList.Create;
  try
    L.LoadFromFile(Path);
    for I := 0 to L.Count - 1 do
    begin
      T := Trim(L[I]);
      if (Copy(T, 1, 2) = 'S.') or (Copy(T, 1, 8) = 'V.Field(') then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := T;
      end;
    end;
  finally
    L.Free;
  end;
end;

function Skipped(const Line, Prop: string): Boolean;
begin
  Result := (Prop <> '') and (Copy(Line, 1, 8) = 'V.Field(') and
    (Pos('''' + Prop + '''', Line) > 0);
end;

var
  A: TArena;
  C: TDbConnection;
  S: TDbSchema;
  P: TResourcePlan;
  Spec: TFieldSpecs;
  Args: array of string;
  F: TFieldSpec;
  PC: TPlanColumn;
  Dsn, Dialect, Want: string;
  I, K: Integer;
  RuleLines, DescribeLines, ModelLines: TStringArray;
  Exempt: string;
  MySqlUuid: Boolean;
begin
  Dsn := GetEnvironmentVariable('DATABASE_URL');
  Dialect := Copy(Dsn, 1, Pos(':', Dsn) - 1);
  WriteLn('- the plan read back from ', Dialect);

  { Model name first, then the spec, as make model takes them. }
  SetLength(Args, ParamCount - 1);
  for I := 2 to ParamCount do
    Args[I - 2] := ParamStr(I);
  Spec := ParseFields(Args);

  A := TArena.Create(64 * 1024);
  UseArena(A);
  C := OpenDbConnection(Dsn);
  S := IntrospectSchema(C);
  try
    P := PlanResource(S, ParamStr(1));
    Check(Length(P.Problems) = 0, 'the table can be a resource',
      Joined(P.Problems));
    Check(P.PrimaryKey = 'id', 'its key is id', P.PrimaryKey);
    Check(P.HasTimestamps, 'the timestamps make model added are recognised');

    RuleLines := RuleLinesOf(P);
    DescribeLines := DescribeLinesOf(P);
    Exempt := '';

    for F in Spec do
    begin
      K := PlanColumnIndex(P, F.Column);
      if K < 0 then
      begin
        Check(False, F.Column + ' is in the plan');
        Continue;
      end;
      PC := P.Columns[K];
      MySqlUuid := (Dialect = 'mysql') and (F.Kind = ftUuid);

      if MySqlUuid then
      begin
        Check((PC.Field.Kind = ftString) and (PC.Field.Length = 36),
          F.Column + ': a uuid on MySQL reads back as the CHAR(36) it is',
          PascalTypeOf(PC.Field));
        Check(NoteMentions(P, F.Column),
          F.Column + ': and the plan says it may be a uuid');
        Exempt := PC.Field.Prop;
        Continue;
      end;

      Check(PC.Field.Kind = F.Kind, F.Column + ' has the kind the spec gave',
        PC.SqlType);
      Check(PascalTypeOf(PC.Field) = PascalTypeOf(F),
        F.Column + ' is a ' + PascalTypeOf(F), PascalTypeOf(PC.Field));
      Check(PC.Field.Nullable = F.Nullable,
        F.Column + BoolToStr(F.Nullable, ' is nullable', ' is NOT NULL'));
      Check(PC.Field.Prop = F.Prop, F.Column + ' is the property ' + F.Prop,
        PC.Field.Prop);
      if F.Kind = ftString then
        Check(PC.Field.Length = F.Length,
          F.Column + ' keeps its length of ' + IntToStr(F.Length),
          IntToStr(PC.Field.Length) + ' from ' + PC.SqlType);
      if F.Kind = ftReferences then
        Check(PC.Field.RefTable = F.RefTable,
          F.Column + ' refers to ' + F.RefTable, PC.Field.RefTable);

      { The rule and the Describe line are the ones make model wrote. }
      Want := RuleLineOf(F);
      if Want <> '' then
        Check(Has(RuleLines, Want), F.Column + ': ' + Want, Joined(RuleLines));
      Want := DescribeLineOf(F);
      if Want <> '' then
        Check(Has(DescribeLines, Want), F.Column + ': ' + Want,
          Joined(DescribeLines));
    end;

    { Both ways, against the file make model wrote: every S. and V.Field
      line in it is one the plan gives, and the plan gives no other. A
      count would pass with one line swapped for another. The exception
      column's rule is a string's on MySQL, and is left out of both. }
    ModelLines := ModelLinesIn('app/Models/App.Models.' + ParamStr(1) + '.pas');
    Check(Length(ModelLines) > 0, 'the model make model wrote is there to compare with');
    for Want in ModelLines do
      if not Skipped(Want, Exempt) then
        Check(Has(RuleLines, Want) or Has(DescribeLines, Want),
          'the plan gives ' + Want, Joined(RuleLines) + Joined(DescribeLines));
    for Want in RuleLines do
      if not Skipped(Want, Exempt) then
        Check(Has(ModelLines, Want), 'make model wrote ' + Want, Joined(ModelLines));
    for Want in DescribeLines do
      if not Skipped(Want, Exempt) then
        Check(Has(ModelLines, Want), 'make model wrote ' + Want, Joined(ModelLines));
  finally
    S.Free;
    C.Free;
    A.Free;
  end;

  WriteLn;
  if Fails > 0 then
  begin
    WriteLn(Fails, ' failed.');
    Halt(1);
  end;
  WriteLn('The plan agrees with the spec.');
end.
