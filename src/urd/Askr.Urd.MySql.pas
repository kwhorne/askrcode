{ Askr.Urd.MySql — MySQL- og MariaDB-driver.

  Bindingen går mot **MariaDB Connector/C** (libmariadb). Den er
  ABI-kompatibel med libmysqlclient, ligger i Debian som libmariadb3 og på
  Homebrew som mariadb-connector-c, og snakker med både MySQL og MariaDB.
  Én binding, to servere. Verifisert mot MySQL 8.4 med caching_sha2_password.

  To utførelsesveier, med vilje:

    * Exec uten parametre går over **tekstprotokollen** (mysql_real_query).
      Migrasjoner og DDL havner her, og MySQL lar seg ikke prepare på alt av
      det.
    * ExecParams går over **prepared statements**, med en cache per
      forbindelse. Parametrene sendes da som parametre hele veien til
      serveren, ikke som tekst limt inn i spørringen.

  Cachen ligger på forbindelsen fordi et prepared statement gjør det: det er
  serverens tilstand for akkurat denne sesjonen. En cache delt mellom
  forbindelser ville pekt på håndtak i feil sesjon.

  Resultatene leses som tekst også over binærprotokollen: alle kolonner
  bindes som MYSQL_TYPE_STRING, og klienten konverterer. Det holder
  TDbResult likt på tvers av de tre driverne, som er hele poenget med
  abstraksjonen.

  MYSQL_BIND er en C-struct denne koden må treffe på byten. Layouten er
  verifisert mot headeren med offsetof, ikke husket — se
  MYSQL_BIND_SIZE-sjekken i initialization. }
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

    { Klientbiblioteket har tilstand per tråd. Poolen kan gi en forbindelse
      til en annen tråd enn den som åpnet den, så den må settes opp der. }
    procedure EnsureThread;
    procedure RaiseConn(const Sql: string);
    { Bygger unntaket uten å kaste det, slik at feilkoden kan leses av
      statementet før noe lukker det. }
    function StmtError(Stmt: Pointer; const Sql: string): EDbError;
    procedure RaiseStmt(Stmt: Pointer; const Sql: string);
    procedure Simple(const Sql: string);
    { Cachet sier om statementet ligger i cachen. Gjør det ikke det, eier
      kalleren det og må lukke det. }
    function Prepared(const Sql: string; out Cachet: Boolean): Pointer;
    procedure DropCached(const Sql: string);
    function RunText(A: TArena; const Sql: string): TDbResult;
    function RunPrepared(A: TArena; const Sql: string;
      const Params: array of TDbParam): TDbResult;
  public
    { Dsn er enten en URI:

        mysql://bruker:passord@vert:3306/database
        mysql://bruker@/var/run/mysqld/mysqld.sock/database

      eller nøkkel=verdi atskilt med semikolon:

        mysql:host=127.0.0.1;port=3308;user=askr;password=askr;db=askr_dev

      Tegnsettet er utf8mb4 med mindre charset= sier noe annet. MySQLs
      «utf8» er ikke UTF-8, og standarden her skal ikke være en felle. }
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

    { Tømmer statement-cachen. Nødvendig etter DDL som endrer en tabell et
      cachet statement rører: serveren merker det, men et statement som
      allerede er forberedt peker på den gamle formen. }
    procedure FlushStatementCache;

    property Dsn: string read FDsn;
    { Hvor mange statements som er forberedt mot serveren, og hvor mange kall
      som slapp unna med et cachet. Til testene og til å se at cachen virker. }
    property PreparedCount: Int64 read FPrepared;
    property CacheHits: Int64 read FCacheHits;
    { 0 slår cachen av. Standard er 64. }
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

  { Feilkoder som må oversettes til SQLSTATE-ene resten av Urd bruker.
    MySQLs egen SQLSTATE duger ikke: både unik-brudd og fremmednøkkelbrudd
    rapporteres som '23000'. Errno skiller dem. }
  ER_DUP_ENTRY            = 1062;
  ER_DUP_ENTRY_WITH_KEY   = 1586;
  ER_ROW_IS_REFERENCED_2  = 1451;
  ER_NO_REFERENCED_ROW_2  = 1452;
  ER_ROW_IS_REFERENCED    = 1216;
  ER_NO_REFERENCED_ROW    = 1217;

type
  PMysqlBind = ^TMysqlBind;
  { Verifisert mot libmariadb: 112 bytes, feltene på 0, 8, 16, 24, 32, 40,
    48, 56, 64, 72, 80, 88, 92, 96, 100, 101, 102, 103, 104. Naturlig
    justering i Pascal treffer det samme. }
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

{ Oversetter MySQLs errno til SQLSTATE-ene resten av Urd kjenner. MySQL sier
  '23000' om både unik-brudd og fremmednøkkelbrudd, så SQLSTATE alene kan
  ikke brukes til å skille dem. }
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
    raise EDbError.CreateFmt('Invalid MySQL DSN: %s', [Dsn]);
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

  { Nøkkel=verdi-form. }
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

  { CLIENT_FOUND_ROWS gjør at UPDATE rapporterer rader som traff, ikke rader
    som faktisk endret seg. Uten det melder «lagre uten endringer» 0 rader,
    og kallende kode tror raden er borte. }
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

