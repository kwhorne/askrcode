{ Askr.Cli.Plan — a table, read into what a resource needs.

  `askr make resource Customer` writes a controller, pages and a model
  from the table `customers` -- the one that exists, read from the
  database, the way `askr schema` reads it. This unit is the reading. It
  writes nothing, so it can be held against real tables without a file
  in sight.

  ONE SET OF RULES, NOT TWO

  A column becomes a TFieldSpec -- the same record `askr make model`
  parses from the command line -- and the rule, the type and the
  EmptyIsNull line come from the same functions. So a table made by
  `make model` and read back here gives the same model the spec did. The
  gate for this unit is exactly that: spec, migrate, read, compare, on
  all three databases.

  WHERE IT CANNOT SEE

  A database does not keep everything a spec said. MySQL has no UUID type
  and stores one as CHAR(36), which reads back as a string of 36 -- true
  of a UUID, and indistinguishable from any other CHAR(36). That is
  stated, not papered over.

  SQLite used to lose more: a boolean was INTEGER, JSON and UUID were
  TEXT. It declares BOOLEAN, JSON TEXT and UUID now, for new tables. A
  table made before that still reads its booleans as numbers here, and
  the plan says so for any INTEGER column called is_something or has_it.

  WHAT IS HIDDEN

  A column whose name looks like a secret -- password, token, hash,
  secret, salt -- is hidden from JSON and left out of forms and lists.
  That is a guess, and made on purpose in the direction whose failure is
  loud: a field hidden by mistake is missing from a page, and somebody
  notices; a hash that leaks is noticed by whoever reads it. The same
  asymmetry as robots.txt and CORS -- closed until somebody opens it --
  and the plan says which it hid, and why, so opening it is one line. }
unit Askr.Cli.Plan;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Askr.Norn.Introspect, Askr.Cli.Fields;

type
  TPlanColumn = record
    { Column, Prop, Kind, Length, Nullable, RefTable -- as make model
      would have had them. }
    Field: TFieldSpec;
    SqlType: string;
    { The typed constant `askr schema` writes for this column, and its
      type: Customers.Name is a TColStr. Generated code refers to these,
      never to a string, so a column that goes away is a compile error. }
    Member: string;
    ColAlias: string;
    IsPrimaryKey: Boolean;
    HasDefault: Boolean;
    IsTimestamp: Boolean;
    IsSoftDelete: Boolean;
    LooksSecret: Boolean;
    { False when the property name would not map back to the column --
      a keyword that took an underscore, or a name SnakeCase splits
      differently -- and Describe needs an S.Column for it. }
    MapsByName: Boolean;
    Editable: Boolean;   { goes in the form }
    Listed: Boolean;     { goes in the list }
    Sortable: Boolean;
    Searchable: Boolean;
  end;
  TPlanColumns = array of TPlanColumn;

  TPlanRelationKind = (prBelongsTo, prHasMany);

  TPlanRelation = record
    Kind: TPlanRelationKind;
    Name: string;        { Maker, Gadgets }
    Table: string;       { the other table }
    Model: string;       { the other model, without the T }
    ForeignKey: string;  { the column on the many side }
  end;
  TPlanRelations = array of TPlanRelation;

  TResourcePlan = record
    Model: string;       { Customer }
    Table: string;       { customers }
    PrimaryKey: string;
    Columns: TPlanColumns;
    Relations: TPlanRelations;
    HasTimestamps: Boolean;
    HasSoftDeletes: Boolean;
    DefaultSort: string;
    { Non-empty means this table cannot be a resource, and says why. }
    Problems: TStringArray;
    { Things a human should decide, and what the plan did meanwhile. }
    Notes: TStringArray;
  end;

{ Reads Table -- or the table the model's name gives, Customer ->
  customers -- out of Schema. Never raises for a table that is wrong:
  what is wrong goes in Problems, so a caller can print all of it. }
function PlanResource(Schema: TDbSchema; const ModelName: string;
  const Table: string = ''): TResourcePlan;

{ The column in a plan, by name, or -1. }
function PlanColumnIndex(const P: TResourcePlan; const Column: string): Integer;

{ The lines a model's Describe gets, and its Rules, and the columns it
  hides -- from the plan, with the same functions make model uses. }
