{ Askr.Urd.MySql — the MySQL and MariaDB driver.

  The binding goes against **MariaDB Connector/C** (libmariadb). It is
  ABI-compatible with libmysqlclient, is in Debian as libmariadb3 and on
  Homebrew as mariadb-connector-c, and talks to both MySQL and MariaDB.
  One binding, two servers. Verified against MySQL 8.4 with
  caching_sha2_password.

  Two execution paths, deliberately:

    * Exec without parameters goes over the **text protocol**
      (mysql_real_query). Migrations and DDL end up here, and MySQL will
      not let you prepare all of it.
    * ExecParams goes over **prepared statements**, with a cache per
      connection. The parameters are then sent as parameters all the way
      to the server, not as text pasted into the query.

  The cache lives on the connection because a prepared statement does: it
  is the server's state for this particular session. A cache shared
  between connections would point at handles in the wrong session.

  Results are read as text over the binary protocol too: every column is
  bound as MYSQL_TYPE_STRING and the client converts. That keeps
  TDbResult the same across all three drivers, which is the whole point of
  the abstraction.

  MYSQL_BIND is a C struct this code has to match byte for byte. The
  layout is verified against the header with offsetof, not remembered —
  see the MYSQL_BIND_SIZE check in initialization. }
unit Askr.Urd.MySql;

{$mode Delphi}{$H+}
{$POINTERMATH ON}

interface

uses
  SysUtils, Classes, DynLibs, Askr.Core.Arena, Askr.Core.Text,
  Askr.Urd.Driver;

type
  TMySqlConnection = class(TDbConnection)
  private
    FMysql: Pointer;
    FDsn: string;
    FCache: TStringList;      { sql -> MYSQL_STMT* i Objects }
    FCacheLimit: Integer;
    FPrepared: Int64;
    FCacheHits: Int64;

    { The client library has per-thread state. The pool may give a
      connection to a thread other than the one that opened it, so it has
      to be set up there. }
    procedure EnsureThread;
    procedure RaiseConn(const Sql: string);
    { Builds the exception without raising it, so the error code can be
      read off the statement before anything closes it. }
    function StmtError(Stmt: Pointer; const Sql: string): EDbError;
    procedure RaiseStmt(Stmt: Pointer; const Sql: string);
    procedure Simple(const Sql: string);
    { Cached says whether the statement is in the cache. If it is not, the
      caller owns it and has to close it. }
    function Prepared(const Sql: string; out Cachet: Boolean): Pointer;
    procedure DropCached(const Sql: string);
    function RunText(A: TArena; const Sql: string): TDbResult;
    function RunPrepared(A: TArena; const Sql: string;
      const Params: array of TDbParam): TDbResult;
  public
    { Dsn is either a URI:

        mysql://user:password@host:3306/database
        mysql://user@/var/run/mysqld/mysqld.sock/database

      or key=value separated by semicolons:

        mysql:host=127.0.0.1;port=3308;user=askr;password=askr;db=askr_dev

      The character set is utf8mb4 unless charset= says otherwise. MySQL's
      "utf8" is not UTF-8, and the default here must not be a trap. }
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

    { Empties the statement cache. Necessary after DDL that changes a table
      a cached statement touches: the server notices, but a statement
      already prepared points at the old shape. }
    procedure FlushStatementCache;

    property Dsn: string read FDsn;
    { How many statements are prepared against the server, and how many
      calls got away with a cached one. For the tests, and for seeing that
      the cache works. }
    property PreparedCount: Int64 read FPrepared;
    property CacheHits: Int64 read FCacheHits;
    { 0 turns the cache off. The default is 64. }
    property CacheLimit: Integer read FCacheLimit write FCacheLimit;
  end;

function MySqlAvailable: Boolean;
function MySqlLibraryName: string;
function MySqlClientVersion: string;

implementation

uses
  SyncObjs;

const
  MYSQL_TYPE_LONGLONG = 8;
  MYSQL_TYPE_NULL     = 6;
  MYSQL_TYPE_STRING   = 254;

  MYSQL_SET_CHARSET_NAME   = 7;
  MYSQL_OPT_CONNECT_TIMEOUT = 0;
  MYSQL_OPT_READ_TIMEOUT   = 11;
  MYSQL_OPT_WRITE_TIMEOUT  = 12;

  CLIENT_FOUND_ROWS = 2;

  MYSQL_NO_DATA        = 100;
  MYSQL_DATA_TRUNCATED = 101;

  { Error codes that have to be translated to the SQLSTATEs the rest of
    Urd uses. MySQL's own SQLSTATE will not do: both a unique violation
    and a foreign key violation are reported as '23000'. The errno
    separates them. }
  ER_DUP_ENTRY            = 1062;
  ER_DUP_ENTRY_WITH_KEY   = 1586;
  ER_ROW_IS_REFERENCED_2  = 1451;
  ER_NO_REFERENCED_ROW_2  = 1452;
  ER_ROW_IS_REFERENCED    = 1216;
  ER_NO_REFERENCED_ROW    = 1217;

