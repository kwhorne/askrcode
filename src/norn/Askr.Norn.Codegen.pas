{ Askr.Norn.Codegen — generates typed columns from the actual schema.

  The Norns write, Urd remembers. These are the files Urd reads.

  For each table a unit is made with a record of TCol<T> constants. They are
  what turns a typo in a column name into a compile error, and what keeps
  .Where(Customers.Balance, GT, 'abc') from compiling.

  In addition a manifest is made with indexes, foreign keys and cardinality.
  The PRD points at the manifest as the basis for three analyses: a warning
  on a Where against a column without an index, N+1 in a loop, and Inertia
  fields that do not exist. None of them can be enforced at compile time in
  Free Pascal, because the language has no comptime. The manifest is
  therefore data and lookups at run time — enough for an analyser outside
  the compiler, not enough for what the PRD promises. That is one of the
  things phase 3 has to take a position on.

  The files here are never edited by hand and are checked into git.
  `askr schema:check` says so when they no longer match the database. }
unit Askr.Norn.Codegen;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, Askr.Urd.Driver,
  Askr.Norn.Schema, Askr.Norn.Introspect, Askr.Norn.Migration;

type
  TCodegenOptions = record
    OutputDir: string;
    UnitPrefix: string;
    SkipTables: string;   { kommaseparert }
  end;

  TGeneratedFile = record
    FileName: string;
    Source: string;
  end;
  TGeneratedFiles = array of TGeneratedFile;

function DefaultCodegenOptions: TCodegenOptions;

{ Bygger kildekoden i minnet. Skriver ingenting. }
function GenerateSources(Schema: TDbSchema;
  const Opts: TCodegenOptions): TGeneratedFiles;

{ Writes the files. Returns the names of the ones that actually
  changed. }
function WriteSources(const Files: TGeneratedFiles;
  const Opts: TCodegenOptions): TStringArray;

{ Compares generated source with what is on disk. An empty list means
  they match. }
function CheckDrift(const Files: TGeneratedFiles;
  const Opts: TCodegenOptions): TStringArray;

{ Naming conventions, exposed because the tests and the manifest use
  them. }
function PascalCase(const S: string): string;
function TableTypeName(const Table: string): string;
function TableConstName(const Table: string): string;
function MemberName(const Column: string): string;
function SchemaFingerprint(Schema: TDbSchema): string;
{ The fingerprint for one table. It lives in the table's own file, so that
  a change in customers does not make orders look changed. }
function TableFingerprint(T: TDbTable): string;

implementation

const
  { Words that cannot be used as field names. If a column name collides
    with one of them, the member gets a trailing underscore. }
  Reserved: array[0..40] of string = (
    'and', 'array', 'as', 'begin', 'case', 'class', 'const', 'div', 'do',
    'downto', 'else', 'end', 'except', 'file', 'for', 'function', 'goto',
    'if', 'implementation', 'in', 'inherited', 'interface', 'is', 'label',
    'mod', 'nil', 'not', 'object', 'of', 'or', 'procedure', 'program',
    'record', 'repeat', 'set', 'then', 'to', 'type', 'unit', 'uses', 'var'
  );

function DefaultCodegenOptions: TCodegenOptions;
begin
  Result.OutputDir := 'app/Schema';
  Result.UnitPrefix := 'App.Schema';
  Result.SkipTables := MigrationsTable;
end;

function IsReserved(const S: string): Boolean;
var
  I: Integer;
  L: string;
begin
  L := LowerCase(S);
  for I := Low(Reserved) to High(Reserved) do
    if Reserved[I] = L then
      Exit(True);
  Result := False;
end;

function PascalCase(const S: string): string;
var
  I: Integer;
  Upper: Boolean;
begin
  Result := '';
  Upper := True;
  for I := 1 to Length(S) do
  begin
    if S[I] = '_' then
    begin
      Upper := True;
      Continue;
    end;
    if Upper then
      Result := Result + UpCase(S[I])
    else
      Result := Result + S[I];
    Upper := False;
  end;
end;

function TableTypeName(const Table: string): string;
begin
  Result := 'T' + PascalCase(Table) + 'Columns';
end;

function TableConstName(const Table: string): string;
begin
  Result := PascalCase(Table);