function DescribeLinesOf(const P: TResourcePlan): TStringArray;
function RuleLinesOf(const P: TResourcePlan): TStringArray;
function HiddenColumnsOf(const P: TResourcePlan): TStringArray;

{ What `make resource --dry-run` prints: the plan, in words. }
function PlanText(const P: TResourcePlan): string;

{ The singular a table name was made from, checked against the plural
  rule: 'makers' -> 'maker', or '' when no singular pluralises back to
  it. A guess that is verified before it is used. }
function SingularOf(const Table: string): string;

implementation

uses
  Askr.Urd.Model,     { SnakeCase, Pluralize: what the model does at run time }
  Askr.Norn.Codegen;  { MemberName, IsPascalKeyword: what askr schema writes }

const
  SecretWords: array[0..9] of string = (
    'password', 'passwd', 'secret', 'token', 'hash', 'salt',
    'api_key', 'apikey', 'private_key', 'otp');

procedure Say(var A: TStringArray; const S: string);
begin
  SetLength(A, Length(A) + 1);
  A[High(A)] := S;
end;

function SingularOf(const Table: string): string;
var
  C: string;
begin
  Result := '';
  if Table = '' then
    Exit;
  if Copy(Table, Length(Table) - 2, 3) = 'ies' then
  begin
    C := Copy(Table, 1, Length(Table) - 3) + 'y';
    if Pluralize(C) = Table then
      Exit(C);
  end;
  if Copy(Table, Length(Table) - 1, 2) = 'es' then
  begin
    C := Copy(Table, 1, Length(Table) - 2);
    if Pluralize(C) = Table then
      Exit(C);
  end;
  if Table[Length(Table)] = 's' then
  begin
    C := Copy(Table, 1, Length(Table) - 1);
    if Pluralize(C) = Table then
      Exit(C);
  end;
end;

{ The length a column was declared with. Postgres and MySQL report it in
  a field of its own; SQLite reports only the text, VARCHAR(60). It is
  read out of the text here rather than in the introspection, because the
  length is part of a table's fingerprint: reporting it there would have
  made every SQLite table look changed to `schema:check` after an
  upgrade, when nothing had. }
function DeclaredLength(const C: TDbColumn): Integer;
var
  T: string;
  P, Q: Integer;
begin
  Result := C.MaxLength;
  if Result > 0 then
    Exit;
  T := LowerCase(C.SqlType);
  P := Pos('(', T);
  Q := Pos(')', T);
  if (P = 0) or (Q < P) or (Pos(',', T) > 0) then
    Exit(0);
  if not ((Pos('char', T) = 1) or (Pos('varchar', T) = 1) or
          (Pos('character', T) = 1)) then
    Exit(0);
  Result := StrToIntDef(Trim(Copy(T, P + 1, Q - P - 1)), 0);
end;

function IsForeignKey(T: TDbTable; const Column: string;
  out RefTable: string): Boolean;
var
  I: Integer;
begin
  RefTable := '';
  for I := 0 to T.ForeignKeyCount - 1 do
    if T.ForeignKey(I).Column = Column then
    begin
      RefTable := T.ForeignKey(I).RefTable;
      Exit(True);
    end;
  Result := False;
end;

{ The kind a column's SQL type says it is. Nothing from the name: a
  column called email is text. }
function KindOf(const C: TDbColumn; out Kind: TFieldType;
  out Length_: Integer): Boolean;
var
  T, Base: string;
  P: Integer;
