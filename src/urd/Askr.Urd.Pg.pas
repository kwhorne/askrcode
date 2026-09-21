{ Askr.Urd.Pg — Postgres behind TDbConnection, over libpq.

  Two choices that follow from the PRD's principles and are not free to
  change later:

  The library is loaded with dlopen at first use, not at build time. Then
  the binary starts on a machine with no Postgres installed — and it has
  to, or the desktop variant with only SQLite cannot exist, and "copy one
  binary to the server" becomes a lie. The price is that a missing libpq
  is discovered at the first query, so the error message says what it
  looked for.

  The result is copied into the arena, and the PGresult is freed before
  Exec returns. The alternative was deferring PQclear to Arena.Reset via
  Defer, but then the rows would point into memory libpq owns, and every
  rule about lifetime would have to be explained twice. One memcpy per
  result set is cheap beside the network.

  The connection is not an arena object. It lives on the heap across
  requests, as the PRD's first rule requires.

  ExecParams goes through prepared statements with a cache per connection.
  The statements are named askr_N and prepared with PQprepare — that is,
  at the protocol level, not with the SQL statement PREPARE. The
  difference matters: protocol-level statements belong to the session and
  survive a rollback. }
unit Askr.Urd.Pg;

{$mode Delphi}{$H+}
{$POINTERMATH ON}

interface

uses
  SysUtils, Classes, DynLibs, Askr.Core.Arena, Askr.Core.Text,
  Askr.Urd.Driver;

type
  TPgConnection = class(TDbConnection)
  private
    FConn: Pointer;
    FDsn: string;
    FCache: TStringList;     { sql -> sequence number in Objects }
    FCacheLimit: Integer;
    FStmtSeq: Integer;
    FPrepared: Int64;
    FCacheHits: Int64;
    function Materialize(A: TArena; Res: Pointer): TDbResult;
    procedure RaiseFor(Res: Pointer; const Sql: string);
    function Run(A: TArena; const Sql: string;
      const Params: array of TDbParam): TDbResult;
    procedure Simple(const Sql: string);
    { The name of the prepared statement for this query, prepared if
      necessary. An empty string when the cache is off, and then the query
      goes over PQexecParams as before. }
    function PreparedName(const Sql: string): string;
    procedure DropCached(const Sql: string);
    function BuildParams(A: TArena; const Params: array of TDbParam): PPAnsiChar;
  public
    { Dsn is a libpq conninfo string or a URI:
      'postgresql://askr:askr@127.0.0.1:5433/askr_dev'
      'host=127.0.0.1 port=5433 dbname=askr_dev user=askr' }
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
    procedure AppendPlaceholder(var B: TStrBuilder; Index: Integer); override;

    { PostgreSQL 17.2 gives 170002. }
    function ServerVersion: Integer;

    { DEALLOCATE ALL and empty the cache. }
    procedure FlushStatementCache;

    property Dsn: string read FDsn;
    { How many statements are prepared against the server, and how many
      calls got away with a cached one. }
    property PreparedCount: Int64 read FPrepared;
    property CacheHits: Int64 read FCacheHits;
    { 0 turns the cache off, and then every query goes over PQexecParams as
      before. The default is 64. }
    property CacheLimit: Integer read FCacheLimit write FCacheLimit;
  end;

type
  { Called for every NOTICE and WARNING the server sends. With none set
    they are discarded. }
  TPgNoticeHandler = procedure(const Message_: string);

{ Without this, libpq's default handler writes straight to stderr, in
  the middle of whatever the program is printing. }
procedure SetPgNoticeHandler(Handler: TPgNoticeHandler);

{ True when libpq could be loaded. Does not raise. }
function PgAvailable: Boolean;
{ The name of the library that was actually loaded, for diagnostics. }
function PgLibraryName: string;

implementation

uses
  SyncObjs;

const
  ConnectionOk = 0;

  PgresEmptyQuery = 0;
  PgresCommandOk  = 1;
  PgresTuplesOk   = 2;
  PgresFatalError = 7;

  DiagSqlState = Ord('C');

