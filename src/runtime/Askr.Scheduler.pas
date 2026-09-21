{ Askr.Scheduler — scheduled jobs in the same process.

  No crontab, no systemd timer, no supervisor. The scheduler is a thread
  that wakes every second, sees what is due, and pushes it onto the queue.
  The work itself is done by the queue workers, with their arenas — the
  scheduler never executes anything itself.

  That is a deliberate choice. A scheduler that also runs the jobs becomes
  a second execution path with its own lifetime rules, and then everything
  runnable has to be written for two worlds. Here there is only one.

  The expressions are deliberately simpler than cron. Cron syntax is
  compact to write and painful to read, and a schedule you have to decode
  in your head is a schedule that ends up wrong:

      Schedule.EveryMinutes(5, 'cleanup');
      Schedule.Hourly('fetch-rates');
      Schedule.DailyAt(3, 30, 'nightly');
      Schedule.WeeklyAt(dowMonday, 8, 0, 'weekly-report'); }
unit Askr.Scheduler;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs, Askr.Core.Clock, Askr.Queue;

type
  EScheduleError = class(Exception);

  TDayOfWeek = (dowSunday, dowMonday, dowTuesday, dowWednesday,
                dowThursday, dowFriday, dowSaturday);

  TScheduleKind = (skInterval, skDaily, skWeekly, skMonthly);

  TScheduleEntry = record
    JobName: string;
    Payload: string;
    Kind: TScheduleKind;
    { For skInterval: seconds between runs. }
    IntervalSec: Integer;
    Hour, Minute: Integer;
    Day: Integer;          { ukedag for skWeekly, dato for skMonthly }
    NextRun: Int64;        { unix-sekunder }
    LastRun: Int64;
    Runs: QWord;
    { Keeps a slow job from stacking on top of itself. }
    SkipIfPending: Boolean;
    Skipped: QWord;
  end;

  TScheduler = class
  private
    FQueue: TQueue;
    FLock: TCriticalSection;
    FEntries: array of TScheduleEntry;
    FThread: TThread;
    FRunning: LongInt;
    FTicks: QWord;
    FDispatched: QWord;
    function IsRunning: Boolean;
    procedure Add(const AJob, APayload: string; AKind: TScheduleKind;
      AInterval, AHour, AMinute, ADay: Integer);
    function NextAfter(const E: TScheduleEntry; FromUnix: Int64): Int64;
  public
    constructor Create(AQueue: TQueue);
    destructor Destroy; override;

    procedure EverySeconds(N: Integer; const JobName: string;
      const Payload: string = '');
    procedure EveryMinutes(N: Integer; const JobName: string;
      const Payload: string = '');
    procedure Hourly(const JobName: string; const Payload: string = '');
    procedure DailyAt(Hour, Minute: Integer; const JobName: string;
      const Payload: string = '');
    procedure WeeklyAt(Day: TDayOfWeek; Hour, Minute: Integer;
      const JobName: string; const Payload: string = '');
    procedure MonthlyAt(DayOfMonth, Hour, Minute: Integer;
      const JobName: string; const Payload: string = '');

    { Skips the run if a job with the same name is already waiting.
      Applies to the entry added last. }
    procedure SkipWhenPending;

    procedure Start;
    procedure Stop;
    { Runs one tick by hand. It exists for tests, which do not want to
      wait on the wall clock. }
    function Tick(NowUnix: Int64 = 0): Integer;

    procedure Describe(Lines: TStrings);
    function Count: Integer;
    property Ticks: QWord read FTicks;
    property Dispatched: QWord read FDispatched;
  end;

function Schedule: TScheduler;
procedure SetSchedule(AScheduler: TScheduler);

implementation

uses
  DateUtils;

var
  GSchedule: TScheduler = nil;

function Schedule: TScheduler;
begin
  if GSchedule = nil then
    raise EScheduleError.Create(
      'No scheduler is configured. Call SetSchedule at startup.');
  Result := GSchedule;
end;

procedure SetSchedule(AScheduler: TScheduler);
begin
  GSchedule := AScheduler;
end;

type
  TSchedulerThread = class(TThread)
  private
    FOwner: TScheduler;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TScheduler);
  end;

constructor TSchedulerThread.Create(AOwner: TScheduler);
begin
  FOwner := AOwner;
  inherited Create(False);
end;

