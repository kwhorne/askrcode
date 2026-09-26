{ Askr.Session.Db — sessions in the app's database.

  The memory store is right for one process, and wrong the moment there
  are two: a login on one node is a stranger on the other, and a restart
  signs everybody out. This backend keeps the sessions in the database the
  app already has, so any node can answer any request and a deploy keeps
  people signed in. No Redis, for the same reason the durable queue has
  none.

  Four things worth knowing:

    * **The id is not stored, its SHA-256 is.** The id is the only thing
      that proves who a request is. A table of them is a table of logins —
      one backup, one read replica or one SQL injection away from
      somebody else's hands. The hash still finds the row, and nothing in
      it can be sent back as a cookie.
    * **The table is made on first use, not at startup.** An app has to
      start whether or not the database is up, and a DDL on boot would
      make that untrue. The check introspects first, as the queue does:
      `CREATE INDEX IF NOT EXISTS` does not exist in MySQL.
    * **The request's own connection is used when there is one.** A
      store that took a second connection from the same pool would
      deadlock the moment every worker held one and wanted another. Built
      with `Create(Dsn)` it has a pool of its own and never touches the
      request's.
    * **Expiry is unix milliseconds**, as in the queue: several nodes
      share the table, and an integer means the same thing whatever time
      zone each of them believes it is in. }
unit Askr.Session.Db;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, SyncObjs,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Json, Askr.Core.Crypto,
  Askr.Urd.Driver, Askr.Urd.Pool, Askr.Urd.Model,
  Askr.Norn.Schema, Askr.Norn.Introspect,
  Askr.Session;

const
  DefaultSessionsTable = 'askr_sessions';

type
  TDbSessions = class(TSessionBackend)
  private
    FPool: TDbPool;
    FOwnsPool: Boolean;
    FShareRequest: Boolean;
    FTable: string;
    FReady: Boolean;
    FLock: TCriticalSection;
    function Borrow(out Borrowed: Boolean): TDbConnection;
    procedure GiveBack(C: TDbConnection; Borrowed: Boolean);
    procedure Prepare(C: TDbConnection);
  public
    { Its own pool against the DSN. The request's connection is never
      used, because it may be to another database. }
    constructor Create(const Dsn: string; AMaxConnections: Integer = 4); overload;
    { The pool the app leases its request connections from. When the
      request holds one, that one is used; outside a request — a console
      command, a test — one is taken from the pool. }
    constructor Create(APool: TDbPool; AOwnsPool: Boolean = False); overload;
    destructor Destroy; override;

    function Load(const Id: string; NowMs: Int64;
      out Data, Flash: TSessionPairs): Boolean; override;
    procedure Save(const Id: string; const Data, Flash: TSessionPairs;
      ExpiresAtMs: Int64); override;
    procedure Delete(const Id: string); override;
    function Count(NowMs: Int64): Integer; override;
    function Sweep(NowMs: Int64): Integer; override;

    { Set it before the first request; the table is made under this
      name. }
    property Table: string read FTable write FTable;
  end;

{ The store askr.toml asks for, under [session]:

      driver = "memory"      # or "database"
      lifetime = 7200        # seconds

  or SESSION_DRIVER and SESSION_LIFETIME in the environment. "database"
  keeps them in Pool, which is the app's; without one it raises rather
  than quietly falling back to memory, because that fallback would look
  like working until the second node. An unknown driver raises for the
  same reason. }
function SessionsFromConfig(Pool: TDbPool): TSessionStore;

implementation

uses
  Askr.Core.Config;

{ --------------------------------------------------------------- setup -- }

constructor TDbSessions.Create(const Dsn: string; AMaxConnections: Integer);
begin
  Create(TDbPool.Create(Dsn, AMaxConnections), True);
  FShareRequest := False;
end;

constructor TDbSessions.Create(APool: TDbPool; AOwnsPool: Boolean);
begin
  inherited Create;
  if APool = nil then
    raise ESessionError.Create('A database session store needs a pool.');
  FPool := APool;
  FOwnsPool := AOwnsPool;
  FShareRequest := True;
  FTable := DefaultSessionsTable;
  FLock := TCriticalSection.Create;
end;

destructor TDbSessions.Destroy;
begin
  FLock.Free;
  if FOwnsPool then
    FPool.Free;
  inherited Destroy;
end;

function TDbSessions.Borrow(out Borrowed: Boolean): TDbConnection;
begin
  Borrowed := False;
  if FShareRequest and (CurrentDb <> nil) then
    Result := CurrentDb
  else
  begin
    Result := FPool.Acquire;
    Borrowed := True;
  end;
  try
    Prepare(Result);
  except
    GiveBack(Result, Borrowed);
    raise;
  end;
end;

procedure TDbSessions.GiveBack(C: TDbConnection; Borrowed: Boolean);
begin
  if Borrowed then
    FPool.Release(C);
end;

