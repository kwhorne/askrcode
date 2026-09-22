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

type
  { What is wrong with one file, if anything.

    They are told apart because they call for different reactions, and
    only the last is harmless: an older `askr schema` wrote the header,
    and everything below it is what would be written today. Failing CI
    over that after every upgrade would teach people to ignore the check.

    Retyped is the one that is easy to wave through and must not be. The
    table is unchanged -- the fingerprint says so -- but this version
    types it differently. That has happened: SQLite used to declare
    created_at as TEXT, and the same migration typed it `string` there and
    `TDateTime` against Postgres. Code compiling against the old types is
    compiling against a description that is no longer the framework's.

    The fingerprint in the header is what tells a changed table from the
    rest. It was written into every file from the start, and until now
    nothing read it. }
  TDriftKind = (
    dkMissing,        { a table with no file }
    dkChanged,        { the file describes a table that has since changed }
    dkRetyped,        { same table, typed differently by this askr schema }
    dkNoSuchTable,    { a file for a table that is no longer there }
    dkOlderTemplate   { same table, same declarations, older wording }
  );

  TDrift = record
    FileName: string;
    Kind: TDriftKind;
  end;
  TDrifts = array of TDrift;

{ Everything on disk that is not what `askr schema` would write now, in
  both directions: a table with no file, and a file with no table. The
  second is the one that matters most and was not checked at all -- a
  dropped table left its file behind, and code using its columns went on
  compiling against a table that was gone.

  Only files carrying Norn's own header are considered. A file of the
  application's that happens to live in the same directory is never
  reported, and never removed. }
function FindDrift(const Files: TGeneratedFiles;
  const Opts: TCodegenOptions): TDrifts;
{ True for the kinds that mean the file no longer describes the
  database. }
function DriftMatters(Kind: TDriftKind): Boolean;
function DriftText(const D: TDrift): string;

{ The kinds that matter, as text. An empty list means the typed columns
  describe the database. }
function CheckDrift(const Files: TGeneratedFiles;
  const Opts: TCodegenOptions): TStringArray;

{ Removes generated files whose table is gone, and returns their names.
  `askr schema` calls it, because a check that says "no such table" has
  to point at a command that actually fixes it. The files are checked
  into git, so a removal is a diff to read and not a loss. }
function RemoveStaleSources(const Files: TGeneratedFiles;
  const Opts: TCodegenOptions): TStringArray;

{ The fingerprint written in a generated file's header, or ''. Reads the
  older Norwegian wording too, since projects still have files from before
  the language sweep. }
{ What `askr schema` does, as one call: generate every unit, write the
  ones that changed, remove the ones whose table is gone. `make resource`
  calls it too, so the typed columns a generated controller uses are
  the ones `askr schema` would have written -- not a second opinion. }
procedure RegenerateSchema(Schema: TDbSchema; const Opts: TCodegenOptions;
  out Files: TGeneratedFiles; out Changed, Removed: TStringArray);

function FingerprintIn(const Source: string): string;

{ Naming conventions, exposed because the tests and the manifest use
  them. }
function PascalCase(const S: string): string;
function TableTypeName(const Table: string): string;
function TableConstName(const Table: string): string;
function MemberName(const Column: string): string;
{ True for a word Free Pascal reserves in Delphi mode. One list, used by
  the schema units and by `askr make model`, so the two cannot disagree
  about which names need an underscore. }
function IsPascalKeyword(const S: string): Boolean;
function SchemaFingerprint(Schema: TDbSchema): string;
{ The fingerprint for one table. It lives in the table's own file, so that
  a change in customers does not make orders look changed. }
function TableFingerprint(T: TDbTable): string;

implementation

const
  { Every word Free Pascal reserves in Delphi mode: Turbo Pascal's, then
    Object Pascal's. A column with one of these names cannot be a field
    of that name, so the member gets a trailing underscore.

    The list used to have 41 of them. `until`, `while`, `with`, `try`,
    `on`, `out`, `string`, `raise`, `property`, `xor` and sixteen more
    were missing, so a column called any of those produced a schema unit
    that did not compile. `askr make model` had a longer list of its own
    for the same rule; it uses this one now. }
  PascalKeywords: array[0..66] of string = (
    'and', 'array', 'as', 'asm', 'begin', 'case', 'class', 'const',
    'constructor', 'destructor', 'dispinterface', 'div', 'do', 'downto',
    'else', 'end', 'except', 'exports', 'file', 'finalization', 'finally',
    'for', 'function', 'goto', 'if', 'implementation', 'in', 'inherited',
    'initialization', 'inline', 'interface', 'is', 'label', 'library',
    'mod', 'nil', 'not', 'object', 'of', 'on', 'operator', 'or', 'out',
    'packed', 'procedure', 'program', 'property', 'raise', 'record',
    'repeat', 'resourcestring', 'set', 'shl', 'shr', 'string', 'then',
    'threadvar', 'to', 'try', 'type', 'unit', 'until', 'uses', 'var',
    'while', 'with', 'xor');