procedure TSchedulerThread.Execute;
var
  NextAt: Int64;
begin
  while FOwner.IsRunning do
  begin
    FOwner.Tick;
    { Wakes on whole seconds. A scheduler with second resolution needs no
      finer granularity, and a whole second is cheap to wait. }
    NextAt := UnixNowMs;
    Sleep(1000 - (NextAt mod 1000));
  end;
end;

{ TScheduler }

constructor TScheduler.Create(AQueue: TQueue);
begin
  inherited Create;
  if AQueue = nil then
    raise EScheduleError.Create('The scheduler needs a queue to push to');
  FQueue := AQueue;
  FLock := TCriticalSection.Create;
end;

destructor TScheduler.Destroy;
begin
  Stop;
  FLock.Free;
  inherited Destroy;
end;

function TScheduler.IsRunning: Boolean;
begin
  Result := InterLockedExchangeAdd(FRunning, 0) <> 0;
end;

{ The next time after FromUnix. Computed in UTC, like everything else in
  Askr — local time would give two runs or none at a daylight-saving
  change. }
function TScheduler.NextAfter(const E: TScheduleEntry; FromUnix: Int64): Int64;
var
  D: TDateTime;
  Y, M, Dd: Word;
  Candidate: TDateTime;
  DayNow, Diff: Integer;
begin
  if E.Kind = skInterval then
    Exit(FromUnix + E.IntervalSec);

  D := UnixToDateTime(FromUnix);
  DecodeDate(D, Y, M, Dd);

  case E.Kind of
    skDaily:
      begin
        Candidate := EncodeDate(Y, M, Dd) + EncodeTime(E.Hour, E.Minute, 0, 0);
        if DateTimeToUnix(Candidate) <= FromUnix then
          Candidate := Candidate + 1;
      end;
    skWeekly:
      begin
        { DayOfWeek in FPC is 1 = Sunday. TDayOfWeek is 0 = Sunday. }
        DayNow := DayOfWeek(D) - 1;
        Diff := E.Day - DayNow;
        if Diff < 0 then
          Inc(Diff, 7);
        Candidate := EncodeDate(Y, M, Dd) + Diff +
          EncodeTime(E.Hour, E.Minute, 0, 0);
        if DateTimeToUnix(Candidate) <= FromUnix then
          Candidate := Candidate + 7;
      end;
    skMonthly:
      begin
        Candidate := EncodeDate(Y, M, 1) + EncodeTime(E.Hour, E.Minute, 0, 0);
        { A date that does not exist in the month — 31 February — is moved to
          the last day of the month rather than skipped. }
        Dd := E.Day;
        if Dd > DaysInMonth(Candidate) then
          Dd := DaysInMonth(Candidate);
        Candidate := EncodeDate(Y, M, Dd) + EncodeTime(E.Hour, E.Minute, 0, 0);
        if DateTimeToUnix(Candidate) <= FromUnix then
        begin
          Candidate := IncMonth(EncodeDate(Y, M, 1), 1);
          Dd := E.Day;
          if Dd > DaysInMonth(Candidate) then
            Dd := DaysInMonth(Candidate);
          DecodeDate(Candidate, Y, M, Dd);
          Candidate := EncodeDate(Y, M, Dd) + EncodeTime(E.Hour, E.Minute, 0, 0);
        end;
      end;
  else
    Exit(FromUnix + 60);
  end;
  Result := DateTimeToUnix(Candidate);
end;

procedure TScheduler.Add(const AJob, APayload: string; AKind: TScheduleKind;
  AInterval, AHour, AMinute, ADay: Integer);
var
  N: Integer;
begin
  FLock.Acquire;
  try
    N := Length(FEntries);
    SetLength(FEntries, N + 1);
    FEntries[N].JobName := AJob;
    FEntries[N].Payload := APayload;
    FEntries[N].Kind := AKind;
    FEntries[N].IntervalSec := AInterval;
    FEntries[N].Hour := AHour;
    FEntries[N].Minute := AMinute;
    FEntries[N].Day := ADay;
    FEntries[N].NextRun := NextAfter(FEntries[N], UnixNow);
  finally
    FLock.Release;
  end;
end;

procedure TScheduler.EverySeconds(N: Integer; const JobName, Payload: string);
begin
  if N < 1 then
    raise EScheduleError.Create('The interval must be at least one second');
  Add(JobName, Payload, skInterval, N, 0, 0, 0);