type
  TPQconnectdb = function(ConnInfo: PAnsiChar): Pointer; cdecl;
  TPQstatus = function(Conn: Pointer): Integer; cdecl;
  TPQerrorMessage = function(Conn: Pointer): PAnsiChar; cdecl;
  TPQfinish = procedure(Conn: Pointer); cdecl;
  TPQserverVersion = function(Conn: Pointer): Integer; cdecl;
  TPQexec = function(Conn: Pointer; Query: PAnsiChar): Pointer; cdecl;
  TPQexecParams = function(Conn: Pointer; Command: PAnsiChar; NParams: Integer;
    ParamTypes: PCardinal; ParamValues: PPAnsiChar; ParamLengths: PInteger;
    ParamFormats: PInteger; ResultFormat: Integer): Pointer; cdecl;
  TPQprepare = function(Conn: Pointer; StmtName, Query: PAnsiChar;
    NParams: Integer; ParamTypes: Pointer): Pointer; cdecl;
  TPQexecPrepared = function(Conn: Pointer; StmtName: PAnsiChar;
    NParams: Integer; ParamValues: PPAnsiChar;
    ParamLengths, ParamFormats: Pointer; ResultFormat: Integer): Pointer; cdecl;
  TPQresultStatus = function(Res: Pointer): Integer; cdecl;
  TPQresultErrorMessage = function(Res: Pointer): PAnsiChar; cdecl;
  TPQresultErrorField = function(Res: Pointer; FieldCode: Integer): PAnsiChar; cdecl;
  TPQntuples = function(Res: Pointer): Integer; cdecl;
  TPQnfields = function(Res: Pointer): Integer; cdecl;
  TPQfname = function(Res: Pointer; Col: Integer): PAnsiChar; cdecl;
  TPQgetvalue = function(Res: Pointer; Row, Col: Integer): PAnsiChar; cdecl;
  TPQgetlength = function(Res: Pointer; Row, Col: Integer): Integer; cdecl;
  TPQgetisnull = function(Res: Pointer; Row, Col: Integer): Integer; cdecl;
  TPQcmdTuples = function(Res: Pointer): PAnsiChar; cdecl;
  TPQclear = procedure(Res: Pointer); cdecl;
  TPQnoticeProcessor = procedure(Arg: Pointer; Msg: PAnsiChar); cdecl;
  TPQsetNoticeProcessor = function(Conn: Pointer; Proc: TPQnoticeProcessor;
    Arg: Pointer): TPQnoticeProcessor; cdecl;

var
  PQconnectdb: TPQconnectdb;
  PQstatus: TPQstatus;
  PQerrorMessage: TPQerrorMessage;
  PQfinish: TPQfinish;
  PQserverVersion: TPQserverVersion;
  PQexec: TPQexec;
  PQexecParams: TPQexecParams;
  PQprepare: TPQprepare;
  PQexecPrepared: TPQexecPrepared;
  PQresultStatus: TPQresultStatus;
  PQresultErrorMessage: TPQresultErrorMessage;
  PQresultErrorField: TPQresultErrorField;
  PQntuples: TPQntuples;
  PQnfields: TPQnfields;
  PQfname: TPQfname;
  PQgetvalue: TPQgetvalue;
  PQgetlength: TPQgetlength;
  PQgetisnull: TPQgetisnull;
  PQcmdTuples: TPQcmdTuples;
  PQclear: TPQclear;
  PQsetNoticeProcessor: TPQsetNoticeProcessor;
  GNoticeHandler: TPgNoticeHandler = nil;

  GLibHandle: TLibHandle = NilHandle;
  GLibName: string = '';
  GLoadTried: Boolean = False;
  GLoadError: string = '';
  GLoadLock: TCriticalSection;