function IsPascalKeyword(const S: string): Boolean;
var
  I: Integer;
  L: string;
begin
  L := LowerCase(S);
  for I := Low(PascalKeywords) to High(PascalKeywords) do
    if PascalKeywords[I] = L then
      Exit(True);
  Result := False;
end;

function IsReserved(const S: string): Boolean;
begin
  Result := IsPascalKeyword(S);
end;

function DefaultCodegenOptions: TCodegenOptions;
begin
  Result.OutputDir := 'app/Schema';
  Result.UnitPrefix := 'App.Schema';
  { The framework's own tables, not only the migrations one. An app with a
    durable queue would otherwise get App.Schema.AskrJobs and
    App.Schema.AskrFailedJobs generated for tables it never queries — and
    they would appear and disappear from `askr schema` depending on whether
    the queue had been used yet. The names are repeated here rather than
    taken from Askr.Queue.Db, because Norn must not depend on the runtime. }
  {
    api_tokens joined them in 0.12.0 and was left off this list, so any
    app that had issued a token got App.Schema.ApiTokens as well -- the
    exact appear-and-disappear the comment above describes. Found by
    writing the check that would have reported it. }
  Result.SkipTables := MigrationsTable +
    ',askr_jobs,askr_failed_jobs,api_tokens';
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

procedure RegenerateSchema(Schema: TDbSchema; const Opts: TCodegenOptions;
  out Files: TGeneratedFiles; out Changed, Removed: TStringArray);
begin
  Files := GenerateSources(Schema, Opts);
  Changed := WriteSources(Files, Opts);
  Removed := RemoveStaleSources(Files, Opts);
end;

function FingerprintIn(const Source: string): string;
const
  Markers: array[0..1] of string = ('Schema fingerprint: ', 'Skjemaavtrykk: ');
var
  I, P, E: Integer;
begin
  Result := '';
  for I := Low(Markers) to High(Markers) do
  begin
    P := Pos(Markers[I], Source);
    if P = 0 then
      Continue;
    P := P + Length(Markers[I]);
    E := P;
    while (E <= Length(Source)) and
          (Source[E] in ['0'..'9', 'a'..'f', 'A'..'F']) do
      Inc(E);
    Exit(LowerCase(Copy(Source, P, E - P)));
  end;
end;

{ Norn's header, in either language. The first line is enough: nothing an
  application writes by hand starts like that. }
function IsGenerated(const Source: string): Boolean;
begin
  Result := (Copy(Source, 1, Length('{ GENERATED BY NORN')) = '{ GENERATED BY NORN') or
            (Copy(Source, 1, Length('{ AUTOGENERERT AV NORN')) = '{ AUTOGENERERT AV NORN');
end;

{ What the file declares, and nothing else: comments out, whitespace
  collapsed to single spaces, string literals kept as they are.

  The first version compared the raw text after the header, and the first
  real project it ran against came back "retyped" -- over a comment in
  the manifest that had been translated when the codebase went English.
  No type had changed. A check that cries wolf over prose is a check
  people stop reading, so what is compared now is the tokens: a changed
  type or name is a difference, a changed sentence or a wider column of
  alignment is not. }
function DeclarationsOf(const Source: string): string;
var
  I, N: Integer;
  C: Char;
  B: TStringBuilder;
  Space: Boolean;
