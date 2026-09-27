{ Askr.Core.Supervisor -- a thread that does not die in silence.

  A TThread whose Execute raises ends there. Free Pascal keeps the
  exception in FatalException, nobody reads it, and whatever the thread
  did stops being done: a scheduler that met a database gone for a moment
  pushes nothing again until the process restarts, and the log has no
  line about it.

  A TSupervisedThread puts its work in Run, and the thread around it is
  the supervisor -- the idea is Erlang's, as Phoenix inherits it:

      rpOnCrash   a crash is logged and Run starts again, after a backoff
                  that doubles from 100 ms to 30 s. The queue's workers
                  and the scheduler.
      rpNever     a crash is logged and the thread ends. A stream or a
                  websocket: the connection is gone with it, and the
                  browser reconnects on its own.

  Run returning is the thread done, not a crash. A thread restarts only
  while Wanted says so: Terminated by default, the queue's own running
  flag for a worker, so a Stop is never answered by a restart.

  **The backoff is reset by a run that lasted.** Thirty seconds without a
  crash, and the next one waits 100 ms again: a worker that fell over once
  a day is not made to wait the half-minute a crash loop earns.

  **Every crash is counted by the thread's name**, not by the thread, so
  a stream that crashed and was freed a minute ago is still in
  SupervisedThreads -- which the dashboard shows -- and hundreds of
  streams are one line. It is also an askr.thread event -- thread,
  outcome restarted or ended, error, restarts, in_ms -- with the
  exception's class and never its message, like the others. The log line
  has the message. }
unit Askr.Core.Supervisor;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, StrUtils, Classes, SyncObjs, Askr.Core.Clock, Askr.Core.Log,
  Askr.Core.Telemetry;

