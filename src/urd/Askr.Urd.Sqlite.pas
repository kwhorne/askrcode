{ Askr.Urd.Sqlite — SQLite bak TDbConnection.

  Dette er desktop-variantens datalag. PRD-en skriver
  App.UseDatabase('sqlite:local.db'), og forskjellen mellom web og desktop
  skal i praksis være én unit og valg av databaseadapter.

  SQLite oppfører seg annerledes enn Postgres på tre punkter som må håndteres
  her og ikke lekke oppover:

    * Plassholdere er ?, ikke $1.
    * Typing er dynamisk. En kolonne erklært NUMERIC kan inneholde hva som
      helst. Driveren leverer alt som tekst, slik Postgres-driveren gjør,
      og lar Urd konvertere — da er oppførselen den samme i begge.
    * Én skriver om gangen. WAL og busy_timeout settes ved oppkobling, ellers
      får en pool med flere workere SQLITE_BUSY i stedet for å vente.

  Biblioteket lastes med dlopen som libpq. På macOS ligger libsqlite3 i
  dyld-cachen og finnes ikke som fil på disk — dlopen finner den likevel. }
unit Askr.Urd.Sqlite;

{$mode Delphi}{$H+}
{$POINTERMATH ON}

interface

uses
  SysUtils, Classes, DynLibs, Askr.Core.Arena, Askr.Core.Text,
  Askr.Urd.Driver;

type
  TSqliteConnection = class(TDbConnection)
  private
    FDb: Pointer;
    FPath: string;
    FCache: TStringList;     { sql -> sqlite3_stmt* i Objects }
    FCacheLimit: Integer;
    FPrepared: Int64;
    FCacheHits: Int64;
    procedure Pragma(const Sql: string);
    procedure RaiseLast(const Sql: string);
    { Cachet sier om statementet ligger i cachen. Gjør det ikke det, eier
      kalleren det og må frigjøre det. }
    function Prepared(const Sql: string; UseCache: Boolean;
      out Cachet: Boolean): Pointer;
    function Run(A: TArena; const Sql: string;
      const Params: array of TDbParam; UseCache: Boolean): TDbResult;
  public
    { Dsn er 'sqlite:sti/til/fil.db' eller 'sqlite::memory:'. }
    constructor Create(const ADsn: string);
    destructor Destroy; override;

    function Dialect: TSqlDialect; override;
    function IsAlive: Boolean; override;
    function Exec(A: TArena; const Sql: string): TDbResult; override;
    function ExecParams(A: TArena; const Sql: string;
      const Params: array of TDbParam): TDbResult; override;
    function InsertGetId(A: TArena; const Sql: string;
      const Params: array of TDbParam; const IdColumn: string): Int64; override;
    procedure StartTransaction; override;
    procedure Commit; override;
    procedure Rollback; override;

    { Frigjør alle cachede statements og tømmer cachen. }
    procedure FlushStatementCache;
    { SQLites eget tall på hvor mange statements som står åpne mot denne
      forbindelsen. Driverens egne tellere sier hva den *tror*; denne sier
      hva som faktisk finnes, og det er den forskjellen som avdekker en
      lekkasje. }
    function OpenStatements: Integer;

    property Path: string read FPath;
    { Where_ mange statements som er forberedt, og hvor mange kall som slapp
      unna med et cachet. Samme flate som Postgres- og MySQL-driveren. }
    property PreparedCount: Int64 read FPrepared;
    property CacheHits: Int64 read FCacheHits;
    { 0 slår cachen av, og da forberedes og frigjøres hvert kall som før.
      Standard er 64. }
    property CacheLimit: Integer read FCacheLimit write FCacheLimit;
  end;

function SqliteAvailable: Boolean;
function SqliteLibraryName: string;
function SqliteVersion: string;

implementation

uses
  SyncObjs;

const
  SqliteOk     = 0;
  SqliteRow    = 100;
  SqliteDone   = 101;
  SqliteNull   = 5;

  OpenReadWrite = $00000002;
  OpenCreate    = $00000004;
  { Full mutex: flere tråder kan dele biblioteket, men ikke én forbindelse. }
  OpenFullMutex = $00010000;