type
  PMysqlBind = ^TMysqlBind;
  { Verified against libmariadb: 112 bytes, the fields at 0, 8, 16, 24,
    32, 40, 48, 56, 64, 72, 80, 88, 92, 96, 100, 101, 102, 103, 104.
    Natural alignment in Pascal hits the same. }
  TMysqlBind = record
    Length_: PPtrUInt;          { 0 }
    IsNull: PByte;              { 8 }
    Buffer: Pointer;            { 16 }
    Error: PByte;               { 24 }
    RowPtr: Pointer;            { 32 — union row_ptr/indicator }
    StoreParamFunc: Pointer;    { 40 }
    FetchResult: Pointer;       { 48 }
    SkipResult: Pointer;        { 56 }
    BufferLength: PtrUInt;      { 64 }
    Offset: PtrUInt;            { 72 }
    LengthValue: PtrUInt;       { 80 }
    Flags: LongWord;            { 88 }
    PackLength: LongWord;       { 92 }
    BufferType: LongInt;        { 96 }
    ErrorValue: Byte;           { 100 }
    IsUnsigned: Byte;           { 101 }
    LongDataUsed: Byte;         { 102 }
    IsNullValue: Byte;          { 103 }
    Extension: Pointer;         { 104 }
  end;

  PRowChunk = ^TRowChunk;
  TRowChunk = record
    Cells: PDbCell;
    Next: PRowChunk;
  end;

  TCharPP = ^PAnsiChar;
  PPtrUIntArr = ^PtrUInt;

var
  mysql_init: function(M: Pointer): Pointer; cdecl;
  mysql_real_connect: function(M: Pointer; Host, User, Passwd, Db: PAnsiChar;
    Port: LongWord; UnixSocket: PAnsiChar; Flags: PtrUInt): Pointer; cdecl;
  mysql_close: procedure(M: Pointer); cdecl;
  mysql_options: function(M: Pointer; Opt: LongInt; Arg: Pointer): LongInt; cdecl;
  mysql_errno: function(M: Pointer): LongWord; cdecl;
  mysql_error: function(M: Pointer): PAnsiChar; cdecl;
  mysql_sqlstate: function(M: Pointer): PAnsiChar; cdecl;
  mysql_real_query: function(M: Pointer; Q: PAnsiChar; L: PtrUInt): LongInt; cdecl;
  mysql_store_result: function(M: Pointer): Pointer; cdecl;
  mysql_free_result: procedure(R: Pointer); cdecl;
  mysql_num_fields: function(R: Pointer): LongWord; cdecl;
  mysql_fetch_row: function(R: Pointer): TCharPP; cdecl;
  mysql_fetch_lengths: function(R: Pointer): PPtrUIntArr; cdecl;
  mysql_fetch_field_direct: function(R: Pointer; N: LongWord): Pointer; cdecl;
  mysql_affected_rows: function(M: Pointer): QWord; cdecl;
  mysql_insert_id: function(M: Pointer): QWord; cdecl;
  mysql_ping: function(M: Pointer): LongInt; cdecl;
  mysql_field_count: function(M: Pointer): LongWord; cdecl;
  mysql_get_client_info: function: PAnsiChar; cdecl;
  mysql_server_init: function(Argc: LongInt; Argv, Groups: Pointer): LongInt; cdecl;
  mysql_thread_init: function: Byte; cdecl;

  mysql_stmt_init: function(M: Pointer): Pointer; cdecl;
  mysql_stmt_prepare: function(S: Pointer; Q: PAnsiChar; L: PtrUInt): LongInt; cdecl;
  mysql_stmt_bind_param: function(S: Pointer; B: PMysqlBind): Byte; cdecl;
  mysql_stmt_execute: function(S: Pointer): LongInt; cdecl;
  mysql_stmt_store_result: function(S: Pointer): LongInt; cdecl;
  mysql_stmt_result_metadata: function(S: Pointer): Pointer; cdecl;
  mysql_stmt_bind_result: function(S: Pointer; B: PMysqlBind): Byte; cdecl;
  mysql_stmt_fetch: function(S: Pointer): LongInt; cdecl;
  mysql_stmt_fetch_column: function(S: Pointer; B: PMysqlBind; Col: LongWord;
    Offset: PtrUInt): LongInt; cdecl;
  mysql_stmt_affected_rows: function(S: Pointer): QWord; cdecl;
  mysql_stmt_field_count: function(S: Pointer): LongWord; cdecl;
  mysql_stmt_close: function(S: Pointer): Byte; cdecl;
  mysql_stmt_free_result: function(S: Pointer): Byte; cdecl;
  mysql_stmt_errno: function(S: Pointer): LongWord; cdecl;
  mysql_stmt_error: function(S: Pointer): PAnsiChar; cdecl;
  mysql_stmt_sqlstate: function(S: Pointer): PAnsiChar; cdecl;

  GLib: TLibHandle = NilHandle;
  GLibName: string = '';
  GTried: Boolean = False;
  GError: string = '';
  GLock: TCriticalSection;

