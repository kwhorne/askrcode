{ Askr.Queue — bakgrunnsjobber i samme prosess.

  PRD-ens andre regel: bakgrunnsjobber låner aldri requestens arena, de får
  en egen. Her er hvorfor den regelen ikke kan være en konvensjon.

  Når en kontroller gjør Push, lever payloaden i request-arenaen. Requesten
  er ferdig lenge før jobben kjører — arenaen er nullstilt, og minnet er delt
  ut til en ny request. Peker jobben dit, leser den en annen brukers data.

  Derfor er det to kopier på veien, og ingen av dem kan hoppes over:

    request-arena  ->  heap (i Push, mens kalleren fortsatt eier bytene)
                   ->  worker-arena (i workeren, før handleren kalles)

  Første kopi løsner jobben fra requesten. Andre gir handleren en payload med
  samme levetid som alt annet den jobber med, slik at den kan skrives på
  nøyaktig samme måte som en kontroller. Workeren nullstiller arenaen mellom
  hver jobb, som HTTP-workerne gjør mellom requests.

  Kø, scheduler og cache i samme prosess er hele poenget: ingen Redis, ingen
  Horizon, ingen supervisor ved siden av. }
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
    { Ligger i workerens arena. Dør når jobben er ferdig. }
    Payload: TStr;
    Attempt: Integer;
    Arena: TArena;
  end;

  TJobHandler = procedure(const Ctx: TJobContext);
  { Kalles når en jobb feiler eller forkastes. Egen type fordi en property
    ikke kan ha anonym prosedyretype. }
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

  { En jobb som er tatt ut av lageret og hører til én worker til den er
    gjort opp. Data eies av lageret; nøyaktig ett av Complete, Retry, Fail
    eller Drop skal kalles etterpå, og først da slippes den. }
  TReservedJob = record
    Name: string;
    Data: PByte;
    Len: SizeInt;
    Attempt: Integer;     { antall tidligere forsøk }
    Token: Pointer;       { lagerets eget håndtak }
    Id: Int64;            { lagerets id, 0 når det ikke har noen }
  end;

  { Hvor jobbene ligger. To implementasjoner: i prosessen, som før, og i en
    database.

    Grensesnittet finnes for at det skal være **én** utførelsesvei. Et eget
    worker-løp for varige jobber ville gitt to sett regler for backoff,
    forsøkstelling og arena-levetid, og de to ville drevet fra hverandre. }
  TJobStore = class abstract
  public
    { Bytene er kallerens og kopieres her. }
    procedure Push(const JobName: string; Data: PByte; Len: SizeInt;
      DelayMs: Int64); virtual; abstract;
    { Tar én jobb som er klar. False når det ikke finnes noen. }
    function Reserve(out J: TReservedJob): Boolean; virtual; abstract;
    procedure Complete(var J: TReservedJob); virtual; abstract;
    procedure Retry(var J: TReservedJob; DelayMs: Int64); virtual; abstract;
    { Oppbrukte forsøk. }
    procedure Fail(var J: TReservedJob; const Reason: string); virtual; abstract;
    { Ingen handler registrert — jobben kan aldri kjøre. }
    procedure Drop(var J: TReservedJob; const Reason: string); virtual; abstract;
    function Pending: Integer; virtual; abstract;
    { Overlever jobbene at prosessen starter på nytt? }
    function Durable: Boolean; virtual;
    { Hvor lenge en worker uten arbeid venter før den ser etter igjen. Et
      lager i prosessen vekkes av et signal og kan vente kort; et lager i
      en database må spørre, og da er 20 ms å hamre på den. }
    function PollIntervalMs: Integer; virtual;
  end;

  { Jobbene i en kjede i prosessen. Dette er oppførselen køen alltid har
    hatt, nå bak grensesnittet. }
  TMemoryJobStore = class(TJobStore)
  private
    FLock: TCriticalSection;
    FHead: PJob;
    FCount: Integer;
    procedure Insert_(J: PJob);
    procedure Slipp(var J: TReservedJob);
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
    { Navn til handler. En vanlig tabell med lineært søk, ikke TStringList
      med Objects: en prosedyrevariabel kan ikke castes til TObject i
      Delphi-modus uten at kompilatoren tolker den som et kall. Antall
      jobbtyper er uansett en håndfull. }
    FBindings: array of TJobBinding;
    FProcessed, FFailed, FRetried, FDropped: QWord;
    FOnError: TQueueErrorHandler;
    function HandlerFor(const JobName: string): TJobHandler;
    function IsRunning: Boolean;
  public
    constructor Create(AWorkers: Integer = 2;
      AMaxAttempts: Integer = 3); overload;
    { Med et eget lager. Køen overtar eieskapet når OwnsStore er satt. }
    constructor Create(AStore: TJobStore; AWorkers: Integer = 2;
      AMaxAttempts: Integer = 3; AOwnsStore: Boolean = True); overload;
    destructor Destroy; override;

    { Navnet kobles til en handler. Ukjente navn forkastes med telling. }
    procedure Handle(const JobName: string; H: TJobHandler);

    { Payloaden kopieres ut av kallerens arena her og nå. }
    procedure Push(const JobName: string; const Payload: TStr;
      DelaySeconds: Integer = 0); overload;
    procedure Push(const JobName, Payload: string;
      DelaySeconds: Integer = 0); overload;

    procedure Start;
    { Drain venter til køen er tom. Uten drain forkastes det som står igjen. }
    procedure Stop(Drain: Boolean = True);
    { Venter til køen er tom eller tiden er ute. Finnes for tester. }
    function WaitUntilEmpty(TimeoutMs: Integer): Boolean;

    function Pending: Integer;
    property Processed: QWord read FProcessed;
    property Failed: QWord read FFailed;
    property Retried: QWord read FRetried;
    property Dropped: QWord read FDropped;
    property Workers: Integer read FWorkerCount;
    property MaxAttempts: Integer read FMaxAttempts write FMaxAttempts;
    property OnError: TQueueErrorHandler read FOnError write FOnError;
    property Store: TJobStore read FStore;
    { Overlever jobbene en omstart? Til statusendepunkter og til å si fra i
      oppstartsloggen hva slags kø dette faktisk er. }
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
  { Her er grensen. Bytene kopieres mens kalleren fortsatt eier dem; om ett
    millisekund er request-arenaen nullstilt og minnet delt ut på nytt. }
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

