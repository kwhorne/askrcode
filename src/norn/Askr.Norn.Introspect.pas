{ Askr.Norn.Introspect — leser det faktiske skjemaet ut av databasen.

  Dette er halve poenget med Norn. Migrasjonen sier hva som skulle skje;
  introspeksjonen sier hva som faktisk står der. Codegen bygger på det siste,
  ikke det første, slik at en kolonne som ble lagt til for hånd eller en
  migrasjon som feilet halvveis ikke blir usynlig.

  Postgres og SQLite er implementert. MySQL har samme form og kan legges til
  uten å røre codegen. }
unit Askr.Norn.Introspect;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, Askr.Core.Arena, Askr.Core.Text,
  Askr.Urd.Driver, Askr.Norn.Schema;

type
  TDbColumn = record
    Name: string;
    SqlType: string;
    Nullable: Boolean;
    DefaultExpr: string;
    MaxLength: Integer;
    Precision: Integer;
    Scale: Integer;
    IsPrimaryKey: Boolean;
    Position: Integer;
  end;

  TDbForeignKey = record
    Column: string;
    RefTable: string;
    RefColumn: string;
    Name: string;
  end;

  TDbIndex = record
    Name: string;
    Columns: TStringArray;
    IsUnique: Boolean;
    IsPrimary: Boolean;
  end;

  TDbTable = class
  private
    FName: string;
    FColumns: array of TDbColumn;
    FForeignKeys: array of TDbForeignKey;
    FIndexes: array of TDbIndex;
  public
    constructor Create(const AName: string);
    function ColumnCount: Integer;
    function Column(Index: Integer): TDbColumn;
    function IndexOfColumn(const AName: string): Integer;
    function HasColumn(const AName: string): Boolean;
    function PrimaryKey: string;
    function ForeignKeyCount: Integer;
    function ForeignKey(Index: Integer): TDbForeignKey;
    function IndexCount: Integer;
    function IndexAt(Index: Integer): TDbIndex;
    { True når kolonnen er første kolonne i en indeks. Det er dette en
      advarsel om «Where mot kolonne uten indeks» må bygge på. }
    function IsIndexed(const AColumn: string): Boolean;
    property Name: string read FName;
  end;

  TDbSchema = class
  private
    FTables: TList;
  public
    constructor Create;
    destructor Destroy; override;
    function TableCount: Integer;
    function TableAt(Index: Integer): TDbTable;
    function Table(const AName: string): TDbTable;
    function AddTable(const AName: string): TDbTable;
  end;

{ Leser hele skjemaet. Kalleren eier resultatet. }
function IntrospectSchema(Conn: TDbConnection): TDbSchema;

{ Oversetter en SQL-type til kolonnetypen query builderen bruker.
  Returnerer navnet på TCol-aliaset: 'TColInt64', 'TColStr' og så videre. }
function ColAliasFor(const SqlType: string; Scale: Integer): string;
{ Pascal-typen bak aliaset, til bruk i kommentarer og manifest. }
function PascalTypeFor(const SqlType: string; Scale: Integer): string;

implementation

{ TDbTable }

constructor TDbTable.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
end;

function TDbTable.ColumnCount: Integer;
begin
  Result := Length(FColumns);
end;

function TDbTable.Column(Index: Integer): TDbColumn;
begin
  Result := FColumns[Index];
end;

function TDbTable.IndexOfColumn(const AName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FColumns) do
    if SameText(FColumns[I].Name, AName) then
      Exit(I);
  Result := -1;
end;

function TDbTable.HasColumn(const AName: string): Boolean;
begin
  Result := IndexOfColumn(AName) >= 0;
end;

function TDbTable.PrimaryKey: string;
var
  I: Integer;
begin
  for I := 0 to High(FColumns) do
    if FColumns[I].IsPrimaryKey then
      Exit(FColumns[I].Name);
  Result := '';
end;

function TDbTable.ForeignKeyCount: Integer;
begin
  Result := Length(FForeignKeys);
end;

function TDbTable.ForeignKey(Index: Integer): TDbForeignKey;
begin
  Result := FForeignKeys[Index];
end;

function TDbTable.IndexCount: Integer;
begin
  Result := Length(FIndexes);
end;

function TDbTable.IndexAt(Index: Integer): TDbIndex;
begin
  Result := FIndexes[Index];
end;