{ Makes the table the first time it is needed. Under a lock, so two
  requests arriving together do not both try. }
procedure TDbSessions.Prepare(C: TDbConnection);
var
  A: TArena;
  Schema_: TDbSchema;
  Exists_: Boolean;
  S: TSchemaBuilder;
  T: TTableBuilder;
  Statements: TStringArray;
  I: Integer;
begin
  if FReady then
    Exit;
  FLock.Acquire;
  try
    if FReady then
      Exit;
    Schema_ := IntrospectSchema(C);
    try
      Exists_ := Schema_.Table(FTable) <> nil;
    finally
      Schema_.Free;
    end;
    if not Exists_ then
    begin
      S := TSchemaBuilder.Create(C.Dialect);
      try
        T := S.Create(FTable);
        T.IfNotExists := True;
        T.Id;
        T.Text('id_hash', 64).Unique;
        T.Text('payload');
        T.BigInt('expires_at');
        { The sweep deletes on expires_at. Without the index every sweep
          reads the whole table. }
        T.Index(['expires_at']);
        Statements := S.ToSql;
      finally
        S.Free;
      end;
      A := TArena.Create(8 * 1024);
      try
        for I := 0 to High(Statements) do
          C.Exec(A, Statements[I]);
      finally
        A.Free;
      end;
    end;
    FReady := True;
  finally
    FLock.Release;
  end;
end;

{ ------------------------------------------------------------- helpers -- }

function Ph(C: TDbConnection; A: TArena; Index: Integer): string;
var
  B: TStrBuilder;
begin
  B.Init(A, 8);
  C.AppendPlaceholder(B, Index);
  Result := B.ToString;
end;

function Quoted(C: TDbConnection; A: TArena; const Name_: string): string;
var
  B: TStrBuilder;
begin
  B.Init(A, Length(Name_) + 4);
  C.AppendIdentStr(B, Name_);
  Result := B.ToString;
end;

{ The key the row is found by. See the unit header for why it is not the
  id itself. }
function IdHash(const Id: string): string;
begin
  Result := Sha256Hex(Id);
end;

function EncodePayload(A: TArena; const Data, Flash: TSessionPairs): string;
var
  W: TJsonWriter;
  I: Integer;
begin
  W.Init(A, 256);
  W.BeginObject;
  W.Key('data');
  W.BeginObject;
  for I := 0 to High(Data) do
    W.Field(Data[I].Key, Data[I].Value);
  W.EndObject;
  W.Key('flash');
  W.BeginObject;
  for I := 0 to High(Flash) do
    W.Field(Flash[I].Key, Flash[I].Value);
  W.EndObject;
  W.EndObject;
  Result := W.ToString;
end;

function PairsOf(V: PJsonValue): TSessionPairs;
var
  E: PJsonValue;
  N: Integer;
begin
  Result := nil;
  if (V = nil) or (V^.Kind <> jkObject) then
    Exit;
  SetLength(Result, V^.Count);
  N := 0;
  E := V^.First;
  while (E <> nil) and (N < Length(Result)) do
  begin
    Result[N].Key := E^.Key.ToString;
    Result[N].Value := JsonAsString(E);
    Inc(N);
    E := E^.Next;
  end;
  SetLength(Result, N);
end;

{ ---------------------------------------------------------- operations -- }

function TDbSessions.Load(const Id: string; NowMs: Int64;
  out Data, Flash: TSessionPairs): Boolean;
var
  A: TArena;
  C: TDbConnection;
  Borrowed: Boolean;
  R: TDbResult;
  Payload: string;
  Root: PJsonValue;
  ErrorAt: SizeInt;
begin
  Data := nil;
  Flash := nil;
  Result := False;
  A := TArena.Create(8 * 1024);
  try
    C := Borrow(Borrowed);
    try
      R := C.ExecParams(A, 'SELECT payload FROM ' + Quoted(C, A, FTable) +
        ' WHERE id_hash = ' + Ph(C, A, 1) + ' AND expires_at > ' +
        Ph(C, A, 2), [DbParam(A, IdHash(Id)), DbParam(A, NowMs)]);
      if (R = nil) or R.IsEmpty then
        Exit(False);
      Payload := R.Value(0, 0).ToString;
    finally
      GiveBack(C, Borrowed);
    end;

    { A row we cannot read is a session that starts over, not a request
      that fails. It can only get that way by someone editing the table,
      and a 500 on every page for that one visitor helps nobody. }
    if not JsonParse(A, Str(Payload), Root, ErrorAt) then
      Exit(False);
    Data := PairsOf(JsonMember(Root, 'data'));
    Flash := PairsOf(JsonMember(Root, 'flash'));
    Result := True;
  finally
    A.Free;
  end;
end;

procedure TDbSessions.Save(const Id: string;
  const Data, Flash: TSessionPairs; ExpiresAtMs: Int64);
