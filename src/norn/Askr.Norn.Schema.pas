{ Askr.Norn.Schema — schema changes described in Pascal, translated into
  SQL.

  The Norns write, Urd remembers. This unit is the writing part: a migration
  describes what is to happen, and the builder translates it into the
  dialect the connection actually speaks.

      with S.Create('customers') do
      begin
        Id;
        Text('name', 120);
        Text('email', 255).Unique;
        Money('balance').Default(0);
        Timestamps;
        Index(['created_at']);
      end;

  Nothing here is arena based. Migrations run outside a request, live
  briefly, and own their objects in the ordinary way. Pulling the arena into
  build time would be lending a mechanism to something it is not for. }
unit Askr.Norn.Schema;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, Askr.Urd.Driver;

type
  ENornError = class(EDbError);

  TColumnType = (
    ctBigSerial,   { auto key }
    ctBigInt,
    ctInt,
    ctSmallInt,
    ctText,        { free text, or VARCHAR(n) when a length is given }
    ctBoolean,
    ctNumeric,     { precision and scale }
    ctFloat,
    ctTimestamp,
    ctDate,
    ctJson,
    ctUuid,
    ctBytes
  );

  TColumnAction = (caAdd, caDrop, caAlter);

  TNornColumn = class
  private
    FName: string;
    FKind: TColumnType;
    FLength: Integer;
    FPrecision: Integer;
    FScale: Integer;
    FNullable: Boolean;
    FDefault: string;
    FHasDefault: Boolean;
    FUnique: Boolean;
    FPrimaryKey: Boolean;
    FRefTable: string;
    FRefColumn: string;
    FOnDelete: string;
    FAction: TColumnAction;
  public
    constructor Create(const AName: string; AKind: TColumnType);

    { The builders return Self, the way the PRD writes it:
      Text('email', 255).Unique
      Money('balance').Default(0) }
    function Nullable: TNornColumn;
    function Unique: TNornColumn;
    function PrimaryKey: TNornColumn;
    function Default(const Value: string): TNornColumn; overload;
    function Default(Value: Int64): TNornColumn; overload;
    function Default(Value: Currency): TNornColumn; overload;
    function Default(Value: Boolean): TNornColumn; overload;
    { Raw SQL as a default value — now(), gen_random_uuid() and the
      like. }
    function DefaultRaw(const Sql: string): TNornColumn;
    function References(const ATable: string; const AColumn: string = 'id';
      const AOnDelete: string = 'CASCADE'): TNornColumn;

    property Name: string read FName;
    property Kind: TColumnType read FKind;
    property RefTable: string read FRefTable;
    property RefColumn: string read FRefColumn;
    property IsUnique: Boolean read FUnique;
    property IsPrimaryKey: Boolean read FPrimaryKey;
    property IsNullable: Boolean read FNullable;
    property Action: TColumnAction read FAction write FAction;
  end;

  TIndexDef = class
  private
    FColumns: TStringList;
    FUnique: Boolean;
    FName: string;
  public
    constructor Create(const AColumns: array of string; AUnique: Boolean);
    destructor Destroy; override;
    property Columns: TStringList read FColumns;
    property IsUnique: Boolean read FUnique;
    property Name: string read FName write FName;
  end;

  TTableOp = (toCreate, toAlter, toDrop, toRename);

  TTableBuilder = class
  private
    FTable: string;
    FNewName: string;
    FOp: TTableOp;
    FColumns: TList;
    FIndexes: TList;
    FDropped: TStringList;
    FIfNotExists: Boolean;
    FIfExists: Boolean;
    function Add(const AName: string; AKind: TColumnType): TNornColumn;
  public
    constructor Create(const ATable: string; AOp: TTableOp);
    destructor Destroy; override;

    { An auto key. Called id unless something else is given. }
    procedure Id(const AName: string = 'id');
    function Text(const AName: string; ALength: Integer = 0): TNornColumn;
    function Int(const AName: string): TNornColumn;
    function BigInt(const AName: string): TNornColumn;
    function SmallInt(const AName: string): TNornColumn;
    function Bool(const AName: string): TNornColumn;
    { NUMERIC(12,2) — nok for penger uten flyttallsavrunding. }
    function Money(const AName: string): TNornColumn;
    function Numeric(const AName: string; APrecision: Integer = 12;
      AScale: Integer = 2): TNornColumn;
    function Float(const AName: string): TNornColumn;
    function Timestamp(const AName: string): TNornColumn;
    function Date(const AName: string): TNornColumn;
    function Json(const AName: string): TNornColumn;
    function Uuid(const AName: string): TNornColumn;
    function Bytes(const AName: string): TNornColumn;
    { BIGINT with a foreign key. ForeignKey('customer_id', 'customers'). }
    function ForeignKey(const AName, ATable: string;
      const AColumn: string = 'id'): TNornColumn;
    { created_at and updated_at, both NOT NULL with now() as the
      default. }
    procedure Timestamps;
    { deleted_at, nullable. The counterpart to S.SoftDeletes on the model —
      without it the column would have to be written by hand while the
      model had one line, and that asymmetry is easy to forget until a
      delete stops working. }
    procedure SoftDeletes(const AName: string = 'deleted_at');

    procedure DropColumn(const AName: string);
    procedure Index(const AColumns: array of string);
    procedure UniqueIndex(const AColumns: array of string);

    property Table: string read FTable;
    property Op: TTableOp read FOp;
    property Columns: TList read FColumns;
    property Indexes: TList read FIndexes;
    property IfNotExists: Boolean read FIfNotExists write FIfNotExists;
    property IfExists: Boolean read FIfExists write FIfExists;
    property NewName: string read FNewName write FNewName;
  end;

  TSchemaBuilder = class
  private
    FOps: TList;
    FRaw: TStringList;
    FDialect: TSqlDialect;
    function AddTable(const ATable: string; AOp: TTableOp): TTableBuilder;
  public
    constructor Create(ADialect: TSqlDialect); overload;
    destructor Destroy; override;

    { The PRD writes S.Create('customers'). The method overloads the
      constructor; the signatures differ, so the resolution is
      unambiguous. }
    function Create(const ATable: string): TTableBuilder; overload;
    function Alter(const ATable: string): TTableBuilder;
    procedure Drop(const ATable: string; AIfExists: Boolean = True);
    procedure Rename(const AFrom, ATo: string);
    { An escape hatch for what the builder does not cover. }
    procedure Execute(const Sql: string);

    { All the statements in order. }
    function ToSql: TStringArray;
    property Dialect: TSqlDialect read FDialect;
  end;