end;

function MemberName(const Column: string): string;
begin
  Result := PascalCase(Column);
  if IsReserved(Result) then
    Result := Result + '_';
end;

function Pad(const S: string; Width: Integer): string;
begin
  Result := S;
  while Length(Result) < Width do
    Result := Result + ' ';
end;

{ FNV-1a. It does not need to be cryptographic — it only has to change
  when the schema does.

  The algorithm is built on the multiplication overflowing and being cut
  modulo the word size. If somebody builds with -Cr or -Co, which is
  entirely reasonable in a debug build, the intended wraparound becomes an
  ERangeError. The dependency is therefore written here rather than being
  tacit. }
{$push}{$R-}{$Q-}
function Fnv1a(const S: string; Seed: QWord): QWord;
var
  I: Integer;
begin
  Result := Seed;
  for I := 1 to Length(S) do
  begin
    Result := Result xor QWord(Ord(S[I]));
    Result := Result * QWord(1099511628211);
  end;
end;

function HashTable(T: TDbTable; Seed: QWord): QWord;
var
  J, K: Integer;
  C: TDbColumn;
  Idx: TDbIndex;
  FK: TDbForeignKey;
begin
  Result := Fnv1a(T.Name + '|', Seed);
  for J := 0 to T.ColumnCount - 1 do
  begin
    C := T.Column(J);
    Result := Fnv1a(Format('%s:%s:%d:%d:%d:%d|',
      [C.Name, C.SqlType, Ord(C.Nullable), Ord(C.IsPrimaryKey),
       C.MaxLength, C.Scale]), Result);
  end;
  for J := 0 to T.IndexCount - 1 do
  begin
    Idx := T.IndexAt(J);
    Result := Fnv1a('i:' + Idx.Name + ':', Result);
    for K := 0 to High(Idx.Columns) do
      Result := Fnv1a(Idx.Columns[K] + ',', Result);
    Result := Fnv1a(Format(':%d:%d|',
      [Ord(Idx.IsUnique), Ord(Idx.IsPrimary)]), Result);
  end;
  for J := 0 to T.ForeignKeyCount - 1 do
  begin
    FK := T.ForeignKey(J);
    Result := Fnv1a(Format('f:%s>%s.%s|',
      [FK.Column, FK.RefTable, FK.RefColumn]), Result);
  end;
end;

function TableFingerprint(T: TDbTable): string;
begin
  Result := LowerCase(IntToHex(HashTable(T, QWord(14695981039346656037)), 16));
end;

function SchemaFingerprint(Schema: TDbSchema): string;
var
  H: QWord;
  I: Integer;
begin
  H := QWord(14695981039346656037);
  for I := 0 to Schema.TableCount - 1 do
    H := HashTable(Schema.TableAt(I), H);
  Result := LowerCase(IntToHex(H, 16));
end;
{$pop}

function Header(const UnitName, Fingerprint: string): string;
begin
  Result :=
    '{ GENERATED BY NORN - DO NOT EDIT.' + LineEnding +
    LineEnding +
    '  This file is read from the live database schema, not from the' + LineEnding +
    '  migrations. Change the schema with a migration and run `askr migrate`;' + LineEnding +
    '  `askr schema:check` tells you when this file no longer matches.' + LineEnding +
    LineEnding +
    '  Schema fingerprint: ' + Fingerprint + ' }' + LineEnding +
    'unit ' + UnitName + ';' + LineEnding +
    LineEnding +
    '{$mode Delphi}{$H+}' + LineEnding +
    LineEnding +
    'interface' + LineEnding +
    LineEnding;
end;

function GenerateTableUnit(T: TDbTable; const Opts: TCodegenOptions): string;
var
  UnitName, TypeName, ConstName: string;
  I, WName, WType: Integer;
  C: TDbColumn;
  Alias, Member: string;
  B: TStringList;