var
  A: TArena;
  C: TDbConnection;
  Borrowed: Boolean;
  R: TDbResult;
  Payload, Hash, Update_: string;
  Params: array of TDbParam;
begin
  A := TArena.Create(16 * 1024);
  try
    Payload := EncodePayload(A, Data, Flash);
    Hash := IdHash(Id);
    C := Borrow(Borrowed);
    try
      { UPDATE first, INSERT if nothing was there. Not an upsert: the
        three dialects spell it three ways, and the one statement that
        works everywhere is the pair. }
      Update_ := 'UPDATE ' + Quoted(C, A, FTable) + ' SET payload = ' +
        Ph(C, A, 1) + ', expires_at = ' + Ph(C, A, 2) +
        ' WHERE id_hash = ' + Ph(C, A, 3);
      SetLength(Params, 3);
      Params[0] := DbParam(A, Payload);
      Params[1] := DbParam(A, ExpiresAtMs);
      Params[2] := DbParam(A, Hash);
      R := C.ExecParams(A, Update_, Params);
      if (R <> nil) and (R.AffectedRows > 0) then
        Exit;
      try
        C.ExecParams(A, 'INSERT INTO ' + Quoted(C, A, FTable) +
          ' (id_hash, payload, expires_at) VALUES (' + Ph(C, A, 1) + ', ' +
          Ph(C, A, 2) + ', ' + Ph(C, A, 3) + ')',
          [DbParam(A, Hash), DbParam(A, Payload), DbParam(A, ExpiresAtMs)]);
      except
        { Two requests from the same browser, both with a new session,
          both found nothing to update. The second insert loses on the
          unique index; its data is written over the first instead. }
        on E: EDbError do
          if E.IsUniqueViolation and not C.InTransaction then
            C.ExecParams(A, Update_, Params)
          else
            raise;
      end;
    finally
      GiveBack(C, Borrowed);
    end;
  finally
    A.Free;
  end;
end;

procedure TDbSessions.Delete(const Id: string);
var
  A: TArena;
  C: TDbConnection;
  Borrowed: Boolean;
begin
  A := TArena.Create(4 * 1024);
  try
    C := Borrow(Borrowed);
    try
      C.ExecParams(A, 'DELETE FROM ' + Quoted(C, A, FTable) +
        ' WHERE id_hash = ' + Ph(C, A, 1), [DbParam(A, IdHash(Id))]);
    finally
      GiveBack(C, Borrowed);
    end;
  finally
    A.Free;
  end;
end;

function TDbSessions.Count(NowMs: Int64): Integer;
var
  A: TArena;
  C: TDbConnection;
  Borrowed: Boolean;
  R: TDbResult;
begin
  Result := 0;
  A := TArena.Create(4 * 1024);
  try
    C := Borrow(Borrowed);
    try
      R := C.ExecParams(A, 'SELECT count(*) FROM ' + Quoted(C, A, FTable) +
        ' WHERE expires_at > ' + Ph(C, A, 1), [DbParam(A, NowMs)]);
      if (R <> nil) and not R.IsEmpty then
        Result := Integer(R.AsInt64(0, 0));
    finally
      GiveBack(C, Borrowed);
    end;
  finally
    A.Free;
  end;
end;

function TDbSessions.Sweep(NowMs: Int64): Integer;
var
  A: TArena;
  C: TDbConnection;
  Borrowed: Boolean;
  R: TDbResult;
begin
  Result := 0;
  A := TArena.Create(4 * 1024);
  try
    C := Borrow(Borrowed);
    try
      R := C.ExecParams(A, 'DELETE FROM ' + Quoted(C, A, FTable) +
        ' WHERE expires_at <= ' + Ph(C, A, 1), [DbParam(A, NowMs)]);
      if R <> nil then
        Result := Integer(R.AffectedRows);
    finally
      GiveBack(C, Borrowed);
    end;
  finally
    A.Free;
  end;
end;

{ -------------------------------------------------------------- config -- }

function SessionsFromConfig(Pool: TDbPool): TSessionStore;
var
  Driver: string;
  Lifetime: Int64;
begin
  Driver := LowerCase(Trim(Cfg('session.driver', 'memory')));
  Lifetime := CfgInt('session.lifetime', 7200);
  if Lifetime <= 0 then
    raise ESessionError.CreateFmt(
      'session.lifetime must be a number of seconds above zero, not %d.',
      [Lifetime]);
  if Driver = 'memory' then
    Result := TSessionStore.Create(Integer(Lifetime))
  else if Driver = 'database' then
  begin
    if Pool = nil then
      raise ESessionError.Create(
        'session.driver is "database", but the app has no database. ' +
        'Set DATABASE_URL, or set session.driver to "memory".');
    Result := TSessionStore.Create(TDbSessions.Create(Pool),
      Integer(Lifetime));
  end
  else
    raise ESessionError.CreateFmt(
      'Unknown session.driver "%s". It is "memory" or "database".',
      [Driver]);
end;

end.