{ Exposed because introspection and codegen need the same
  translation. }
function SqlTypeFor(Kind: TColumnType; Dialect: TSqlDialect;
  Length_, Precision, Scale: Integer): string;

implementation

function QuoteIdent(const AName: string; Dialect: TSqlDialect): string;
var
  Q: Char;
  I: Integer;
begin
  if Dialect = sdMySql then
    Q := '`'
  else
    Q := '"';
  Result := Q;
  for I := 1 to System.Length(AName) do
  begin
    if AName[I] = Q then
      Result := Result + Q;
    Result := Result + AName[I];
  end;
  Result := Result + Q;
end;

function SqlTypeFor(Kind: TColumnType; Dialect: TSqlDialect;
  Length_, Precision, Scale: Integer): string;
begin
  case Kind of
    ctBigSerial:
      case Dialect of
        sdPostgres: Result := 'BIGSERIAL';
        sdMySql:    Result := 'BIGINT AUTO_INCREMENT';
        sdSqlite:   Result := 'INTEGER';
      end;
    ctBigInt:   Result := 'BIGINT';
    ctInt:      Result := 'INTEGER';
    ctSmallInt: Result := 'SMALLINT';
    ctText:
      if Length_ > 0 then
        Result := Format('VARCHAR(%d)', [Length_])
      else if Dialect = sdMySql then
        Result := 'TEXT'
      else
        Result := 'TEXT';
    ctBoolean:
      case Dialect of
        sdPostgres: Result := 'BOOLEAN';
        sdMySql:    Result := 'TINYINT(1)';
        { BOOLEAN, not INTEGER, for the same reason as DATETIME below. The
          declared type is what the introspection reads, and with INTEGER
          `askr schema` typed a boolean as TColInt64 on SQLite and as
          TColBool on the other two -- from the same migration. BOOLEAN
          has NUMERIC affinity and the values are 0 and 1, so what is
          stored does not change; only the name that says what it is. }
        sdSqlite:   Result := 'BOOLEAN';
      end;
    ctNumeric:  Result := Format('NUMERIC(%d,%d)', [Precision, Scale]);
    ctFloat:
      if Dialect = sdSqlite then
        Result := 'REAL'
      else
        Result := 'DOUBLE PRECISION';
    ctTimestamp:
      case Dialect of
        sdPostgres: Result := 'TIMESTAMPTZ';
        sdMySql:    Result := 'DATETIME';
        { SQLite has no date type and stores text anyway. But the
          **declared** type is what the introspection reads, and with TEXT
          it cannot tell a date from any other string — then `askr schema`
          typed created_at as string against SQLite and as TDateTime
          against Postgres, from the same migration.

          DATETIME gives NUMERIC affinity, and an ISO text cannot be
          converted losslessly to a number, so it stays as text. The
          storage is therefore unchanged; it is only the name that now
          says what the column is. }
        sdSqlite:   Result := 'DATETIME';
      end;
    ctDate:
      Result := 'DATE';
    ctJson:
      case Dialect of
        sdPostgres: Result := 'JSONB';
        sdMySql:    Result := 'JSON';
        { Two words on purpose. A plain JSON would name it, but would give
          the column NUMERIC affinity, and SQLite then turns a document
          that is only a large number into a REAL and loses digits. The
          word TEXT in the name keeps TEXT affinity -- the storage is
          what it was -- and JSON in front of it is what lets a reader of
          the schema tell a document from any other text. }
        sdSqlite:   Result := 'JSON TEXT';
      end;
    ctUuid:
      case Dialect of
        sdPostgres: Result := 'UUID';
        sdMySql:    Result := 'CHAR(36)';
        { UUID has NUMERIC affinity, which is harmless here: a UUID always
          has four hyphens in it, so it is never a well-formed number and
          SQLite leaves it as text. The name is what changes. }
        sdSqlite:   Result := 'UUID';
      end;
    ctBytes:
      case Dialect of
        sdPostgres: Result := 'BYTEA';
        sdMySql:    Result := 'BLOB';
        sdSqlite:   Result := 'BLOB';
      end;
  end;