begin
  UnitName := Opts.UnitPrefix + '.' + PascalCase(T.Name);
  TypeName := TableTypeName(T.Name);
  ConstName := TableConstName(T.Name);

  { The columns are lined up, so the file is readable when somebody does
    open it. }
  WName := 0;
  WType := 0;
  for I := 0 to T.ColumnCount - 1 do
  begin
    C := T.Column(I);
    Member := MemberName(C.Name);
    if Length(Member) > WName then
      WName := Length(Member);
    Alias := ColAliasFor(C.SqlType, C.Scale);
    if Length(Alias) > WType then
      WType := Length(Alias);
  end;

  B := TStringList.Create;
  try
    B.Add(Header(UnitName, TableFingerprint(T)));
    B.Add('uses');
    B.Add('  Askr.Urd.Query;');
    B.Add('');
    B.Add('type');
    B.Add('  ' + TypeName + ' = record');
    for I := 0 to T.ColumnCount - 1 do
    begin
      C := T.Column(I);
      Alias := ColAliasFor(C.SqlType, C.Scale);
      Member := MemberName(C.Name);
      B.Add(Format('    const %s : %s = (Name: ''%s''; Table: ''%s'');',
        [Pad(Member, WName), Pad(Alias, WType), C.Name, T.Name]));
    end;
    B.Add('  end;');
    B.Add('');
    B.Add('var');
    B.Add(Format('  %s: %s;', [ConstName, TypeName]));
    B.Add('');
    B.Add('implementation');
    B.Add('');
    B.Add('end.');
    Result := B.Text;
  finally
    B.Free;
  end;
end;

function JoinColumns(const Cols: TStringArray): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Cols) do
  begin
    if I > 0 then
      Result := Result + ',';
    Result := Result + Cols[I];
  end;
end;

function GenerateManifest(Schema: TDbSchema; const Opts: TCodegenOptions;
  const Fingerprint: string): string;
var
  B: TStringList;
  I, J, Total: Integer;
  T: TDbTable;
  C: TDbColumn;
  Idx: TDbIndex;
  FK: TDbForeignKey;
  UnitName: string;

  procedure AddEntry(const Line: string; Last: Boolean);
  begin
    if Last then
      B.Add('    ' + Line)
    else
      B.Add('    ' + Line + ',');
  end;