type
  TRestartPolicy = (rpOnCrash, rpNever);

  TSupervisedThread = class(TThread)
  private
    FName: string;
    FPolicy: TRestartPolicy;
    FRestarts: Integer;
    procedure Nap(Ms: Int64);
  protected
    { The work. Returning is done; raising is a crash. }
    procedure Run; virtual; abstract;
    { Whether a crash should be followed by a restart. Not Terminated,
      unless the owner keeps its own flag. }
    function Wanted: Boolean; virtual;
    procedure Execute; override;
  public
    constructor Create(const AName: string; APolicy: TRestartPolicy;
      ACreateSuspended: Boolean = False;
      AStackSize: SizeUInt = DefaultStackSize);
    property Name: string read FName;
    property Restarts: Integer read FRestarts;
  end;

  TSupervisedStat = record
    Name: string;
    { Alive now. }
    Running: Integer;
    Crashes, Restarts: Int64;
    { The class of the last crash's exception, and when, in unix seconds. }
    LastError: string;
    LastCrashAt: Int64;
  end;

{ One line per name, in the order the names were first seen. }
function SupervisedThreads: TArray<TSupervisedStat>;
{ Forgets the counts of every name no thread is running under. For tests. }
procedure ResetSupervisedThreads;
{ The backoff's first and longest wait, and how long a run must last to
  reset it, in milliseconds. For tests. }
procedure SetRestartBackoff(FirstMs, MaxMs: Integer; HealthyMs: Integer = 30000);

implementation

var
  GLock: TCriticalSection;
  GStats: TArray<TSupervisedStat>;
  GFirstMs: Integer = 100;
  GMaxMs: Integer = 30000;
  { A run this long was not a crash loop. }
  GHealthyMs: Integer = 30000;

function StatIndex(const Name: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(GStats) do
    if GStats[I].Name = Name then
      Exit(I);
  SetLength(GStats, Length(GStats) + 1);
  Result := High(GStats);
  GStats[Result].Name := Name;
end;

procedure Entered(const Name: string; Delta: Integer);
var
  I: Integer;
begin
  GLock.Acquire;
  try
    { The index first: StatIndex may grow the array, and GStats[StatIndex]
      would take the address of the old one before the call. }
    I := StatIndex(Name);
    Inc(GStats[I].Running, Delta);
  finally
    GLock.Release;
  end;
end;

procedure Crashed(const Name, ErrorClass: string; Restarting: Boolean);
var
  I: Integer;
begin
  GLock.Acquire;
  try
    I := StatIndex(Name);
    Inc(GStats[I].Crashes);
    if Restarting then
      Inc(GStats[I].Restarts);
    GStats[I].LastError := ErrorClass;
    GStats[I].LastCrashAt := UnixNow;
  finally
    GLock.Release;
  end;
end;

function SupervisedThreads: TArray<TSupervisedStat>;
begin
  GLock.Acquire;
  try
    Result := Copy(GStats);
  finally
    GLock.Release;
  end;
end;

procedure ResetSupervisedThreads;
var
  I, J: Integer;
begin
  GLock.Acquire;
  try
    J := 0;
    for I := 0 to High(GStats) do
      if GStats[I].Running > 0 then
      begin
        GStats[J] := GStats[I];
        GStats[J].Crashes := 0;
        GStats[J].Restarts := 0;
        GStats[J].LastError := '';
        GStats[J].LastCrashAt := 0;
        Inc(J);
      end;
    SetLength(GStats, J);
  finally
    GLock.Release;
  end;
end;

procedure SetRestartBackoff(FirstMs, MaxMs, HealthyMs: Integer);
begin
  GFirstMs := FirstMs;
  GMaxMs := MaxMs;
  GHealthyMs := HealthyMs;
end;

{ TSupervisedThread }

constructor TSupervisedThread.Create(const AName: string;
  APolicy: TRestartPolicy; ACreateSuspended: Boolean; AStackSize: SizeUInt);
begin
  FName := AName;
  FPolicy := APolicy;
  inherited Create(ACreateSuspended, AStackSize);
end;

function TSupervisedThread.Wanted: Boolean;
begin
  Result := not Terminated;
end;

{ In slices, asking Wanted between them: an owner that stops does not
  know this thread is waiting, and should not have to wait out the
  backoff before its WaitFor returns. }
procedure TSupervisedThread.Nap(Ms: Int64);
var
  Deadline: Int64;
begin
  Deadline := MonotonicMs + Ms;
  while Wanted and (MonotonicMs < Deadline) do
    Sleep(20);
end;

procedure TSupervisedThread.Execute;
var
  Backoff, Began: Int64;
  ErrorClass, Message_: string;
  Again: Boolean;
begin
  Entered(FName, 1);
  try
    Backoff := GFirstMs;
    repeat
      Began := MonotonicMs;
      try
        Run;
        Exit;
      except
        on E: Exception do
        begin
          ErrorClass := E.ClassName;
          Message_ := E.Message;
        end
        else
        begin
          { Raise of something that is not an Exception: rare, and still
            a crash. }
          ErrorClass := '(not an exception)';
          Message_ := '';
        end;
      end;

      Again := (FPolicy = rpOnCrash) and Wanted;
      if MonotonicMs - Began >= GHealthyMs then
        Backoff := GFirstMs;
      Crashed(FName, ErrorClass, Again);
      if Again then
      begin
        Inc(FRestarts);
        LogError('a thread crashed and will start again', ['thread', FName,
          'class', ErrorClass, 'error', Message_, 'restarts', FRestarts,
          'in_ms', Backoff]);
      end
      else
        LogError('a thread crashed', ['thread', FName, 'class', ErrorClass,
          'error', Message_]);
      if TelemetryOn then
        EmitTelemetry('askr.thread', 0, ['thread', FName,
          'outcome', IfThen(Again, 'restarted', 'ended'),
          'error', ErrorClass, 'restarts', IntToStr(FRestarts),
          'in_ms', IfThen(Again, IntToStr(Backoff), '')]);
      if not Again then
        Exit;

      Nap(Backoff);
      Backoff := Backoff * 2;
      if Backoff > GMaxMs then
        Backoff := GMaxMs;
    until not Wanted;
  finally
    Entered(FName, -1);
  end;
end;

initialization
  GLock := TCriticalSection.Create;

finalization
  GLock.Free;

end.