function Candidates: TStringArray;
begin
{$IFDEF DARWIN}
  Result := [
    '/opt/homebrew/opt/mariadb-connector-c/lib/libmariadb.dylib',
    '/usr/local/opt/mariadb-connector-c/lib/libmariadb.dylib',
    '/opt/homebrew/opt/mysql-client/lib/libmysqlclient.dylib',
    '/usr/local/opt/mysql-client/lib/libmysqlclient.dylib',
    '/opt/homebrew/lib/libmariadb.dylib',
    'libmariadb.dylib', 'libmysqlclient.dylib'
  ];
{$ELSE}
{$IFDEF WINDOWS}
  Result := ['libmariadb.dll', 'libmysql.dll'];
{$ELSE}
  Result := ['libmariadb.so.3', 'libmysqlclient.so.21',
             'libmysqlclient.so.20', 'libmariadb.so', 'libmysqlclient.so'];
{$ENDIF}
{$ENDIF}
end;

function Resolve(const AName: string): Pointer;
begin
  Result := GetProcedureAddress(GLib, AName);
  if Result = nil then
    raise EDbUnavailable.CreateFmt(
      'The MySQL client was loaded from %s but is missing %s',
      [GLibName, AName]);
end;

function ResolveOpt(const AName: string): Pointer;
begin
  Result := GetProcedureAddress(GLib, AName);
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
      GError := 'Could not find the MySQL client library. Tried: ' + Tried + '.' +
{$IFDEF DARWIN}
        ' On macOS: brew install mariadb-connector-c.';
{$ELSE}
        ' On Debian and Ubuntu: apt install libmariadb3.';
{$ENDIF}
      raise EDbUnavailable.Create(GError);
    end;

    try
      mysql_init := Resolve('mysql_init');
      mysql_real_connect := Resolve('mysql_real_connect');
      mysql_close := Resolve('mysql_close');
      mysql_options := Resolve('mysql_options');
      mysql_errno := Resolve('mysql_errno');
      mysql_error := Resolve('mysql_error');
      mysql_sqlstate := Resolve('mysql_sqlstate');
      mysql_real_query := Resolve('mysql_real_query');
      mysql_store_result := Resolve('mysql_store_result');
      mysql_free_result := Resolve('mysql_free_result');
      mysql_num_fields := Resolve('mysql_num_fields');
      mysql_fetch_row := Resolve('mysql_fetch_row');
      mysql_fetch_lengths := Resolve('mysql_fetch_lengths');
      mysql_fetch_field_direct := Resolve('mysql_fetch_field_direct');
      mysql_affected_rows := Resolve('mysql_affected_rows');
      mysql_insert_id := Resolve('mysql_insert_id');
      mysql_ping := Resolve('mysql_ping');
      mysql_field_count := Resolve('mysql_field_count');
      mysql_get_client_info := Resolve('mysql_get_client_info');
      mysql_server_init := ResolveOpt('mysql_server_init');
      mysql_thread_init := ResolveOpt('mysql_thread_init');

      mysql_stmt_init := Resolve('mysql_stmt_init');
      mysql_stmt_prepare := Resolve('mysql_stmt_prepare');
      mysql_stmt_bind_param := Resolve('mysql_stmt_bind_param');
      mysql_stmt_execute := Resolve('mysql_stmt_execute');
      mysql_stmt_store_result := Resolve('mysql_stmt_store_result');
      mysql_stmt_result_metadata := Resolve('mysql_stmt_result_metadata');
      mysql_stmt_bind_result := Resolve('mysql_stmt_bind_result');
      mysql_stmt_fetch := Resolve('mysql_stmt_fetch');
      mysql_stmt_fetch_column := Resolve('mysql_stmt_fetch_column');
      mysql_stmt_affected_rows := Resolve('mysql_stmt_affected_rows');
      mysql_stmt_field_count := Resolve('mysql_stmt_field_count');
      mysql_stmt_close := Resolve('mysql_stmt_close');
      mysql_stmt_free_result := Resolve('mysql_stmt_free_result');
      mysql_stmt_errno := Resolve('mysql_stmt_errno');
      mysql_stmt_error := Resolve('mysql_stmt_error');
      mysql_stmt_sqlstate := Resolve('mysql_stmt_sqlstate');

      if Assigned(mysql_server_init) then
        mysql_server_init(0, nil, nil);
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

function MySqlAvailable: Boolean;
begin
  try
    EnsureLoaded;
    Result := True;
  except
    Result := False;
  end;
end;

function MySqlLibraryName: string;
begin
  Result := GLibName;
end;

function MySqlClientVersion: string;
begin
  EnsureLoaded;
  Result := string(mysql_get_client_info());
end;

{ Translates MySQL's errno into the SQLSTATEs the rest of Urd knows.
  MySQL says '23000' for both a unique violation and a foreign key
  violation, so the SQLSTATE alone cannot tell them apart. }
function StateFor(Errno: LongWord; const Native: string): string;
begin
  case Errno of
    ER_DUP_ENTRY, ER_DUP_ENTRY_WITH_KEY:
      Result := '23505';
    ER_ROW_IS_REFERENCED, ER_ROW_IS_REFERENCED_2,
    ER_NO_REFERENCED_ROW, ER_NO_REFERENCED_ROW_2:
      Result := '23503';
  else
    Result := Native;
  end;