type
  TSqliteDestructor = procedure(P: Pointer); cdecl;

  Tsqlite3_open_v2 = function(Filename: PAnsiChar; out Db: Pointer;
    Flags: Integer; Vfs: PAnsiChar): Integer; cdecl;
  Tsqlite3_close_v2 = function(Db: Pointer): Integer; cdecl;
  Tsqlite3_errmsg = function(Db: Pointer): PAnsiChar; cdecl;
  Tsqlite3_errcode = function(Db: Pointer): Integer; cdecl;
  Tsqlite3_prepare_v2 = function(Db: Pointer; Sql: PAnsiChar; NBytes: Integer;
    out Stmt: Pointer; out Tail: PAnsiChar): Integer; cdecl;
  Tsqlite3_step = function(Stmt: Pointer): Integer; cdecl;
  Tsqlite3_finalize = function(Stmt: Pointer): Integer; cdecl;
  Tsqlite3_reset = function(Stmt: Pointer): Integer; cdecl;
  Tsqlite3_next_stmt = function(Db, Stmt: Pointer): Pointer; cdecl;
  Tsqlite3_clear_bindings = function(Stmt: Pointer): Integer; cdecl;
  Tsqlite3_bind_text = function(Stmt: Pointer; Index: Integer; Value: PAnsiChar;
    NBytes: Integer; Dtor: TSqliteDestructor): Integer; cdecl;
  Tsqlite3_bind_null = function(Stmt: Pointer; Index: Integer): Integer; cdecl;
  Tsqlite3_column_count = function(Stmt: Pointer): Integer; cdecl;
  Tsqlite3_column_name = function(Stmt: Pointer; N: Integer): PAnsiChar; cdecl;
  Tsqlite3_column_type = function(Stmt: Pointer; N: Integer): Integer; cdecl;
  Tsqlite3_column_text = function(Stmt: Pointer; N: Integer): PByte; cdecl;
  Tsqlite3_column_bytes = function(Stmt: Pointer; N: Integer): Integer; cdecl;
  Tsqlite3_changes = function(Db: Pointer): Integer; cdecl;
  Tsqlite3_last_insert_rowid = function(Db: Pointer): Int64; cdecl;
  Tsqlite3_libversion = function: PAnsiChar; cdecl;

var
  sqlite3_open_v2: Tsqlite3_open_v2;
  sqlite3_close_v2: Tsqlite3_close_v2;
  sqlite3_errmsg: Tsqlite3_errmsg;
  sqlite3_errcode: Tsqlite3_errcode;
  sqlite3_prepare_v2: Tsqlite3_prepare_v2;
  sqlite3_step: Tsqlite3_step;
  sqlite3_finalize: Tsqlite3_finalize;
  sqlite3_reset: Tsqlite3_reset;
  sqlite3_next_stmt: Tsqlite3_next_stmt;
  sqlite3_clear_bindings: Tsqlite3_clear_bindings;
  sqlite3_bind_text: Tsqlite3_bind_text;
  sqlite3_bind_null: Tsqlite3_bind_null;
  sqlite3_column_count: Tsqlite3_column_count;
  sqlite3_column_name: Tsqlite3_column_name;
  sqlite3_column_type: Tsqlite3_column_type;
  sqlite3_column_text: Tsqlite3_column_text;
  sqlite3_column_bytes: Tsqlite3_column_bytes;
  sqlite3_changes: Tsqlite3_changes;
  sqlite3_last_insert_rowid: Tsqlite3_last_insert_rowid;
  sqlite3_libversion: Tsqlite3_libversion;

  GLib: TLibHandle = NilHandle;
  GLibName: string = '';
  GTried: Boolean = False;
  GError: string = '';
  GLock: TCriticalSection;

