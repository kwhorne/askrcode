{ Askr.Norn.Migration — migrations and running them.

  A migration is a class that registers itself in its own initialization.
  The version is a timestamp as text, so that sorting is order.

      type
        TCreateCustomers = class(TMigration)
        public
          class function Version: string; override;
          procedure Up(S: TSchemaBuilder); override;
          procedure Down(S: TSchemaBuilder); override;
        end;

  Each migration runs in a transaction of its own where the dialect allows
  it. Postgres and SQLite do; MySQL commits implicitly on DDL, and there a
  half-run migration is something the user has to clean up. That is said
  explicitly rather than pretending it is safe. }
unit Askr.Norn.Migration;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, Askr.Core.Arena, Askr.Core.Text,
  Askr.Urd.Driver, Askr.Norn.Schema;

const
  MigrationsTable = 'askr_migrations';

type
  TMigration = class
  public
    { A timestamp as text: '20260919143000'. Sorting is order. }
    class function Version: string; virtual; abstract;
    { A readable name. Derived from the class name unless it is
      overridden. }
    class function Title: string; virtual;
    procedure Up(S: TSchemaBuilder); virtual; abstract;
    { Without Down the migration is not reversible, and Down will
      refuse. }
    procedure Down(S: TSchemaBuilder); virtual;
    class function Reversible: Boolean; virtual;
  end;

  TMigrationClass = class of TMigration;

  TMigrationInfo = record
    Version: string;
    Title: string;
    Applied: Boolean;
    AppliedAt: string;
    Registered: Boolean;
  end;
  TMigrationInfoArray = array of TMigrationInfo;

  { An ordinary procedure, not "of object". The logging here is a tool run
    from a command line, not an event on an object. }
  TNornLog = procedure(const Line: string);

  TMigrator = class
  private
    FConn: TDbConnection;
    FArena: TArena;
    FLog: TNornLog;
    procedure Say(const Line: string);
    procedure EnsureTable;
    function AppliedVersions: TStringList;
    procedure MarkApplied(const AVersion, ATitle: string);
    procedure MarkRolledBack(const AVersion: string);
    procedure RunStatements(const Stmts: TStringArray);
    function UseTransaction: Boolean;
    procedure RunOne(M: TMigrationClass; Forward_: Boolean);
  public
    constructor Create(AConn: TDbConnection);
    destructor Destroy; override;

    { All registered and all run, merged and sorted. A row that has been
      run but is not registered means a migration file has gone
      missing. }
    function Status: TMigrationInfoArray;
    function PendingCount: Integer;

    { Runs pending migrations. Steps = 0 means all of them. }
    function Up(Steps: Integer = 0): Integer;
    { Ruller tilbake de siste. }
    function Down(Steps: Integer = 1): Integer;

    property OnLog: TNornLog read FLog write FLog;
  end;

procedure RegisterMigration(M: TMigrationClass);
function RegisteredMigrations: TList;

implementation

var
  GMigrations: TList = nil;

procedure RegisterMigration(M: TMigrationClass);
var
  I: Integer;
begin
  if GMigrations = nil then
    GMigrations := TList.Create;
  for I := 0 to GMigrations.Count - 1 do
    if TMigrationClass(GMigrations[I]) = M then
      Exit;
  GMigrations.Add(Pointer(M));
end;

function CompareVersions(Item1, Item2: Pointer): Integer;
begin
  Result := CompareStr(TMigrationClass(Item1).Version,
                       TMigrationClass(Item2).Version);
end;

function RegisteredMigrations: TList;
begin
  if GMigrations = nil then
    GMigrations := TList.Create;
  GMigrations.Sort(CompareVersions);
  Result := GMigrations;
end;

{ TMigration }

class function TMigration.Title: string;
var
  N: string;
  I: Integer;
begin
  { TCreateCustomers blir 'Create customers'. }
  N := ClassName;
  if (Length(N) > 1) and (N[1] = 'T') and (N[2] >= 'A') and (N[2] <= 'Z') then
    Delete(N, 1, 1);
  Result := '';
  for I := 1 to Length(N) do
  begin
    if (I > 1) and (N[I] >= 'A') and (N[I] <= 'Z') then
      Result := Result + ' ' + LowerCase(N[I])
    else
      Result := Result + N[I];
  end;
