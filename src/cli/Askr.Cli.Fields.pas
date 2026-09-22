{ Askr.Cli.Fields — `name:type` on the command line, into a model and a
  migration that cannot disagree.

      askr make model Customer name:string(60) email:string balance:money
                               active:bool born:date? customer:references

  The spec is written once and both files come from it. That is most of
  the point: a model and its migration written by hand drift apart one
  column at a time, and the first sign is a query for a column that is
  not there -- or, with timestamps, a NOT NULL column the model never
  sets, which CLAUDE.md records as the one way the TDateTime change can
  break code.

  WHAT IS REFUSED, AND WHY

  **A type that is not on the list.** `name:strng` is an error, not a
  TEXT column. A generator that guesses turns a typo into a schema.

  **A name that does not come back as itself.** A model maps a property
  to a column with Urd's SnakeCase, at run time, every time. So the
  property this writes for a column has to snake_case back to exactly
  that column, or the model reads and writes a column the migration never
  made. That happened here once by hand: a property called `Label_`
  because `Label` is reserved, which Urd mapped to `label_` while the
  migration said `label`. The check uses Urd's own function, not a copy
  of it -- two implementations of one naming rule is how the command
  list drifted.

  **A name that is a Pascal keyword.** Same bug, other half. `type`,
  `label`, `end` and the rest cannot be property names, and the escape --
  a trailing underscore -- is the thing that breaks the round trip.

  **`id`, and duplicates.** The key is always made; asking for it again
  would make two. }
unit Askr.Cli.Fields;

{$mode Delphi}{$H+}

interface

uses
  SysUtils;

type
  EFieldSpec = class(Exception);

  TFieldType = (
    ftString, ftText, ftInt, ftBigInt, ftBool, ftMoney, ftFloat,
    ftDateTime, ftDate, ftJson, ftUuid, ftReferences);

  TFieldSpec = record
    Column: string;     { snake_case, as it is in the database }
    Prop: string;       { PascalCase, as it is on the model }
    Kind: TFieldType;
    Length: Integer;    { string(n); 0 means the default }
    Nullable: Boolean;  { a trailing ? }
    RefTable: string;   { for references: the table it points at }
  end;
  TFieldSpecs = array of TFieldSpec;

const
  { What string means without a length. Long enough for a name or an
    address, short enough that the index on it is not a waste. }
  DefaultStringLength = 255;

{ Parses every argument. Raises EFieldSpec naming the argument that is
  wrong and what would be right, so the message can be read by somebody
  who has not read this file. }
function ParseFields(const Args: array of string): TFieldSpecs;

{ The pieces the model and the migration are built from. }
function PascalTypeOf(const F: TFieldSpec): string;
function MigrationLineOf(const F: TFieldSpec): string;
{ The validation rule the spec itself states, or ''. Nothing is inferred
  from a name: `email` does not become `.Email`. The spec says what the
  column is, not what the application means by it. }
function RuleLineOf(const F: TFieldSpec): string;

{ The line in Describe that makes a nullable string column NULL when it is
  empty, or ''. Only for a column the spec marked with `?`. }
function DescribeLineOf(const F: TFieldSpec): string;

{ The names that are accepted, for a message that lists them. }
function TypeNames: string;

implementation

uses
  { SnakeCase and Pluralize: the functions the model uses at run time.
    Copies of them here would be a second naming rule to drift from the
    first -- the way the command list once did. }
  Askr.Urd.Model;

const
  TypeWords: array[TFieldType] of string = (
    'string', 'text', 'int', 'bigint', 'bool', 'money', 'float',
    'datetime', 'date', 'json', 'uuid', 'references');

  Keywords: array[0..62] of string = (
    'and', 'array', 'as', 'asm', 'begin', 'case', 'class', 'const',
    'constructor', 'destructor', 'dispinterface', 'div', 'do', 'downto',
    'else', 'end', 'except', 'exports', 'file', 'finalization', 'finally',
    'for', 'function', 'goto', 'if', 'implementation', 'in', 'inherited',
    'initialization', 'inline', 'interface', 'is', 'label', 'library',
    'mod', 'nil', 'not', 'object', 'of', 'operator', 'or', 'out', 'packed',
    'procedure', 'program', 'property', 'raise', 'record', 'repeat',
    'resourcestring', 'set', 'shl', 'shr', 'string', 'then', 'threadvar',
    'to', 'try', 'type', 'unit', 'until', 'uses', 'var');

function TypeNames: string;
var
  T: TFieldType;
begin
  Result := '';
  for T := Low(TFieldType) to High(TFieldType) do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + TypeWords[T];
  end;
end;

function IsKeyword(const S: string): Boolean;
var
  I: Integer;
  L: string;
