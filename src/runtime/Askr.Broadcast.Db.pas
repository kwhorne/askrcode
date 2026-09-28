{ Askr.Broadcast.Db -- a broadcast every process hears.

      SetBroadcasts(BroadcastsFromConfig(DbPool));    // BROADCAST_DRIVER=database

  Broadcast -- and PropsChanged, and every stream and websocket on a
  channel -- reaches the process that sent it and no further. Behind a load
  balancer with two processes, a page connected to one never hears what
  changed on the other. This writes each broadcast to a table in the app's
  database, and every process reads what the others wrote. No Redis, for
  the same reason the durable queue and the sessions have none.

  **The row's id is the event's id.** A browser that reconnects to another
  process sends Last-Event-ID, and that process replays from the same
  numbers, because every process delivered every event under the id the
  database gave it.

  **Sent here, delivered here at once.** The process that broadcasts does
  not wait for its own poll: it writes the row and delivers under the id it
  got back. The others hear it on their next poll, 100 ms apart unless
  set. A row this process wrote is skipped when its poll comes round.

  **An id can commit after a larger one.** Two inserts at once take 10 and
  11, and 11 can commit first. A poll that saw 11 and moved on would never
  see 10. So an id that was skipped is asked for again, by number, for a
  few seconds, and then given up -- a rollback leaves a hole that is never
  filled. SQLite has one writer, so the ids commit in order there.

  **In a transaction, it is the transaction's.** In a request, the row is
  written on the request's own connection, as the database sessions are:
  a second connection from the same pool would deadlock the moment every
  worker held one. If that transaction rolls back, the other processes
  never hear it; this process already did.

  **The table is made on first use**, not at startup, so an app starts with
  its database down. Rows are kept ten minutes, which is ample for a
  reconnect, and the process that writes sweeps the old ones now and then. }
unit Askr.Broadcast.Db;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Clock, Askr.Core.Crypto,
  Askr.Core.Supervisor,
  Askr.Urd.Driver, Askr.Urd.Pool, Askr.Urd.Model,
  Askr.Norn.Schema, Askr.Norn.Introspect,
  Askr.Http.Stream;

const
  DefaultBroadcastsTable = 'askr_broadcasts';

type
  EBroadcastError = class(Exception);

  { An id skipped by a poll, asked for again until Until_. }
  TBroadcastGap = record
    Id: Int64;
    Until_: Int64;
  end;

  TDbBroadcasts = class
  private
    FPool: TDbPool;
    FOwnsPool: Boolean;
    FShareRequest: Boolean;
    FTable: string;
    FOrigin: string;
    FReady: Boolean;
    FLock: TCriticalSection;
    FPollLock: TCriticalSection;
    FLast: Int64;
    FGaps: array of TBroadcastGap;
    FPollMs: Integer;
    FGapMs: Integer;
    FKeepMs: Int64;
    FRunning: LongInt;
    FThread: TThread;
    FSent: Int64;
    procedure Prepare(C: TDbConnection);
    function Relay(const Channel, Event, Data: string): Int64;
  public
    { Its own pool against the DSN: the request's connection is never used,
      because it may be to another database. }
    constructor Create(const Dsn: string; AMaxConnections: Integer = 2); overload;
    { The app's pool. A request's own connection is used when it has one. }
    constructor Create(APool: TDbPool; AOwnsPool: Boolean = False); overload;
    destructor Destroy; override;

    { Makes this the relay Broadcast writes through, and starts the thread
      that reads what the other processes wrote. }
    procedure Start;
    procedure Stop;

    { Writes one broadcast and returns its id. Broadcast calls it; so can a
      test. }
    function Send(const Channel, Event, Data: string): Int64;
    { One read of what the others wrote since the last: delivered, and
      counted. The thread calls it; so can a test. }
    function Poll: Integer;

    { Who this process is in the table. }
    property Origin: string read FOrigin;
    property PollIntervalMs: Integer read FPollMs write FPollMs;
    { How long a skipped id is asked for again. }
    property GapMs: Integer read FGapMs write FGapMs;
    property Table: string read FTable write FTable;
  end;

{ database: a TDbBroadcasts on the pool. memory, the default: nil, and each
  process broadcasts to itself. Anything else raises: a typo in production
  would otherwise look like broadcasting that works on one node. }
function BroadcastsFromConfig(Pool: TDbPool): TDbBroadcasts;

{ Starts B and keeps it; nil stops the one there is and goes back to one
  process. }
procedure SetBroadcasts(B: TDbBroadcasts);
function CurrentBroadcasts: TDbBroadcasts;

implementation

uses
  Askr.Core.Config;