end;

class function TMigration.Reversible: Boolean;
begin
  Result := True;
end;

procedure TMigration.Down(S: TSchemaBuilder);
begin
  raise ENornError.CreateFmt(
    '%s has no Down and cannot be rolled back', [ClassName]);
end;

{ TMigrator }

constructor TMigrator.Create(AConn: TDbConnection);
begin
  inherited Create;
  FConn := AConn;
  FArena := TArena.Create(64 * 1024);
end;

destructor TMigrator.Destroy;
begin
  FArena.Free;
  inherited Destroy;
end;

procedure TMigrator.Say(const Line: string);
begin
  if Assigned(FLog) then
    FLog(Line)
  else
    WriteLn(Line);
end;

function TMigrator.UseTransaction: Boolean;
begin
  { MySQL commits implicitly on DDL, so a transaction there gives false
    confidence. }
  Result := FConn.Dialect <> sdMySql;
end;

procedure TMigrator.EnsureTable;
var
  S: TSchemaBuilder;
  Stmts: TStringArray;
  I: Integer;
begin
  S := TSchemaBuilder.Create(FConn.Dialect);
  try
    with S.Create(MigrationsTable) do
    begin
      IfNotExists := True;
      Text('version', 64).PrimaryKey;
      Text('title', 255);
      { CURRENT_TIMESTAMP, not now(). now() exists in Postgres and MySQL,
        but not in SQLite — and the migration table's own DDL had never
        been run against SQLite before, because the Norn tests go against
        the other two. The same rule TTableBuilder.Timestamps follows. }
      Timestamp('applied_at').DefaultRaw('CURRENT_TIMESTAMP');
    end;
    Stmts := S.ToSql;
    for I := 0 to High(Stmts) do
    begin
      FArena.Reset;
      FConn.Exec(FArena, Stmts[I]);
    end;
  finally
    S.Free;
  end;
end;

function TMigrator.AppliedVersions: TStringList;
var
  R: TDbResult;
  I: Integer;
begin
  Result := TStringList.Create;
  Result.Sorted := False;
  FArena.Reset;
  R := FConn.Exec(FArena, 'SELECT version, applied_at FROM ' +
    MigrationsTable + ' ORDER BY version');
  for I := 0 to R.RowCount - 1 do
    Result.AddObject(R.Value(I, 0).ToString,
      TObject(PtrInt(I)));
end;

procedure TMigrator.MarkApplied(const AVersion, ATitle: string);
var
  B: TStrBuilder;
begin
  FArena.Reset;
  B.Init(FArena, 128);
  B.Append('INSERT INTO ' + MigrationsTable + ' (version, title) VALUES (');
  FConn.AppendPlaceholder(B, 1);
  B.Append(', ');
  FConn.AppendPlaceholder(B, 2);
  B.AppendByte(Ord(')'));
  FConn.ExecParams(FArena, B.ToString,
    [DbParam(FArena, AVersion), DbParam(FArena, ATitle)]);
end;

procedure TMigrator.MarkRolledBack(const AVersion: string);
var
  B: TStrBuilder;
begin
  FArena.Reset;
  B.Init(FArena, 128);
  B.Append('DELETE FROM ' + MigrationsTable + ' WHERE version = ');
  FConn.AppendPlaceholder(B, 1);
  FConn.ExecParams(FArena, B.ToString, [DbParam(FArena, AVersion)]);
end;

procedure TMigrator.RunStatements(const Stmts: TStringArray);
var
  I: Integer;
begin
  for I := 0 to High(Stmts) do
  begin
    Say('    ' + Stmts[I]);
    FArena.Reset;
    FConn.Exec(FArena, Stmts[I]);
  end;
end;

procedure TMigrator.RunOne(M: TMigrationClass; Forward_: Boolean);
var
  Inst: TMigration;
  S: TSchemaBuilder;
  Stmts: TStringArray;