begin
  L := LowerCase(S);
  for I := Low(Keywords) to High(Keywords) do
    if Keywords[I] = L then
      Exit(True);
  Result := False;
end;

{ customer_id -> CustomerId. }
function PropFor(const Column: string): string;
var
  I: Integer;
  Up: Boolean;
begin
  Result := '';
  Up := True;
  for I := 1 to Length(Column) do
  begin
    if Column[I] = '_' then
    begin
      Up := True;
      Continue;
    end;
    if Up then
      Result := Result + UpCase(Column[I])
    else
      Result := Result + Column[I];
    Up := False;
  end;
end;

function ValidColumnName(const S: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if S = '' then
    Exit;
  if not (S[1] in ['a'..'z']) then
    Exit;
  for I := 1 to Length(S) do
    if not (S[I] in ['a'..'z', '0'..'9', '_']) then
      Exit;
  if S[Length(S)] = '_' then
    Exit;
  if Pos('__', S) > 0 then
    Exit;
  Result := True;
end;

function ParseOne(const Arg: string): TFieldSpec;
var
  P, Q: Integer;
  Name_, TypePart, LenPart: string;
  T: TFieldType;
  Found: Boolean;
begin
  Result.Column := '';
  Result.Prop := '';
  Result.Kind := ftString;
  Result.Length := 0;
  Result.Nullable := False;
  Result.RefTable := '';

  P := Pos(':', Arg);
  if P = 0 then
    raise EFieldSpec.CreateFmt(
      '%s has no type. Write it as name:type, for instance %s:string.',
      [Arg, Arg]);
  Name_ := Copy(Arg, 1, P - 1);
  TypePart := Copy(Arg, P + 1, MaxInt);

  if (TypePart <> '') and (TypePart[Length(TypePart)] = '?') then
  begin
    Result.Nullable := True;
    System.Delete(TypePart, Length(TypePart), 1);
  end;

  LenPart := '';
  P := Pos('(', TypePart);
  if P > 0 then
  begin
    Q := Pos(')', TypePart);
    if (Q < P) or (Q <> Length(TypePart)) then
      raise EFieldSpec.CreateFmt(
        '%s: a length is written in brackets at the end, as string(60).',
        [Arg]);
    LenPart := Copy(TypePart, P + 1, Q - P - 1);
    TypePart := Copy(TypePart, 1, P - 1);
  end;

  Found := False;
  for T := Low(TFieldType) to High(TFieldType) do
    if TypeWords[T] = LowerCase(TypePart) then
    begin
      Result.Kind := T;
      Found := True;
      Break;
    end;
  if not Found then
    raise EFieldSpec.CreateFmt(
      '%s: "%s" is not a type here. It would have become a column of some ' +
      'kind, and a typo should not decide which. The types are: %s.',
      [Arg, TypePart, TypeNames]);

  if LenPart <> '' then
  begin
    if Result.Kind <> ftString then
      raise EFieldSpec.CreateFmt(
        '%s: only string takes a length. text has none, and the other ' +
        'types have one the database decides.', [Arg]);
    if not TryStrToInt(LenPart, Result.Length) or (Result.Length < 1) or
       (Result.Length > 65535) then
      raise EFieldSpec.CreateFmt(
        '%s: the length has to be a whole number from 1 to 65535.', [Arg]);
  end;

  if not ValidColumnName(Name_) then
    raise EFieldSpec.CreateFmt(
      '%s: "%s" is not a column name. Lower case letters, digits and single ' +
      'underscores, starting with a letter: born_on, address2, sku.',
      [Arg, Name_]);

  if Result.Kind = ftReferences then
  begin
    { customer:references is customer_id, pointing at customers. }
    if Copy(Name_, Length(Name_) - 2, 3) = '_id' then
      raise EFieldSpec.CreateFmt(
        '%s: write the thing it points at, not the column. ' +
        '%s:references makes %s.',
        [Arg, Copy(Name_, 1, Length(Name_) - 3), Name_]);
    Result.RefTable := Pluralize(Name_);
    Result.Column := Name_ + '_id';
  end
  else
    Result.Column := Name_;

  if Result.Column = 'id' then
    raise EFieldSpec.Create(
      'id is made for every model already. Asking for it again would ' +
      'make two.');
  if (Result.Column = 'created_at') or (Result.Column = 'updated_at') then
    raise EFieldSpec.CreateFmt(
      '%s comes with the timestamps, which are on by default. Leave it ' +
      'out, or pass --no-timestamps and add it yourself.', [Result.Column]);

  Result.Prop := PropFor(Result.Column);

  if IsKeyword(Result.Prop) then
    raise EFieldSpec.CreateFmt(
      '%s: %s is a Pascal keyword and cannot be a property. The usual way ' +
      'round that -- a trailing underscore -- is what breaks the mapping: ' +
      'the model would read and write %s_ while the migration made %s. ' +
      'Pick another name, such as %s_name or %s_kind.',
      [Arg, Result.Prop, Result.Column, Result.Column, Result.Column,
       Result.Column]);

  { The check that matters. The model does this conversion at run time; if
    it does not land back on the column, nothing else here is right. }
  if SnakeCase(Result.Prop) <> Result.Column then
    raise EFieldSpec.CreateFmt(
      '%s: the property for %s would be %s, and a model maps that back to ' +
      '%s -- not to %s. The model would then read and write a column the ' +
      'migration never made. Rename it so the two agree.',
      [Arg, Result.Column, Result.Prop, SnakeCase(Result.Prop),
       Result.Column]);
end;

function ParseFields(const Args: array of string): TFieldSpecs;
var
  I, J: Integer;
  F: TFieldSpec;
begin
  Result := nil;
  for I := 0 to High(Args) do
  begin
    if Copy(Args[I], 1, 2) = '--' then
      Continue;
    F := ParseOne(Args[I]);
    for J := 0 to High(Result) do
      if Result[J].Column = F.Column then
        raise EFieldSpec.CreateFmt(
          '%s is given twice.', [F.Column]);
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := F;
  end;
end;

function PascalTypeOf(const F: TFieldSpec): string;
begin
  case F.Kind of
    ftString, ftText, ftJson, ftUuid:
      Result := 'string';
    ftInt, ftBigInt, ftReferences:
      Result := 'Int64';
    ftBool:
      Result := 'Boolean';
    ftMoney:
      { Currency, because it is an exact scaled integer. A Double here would
        be a column of money that rounds. }
      Result := 'Currency';
    ftFloat:
      Result := 'Double';
    ftDateTime, ftDate:
      Result := 'TDateTime';
  end;
end;

function MigrationLineOf(const F: TFieldSpec): string;
const
  Q = '''';
var
  Len: Integer;
begin
  case F.Kind of
    ftString:
      begin
        Len := F.Length;
        if Len = 0 then
          Len := DefaultStringLength;
        Result := 'Text(' + Q + F.Column + Q + ', ' + IntToStr(Len) + ')';
      end;
    ftText:
      Result := 'Text(' + Q + F.Column + Q + ')';
    ftInt:
      Result := 'Int(' + Q + F.Column + Q + ')';
    ftBigInt:
      Result := 'BigInt(' + Q + F.Column + Q + ')';
    ftBool:
      Result := 'Bool(' + Q + F.Column + Q + ')';
    ftMoney:
      Result := 'Money(' + Q + F.Column + Q + ')';
    ftFloat:
      Result := 'Float(' + Q + F.Column + Q + ')';
    ftDateTime:
      Result := 'Timestamp(' + Q + F.Column + Q + ')';
    ftDate:
      Result := 'Date(' + Q + F.Column + Q + ')';
    ftJson:
      Result := 'Json(' + Q + F.Column + Q + ')';
    ftUuid:
      Result := 'Uuid(' + Q + F.Column + Q + ')';
    ftReferences:
      Result := 'ForeignKey(' + Q + F.Column + Q + ', ' + Q + F.RefTable + Q + ')';
  end;
  if F.Nullable then
    Result := Result + '.Nullable';
  Result := Result + ';';
end;

function DescribeLineOf(const F: TFieldSpec): string;
begin
  { `?` has to mean what it says. Without this an empty field is written
    as '', so a nullable column is never NULL -- and for json and uuid, ''
    is not even a value the column accepts. }
  if F.Nullable and (F.Kind in [ftString, ftText, ftJson, ftUuid]) then
    Result := 'S.EmptyIsNull(''' + F.Prop + ''');'
  else
    Result := '';
end;

function RuleLineOf(const F: TFieldSpec): string;
const
  Q = '''';
var
  R: string;
  Len: Integer;
begin
  R := '';
  { Required only where empty is a value the column can hold and a NOT
    NULL means "you have to say". A bool that is false has said; so has a
    number that is zero. Required on those would refuse the one value
    nobody thinks of as missing. }
  if not F.Nullable and (F.Kind in [ftString, ftText, ftDateTime, ftDate,
                                     ftReferences, ftUuid, ftJson]) then
    R := R + '.Required';
  if F.Kind = ftString then
  begin
    Len := F.Length;
    if Len = 0 then
      Len := DefaultStringLength;
    R := R + '.MaxLen(' + IntToStr(Len) + ')';
  end;
  if R = '' then
    Exit('');
  Result := 'V.Field(' + Q + F.Prop + Q + ')' + R + ';';
end;

end.