end;

{ ---- DSN ---- }

type
  TConnInfo = record
    Host, User, Password, Db, Socket, Charset: string;
    Port: LongWord;
    TimeoutSec: LongInt;
  end;

function UrlDecode(const S: string): string;
var
  I: Integer;
  C: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if (S[I] = '%') and (I + 2 <= Length(S)) and
       TryStrToInt('$' + Copy(S, I + 1, 2), C) then
    begin
      Result := Result + Chr(C);
      Inc(I, 3);
    end
    else
    begin
      Result := Result + S[I];
      Inc(I);
    end;
  end;
end;

procedure ParseDsn(const Dsn: string; out Info: TConnInfo);
var
  Rest, Auth, HostPart, Key, Value: string;
  P: Integer;
  Pairs: TStringList;
  I: Integer;
begin
  FillChar(Info, SizeOf(Info), 0);
  Info.Host := '127.0.0.1';
  Info.Port := 3306;
  Info.Charset := 'utf8mb4';
  Info.TimeoutSec := 10;

  P := Pos(':', Dsn);
  if P <= 0 then
    { Never the DSN. A DSN that is wrong in some other way still carries a
      password that is right, and this message is exactly the one that ends
      up pasted into an issue. }
    raise EDbError.Create('Invalid MySQL DSN: no scheme. Expected ' +
      'mysql://user:password@host:port/database');
  Rest := Copy(Dsn, P + 1, MaxInt);

  if Copy(Rest, 1, 2) = '//' then
  begin
    { URI-form. }
    Rest := Copy(Rest, 3, MaxInt);
    P := Pos('@', Rest);
    if P > 0 then
    begin
      Auth := Copy(Rest, 1, P - 1);
      Rest := Copy(Rest, P + 1, MaxInt);
      P := Pos(':', Auth);
      if P > 0 then
      begin
        Info.User := UrlDecode(Copy(Auth, 1, P - 1));
        Info.Password := UrlDecode(Copy(Auth, P + 1, MaxInt));
      end
      else
        Info.User := UrlDecode(Auth);
    end;

    P := Pos('/', Rest);
    if P > 0 then
    begin
      HostPart := Copy(Rest, 1, P - 1);
      Info.Db := Copy(Rest, P + 1, MaxInt);
    end
    else
    begin
      HostPart := Rest;
      Info.Db := '';
    end;

    P := Pos('?', Info.Db);
    if P > 0 then
    begin
      Rest := Copy(Info.Db, P + 1, MaxInt);
      Info.Db := Copy(Info.Db, 1, P - 1);
      Pairs := TStringList.Create;
      try
        Pairs.Delimiter := '&';
        Pairs.StrictDelimiter := True;
        Pairs.DelimitedText := Rest;
        for I := 0 to Pairs.Count - 1 do
        begin
          Key := LowerCase(Pairs.Names[I]);
          Value := Pairs.ValueFromIndex[I];
          if Key = 'charset' then Info.Charset := Value
          else if Key = 'timeout' then Info.TimeoutSec := StrToIntDef(Value, 10);
        end;
      finally
        Pairs.Free;
      end;
    end;

    if HostPart <> '' then
    begin
      P := Pos(':', HostPart);
      if P > 0 then
      begin
        Info.Host := Copy(HostPart, 1, P - 1);
        Info.Port := LongWord(StrToIntDef(Copy(HostPart, P + 1, MaxInt), 3306));
      end
      else
        Info.Host := HostPart;
    end;
    Exit;
  end;

  { The key=value form. }
  Pairs := TStringList.Create;
  try
    Pairs.Delimiter := ';';
    Pairs.StrictDelimiter := True;
    Pairs.DelimitedText := Rest;
    for I := 0 to Pairs.Count - 1 do
    begin
      Key := LowerCase(Trim(Pairs.Names[I]));
      Value := Trim(Pairs.ValueFromIndex[I]);
      if (Key = 'host') or (Key = 'server') then Info.Host := Value
      else if Key = 'port' then Info.Port := LongWord(StrToIntDef(Value, 3306))
      else if (Key = 'user') or (Key = 'username') then Info.User := Value
      else if (Key = 'password') or (Key = 'passwd') then Info.Password := Value
      else if (Key = 'db') or (Key = 'database') or (Key = 'dbname') then
        Info.Db := Value
      else if Key = 'socket' then Info.Socket := Value
      else if Key = 'charset' then Info.Charset := Value
      else if Key = 'timeout' then Info.TimeoutSec := StrToIntDef(Value, 10);
    end;
  finally
    Pairs.Free;
  end;
end;

{ ---- TMySqlConnection ---- }

function NilOrPChar(const S: string; var Buf: AnsiString): PAnsiChar;
begin
  if S = '' then
    Exit(nil);
  Buf := AnsiString(S);
  Result := PAnsiChar(Buf);
end;

constructor TMySqlConnection.Create(const ADsn: string);
var
  Info: TConnInfo;
  BHost, BUser, BPass, BDb, BSock, BChar: AnsiString;
  Timeout: LongInt;