end;

{ TNornColumn }

constructor TNornColumn.Create(const AName: string; AKind: TColumnType);
begin
  inherited Create;
  FName := AName;
  FKind := AKind;
  FPrecision := 12;
  FScale := 2;
  FAction := caAdd;
end;

function TNornColumn.Nullable: TNornColumn;
begin
  FNullable := True;
  Result := Self;
end;

function TNornColumn.Unique: TNornColumn;
begin
  FUnique := True;
  Result := Self;
end;

function TNornColumn.PrimaryKey: TNornColumn;
begin
  FPrimaryKey := True;
  Result := Self;
end;

function TNornColumn.Default(const Value: string): TNornColumn;
begin
  { Text is quoted. DefaultRaw exists for what is not to be. }
  FDefault := '''' + StringReplace(Value, '''', '''''', [rfReplaceAll]) + '''';
  FHasDefault := True;
  Result := Self;
end;

function TNornColumn.Default(Value: Int64): TNornColumn;
begin
  FDefault := IntToStr(Value);
  FHasDefault := True;
  Result := Self;
end;

function TNornColumn.Default(Value: Currency): TNornColumn;
begin
  FDefault := CurrencyToSql(Value);
  FHasDefault := True;
  Result := Self;
end;

function TNornColumn.Default(Value: Boolean): TNornColumn;
begin
  if Value then
    FDefault := 'true'
  else
    FDefault := 'false';
  FHasDefault := True;
  Result := Self;
end;

function TNornColumn.DefaultRaw(const Sql: string): TNornColumn;
begin
  FDefault := Sql;
  FHasDefault := True;
  Result := Self;
end;

function TNornColumn.References(const ATable: string; const AColumn: string;
  const AOnDelete: string): TNornColumn;
