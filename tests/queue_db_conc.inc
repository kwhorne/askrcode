{ The durable queue under concurrency — shared by Postgres and MySQL.

  This is what SQLite cannot test. `SKIP LOCKED` exists only in Postgres
  and MySQL 8, and the one failure that matters here is two workers taking
  the same job. Then it runs twice, and that email is sent twice, or that
  payment taken twice.

  The file is included in both suites rather than written twice. Both have
  Start, Ok and LikeI with the same signature. }

var
  QueueLock: TRTLCriticalSection;
  QueueSet: array of Integer;   { how many times each job ran }
  QueueTotal: Integer;

procedure KoeJobb(const Ctx: TJobContext);
var
  N: Integer;
begin
  N := StrToIntDef(Ctx.Payload.ToString, -1);
  EnterCriticalSection(QueueLock);
  try
    if (N >= 0) and (N <= High(QueueSet)) then
      Inc(QueueSet[N]);
    Inc(QueueTotal);
  finally
    LeaveCriticalSection(QueueLock);
  end;
end;

var
  BatchRows, BatchDone, BatchAlways, BatchCaught: Integer;
  ChainLog: string;

procedure BatchRow(const Ctx: TJobContext);
begin
  if Ctx.Payload.ToString = 'bad' then
    raise Exception.Create('a bad row');
  InterLockedIncrement(BatchRows);
end;

procedure BatchCallback(const Ctx: TJobContext);
begin
  if Ctx.Name = 'batch-done' then
    InterLockedIncrement(BatchDone)
  else if Ctx.Name = 'batch-always' then
    InterLockedIncrement(BatchAlways)
  else if Ctx.Name = 'batch-caught' then
    InterLockedIncrement(BatchCaught);
end;

procedure ChainStep(const Ctx: TJobContext);
begin
  EnterCriticalSection(QueueLock);
  try
    ChainLog := ChainLog + Ctx.Payload.ToString;
  finally
    LeaveCriticalSection(QueueLock);
  end;
end;

{ Batches and a chain under six workers. The one thing that matters for a
  batch here: of the workers settling its last jobs at the same moment,
  exactly one finds it finished -- or the callbacks run twice, or never. }
procedure QueueFlows(const QueueDsn: string);
var
  Storage: TDbJobStore;
  Q: TQueue;
  B: TBatch;
  I: Integer;
  Id: string;
  S: TBatchState;
begin
  BatchRows := 0;
  BatchDone := 0;
  BatchAlways := 0;
  BatchCaught := 0;
  ChainLog := '';
  Storage := TDbJobStore.Create(QueueDsn, 8);
  Storage.Poll := 10;
  Storage.EnsureSchema;
  Q := TQueue.Create(Storage, 6, 1, True);
  try
    Q.Handle('batch-row', @BatchRow);
    Q.Handle('batch-done', @BatchCallback);
    Q.Handle('batch-always', @BatchCallback);
    Q.Handle('batch-caught', @BatchCallback);
    Q.Handle('chain-step', @ChainStep);
    B := Q.Batch('rows');
    for I := 1 to 200 do
      B := B.Add('batch-row', IntToStr(I));
    Id := B.OnSuccess('batch-done').Always('batch-always').Push;
    B := Q.Batch('some bad');
    for I := 1 to 40 do
      if I mod 5 = 0 then
        B := B.Add('batch-row', 'bad')
      else
        B := B.Add('batch-row', IntToStr(I));
    B.OnSuccess('batch-done').OnFailure('batch-caught').Always('batch-always').Push;
    Q.Chain.Add('chain-step', 'a').Add('chain-step', 'b').Add('chain-step', 'c')
      .Add('chain-step', 'd').Add('chain-step', 'e').Push;
    Q.Start;
    Ok('the batches and the chain drained', Q.WaitUntilEmpty(60000));
    Q.Stop(True);
    LikeI('every good row ran', 232, BatchRows);
    LikeI('OnSuccess once, for the batch with no bad rows', 1, BatchDone);
    LikeI('OnFailure once, not once per bad row', 1, BatchCaught);
    LikeI('Always once per batch', 2, BatchAlways);
    Ok('the table says the batch is done', Q.BatchStatus(Id, S) and (S.Pending = 0) and
      S.Finished and (S.Failed = 0));
    Ok('the chain ran in order, on six workers', ChainLog = 'abcde');
  finally
    Q.Free;
  end;
end;

procedure QueuePart(const QueueDsn: string);
const
  Jobs_ = 200;
var
  Storage: TDbJobStore;
  Q: TQueue;
  A: TArena;
  C: TDbConnection;
  I, RanTwice, Manglende: Integer;
begin
  Start('the durable queue');
  InitCriticalSection(QueueLock);
  A := TArena.Create(16 * 1024);
  try
    { Clean up from the previous run. The tables are the framework's own and
      have to survive between runs. }
    C := OpenDbConnection(QueueDsn);
    try
      try
        C.Exec(A, 'DROP TABLE IF EXISTS askr_jobs');
        C.Exec(A, 'DROP TABLE IF EXISTS askr_failed_jobs');
        C.Exec(A, 'DROP TABLE IF EXISTS askr_job_batches');
      except
        on EDbError do ;
      end;
    finally
      C.Free;
    end;

    Storage := TDbJobStore.Create(QueueDsn, 8);
    Storage.Poll := 10;
    Storage.EnsureSchema;

    { EnsureSchema has to be callable on every start-up. }
    Storage.EnsureSchema;
    Ok('EnsureSchema can be called twice', True);

    SetLength(QueueSet, Jobs_);
    for I := 0 to Jobs_ - 1 do
      QueueSet[I] := 0;
    QueueTotal := 0;

    Q := TQueue.Create(Storage, 6, 3, True);
    try
      Q.Handle('koe', @KoeJobb);
      for I := 0 to Jobs_ - 1 do
        Q.Push('koe', IntToStr(I));
      LikeI('alle jobbene ligger i tabellen', Jobs_, Q.Pending);

      Q.Start;
      Ok('the queue drained', Q.WaitUntilEmpty(60000));
      Sleep(300);
      Q.Stop(True);

      RanTwice := 0;
      Manglende := 0;
      EnterCriticalSection(QueueLock);
      try
        for I := 0 to Jobs_ - 1 do
        begin
          if QueueSet[I] > 1 then
            Inc(RanTwice);
          if QueueSet[I] = 0 then
            Inc(Manglende);
        end;
      finally
        LeaveCriticalSection(QueueLock);
      end;

      { The one failure that matters: six workers fighting over the same
        rows must not be able to hand the same job to two of them.

        Note what this test does **not** prove. Remove both
        `FOR UPDATE SKIP LOCKED` and the guard `AND reserved_at IS NULL`
        and it is still green — the window between SELECT and UPDATE is
        too narrow for it to hit. Put a Sleep(5) into that window and six
        jobs out of two hundred run twice. That has been tried.

        So the locks are shown to be necessary by widening the window,
        and that the reservation holds is shown deterministically in the
        SQLite part of askr_runtime_tests. This test shows that it works
        under real concurrency — not that each individual lock is
        indispensable. }
      LikeI('no job ran twice', 0, RanTwice);
      LikeI('and none was skipped', 0, Manglende);
      LikeI('every run is accounted for', Jobs_, QueueTotal);
      LikeI('the queue is empty', 0, Q.Pending);
      Ok('the queue knows it is durable', Q.Durable);
    finally
      Q.Free;
    end;
    QueueFlows(QueueDsn);
  finally
    A.Free;
    DoneCriticalSection(QueueLock);
  end;
end;