function Candidates: TStringArray;
begin
{$IFDEF DARWIN}
  { libsqlite3.dylib finnes ikke som fil på nyere macOS — dyld løser den fra
    delt cache. dlopen på navnet virker likevel. }
  Result := ['libsqlite3.dylib', '/usr/lib/libsqlite3.dylib'];
{$ELSE}
{$IFDEF WINDOWS}
  Result := ['sqlite3.dll'];
{$ELSE}
  Result := ['libsqlite3.so.0', 'libsqlite3.so'];
{$ENDIF}
{$ENDIF}
end;

function Resolve(const AName: string): Pointer;
begin
  Result := GetProcedureAddress(GLib, AName);
  if Result = nil then
    raise EDbUnavailable.CreateFmt(
      'libsqlite3 was loaded from %s but is missing %s', [GLibName, AName]);
end;

procedure EnsureLoaded;
var
  Names: TStringArray;
  I: Integer;
  Tried: string;
begin
  if GLib <> NilHandle then
    Exit;
  GLock.Acquire;
  try
    if GLib <> NilHandle then
      Exit;
    if GTried then
      raise EDbUnavailable.Create(GError);
    GTried := True;

    Names := Candidates;
    Tried := '';
    for I := 0 to High(Names) do
    begin
      GLib := LoadLibrary(Names[I]);
      if GLib <> NilHandle then
      begin
        GLibName := Names[I];
        Break;
      end;
      if Tried <> '' then
        Tried := Tried + ', ';
      Tried := Tried + Names[I];
    end;
    if GLib = NilHandle then
    begin
      GError := 'Could not find libsqlite3. Tried: ' + Tried + '.';
      raise EDbUnavailable.Create(GError);
    end;

    try
      sqlite3_open_v2 := Tsqlite3_open_v2(Resolve('sqlite3_open_v2'));
      sqlite3_close_v2 := Tsqlite3_close_v2(Resolve('sqlite3_close_v2'));
      sqlite3_errmsg := Tsqlite3_errmsg(Resolve('sqlite3_errmsg'));
      sqlite3_errcode := Tsqlite3_errcode(Resolve('sqlite3_errcode'));
      sqlite3_prepare_v2 := Tsqlite3_prepare_v2(Resolve('sqlite3_prepare_v2'));
      sqlite3_step := Tsqlite3_step(Resolve('sqlite3_step'));
      sqlite3_finalize := Tsqlite3_finalize(Resolve('sqlite3_finalize'));
      sqlite3_reset := Tsqlite3_reset(Resolve('sqlite3_reset'));
      sqlite3_next_stmt := Tsqlite3_next_stmt(Resolve('sqlite3_next_stmt'));
      sqlite3_clear_bindings :=
        Tsqlite3_clear_bindings(Resolve('sqlite3_clear_bindings'));
      sqlite3_bind_text := Tsqlite3_bind_text(Resolve('sqlite3_bind_text'));
      sqlite3_bind_null := Tsqlite3_bind_null(Resolve('sqlite3_bind_null'));
      sqlite3_column_count := Tsqlite3_column_count(Resolve('sqlite3_column_count'));
      sqlite3_column_name := Tsqlite3_column_name(Resolve('sqlite3_column_name'));
      sqlite3_column_type := Tsqlite3_column_type(Resolve('sqlite3_column_type'));
      sqlite3_column_text := Tsqlite3_column_text(Resolve('sqlite3_column_text'));
      sqlite3_column_bytes := Tsqlite3_column_bytes(Resolve('sqlite3_column_bytes'));
      sqlite3_changes := Tsqlite3_changes(Resolve('sqlite3_changes'));
      sqlite3_last_insert_rowid :=
        Tsqlite3_last_insert_rowid(Resolve('sqlite3_last_insert_rowid'));
      sqlite3_libversion := Tsqlite3_libversion(Resolve('sqlite3_libversion'));
    except
      on E: Exception do
      begin
        UnloadLibrary(GLib);
        GLib := NilHandle;
        GError := E.Message;
        raise;
      end;
    end;
  finally
    GLock.Release;
  end;
end;

function SqliteAvailable: Boolean;
begin
  try
    EnsureLoaded;
    Result := True;
  except
    Result := False;
  end;
end;

function SqliteLibraryName: string;
begin
  Result := GLibName;
end;