begin
  FRefTable := ATable;
  FRefColumn := AColumn;
  FOnDelete := AOnDelete;
  Result := Self;
end;

{ TIndexDef }

constructor TIndexDef.Create(const AColumns: array of string; AUnique: Boolean);
var
  I: Integer;
begin
  inherited Create;
  FColumns := TStringList.Create;
  for I := 0 to High(AColumns) do
    FColumns.Add(AColumns[I]);
  FUnique := AUnique;
end;

destructor TIndexDef.Destroy;
begin
  FColumns.Free;
  inherited Destroy;
end;

{ TTableBuilder }

constructor TTableBuilder.Create(const ATable: string; AOp: TTableOp);
begin
  inherited Create;
  FTable := ATable;
  FOp := AOp;
  FColumns := TList.Create;
  FIndexes := TList.Create;
  FDropped := TStringList.Create;
end;

destructor TTableBuilder.Destroy;
var
  I: Integer;
begin
  for I := 0 to FColumns.Count - 1 do
    TNornColumn(FColumns[I]).Free;
  FColumns.Free;
  for I := 0 to FIndexes.Count - 1 do
    TIndexDef(FIndexes[I]).Free;
  FIndexes.Free;
  FDropped.Free;
  inherited Destroy;
end;

function TTableBuilder.Add(const AName: string; AKind: TColumnType): TNornColumn;
begin
  Result := TNornColumn.Create(AName, AKind);
  FColumns.Add(Result);
end;

procedure TTableBuilder.Id(const AName: string);
begin
  Add(AName, ctBigSerial).PrimaryKey;
end;

function TTableBuilder.Text(const AName: string; ALength: Integer): TNornColumn;
begin
  Result := Add(AName, ctText);
  Result.FLength := ALength;
end;

function TTableBuilder.Int(const AName: string): TNornColumn;
begin
  Result := Add(AName, ctInt);
end;

function TTableBuilder.BigInt(const AName: string): TNornColumn;
begin
  Result := Add(AName, ctBigInt);
end;

function TTableBuilder.SmallInt(const AName: string): TNornColumn;
begin
  Result := Add(AName, ctSmallInt);
end;

function TTableBuilder.Bool(const AName: string): TNornColumn;
begin
  Result := Add(AName, ctBoolean);
end;

function TTableBuilder.Money(const AName: string): TNornColumn;
begin
  Result := Numeric(AName, 12, 2);
end;

function TTableBuilder.Numeric(const AName: string; APrecision, AScale: Integer): TNornColumn;
begin
  Result := Add(AName, ctNumeric);
  Result.FPrecision := APrecision;
  Result.FScale := AScale;
end;

function TTableBuilder.Float(const AName: string): TNornColumn;
begin
  Result := Add(AName, ctFloat);
end;

function TTableBuilder.Timestamp(const AName: string): TNornColumn;
begin
  Result := Add(AName, ctTimestamp);
end;

function TTableBuilder.Date(const AName: string): TNornColumn;
begin
  Result := Add(AName, ctDate);
end;

function TTableBuilder.Json(const AName: string): TNornColumn;
begin
  Result := Add(AName, ctJson);
end;

function TTableBuilder.Uuid(const AName: string): TNornColumn;
begin
  Result := Add(AName, ctUuid);
end;

function TTableBuilder.Bytes(const AName: string): TNornColumn;
begin
  Result := Add(AName, ctBytes);
end;

function TTableBuilder.ForeignKey(const AName, ATable: string;
  const AColumn: string): TNornColumn;
begin
  Result := Add(AName, ctBigInt).References(ATable, AColumn);
end;

procedure TTableBuilder.Timestamps;
begin
  { CURRENT_TIMESTAMP, not now(). now() exists in Postgres and MySQL, but
    not in SQLite — and CURRENT_TIMESTAMP exists in all three. }
  Timestamp('created_at').DefaultRaw('CURRENT_TIMESTAMP');
  Timestamp('updated_at').DefaultRaw('CURRENT_TIMESTAMP');
end;

procedure TTableBuilder.SoftDeletes(const AName: string);
begin
  { Nullable, and with no default: NULL means "not deleted", and that is
    precisely the difference the queries filter on. }
  Timestamp(AName).Nullable;
  { Indexed because every single query against the table now has a clause
    about this column. }
  Index([AName]);