begin
  N := Length(Source);
  B := TStringBuilder.Create;
  try
    I := 1;
    Space := False;
    while I <= N do
    begin
      C := Source[I];
      if C = '''' then
      begin
        { A string literal is part of what is declared, braces and all. }
        if Space and (B.Length > 0) then
          B.Append(' ');
        Space := False;
        B.Append(C);
        Inc(I);
        while I <= N do
        begin
          B.Append(Source[I]);
          if Source[I] = '''' then
          begin
            Inc(I);
            Break;
          end;
          Inc(I);
        end;
        Continue;
      end;
      if C = '{' then
      begin
        while (I <= N) and (Source[I] <> '}') do
          Inc(I);
        Inc(I);
        Space := True;
        Continue;
      end;
      if (C = '(') and (I < N) and (Source[I + 1] = '*') then
      begin
        Inc(I, 2);
        while (I < N) and not ((Source[I] = '*') and (Source[I + 1] = ')')) do
          Inc(I);
        Inc(I, 2);
        Space := True;
        Continue;
      end;
      if (C = '/') and (I < N) and (Source[I + 1] = '/') then
      begin
        while (I <= N) and not (Source[I] in [#10, #13]) do
          Inc(I);
        Space := True;
        Continue;
      end;
      if C in [' ', #9, #10, #13] then
      begin
        Space := True;
        Inc(I);
        Continue;
      end;
      if Space and (B.Length > 0) then
        B.Append(' ');
      Space := False;
      B.Append(C);
      Inc(I);
    end;
    Result := B.ToString;
  finally
    B.Free;
  end;
end;

function Wanted(const Files: TGeneratedFiles; const Name_: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(Files) do
    if SameText(Files[I].FileName, Name_) then
      Exit(True);
  Result := False;
end;

procedure AddDrift(var R: TDrifts; const Name_: string; K: TDriftKind);
begin
  SetLength(R, Length(R) + 1);
  R[High(R)].FileName := Name_;
  R[High(R)].Kind := K;
end;

function FindDrift(const Files: TGeneratedFiles;
  const Opts: TCodegenOptions): TDrifts;
var
  I: Integer;
  Path, OnDisk: string;
  SR: TSearchRec;
  Dir: string;
begin
  Result := nil;
  Dir := IncludeTrailingPathDelimiter(Opts.OutputDir);

  for I := 0 to High(Files) do
  begin
    Path := Dir + Files[I].FileName;
    OnDisk := ReadWhole(Path);
    if OnDisk = Files[I].Source then
      Continue;
    if OnDisk = '' then
      AddDrift(Result, Files[I].FileName, dkMissing)
    else if FingerprintIn(OnDisk) <> FingerprintIn(Files[I].Source) then
      AddDrift(Result, Files[I].FileName, dkChanged)
    else if DeclarationsOf(OnDisk) <> DeclarationsOf(Files[I].Source) then
      AddDrift(Result, Files[I].FileName, dkRetyped)
    else
      { The table is what the file says it is, declared the way it would
        be declared today; only the words around the declarations have
        moved on. }
      AddDrift(Result, Files[I].FileName, dkOlderTemplate);
  end;

  { The other direction. }
  if FindFirst(Dir + Opts.UnitPrefix + '.*.pas', faAnyFile, SR) = 0 then
  try
    repeat
      if Wanted(Files, SR.Name) then
        Continue;
      if not IsGenerated(ReadWhole(Dir + SR.Name)) then
        Continue;
      AddDrift(Result, SR.Name, dkNoSuchTable);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

function DriftMatters(Kind: TDriftKind): Boolean;
begin
  Result := Kind <> dkOlderTemplate;
end;

function DriftText(const D: TDrift): string;
begin
  case D.Kind of
    dkMissing:
      Result := D.FileName + ' is missing: a table with no typed columns';
    dkChanged:
      Result := D.FileName + ' describes the table as it was: it has ' +
        'changed since';
    dkRetyped:
      Result := D.FileName + ' describes the same table with other types ' +
        'than this askr schema would give it';
    dkNoSuchTable:
      Result := D.FileName + ' is for a table that is no longer there, ' +
        'and code using it still compiles';
    dkOlderTemplate:
      Result := D.FileName + ' was written by an older askr schema; what ' +
        'it declares is the same';
  end;
end;

function CheckDrift(const Files: TGeneratedFiles;
  const Opts: TCodegenOptions): TStringArray;
var
  D: TDrifts;
  I: Integer;
begin
  Result := nil;
  D := FindDrift(Files, Opts);
  for I := 0 to High(D) do
    if DriftMatters(D[I].Kind) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := DriftText(D[I]);
    end;
end;

function RemoveStaleSources(const Files: TGeneratedFiles;
  const Opts: TCodegenOptions): TStringArray;
var
  D: TDrifts;
  I: Integer;
begin
  Result := nil;
  D := FindDrift(Files, Opts);
  for I := 0 to High(D) do
    if D[I].Kind = dkNoSuchTable then
      if DeleteFile(IncludeTrailingPathDelimiter(Opts.OutputDir) +
                    D[I].FileName) then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := D[I].FileName;
      end;
end;

end.
