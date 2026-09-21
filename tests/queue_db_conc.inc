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
  finally
    A.Free;
    DoneCriticalSection(QueueLock);
  end;
end;
