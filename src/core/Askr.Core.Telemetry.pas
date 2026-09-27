{ Askr.Core.Telemetry -- what happened, how long it took, to whoever asks.

  The framework says when a request, a query, a job or a mail is done:

      askr.request   method, route, path, status
      askr.query     sql, rows, and error when it failed
      askr.job       job, outcome, attempt
      askr.mail      transport, recipients, and error when it failed

  each with its duration in microseconds. A plugin names its own under its
  own prefix -- stripe.webhook -- and they go the same way. Something that
  wants them attaches to a prefix:

      AttachTelemetry('askr.query', @SlowQueries);

  The idea is Phoenix's :telemetry: the code that knows something happened
  says so once, and the log, a dashboard or a metrics exporter each listen
  without the code knowing any of them.

  **Nothing attached costs nothing.** TelemetryOn is a read of one
  integer, and the places that emit ask it before they read a clock or
  build a field. A server that nobody measures does no measuring.

  **A handler runs on the thread that emitted**, in the middle of a
  request or a job, so it has to be quick and has to be safe on any
  thread. Slow work -- sending the numbers somewhere -- belongs in a
  queue. **A handler that raises is logged and skipped**: a broken meter
  must not turn into a 500.

  **Fields never carry a value from a request or a secret.** The SQL is
  the statement with its placeholders, not its parameters; a mail says
  how many recipients, not who. A handler that needs more has the thing
  itself, where it runs. }
unit Askr.Core.Telemetry;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, SyncObjs, Askr.Core.Clock, Askr.Core.Log;

type
  TTelemetryEvent = record
    Name: string;
    DurationUs: Int64;
    { Key, value, key, value. }
    Fields: array of string;
    function Field(const Key: string): string;
  end;

  TTelemetryHandler = procedure(const E: TTelemetryEvent);

{ H hears every event whose name is Prefix or starts with Prefix and a
  dot: 'askr.query' hears askr.query, 'askr' hears everything the
  framework says, '' hears everything. }
procedure AttachTelemetry(const Prefix: string; H: TTelemetryHandler);
procedure DetachTelemetry(H: TTelemetryHandler);
{ Detaches everything. For tests. }
procedure ClearTelemetry;

{ Anybody listening. Ask before measuring. }
function TelemetryOn: Boolean; inline;
{ Now, on the clock durations are measured with, in microseconds: 0 when
  nobody is listening, so a start time of 0 means "not measured". }
function TelemetryStart: Int64;
{ Tells every handler whose prefix matches. Fields are key, value pairs. }
procedure EmitTelemetry(const Name: string; DurationUs: Int64;
  const Fields: array of string);
{ The same, with the duration taken from Started, a TelemetryStart. Does
  nothing when Started is 0. }
procedure EmitSince(const Name: string; Started: Int64;
  const Fields: array of string);

implementation

type
  TAttached = record
    Prefix: string;
    Handler: TTelemetryHandler;
  end;

var
  GLock: TCriticalSection;
  GAttached: array of TAttached;
  { Read without the lock, as a flag: a handler attached a moment ago may
    miss one event, and that is all a race here can cost. }
  GCount: Integer = 0;

function TTelemetryEvent.Field(const Key: string): string;
var
  I: Integer;
begin
  I := 0;
  while I < High(Fields) do
  begin
    if Fields[I] = Key then
      Exit(Fields[I + 1]);
    Inc(I, 2);
  end;
  Result := '';
end;

procedure AttachTelemetry(const Prefix: string; H: TTelemetryHandler);
begin
  GLock.Acquire;
  try
    SetLength(GAttached, Length(GAttached) + 1);
    GAttached[High(GAttached)].Prefix := Prefix;
    GAttached[High(GAttached)].Handler := H;
    GCount := Length(GAttached);
  finally
    GLock.Release;
  end;
end;

procedure DetachTelemetry(H: TTelemetryHandler);
var
  I, J: Integer;
begin
  GLock.Acquire;
  try
    J := 0;
    for I := 0 to High(GAttached) do
      if @GAttached[I].Handler <> @H then
      begin
        GAttached[J] := GAttached[I];
        Inc(J);
      end;
    SetLength(GAttached, J);
    GCount := J;
  finally
    GLock.Release;
  end;
end;

procedure ClearTelemetry;
begin
  GLock.Acquire;
  try
    GAttached := nil;
    GCount := 0;
  finally
    GLock.Release;
  end;
end;

function TelemetryOn: Boolean;
begin
  Result := GCount > 0;
end;

function TelemetryStart: Int64;
begin
  if GCount = 0 then
    Exit(0);
  Result := MonotonicUs;
  { A clock that reads 0 would look like "not measured". }
  if Result = 0 then
    Result := 1;
end;

function Matches(const Prefix, Name: string): Boolean;
begin
  if Prefix = '' then
    Exit(True);
  if Name = Prefix then
    Exit(True);
  Result := (Length(Name) > Length(Prefix)) and
    (Name[Length(Prefix) + 1] = '.') and
    (Copy(Name, 1, Length(Prefix)) = Prefix);
end;

procedure EmitTelemetry(const Name: string; DurationUs: Int64;
  const Fields: array of string);
var
  E: TTelemetryEvent;
  Snapshot: array of TAttached;
  I: Integer;
begin
  if GCount = 0 then
    Exit;
  E.Name := Name;
  E.DurationUs := DurationUs;
  SetLength(E.Fields, Length(Fields));
  for I := 0 to High(Fields) do
    E.Fields[I] := Fields[I];

  { A copy, so a handler that attaches or detaches -- or one that takes a
    while -- does not hold the lock every other thread needs. }
  GLock.Acquire;
  try
    Snapshot := Copy(GAttached);
  finally
    GLock.Release;
  end;

  for I := 0 to High(Snapshot) do
    if Matches(Snapshot[I].Prefix, Name) then
      try
        Snapshot[I].Handler(E);
      except
        on X: Exception do
          LogException(X, 'telemetry handler for ' + Name);
      end;
end;

procedure EmitSince(const Name: string; Started: Int64;
  const Fields: array of string);
begin
  if Started = 0 then
    Exit;
  EmitTelemetry(Name, MonotonicUs - Started, Fields);
end;

initialization
  GLock := TCriticalSection.Create;

finalization
  GLock.Free;

end.
