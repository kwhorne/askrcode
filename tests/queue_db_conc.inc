{ Varig kø under samtidighet — felles for Postgres og MySQL.

  Dette er det SQLite ikke kan teste. `SKIP LOCKED` finnes bare i Postgres
  og MySQL 8, og den ene feilen som betyr noe her er at to workere tar den
  samme jobben. Da kjører den to ganger, og den e-posten blir sendt to
  ganger, eller den betalingen trukket to ganger.

  Fila inkluderes i begge suitene i stedet for å skrives to ganger. Begge
  har Start, Ok og LikeI med samme signatur. }

var
  QueueLock: TRTLCriticalSection;
  QueueSet: array of Integer;   { hvor mange ganger hver jobb kjørte }
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
  I, Dobbelt, Manglende: Integer;
begin
  Start('varig kø');
  InitCriticalSection(QueueLock);
  A := TArena.Create(16 * 1024);
  try
    { Rydd fra forrige kjøring. Tabellene er rammeverkets egne og skal
      kunne stå mellom kjøringer. }
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

    { EnsureSchema skal kunne kalles ved hver oppstart. }
    Storage.EnsureSchema;
    Ok('EnsureSchema kan kalles to ganger', True);

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
      Ok('køen ble tom', Q.WaitUntilEmpty(60000));
      Sleep(300);
      Q.Stop(True);

      Dobbelt := 0;
      Manglende := 0;
      EnterCriticalSection(QueueLock);
      try
        for I := 0 to Jobs_ - 1 do
        begin
          if QueueSet[I] > 1 then
            Inc(Dobbelt);
          if QueueSet[I] = 0 then
            Inc(Manglende);
        end;
      finally
        LeaveCriticalSection(QueueLock);
      end;

      { Den ene feilen som betyr noe: seks workere som slåss om de samme
        radene skal ikke kunne gi den samme jobben til to av dem.

        Merk hva denne testen **ikke** beviser. Fjerner man både
        `FOR UPDATE SKIP LOCKED` og vakten `AND reserved_at IS NULL`, er
        den fortsatt grønn — vinduet mellom SELECT og UPDATE er for smalt
        til at den treffer det. Legger man en Sleep(5) inn i det vinduet,
        kjører seks av to hundre jobber dobbelt. Det er prøvd.

        At sperrene er nødvendige, er altså vist ved å utvide vinduet, og
        at reservasjonen holder er vist deterministisk i SQLite-delen av
        askr_runtime_tests. Denne testen viser at det virker under ekte
        samtidighet — ikke at hver enkelt sperre er uunnværlig. }
      LikeI('ingen jobb kjørte to ganger', 0, Dobbelt);
      LikeI('og ingen ble hoppet over', 0, Manglende);
      LikeI('alle kjøringene er talt', Jobs_, QueueTotal);
      LikeI('køen er tom', 0, Q.Pending);
      Ok('køen vet at den er varig', Q.Durable);
    finally
      Q.Free;
    end;
  finally
    A.Free;
    DoneCriticalSection(QueueLock);
  end;
end;