function TDbTable.IsIndexed(const AColumn: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FIndexes) do
    if (Length(FIndexes[I].Columns) > 0) and
       SameText(FIndexes[I].Columns[0], AColumn) then
      Exit(True);
  Result := False;
end;

{ TDbSchema }

constructor TDbSchema.Create;
begin
  inherited Create;
  FTables := TList.Create;
end;

destructor TDbSchema.Destroy;
var
  I: Integer;
begin
  for I := 0 to FTables.Count - 1 do
    TDbTable(FTables[I]).Free;
  FTables.Free;
  inherited Destroy;
end;

function TDbSchema.TableCount: Integer;
begin
  Result := FTables.Count;
end;

function TDbSchema.TableAt(Index: Integer): TDbTable;
begin
  Result := TDbTable(FTables[Index]);
end;

function TDbSchema.Table(const AName: string): TDbTable;
var
  I: Integer;
begin
  for I := 0 to FTables.Count - 1 do
    if SameText(TDbTable(FTables[I]).Name, AName) then
      Exit(TDbTable(FTables[I]));
  Result := nil;
end;

function TDbSchema.AddTable(const AName: string): TDbTable;
begin
  Result := TDbTable.Create(AName);
  FTables.Add(Result);
end;

{ Typeoversettelse }

function ColAliasFor(const SqlType: string; Scale: Integer): string;
var
  T: string;
begin
  T := LowerCase(Trim(SqlType));
  if (T = 'bigint') or (T = 'integer') or (T = 'int') or (T = 'int4') or
     (T = 'int8') or (T = 'smallint') or (T = 'int2') or (T = 'serial') or
     (T = 'bigserial') then
    Exit('TColInt64');
  { MySQL og SQLite har ingen egen boolsk type: begge skriver TINYINT(1),
    og det er konvensjonen som gjør den boolsk. Bredden må derfor leses før
    parentesen strykes. }
  if (T = 'tinyint(1)') or (T = 'bit(1)') then
    Exit('TColBool');
  { SQLite oppgir typen slik den ble erklært: NUMERIC(12,2), VARCHAR(60),
    TINYINT(1). MySQLs column_type ser likedan ut. Parentesen må vekk før
    sammenlikningen. }
  if Pos('(', T) > 0 then
    T := Trim(Copy(T, 1, Pos('(', T) - 1));
  { Resten av MySQLs heltallstyper. Uten dem ville en mediumint blitt tekst. }
  if (T = 'tinyint') or (T = 'mediumint') or (T = 'year') then
    Exit('TColInt64');
  if (T = 'bigint') or (T = 'integer') or (T = 'int') or (T = 'smallint') then
    Exit('TColInt64');
  if T = 'varchar' then
    Exit('TColStr');
  if (T = 'boolean') or (T = 'bool') then
    Exit('TColBool');
  if (T = 'numeric') or (T = 'decimal') or (T = 'money') then
  begin
    { Currency har fire desimaler. Mer enn det måtte gått til flyttall, og da
      er det bedre å si det enn å miste presisjon i det stille. }
    if (Scale >= 0) and (Scale <= 4) then
      Exit('TColCurrency');
    Exit('TColFloat');
  end;
  if (T = 'double precision') or (T = 'double') or (T = 'real') or
     (T = 'float') or (T = 'float4') or (T = 'float8') then
    Exit('TColFloat');
  { MySQLs datetime starter ikke med «time», og ville falt gjennom til tekst
    hvis den ikke sto her. }
  if (Pos('timestamp', T) = 1) or (T = 'date') or (T = 'datetime') or
     (Pos('time', T) = 1) then
    Exit('TColDateTime');
  { Alt annet — text, varchar, uuid, jsonb, bytea — behandles som tekst.
    Det er sant for wire-formatet, som er det query builderen ser. }
  Result := 'TColStr';
end;

function PascalTypeFor(const SqlType: string; Scale: Integer): string;
var
  A: string;
begin
  A := ColAliasFor(SqlType, Scale);
  if A = 'TColInt64' then
    Exit('Int64');
  if A = 'TColBool' then
    Exit('Boolean');
  if A = 'TColCurrency' then
    Exit('Currency');
  if A = 'TColFloat' then
    Exit('Double');
  if A = 'TColDateTime' then
    Exit('TDateTime');
  Result := 'string';
end;

{ Postgres }

