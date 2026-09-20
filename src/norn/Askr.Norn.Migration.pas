{ Askr.Norn.Migration — migrasjoner og kjøring av dem.

  En migrasjon er en klasse som registrerer seg selv i sin initialization.
  Versjonen er et tidsstempel som tekst, slik at sortering er rekkefølge.

      type
        TCreateCustomers = class(TMigration)
        public
          class function Version: string; override;
          procedure Up(S: TSchemaBuilder); override;
          procedure Down(S: TSchemaBuilder); override;
        end;

  Hver migrasjon kjøres i sin egen transaksjon der dialekten tillater det.
  Postgres og SQLite gjør det; MySQL committer implisitt ved DDL, og der er
  en halvkjørt migrasjon noe brukeren må rydde selv. Det sies eksplisitt i
  stedet for å latest som om det er trygt. }
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
    { Tidsstempel som tekst: '20260919143000'. Sortering er rekkefølge. }
    class function Version: string; virtual; abstract;
    { Lesbart navn. Utledes fra klassenavnet om den ikke overstyres. }
    class function Title: string; virtual;
    procedure Up(S: TSchemaBuilder); virtual; abstract;
    { Uten Down er migrasjonen ikke reversibel, og Down vil nekte. }
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

  { Vanlig prosedyre, ikke «of object». Loggingen her er et verktøy som
    kjøres fra en kommandolinje, ikke en hendelse på et objekt. }
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

    { Alle registrerte og alle kjørte, slått sammen og sortert. En rad som er
      kjørt men ikke registrert betyr at en migrasjonsfil er borte. }
    function Status: TMigrationInfoArray;
    function PendingCount: Integer;

    { Kjører ventende migrasjoner. Steps = 0 betyr alle. }
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
  { MySQL committer implisitt ved DDL, så en transaksjon der gir falsk
    trygghet. }
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
      { CURRENT_TIMESTAMP, ikke now(). now() finnes i Postgres og MySQL,
        men ikke i SQLite — og migrasjonstabellens egen DDL hadde aldri
        vært kjørt mot SQLite før, fordi Norn-testene går mot de to andre.
        Samme regel som TTableBuilder.Timestamps følger. }
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
        Say('    ADVARSEL: ' + M.Version +
            ' feilet midt i, og dialekten støtter ikke DDL i transaksjon.');
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

    { Kjørte versjoner uten registrert klasse — filen er borte. }
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
      Result[N].Title := '(migrasjonen finnes ikke i koden)';
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
    Say('  ingenting å gjøre');
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
    Say('  ingenting å rulle tilbake');
end;

initialization

finalization
  GMigrations.Free;

end.
