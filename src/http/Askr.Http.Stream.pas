{ Askr.Http.Stream — server-sent events.

      // the route
      function TFeed.Open(Req: TRequest): TResponse;
      begin
        Authorize('see-orders');
        Result := StreamEvents(['orders', 'user.' + Askr.Auth.Id]);
      end;

      // anywhere: a handler, a job, the scheduler
      Broadcast('orders', 'placed', '{"id":42}');

      // the browser
      new EventSource('/feed').addEventListener('placed', e => ...)

  A stream is a response that does not end: the server keeps the
  connection and writes an event down it whenever one is broadcast on a
  channel it listens to. The browser's EventSource reconnects by itself
  and says which event it saw last, and the ones it missed are sent again.

  **A stream does not hold a worker.** The server's workers each follow one
  connection from start to finish, and a stream open for an hour would hold
  one for the hour -- a few hundred open tabs would stop the server. So the
  worker writes the head and hands the socket to a thread of the stream's
  own, and goes back to serving requests. A thread per open stream is fine
  for hundreds; for tens of thousands of open connections, put something
  built for it in front.

  **The handler decides who hears what.** StreamEvents takes the channels,
  after the route's own checks -- a channel per user is how one user's
  events stay theirs.

  A comment line goes down every open stream every fifteen seconds. It
  keeps a proxy from closing a quiet connection, and it is how a stream
  whose browser went away finds out: the write fails. }
unit Askr.Http.Stream;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs, Sockets, BaseUnix,
  Askr.Core.Arena, Askr.Core.Text, Askr.Http.Response, Askr.Tls;

type
  EStreamError = class(Exception);

{ The response that opens a stream on these channels: letters, digits and
  . _ : - in a name. Raises on one that is not. }
function StreamEvents(const Channels: array of string): TResponse;
{ Sends an event to every stream on Channel, and keeps it for a stream
  that reconnects. Data may have line breaks; each becomes a data line. }
procedure Broadcast(const Channel, Event, Data: string);
function OpenStreams: Integer;

{ How often an idle stream gets its comment line. 15 seconds unless set. }
procedure SetStreamHeartbeat(Ms: Integer);
{ How many streams may be open at once; one more is answered 503. 1000
  unless set. }
procedure SetMaxStreams(N: Integer);
{ How many recent events are kept for streams that reconnect with
  Last-Event-ID. 500 unless set. }
procedure SetStreamReplay(N: Integer);

type
  { Something else Broadcast reaches: Askr.Http.WebSocket registers one,
    so a websocket on a channel hears what a stream on it hears, without
    this unit knowing what a websocket is. }
  TBroadcastSink = procedure(Id: Int64; const Channel, Event, Data: string);

procedure AddBroadcastSink(Sink: TBroadcastSink);