begin
  Result := True;
  Length_ := 0;
  T := LowerCase(Trim(C.SqlType));
  Base := T;
  P := Pos('(', Base);
  if P > 0 then
    Base := Trim(Copy(Base, 1, P - 1));

  if (T = 'tinyint(1)') or (T = 'bit(1)') or (Base = 'boolean') or
     (Base = 'bool') then
    Kind := ftBool
  else if Pos('json', Base) = 1 then
    Kind := ftJson
  else if Base = 'uuid' then
    Kind := ftUuid
  else if (Base = 'varchar') or (Base = 'char') or
          (Base = 'character varying') or (Base = 'character') or
          (Base = 'nvarchar') then
  begin
    Kind := ftString;
    Length_ := DeclaredLength(C);
    { A VARCHAR with no length is as long as the database allows, which
      is TEXT in everything but name. }
    if Length_ = 0 then
      Kind := ftText;
  end
  else if (Base = 'text') or (Base = 'mediumtext') or (Base = 'longtext') or
          (Base = 'tinytext') or (Base = 'clob') then
    Kind := ftText
  else if (Base = 'bigint') or (Base = 'int8') or (Base = 'bigserial') then
    Kind := ftBigInt
  else if (Base = 'integer') or (Base = 'int') or (Base = 'int4') or
          (Base = 'smallint') or (Base = 'int2') or (Base = 'serial') or
          (Base = 'tinyint') or (Base = 'mediumint') then
    Kind := ftInt
  else if (Base = 'numeric') or (Base = 'decimal') or (Base = 'money') then
  begin
    { Currency has four decimals; the same line askr schema draws. }
    if (C.Scale >= 0) and (C.Scale <= 4) then
      Kind := ftMoney
    else
      Kind := ftFloat;
  end
  else if (Base = 'real') or (Base = 'double') or
          (Base = 'double precision') or (Base = 'float') or
          (Base = 'float4') or (Base = 'float8') then
    Kind := ftFloat
  else if Base = 'date' then
    Kind := ftDate
  else if (Pos('timestamp', Base) = 1) or (Base = 'datetime') then
    Kind := ftDateTime
  else
  begin
    { bytea, blob and the rest: not something a form or a list can show. }
    Kind := ftText;
    Result := False;
  end;
end;

function LooksLikeSecret(const Column: string): Boolean;
var
  I: Integer;
begin
  for I := Low(SecretWords) to High(SecretWords) do
    if Pos(SecretWords[I], Column) > 0 then
      Exit(True);
  Result := False;
end;