end;

procedure TScheduler.EveryMinutes(N: Integer; const JobName, Payload: string);
begin
  EverySeconds(N * 60, JobName, Payload);
end;

procedure TScheduler.Hourly(const JobName, Payload: string);
begin
  EverySeconds(3600, JobName, Payload);
end;

procedure TScheduler.DailyAt(Hour, Minute: Integer;
  const JobName, Payload: string);
begin
  Add(JobName, Payload, skDaily, 0, Hour, Minute, 0);
end;

procedure TScheduler.WeeklyAt(Day: TDayOfWeek; Hour, Minute: Integer;
  const JobName, Payload: string);
begin
  Add(JobName, Payload, skWeekly, 0, Hour, Minute, Ord(Day));
end;

procedure TScheduler.MonthlyAt(DayOfMonth, Hour, Minute: Integer;
  const JobName, Payload: string);
begin
  Add(JobName, Payload, skMonthly, 0, Hour, Minute, DayOfMonth);
end;

procedure TScheduler.SkipWhenPending;
begin
  FLock.Acquire;
  try
    if Length(FEntries) = 0 then
      raise EScheduleError.Create('SkipWhenPending with no entry');
    FEntries[High(FEntries)].SkipIfPending := True;
  finally
    FLock.Release;
  end;
end;

function TScheduler.Tick(NowUnix: Int64): Integer;
var
  I: Integer;
  Now_: Int64;
begin
  Result := 0;
  if NowUnix = 0 then
    Now_ := UnixNow
  else
    Now_ := NowUnix;

  Inc(FTicks);
  FLock.Acquire;
  try
    for I := 0 to High(FEntries) do
    begin
      if FEntries[I].NextRun > Now_ then
        Continue;

      { A job already waiting must not stack. Without this the queue grows
        without bound when the job is slower than the interval. }
      if FEntries[I].SkipIfPending and (FQueue.Pending > 0) then
      begin
        Inc(FEntries[I].Skipped);
        FEntries[I].NextRun := NextAfter(FEntries[I], Now_);
        Continue;
      end;

      FQueue.Push(FEntries[I].JobName, FEntries[I].Payload);
      FEntries[I].LastRun := Now_;
      Inc(FEntries[I].Runs);
      Inc(FDispatched);
      Inc(Result);
      FEntries[I].NextRun := NextAfter(FEntries[I], Now_);
    end;
  finally
    FLock.Release;
  end;
end;

procedure TScheduler.Start;
begin
  if IsRunning then
    Exit;
  InterLockedExchange(FRunning, 1);
  FThread := TSchedulerThread.Create(Self);
end;

procedure TScheduler.Stop;
begin
  if InterLockedExchange(FRunning, 0) = 0 then
    Exit;
  if FThread <> nil then
  begin
    FThread.WaitFor;
    FThread.Free;
    FThread := nil;
  end;
end;

procedure TScheduler.Describe(Lines: TStrings);
var
  I: Integer;
  When_: string;
  E: TScheduleEntry;
begin
  FLock.Acquire;
  try
    for I := 0 to High(FEntries) do
    begin
      E := FEntries[I];
      case E.Kind of
        skInterval:
          if E.IntervalSec mod 3600 = 0 then
            When_ := Format('every %d hours', [E.IntervalSec div 3600])
          else if E.IntervalSec mod 60 = 0 then
            When_ := Format('every %d minutes', [E.IntervalSec div 60])
          else
            When_ := Format('every %d seconds', [E.IntervalSec]);
        skDaily:   When_ := Format('daily at %.2d:%.2d', [E.Hour, E.Minute]);
        skWeekly:  When_ := Format('weekly on day %d at %.2d:%.2d',
                     [E.Day, E.Hour, E.Minute]);
        skMonthly: When_ := Format('monthly on the %dth at %.2d:%.2d',
                     [E.Day, E.Hour, E.Minute]);
      end;
      Lines.Add(Format('%-22s %-28s next: %s', [E.JobName, When_,
        FormatDateTime('yyyy-mm-dd hh:nn:ss', UnixToDateTime(E.NextRun))]));
    end;
  finally
    FLock.Release;
  end;
end;

function TScheduler.Count: Integer;
begin
  FLock.Acquire;
  try
    Result := Length(FEntries);
  finally
    FLock.Release;
  end;
end;

end.