function LibraryCandidates: TStringArray;
begin
{$IFDEF DARWIN}
  { Homebrew's libpq is keg-only and is not on the default search
    path. }
  Result := [
    'libpq.5.dylib',
    'libpq.dylib',
    '/opt/homebrew/opt/libpq/lib/libpq.5.dylib',
    '/usr/local/opt/libpq/lib/libpq.5.dylib',
    '/Applications/Postgres.app/Contents/Versions/latest/lib/libpq.5.dylib'
  ];
{$ELSE}
{$IFDEF WINDOWS}
  Result := ['libpq.dll'];
{$ELSE}
  Result := ['libpq.so.5', 'libpq.so'];
{$ENDIF}
{$ENDIF}
end;

function Resolve(const AName: string): Pointer;
begin
  Result := GetProcedureAddress(GLibHandle, AName);
  if Result = nil then
    raise EDbUnavailable.CreateFmt(
      'libpq was loaded from %s but is missing %s', [GLibName, AName]);
end;

procedure BindAll;
begin
  PQconnectdb := TPQconnectdb(Resolve('PQconnectdb'));
  PQstatus := TPQstatus(Resolve('PQstatus'));
  PQerrorMessage := TPQerrorMessage(Resolve('PQerrorMessage'));
  PQfinish := TPQfinish(Resolve('PQfinish'));
  PQserverVersion := TPQserverVersion(Resolve('PQserverVersion'));
  PQexec := TPQexec(Resolve('PQexec'));
  PQexecParams := TPQexecParams(Resolve('PQexecParams'));
  PQprepare := TPQprepare(Resolve('PQprepare'));
  PQexecPrepared := TPQexecPrepared(Resolve('PQexecPrepared'));
  PQresultStatus := TPQresultStatus(Resolve('PQresultStatus'));
  PQresultErrorMessage := TPQresultErrorMessage(Resolve('PQresultErrorMessage'));
  PQresultErrorField := TPQresultErrorField(Resolve('PQresultErrorField'));
  PQntuples := TPQntuples(Resolve('PQntuples'));
  PQnfields := TPQnfields(Resolve('PQnfields'));
  PQfname := TPQfname(Resolve('PQfname'));
  PQgetvalue := TPQgetvalue(Resolve('PQgetvalue'));
  PQgetlength := TPQgetlength(Resolve('PQgetlength'));
  PQgetisnull := TPQgetisnull(Resolve('PQgetisnull'));
  PQcmdTuples := TPQcmdTuples(Resolve('PQcmdTuples'));
  PQclear := TPQclear(Resolve('PQclear'));
  PQsetNoticeProcessor := TPQsetNoticeProcessor(Resolve('PQsetNoticeProcessor'));
end;

procedure SetPgNoticeHandler(Handler: TPgNoticeHandler);
begin
  GNoticeHandler := Handler;
end;

procedure NoticeProcessor(Arg: Pointer; Msg: PAnsiChar); cdecl;
begin
  if Assigned(GNoticeHandler) then
    GNoticeHandler(Trim(string(Msg)));
end;

procedure EnsureLoaded;
var
  Candidates: TStringArray;
  I: Integer;
  Tried: string;
begin
  if GLibHandle <> NilHandle then
    Exit;

  GLoadLock.Acquire;
  try
    if GLibHandle <> NilHandle then
      Exit;
    if GLoadTried then
      raise EDbUnavailable.Create(GLoadError);

    GLoadTried := True;
    Candidates := LibraryCandidates;
    Tried := '';
    for I := 0 to High(Candidates) do
    begin
      GLibHandle := LoadLibrary(Candidates[I]);
      if GLibHandle <> NilHandle then
      begin
        GLibName := Candidates[I];
        Break;
      end;
      if Tried <> '' then
        Tried := Tried + ', ';
      Tried := Tried + Candidates[I];
    end;

    if GLibHandle = NilHandle then
    begin
      GLoadError := 'Could not find libpq. Tried: ' + Tried +
        '. Install the Postgres client library, or put its path in ' +
        'DYLD_LIBRARY_PATH / LD_LIBRARY_PATH.';
      raise EDbUnavailable.Create(GLoadError);
    end;

    try
      BindAll;
    except
      on E: Exception do
      begin
        UnloadLibrary(GLibHandle);
        GLibHandle := NilHandle;
        GLoadError := E.Message;
        raise;
      end;
    end;
  finally
    GLoadLock.Release;
  end;