function PlanColumnIndex(const P: TResourcePlan; const Column: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(P.Columns) do
    if P.Columns[I].Field.Column = Column then
      Exit(I);
  Result := -1;
end;

function PlanResource(Schema: TDbSchema; const ModelName: string;
  const Table: string): TResourcePlan;
var
  T, Other: TDbTable;
  I, J, Pks: Integer;
  C: TDbColumn;
  PC: TPlanColumn;
  Ref, Name_: string;
  Supported: Boolean;
  Kind: TFieldType;
  Len: Integer;
  Rel: TPlanRelation;
  FirstString: string;
  HasCreated, HasUpdated: Boolean;
  Near: string;
begin
  Result.Model := ModelName;
  Result.Table := Table;
  if Result.Table = '' then
    Result.Table := Pluralize(SnakeCase(ModelName));
  Result.PrimaryKey := '';
  Result.Columns := nil;
  Result.Relations := nil;
  Result.HasTimestamps := False;
  Result.HasSoftDeletes := False;
  Result.DefaultSort := '';
  Result.Problems := nil;
  Result.Notes := nil;

  T := Schema.Table(Result.Table);
  if T = nil then
  begin
    Near := '';
    for I := 0 to Schema.TableCount - 1 do
    begin
      if Near <> '' then
        Near := Near + ', ';
      Near := Near + Schema.TableAt(I).Name;
    end;
    if Near = '' then
      Near := 'none';
    Say(Result.Problems, Format(
      'There is no table called %s. A resource is read from a table that ' +
      'exists; make it first with askr make model %s name:type ... and ' +
      'askr migrate, or name another with --table. The tables there are: %s.',
      [Result.Table, ModelName, Near]));
    Exit;
  end;

  Pks := 0;
  HasCreated := False;
  HasUpdated := False;
  FirstString := '';
  for I := 0 to T.ColumnCount - 1 do
  begin
    C := T.Column(I);
    { Every field set by hand, not with FillChar: the record has strings,
      PC is reused round the loop, and zeroing a string's pointer leaves
      the reference it held with nobody to release it. }
    PC.Field.Column := C.Name;
    PC.Field.Prop := '';
    PC.Field.RefTable := '';
    PC.SqlType := C.SqlType;
    PC.Member := '';
    PC.ColAlias := '';
    PC.IsTimestamp := False;
    PC.IsSoftDelete := False;
    PC.LooksSecret := False;
    PC.MapsByName := True;
    PC.Editable := False;
    PC.Listed := False;
    PC.Sortable := False;
    PC.Searchable := False;

    Supported := KindOf(C, Kind, Len);
    PC.Field.Kind := Kind;
    PC.Field.Length := Len;
    PC.Field.Nullable := C.Nullable;
    PC.IsPrimaryKey := C.IsPrimaryKey;
    PC.HasDefault := Trim(C.DefaultExpr) <> '';

    if IsForeignKey(T, C.Name, Ref) then
    begin
      if Schema.Table(Ref) <> nil then
      begin
        PC.Field.Kind := ftReferences;
        PC.Field.RefTable := Ref;
      end
      else
        Say(Result.Notes, Format(
          '%s points at %s, which is not there, so it is treated as a ' +
          'number and not as a relation.', [C.Name, Ref]));
    end;

    { The name: the property make model would give it, and whether that
      maps back. A keyword takes the underscore askr schema gives it too,
      so the model property and the typed constant are the same word. }
    PC.Member := MemberName(C.Name);
    PC.Field.Prop := PropFor(C.Name);
    if IsPascalKeyword(PC.Field.Prop) then
      PC.Field.Prop := PC.Field.Prop + '_';
    PC.MapsByName := SnakeCase(PC.Field.Prop) = C.Name;
    PC.ColAlias := ColAliasFor(C.SqlType, C.Scale);

    PC.IsTimestamp := ((C.Name = 'created_at') or (C.Name = 'updated_at')) and
                      (PC.Field.Kind = ftDateTime);
    if PC.IsTimestamp and (C.Name = 'created_at') then
      HasCreated := True;
    if PC.IsTimestamp and (C.Name = 'updated_at') then
      HasUpdated := True;
    PC.IsSoftDelete := (C.Name = 'deleted_at') and (PC.Field.Kind = ftDateTime);
    PC.LooksSecret := LooksLikeSecret(C.Name);

    PC.Editable := Supported and not PC.IsPrimaryKey and not PC.IsTimestamp and
                   not PC.IsSoftDelete and not PC.LooksSecret;
    PC.Listed := Supported and not PC.IsSoftDelete and not PC.LooksSecret and
                 not (PC.Field.Kind in [ftText, ftJson]) and
                 (C.Name <> 'updated_at');
    PC.Sortable := Supported and not PC.IsSoftDelete and not PC.LooksSecret and
                   (PC.Field.Kind in [ftString, ftInt, ftBigInt, ftMoney,
                                      ftFloat, ftDateTime, ftDate]);
    PC.Searchable := Supported and not PC.LooksSecret and
                     (PC.Field.Kind in [ftString, ftText]);

    if PC.IsPrimaryKey then
    begin
      Inc(Pks);
      Result.PrimaryKey := C.Name;
      if not (PC.Field.Kind in [ftInt, ftBigInt]) then
        Say(Result.Problems, Format(
          'The primary key %s is %s. A resource finds a row by a whole ' +
          'number in the path -- /%s/7 -- and TQuery.Find takes one.',
          [C.Name, C.SqlType, Result.Table]));
    end;

    if not Supported then
      Say(Result.Notes, Format(
        '%s is %s, which a form or a list cannot show. It stays on the ' +
        'model and out of the pages.', [C.Name, C.SqlType]));
    if PC.LooksSecret then
      Say(Result.Notes, Format(
        '%s looks like a secret, so it is hidden from JSON and left out of ' +
        'the form and the list. If it is not one, take it out of ' +
        'HideFromJson -- a field hidden by mistake is noticed, and a secret ' +
        'that leaks is not.', [C.Name]));
    if not PC.MapsByName then
      Say(Result.Notes, Format(
        '%s is not a name a property can have as it is, so the property ' +
        'is %s and Describe maps it: S.Column(''%s'', ''%s'').',
        [C.Name, PC.Field.Prop, PC.Field.Prop, C.Name]));
    if PC.HasDefault and not C.Nullable and not PC.IsPrimaryKey and
       not PC.IsTimestamp then
      Say(Result.Notes, Format(
        '%s has a database default (%s). A model writes every column it ' +
        'maps, so the default is not what an insert through the model ' +
        'gets; the form starts with it filled in instead, and it is not ' +
        'Required.', [C.Name, C.DefaultExpr]));
    if (PC.Field.Kind = ftInt) and ((Pos('is_', C.Name) = 1) or
       (Pos('has_', C.Name) = 1)) then
      Say(Result.Notes, Format(
        '%s is %s, and its name suggests a yes or no. A table made before ' +
        'SQLite declared BOOLEAN reads its booleans as numbers; if that is ' +
        'what this is, change the property to Boolean.', [C.Name, C.SqlType]));
    if (PC.Field.Kind = ftString) and (Len = 36) and
       (Pos('char', LowerCase(C.SqlType)) = 1) then
      Say(Result.Notes, Format(
        '%s is CHAR(36). On MySQL that is how a UUID is stored, and nothing ' +
        'in the schema says which this is; it is treated as a string of 36.',
        [C.Name]));

    if (FirstString = '') and (PC.Field.Kind = ftString) and PC.Sortable then
      FirstString := C.Name;

    SetLength(Result.Columns, Length(Result.Columns) + 1);
    Result.Columns[High(Result.Columns)] := PC;
  end;

  if Pks = 0 then
    Say(Result.Problems, Format(
      '%s has no primary key. Show, update and delete find a row by it, ' +
      'and a resource without three of its seven actions is not one.',
      [Result.Table]))
  else if Pks > 1 then
    Say(Result.Problems, Format(
      '%s has a primary key of %d columns. A resource finds a row by one ' +
      'number in the path.', [Result.Table, Pks]));

  Result.HasTimestamps := HasCreated and HasUpdated;
  if HasCreated <> HasUpdated then
    Say(Result.Notes, Format(
      '%s has only one of created_at and updated_at, so the model does not ' +
      'set them: S.Timestamps needs both.', [Result.Table]));
  for I := 0 to High(Result.Columns) do
    if Result.Columns[I].IsSoftDelete then
      Result.HasSoftDeletes := True;

  if FirstString <> '' then
    Result.DefaultSort := FirstString
  else
    Result.DefaultSort := Result.PrimaryKey;

  { Belongs to: the references in this table. }
  for I := 0 to High(Result.Columns) do
    if Result.Columns[I].Field.Kind = ftReferences then
    begin
      Name_ := Result.Columns[I].Field.Column;
      if Copy(Name_, Length(Name_) - 2, 3) = '_id' then
        Name_ := Copy(Name_, 1, Length(Name_) - 3);
      Rel.Kind := prBelongsTo;
      Rel.Name := PropFor(Name_);
      Rel.Table := Result.Columns[I].Field.RefTable;
      Rel.Model := PropFor(SingularOf(Rel.Table));
      Rel.ForeignKey := Result.Columns[I].Field.Column;
      if SingularOf(Rel.Table) = '' then
        Say(Result.Notes, Format(
          '%s points at %s, and no model name pluralises to it, so the ' +
          'relation is left out. Name the model yourself.',
          [Rel.ForeignKey, Rel.Table]))
      else
      begin
        SetLength(Result.Relations, Length(Result.Relations) + 1);
        Result.Relations[High(Result.Relations)] := Rel;
      end;
    end;

  { Has many: the other tables that point here. }
  for I := 0 to Schema.TableCount - 1 do
  begin
    Other := Schema.TableAt(I);
    if Other.Name = Result.Table then
      Continue;
    for J := 0 to Other.ForeignKeyCount - 1 do
      if Other.ForeignKey(J).RefTable = Result.Table then
      begin
        Rel.Kind := prHasMany;
        Rel.Name := PropFor(Other.Name);
        Rel.Table := Other.Name;
        Rel.Model := PropFor(SingularOf(Other.Name));
        Rel.ForeignKey := Other.ForeignKey(J).Column;
        if SingularOf(Other.Name) <> '' then
        begin
          SetLength(Result.Relations, Length(Result.Relations) + 1);
          Result.Relations[High(Result.Relations)] := Rel;
        end;
      end;
  end;
end;

{ The field as the rules should see it. A NOT NULL column with a database
  default is not Required: the form starts with the default filled in.
  Nothing else about the column changes, so EmptyIsNull still reads the
  real nullability. }
function ForRules(const PC: TPlanColumn): TFieldSpec;
begin
  Result := PC.Field;
  if PC.HasDefault then
    Result.Nullable := True;
end;

function DescribeLinesOf(const P: TResourcePlan): TStringArray;
var
  I: Integer;
  PC: TPlanColumn;
begin
  Result := nil;
  Say(Result, 'S.Table(''' + P.Table + ''');');
  for I := 0 to High(P.Columns) do
  begin
    PC := P.Columns[I];
    if not PC.MapsByName then
      Say(Result, 'S.Column(''' + PC.Field.Prop + ''', ''' +
        PC.Field.Column + ''');');
  end;
  for I := 0 to High(P.Columns) do
    if DescribeLineOf(P.Columns[I].Field) <> '' then
      Say(Result, DescribeLineOf(P.Columns[I].Field));
  if P.HasTimestamps then
    Say(Result, 'S.Timestamps;');
  if P.HasSoftDeletes then
    Say(Result, 'S.SoftDeletes;');
end;

function RuleLinesOf(const P: TResourcePlan): TStringArray;
var
  I: Integer;
  PC: TPlanColumn;
  L: string;
begin
  Result := nil;
  for I := 0 to High(P.Columns) do
  begin
    PC := P.Columns[I];
    if not PC.Editable then
      Continue;
    L := RuleLineOf(ForRules(PC));
    if L <> '' then
      Say(Result, L);
  end;
end;

function HiddenColumnsOf(const P: TResourcePlan): TStringArray;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to High(P.Columns) do
    if P.Columns[I].LooksSecret then
      Say(Result, P.Columns[I].Field.Column);
end;

function PlanText(const P: TResourcePlan): string;
var
  B: TStringArray;
  I: Integer;
  PC: TPlanColumn;
  Flags: string;
  L: TStringArray;

  procedure Add(const S: string);
  begin
    Say(B, S);
  end;

begin
  B := nil;
  if Length(P.Problems) > 0 then
  begin
    Add(Format('%s cannot be a resource:', [P.Table]));
    Add('');
    for I := 0 to High(P.Problems) do
      Add('  ' + P.Problems[I]);
  end
  else
  begin
    Add(Format('T%s, from the table %s:', [P.Model, P.Table]));
    Add('');
    for I := 0 to High(P.Columns) do
    begin
      PC := P.Columns[I];
      Flags := '';
      if PC.IsPrimaryKey then Flags := Flags + ' key';
      if PC.Field.Nullable then Flags := Flags + ' nullable';
      if PC.Editable then Flags := Flags + ' form';
      if PC.Listed then Flags := Flags + ' list';
      if PC.Sortable then Flags := Flags + ' sort';
      if PC.Searchable then Flags := Flags + ' search';
      if PC.LooksSecret then Flags := Flags + ' hidden';
      Add(Format('  %-18s %-10s %-24s%s',
        [PC.Field.Column, PascalTypeOf(PC.Field), PC.SqlType, Flags]));
    end;
    Add('');
    Add('  Describe:');
    L := DescribeLinesOf(P);
    for I := 0 to High(L) do
      Add('    ' + L[I]);
    L := RuleLinesOf(P);
    if Length(L) > 0 then
    begin
      Add('  Rules:');
      for I := 0 to High(L) do
        Add('    ' + L[I]);
    end;
    L := HiddenColumnsOf(P);
    if Length(L) > 0 then
    begin
      Add('  Hidden from JSON:');
      for I := 0 to High(L) do
        Add('    ' + L[I]);
    end;
    if Length(P.Relations) > 0 then
    begin
      Add('  Relations:');
      for I := 0 to High(P.Relations) do
        if P.Relations[I].Kind = prBelongsTo then
          Add(Format('    belongs to %s (T%s) by %s',
            [P.Relations[I].Name, P.Relations[I].Model, P.Relations[I].ForeignKey]))
        else
          Add(Format('    has many %s (T%s) by %s.%s',
            [P.Relations[I].Name, P.Relations[I].Model, P.Relations[I].Table,
             P.Relations[I].ForeignKey]));
    end;
    Add('  Sorted by ' + P.DefaultSort + ' unless the request says otherwise.');
  end;
  if Length(P.Notes) > 0 then
  begin
    Add('');
    Add('Worth knowing:');
    for I := 0 to High(P.Notes) do
      Add('  - ' + P.Notes[I]);
  end;
  Result := '';
  for I := 0 to High(B) do
    Result := Result + B[I] + LineEnding;
end;

end.