end;

procedure TTableBuilder.DropColumn(const AName: string);
var
  C: TNornColumn;
begin
  C := Add(AName, ctText);
  C.Action := caDrop;
end;

procedure TTableBuilder.Index(const AColumns: array of string);
begin
  FIndexes.Add(TIndexDef.Create(AColumns, False));
end;

procedure TTableBuilder.UniqueIndex(const AColumns: array of string);
begin
  FIndexes.Add(TIndexDef.Create(AColumns, True));
end;

{ TSchemaBuilder }

constructor TSchemaBuilder.Create(ADialect: TSqlDialect);
begin
  inherited Create;
  FDialect := ADialect;
  FOps := TList.Create;
  FRaw := TStringList.Create;
end;

destructor TSchemaBuilder.Destroy;
var
  I: Integer;
begin
  for I := 0 to FOps.Count - 1 do
    TTableBuilder(FOps[I]).Free;
  FOps.Free;
  FRaw.Free;
  inherited Destroy;
end;

function TSchemaBuilder.AddTable(const ATable: string; AOp: TTableOp): TTableBuilder;
begin
  Result := TTableBuilder.Create(ATable, AOp);
  FOps.Add(Result);
end;

function TSchemaBuilder.Create(const ATable: string): TTableBuilder;
begin
  Result := AddTable(ATable, toCreate);
end;

function TSchemaBuilder.Alter(const ATable: string): TTableBuilder;
begin
  Result := AddTable(ATable, toAlter);
end;

procedure TSchemaBuilder.Drop(const ATable: string; AIfExists: Boolean);
var
  T: TTableBuilder;
begin
  T := AddTable(ATable, toDrop);
  T.IfExists := AIfExists;
end;

procedure TSchemaBuilder.Rename(const AFrom, ATo: string);
var
  T: TTableBuilder;
begin
  T := AddTable(AFrom, toRename);
  T.NewName := ATo;
end;

procedure TSchemaBuilder.Execute(const Sql: string);
begin
  { Raw SQL is put in as an operation of its own in the order. }
  FRaw.AddObject(Sql, TObject(PtrInt(FOps.Count)));
end;

function ColumnSql(C: TNornColumn; Dialect: TSqlDialect; InCreate: Boolean): string;
begin
  Result := QuoteIdent(C.Name, Dialect) + ' ' +
    SqlTypeFor(C.Kind, Dialect, C.FLength, C.FPrecision, C.FScale);

  if C.FPrimaryKey then
    Result := Result + ' PRIMARY KEY'
  else if not C.FNullable then
    Result := Result + ' NOT NULL';

  if C.FHasDefault then
    Result := Result + ' DEFAULT ' + C.FDefault;

  if C.FUnique and not C.FPrimaryKey then
    Result := Result + ' UNIQUE';

  { **InnoDB silently ignores REFERENCES written on the column.** The
    statement parses without error, the table is created, and the foreign
    key does not exist — which is worse than an error message, because the
    schema looks right until something deletes a row that is pointed at.
    MySQL therefore gets a FOREIGN KEY clause at table level, added by the
    caller. }
  if (C.FRefTable <> '') and (Dialect <> sdMySql) then
    Result := Result + ' REFERENCES ' + QuoteIdent(C.FRefTable, Dialect) +
      '(' + QuoteIdent(C.FRefColumn, Dialect) + ') ON DELETE ' + C.FOnDelete;
end;

{ A foreign key at table level. Only MySQL needs it; the other two take
  the column form. }
function ForeignKeySql(C: TNornColumn; Dialect: TSqlDialect): string;
begin
  Result := 'FOREIGN KEY (' + QuoteIdent(C.Name, Dialect) + ') REFERENCES ' +
    QuoteIdent(C.FRefTable, Dialect) + '(' +
    QuoteIdent(C.FRefColumn, Dialect) + ') ON DELETE ' + C.FOnDelete;
end;

function IndexName(const Table: string; Idx: TIndexDef): string;
var
  I: Integer;