end;

function PgAvailable: Boolean;
begin
  try
    EnsureLoaded;
    Result := True;
  except
    Result := False;
  end;
end;

function PgLibraryName: string;
begin
  Result := GLibName;
end;

{ TPgConnection }

constructor TPgConnection.Create(const ADsn: string);
var
  Msg: string;
begin
  inherited Create;
  EnsureLoaded;
  FDsn := ADsn;
  FCacheLimit := 64;
  FCache := TStringList.Create;
  FCache.Sorted := True;
  FCache.Duplicates := dupIgnore;
  FConn := PQconnectdb(PAnsiChar(AnsiString(ADsn)));
  if FConn = nil then
    raise EDbError.Create('libpq could not allocate a connection');
  if PQstatus(FConn) <> ConnectionOk then
  begin
    Msg := Trim(string(PQerrorMessage(FConn)));
    PQfinish(FConn);
    FConn := nil;
    raise EDbError.Create('Could not connect to Postgres: ' + Msg);
  end;
  PQsetNoticeProcessor(FConn, @NoticeProcessor, nil);
end;

destructor TPgConnection.Destroy;
begin
  { No DEALLOCATE: the connection is closing, and then the session's
    prepared statements go away by themselves. }
  FreeAndNil(FCache);
  if FConn <> nil then
  begin
    PQfinish(FConn);
    FConn := nil;
  end;
  inherited Destroy;
end;

function TPgConnection.Dialect: TSqlDialect;
begin
  Result := sdPostgres;
end;

function TPgConnection.IsAlive: Boolean;
begin
  Result := (FConn <> nil) and (PQstatus(FConn) = ConnectionOk);
end;

function TPgConnection.ServerVersion: Integer;
begin
  Result := PQserverVersion(FConn);
end;

procedure TPgConnection.AppendPlaceholder(var B: TStrBuilder; Index: Integer);
begin
  B.AppendByte(Ord('$'));
  B.AppendInt(Index);
end;

procedure TPgConnection.RaiseFor(Res: Pointer; const Sql: string);
var
  Msg, State: string;
  P: PAnsiChar;
begin
  Msg := Trim(string(PQresultErrorMessage(Res)));
  P := PQresultErrorField(Res, DiagSqlState);
  if P <> nil then
    State := string(P)
  else
    State := '';
  PQclear(Res);
  if Msg = '' then
    Msg := Trim(string(PQerrorMessage(FConn)));
  raise EDbError.Create(Msg + ' — i: ' + Sql, State);
end;

function TPgConnection.Materialize(A: TArena; Res: Pointer): TDbResult;
var
  R, C, Len: Integer;
  Prev: TArena;
  Cmd: string;
begin
  Prev := UseArena(A);
  try
    Result := TDbResult.Create;
    Result.Allocate(PQntuples(Res), PQnfields(Res));

    for C := 0 to Result.FieldCount - 1 do
      Result.SetFieldName(C, StrDup(A, string(PQfname(Res, C))));

    for R := 0 to Result.RowCount - 1 do
      for C := 0 to Result.FieldCount - 1 do
        if PQgetisnull(Res, R, C) <> 0 then
          Result.SetCell(R, C, StrEmpty, True)
        else
        begin
          { PQgetlength is a byte count, not characters — right for UTF-8. }
          Len := PQgetlength(Res, R, C);
          Result.SetCell(R, C,
            StrDup(A, StrRef(PByte(PQgetvalue(Res, R, C)), Len)), False);
        end;

    Cmd := Trim(string(PQcmdTuples(Res)));
    if Cmd <> '' then
      Result.SetAffected(StrToInt64Def(Cmd, -1));
  finally
    UseArena(Prev);
  end;
end;

{ The SQLSTATE from a result, without freeing it. }
function ResultState(Res: Pointer): string;
var
  P: PAnsiChar;