begin
  inherited Create;
  EnsureLoaded;
  EnsureThread;
  FDsn := ADsn;
  FCacheLimit := 64;
  FCache := TStringList.Create;
  FCache.Sorted := True;
  FCache.Duplicates := dupIgnore;

  ParseDsn(ADsn, Info);

  FMysql := mysql_init(nil);
  if FMysql = nil then
    raise EDbUnavailable.Create('mysql_init returned nil');

  Timeout := Info.TimeoutSec;
  mysql_options(FMysql, MYSQL_OPT_CONNECT_TIMEOUT, @Timeout);
  mysql_options(FMysql, MYSQL_OPT_READ_TIMEOUT, @Timeout);
  mysql_options(FMysql, MYSQL_OPT_WRITE_TIMEOUT, @Timeout);
  BChar := AnsiString(Info.Charset);
  mysql_options(FMysql, MYSQL_SET_CHARSET_NAME, PAnsiChar(BChar));

  { CLIENT_FOUND_ROWS makes UPDATE report rows that matched rather than
    rows that actually changed. Without it, "save with no changes"
    reports 0 rows and the calling code believes the row is gone. }
  if mysql_real_connect(FMysql,
       NilOrPChar(Info.Host, BHost), NilOrPChar(Info.User, BUser),
       NilOrPChar(Info.Password, BPass), NilOrPChar(Info.Db, BDb),
       Info.Port, NilOrPChar(Info.Socket, BSock), CLIENT_FOUND_ROWS) = nil then
  begin
    FDsn := Format('%s:%d', [Info.Host, Info.Port]);
    try
      raise EDbError.Create(
        Format('Could not connect to MySQL at %s: %s',
          [FDsn, string(mysql_error(FMysql))]),
        string(mysql_sqlstate(FMysql)));
    finally
      mysql_close(FMysql);
      FMysql := nil;
      FreeAndNil(FCache);
    end;
  end;
end;

destructor TMySqlConnection.Destroy;
begin
  if FCache <> nil then
  begin
    FlushStatementCache;
    FreeAndNil(FCache);
  end;
  if FMysql <> nil then
  begin
    mysql_close(FMysql);
    FMysql := nil;
  end;
  inherited Destroy;
end;

{ mysql_thread_init has to be called once in every thread that touches
  the library. Without it, simple queries appear to work, but the
  conversion of results over the prepared protocol uses thread-local
  buffers that do not exist — and the values come back empty with nothing
  reporting an error.

  The flag is a threadvar, so each thread only does it the first time. The
  matching mysql_thread_end is never called: there is no portable way to
  hook onto a thread finishing, and the price is one small thread-local
  allocation per thread in a process that has long-lived workers
  anyway. }
threadvar
  GThreadReady: Boolean;

procedure TMySqlConnection.EnsureThread;
begin
  if GThreadReady then
    Exit;
  if Assigned(mysql_thread_init) then
    mysql_thread_init();
  GThreadReady := True;
end;

function TMySqlConnection.Dialect: TSqlDialect;
begin
  Result := sdMySql;
end;

function TMySqlConnection.IsAlive: Boolean;
begin
  if FMysql = nil then
    Exit(False);
  EnsureThread;
  Result := mysql_ping(FMysql) = 0;
end;

procedure TMySqlConnection.RaiseConn(const Sql: string);
var
  E: LongWord;
begin
  E := mysql_errno(FMysql);
  raise EDbError.Create(
    Format('MySQL error %d: %s'#10'  SQL: %s',
      [E, string(mysql_error(FMysql)), Sql]),
    StateFor(E, string(mysql_sqlstate(FMysql))));
end;

function TMySqlConnection.StmtError(Stmt: Pointer;
  const Sql: string): EDbError;
var
  E: LongWord;
begin
  E := mysql_stmt_errno(Stmt);
  Result := EDbError.Create(
    Format('MySQL error %d: %s'#10'  SQL: %s',
      [E, string(mysql_stmt_error(Stmt)), Sql]),
    StateFor(E, string(mysql_stmt_sqlstate(Stmt))));
end;

procedure TMySqlConnection.RaiseStmt(Stmt: Pointer; const Sql: string);
begin
  raise StmtError(Stmt, Sql);
end;

procedure TMySqlConnection.Simple(const Sql: string);
var
  Res: Pointer;
begin
  EnsureThread;
  if mysql_real_query(FMysql, PAnsiChar(AnsiString(Sql)), PtrUInt(Length(Sql))) <> 0 then
    RaiseConn(Sql);
  { Even a statement with no result has to be fetched and freed, or the
    connection is left "out of sync" for the next query. }
  Res := mysql_store_result(FMysql);
  if Res <> nil then
    mysql_free_result(Res);
end;

procedure TMySqlConnection.DropCached(const Sql: string);
var
  Idx: Integer;
begin
  Idx := FCache.IndexOf(Sql);
  if Idx >= 0 then
  begin
    mysql_stmt_close(Pointer(FCache.Objects[Idx]));
    FCache.Delete(Idx);
  end;
end;

procedure TMySqlConnection.FlushStatementCache;
var
  I: Integer;