function SqliteVersion: string;
begin
  EnsureLoaded;
  Result := string(sqlite3_libversion());
end;

{ TSqliteConnection }

constructor TSqliteConnection.Create(const ADsn: string);
var
  P: Integer;
  Rc: Integer;
begin
  FCacheLimit := 64;
  FCache := TStringList.Create;
  FCache.Sorted := True;
  FCache.Duplicates := dupIgnore;
  inherited Create;
  EnsureLoaded;

  FPath := ADsn;
  P := Pos(':', FPath);
  if P > 0 then
    Delete(FPath, 1, P);
  { 'sqlite://fil.db' skal også virke. }
  while (Length(FPath) > 0) and (FPath[1] = '/') and
        (Copy(FPath, 1, 2) = '//') do
    Delete(FPath, 1, 2);
  if FPath = '' then
    FPath := ':memory:';

  Rc := sqlite3_open_v2(PAnsiChar(AnsiString(FPath)), FDb,
    OpenReadWrite or OpenCreate or OpenFullMutex, nil);
  if Rc <> SqliteOk then
  begin
    if FDb <> nil then
    begin
      sqlite3_close_v2(FDb);
      FDb := nil;
    end;
    raise EDbError.CreateFmt('Could not open %s (sqlite error %d)',
      [FPath, Rc]);
  end;

  { WAL lar lesere og én skriver jobbe samtidig. Without busy_timeout gir en
    pool med flere workere SQLITE_BUSY i stedet for å vente. En fil i minnet
    har ingen WAL. }
  if FPath <> ':memory:' then
    Pragma('PRAGMA journal_mode = WAL');
  Pragma('PRAGMA busy_timeout = 5000');
  { SQLite håndhever ikke fremmednøkler med mindre man ber om det. }
  Pragma('PRAGMA foreign_keys = ON');
end;

destructor TSqliteConnection.Destroy;
begin
  { Statementene må frigjøres før basen lukkes. sqlite3_close_v2 tåler
    riktignok at de henger igjen — den utsetter lukkingen til siste
    statement er borte — men da ville fila stått åpen på ubestemt tid, og
    «lukket» ville betydd noe annet enn det ser ut som. }
  if FCache <> nil then
  begin
    FlushStatementCache;
    FreeAndNil(FCache);
  end;
  if FDb <> nil then
  begin
    sqlite3_close_v2(FDb);
    FDb := nil;
  end;
  inherited Destroy;
end;

procedure TSqliteConnection.FlushStatementCache;
var
  I: Integer;
begin
  if FCache = nil then
    Exit;
  for I := 0 to FCache.Count - 1 do
    if FCache.Objects[I] <> nil then
      sqlite3_finalize(Pointer(FCache.Objects[I]));
  FCache.Clear;
end;

function TSqliteConnection.OpenStatements: Integer;
var
  Stmt: Pointer;
begin
  Result := 0;
  if FDb = nil then
    Exit;
  Stmt := sqlite3_next_stmt(FDb, nil);
  while Stmt <> nil do
  begin
    Inc(Result);
    Stmt := sqlite3_next_stmt(FDb, Stmt);
  end;
end;

function TSqliteConnection.Prepared(const Sql: string; UseCache: Boolean;
  out Cachet: Boolean): Pointer;
var
  Idx, Rc: Integer;
  Stmt: Pointer;
  Tail: PAnsiChar;
begin
  Cachet := False;

  if UseCache and (FCacheLimit > 0) then
  begin
    Idx := FCache.IndexOf(Sql);
    if Idx >= 0 then
    begin
      Inc(FCacheHits);
      Cachet := True;
      Result := Pointer(FCache.Objects[Idx]);
      { Et gjenbrukt statement må nullstilles før det kjøres igjen, og
        bindingene ryddes: SQLite eier kopier av dem etter
        SQLITE_TRANSIENT, og uten dette blir de liggende til neste
        binding overskriver dem. }
      sqlite3_reset(Result);
      sqlite3_clear_bindings(Result);
      Exit;
    end;
  end;

  Stmt := nil;
  Rc := sqlite3_prepare_v2(FDb, PAnsiChar(AnsiString(Sql)), -1, Stmt, Tail);
  if (Rc <> SqliteOk) or (Stmt = nil) then
    RaiseLast(Sql);
  Inc(FPrepared);

  if UseCache and (FCacheLimit > 0) then
  begin
    { Grensen er en grense, ikke en gjenbruksrekkefølge. Faller cachen over,
      tømmes den helt — enklere enn en LRU, og treffer sjelden, fordi
      spørringene i en app er et endelig sett. }
    if FCache.Count >= FCacheLimit then
      FlushStatementCache;
    FCache.AddObject(Sql, TObject(Stmt));
    Cachet := True;
  end;
  Result := Stmt;