begin
  P := PQresultErrorField(Res, DiagSqlState);
  if P <> nil then
    Result := string(P)
  else
    Result := '';
end;

procedure TPgConnection.FlushStatementCache;
var
  Res: Pointer;
begin
  if FCache = nil then
    Exit;
  FCache.Clear;
  if FConn = nil then
    Exit;
  { DEALLOCATE ALL fails in an aborted transaction. There is nothing to
    be done about it anyway — the names are never reused, so a statement
    we lost track of cannot collide with a new one. }
  Res := PQexec(FConn, 'DEALLOCATE ALL');
  if Res <> nil then
    PQclear(Res);
end;

procedure TPgConnection.DropCached(const Sql: string);
var
  Idx: Integer;
begin
  Idx := FCache.IndexOf(Sql);
  if Idx >= 0 then
    FCache.Delete(Idx);
end;

function TPgConnection.PreparedName(const Sql: string): string;
var
  Idx: Integer;
  Res: Pointer;
begin
  if FCacheLimit <= 0 then
    Exit('');

  Idx := FCache.IndexOf(Sql);
  if Idx >= 0 then
  begin
    Inc(FCacheHits);
    Exit('askr_' + IntToStr(PtrInt(FCache.Objects[Idx])));
  end;

  if FCache.Count >= FCacheLimit then
    FlushStatementCache;

  Inc(FStmtSeq);
  Result := 'askr_' + IntToStr(FStmtSeq);
  { NParams = 0 lets the server infer the parameter types from the query,
    exactly as PQexecParams with nil in ParamTypes does. }
  Res := PQprepare(FConn, PAnsiChar(AnsiString(Result)),
    PAnsiChar(AnsiString(Sql)), 0, nil);
  if Res = nil then
    raise EDbError.Create('No response from Postgres during PREPARE: ' +
      Trim(string(PQerrorMessage(FConn))));
  if PQresultStatus(Res) <> PgresCommandOk then
    RaiseFor(Res, Sql);
  PQclear(Res);
  Inc(FPrepared);
  FCache.AddObject(Sql, TObject(PtrInt(FStmtSeq)));
end;

{ The pointer and string tables for libpq. They live only for the
  duration of the call, so the caller rewinds the arena afterwards. }
function TPgConnection.BuildParams(A: TArena;
  const Params: array of TDbParam): PPAnsiChar;
var
  I: Integer;
  Buf: PByte;
begin
  Result := PPAnsiChar(A.Alloc(PtrUInt(Length(Params)) * SizeOf(PAnsiChar)));
  for I := 0 to High(Params) do
  begin
    if Params[I].IsNull then
    begin
      Result[I] := nil;
      Continue;
    end;
    { libpq reads text parameters as null-terminated C strings, so a TStr
      has to get a copy with a terminator. }
    Buf := PByte(A.Alloc(PtrUInt(Params[I].Value.Len) + 1));
    if Params[I].Value.Len > 0 then
      Move(Params[I].Value.Data^, Buf^, Params[I].Value.Len);
    Buf[Params[I].Value.Len] := 0;
    Result[I] := PAnsiChar(Buf);
  end;
end;

function TPgConnection.Run(A: TArena; const Sql: string;
  const Params: array of TDbParam): TDbResult;
var
  N, Status: Integer;
  Values: PPAnsiChar;
  Res: Pointer;
  Mark: TArenaMark;
  Name_: string;