begin
  if Idx.Name <> '' then
    Exit(Idx.Name);
  Result := Table;
  for I := 0 to Idx.Columns.Count - 1 do
    Result := Result + '_' + Idx.Columns[I];
  if Idx.IsUnique then
    Result := Result + '_uniq'
  else
    Result := Result + '_idx';
end;

function TSchemaBuilder.ToSql: TStringArray;
var
  Out_: TStringList;
  I, J, K: Integer;
  T: TTableBuilder;
  C: TNornColumn;
  Idx: TIndexDef;
  S, Cols: string;
begin
  Result := nil;
  Out_ := TStringList.Create;
  try
    for I := 0 to FOps.Count - 1 do
    begin
      { Raw SQL that was put in before this operation. }
      for K := 0 to FRaw.Count - 1 do
        if PtrInt(FRaw.Objects[K]) = I then
          Out_.Add(FRaw[K]);

      T := TTableBuilder(FOps[I]);
      case T.Op of
        toCreate:
          begin
            S := 'CREATE TABLE ';
            if T.IfNotExists then
              S := S + 'IF NOT EXISTS ';
            S := S + QuoteIdent(T.Table, FDialect) + ' (';
            for J := 0 to T.Columns.Count - 1 do
            begin
              C := TNornColumn(T.Columns[J]);
              if J > 0 then
                S := S + ', ';
              S := S + ColumnSql(C, FDialect, True);
            end;
            if FDialect = sdMySql then
              for J := 0 to T.Columns.Count - 1 do
              begin
                C := TNornColumn(T.Columns[J]);
                if C.FRefTable <> '' then
                  S := S + ', ' + ForeignKeySql(C, FDialect);
              end;
            S := S + ')';
            Out_.Add(S);
          end;
        toAlter:
          for J := 0 to T.Columns.Count - 1 do
          begin
            C := TNornColumn(T.Columns[J]);
            if C.Action = caDrop then
              Out_.Add('ALTER TABLE ' + QuoteIdent(T.Table, FDialect) +
                ' DROP COLUMN ' + QuoteIdent(C.Name, FDialect))
            else
            begin
              Out_.Add('ALTER TABLE ' + QuoteIdent(T.Table, FDialect) +
                ' ADD COLUMN ' + ColumnSql(C, FDialect, False));
              { The same reason as above: the column form disappears in MySQL, so
                the foreign key has to be added as a statement of its
                own. }
              if (FDialect = sdMySql) and (C.FRefTable <> '') then
                Out_.Add('ALTER TABLE ' + QuoteIdent(T.Table, FDialect) +
                  ' ADD ' + ForeignKeySql(C, FDialect));
            end;
          end;
        toDrop:
          begin
            S := 'DROP TABLE ';
            if T.IfExists then
              S := S + 'IF EXISTS ';
            Out_.Add(S + QuoteIdent(T.Table, FDialect));
          end;
        toRename:
          Out_.Add('ALTER TABLE ' + QuoteIdent(T.Table, FDialect) +
            ' RENAME TO ' + QuoteIdent(T.NewName, FDialect));
      end;

      for J := 0 to T.Indexes.Count - 1 do
      begin
        Idx := TIndexDef(T.Indexes[J]);
        Cols := '';
        for K := 0 to Idx.Columns.Count - 1 do
        begin
          if K > 0 then
            Cols := Cols + ', ';
          Cols := Cols + QuoteIdent(Idx.Columns[K], FDialect);
        end;
        if Idx.IsUnique then
          S := 'CREATE UNIQUE INDEX '
        else
          S := 'CREATE INDEX ';
        Out_.Add(S + QuoteIdent(IndexName(T.Table, Idx), FDialect) +
          ' ON ' + QuoteIdent(T.Table, FDialect) + ' (' + Cols + ')');
      end;
    end;

    { Raw SQL put in after the last table operation. }
    for K := 0 to FRaw.Count - 1 do
      if PtrInt(FRaw.Objects[K]) >= FOps.Count then
        Out_.Add(FRaw[K]);

    SetLength(Result, Out_.Count);
    for I := 0 to Out_.Count - 1 do
      Result[I] := Out_[I];
  finally
    Out_.Free;
  end;
end;

end.