begin
  UnitName := Opts.UnitPrefix + '.Manifest';
  B := TStringList.Create;
  try
    B.Add(Header(UnitName, Fingerprint));
    B.Add('type');
    B.Add('  TManifestColumn = record');
    B.Add('    Table: string;');
    B.Add('    Name: string;');
    B.Add('    SqlType: string;');
    B.Add('    PascalType: string;');
    B.Add('    Nullable: Boolean;');
    B.Add('    PrimaryKey: Boolean;');
    B.Add('    Indexed: Boolean;');
    B.Add('  end;');
    B.Add('');
    B.Add('  TManifestIndex = record');
    B.Add('    Table: string;');
    B.Add('    Name: string;');
    B.Add('    Columns: string;');
    B.Add('    Unique: Boolean;');
    B.Add('    Primary: Boolean;');
    B.Add('  end;');
    B.Add('');
    B.Add('  TManifestForeignKey = record');
    B.Add('    Table: string;');
    B.Add('    Column: string;');
    B.Add('    RefTable: string;');
    B.Add('    RefColumn: string;');
    B.Add('  end;');
    B.Add('');
    B.Add('const');
    B.Add('  SchemaAvtrykk = ''' + Fingerprint + ''';');
    B.Add('');

    { Kolonner }
    Total := 0;
    for I := 0 to Schema.TableCount - 1 do
      Inc(Total, Schema.TableAt(I).ColumnCount);
    B.Add(Format('  ManifestColumns: array[0..%d] of TManifestColumn = (',
      [Total - 1]));
    Total := 0;
    for I := 0 to Schema.TableCount - 1 do
    begin
      T := Schema.TableAt(I);
      for J := 0 to T.ColumnCount - 1 do
      begin
        C := T.Column(J);
        Inc(Total);
        AddEntry(Format(
          '(Table: ''%s''; Name: ''%s''; SqlType: ''%s''; PascalType: ''%s''; ' +
          'Nullable: %s; PrimaryKey: %s; Indexed: %s)',
          [T.Name, C.Name, C.SqlType, PascalTypeFor(C.SqlType, C.Scale),
           BoolToStr(C.Nullable, 'True', 'False'),
           BoolToStr(C.IsPrimaryKey, 'True', 'False'),
           BoolToStr(T.IsIndexed(C.Name), 'True', 'False')]),
          (I = Schema.TableCount - 1) and (J = T.ColumnCount - 1));
      end;
    end;
    B.Add('  );');
    B.Add('');

    { Indekser }
    Total := 0;
    for I := 0 to Schema.TableCount - 1 do
      Inc(Total, Schema.TableAt(I).IndexCount);
    if Total = 0 then
      B.Add('  ManifestIndexes: array[0..0] of TManifestIndex = ' +
            '((Table: ''''; Name: ''''; Columns: ''''; Unique: False; Primary: False));')
    else
    begin
      B.Add(Format('  ManifestIndexes: array[0..%d] of TManifestIndex = (',
        [Total - 1]));
      for I := 0 to Schema.TableCount - 1 do
      begin
        T := Schema.TableAt(I);
        for J := 0 to T.IndexCount - 1 do
        begin
          Idx := T.IndexAt(J);
          AddEntry(Format(
            '(Table: ''%s''; Name: ''%s''; Columns: ''%s''; Unique: %s; Primary: %s)',
            [T.Name, Idx.Name, JoinColumns(Idx.Columns),
             BoolToStr(Idx.IsUnique, 'True', 'False'),
             BoolToStr(Idx.IsPrimary, 'True', 'False')]),
            (I = Schema.TableCount - 1) and (J = T.IndexCount - 1));
        end;
      end;
      B.Add('  );');
    end;
    B.Add('');

    { Foreign keys — the cardinality the PRD asks for is here: each row is
      a many-to-one from Table.Column to RefTable.RefColumn. }
    Total := 0;
    for I := 0 to Schema.TableCount - 1 do
      Inc(Total, Schema.TableAt(I).ForeignKeyCount);
    if Total = 0 then
      B.Add('  ManifestForeignKeys: array[0..0] of TManifestForeignKey = ' +
            '((Table: ''''; Column: ''''; RefTable: ''''; RefColumn: ''''));')
    else
    begin
      B.Add(Format('  ManifestForeignKeys: array[0..%d] of TManifestForeignKey = (',
        [Total - 1]));
      for I := 0 to Schema.TableCount - 1 do
      begin
        T := Schema.TableAt(I);
        for J := 0 to T.ForeignKeyCount - 1 do
        begin
          FK := T.ForeignKey(J);
          AddEntry(Format(
            '(Table: ''%s''; Column: ''%s''; RefTable: ''%s''; RefColumn: ''%s'')',
            [T.Name, FK.Column, FK.RefTable, FK.RefColumn]),
            (I = Schema.TableCount - 1) and (J = T.ForeignKeyCount - 1));
        end;
      end;
      B.Add('  );');
    end;

    B.Add('');
    B.Add('{ Lookups at run time. The PRD wants these at compile time — that');
    B.Add('  requires comptime, which Free Pascal does not have. See the');
    B.Add('  Rún document. }');
    B.Add('function ColumnExists(const Table, Column: string): Boolean;');
    B.Add('function IsIndexed(const Table, Column: string): Boolean;');
    B.Add('function PascalTypeOf(const Table, Column: string): string;');
    B.Add('');
    B.Add('implementation');
    B.Add('');
    { uses belongs right after implementation, not at the bottom. }
    B.Add('uses');
    B.Add('  SysUtils;');
    B.Add('');
    B.Add('function IndexOfColumn(const Table, Column: string): Integer;');
    B.Add('var');
    B.Add('  I: Integer;');
    B.Add('begin');
    B.Add('  for I := Low(ManifestColumns) to High(ManifestColumns) do');
    B.Add('    if SameText(ManifestColumns[I].Table, Table) and');
    B.Add('       SameText(ManifestColumns[I].Name, Column) then');
    B.Add('      Exit(I);');
    B.Add('  Result := -1;');
    B.Add('end;');
    B.Add('');
    B.Add('function ColumnExists(const Table, Column: string): Boolean;');
    B.Add('begin');
    B.Add('  Result := IndexOfColumn(Table, Column) >= 0;');
    B.Add('end;');
    B.Add('');
    B.Add('function IsIndexed(const Table, Column: string): Boolean;');
    B.Add('var');
    B.Add('  I: Integer;');
    B.Add('begin');
    B.Add('  I := IndexOfColumn(Table, Column);');
    B.Add('  Result := (I >= 0) and ManifestColumns[I].Indexed;');
    B.Add('end;');
    B.Add('');
    B.Add('function PascalTypeOf(const Table, Column: string): string;');
    B.Add('var');
    B.Add('  I: Integer;');
    B.Add('begin');
    B.Add('  I := IndexOfColumn(Table, Column);');
    B.Add('  if I < 0 then');
    B.Add('    Exit('''');');
    B.Add('  Result := ManifestColumns[I].PascalType;');
    B.Add('end;');
    B.Add('');
    B.Add('end.');
    Result := B.Text;
  finally
    B.Free;
  end;
end;

function ShouldSkip(const Table, SkipList: string): Boolean;
var
  Parts: TStringList;
  I: Integer;
begin
  Result := False;
  if SkipList = '' then
    Exit;
  Parts := TStringList.Create;
  try
    Parts.CommaText := SkipList;
    for I := 0 to Parts.Count - 1 do
      if SameText(Trim(Parts[I]), Table) then
        Exit(True);
  finally
    Parts.Free;
  end;
end;

function GenerateSources(Schema: TDbSchema;
  const Opts: TCodegenOptions): TGeneratedFiles;
var
  I, N: Integer;
  T: TDbTable;
  Fingerprint: string;
begin
  Result := nil;
  Fingerprint := SchemaFingerprint(Schema);
  for I := 0 to Schema.TableCount - 1 do
  begin
    T := Schema.TableAt(I);
    if ShouldSkip(T.Name, Opts.SkipTables) then
      Continue;
    if T.ColumnCount = 0 then
      Continue;
    N := Length(Result);
    SetLength(Result, N + 1);
    Result[N].FileName := Opts.UnitPrefix + '.' + PascalCase(T.Name) + '.pas';
    Result[N].Source := GenerateTableUnit(T, Opts);
  end;
  N := Length(Result);
  SetLength(Result, N + 1);
  Result[N].FileName := Opts.UnitPrefix + '.Manifest.pas';
  Result[N].Source := GenerateManifest(Schema, Opts, Fingerprint);
end;

function ReadWhole(const Path: string): string;
var
  L: TStringList;
begin
  Result := '';
  if not FileExists(Path) then
    Exit;
  L := TStringList.Create;
  try
    L.LoadFromFile(Path);
    Result := L.Text;
  finally
    L.Free;
  end;
end;

function WriteSources(const Files: TGeneratedFiles;
  const Opts: TCodegenOptions): TStringArray;
var
  I, N: Integer;
  Path: string;
  L: TStringList;
begin
  Result := nil;
  if not DirectoryExists(Opts.OutputDir) then
    if not ForceDirectories(Opts.OutputDir) then
      raise ENornError.CreateFmt('Could not create %s', [Opts.OutputDir]);

  for I := 0 to High(Files) do
  begin
    Path := IncludeTrailingPathDelimiter(Opts.OutputDir) + Files[I].FileName;
    { Unchanged files are left alone, so that timestamps and incremental
      compilation are not disturbed for no reason. }
    if ReadWhole(Path) = Files[I].Source then
      Continue;
    L := TStringList.Create;
    try
      L.Text := Files[I].Source;
      L.SaveToFile(Path);
    finally
      L.Free;
    end;
    N := Length(Result);
    SetLength(Result, N + 1);
    Result[N] := Files[I].FileName;
  end;
end;

function CheckDrift(const Files: TGeneratedFiles;
  const Opts: TCodegenOptions): TStringArray;
var
  I, N: Integer;
  Path, OnDisk: string;
begin
  Result := nil;
  for I := 0 to High(Files) do
  begin
    Path := IncludeTrailingPathDelimiter(Opts.OutputDir) + Files[I].FileName;
    OnDisk := ReadWhole(Path);
    if OnDisk = Files[I].Source then
      Continue;
    N := Length(Result);
    SetLength(Result, N + 1);
    if OnDisk = '' then
      Result[N] := Files[I].FileName + ' (missing)'
    else
      Result[N] := Files[I].FileName + ' (differs)';
  end;
end;

end.
