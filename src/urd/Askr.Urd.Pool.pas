{ Askr.Urd.Pool — connections that are lent out and come back by
  themselves.

  The pool lives on the heap and outlives requests. That follows from the
  PRD's first rule: values that must live longer than the request must not
  live in the request arena.

  Lease is the point. A controller writes

      C := Pool.Lease(Req.Arena);

  and is done with it. The connection is handed back when the host calls
  Arena.Reset, through the Defer mechanism. No try/finally, no forgotten
  returns. Two Lease calls on the same arena and the same pool give the
  same connection, so several queries in one request share a transaction
  and its state.

  A connection that comes back mid-transaction is rolled back before it is
  reused. The alternative — letting the next request inherit an open
  transaction — is a source of bugs nobody ever traces back. }
unit Askr.Urd.Pool;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, SyncObjs, Askr.Core.Arena, Askr.Urd.Driver;

type
  EDbPoolError = class(EDbError);

  TDbPool = class
  private
    FDsn: string;
    FMax: Integer;
    FIdle: array of TDbConnection;
    FIdleCount: Integer;
    FLive: Integer;
    FLock: TCriticalSection;
    FSlot: TEvent;
    FClosing: Boolean;
    FAcquired: QWord;
    FCreated: QWord;
    FDiscarded: QWord;
    function TakeIdle: TDbConnection;
    procedure Discard(C: TDbConnection);
  public
    constructor Create(const ADsn: string; AMax: Integer = 8);
    destructor Destroy; override;

    { Blocks until a connection is free or the time runs out. The caller is
      responsible for Release. Prefer Lease. }
    function Acquire(TimeoutMs: Integer = 5000): TDbConnection;
    procedure Release(C: TDbConnection);

    { Lends one out for the rest of the request. Returned at
      Arena.Reset. }
    function Lease(A: TArena): TDbConnection;

    { Opens MaxConnections connections up front, so the first request does
      not pay for connecting. Raises if the database does not answer. }
    procedure Warmup;

    property Dsn: string read FDsn;
    property MaxConnections: Integer read FMax;
    property IdleCount: Integer read FIdleCount;
    { Open connections in total, free and lent out. }
    property LiveCount: Integer read FLive;
    property AcquiredTotal: QWord read FAcquired;
    property CreatedTotal: QWord read FCreated;
    property DiscardedTotal: QWord read FDiscarded;
  end;

implementation

type
  PLeaseSlot = ^TLeaseSlot;
  TLeaseSlot = record
    Arena: TArena;
    Pool: TDbPool;
    Conn: TDbConnection;
  end;

const
  { Enough for one request to talk to several databases. If more are
    needed, that is a design problem in the app, not in the pool. }
  MaxLeasesPerThread = 4;

threadvar
  GLeases: array[0..MaxLeasesPerThread - 1] of TLeaseSlot;

function FindLease(A: TArena; P: TDbPool): TDbConnection;
var
  I: Integer;
begin
  for I := 0 to MaxLeasesPerThread - 1 do
    if (GLeases[I].Arena = A) and (GLeases[I].Pool = P) then
      Exit(GLeases[I].Conn);
  Result := nil;
end;

function StoreLease(A: TArena; P: TDbPool; C: TDbConnection): PLeaseSlot;
var
  I: Integer;
begin
  for I := 0 to MaxLeasesPerThread - 1 do
    if GLeases[I].Arena = nil then
    begin
      GLeases[I].Arena := A;
      GLeases[I].Pool := P;
      GLeases[I].Conn := C;
      Exit(@GLeases[I]);
    end;
  Result := nil;
end;

procedure ReturnLease(Data: Pointer);
var
  S: PLeaseSlot;
  P: TDbPool;
  C: TDbConnection;
begin
  S := PLeaseSlot(Data);
  P := S^.Pool;
  C := S^.Conn;
  { Released first, so a Release that raises does not leave a slot
    pointing at a connection nobody owns. }
  S^.Arena := nil;
  S^.Pool := nil;
  S^.Conn := nil;
  if (P <> nil) and (C <> nil) then
    P.Release(C);
end;

{ TDbPool }

constructor TDbPool.Create(const ADsn: string; AMax: Integer);
begin
  inherited Create;
  if AMax < 1 then
    AMax := 1;
  FDsn := ADsn;
  FMax := AMax;
  FLock := TCriticalSection.Create;
  { Auto-reset: one return should wake one waiting thread, not all of
    them. }
  FSlot := TEvent.Create(nil, False, False, '');
  SetLength(FIdle, FMax);
end;

destructor TDbPool.Destroy;
var
  I: Integer;