end;

function TSqliteConnection.Dialect: TSqlDialect;
begin
  Result := sdSqlite;
end;

function TSqliteConnection.IsAlive: Boolean;
begin
  Result := FDb <> nil;
end;

procedure TSqliteConnection.RaiseLast(const Sql: string);
var
  Msg: string;
  Code: Integer;
  State: string;
begin
  Msg := string(sqlite3_errmsg(FDb));
  Code := sqlite3_errcode(FDb);
  { SQLite har ikke SQLSTATE. De to kodene Urd faktisk bryr seg om oversettes,
    slik at IsUniqueViolation virker likt på tvers av dialekter. }
  case Code of
    19: State := '23505';   { SQLITE_CONSTRAINT }
    787: State := '23503';  { SQLITE_CONSTRAINT_FOREIGNKEY }
  else
    State := '';
  end;
  if (Code = 19) and (Pos('FOREIGN KEY', Msg) > 0) then
    State := '23503';
  raise EDbError.Create(Msg + ' — i: ' + Sql, State);
end;

procedure TSqliteConnection.Pragma(const Sql: string);
var
  A: TArena;
begin
  A := TArena.Create(4096);
  try
    Run(A, Sql, [], False);
  finally
    A.Free;
  end;
end;

type
  PRowChunk = ^TRowChunk;
  TRowChunk = record
    Cells: PDbCell;
    Next: PRowChunk;
  end;

function TSqliteConnection.Run(A: TArena; const Sql: string;
  const Params: array of TDbParam; UseCache: Boolean): TDbResult;
var
  Stmt: Pointer;
  Rc, I, Cols, RowCount: Integer;
  Buf: PByte;
  Head, Last, Chunk: PRowChunk;
  Cells: PDbCell;
  Len: Integer;
  Prev: TArena;
  Txt: PByte;
  Cachet: Boolean;
