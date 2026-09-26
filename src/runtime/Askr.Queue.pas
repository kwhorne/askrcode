{ Askr.Queue — background jobs in the same process.

  The PRD's second rule: background jobs never borrow the request's arena,
  they get their own. Here is why that rule cannot be a convention.

  When a controller calls Push, the payload lives in the request arena.
  The request is long finished before the job runs — the arena has been
  reset, and the memory handed out to a new request. If the job points
  there, it reads another user's data.

  So there are two copies on the way, and neither can be skipped:

    request arena  ->  heap (in Push, while the caller still owns the bytes)
                   ->  worker arena (in the worker, before the handler runs)

  The first copy detaches the job from the request. The second gives the
  handler a payload with the same lifetime as everything else it works
  with, so it can be written exactly like a controller. The worker resets
  its arena between jobs, as the HTTP workers do between requests.

  Queue, scheduler and cache in the same process is the whole point: no
  Redis, no Horizon, no supervisor alongside. }
unit Askr.Queue;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs, Askr.Core.Arena, Askr.Core.Text,
  Askr.Core.Clock;

type
  EQueueError = class(Exception);

  TJobContext = record
    Name: string;
    { Lives in the worker's arena. Dies when the job is done. }
    Payload: TStr;
    Attempt: Integer;
    Arena: TArena;
  end;

  TJobHandler = procedure(const Ctx: TJobContext);
  { Called when a job fails or is discarded. Its own type because a
    property cannot have an anonymous procedure type. }
  TQueueErrorHandler = procedure(const JobName, Message_: string);

  PJob = ^TJob;
  TJob = record
    Name: string;
    Data: PByte;
    Len: SizeInt;
    RunAt: Int64;        { monotont, millisekunder }
    Attempt: Integer;
    Next: PJob;
  end;

  { A job taken out of the store and belonging to one worker until it is
    settled. Data is owned by the store; exactly one of Complete, Retry,
    Fail or Drop must be called afterwards, and only then is it
    released. }
  TReservedJob = record
    Name: string;
    Data: PByte;
    Len: SizeInt;
    Attempt: Integer;     { number of previous attempts }
    Token: Pointer;       { the store's own handle }
    Id: Int64;            { the store's id, 0 when it has none }
  end;

  { Where the jobs live. Two implementations: in the process, as before,
    and in a database.

    The interface exists so that there is **one** execution path. A separate
    worker loop for durable jobs would give two sets of rules for backoff,
    attempt counting and arena lifetime, and the two would drift apart. }
  TJobStore = class abstract
  public
    { The bytes are the caller's and are copied here. }
    procedure Push(const JobName: string; Data: PByte; Len: SizeInt;
      DelayMs: Int64); virtual; abstract;
    { Takes one job that is ready. False when there is none. }
    function Reserve(out J: TReservedJob): Boolean; virtual; abstract;
    procedure Complete(var J: TReservedJob); virtual; abstract;
    procedure Retry(var J: TReservedJob; DelayMs: Int64); virtual; abstract;
    { Attempts exhausted. }
    procedure Fail(var J: TReservedJob; const Reason: string); virtual; abstract;
    { No handler registered — the job can never run. }
    procedure Drop(var J: TReservedJob; const Reason: string); virtual; abstract;
    function Pending: Integer; virtual; abstract;
    { Do the jobs survive the process restarting? }
    function Durable: Boolean; virtual;
    { How long an idle worker waits before looking again. A store in the
      process is woken by a signal and can wait briefly; a store in a
      database has to ask, and then 20 ms is hammering on it. }
    function PollIntervalMs: Integer; virtual;
  end;

  { The jobs in a chain in the process. This is the behaviour the queue
    has always had, now behind the interface. }
  TMemoryJobStore = class(TJobStore)
  private
    FLock: TCriticalSection;
    FHead: PJob;
    FCount: Integer;
    procedure Insert_(J: PJob);
    procedure FreeJob(var J: TReservedJob);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Push(const JobName: string; Data: PByte; Len: SizeInt;
      DelayMs: Int64); override;
    function Reserve(out J: TReservedJob): Boolean; override;
    procedure Complete(var J: TReservedJob); override;
    procedure Retry(var J: TReservedJob; DelayMs: Int64); override;
    procedure Fail(var J: TReservedJob; const Reason: string); override;
    procedure Drop(var J: TReservedJob; const Reason: string); override;
    function Pending: Integer; override;
  end;

  TJobBinding = record
    Name: string;
    Handler: TJobHandler;
  end;

  TQueue = class;

  TQueueWorker = class(TThread)
  private
    FQueue: TQueue;
    FArena: TArena;
    FIndex: Integer;
    FDone: QWord;
  protected
    procedure Execute; override;
  public
    constructor Create(AQueue: TQueue; AIndex: Integer);
    destructor Destroy; override;
    property Handled: QWord read FDone;
  end;

  TQueue = class
  private
    FLock: TCriticalSection;
    FSignal: TEvent;
    FStore: TJobStore;
    FOwnsStore: Boolean;
    FWorkers: array of TQueueWorker;
    FWorkerCount: Integer;
    FMaxAttempts: Integer;
    FRunning: LongInt;
    { Workers between asking the store for a job and settling it. Counted
      up before Reserve, so there is no moment where a job has left the
      store and is not counted here. }
    FBusy: LongInt;
    { Name to handler. An ordinary table with a linear search, not a
      TStringList with Objects: a procedure variable cannot be cast to
      TObject in Delphi mode without the compiler reading it as a call.
      The number of job types is a handful anyway. }
    FBindings: array of TJobBinding;
    FProcessed, FFailed, FRetried, FDropped: QWord;
    FOnError: TQueueErrorHandler;
    FFaking: Boolean;
    FFakeNames: array of string;
    FFakePayloads: array of string;
    function HandlerFor(const JobName: string): TJobHandler;
    function IsRunning: Boolean;
  public
    constructor Create(AWorkers: Integer = 2;
      AMaxAttempts: Integer = 3); overload;
    { With a store of your own. The queue takes ownership when OwnsStore is
      set. }
    constructor Create(AStore: TJobStore; AWorkers: Integer = 2;
      AMaxAttempts: Integer = 3; AOwnsStore: Boolean = True); overload;
    destructor Destroy; override;

    { The name is bound to a handler. Unknown names are discarded with a
      count. }
    procedure Handle(const JobName: string; H: TJobHandler);

    { The payload is copied out of the caller's arena here and now. }
    procedure Push(const JobName: string; const Payload: TStr;
      DelaySeconds: Integer = 0); overload;
    procedure Push(const JobName, Payload: string;
      DelaySeconds: Integer = 0); overload;

    procedure Start;
    { Drain waits until the queue is empty. Without drain, whatever is left
      is discarded. }
    procedure Stop(Drain: Boolean = True);
    { Waits until no job is waiting and none is running, or the time runs
      out. It exists for tests. The store alone counts a job as gone once
      a worker has taken it, so asking the store returned while the last
      job still ran. }
    function WaitUntilEmpty(TimeoutMs: Integer): Boolean;

    function Pending: Integer;

    { For a test. From Fake on, Push records the job and nothing runs it,
      so a test can ask what was queued without a worker racing it:
      Pushed counts a name, PushedPayload gives one, and RunPushed runs
      what was recorded through the real handlers, here and now, in order
      -- with an arena, as a worker would -- and lets an exception out.
      StopFaking forgets the record and queues for real again. }
    procedure Fake;
    procedure StopFaking;
    function Pushed(const JobName: string): Integer;
    function PushedPayload(const JobName: string; Index: Integer = 0): string;
    procedure RunPushed;
    property Processed: QWord read FProcessed;
    property Failed: QWord read FFailed;
    property Retried: QWord read FRetried;
    property Dropped: QWord read FDropped;
    property Workers: Integer read FWorkerCount;
    property MaxAttempts: Integer read FMaxAttempts write FMaxAttempts;
    property OnError: TQueueErrorHandler read FOnError write FOnError;
    property Store: TJobStore read FStore;
    { Do the jobs survive a restart? For status endpoints, and for saying
      in the startup log what kind of queue this actually is. }
    function Durable: Boolean;
  end;

function Queue: TQueue;
procedure SetQueue(AQueue: TQueue);

implementation

var
  GQueue: TQueue = nil;

function Queue: TQueue;
begin
  if GQueue = nil then
    raise EQueueError.Create(
      'No queue is configured. Call SetQueue at startup.');
  Result := GQueue;
end;

procedure SetQueue(AQueue: TQueue);
begin
  GQueue := AQueue;
end;

{ TJobStore }

function TJobStore.Durable: Boolean;
begin
  Result := False;
end;

function TJobStore.PollIntervalMs: Integer;
begin
  Result := 20;
end;

{ TMemoryJobStore }

constructor TMemoryJobStore.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TMemoryJobStore.Destroy;
var
  J, N: PJob;
begin
  J := FHead;
  while J <> nil do
  begin
    N := J^.Next;
    if J^.Data <> nil then
      FreeMem(J^.Data);
    J^.Name := '';
    Dispose(J);
    J := N;
  end;
  FLock.Free;
  inherited Destroy;
end;

procedure TMemoryJobStore.Insert_(J: PJob);
var
  Cur, Prev: PJob;
begin
  Cur := FHead;
  Prev := nil;
  while (Cur <> nil) and (Cur^.RunAt <= J^.RunAt) do
  begin
    Prev := Cur;
    Cur := Cur^.Next;
  end;
  J^.Next := Cur;
  if Prev = nil then
    FHead := J
  else
    Prev^.Next := J;
  Inc(FCount);
end;

procedure TMemoryJobStore.Push(const JobName: string; Data: PByte;
  Len: SizeInt; DelayMs: Int64);
var
  J: PJob;
begin
  New(J);
  FillChar(J^, SizeOf(TJob), 0);
  J^.Name := JobName;
  J^.Attempt := 0;
  J^.RunAt := MonotonicMs + DelayMs;
  { This is the boundary. The bytes are copied while the caller still
    owns them; in a millisecond the request arena is reset and the memory
    handed out again. }
  if Len > 0 then
  begin
    J^.Data := GetMem(Len);
    Move(Data^, J^.Data^, Len);
  end;
  J^.Len := Len;

  FLock.Acquire;
  try
    Insert_(J);
  finally
    FLock.Release;
  end;
end;

function TMemoryJobStore.Reserve(out J: TReservedJob): Boolean;
var
  P: PJob;
  Now_: Int64;
begin
  FillChar(J, SizeOf(J), 0);
  J.Name := '';
  Result := False;
  Now_ := MonotonicMs;
  FLock.Acquire;
  try
    if (FHead = nil) or (FHead^.RunAt > Now_) then
      Exit;
    P := FHead;
    FHead := P^.Next;
    P^.Next := nil;
    Dec(FCount);
  finally
    FLock.Release;
  end;
  J.Name := P^.Name;
  J.Data := P^.Data;
  J.Len := P^.Len;
  J.Attempt := P^.Attempt;
  J.Token := P;
  J.Id := 0;
  Result := True;
end;

procedure TMemoryJobStore.FreeJob(var J: TReservedJob);
var
  P: PJob;
begin
  P := PJob(J.Token);
  if P <> nil then
  begin
    if P^.Data <> nil then
      FreeMem(P^.Data);
    P^.Name := '';
    Dispose(P);
  end;
  J.Token := nil;
  J.Data := nil;
  J.Len := 0;
  J.Name := '';
end;

procedure TMemoryJobStore.Complete(var J: TReservedJob);
begin
  FreeJob(J);
end;

procedure TMemoryJobStore.Retry(var J: TReservedJob; DelayMs: Int64);
var
  P: PJob;
begin
  P := PJob(J.Token);
  if P = nil then
    Exit;
  Inc(P^.Attempt);
  P^.RunAt := MonotonicMs + DelayMs;
  FLock.Acquire;
  try
    Insert_(P);
  finally
    FLock.Release;
  end;
  { The job is back in the chain and no longer owned by the worker. }
  J.Token := nil;
  J.Data := nil;
  J.Len := 0;
  J.Name := '';
end;

procedure TMemoryJobStore.Fail(var J: TReservedJob; const Reason: string);
begin
  { A job that has used up its attempts disappears. A store in the
    process has nowhere to put it; that is precisely the difference
    between this and a durable queue. }
  FreeJob(J);
end;

procedure TMemoryJobStore.Drop(var J: TReservedJob; const Reason: string);
begin
  FreeJob(J);
end;

function TMemoryJobStore.Pending: Integer;
begin
  FLock.Acquire;
  try
    Result := FCount;
  finally
    FLock.Release;
  end;
end;

{ TQueue }

constructor TQueue.Create(AWorkers, AMaxAttempts: Integer);
begin
  Create(TMemoryJobStore.Create, AWorkers, AMaxAttempts, True);
end;

constructor TQueue.Create(AStore: TJobStore; AWorkers, AMaxAttempts: Integer;
  AOwnsStore: Boolean);
begin
  inherited Create;
  if AStore = nil then
    raise EQueueError.Create('A queue needs a job store.');
  if AWorkers < 1 then
    AWorkers := 1;
  FStore := AStore;
  FOwnsStore := AOwnsStore;
  FWorkerCount := AWorkers;
  FMaxAttempts := AMaxAttempts;
  FLock := TCriticalSection.Create;
  FSignal := TEvent.Create(nil, False, False, '');
end;

destructor TQueue.Destroy;
begin
  Stop(False);
  FSignal.Free;
  FLock.Free;
  if FOwnsStore then
    FStore.Free;
  inherited Destroy;
end;

function TQueue.Durable: Boolean;
begin
  Result := FStore.Durable;
end;

function TQueue.IsRunning: Boolean;
begin
  Result := InterLockedExchangeAdd(FRunning, 0) <> 0;
end;

procedure TQueue.Handle(const JobName: string; H: TJobHandler);
var
  I, N: Integer;
begin
  if not Assigned(H) then
    raise EQueueError.CreateFmt('The handler for "%s" is nil', [JobName]);
  FLock.Acquire;
  try
    for I := 0 to High(FBindings) do
      if FBindings[I].Name = JobName then
      begin
        FBindings[I].Handler := H;
        Exit;
      end;
    N := Length(FBindings);
    SetLength(FBindings, N + 1);
    FBindings[N].Name := JobName;
    FBindings[N].Handler := H;
  finally
    FLock.Release;
  end;
end;

function TQueue.HandlerFor(const JobName: string): TJobHandler;
var
  I: Integer;
begin
  Result := nil;
  FLock.Acquire;
  try
    for I := 0 to High(FBindings) do
      if FBindings[I].Name = JobName then
        Exit(FBindings[I].Handler);
  finally
    FLock.Release;
  end;
end;


procedure TQueue.Push(const JobName: string; const Payload: TStr;
  DelaySeconds: Integer);
var
  I: Integer;
begin
  if FFaking then
  begin
    FLock.Acquire;
    try
      I := Length(FFakeNames);
      SetLength(FFakeNames, I + 1);
      SetLength(FFakePayloads, I + 1);
      FFakeNames[I] := JobName;
      FFakePayloads[I] := Payload.ToString;
    finally
      FLock.Release;
    end;
    Exit;
  end;
  { The store copies the bytes while the caller still owns them. The
    boundary is there and cannot be skipped: in a millisecond the request
    arena is reset and the memory handed out again. }
  FStore.Push(JobName, Payload.Data, Payload.Len,
    Int64(DelaySeconds) * 1000);
  FSignal.SetEvent;
end;

procedure TQueue.Push(const JobName, Payload: string; DelaySeconds: Integer);
begin
  Push(JobName, Str(Payload), DelaySeconds);
end;



procedure TQueue.Fake;
begin
  FLock.Acquire;
  try
    FFaking := True;
    FFakeNames := nil;
    FFakePayloads := nil;
  finally
    FLock.Release;
  end;
end;

procedure TQueue.StopFaking;
begin
  FLock.Acquire;
  try
    FFaking := False;
    FFakeNames := nil;
    FFakePayloads := nil;
  finally
    FLock.Release;
  end;
end;

function TQueue.Pushed(const JobName: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  FLock.Acquire;
  try
    for I := 0 to High(FFakeNames) do
      if FFakeNames[I] = JobName then
        Inc(Result);
  finally
    FLock.Release;
  end;
end;

function TQueue.PushedPayload(const JobName: string; Index: Integer): string;
var
  I, N: Integer;
begin
  N := 0;
  FLock.Acquire;
  try
    for I := 0 to High(FFakeNames) do
      if FFakeNames[I] = JobName then
      begin
        if N = Index then
          Exit(FFakePayloads[I]);
        Inc(N);
      end;
  finally
    FLock.Release;
  end;
  raise EQueueError.CreateFmt('No job %s number %d was pushed', [JobName, Index]);
end;

procedure TQueue.RunPushed;
var
  Names, Payloads: array of string;
  I: Integer;
  H: TJobHandler;
  Ctx: TJobContext;
  A, Prev: TArena;
begin
  FLock.Acquire;
  try
    Names := Copy(FFakeNames);
    Payloads := Copy(FFakePayloads);
    FFakeNames := nil;
    FFakePayloads := nil;
  finally
    FLock.Release;
  end;
  for I := 0 to High(Names) do
  begin
    H := HandlerFor(Names[I]);
    if not Assigned(H) then
      raise EQueueError.CreateFmt('No handler for the job %s', [Names[I]]);
    A := TArena.Create(64 * 1024);
    Prev := UseArena(A);
    try
      Ctx.Name := Names[I];
      Ctx.Payload := StrDup(A, Payloads[I]);
      Ctx.Attempt := 1;
      Ctx.Arena := A;
      H(Ctx);
    finally
      UseArena(Prev);
      A.Free;
    end;
  end;
end;

procedure TQueue.Start;
var
  I: Integer;
begin
  if IsRunning then
    Exit;
  InterLockedExchange(FRunning, 1);
  SetLength(FWorkers, FWorkerCount);
  for I := 0 to FWorkerCount - 1 do
    FWorkers[I] := TQueueWorker.Create(Self, I);
end;

function TQueue.WaitUntilEmpty(TimeoutMs: Integer): Boolean;
var
  Deadline: Int64;
begin
  Deadline := MonotonicMs + TimeoutMs;
  repeat
    { Pending first: a worker counts itself busy before it takes a job,
      so a job that has left the store is seen here. }
    if (Pending = 0) and (InterLockedExchangeAdd(FBusy, 0) = 0) then
      Exit(True);
    if MonotonicMs > Deadline then
      Exit(False);
    Sleep(2);
  until False;
end;

procedure TQueue.Stop(Drain: Boolean);
var
  I: Integer;
begin
  if not IsRunning then
    Exit;
  if Drain then
    WaitUntilEmpty(10000);

  InterLockedExchange(FRunning, 0);
  for I := 0 to High(FWorkers) do
    FSignal.SetEvent;
  for I := 0 to High(FWorkers) do
    if FWorkers[I] <> nil then
    begin
      FWorkers[I].WaitFor;
      FWorkers[I].Free;
      FWorkers[I] := nil;
    end;
  SetLength(FWorkers, 0);

  { Whatever is left is cleared by the store, not here. For a store in
    the process that means the jobs disappear — which is why Stop without
    Drain counts them as discarded. For a durable store they stay and run
    the next time the app starts, and that is the whole point. }
  if not FStore.Durable then
    Inc(FDropped, QWord(FStore.Pending));
end;

function TQueue.Pending: Integer;
begin
  Result := FStore.Pending;
end;

{ TQueueWorker }

constructor TQueueWorker.Create(AQueue: TQueue; AIndex: Integer);
begin
  FQueue := AQueue;
  FIndex := AIndex;
  { Its own arena per worker, reset between jobs. The same pattern as the
    HTTP workers, and for the same reason. }
  FArena := TArena.Create(64 * 1024);
  inherited Create(False);
end;

destructor TQueueWorker.Destroy;
begin
  inherited Destroy;
  FArena.Free;
end;

procedure TQueueWorker.Execute;
var
  J: TReservedJob;
  H: TJobHandler;
  Ctx: TJobContext;
  Prev: TArena;
  Backoff: Int64;
begin
  while FQueue.IsRunning do
  begin
    InterLockedIncrement(FQueue.FBusy);
    if not FQueue.FStore.Reserve(J) then
    begin
      InterLockedDecrement(FQueue.FBusy);
      { Waits on a signal, but wakes regularly regardless: a delayed job
        does not signal itself when its time comes, and a job added by
        another process does not signal at all. }
      FQueue.FSignal.WaitFor(FQueue.FStore.PollIntervalMs);
      Continue;
    end;

    H := FQueue.HandlerFor(J.Name);
    if not Assigned(H) then
    begin
      InterLockedIncrement64(Int64(FQueue.FDropped));
      if Assigned(FQueue.FOnError) then
        FQueue.FOnError(J.Name, 'no handler registered');
      FQueue.FStore.Drop(J, 'no handler registered');
      InterLockedDecrement(FQueue.FBusy);
      Continue;
    end;

    FArena.Reset;
    Prev := UseArena(FArena);
    try
      Ctx.Name := J.Name;
      Ctx.Attempt := J.Attempt + 1;
      Ctx.Arena := FArena;
      { The second copy: from the store's memory into the worker's arena, so
        the handler can be written like a controller. }
      if J.Len > 0 then
        Ctx.Payload := StrDup(FArena, StrRef(J.Data, J.Len))
      else
        Ctx.Payload := StrEmpty;

      try
        H(Ctx);
        InterLockedIncrement64(Int64(FQueue.FProcessed));
        Inc(FDone);
        FQueue.FStore.Complete(J);
      except
        on E: Exception do
        begin
          if Assigned(FQueue.FOnError) then
            FQueue.FOnError(J.Name, E.ClassName + ': ' + E.Message);
          if J.Attempt + 1 < FQueue.FMaxAttempts then
          begin
            InterLockedIncrement64(Int64(FQueue.FRetried));
            { Exponential backoff, capped at 30 seconds. }
            Backoff := Int64(100) shl J.Attempt;
            if Backoff > 30000 then
              Backoff := 30000;
            FQueue.FStore.Retry(J, Backoff);
          end
          else
          begin
            InterLockedIncrement64(Int64(FQueue.FFailed));
            FQueue.FStore.Fail(J, E.ClassName + ': ' + E.Message);
          end;
        end;
      end;
    finally
      UseArena(Prev);
      { After Complete, Retry or Fail: a retried job is back in the store
        before it stops being counted here. }
      InterLockedDecrement(FQueue.FBusy);
    end;
  end;
end;

end.
