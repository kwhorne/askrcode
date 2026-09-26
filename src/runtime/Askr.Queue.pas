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

  TQueue = class;

  TJobContext = record
    Name: string;
    { Lives in the worker's arena. Dies when the job is done. }
    Payload: TStr;
    Attempt: Integer;
    Arena: TArena;
    { True when a failure now is final: no attempt comes after this one. }
    Last: Boolean;
    { The batch this job -- or this batch's callback -- belongs to; '' for
      a job that is in none. }
    BatchId: string;
    Queue: TQueue;
  end;

  { A job to be queued: its name and its payload. }
  TJobSpec = record
    Name: string;
    Payload: string;
  end;
  TJobSpecs = array of TJobSpec;

  { What a batch queues when it ends. A job with no name is none. }
  TBatchCallbacks = record
    { When every job has succeeded. }
    OnSuccess: TJobSpec;
    { When the first job has failed for good -- once, not per failure. }
    OnFailure: TJobSpec;
    { When every job has run, however it went. }
    Always: TJobSpec;
  end;

  TBatchState = record
    Id: string;
    Name: string;
    Total: Integer;
    { Not yet settled: waiting, running, or between attempts. }
    Pending: Integer;
    Failed: Integer;
    Cancelled: Boolean;
    Finished: Boolean;
  end;

  TMemoryBatch = record
    State: TBatchState;
    Callbacks: TBatchCallbacks;
    Caught: Boolean;
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

    { Batches. The store keeps the count, because deciding which job was
      the last one has to be one step there: two workers finishing at once
      must not both think they did, or neither. Kept in the process here;
      Askr.Queue.Db keeps them in a table. }
    procedure CreateBatch(const Id, Name: string; Total: Integer;
      const Callbacks: TBatchCallbacks); virtual;
    { One job of the batch is settled, for good. Gives the callbacks to
      queue now, if this settling is what calls for them. }
    function SettleBatchJob(const Id: string; Failed: Boolean): TJobSpecs; virtual;
    function FindBatch(const Id: string; out State: TBatchState): Boolean; virtual;
    procedure CancelBatch(const Id: string); virtual;
  private
    FBatches: array of TMemoryBatch;
    function CreateBatch_Index(const Id: string): Integer;
    procedure Delete_(Index: Integer);
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

  { The jobs of a chain run one after the other, each only when the one
    before it has succeeded. Built with Queue.Chain. }
  TChain = record
  private
    FQueue: TQueue;
    FSteps: TJobSpecs;
    FFailure: TJobSpec;
  public
    function Add(const Name: string; const Payload: string = ''): TChain;
    { Queued when a step has failed for good. The steps after it never
      run. }
    function OnFailure(const Name: string; const Payload: string = ''): TChain;
    procedure Push;
  end;

  { The jobs of a batch run side by side, and the batch knows when they
    are all done. Built with Queue.Batch. }
  TBatch = record
  private
    FQueue: TQueue;
    FName: string;
    FJobs: TJobSpecs;
    FCallbacks: TBatchCallbacks;
  public
    function Add(const Name: string; const Payload: string = ''): TBatch;
    function OnSuccess(const Name: string; const Payload: string = ''): TBatch;
    function OnFailure(const Name: string; const Payload: string = ''): TBatch;
    function Always(const Name: string; const Payload: string = ''): TBatch;
    { Makes the batch and queues its jobs. The batch's id comes back. }
    function Push: string;
  end;

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
    class procedure RunChainJob(const Ctx: TJobContext); static;
    class procedure RunBatchJob(const Ctx: TJobContext); static;
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

    { Jobs that run one after another. }
    function Chain: TChain;
    { Jobs that run side by side, as one piece of work. Name is for people
      reading the status. }
    function Batch(const Name: string): TBatch;
    { False when there is no such batch. }
    function BatchStatus(const Id: string; out State: TBatchState): Boolean;
    { The jobs of the batch not yet started are skipped; those running
      finish. OnSuccess is not queued, Always is. }
    procedure CancelBatch(const Id: string);
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

const
  ChainJob = 'askr.chain';
  BatchJob = 'askr.batch';

function Job(const Name: string; const Payload: string = ''): TJobSpec;

implementation

uses
  Askr.Core.Json, Askr.Core.Crypto, Askr.Core.Log;

var
  GQueue: TQueue = nil;
  GBatchLock: TCriticalSection = nil;

function Job(const Name, Payload: string): TJobSpec;
begin
  Result.Name := Name;
  Result.Payload := Payload;
end;

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

{ The batches of a store in the process. One lock for all of them: a
  settling is a handful of assignments. }

function TJobStore.CreateBatch_Index(const Id: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FBatches) do
    if FBatches[I].State.Id = Id then
      Exit(I);
  Result := -1;
end;

procedure TJobStore.CreateBatch(const Id, Name: string; Total: Integer;
  const Callbacks: TBatchCallbacks);
var
  I, Finished_: Integer;
begin
  GBatchLock.Acquire;
  try
    { Finished ones are kept for BatchStatus, but not for ever: past a
      thousand, the oldest finished one goes. }
    Finished_ := 0;
    for I := 0 to High(FBatches) do
      if FBatches[I].State.Finished then
        Inc(Finished_);
    if Finished_ >= 1000 then
      for I := 0 to High(FBatches) do
        if FBatches[I].State.Finished then
        begin
          Delete_(I);
          Break;
        end;
    I := Length(FBatches);
    SetLength(FBatches, I + 1);
    FBatches[I].State.Id := Id;
    FBatches[I].State.Name := Name;
    FBatches[I].State.Total := Total;
    FBatches[I].State.Pending := Total;
    FBatches[I].State.Failed := 0;
    FBatches[I].State.Cancelled := False;
    FBatches[I].State.Finished := Total = 0;
    FBatches[I].Callbacks := Callbacks;
    FBatches[I].Caught := False;
  finally
    GBatchLock.Release;
  end;
end;

procedure TJobStore.Delete_(Index: Integer);
var
  I: Integer;
begin
  for I := Index to High(FBatches) - 1 do
    FBatches[I] := FBatches[I + 1];
  SetLength(FBatches, Length(FBatches) - 1);
end;

procedure AddSpec(var L: TJobSpecs; const S: TJobSpec);
var
  I: Integer;
begin
  if S.Name = '' then
    Exit;
  I := Length(L);
  SetLength(L, I + 1);
  L[I] := S;
end;

function TJobStore.SettleBatchJob(const Id: string; Failed: Boolean): TJobSpecs;
var
  I: Integer;
begin
  Result := nil;
  GBatchLock.Acquire;
  try
    I := CreateBatch_Index(Id);
    if I < 0 then
      Exit;
    with FBatches[I] do
    begin
      { A job put back from somewhere and run again after it was counted
        does not take the count below nothing. }
      if State.Pending = 0 then
        Exit;
      Dec(State.Pending);
      if Failed then
      begin
        Inc(State.Failed);
        if not Caught then
        begin
          Caught := True;
          AddSpec(Result, Callbacks.OnFailure);
        end;
      end;
      if State.Pending = 0 then
      begin
        State.Finished := True;
        if (State.Failed = 0) and not State.Cancelled then
          AddSpec(Result, Callbacks.OnSuccess);
        AddSpec(Result, Callbacks.Always);
      end;
    end;
  finally
    GBatchLock.Release;
  end;
end;

function TJobStore.FindBatch(const Id: string; out State: TBatchState): Boolean;
var
  I: Integer;
begin
  GBatchLock.Acquire;
  try
    I := CreateBatch_Index(Id);
    Result := I >= 0;
    if Result then
      State := FBatches[I].State
    else
      State := Default(TBatchState);
  finally
    GBatchLock.Release;
  end;
end;

procedure TJobStore.CancelBatch(const Id: string);
var
  I: Integer;
begin
  GBatchLock.Acquire;
  try
    I := CreateBatch_Index(Id);
    if I >= 0 then
      FBatches[I].State.Cancelled := True;
  finally
    GBatchLock.Release;
  end;
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
  Handle(ChainJob, RunChainJob);
  Handle(BatchJob, RunBatchJob);
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
      { Nothing retries what RunPushed runs: its failure is the last. }
      Ctx.Last := True;
      Ctx.BatchId := '';
      Ctx.Queue := Self;
      H(Ctx);
    finally
      UseArena(Prev);
      A.Free;
    end;
  end;
end;


{ ------------------------------------------------------ chains, batches -- }

procedure WriteSpec(var W: TJsonWriter; const S: TJobSpec);
begin
  W.BeginObject;
  W.Field('name', S.Name);
  W.Field('payload', S.Payload);
  W.EndObject;
end;

function ReadSpec(V: PJsonValue): TJobSpec;
begin
  Result.Name := JsonAsString(JsonMember(V, 'name'));
  Result.Payload := JsonAsString(JsonMember(V, 'payload'));
end;

function ChainPayload(const Steps: TJobSpecs; From_: Integer; const Failure: TJobSpec): string;
var
  A: TArena;
  W: TJsonWriter;
  I: Integer;
begin
  A := TArena.Create(4096);
  try
    W.Init(A, 512);
    W.BeginObject;
    W.Key('steps');
    W.BeginArray;
    for I := From_ to High(Steps) do
      WriteSpec(W, Steps[I]);
    W.EndArray;
    W.Key('failure');
    WriteSpec(W, Failure);
    W.EndObject;
    Result := W.ToString;
  finally
    A.Free;
  end;
end;

function BatchPayload(const Id: string; const S: TJobSpec; Callback: Boolean): string;
var
  A: TArena;
  W: TJsonWriter;
begin
  A := TArena.Create(4096);
  try
    W.Init(A, 512);
    W.BeginObject;
    W.Field('batch', Id);
    W.Field('name', S.Name);
    W.Field('payload', S.Payload);
    W.Field('callback', Callback);
    W.EndObject;
    Result := W.ToString;
  finally
    A.Free;
  end;
end;

{ The step's own handler, with a context of its own: its name and payload
  where the envelope's were. }
procedure RunInner(const Ctx: TJobContext; const S: TJobSpec; const BatchId: string);
var
  H: TJobHandler;
  Inner: TJobContext;
begin
  H := Ctx.Queue.HandlerFor(S.Name);
  if not Assigned(H) then
    raise EQueueError.CreateFmt('No handler is registered for "%s"', [S.Name]);
  Inner := Ctx;
  Inner.Name := S.Name;
  Inner.Payload := StrDup(Ctx.Arena, S.Payload);
  Inner.BatchId := BatchId;
  H(Inner);
end;

{ A chain is one job at a time: the first step, carrying the rest. When it
  succeeds the rest goes back in the queue as a chain of its own, so each
  step gets the queue's retries, and a chain in a durable store survives
  a restart between two steps. }
class procedure TQueue.RunChainJob(const Ctx: TJobContext);
var
  A: TArena;
  Root, Steps, V: PJsonValue;
  ErrorAt: SizeInt;
  L: TJobSpecs;
  Failure: TJobSpec;
begin
  A := TArena.Create(4096);
  try
    if not JsonParse(A, StrDup(A, Ctx.Payload.ToString), Root, ErrorAt) or
       (Root^.Kind <> jkObject) then
      raise EQueueError.Create('A chain job that is not a chain');
    L := nil;
    Steps := JsonMember(Root, 'steps');
    if Steps <> nil then
    begin
      V := Steps^.First;
      while V <> nil do
      begin
        SetLength(L, Length(L) + 1);
        L[High(L)] := ReadSpec(V);
        V := V^.Next;
      end;
    end;
    Failure := ReadSpec(JsonMember(Root, 'failure'));
  finally
    A.Free;
  end;
  if Length(L) = 0 then
    Exit;
  try
    RunInner(Ctx, L[0], '');
  except
    if Ctx.Last and (Failure.Name <> '') then
      Ctx.Queue.Push(Failure.Name, Failure.Payload);
    raise;
  end;
  if Length(L) > 1 then
    Ctx.Queue.Push(ChainJob, ChainPayload(L, 1, Failure));
end;

procedure PushCallbacks(Q: TQueue; const Id: string; const L: TJobSpecs);
var
  I: Integer;
begin
  for I := 0 to High(L) do
    Q.Push(BatchJob, BatchPayload(Id, L[I], True));
end;

class procedure TQueue.RunBatchJob(const Ctx: TJobContext);
var
  A: TArena;
  Root: PJsonValue;
  ErrorAt: SizeInt;
  Id: string;
  S: TJobSpec;
  Callback: Boolean;
  State: TBatchState;
begin
  A := TArena.Create(4096);
  try
    if not JsonParse(A, StrDup(A, Ctx.Payload.ToString), Root, ErrorAt) or
       (Root^.Kind <> jkObject) then
      raise EQueueError.Create('A batch job that is not a batch''s');
    Id := JsonAsString(JsonMember(Root, 'batch'));
    S := ReadSpec(Root);
    Callback := JsonAsBool(JsonMember(Root, 'callback'));
  finally
    A.Free;
  end;
  if Callback then
  begin
    RunInner(Ctx, S, Id);
    Exit;
  end;
  { Cancelled: skipped, and settled, so the batch still ends. }
  if Ctx.Queue.FStore.FindBatch(Id, State) and State.Cancelled then
  begin
    PushCallbacks(Ctx.Queue, Id, Ctx.Queue.FStore.SettleBatchJob(Id, False));
    Exit;
  end;
  try
    RunInner(Ctx, S, Id);
  except
    { Settled as failed only when no attempt comes after this one. }
    if Ctx.Last then
      PushCallbacks(Ctx.Queue, Id, Ctx.Queue.FStore.SettleBatchJob(Id, True));
    raise;
  end;
  PushCallbacks(Ctx.Queue, Id, Ctx.Queue.FStore.SettleBatchJob(Id, False));
end;

function TQueue.Chain: TChain;
begin
  Result.FQueue := Self;
  Result.FSteps := nil;
  Result.FFailure := Job('');
end;

function TQueue.Batch(const Name: string): TBatch;
begin
  Result.FQueue := Self;
  Result.FName := Name;
  Result.FJobs := nil;
  Result.FCallbacks := Default(TBatchCallbacks);
end;

function TQueue.BatchStatus(const Id: string; out State: TBatchState): Boolean;
begin
  Result := FStore.FindBatch(Id, State);
end;

procedure TQueue.CancelBatch(const Id: string);
begin
  FStore.CancelBatch(Id);
end;

{ TChain }

function TChain.Add(const Name, Payload: string): TChain;
begin
  if Name = '' then
    raise EQueueError.Create('A step in a chain needs a name');
  Result := Self;
  SetLength(Result.FSteps, Length(Result.FSteps) + 1);
  Result.FSteps[High(Result.FSteps)] := Job(Name, Payload);
end;

function TChain.OnFailure(const Name, Payload: string): TChain;
begin
  Result := Self;
  Result.FFailure := Job(Name, Payload);
end;

procedure TChain.Push;
begin
  if Length(FSteps) = 0 then
    raise EQueueError.Create('A chain needs at least one step');
  FQueue.Push(ChainJob, ChainPayload(FSteps, 0, FFailure));
end;

{ TBatch }

function TBatch.Add(const Name, Payload: string): TBatch;
begin
  if Name = '' then
    raise EQueueError.Create('A job in a batch needs a name');
  Result := Self;
  SetLength(Result.FJobs, Length(Result.FJobs) + 1);
  Result.FJobs[High(Result.FJobs)] := Job(Name, Payload);
end;

function TBatch.OnSuccess(const Name, Payload: string): TBatch;
begin
  Result := Self;
  Result.FCallbacks.OnSuccess := Job(Name, Payload);
end;

function TBatch.OnFailure(const Name, Payload: string): TBatch;
begin
  Result := Self;
  Result.FCallbacks.OnFailure := Job(Name, Payload);
end;

function TBatch.Always(const Name, Payload: string): TBatch;
begin
  Result := Self;
  Result.FCallbacks.Always := Job(Name, Payload);
end;

function TBatch.Push: string;
var
  I: Integer;
  Done: TJobSpecs;
begin
  Result := LowerCase(RandomHex(16));
  { Made before a job is queued: a job that finished before its batch
    existed would have nothing to count against. }
  FQueue.FStore.CreateBatch(Result, FName, Length(FJobs), FCallbacks);
  if Length(FJobs) = 0 then
  begin
    { Nothing to wait for: it has succeeded. }
    Done := nil;
    AddSpec(Done, FCallbacks.OnSuccess);
    AddSpec(Done, FCallbacks.Always);
    PushCallbacks(FQueue, Result, Done);
    Exit;
  end;
  for I := 0 to High(FJobs) do
    FQueue.Push(BatchJob, BatchPayload(Result, FJobs[I], False));
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

{ The store failed -- a database that was busy, or gone for a moment. The
  worker says so and carries on: a thread that died of it would take its
  share of the queue with it, without a word. }
procedure StoreTrouble(Q: TQueue; const JobName: string; E: Exception);
begin
  LogException(E, 'the job store failed', ['job', JobName]);
  if Assigned(Q.FOnError) then
    Q.FOnError(JobName, 'the job store failed: ' + E.ClassName + ': ' + E.Message);
end;

procedure TQueueWorker.Execute;
var
  J: TReservedJob;
  H: TJobHandler;
  Ctx: TJobContext;
  Prev: TArena;
  Backoff: Int64;
  Got, Ok: Boolean;
  Err: string;
begin
  while FQueue.IsRunning do
  begin
    InterLockedIncrement(FQueue.FBusy);
    try
      Got := FQueue.FStore.Reserve(J);
    except
      on E: Exception do
      begin
        InterLockedDecrement(FQueue.FBusy);
        StoreTrouble(FQueue, '', E);
        FQueue.FSignal.WaitFor(FQueue.FStore.PollIntervalMs);
        Continue;
      end;
    end;
    if not Got then
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
      try
        FQueue.FStore.Drop(J, 'no handler registered');
      except
        on E: Exception do
          StoreTrouble(FQueue, J.Name, E);
      end;
      InterLockedDecrement(FQueue.FBusy);
      Continue;
    end;

    FArena.Reset;
    Prev := UseArena(FArena);
    try
      Ctx.Name := J.Name;
      Ctx.Attempt := J.Attempt + 1;
      Ctx.Arena := FArena;
      Ctx.Last := J.Attempt + 1 >= FQueue.FMaxAttempts;
      Ctx.BatchId := '';
      Ctx.Queue := FQueue;
      { The second copy: from the store's memory into the worker's arena, so
        the handler can be written like a controller. }
      if J.Len > 0 then
        Ctx.Payload := StrDup(FArena, StrRef(J.Data, J.Len))
      else
        Ctx.Payload := StrEmpty;

      Ok := False;
      Err := '';
      try
        H(Ctx);
        Ok := True;
      except
        on E: Exception do
          Err := E.ClassName + ': ' + E.Message;
      end;

      { Settled apart from the handler: a store that fails to record a job
        that ran is not a job that failed, and is not retried as one. A
        durable store's row stays reserved and is released after the
        visibility timeout. }
      try
        if Ok then
        begin
          InterLockedIncrement64(Int64(FQueue.FProcessed));
          Inc(FDone);
          FQueue.FStore.Complete(J);
        end
        else
        begin
          if Assigned(FQueue.FOnError) then
            FQueue.FOnError(J.Name, Err);
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
            FQueue.FStore.Fail(J, Err);
          end;
        end;
      except
        on E: Exception do
          StoreTrouble(FQueue, J.Name, E);
      end;
    finally
      UseArena(Prev);
      { After Complete, Retry or Fail: a retried job is back in the store
        before it stops being counted here. }
      InterLockedDecrement(FQueue.FBusy);
    end;
  end;
end;

initialization
  GBatchLock := TCriticalSection.Create;

finalization
  FreeAndNil(GBatchLock);

end.