const
  SqlTables =
    'SELECT table_name FROM information_schema.tables ' +
    'WHERE table_schema = current_schema() AND table_type = ''BASE TABLE'' ' +
    'ORDER BY table_name';

  SqlColumns =
    'SELECT c.table_name, c.column_name, c.data_type, c.is_nullable, ' +
    '       coalesce(c.column_default, ''''), ' +
    '       coalesce(c.character_maximum_length, 0), ' +
    '       coalesce(c.numeric_precision, 0), ' +
    '       coalesce(c.numeric_scale, -1), ' +
    '       c.ordinal_position ' +
    'FROM information_schema.columns c ' +
    'JOIN information_schema.tables t ' +
    '  ON t.table_schema = c.table_schema AND t.table_name = c.table_name ' +
    'WHERE c.table_schema = current_schema() AND t.table_type = ''BASE TABLE'' ' +
    'ORDER BY c.table_name, c.ordinal_position';

  SqlPrimaryKeys =
    'SELECT tc.table_name, kcu.column_name ' +
    'FROM information_schema.table_constraints tc ' +
    'JOIN information_schema.key_column_usage kcu ' +
    '  ON kcu.constraint_name = tc.constraint_name ' +
    ' AND kcu.table_schema = tc.table_schema ' +
    'WHERE tc.table_schema = current_schema() ' +
    '  AND tc.constraint_type = ''PRIMARY KEY''';

  SqlForeignKeys =
    'SELECT tc.table_name, kcu.column_name, ccu.table_name, ' +
    '       ccu.column_name, tc.constraint_name ' +
    'FROM information_schema.table_constraints tc ' +
    'JOIN information_schema.key_column_usage kcu ' +
    '  ON kcu.constraint_name = tc.constraint_name ' +
    ' AND kcu.table_schema = tc.table_schema ' +
    'JOIN information_schema.constraint_column_usage ccu ' +
    '  ON ccu.constraint_name = tc.constraint_name ' +
    ' AND ccu.table_schema = tc.table_schema ' +
    'WHERE tc.table_schema = current_schema() ' +
    '  AND tc.constraint_type = ''FOREIGN KEY'' ' +
    'ORDER BY tc.table_name, kcu.column_name';

  SqlIndexes =
    'SELECT t.relname, i.relname, ix.indisunique, ix.indisprimary, a.attname, ' +
    '       array_position(ix.indkey::int2[], a.attnum) AS ord ' +
    'FROM pg_class t ' +
    'JOIN pg_index ix ON t.oid = ix.indrelid ' +
    'JOIN pg_class i ON i.oid = ix.indexrelid ' +
    'JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(ix.indkey) ' +
    'JOIN pg_namespace n ON n.oid = t.relnamespace ' +
    'WHERE t.relkind = ''r'' AND n.nspname = current_schema() ' +
    'ORDER BY t.relname, i.relname, ord';

procedure AddColumn(T: TDbTable; const C: TDbColumn);
var
  N: Integer;
begin
  N := Length(T.FColumns);
  SetLength(T.FColumns, N + 1);
  T.FColumns[N] := C;
end;

function IntrospectPostgres(Conn: TDbConnection; A: TArena): TDbSchema;
var
  R: TDbResult;
  I, J, N, Col: Integer;
  T: TDbTable;
  C: TDbColumn;
  FK: TDbForeignKey;
  TableName, IdxName, ColName: string;
  Uniq, Prim: Boolean;