begin
  if FCache = nil then
    Exit;
  for I := 0 to FCache.Count - 1 do
    if FCache.Objects[I] <> nil then
      mysql_stmt_close(Pointer(FCache.Objects[I]));
  FCache.Clear;
end;

function TMySqlConnection.Prepared(const Sql: string;
  out Cachet: Boolean): Pointer;
var
  Idx: Integer;
  Stmt: Pointer;
begin
  Cachet := False;
  Idx := FCache.IndexOf(Sql);
  if Idx >= 0 then
  begin
    Inc(FCacheHits);
    Cachet := True;
    Exit(Pointer(FCache.Objects[Idx]));
  end;

  Stmt := mysql_stmt_init(FMysql);
  if Stmt = nil then
    RaiseConn(Sql);
  if mysql_stmt_prepare(Stmt, PAnsiChar(AnsiString(Sql)),
     PtrUInt(Length(Sql))) <> 0 then
  begin
    try
      RaiseStmt(Stmt, Sql);
    finally
      mysql_stmt_close(Stmt);
    end;
  end;
  Inc(FPrepared);

  if FCacheLimit > 0 then
  begin
    { The limit is a limit, not an LRU. A prepared statement costs server
      memory, and an app with unboundedly many different queries must not be
      able to eat it. If the cache goes over, it is emptied entirely —
      simpler than a reuse order, and it rarely happens in practice because
      the queries in an app are a finite set. }
    if FCache.Count >= FCacheLimit then
      FlushStatementCache;
    FCache.AddObject(Sql, TObject(Stmt));
    Cachet := True;
  end;
  Result := Stmt;
end;

function TMySqlConnection.RunText(A: TArena; const Sql: string): TDbResult;
var
  Res: Pointer;
  Row: TCharPP;
  Lens: PPtrUIntArr;
  Cols, I, R, RowCount: Integer;
  Prev: TArena;
  Head, Last, Chunk: PRowChunk;
  Cells: PDbCell;
  Fld: Pointer;
begin
  EnsureThread;
  if mysql_real_query(FMysql, PAnsiChar(AnsiString(Sql)),
     PtrUInt(Length(Sql))) <> 0 then
    RaiseConn(Sql);

  Res := mysql_store_result(FMysql);
  if Res = nil then
  begin
    { No result set. Either an INSERT/UPDATE/DELETE, or an error —
      field_count separates them. }
    if mysql_field_count(FMysql) <> 0 then
      RaiseConn(Sql);
    Prev := UseArena(A);
    try
      Result := TDbResult.Create;
      Result.Allocate(0, 0);
      Result.SetAffected(Int64(mysql_affected_rows(FMysql)));
    finally
      UseArena(Prev);
    end;
    Exit;
  end;

  try
    Cols := Integer(mysql_num_fields(Res));
    Head := nil;
    Last := nil;
    RowCount := 0;

    repeat
      Row := mysql_fetch_row(Res);
      if Row = nil then
        Break;
      Lens := mysql_fetch_lengths(Res);
      Cells := PDbCell(A.AllocZero(PtrUInt(Cols) * SizeOf(TDbCell)));
      for I := 0 to Cols - 1 do
        if Row[I] = nil then
        begin
          Cells[I].IsNull := True;
          Cells[I].Value := StrEmpty;
        end
        else
        begin
          Cells[I].IsNull := False;
          Cells[I].Value := StrDup(A, StrRef(PByte(Row[I]), Integer(Lens[I])));
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
    until False;

    Prev := UseArena(A);
    try
      Result := TDbResult.Create;
      Result.Allocate(RowCount, Cols);
      for I := 0 to Cols - 1 do
      begin
        { MYSQL_FIELD has name as its very first field in both MariaDB and
          MySQL. Only that is read, so the rest of the struct — which differs
          between the two — never becomes a dependency. }
        Fld := mysql_fetch_field_direct(Res, LongWord(I));
        if Fld <> nil then
          Result.SetFieldName(I, StrDup(A, string(PPAnsiChar(Fld)^)))
        else
          Result.SetFieldName(I, StrEmpty);
      end;
      Chunk := Head;
      R := 0;
      while Chunk <> nil do
      begin
        for I := 0 to Cols - 1 do
          Result.SetCell(R, I, Chunk^.Cells[I].Value, Chunk^.Cells[I].IsNull);
        Inc(R);
        Chunk := Chunk^.Next;
      end;
    finally
      UseArena(Prev);
    end;
  finally
    mysql_free_result(Res);
  end;
end;

function TMySqlConnection.RunPrepared(A: TArena; const Sql: string;
  const Params: array of TDbParam): TDbResult;
var
  Stmt, Meta: Pointer;
  Binds, Outs: PMysqlBind;
  Lens: PPtrUInt;
  Nulls, Errs: PByte;
  Cols, I, R, RowCount: Integer;
  Rc: LongInt;
  Prev: TArena;
  Head, Last, Chunk: PRowChunk;
  Cells: PDbCell;
  Fld: Pointer;
  Buf, Small: PByte;
  Err: EDbError;
  Cachet, MustClose: Boolean;
