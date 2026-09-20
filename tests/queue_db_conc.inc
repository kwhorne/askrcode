{ Varig kø under samtidighet — felles for Postgres og MySQL.

  Dette er det SQLite ikke kan teste. `SKIP LOCKED` finnes bare i Postgres
  og MySQL 8, og den ene feilen som betyr noe her er at to workere tar den
  samme jobben. Da kjører den to ganger, og den e-posten blir sendt to
  ganger, eller den betalingen trukket to ganger.

  Fila inkluderes i begge suitene i stedet for å skrives to ganger. Begge
  har Start, Ok og LikeI med samme signatur. }

var
  KoeLaas: TRTLCriticalSection;
  KoeSett: array of Integer;   { hvor mange ganger hver jobb kjørte }
  KoeTotalt: Integer;

procedure KoeJobb(const Ctx: TJobContext);
var
  N: Integer;
begin
  N := StrToIntDef(Ctx.Payload.ToString, -1);
  EnterCriticalSection(KoeLaas);
  try
    if (N >= 0) and (N <= High(KoeSett)) then
      Inc(KoeSett[N]);
    Inc(KoeTotalt);
  finally
    LeaveCriticalSection(KoeLaas);
  end;
end;

procedure KoeDelen(const KoeDsn: string);
const
  Jobber = 200;
var
  Lager: TDbJobStore;
  Q: TQueue;
  A: TArena;
  C: TDbConnection;
  I, Dobbelt, Manglende: Integer;
begin
  Start('varig kø');
  InitCriticalSection(KoeLaas);
  A := TArena.Create(16 * 1024);
  try
    { Rydd fra forrige kjøring. Tabellene er rammeverkets egne og skal
      kunne stå mellom kjøringer. }
    C := OpenDbConnection(KoeDsn);
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

    Lager := TDbJobStore.Create(KoeDsn, 8);
    Lager.Poll := 10;
    Lager.EnsureSchema;

    { EnsureSchema skal kunne kalles ved hver oppstart. }
    Lager.EnsureSchema;
    Ok('EnsureSchema kan kalles to ganger', True);

    SetLength(KoeSett, Jobber);
    for I := 0 to Jobber - 1 do
      KoeSett[I] := 0;
    KoeTotalt := 0;

    Q := TQueue.Create(Lager, 6, 3, True);
    try
      Q.Handle('koe', @KoeJobb);
      for I := 0 to Jobber - 1 do
        Q.Push('koe', IntToStr(I));
      LikeI('alle jobbene ligger i tabellen', Jobber, Q.Pending);

      Q.Start;
      Ok('køen ble tom', Q.WaitUntilEmpty(60000));
      Sleep(300);
      Q.Stop(True);

      Dobbelt := 0;
      Manglende := 0;
      EnterCriticalSection(KoeLaas);
      try
        for I := 0 to Jobber - 1 do
        begin
          if KoeSett[I] > 1 then
            Inc(Dobbelt);
          if KoeSett[I] = 0 then
            Inc(Manglende);
        end;
      finally
        LeaveCriticalSection(KoeLaas);
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
      LikeI('alle kjøringene er talt', Jobber, KoeTotalt);
      LikeI('køen er tom', 0, Q.Pending);
      Ok('køen vet at den er varig', Q.Durable);
    finally
      Q.Free;
    end;
  finally
    A.Free;
    DoneCriticalSection(KoeLaas);
  end;
end;