begin
  N := Length(Params);
  if N = 0 then
    Res := PQexec(FConn, PAnsiChar(AnsiString(Sql)))
  else
  begin
    { The parameters are allocated BEFORE the mark. If they sit after it,
      the next allocations overwrite the values while libpq is reading
      them. }
    Mark := A.Mark;
    try
      Values := BuildParams(A, Params);
      Name_ := PreparedName(Sql);
      if Name_ = '' then
        Res := PQexecParams(FConn, PAnsiChar(AnsiString(Sql)), N,
          nil, Values, nil, nil, 0)
      else
      begin
        Res := PQexecPrepared(FConn, PAnsiChar(AnsiString(Name_)), N,
          Values, nil, nil, 0);
        { The SQL statement PREPARE is transactional, but **PQprepare is
          not**: it sends a Parse message in the extended protocol, and
          such statements belong to the session. They survive a rollback,
          so the cache does not need to know about transactions at all.

          It can still go stale — something else in the app may have run
          DEALLOCATE ALL, or the connection may have been reset. Then the
          server answers 26000, invalid_sql_statement_name. That is
          nothing to report as an error: the statement is thrown out,
          prepared again and run once more. }
        if (Res <> nil) and (PQresultStatus(Res) = PgresFatalError) and
           (ResultState(Res) = '26000') then
        begin
          PQclear(Res);
          DropCached(Sql);
          Name_ := PreparedName(Sql);
          Res := PQexecPrepared(FConn, PAnsiChar(AnsiString(Name_)), N,
            Values, nil, nil, 0);
        end;
      end;
    finally
      A.Rewind(Mark);
    end;
  end;

  if Res = nil then
    raise EDbError.Create('No response from Postgres: ' +
      Trim(string(PQerrorMessage(FConn))));
  Status := PQresultStatus(Res);
  if (Status <> PgresTuplesOk) and (Status <> PgresCommandOk) and
     (Status <> PgresEmptyQuery) then
  begin
    { A cached statement may have been prepared against a table that has
      since changed. It is thrown out, so the next attempt prepares again
      rather than failing again. DEALLOCATE is not done here: in an
      aborted transaction it would fail too. The names are never reused,
      so a forgotten statement cannot collide with a new one. }
    if N > 0 then
      DropCached(Sql);
    RaiseFor(Res, Sql);
  end;
  try
    Result := Materialize(A, Res);
  finally
    { Everything has been copied; libpq owns nothing of what the caller
      gets. }
    PQclear(Res);
  end;
end;

function TPgConnection.Exec(A: TArena; const Sql: string): TDbResult;
begin
  Result := Run(A, Sql, []);
end;

function TPgConnection.ExecParams(A: TArena; const Sql: string;
  const Params: array of TDbParam): TDbResult;
begin
  Result := Run(A, Sql, Params);
end;

function TPgConnection.InsertGetId(A: TArena; const Sql: string;
  const Params: array of TDbParam; const IdColumn: string): Int64;
var
  B: TStrBuilder;
  R: TDbResult;
  Mark: TArenaMark;
  Full: string;
begin
  if IdColumn = '' then
  begin
    Run(A, Sql, Params);
    Exit(0);
  end;

  Mark := A.Mark;
  B.Init(A, Length(Sql) + 32);
  B.Append(Sql);
  B.Append(' RETURNING ');
  AppendIdentStr(B, IdColumn);
  Full := B.ToString;
  A.Rewind(Mark);

  R := Run(A, Full, Params);
  if R.IsEmpty then
    Exit(0);
  Result := R.AsInt64(0, 0);
end;

procedure TPgConnection.Simple(const Sql: string);
var
  A: TArena;
begin
  { Its own arena: a transaction boundary must not live in the
    request's. }
  A := TArena.Create(4096);
  try
    Run(A, Sql, []);
  finally
    A.Free;
  end;
end;

procedure TPgConnection.StartTransaction;
begin
  Simple('BEGIN');
  FInTransaction := True;
end;

procedure TPgConnection.Commit;
begin
  Simple('COMMIT');
  FInTransaction := False;
end;

procedure TPgConnection.Rollback;
begin
  Simple('ROLLBACK');
  FInTransaction := False;
end;

function MakePgConnection(const Dsn: string): TDbConnection;
begin
  Result := TPgConnection.Create(Dsn);
end;

initialization
  GLoadLock := TCriticalSection.Create;
  RegisterDbDriver('postgresql', MakePgConnection);
  RegisterDbDriver('postgres', MakePgConnection);
  RegisterDbDriver('pg', MakePgConnection);

finalization
  if GLibHandle <> NilHandle then
    UnloadLibrary(GLibHandle);
  GLoadLock.Free;

end.