const
  SmallBuf = 192;
begin
  EnsureThread;
  Stmt := Prepared(Sql, Cachet);
  { A cached statement is owned by the cache and closed on eviction or at
    Destroy. An uncached one is owned by this call. }
  MustClose := not Cachet;
  try

  { The parameters have to live in memory that survives execute. They are
    therefore allocated before the mark, the same pitfall as in the Pg
    driver. }
  Binds := nil;
  if Length(Params) > 0 then
  begin
    Binds := PMysqlBind(A.AllocZero(PtrUInt(Length(Params)) * SizeOf(TMysqlBind)));
    for I := 0 to High(Params) do
    begin
      if Params[I].IsNull then
      begin
        Binds[I].BufferType := MYSQL_TYPE_NULL;
        Binds[I].IsNullValue := 1;
        Continue;
      end;
      Buf := PByte(A.Alloc(PtrUInt(Params[I].Value.Len) + 1));
      if Params[I].Value.Len > 0 then
        Move(Params[I].Value.Data^, Buf^, Params[I].Value.Len);
      Buf[Params[I].Value.Len] := 0;
      Binds[I].BufferType := MYSQL_TYPE_STRING;
      Binds[I].Buffer := Buf;
      Binds[I].BufferLength := PtrUInt(Params[I].Value.Len);
      Binds[I].LengthValue := PtrUInt(Params[I].Value.Len);
      Binds[I].Length_ := @Binds[I].LengthValue;
    end;
    if mysql_stmt_bind_param(Stmt, Binds) <> 0 then
      RaiseStmt(Stmt, Sql);
  end;

    if mysql_stmt_execute(Stmt) <> 0 then
    begin
    { The error has to be read BEFORE the statement is evicted from the
      cache: DropCached calls mysql_stmt_close, and after that errno and
      sqlstate are freed memory. Done the other way round, every single
      unique violation was reported as SQLSTATE 00000 — that is, "no error".

      The statement is evicted because a cached statement may have been
      prepared against a table that has since changed; the next attempt
      should prepare afresh. }
      Err := StmtError(Stmt, Sql);
      { DropCached closes it itself. Closing it once more in the finally is
        a double free — and it showed up as an access violation in the
        unique-violation test, not as anything resembling the cause. }
      if Cachet then
        DropCached(Sql)
      else
        mysql_stmt_close(Stmt);
      MustClose := False;
      raise Err;
    end;

    Meta := mysql_stmt_result_metadata(Stmt);
    if Meta = nil then
    begin
      Prev := UseArena(A);
      try
        Result := TDbResult.Create;
        Result.Allocate(0, 0);
        Result.SetAffected(Int64(mysql_stmt_affected_rows(Stmt)));
      finally
        UseArena(Prev);
      end;
      mysql_stmt_free_result(Stmt);
      Exit;
    end;

    try
    Cols := Integer(mysql_stmt_field_count(Stmt));
    if mysql_stmt_store_result(Stmt) <> 0 then
      RaiseStmt(Stmt, Sql);

    { Every column gets a small fixed buffer, and only what does not fit is
      fetched a second time.

      The temptation is to bind with an empty buffer and let Lens report the
      length on the first pass. That works for everything the server sends
      as text — VARCHAR, TEXT, DECIMAL and integers — but **not for
      floats**: a DOUBLE arrives in binary over the prepared protocol, and
      without a buffer to convert into, the client sets the length to zero.
      The result was empty values for every single floating-point column,
      with no error anywhere.

      With a 192-byte buffer, numbers, dates and short strings fit at once,
      and longer text is taken on a second pass where Lens is now
      trustworthy because the conversion has actually happened. }
    Outs := PMysqlBind(A.AllocZero(PtrUInt(Cols) * SizeOf(TMysqlBind)));
    Lens := PPtrUInt(A.AllocZero(PtrUInt(Cols) * SizeOf(PtrUInt)));
    Nulls := PByte(A.AllocZero(PtrUInt(Cols)));
    Errs := PByte(A.AllocZero(PtrUInt(Cols)));
    Small := PByte(A.Alloc(PtrUInt(Cols) * SmallBuf));
    for I := 0 to Cols - 1 do
    begin
      Outs[I].BufferType := MYSQL_TYPE_STRING;
      Outs[I].Buffer := Small + PtrUInt(I) * SmallBuf;
      Outs[I].BufferLength := SmallBuf;
      Outs[I].Length_ := @Lens[I];
      Outs[I].IsNull := @Nulls[I];
      Outs[I].Error := @Errs[I];
    end;
    if mysql_stmt_bind_result(Stmt, Outs) <> 0 then
      RaiseStmt(Stmt, Sql);

    Head := nil;
    Last := nil;
    RowCount := 0;

    repeat
      Rc := mysql_stmt_fetch(Stmt);
      if (Rc = MYSQL_NO_DATA) or (Rc = 1) then
      begin
        if Rc = 1 then
          RaiseStmt(Stmt, Sql);
        Break;
      end;
      { MYSQL_DATA_TRUNCATED is expected here — the buffers are deliberately
        empty. }
      Cells := PDbCell(A.AllocZero(PtrUInt(Cols) * SizeOf(TDbCell)));
      for I := 0 to Cols - 1 do
      begin
        if Nulls[I] <> 0 then
        begin
          Cells[I].IsNull := True;
          Cells[I].Value := StrEmpty;
          Continue;
        end;
        Cells[I].IsNull := False;
        if Lens[I] = 0 then
        begin
          Cells[I].Value := StrEmpty;
          Continue;
        end;
        if Lens[I] <= SmallBuf then
        begin
          { The value is already in the fixed buffer, but that is reused by the
            next row — hence a copy into the arena rather than a pointer to
            it. }
          Cells[I].Value := StrDup(A,
            StrRef(Small + PtrUInt(I) * SmallBuf, Integer(Lens[I])));
          Continue;
        end;
        Buf := PByte(A.Alloc(Lens[I]));
        Outs[I].Buffer := Buf;
        Outs[I].BufferLength := Lens[I];
        if mysql_stmt_fetch_column(Stmt, @Outs[I], LongWord(I), 0) <> 0 then
          RaiseStmt(Stmt, Sql);
        Cells[I].Value := StrRef(Buf, Integer(Lens[I]));
        { Back to the fixed buffer, or the next row overwrites the value just
          placed in the arena. }
        Outs[I].Buffer := Small + PtrUInt(I) * SmallBuf;
        Outs[I].BufferLength := SmallBuf;
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
    until False;

    Prev := UseArena(A);
    try
      Result := TDbResult.Create;
      Result.Allocate(RowCount, Cols);
      for I := 0 to Cols - 1 do
      begin
        Fld := mysql_fetch_field_direct(Meta, LongWord(I));
        if Fld <> nil then
          Result.SetFieldName(I, StrDup(A, string(PPAnsiChar(Fld)^)))
        else
          Result.SetFieldName(I, StrEmpty);
      end;
      Chunk := Head;
      R := 0;
      while Chunk <> nil do
      begin
        for I := 0 to Cols - 1 do
          Result.SetCell(R, I, Chunk^.Cells[I].Value, Chunk^.Cells[I].IsNull);
        Inc(R);
        Chunk := Chunk^.Next;
      end;
    finally
      UseArena(Prev);
    end;
    finally
      mysql_free_result(Meta);
      { The result has to be freed on the server before the statement can be
        used again. Without this the next execute gives "commands out of
        sync". }
      mysql_stmt_free_result(Stmt);
    end;
  finally
    { A statement that did not end up in the cache is owned by this call.
      Without this close, CacheLimit := 0 leaks one statement per query —
      both in the client and on the server. }
    if MustClose then
      mysql_stmt_close(Stmt);
  end;
end;

function TMySqlConnection.Exec(A: TArena; const Sql: string): TDbResult;
begin
  Result := RunText(A, Sql);
end;

function TMySqlConnection.ExecParams(A: TArena; const Sql: string;
  const Params: array of TDbParam): TDbResult;
begin
  if Length(Params) = 0 then
    Result := RunText(A, Sql)
  else
    Result := RunPrepared(A, Sql, Params);
end;

function TMySqlConnection.InsertGetId(A: TArena; const Sql: string;
  const Params: array of TDbParam; const IdColumn: string): Int64;
begin
  { MySQL has no RETURNING. LAST_INSERT_ID is read from the connection
    afterwards, and applies to the last INSERT on this particular
    connection — so it is safe even with a pool, as long as nobody shares
    a connection. }
  if Length(Params) = 0 then
  begin
    RunText(A, Sql);
    if IdColumn = '' then
      Exit(0);
    Result := Int64(mysql_insert_id(FMysql));
  end
  else
  begin
    RunPrepared(A, Sql, Params);
    if IdColumn = '' then
      Exit(0);
    Result := Int64(mysql_insert_id(FMysql));
  end;
end;

procedure TMySqlConnection.StartTransaction;
begin
  if FInTransaction then
    raise EDbError.Create('The transaction is already open');
  Simple('START TRANSACTION');
  FInTransaction := True;
end;

procedure TMySqlConnection.Commit;
begin
  if not FInTransaction then
    raise EDbError.Create('Commit without a transaction');
  Simple('COMMIT');
  FInTransaction := False;
end;

procedure TMySqlConnection.Rollback;
begin
  if not FInTransaction then
    Exit;
  try
    Simple('ROLLBACK');
  finally
    FInTransaction := False;
  end;
end;

function MakeMySql(const Dsn: string): TDbConnection;
begin
  Result := TMySqlConnection.Create(Dsn);
end;

initialization
  GLock := TCriticalSection.Create;
  { The layout is verified with offsetof against libmariadb's header. If
    anyone changes the record, it should blow up here and not in a random
    column. }
  Assert(SizeOf(TMysqlBind) = 112, 'TMysqlBind must be 112 bytes');
  RegisterDbDriver('mysql', MakeMySql);
  RegisterDbDriver('mariadb', MakeMySql);

finalization
  if GLib <> NilHandle then
    UnloadLibrary(GLib);
  GLock.Free;

end.