{ mysql_thread_init må kalles én gang i hver tråd som rører biblioteket.
  Uten det virker enkle spørringer tilsynelatende, men konverteringen av
  resultater over prepared-protokollen bruker trådlokale buffere som ikke
  finnes — og verdiene kommer tomme tilbake uten at noe melder feil.

  Flagget er en threadvar, så hver tråd gjør det bare første gang. Den
  tilhørende mysql_thread_end kalles aldri: det finnes ingen bærbar måte å
  henge seg på at en tråd avslutter, og prisen er én liten trådlokal
  allokering per tråd i en prosess som uansett har langlevde workere. }
threadvar
  GThreadKlar: Boolean;

procedure TMySqlConnection.EnsureThread;
begin
  if GThreadKlar then
    Exit;
  if Assigned(mysql_thread_init) then
    mysql_thread_init();
  GThreadKlar := True;
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
  { Selv en setning uten resultat må hentes og frigjøres, ellers står
    forbindelsen igjen «ute av synk» for neste spørring. }
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
    { Grensen er en grense, ikke en LRU. Et prepared statement koster
      serverminne, og en app med ubegrenset mange ulike spørringer skal ikke
      kunne spise det opp. Faller cachen over, tømmes den helt — enklere enn
      en gjenbruksrekkefølge, og treffer sjelden i praksis fordi spørringene
      i en app er et endelig sett. }
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
    { Ingen resultatsett. Enten en INSERT/UPDATE/DELETE, eller en feil —
      field_count skiller dem. }
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
        { MYSQL_FIELD har name som aller første felt i både MariaDB og MySQL.
          Bare det leses, slik at resten av structen — som er ulik mellom de
          to — aldri blir en avhengighet. }
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
  Feil: EDbError;
  Cachet, MaaLukkes: Boolean;
const
  SmallBuf = 192;
begin
  EnsureThread;
  Stmt := Prepared(Sql, Cachet);
  { Et cachet statement eies av cachen og lukkes ved utkasting eller ved
    Destroy. Et ucachet eies av dette kallet. }
  MaaLukkes := not Cachet;
  try

  { Parametrene må ligge i minne som overlever execute. De allokeres derfor
    før merket, jf. samme fallgruve som i Pg-driveren. }
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
    { Feilen må leses FØR statementet kastes ut av cachen: DropCached kaller
      mysql_stmt_close, og etter det er errno og sqlstate frigjort minne.
      Gjorde man det i motsatt rekkefølge, ble hvert eneste unik-brudd
      rapportert som SQLSTATE 00000 — altså «ingen feil».

      Statementet kastes ut fordi et cachet statement kan være forberedt mot
      en tabell som siden er endret; neste forsøk skal forberede på nytt. }
      Feil := StmtError(Stmt, Sql);
      { DropCached lukker selv. Lukkes det så én gang til i finally, er det
        en dobbeltfrigjøring — og den viste seg som en access violation i
        unik-brudd-testen, ikke som noe som lignet årsaken. }
      if Cachet then
        DropCached(Sql)
      else
        mysql_stmt_close(Stmt);
      MaaLukkes := False;
      raise Feil;
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

    { Hver kolonne får et lite fast buffer, og bare det som ikke får plass
      hentes en gang til.

      Fristelsen er å binde med tomt buffer og la Lens fortelle lengden i
      første runde. Det virker for alt serveren sender som tekst — VARCHAR,
      TEXT, DECIMAL, og heltall — men **ikke for flyttall**: en DOUBLE kommer
      binært over prepared-protokollen, og uten et buffer å konvertere inn i
      setter klienten lengden til null. Resultatet ble tomme verdier for
      hver eneste flyttallskolonne, uten en feil noe sted.

      Med et buffer på 192 bytes får tall, datoer og korte strenger plass med
      én gang, og lengre tekst tas i andre runde der Lens nå er til å stole
      på fordi konverteringen faktisk har skjedd. }
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
      { MYSQL_DATA_TRUNCATED er forventet her — bufferne er med vilje tomme. }
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
          { Verdien ligger allerede i det faste bufferet, men det gjenbrukes
            av neste rad — derfor kopi inn i arenaen, ikke en peker til det. }
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
        { Tilbake til det faste bufferet, ellers skriver neste rad over
          verdien som nettopp ble lagt i arenaen. }
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
      { Resultatet må frigjøres på serveren før statementet kan brukes igjen.
        Uten dette gir neste execute «commands out of sync». }
      mysql_stmt_free_result(Stmt);
    end;
  finally
    { Et statement som ikke havnet i cachen eies av dette kallet. Uten denne
      lukkingen lekker CacheLimit := 0 ett statement per spørring — både i
      klienten og på serveren. }
    if MaaLukkes then
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
  { MySQL har ikke RETURNING. LAST_INSERT_ID leses fra forbindelsen etterpå,
    og gjelder den siste INSERT-en på nettopp denne forbindelsen — derfor er
    det trygt selv med en pool, så lenge ingen deler en forbindelse. }
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
  { Layouten er verifisert med offsetof mot libmariadbs header. Endrer noen
    recorden, skal det smelle her og ikke i en tilfeldig kolonne. }
  Assert(SizeOf(TMysqlBind) = 112, 'TMysqlBind must be 112 bytes');
  RegisterDbDriver('mysql', MakeMySql);
  RegisterDbDriver('mariadb', MakeMySql);

finalization
  if GLib <> NilHandle then
    UnloadLibrary(GLib);
  GLock.Free;

end.