type
  TPollThread = class(TSupervisedThread)
  private
    FOwner: TDbBroadcasts;
  protected
    procedure Run; override;
    function Wanted: Boolean; override;
  public
    constructor Create(AOwner: TDbBroadcasts);
  end;

var
  GBroadcasts: TDbBroadcasts = nil;

{ ------------------------------------------------------------ helpers -- }

function Ph(C: TDbConnection; A: TArena; Index: Integer): string;
var
  B: TStrBuilder;
begin
  B.Init(A, 8);
  C.AppendPlaceholder(B, Index);
  Result := B.ToString;
end;

{ --------------------------------------------------------------- setup -- }

constructor TDbBroadcasts.Create(const Dsn: string; AMaxConnections: Integer);
begin
  Create(TDbPool.Create(Dsn, AMaxConnections), True);
  FShareRequest := False;
end;

constructor TDbBroadcasts.Create(APool: TDbPool; AOwnsPool: Boolean);
begin
  inherited Create;
  if APool = nil then
    raise EBroadcastError.Create('Broadcasting through the database needs ' +
      'a pool, and there is none: is DATABASE_URL set?');
  FPool := APool;
  FOwnsPool := AOwnsPool;
  FShareRequest := True;
  FTable := DefaultBroadcastsTable;
  FOrigin := RandomHex(8);
  FLock := TCriticalSection.Create;
  FPollLock := TCriticalSection.Create;
  FLast := -1;
  FPollMs := 100;
  FGapMs := 5000;
  FKeepMs := 10 * 60 * 1000;
end;

destructor TDbBroadcasts.Destroy;
begin
  Stop;
  FPollLock.Free;
  FLock.Free;
  if FOwnsPool then
    FPool.Free;
  inherited Destroy;
end;

procedure TDbBroadcasts.Prepare(C: TDbConnection);
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
        T.Text('channel', 200);
        T.Text('kind', 200);
        T.Text('payload');
        T.Text('origin', 32);
        T.BigInt('sent_at');
        { The sweep deletes on it. }
        T.Index(['sent_at']);
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

{ ---------------------------------------------------------------- send -- }

function TDbBroadcasts.Send(const Channel, Event, Data: string): Int64;
var
  C: TDbConnection;
  Borrowed: Boolean;
  A: TArena;
  Now_: Int64;