begin
  { Gjenbruk er trygt her fordi løkka under alltid tømmer statementet til
    SQLITE_DONE før den returnerer. Et cachet statement er derfor aldri
    midt i en iterasjon når neste kall henter det — hadde radene blitt
    levert dovent, ville den samme spørringen inne i sin egen løkke ha
    nullstilt seg selv. }
  Stmt := Prepared(Sql, UseCache, Cachet);

  try
    for I := 0 to High(Params) do
    begin
      if Params[I].IsNull then
      begin
        sqlite3_bind_null(Stmt, I + 1);
        Continue;
      end;
      { SQLITE_TRANSIENT (-1) ber SQLite ta sin egen kopi. Without det måtte
        bufferet overleve helt til finalize, og arenaen spoles ofte før. }
      Buf := PByte(A.Alloc(PtrUInt(Params[I].Value.Len) + 1));
      if Params[I].Value.Len > 0 then
        Move(Params[I].Value.Data^, Buf^, Params[I].Value.Len);
      Buf[Params[I].Value.Len] := 0;
      sqlite3_bind_text(Stmt, I + 1, PAnsiChar(Buf), Params[I].Value.Len,
        TSqliteDestructor(-1));
    end;

    Cols := sqlite3_column_count(Stmt);
    Head := nil;
    Last := nil;
    RowCount := 0;

    { SQLite sier ikke hvor mange rader som kommer. Radene samles i en kjede
      i arenaen, og TDbResult allokeres når tallet er kjent. }
    repeat
      Rc := sqlite3_step(Stmt);
      if Rc = SqliteRow then
      begin
        Cells := PDbCell(A.AllocZero(PtrUInt(Cols) * SizeOf(TDbCell)));
        for I := 0 to Cols - 1 do
          if sqlite3_column_type(Stmt, I) = SqliteNull then
          begin
            Cells[I].IsNull := True;
            Cells[I].Value := StrEmpty;
          end
          else
          begin
            Txt := sqlite3_column_text(Stmt, I);
            Len := sqlite3_column_bytes(Stmt, I);
            Cells[I].IsNull := False;
            Cells[I].Value := StrDup(A, StrRef(Txt, Len));
          end;
        Chunk := PRowChunk(A.Alloc(SizeOf(TRowChunk)));
        Chunk^.Cells := Cells;
        Chunk^.Next := nil;
        if Head = nil then
          Head := Chunk
        else
          Last^.Next := Chunk;
        Last := Chunk;
        Inc(RowCount);
      end
      else if Rc <> SqliteDone then
        RaiseLast(Sql);
    until Rc = SqliteDone;

    Prev := UseArena(A);
    try
      Result := TDbResult.Create;
      Result.Allocate(RowCount, Cols);
      for I := 0 to Cols - 1 do
        Result.SetFieldName(I, StrDup(A, string(sqlite3_column_name(Stmt, I))));
      Chunk := Head;
      RowCount := 0;
      while Chunk <> nil do
      begin
        for I := 0 to Cols - 1 do
          Result.SetCell(RowCount, I, Chunk^.Cells[I].Value,
            Chunk^.Cells[I].IsNull);
        Inc(RowCount);
        Chunk := Chunk^.Next;
      end;
      if Cols = 0 then
        Result.SetAffected(sqlite3_changes(FDb));
    finally
      UseArena(Prev);
    end;
  finally
    if Cachet then
      { Nullstilles nå, ikke ved neste bruk: et statement som står igjen
        ferdig-stepped holder på lesesperren sin, og da ville en cachet
        SELECT blokkert en skriver til noen kjørte den samme spørringen om
        igjen. }
      sqlite3_reset(Stmt)
    else
      sqlite3_finalize(Stmt);
  end;
end;

function TSqliteConnection.Exec(A: TArena; const Sql: string): TDbResult;
begin
  { Without parametre caches det ikke. Det er her migrasjoner og DDL havner,
    og et cachet CREATE TABLE er verken til nytte eller ønskelig. Samme
    deling som i Postgres- og MySQL-driveren. }
  Result := Run(A, Sql, [], False);
end;

function TSqliteConnection.ExecParams(A: TArena; const Sql: string;
  const Params: array of TDbParam): TDbResult;
begin
  Result := Run(A, Sql, Params, Length(Params) > 0);
end;

function TSqliteConnection.InsertGetId(A: TArena; const Sql: string;
  const Params: array of TDbParam; const IdColumn: string): Int64;
begin
  Run(A, Sql, Params, Length(Params) > 0);
  if IdColumn = '' then
    Exit(0);
  { SQLite har RETURNING fra 3.35, men last_insert_rowid virker i alle
    versjoner og koster ingen ekstra spørring. }
  Result := sqlite3_last_insert_rowid(FDb);
end;

procedure TSqliteConnection.StartTransaction;
begin
  Pragma('BEGIN');
  FInTransaction := True;
end;

procedure TSqliteConnection.Commit;
begin
  Pragma('COMMIT');
  FInTransaction := False;
end;

procedure TSqliteConnection.Rollback;
begin
  Pragma('ROLLBACK');
  FInTransaction := False;
end;

function MakeSqlite(const Dsn: string): TDbConnection;
begin
  Result := TSqliteConnection.Create(Dsn);
end;

initialization
  GLock := TCriticalSection.Create;
  RegisterDbDriver('sqlite', MakeSqlite);
  RegisterDbDriver('sqlite3', MakeSqlite);
  RegisterDbDriver('file', MakeSqlite);

finalization
  if GLib <> NilHandle then
    UnloadLibrary(GLib);
  GLock.Free;

end.