begin
  FLock.Acquire;
  try
    FClosing := True;
    for I := 0 to FIdleCount - 1 do
    begin
      FIdle[I].Free;
      FIdle[I] := nil;
    end;
    FIdleCount := 0;
  finally
    FLock.Release;
  end;
  FSlot.Free;
  FLock.Free;
  inherited Destroy;
end;

function TDbPool.TakeIdle: TDbConnection;
begin
  Result := nil;
  while FIdleCount > 0 do
  begin
    Dec(FIdleCount);
    Result := FIdle[FIdleCount];
    FIdle[FIdleCount] := nil;
    if Result.IsAlive then
      Exit;
    { A dead connection — throw it away and try the next. }
    Result.Free;
    Dec(FLive);
    Inc(FDiscarded);
    Result := nil;
  end;
end;

procedure TDbPool.Discard(C: TDbConnection);
begin
  FLock.Acquire;
  try
    Dec(FLive);
    Inc(FDiscarded);
  finally
    FLock.Release;
  end;
  C.Free;
  FSlot.SetEvent;
end;

function TDbPool.Acquire(TimeoutMs: Integer): TDbConnection;
var
  Deadline: QWord;
  MayOpen: Boolean;
  Waited: LongInt;
begin
  Deadline := GetTickCount64 + QWord(TimeoutMs);
  repeat
    MayOpen := False;
    FLock.Acquire;
    try
      if FClosing then
        raise EDbPoolError.Create('The pool is closed');
      Result := TakeIdle;
      if Result <> nil then
      begin
        Inc(FAcquired);
        Exit;
      end;
      if FLive < FMax then
      begin
        { The slot is reserved before we drop the lock, or several threads
          can open past the limit at the same time. }
        Inc(FLive);
        MayOpen := True;
      end;
    finally
      FLock.Release;
    end;

    if MayOpen then
    begin
      try
        Result := OpenDbConnection(FDsn);
      except
        FLock.Acquire;
        try
          Dec(FLive);
        finally
          FLock.Release;
        end;
        raise;
      end;
      FLock.Acquire;
      try
        Inc(FCreated);
        Inc(FAcquired);
      finally
        FLock.Release;
      end;
      Exit;
    end;

    if GetTickCount64 >= Deadline then
      Break;
    Waited := LongInt(Deadline - GetTickCount64);
    if Waited > 50 then
      Waited := 50;
    FSlot.WaitFor(Waited);
  until False;

  raise EDbPoolError.CreateFmt(
    'No free database connection within %d ms (max %d).',
    [TimeoutMs, FMax]);
end;

procedure TDbPool.Release(C: TDbConnection);
var
  Keep: Boolean;
begin
  if C = nil then
    Exit;

  { An open transaction must not be inherited by the next request. }
  if C.InTransaction then
  begin
    try
      C.Rollback;
    except
      Discard(C);
      Exit;
    end;
  end;

  if not C.IsAlive then
  begin
    Discard(C);
    Exit;
  end;

  FLock.Acquire;
  try
    Keep := not FClosing and (FIdleCount < FMax);
    if Keep then
    begin
      FIdle[FIdleCount] := C;
      Inc(FIdleCount);
    end
    else
    begin
      Dec(FLive);
      Inc(FDiscarded);
    end;
  finally
    FLock.Release;
  end;
  { Freed outside the lock — a destructor can take time, and libpq
    closes a socket here. }
  if not Keep then
    C.Free;
  FSlot.SetEvent;
end;

function TDbPool.Lease(A: TArena): TDbConnection;
var
  Slot: PLeaseSlot;
begin
  if A = nil then
    raise EDbPoolError.Create('Lease without an arena');

  { The same arena and the same pool should give the same connection, so
    several queries in one request share a transaction. }
  Result := FindLease(A, Self);
  if Result <> nil then
    Exit;

  Result := Acquire;
  Slot := StoreLease(A, Self, Result);
  if Slot = nil then
  begin
    Release(Result);
    raise EDbPoolError.CreateFmt(
      'More than %d concurrent leases on one thread', [MaxLeasesPerThread]);
  end;

  try
    A.Defer(ReturnLease, Slot);
  except
    Slot^.Arena := nil;
    Slot^.Pool := nil;
    Slot^.Conn := nil;
    Release(Result);
    raise;
  end;
end;

procedure TDbPool.Warmup;
var
  Opened: array of TDbConnection;
  I: Integer;
begin
  SetLength(Opened, FMax);
  try
    for I := 0 to FMax - 1 do
      Opened[I] := Acquire;
  finally
    for I := 0 to FMax - 1 do
      if Opened[I] <> nil then
        Release(Opened[I]);
  end;
end;

end.
