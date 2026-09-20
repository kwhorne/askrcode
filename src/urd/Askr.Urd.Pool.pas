{ Askr.Urd.Pool — forbindelser som lånes ut og kommer tilbake av seg selv.

  Poolen ligger på heapen og overlever requests. Det følger av PRD-ens første
  regel: verdier som skal leve lenger enn requesten må ikke ligge i
  request-arenaen.

  Lease er poenget. En kontroller skriver

      C := Pool.Lease(Req.Arena);

  og er ferdig med det. Forbindelsen leveres tilbake når verten kaller
  Arena.Reset, gjennom Defer-mekanismen. Ingen try/finally, ingen glemte
  retur. To Lease på samme arena og samme pool gir den samme forbindelsen, så
  flere spørringer i én request deler transaksjon og tilstand.

  En forbindelse som kommer tilbake midt i en transaksjon rulles tilbake før
  den gjenbrukes. Alternativet — å la neste request arve en åpen transaksjon —
  er en feilkilde ingen finner igjen. }
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

    { Blokkerer til en forbindelse er ledig eller tiden er ute. Kalleren er
      ansvarlig for Release. Foretrekk Lease. }
    function Acquire(TimeoutMs: Integer = 5000): TDbConnection;
    procedure Release(C: TDbConnection);

    { Låner ut for resten av requesten. Leveres tilbake ved Arena.Reset. }
    function Lease(A: TArena): TDbConnection;

    { Åpner MaxConnections forbindelser med en gang, slik at første request
      ikke betaler for oppkoblingen. Kaster hvis databasen ikke svarer. }
    procedure Warmup;

    property Dsn: string read FDsn;
    property MaxConnections: Integer read FMax;
    property IdleCount: Integer read FIdleCount;
    { Åpne forbindelser totalt, ledige og utlånte. }
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
  { Nok til at én request kan snakke med flere databaser. Trengs det flere,
    er det et designproblem i appen, ikke i poolen. }
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
  { Slippes først, slik at et Release som kaster ikke etterlater en slot som
    peker på en forbindelse ingen eier. }
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
  { Auto-reset: én retur skal vekke én ventende tråd, ikke alle. }
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
    { Død forbindelse — kast den og prøv neste. }
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
        { Plassen reserveres før vi slipper låsen, ellers kan flere tråder
          åpne forbi grensen samtidig. }
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

  { En åpen transaksjon skal ikke arves av neste request. }
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
  { Frigjøres utenfor låsen — en destructor kan ta tid, og libpq lukker en
    socket her. }
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

  { Samme arena og samme pool skal gi samme forbindelse, slik at flere
    spørringer i én request deler transaksjon. }
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