begin
  Result := TDbSchema.Create;
  try
    A.Reset;
    R := Conn.Exec(A, SqlTables);
    for I := 0 to R.RowCount - 1 do
      Result.AddTable(R.Value(I, 0).ToString);

    A.Reset;
    R := Conn.Exec(A, SqlColumns);
    for I := 0 to R.RowCount - 1 do
    begin
      T := Result.Table(R.Value(I, 0).ToString);
      if T = nil then
        Continue;
      C.Name := R.Value(I, 1).ToString;
      C.SqlType := R.Value(I, 2).ToString;
      C.Nullable := R.Value(I, 3).SameTextStr('YES');
      C.DefaultExpr := R.Value(I, 4).ToString;
      C.MaxLength := Integer(R.AsInt64(I, 5));
      C.Precision := Integer(R.AsInt64(I, 6));
      C.Scale := Integer(R.AsInt64(I, 7, -1));
      C.Position := Integer(R.AsInt64(I, 8));
      C.IsPrimaryKey := False;
      AddColumn(T, C);
    end;

    A.Reset;
    R := Conn.Exec(A, SqlPrimaryKeys);
    for I := 0 to R.RowCount - 1 do
    begin
      T := Result.Table(R.Value(I, 0).ToString);
      if T = nil then
        Continue;
      J := T.IndexOfColumn(R.Value(I, 1).ToString);
      if J >= 0 then
        T.FColumns[J].IsPrimaryKey := True;
    end;

    A.Reset;
    R := Conn.Exec(A, SqlForeignKeys);
    for I := 0 to R.RowCount - 1 do
    begin
      T := Result.Table(R.Value(I, 0).ToString);
      if T = nil then
        Continue;
      FK.Column := R.Value(I, 1).ToString;
      FK.RefTable := R.Value(I, 2).ToString;
      FK.RefColumn := R.Value(I, 3).ToString;
      FK.Name := R.Value(I, 4).ToString;
      N := Length(T.FForeignKeys);
      SetLength(T.FForeignKeys, N + 1);
      T.FForeignKeys[N] := FK;
    end;

    A.Reset;
    R := Conn.Exec(A, SqlIndexes);
    for I := 0 to R.RowCount - 1 do
    begin
      TableName := R.Value(I, 0).ToString;
      IdxName := R.Value(I, 1).ToString;
      Uniq := R.Value(I, 2).SameTextStr('t');
      Prim := R.Value(I, 3).SameTextStr('t');
      ColName := R.Value(I, 4).ToString;
      T := Result.Table(TableName);
      if T = nil then
        Continue;

      { Radene kommer sortert per indeks, så vi utvider den siste hvis navnet
        er det samme. }
      N := Length(T.FIndexes);
      if (N > 0) and (T.FIndexes[N - 1].Name = IdxName) then
      begin
        Col := Length(T.FIndexes[N - 1].Columns);
        SetLength(T.FIndexes[N - 1].Columns, Col + 1);
        T.FIndexes[N - 1].Columns[Col] := ColName;
      end
      else
      begin
        SetLength(T.FIndexes, N + 1);
        T.FIndexes[N].Name := IdxName;
        T.FIndexes[N].IsUnique := Uniq;
        T.FIndexes[N].IsPrimary := Prim;
        SetLength(T.FIndexes[N].Columns, 1);
        T.FIndexes[N].Columns[0] := ColName;
      end;
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ MySQL }

const
  { DATABASE() er skjemaet forbindelsen står i. Det gjør spørringene
    uavhengige av hva databasen heter, på samme måte som current_schema()
    gjør i Postgres. }
  MySqlTables =
    'SELECT table_name FROM information_schema.tables ' +
    'WHERE table_schema = DATABASE() AND table_type = ''BASE TABLE'' ' +
    'ORDER BY table_name';

  { column_type, ikke data_type: det er den som skiller tinyint(1) fra
    tinyint(4), og dermed boolsk fra heltall. }
  MySqlColumns =
    'SELECT table_name, column_name, column_type, is_nullable, ' +
    '       IFNULL(column_default, ''''), ' +
    '       IFNULL(character_maximum_length, 0), ' +
    '       IFNULL(numeric_precision, 0), ' +
    '       IFNULL(numeric_scale, -1), ordinal_position ' +
    'FROM information_schema.columns ' +
    'WHERE table_schema = DATABASE() ' +
    'ORDER BY table_name, ordinal_position';

  MySqlPrimaryKeys =
    'SELECT table_name, column_name ' +
    'FROM information_schema.key_column_usage ' +
    'WHERE table_schema = DATABASE() AND constraint_name = ''PRIMARY''';

  MySqlForeignKeys =
    'SELECT table_name, column_name, referenced_table_name, ' +
    '       referenced_column_name, constraint_name ' +
    'FROM information_schema.key_column_usage ' +
    'WHERE table_schema = DATABASE() AND referenced_table_name IS NOT NULL ' +
    'ORDER BY table_name, constraint_name, ordinal_position';

  { non_unique er 0 for unike indekser — altså omvendt av navnet. Primær-
    nøkkelen heter alltid PRIMARY i MySQL. }
  MySqlIndexes =
    'SELECT table_name, index_name, ' +
    '       CASE WHEN non_unique = 0 THEN 1 ELSE 0 END, ' +
    '       CASE WHEN index_name = ''PRIMARY'' THEN 1 ELSE 0 END, ' +
    '       column_name ' +
    'FROM information_schema.statistics ' +
    'WHERE table_schema = DATABASE() ' +
    'ORDER BY table_name, index_name, seq_in_index';