{ The server's side. }
function StreamSlotFree: Boolean;
{ Takes over the socket and the TLS connection, if there is one: the
  stream thread closes both. The head has been written. }
procedure StartStream(Sock: TSocket; Tls: TTlsConn;
  const Channels, LastEventId: string);
{ Closes every stream and waits a little for their threads. }
procedure StopStreams;

implementation

type
  TStreamThread = class(TThread)
  private
    FSock: TSocket;
    FTls: TTlsConn;
    FChannels: TStringList;
    FPending: TStringList;
    FSignal: TSimpleEvent;
    FLastId: Int64;
    function Send(const S: string): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(ASock: TSocket; ATls: TTlsConn;
      const AChannels: string; ALastId: Int64);
    destructor Destroy; override;
    function Listens(const Channel: string): Boolean;
    procedure Post(const Text_: string);
    procedure Wake;
  end;

  THistoryEntry = record
    Id: Int64;
    Channel: string;
    Text_: string;
  end;

var
  GLock: TCriticalSection;
  GStreams: TList;
  GSinks: array of TBroadcastSink;
  GHistory: array of THistoryEntry;
  GNextId: Int64 = 0;
  GStopping: Boolean = False;
  GHeartbeatMs: Integer = 15000;
  GMaxStreams: Integer = 1000;
  GReplay: Integer = 500;

procedure AddBroadcastSink(Sink: TBroadcastSink);
var
  I: Integer;
begin
  I := Length(GSinks);
  SetLength(GSinks, I + 1);
  GSinks[I] := Sink;
end;

procedure SetStreamHeartbeat(Ms: Integer);
begin
  GHeartbeatMs := Ms;
end;

procedure SetMaxStreams(N: Integer);
begin
  GMaxStreams := N;
end;

procedure SetStreamReplay(N: Integer);
begin
  GReplay := N;
end;

function ValidChannel(const S: string): Boolean;
var
  I: Integer;
begin
  Result := S <> '';
  for I := 1 to Length(S) do
    if not (S[I] in ['A'..'Z', 'a'..'z', '0'..'9', '.', '_', ':', '-']) then
      Exit(False);
end;

function StreamEvents(const Channels: array of string): TResponse;
var
  I: Integer;
  All: string;
begin
  if Length(Channels) = 0 then
    raise EStreamError.Create('A stream needs at least one channel');
  All := '';
  for I := 0 to High(Channels) do
  begin
    if not ValidChannel(Channels[I]) then
      raise EStreamError.CreateFmt('"%s" is not a channel name: letters, digits ' +
        'and . _ : - only', [Channels[I]]);
    if All <> '' then
      All := All + ',';
    All := All + Channels[I];
  end;
  Result := Respond(200)
    .WithHeader('Content-Type', 'text/event-stream; charset=utf-8')
    { no-transform: a proxy that compresses would hold the events back to
      fill a block. }
    .WithHeader('Cache-Control', 'no-cache, no-transform')
    { nginx buffers a response unless told not to, and an event that
      waits for a buffer to fill is not an event. }
    .WithHeader('X-Accel-Buffering', 'no');
  Result.MarkEventStream(StrDup(CurrentArena, All));
end;

{ One event as the stream writes it. A line break in the data splits it
  into data lines, which EventSource joins again with \n; a CR alone would
  otherwise end a line early on the way. }
function Frame(Id: Int64; const Event, Data: string): string;
var
  D: string;
  L: TStringList;
  I: Integer;
begin
  Result := 'id: ' + IntToStr(Id) + #10;
  if Event <> '' then
    Result := Result + 'event: ' + StringReplace(StringReplace(Event, #13, '', [rfReplaceAll]),
      #10, '', [rfReplaceAll]) + #10;
  D := StringReplace(StringReplace(Data, #13#10, #10, [rfReplaceAll]), #13, #10, [rfReplaceAll]);
  L := TStringList.Create;
  try
    L.StrictDelimiter := True;
    L.Delimiter := #10;
    L.DelimitedText := D;
    if L.Count = 0 then
      Result := Result + 'data: ' + #10
    else
      for I := 0 to L.Count - 1 do
        Result := Result + 'data: ' + L[I] + #10;
  finally
    L.Free;
  end;
  Result := Result + #10;
end;

procedure Broadcast(const Channel, Event, Data: string);
var
  I, N: Integer;
  Text_: string;
  Id: Int64;
begin
  if not ValidChannel(Channel) then
    raise EStreamError.CreateFmt('"%s" is not a channel name', [Channel]);
  GLock.Acquire;
  try
    Inc(GNextId);
    Id := GNextId;
    Text_ := Frame(Id, Event, Data);
    { Kept for a stream that reconnects, the oldest going first. }
    N := Length(GHistory);
    if (GReplay > 0) and (N >= GReplay) then
    begin
      for I := 1 to N - 1 do
        GHistory[I - 1] := GHistory[I];
      Dec(N);
      SetLength(GHistory, N);
    end;
    if GReplay > 0 then
    begin
      SetLength(GHistory, N + 1);
      GHistory[N].Id := Id;
      GHistory[N].Channel := Channel;
      GHistory[N].Text_ := Text_;
    end;
    for I := 0 to GStreams.Count - 1 do
      if TStreamThread(GStreams[I]).Listens(Channel) then
        TStreamThread(GStreams[I]).Post(Text_);
  finally
    GLock.Release;
  end;
  { Outside the lock: a sink takes locks of its own. }
  for I := 0 to High(GSinks) do
    GSinks[I](Id, Channel, Event, Data);
end;

function OpenStreams: Integer;
begin
  GLock.Acquire;
  try
    Result := GStreams.Count;
  finally
    GLock.Release;
  end;
end;

function StreamSlotFree: Boolean;
begin
  Result := (not GStopping) and (OpenStreams < GMaxStreams);
end;

procedure StartStream(Sock: TSocket; Tls: TTlsConn;
  const Channels, LastEventId: string);
var
  T: TStreamThread;
  I: Integer;
  Last: Int64;
begin
  Last := StrToInt64Def(Trim(LastEventId), 0);
  T := TStreamThread.Create(Sock, Tls, Channels, Last);
  GLock.Acquire;
  try
    GStreams.Add(T);
    { What it missed, in order, before anything new: under the lock, so a
      broadcast cannot come between the replay and the stream joining. }
    if Last > 0 then
      for I := 0 to High(GHistory) do
        if (GHistory[I].Id > Last) and T.Listens(GHistory[I].Channel) then
          T.Post(GHistory[I].Text_);
  finally
    GLock.Release;
  end;
  T.Start;
end;

procedure StopStreams;
var
  I, Waited: Integer;
begin
  GLock.Acquire;
  try
    GStopping := True;
    for I := 0 to GStreams.Count - 1 do
      TStreamThread(GStreams[I]).Wake;
  finally
    GLock.Release;
  end;
  Waited := 0;
  while (OpenStreams > 0) and (Waited < 2000) do
  begin
    Sleep(10);
    Inc(Waited, 10);
  end;
  GLock.Acquire;
  try
    GStopping := False;
  finally
    GLock.Release;
  end;
end;

{ TStreamThread }

constructor TStreamThread.Create(ASock: TSocket; ATls: TTlsConn;
  const AChannels: string; ALastId: Int64);
begin
  FSock := ASock;
  FTls := ATls;
  FLastId := ALastId;
  FChannels := TStringList.Create;
  FChannels.StrictDelimiter := True;
  FChannels.Delimiter := ',';
  FChannels.DelimitedText := AChannels;
  FPending := TStringList.Create;
  FSignal := TSimpleEvent.Create;
  FreeOnTerminate := True;
  { A small stack: a stream waits and writes, and hundreds of them should
    not cost hundreds of default stacks. }
  inherited Create(True, 256 * 1024);
end;

destructor TStreamThread.Destroy;
begin
  FSignal.Free;
  FPending.Free;
  FChannels.Free;
  inherited Destroy;
end;

function TStreamThread.Listens(const Channel: string): Boolean;
begin
  Result := FChannels.IndexOf(Channel) >= 0;
end;

{ Under GLock, from Broadcast and StartStream. }
procedure TStreamThread.Post(const Text_: string);
begin
  FPending.Add(Text_);
  FSignal.SetEvent;
end;

procedure TStreamThread.Wake;
begin
  FSignal.SetEvent;
end;

function TStreamThread.Send(const S: string): Boolean;
var
  Sent, N: Integer;
begin
  if S = '' then
    Exit(True);
  if FTls <> nil then
    Exit(FTls.WriteAll(@S[1], Length(S)));
  Sent := 0;
  while Sent < Length(S) do
  begin
    { SIGPIPE is ignored by the server, so a closed peer is an error
      here, not a dead process -- as in the worker's own SendAll. }
    N := fpSend(FSock, @S[Sent + 1], Length(S) - Sent, 0);
    if N < 0 then
    begin
      if fpGetErrno = ESysEINTR then
        Continue;
      Exit(False);
    end;
    if N = 0 then
      Exit(False);
    Inc(Sent, N);
  end;
  Result := True;
end;

procedure TStreamThread.Execute;
var
  Batch: string;
  I: Integer;
begin
  try
    { How long EventSource waits before it reconnects, in milliseconds. }
    if not Send('retry: 3000' + #10#10) then
      Exit;
    while not Terminated do
    begin
      Batch := '';
      GLock.Acquire;
      try
        if GStopping then
          Break;
        for I := 0 to FPending.Count - 1 do
          Batch := Batch + FPending[I];
        FPending.Clear;
        FSignal.ResetEvent;
      finally
        GLock.Release;
      end;
      if Batch <> '' then
      begin
        if not Send(Batch) then
          Break;
        Continue;
      end;
      if FSignal.WaitFor(GHeartbeatMs) = wrTimeout then
        { A comment line: EventSource ignores it, a proxy sees traffic,
          and a stream whose browser has gone finds out here. }
        if not Send(': ping' + #10#10) then
          Break;
    end;
  finally
    GLock.Acquire;
    try
      GStreams.Remove(Self);
    finally
      GLock.Release;
    end;
    if FTls <> nil then
    begin
      FTls.Shutdown;
      FTls.Free;
    end;
    CloseSocket(FSock);
  end;
end;

initialization
  GLock := TCriticalSection.Create;
  GStreams := TList.Create;

finalization
  GStreams.Free;
  GLock.Free;

end.
