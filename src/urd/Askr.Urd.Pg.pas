{ Askr.Urd.Pg — Postgres bak TDbConnection, over libpq.

  To valg som følger av PRD-ens prinsipper og ikke er frie å endre senere:

  Biblioteket lastes med dlopen ved første bruk, ikke på byggetid. Da starter
  binæren på en maskin uten Postgres installert — og det må den, ellers kan
  ikke desktop-varianten med bare SQLite eksistere, og «kopier én binærfil til
  serveren» blir en løgn. Prisen er at en manglende libpq oppdages ved første
  spørring, så feilmeldingen sier hva den lette etter.

  Resultatet kopieres inn i arenaen, og PGresult frigjøres før Exec
  returnerer. Alternativet var å utsette PQclear til Arena.Reset via Defer,
  men da ville radene pekt inn i minne libpq eier, og hver regel om levetid
  måtte forklares to ganger. Én memcpy per resultatsett er billig ved siden av
  nettverket.

  Forbindelsen er ikke et arena-objekt. Den lever på heapen på tvers av
  requests, slik PRD-ens første regel krever.

  ExecParams går over prepared statements med en cache per forbindelse.
  Statementene er navngitt askr_N og forberedes med PQprepare — altså på
  protokollnivå, ikke med SQL-setningen PREPARE. Forskjellen betyr noe:
  protokollnivåets statements hører til sesjonen og overlever rollback. }
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
    FCache: TStringList;     { sql -> løpenummer i Objects }
    FCacheLimit: Integer;
    FStmtSeq: Integer;
    FPrepared: Int64;
    FCacheHits: Int64;
    function Materialize(A: TArena; Res: Pointer): TDbResult;
    procedure RaiseFor(Res: Pointer; const Sql: string);
    function Run(A: TArena; const Sql: string;
      const Params: array of TDbParam): TDbResult;
    procedure Simple(const Sql: string);
    { Navnet på det forberedte statementet for denne spørringen, forberedt
      om nødvendig. Tom streng når cachen er slått av, og da går spørringen
      over PQexecParams som før. }
    function PreparedName(const Sql: string): string;
    procedure DropCached(const Sql: string);
    function BuildParams(A: TArena; const Params: array of TDbParam): PPAnsiChar;
  public
    { Dsn er en libpq-conninfo eller URI:
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

    { PostgreSQL 17.2 gir 170002. }
    function ServerVersion: Integer;

    { DEALLOCATE ALL og tøm cachen. }
    procedure FlushStatementCache;

    property Dsn: string read FDsn;
    { Hvor mange statements som er forberedt mot serveren, og hvor mange kall
      som slapp unna med et cachet. }
    property PreparedCount: Int64 read FPrepared;
    property CacheHits: Int64 read FCacheHits;
    { 0 slår cachen av, og da går hver spørring over PQexecParams som før.
      Standard er 64. }
    property CacheLimit: Integer read FCacheLimit write FCacheLimit;
  end;

type
  { Kalles for hver NOTICE og WARNING serveren sender. Er ingen satt,
    forkastes de. }
  TPgNoticeHandler = procedure(const Message_: string);

{ Uten dette skriver libpq sin standardbehandler rett til stderr, midt i
  det programmet selv holder på å skrive ut. }
procedure SetPgNoticeHandler(Handler: TPgNoticeHandler);

{ True når libpq lot seg laste. Kaster ikke. }
function PgAvailable: Boolean;
{ Navnet på biblioteket som faktisk ble lastet, til diagnostikk. }
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
  { Homebrews libpq er keg-only og ligger ikke i standard søkesti. }
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
        '. Installer Postgres-klientbiblioteket, eller sett stien i ' +
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
  { Ingen DEALLOCATE: forbindelsen lukkes, og da forsvinner sesjonens
    forberedte statements av seg selv. }
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
          { PQgetlength er antall bytes, ikke tegn — riktig for UTF-8. }
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

{ SQLSTATE fra et resultat, uten å frigjøre det. }
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
  { DEALLOCATE ALL feiler i en avbrutt transaksjon. Da er det ikke noe å
    gjøre uansett — navnene gjenbrukes aldri, så et statement vi mistet
    oversikten over kan ikke kollidere med et nytt. }
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
  { NParams = 0 lar serveren utlede parametertypene fra spørringen, akkurat
    som PQexecParams med nil i ParamTypes gjør. }
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

{ Peker- og strengtabellen til libpq. Lever bare under kallet, så kalleren
  spoler arenaen tilbake etterpå. }
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
    { libpq leser tekstparametre som nullterminerte C-strenger, så TStr
      må få en kopi med terminator. }
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
  Navn: string;
begin
  N := Length(Params);
  if N = 0 then
    Res := PQexec(FConn, PAnsiChar(AnsiString(Sql)))
  else
  begin
    { Parametrene allokeres FØR merket. Ligger de etter, skriver de neste
      allokeringene over verdiene mens libpq leser dem. }
    Mark := A.Mark;
    try
      Values := BuildParams(A, Params);
      Navn := PreparedName(Sql);
      if Navn = '' then
        Res := PQexecParams(FConn, PAnsiChar(AnsiString(Sql)), N,
          nil, Values, nil, nil, 0)
      else
      begin
        Res := PQexecPrepared(FConn, PAnsiChar(AnsiString(Navn)), N,
          Values, nil, nil, 0);
        { SQL-setningen PREPARE er transaksjonell, men **PQprepare er ikke
          det**: den sender en Parse-melding i den utvidede protokollen, og
          slike statements hører til sesjonen. De overlever rollback, så
          cachen trenger ikke vite om transaksjoner i det hele tatt.

          Utdatert kan den likevel bli — noe annet i appen kan ha kjørt
          DEALLOCATE ALL, eller forbindelsen kan ha blitt tilbakestilt. Da
          svarer serveren 26000, invalid_sql_statement_name. Det er ikke noe
          å melde feil om: statementet kastes ut, forberedes på nytt og
          kjøres én gang til. }
        if (Res <> nil) and (PQresultStatus(Res) = PgresFatalError) and
           (ResultState(Res) = '26000') then
        begin
          PQclear(Res);
          DropCached(Sql);
          Navn := PreparedName(Sql);
          Res := PQexecPrepared(FConn, PAnsiChar(AnsiString(Navn)), N,
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
    { Et cachet statement kan være forberedt mot en tabell som siden er
      endret. Det kastes ut, slik at neste forsøk forbereder på nytt i
      stedet for å feile om igjen. DEALLOCATE gjøres ikke her: er vi i en
      avbrutt transaksjon, ville den feilet også. Navnene gjenbrukes aldri,
      så et glemt statement kan ikke kollidere med et nytt. }
    if N > 0 then
      DropCached(Sql);
    RaiseFor(Res, Sql);
  end;
  try
    Result := Materialize(A, Res);
  finally
    { Alt er kopiert; libpq eier ingenting av det kalleren får. }
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
  { Egen arena: en transaksjonsgrense skal ikke ligge i requestens. }
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