begin
  Inst := M.Create;
  S := TSchemaBuilder.Create(FConn.Dialect);
  try
    if Forward_ then
      Inst.Up(S)
    else
      Inst.Down(S);
    Stmts := S.ToSql;
  except
    S.Free;
    Inst.Free;
    raise;
  end;

  try
    if UseTransaction then
      FConn.StartTransaction;
    try
      RunStatements(Stmts);
      if Forward_ then
        MarkApplied(M.Version, M.Title)
      else
        MarkRolledBack(M.Version);
      if UseTransaction then
        FConn.Commit;
    except
      if UseTransaction then
        FConn.Rollback
      else
        Say('    WARNING: ' + M.Version +
            ' failed halfway, and this dialect cannot roll back DDL.');
      raise;
    end;
  finally
    S.Free;
    Inst.Free;
  end;
end;

function TMigrator.Status: TMigrationInfoArray;
var
  Applied: TStringList;
  Regs: TList;
  I, J, N: Integer;
  M: TMigrationClass;
  Found: Boolean;
begin
  EnsureTable;
  Applied := AppliedVersions;
  try
    Regs := RegisteredMigrations;
    Result := nil;

    for I := 0 to Regs.Count - 1 do
    begin
      M := TMigrationClass(Regs[I]);
      N := Length(Result);
      SetLength(Result, N + 1);
      Result[N].Version := M.Version;
      Result[N].Title := M.Title;
      Result[N].Registered := True;
      Result[N].Applied := Applied.IndexOf(M.Version) >= 0;
    end;

    { Versions that have been run with no registered class — the file is
      gone. }
    for I := 0 to Applied.Count - 1 do
    begin
      Found := False;
      for J := 0 to High(Result) do
        if Result[J].Version = Applied[I] then
        begin
          Found := True;
          Break;
        end;
      if Found then
        Continue;
      N := Length(Result);
      SetLength(Result, N + 1);
      Result[N].Version := Applied[I];
      Result[N].Title := '(this migration is not in the code)';
      Result[N].Applied := True;
      Result[N].Registered := False;
    end;
  finally
    Applied.Free;
  end;
end;

function TMigrator.PendingCount: Integer;
var
  St: TMigrationInfoArray;
  I: Integer;
begin
  Result := 0;
  St := Status;
  for I := 0 to High(St) do
    if St[I].Registered and not St[I].Applied then
      Inc(Result);
end;

function TMigrator.Up(Steps: Integer): Integer;
var
  Applied: TStringList;
  Regs: TList;
  I: Integer;
  M: TMigrationClass;
begin
  Result := 0;
  EnsureTable;
  Applied := AppliedVersions;
  try
    Regs := RegisteredMigrations;
    for I := 0 to Regs.Count - 1 do
    begin
      M := TMigrationClass(Regs[I]);
      if Applied.IndexOf(M.Version) >= 0 then
        Continue;
      Say('  opp   ' + M.Version + '  ' + M.Title);
      RunOne(M, True);
      Inc(Result);
      if (Steps > 0) and (Result >= Steps) then
        Break;
    end;
  finally
    Applied.Free;
  end;
  if Result = 0 then
    Say('  nothing to do');
end;

function TMigrator.Down(Steps: Integer): Integer;
var
  Applied: TStringList;
  Regs: TList;
  I, J: Integer;
  M: TMigrationClass;
begin
  Result := 0;
  EnsureTable;
  if Steps < 1 then
    Steps := 1;
  Applied := AppliedVersions;
  try
    Regs := RegisteredMigrations;
    for I := Applied.Count - 1 downto 0 do
    begin
      M := nil;
      for J := 0 to Regs.Count - 1 do
        if TMigrationClass(Regs[J]).Version = Applied[I] then
        begin
          M := TMigrationClass(Regs[J]);
          Break;
        end;
      if M = nil then
        raise ENornError.CreateFmt(
          'Migration %s has been applied, but its class no longer exists. ' +
          'It cannot be rolled back.', [Applied[I]]);
      Say('  ned   ' + M.Version + '  ' + M.Title);
      RunOne(M, False);
      Inc(Result);
      if Result >= Steps then
        Break;
    end;
  finally
    Applied.Free;
  end;
  if Result = 0 then
    Say('  nothing to roll back');
end;

initialization

finalization
  GMigrations.Free;

end.