function IntrospectMySql(Conn: TDbConnection; A: TArena): TDbSchema;
var
  R: TDbResult;
  I, J, N, Col: Integer;
  T: TDbTable;
  C: TDbColumn;
  FK: TDbForeignKey;
  TableName, IdxName, ColName: string;
  Uniq, Prim: Boolean;
begin
  Result := TDbSchema.Create;
  try
    A.Reset;
    R := Conn.Exec(A, MySqlTables);
    for I := 0 to R.RowCount - 1 do
      Result.AddTable(R.Value(I, 0).ToString);

    A.Reset;
    R := Conn.Exec(A, MySqlColumns);
    for I := 0 to R.RowCount - 1 do
    begin
      T := Result.Table(R.Value(I, 0).ToString);
      if T = nil then
        Continue;
      C.Name := R.Value(I, 1).ToString;
      C.SqlType := R.Value(I, 2).ToString;
      C.Nullable := R.Value(I, 3).SameTextStr('YES');
      C.DefaultExpr := R.Value(I, 4).ToString;
      C.MaxLength := Integer(R.AsInt64(I, 5));
      C.Precision := Integer(R.AsInt64(I, 6));
      C.Scale := Integer(R.AsInt64(I, 7, -1));
      C.Position := Integer(R.AsInt64(I, 8));
      C.IsPrimaryKey := False;
      AddColumn(T, C);
    end;

    A.Reset;
    R := Conn.Exec(A, MySqlPrimaryKeys);
    for I := 0 to R.RowCount - 1 do
    begin
      T := Result.Table(R.Value(I, 0).ToString);
      if T = nil then
        Continue;
      J := T.IndexOfColumn(R.Value(I, 1).ToString);
      if J >= 0 then
        T.FColumns[J].IsPrimaryKey := True;
    end;

    A.Reset;
    R := Conn.Exec(A, MySqlForeignKeys);
    for I := 0 to R.RowCount - 1 do
    begin
      T := Result.Table(R.Value(I, 0).ToString);
      if T = nil then
        Continue;
      FK.Column := R.Value(I, 1).ToString;
      FK.RefTable := R.Value(I, 2).ToString;
      FK.RefColumn := R.Value(I, 3).ToString;
      FK.Name := R.Value(I, 4).ToString;
      N := Length(T.FForeignKeys);
      SetLength(T.FForeignKeys, N + 1);
      T.FForeignKeys[N] := FK;
    end;

    A.Reset;
    R := Conn.Exec(A, MySqlIndexes);
    for I := 0 to R.RowCount - 1 do
    begin
      TableName := R.Value(I, 0).ToString;
      IdxName := R.Value(I, 1).ToString;
      Uniq := R.Value(I, 2).EqualsStr('1');
      Prim := R.Value(I, 3).EqualsStr('1');
      ColName := R.Value(I, 4).ToString;
      T := Result.Table(TableName);
      if T = nil then
        Continue;

      N := Length(T.FIndexes);
      if (N > 0) and (T.FIndexes[N - 1].Name = IdxName) then
      begin
        Col := Length(T.FIndexes[N - 1].Columns);
        SetLength(T.FIndexes[N - 1].Columns, Col + 1);
        T.FIndexes[N - 1].Columns[Col] := ColName;
      end
      else
      begin
        SetLength(T.FIndexes, N + 1);
        T.FIndexes[N].Name := IdxName;
        T.FIndexes[N].IsUnique := Uniq;
        T.FIndexes[N].IsPrimary := Prim;
        SetLength(T.FIndexes[N].Columns, 1);
        T.FIndexes[N].Columns[0] := ColName;
      end;
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ SQLite har ingen information_schema. Alt går gjennom pragmaer, og de
  returnerer én tabell om gangen — derfor løkka over tabellnavn. }
function IntrospectSqlite(Conn: TDbConnection; A: TArena): TDbSchema;
var
  R, RC, RI, RF: TDbResult;
  I, J, K, N: Integer;
  T: TDbTable;
  C: TDbColumn;
  FK: TDbForeignKey;
  Navn, IdxNavn: string;
  Tabeller: array of string;