begin
  if Pos(#0, Data) > 0 then
    raise EBroadcastError.Create('A broadcast cannot carry a NUL byte: the ' +
      'payload is stored as text.');
  Borrowed := not (FShareRequest and (CurrentDb <> nil));
  if Borrowed then
    C := FPool.Acquire
  else
    C := CurrentDb;
  A := TArena.Create(4 * 1024);
  try
    Prepare(C);
    Now_ := UnixNowMs;
    Result := C.InsertGetId(A,
      'INSERT INTO ' + FTable + ' (channel, kind, payload, origin, sent_at) VALUES (' +
      Ph(C, A, 1) + ', ' + Ph(C, A, 2) + ', ' + Ph(C, A, 3) + ', ' +
      Ph(C, A, 4) + ', ' + Ph(C, A, 5) + ')',
      [DbParam(A, Channel), DbParam(A, Event), DbParam(A, Data),
       DbParam(A, FOrigin), DbParam(A, Now_)], 'id');
    { The sweep, now and then: often enough that the table stays small,
      rarely enough that it costs nothing. }
    if InterLockedIncrement64(FSent) mod 64 = 0 then
      C.ExecParams(A, 'DELETE FROM ' + FTable + ' WHERE sent_at < ' + Ph(C, A, 1),
        [DbParam(A, Now_ - FKeepMs)]);
  finally
    A.Free;
    if Borrowed then
      FPool.Release(C);
  end;
end;

function TDbBroadcasts.Relay(const Channel, Event, Data: string): Int64;
begin
  Result := Send(Channel, Event, Data);
end;

{ ---------------------------------------------------------------- poll -- }

function TDbBroadcasts.Poll: Integer;
var
  C: TDbConnection;
  A: TArena;
  R: TDbResult;
  Sql, Gaps: string;
  I, J, K: Integer;
  Id, Now_: Int64;
  Found: Boolean;
begin
  Result := 0;
  FPollLock.Acquire;
  try
    C := FPool.Acquire;
    A := TArena.Create(64 * 1024);
    try
      Prepare(C);
      Now_ := UnixNowMs;
      { A process that has just started hears from now on: the table's
        history is for reconnecting streams, and those replay from the
        history of the process they reach. }
      if FLast < 0 then
      begin
        R := C.Exec(A, 'SELECT MAX(id) FROM ' + FTable);
        FLast := R.AsInt64(0, 0, 0);
        Exit;
      end;

      { The ids skipped earlier, asked for by number. They are integers
        this process wrote down, so they go into the SQL as they are. }
      Gaps := '';
      for I := 0 to High(FGaps) do
      begin
        if Gaps <> '' then
          Gaps := Gaps + ',';
        Gaps := Gaps + IntToStr(FGaps[I].Id);
      end;
      Sql := 'SELECT id, channel, kind, payload, origin FROM ' + FTable +
        ' WHERE id > ' + Ph(C, A, 1);
      if Gaps <> '' then
        Sql := Sql + ' OR id IN (' + Gaps + ')';
      Sql := Sql + ' ORDER BY id LIMIT 500';
      R := C.ExecParams(A, Sql, [DbParam(A, FLast)]);

      for I := 0 to R.RowCount - 1 do
      begin
        Id := R.AsInt64(I, 0);
        if Id > FLast then
        begin
          { Every id between the last and this one that was not here is
            one that may still commit. A thousand at most: a jump larger
            than that is a table somebody emptied, not a race. }
          if Id - FLast - 1 <= 1000 then
            for K := 1 to Id - FLast - 1 do
            begin
              J := Length(FGaps);
              SetLength(FGaps, J + 1);
              FGaps[J].Id := FLast + K;
              FGaps[J].Until_ := Now_ + FGapMs;
            end;
          FLast := Id;
        end
        else
        begin
          { A gap filled: it no longer needs asking for. }
          Found := False;
          for J := 0 to High(FGaps) do
            if FGaps[J].Id = Id then
            begin
              FGaps[J] := FGaps[High(FGaps)];
              SetLength(FGaps, Length(FGaps) - 1);
              Found := True;
              Break;
            end;
          if not Found then
            Continue;
        end;
        if R.Value(I, 4).ToString = FOrigin then
          Continue;
        DeliverBroadcast(Id, R.Value(I, 1).ToString, R.Value(I, 2).ToString,
          R.Value(I, 3).ToString);
        Inc(Result);
      end;

      { A gap left long enough is a rollback, not a race. }
      J := 0;
      for I := 0 to High(FGaps) do
        if FGaps[I].Until_ > Now_ then
        begin
          FGaps[J] := FGaps[I];
          Inc(J);
        end;
      SetLength(FGaps, J);
    finally
      A.Free;
      FPool.Release(C);
    end;
  finally
    FPollLock.Release;
  end;
end;

{ ------------------------------------------------------------- running -- }

constructor TPollThread.Create(AOwner: TDbBroadcasts);
begin
  FOwner := AOwner;
  inherited Create('askr.broadcast', rpOnCrash);
end;

function TPollThread.Wanted: Boolean;
begin
  Result := InterLockedExchangeAdd(FOwner.FRunning, 0) <> 0;
end;

{ A poll that fails -- the database gone for a moment -- raises, and the
  supervisor starts the thread again after its backoff. }
procedure TPollThread.Run;
var
  Deadline: Int64;
begin
  while Wanted do
  begin
    FOwner.Poll;
    Deadline := MonotonicMs + FOwner.FPollMs;
    while Wanted and (MonotonicMs < Deadline) do
      Sleep(10);
  end;
end;

procedure TDbBroadcasts.Start;
begin
  if InterLockedExchange(FRunning, 1) <> 0 then
    Exit;
  SetBroadcastRelay(Relay);
  FThread := TPollThread.Create(Self);
end;

procedure TDbBroadcasts.Stop;
begin
  if InterLockedExchange(FRunning, 0) = 0 then
    Exit;
  SetBroadcastRelay(nil);
  if FThread <> nil then
  begin
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;
end;

function BroadcastsFromConfig(Pool: TDbPool): TDbBroadcasts;
var
  Driver: string;
begin
  Driver := LowerCase(Trim(Cfg('broadcast.driver', 'memory')));
  if Driver = 'memory' then
    Exit(nil);
  if Driver = 'database' then
    Exit(TDbBroadcasts.Create(Pool));
  raise EBroadcastError.CreateFmt('BROADCAST_DRIVER is "%s", and the ' +
    'drivers are memory and database.', [Driver]);
end;

procedure SetBroadcasts(B: TDbBroadcasts);
begin
  if (GBroadcasts <> nil) and (GBroadcasts <> B) then
    GBroadcasts.Stop;
  GBroadcasts := B;
  if B <> nil then
    B.Start;
end;

function CurrentBroadcasts: TDbBroadcasts;
begin
  Result := GBroadcasts;
end;

end.