procedure TMemoryJobStore.Slipp(var J: TReservedJob);
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
  Slipp(J);
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
  { Jobben er tilbake i kjeden og eies ikke lenger av workeren. }
  J.Token := nil;
  J.Data := nil;
  J.Len := 0;
  J.Name := '';
end;

procedure TMemoryJobStore.Fail(var J: TReservedJob; const Reason: string);
begin
  { En jobb som har brukt opp forsøkene sine forsvinner. Et lager i
    prosessen har ingen plass å legge den; det er nettopp forskjellen på
    dette og en varig kø. }
  Slipp(J);
end;

procedure TMemoryJobStore.Drop(var J: TReservedJob; const Reason: string);
begin
  Slipp(J);
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
begin
  { Lageret kopierer bytene mens kalleren fortsatt eier dem. Grensen ligger
    der og kan ikke hoppes over: om ett millisekund er request-arenaen
    nullstilt og minnet delt ut på nytt. }
  FStore.Push(JobName, Payload.Data, Payload.Len,
    Int64(DelaySeconds) * 1000);
  FSignal.SetEvent;
end;

procedure TQueue.Push(const JobName, Payload: string; DelaySeconds: Integer);
begin
  Push(JobName, Str(Payload), DelaySeconds);
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
    if Pending = 0 then
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

  { Det som står igjen ryddes av lageret, ikke her. For et lager i
    prosessen betyr det at jobbene forsvinner — det er derfor Stop uten
    Drain teller dem som forkastet. For et varig lager blir de liggende
    og kjøres neste gang appen starter, og det er hele poenget. }
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
  { Egen arena per worker, nullstilt mellom jobbene. Samme mønster som
    HTTP-workerne, og av samme grunn. }
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
    if not FQueue.FStore.Reserve(J) then
    begin
      { Venter på signal, men våkner uansett jevnlig: en forsinket jobb
        signaliserer ikke seg selv når tiden er inne, og en jobb lagt inn
        av en annen prosess signaliserer ikke i det hele tatt. }
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
      Continue;
    end;

    FArena.Reset;
    Prev := UseArena(FArena);
    try
      Ctx.Name := J.Name;
      Ctx.Attempt := J.Attempt + 1;
      Ctx.Arena := FArena;
      { Andre kopi: fra lagerets minne inn i workerens arena, slik at
        handleren kan skrives som en kontroller. }
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
            { Eksponentiell backoff, tak på 30 sekunder. }
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
    end;
  end;
end;

end.
