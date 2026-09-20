{ Askr.Scheduler — planlagte jobber i samme prosess.

  Ingen crontab, ingen systemd-timer, ingen supervisor. Scheduleren er en
  tråd som våkner hvert sekund, ser hva som er forfalt, og dytter det på
  køen. Selve arbeidet gjøres av køworkerne, med deres arenaer — scheduleren
  utfører aldri noe selv.

  Det er et bevisst valg. En scheduler som også kjører jobbene blir en andre
  utførelsesvei med egne levetidsregler, og da må alt som kan kjøres skrives
  for to verdener. Her finnes det bare én.

  Uttrykkene er bevisst enklere enn cron. Cron-syntaks er kompakt å skrive og
  vond å lese, og en plan man må dekode i hodet er en plan som blir feil:

      Schedule.EveryMinutes(5, 'rydd-opp');
      Schedule.Hourly('hent-kurser');
      Schedule.DailyAt(3, 30, 'nattjobb');
      Schedule.WeeklyAt(dowMonday, 8, 0, 'ukesrapport'); }
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
    { For skInterval: sekunder mellom kjøringer. }
    IntervalSec: Integer;
    Hour, Minute: Integer;
    Day: Integer;          { ukedag for skWeekly, dato for skMonthly }
    NextRun: Int64;        { unix-sekunder }
    LastRun: Int64;
    Runs: QWord;
    { Hindrer at en treg jobb stables oppå seg selv. }
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

    { Hopper over kjøringen hvis en jobb med samme navn allerede venter.
      Gjelder oppføringen som ble lagt til sist. }
    procedure SkipWhenPending;

    procedure Start;
    procedure Stop;
    { Kjører ett tikk manuelt. Finnes for tester, som ikke vil vente på
      veggklokka. }
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
  Neste: Int64;
begin
  while FOwner.IsRunning do
  begin
    FOwner.Tick;
    { Våkner på hele sekunder. En scheduler med sekundoppløsning trenger
      ikke finere granularitet, og et helt sekund er billig å vente. }
    Neste := UnixNowMs;
    Sleep(1000 - (Neste mod 1000));
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

{ Neste tidspunkt etter FromUnix. Regnes i UTC, som alt annet i Askr —
  lokaltid ville gitt to kjøringer eller null ved sommertidsskifte. }
function TScheduler.NextAfter(const E: TScheduleEntry; FromUnix: Int64): Int64;
var
  D: TDateTime;
  Y, M, Dd: Word;
  Kandidat: TDateTime;
  DagNaa, Diff: Integer;
begin
  if E.Kind = skInterval then
    Exit(FromUnix + E.IntervalSec);

  D := UnixToDateTime(FromUnix);
  DecodeDate(D, Y, M, Dd);

  case E.Kind of
    skDaily:
      begin
        Kandidat := EncodeDate(Y, M, Dd) + EncodeTime(E.Hour, E.Minute, 0, 0);
        if DateTimeToUnix(Kandidat) <= FromUnix then
          Kandidat := Kandidat + 1;
      end;
    skWeekly:
      begin
        { DayOfWeek i FPC er 1 = søndag. TDayOfWeek er 0 = søndag. }
        DagNaa := DayOfWeek(D) - 1;
        Diff := E.Day - DagNaa;
        if Diff < 0 then
          Inc(Diff, 7);
        Kandidat := EncodeDate(Y, M, Dd) + Diff +
          EncodeTime(E.Hour, E.Minute, 0, 0);
        if DateTimeToUnix(Kandidat) <= FromUnix then
          Kandidat := Kandidat + 7;
      end;
    skMonthly:
      begin
        Kandidat := EncodeDate(Y, M, 1) + EncodeTime(E.Hour, E.Minute, 0, 0);
        { En dato som ikke finnes i måneden — 31. februar — skyves til
          siste dag i måneden i stedet for å hoppes over. }
        Dd := E.Day;
        if Dd > DaysInMonth(Kandidat) then
          Dd := DaysInMonth(Kandidat);
        Kandidat := EncodeDate(Y, M, Dd) + EncodeTime(E.Hour, E.Minute, 0, 0);
        if DateTimeToUnix(Kandidat) <= FromUnix then
        begin
          Kandidat := IncMonth(EncodeDate(Y, M, 1), 1);
          Dd := E.Day;
          if Dd > DaysInMonth(Kandidat) then
            Dd := DaysInMonth(Kandidat);
          DecodeDate(Kandidat, Y, M, Dd);
          Kandidat := EncodeDate(Y, M, Dd) + EncodeTime(E.Hour, E.Minute, 0, 0);
        end;
      end;
  else
    Exit(FromUnix + 60);
  end;
  Result := DateTimeToUnix(Kandidat);
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
  Naa: Int64;
begin
  Result := 0;
  if NowUnix = 0 then
    Naa := UnixNow
  else
    Naa := NowUnix;

  Inc(FTicks);
  FLock.Acquire;
  try
    for I := 0 to High(FEntries) do
    begin
      if FEntries[I].NextRun > Naa then
        Continue;

      { En jobb som allerede venter skal ikke stables. Uten dette vokser
        køen i det uendelige når jobben er tregere enn intervallet. }
      if FEntries[I].SkipIfPending and (FQueue.Pending > 0) then
      begin
        Inc(FEntries[I].Skipped);
        FEntries[I].NextRun := NextAfter(FEntries[I], Naa);
        Continue;
      end;

      FQueue.Push(FEntries[I].JobName, FEntries[I].Payload);
      FEntries[I].LastRun := Naa;
      Inc(FEntries[I].Runs);
      Inc(FDispatched);
      Inc(Result);
      FEntries[I].NextRun := NextAfter(FEntries[I], Naa);
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
  Naar: string;
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
            Naar := Format('hver %d. time', [E.IntervalSec div 3600])
          else if E.IntervalSec mod 60 = 0 then
            Naar := Format('hvert %d. minutt', [E.IntervalSec div 60])
          else
            Naar := Format('hvert %d. sekund', [E.IntervalSec]);
        skDaily:   Naar := Format('daglig %.2d:%.2d', [E.Hour, E.Minute]);
        skWeekly:  Naar := Format('ukentlig dag %d %.2d:%.2d',
                     [E.Day, E.Hour, E.Minute]);
        skMonthly: Naar := Format('månedlig den %d. %.2d:%.2d',
                     [E.Day, E.Hour, E.Minute]);
      end;
      Lines.Add(Format('%-22s %-28s neste: %s', [E.JobName, Naar,
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