begin
  Result := TDbSchema.Create;
  try
    A.Reset;
    R := Conn.Exec(A, 'SELECT name FROM sqlite_master ' +
      'WHERE type = ''table'' AND name NOT LIKE ''sqlite_%'' ORDER BY name');
    SetLength(Tabeller, R.RowCount);
    for I := 0 to R.RowCount - 1 do
    begin
      Tabeller[I] := R.Value(I, 0).ToString;
      Result.AddTable(Tabeller[I]);
    end;

    for I := 0 to High(Tabeller) do
    begin
      Navn := Tabeller[I];
      T := Result.Table(Navn);

      A.Reset;
      RC := Conn.Exec(A, 'PRAGMA table_info(''' + Navn + ''')');
      for J := 0 to RC.RowCount - 1 do
      begin
        { cid, name, type, notnull, dflt_value, pk }
        C.Name := RC.Value(J, 1).ToString;
        C.SqlType := RC.Value(J, 2).ToString;
        C.Nullable := RC.Value(J, 3).EqualsStr('0');
        C.DefaultExpr := RC.Value(J, 4).ToString;
        C.MaxLength := 0;
        C.Precision := 0;
        { SQLite oppgir NUMERIC(12,2) som typetekst, ikke som egne felter.
          Skalaen leses ut av teksten, fordi det er den som avgjør om
          kolonnen blir Currency eller Double i generert kode. }
        C.Scale := -1;
        K := Pos(',', C.SqlType);
        if (K > 0) and (Pos('(', C.SqlType) > 0) then
          C.Scale := StrToIntDef(Trim(StringReplace(
            Copy(C.SqlType, K + 1, Length(C.SqlType) - K - 1), ')', '',
            [rfReplaceAll])), -1);
        C.IsPrimaryKey := not RC.Value(J, 5).EqualsStr('0');
        C.Position := J + 1;
        AddColumn(T, C);
      end;

      A.Reset;
      RI := Conn.Exec(A, 'PRAGMA index_list(''' + Navn + ''')');
      for J := 0 to RI.RowCount - 1 do
      begin
        { seq, name, unique, origin, partial }
        IdxNavn := RI.Value(J, 1).ToString;
        N := Length(T.FIndexes);
        SetLength(T.FIndexes, N + 1);
        T.FIndexes[N].Name := IdxNavn;
        T.FIndexes[N].IsUnique := not RI.Value(J, 2).EqualsStr('0');
        T.FIndexes[N].IsPrimary := RI.Value(J, 3).EqualsStr('pk');
        SetLength(T.FIndexes[N].Columns, 0);
      end;
      { Kolonnene per indeks krever et eget pragma-kall, og det må gjøres
        etter at index_list er lest ferdig — arenaen nullstilles under. }
      for J := 0 to High(T.FIndexes) do
      begin
        A.Reset;
        RI := Conn.Exec(A, 'PRAGMA index_info(''' + T.FIndexes[J].Name + ''')');
        SetLength(T.FIndexes[J].Columns, RI.RowCount);
        for K := 0 to RI.RowCount - 1 do
          T.FIndexes[J].Columns[K] := RI.Value(K, 2).ToString;
      end;

      A.Reset;
      RF := Conn.Exec(A, 'PRAGMA foreign_key_list(''' + Navn + ''')');
      for J := 0 to RF.RowCount - 1 do
      begin
        { id, seq, table, from, to, on_update, on_delete, match }
        FK.Column := RF.Value(J, 3).ToString;
        FK.RefTable := RF.Value(J, 2).ToString;
        FK.RefColumn := RF.Value(J, 4).ToString;
        if FK.RefColumn = '' then
          FK.RefColumn := 'id';
        FK.Name := Format('%s_%s_fk', [Navn, FK.Column]);
        N := Length(T.FForeignKeys);
        SetLength(T.FForeignKeys, N + 1);
        T.FForeignKeys[N] := FK;
      end;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function IntrospectSchema(Conn: TDbConnection): TDbSchema;
var
  A: TArena;
begin
  A := TArena.Create(256 * 1024);
  try
    case Conn.Dialect of
      sdPostgres: Result := IntrospectPostgres(Conn, A);
      sdSqlite: Result := IntrospectSqlite(Conn, A);
      sdMySql: Result := IntrospectMySql(Conn, A);
    end;
  finally
    A.Free;
  end;
end;

end.
