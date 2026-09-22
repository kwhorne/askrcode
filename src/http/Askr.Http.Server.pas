{ Askr.Http.Server — an HTTP/1.1 host with one arena per worker.

  The model is the one the PRD describes: N worker threads, each with its
  own arena, all blocking in accept on the same listening socket. The
  kernel distributes the connections. No event loop, no state machine —
  one thread follows one connection from start to finish, and the whole
  request is cleared with a single Arena.Reset.

  The read buffer is owned by the worker and does _not_ live in the arena.
  That is deliberate: the buffer has to survive Reset for keep-alive and
  pipelining to work, and it is reused across connections so the arena
  only ever sees what is actually derived from the request.

  The head is copied into the arena before parsing. That costs one memcpy
  of a few hundred bytes, and in return the read buffer can grow when the
  body arrives without leaving the slices in TRequest dangling.

  Programs using this unit must have cthreads first in uses on Unix. }
unit Askr.Http.Server;

{$mode Delphi}{$H+}
{$POINTERMATH ON}

interface

uses
  SysUtils, Classes, Sockets, BaseUnix,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Clock, Askr.Core.Log,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response, Askr.Tls;

type
  EServerError = class(Exception);

  THandlerMethod = function(Req: TRequest): TResponse of object;
  THandlerFunc = function(Req: TRequest): TResponse;

  TServerOptions = record
    Host: string;
    Port: Word;
    { 0 betyr én worker per kjerne. }
    Workers: Integer;
    Backlog: Integer;
    ArenaBlockSize: PtrUInt;
    MaxBodyBytes: Int64;
    { How long we wait for a new request to start on an open connection. }
    KeepAliveTimeoutMs: Integer;
    { How long we wait for a started request to finish being read. }
    RequestTimeoutMs: Integer;
    { After this many, the connection is closed, so load balancing and
      arenas get a natural boundary. 0 = unlimited. }
    MaxRequestsPerConnection: Integer;
    { Lesebufferet krymper tilbake hit etter en stor request. }
    ReadBufferSize: SizeInt;
    LogRequests: Boolean;
    { PEM files. With both set the server speaks HTTPS instead of HTTP.
      There is no separate port and no redirect: one server, one protocol.
      If you want both, run two servers. }
    TlsCertFile: string;
    TlsKeyFile: string;
  end;

  TAskrServer = class;

  TWorker = class(TThread)
  private
    FServer: TAskrServer;
    FArena: TArena;
    FIndex: Integer;
    FBuf: PByte;
    FBufCap: SizeInt;
    FBufLen: SizeInt;    { gyldige bytes fra 0 }
    FBufPos: SizeInt;    { konsumert til hit }
    FRequests: QWord;
    { Non-nil when the connection is encrypted. Lives exactly as long as one
      connection, and does not own the socket. }
    FTls: TTlsConn;
    procedure EnsureCapacity(Need: SizeInt);
    procedure Compact;
    { Reads at least one more byte. False = the peer closed, or a
      timeout. }
    function Fill(Sock: TSocket): Boolean;
    function FindHeadEnd(out HeadLen, Total: SizeInt): Boolean;
    procedure ServeConnection(Sock: TSocket; const Peer: string);
    function SendAll(Sock: TSocket; const Data: TStr): Boolean;
    procedure SendCannedError(Sock: TSocket; Code: Integer);
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TAskrServer; AIndex: Integer);
    destructor Destroy; override;
    property Requests: QWord read FRequests;
    property Arena: TArena read FArena;
  end;

  TAskrServer = class
  private
    FOpts: TServerOptions;
    FListen: TSocket;
    FWorkers: array of TWorker;
    FTlsCtx: TTlsContext;
    FHandlerMethod: THandlerMethod;
    FHandlerFunc: THandlerFunc;
    FRunning: LongInt;
    FBoundPort: Word;
    procedure OpenListener;
    function CallHandler(Req: TRequest): TResponse;
    function IsRunning: Boolean;
  public
    constructor Create(const AOpts: TServerOptions);
    destructor Destroy; override;

    procedure SetHandler(AHandler: THandlerMethod); overload;
    procedure SetHandler(AHandler: THandlerFunc); overload;

    { Opens the listening socket and starts the workers. Returns at
      once. }
    procedure Start;
    { Start, and block until Stop is called. }
    procedure Run;
    procedure Stop;

    function TotalRequests: QWord;
    { Summed across the workers. If this flattens out under sustained load
      the arena premise holds; if it grows, it does not. }
    function TotalArenaReserved: PtrUInt;
    function TotalArenaHighWater: PtrUInt;
    { The actual port. With Port set to 0 this is the port the kernel
      chose, which is what tests need so they do not have to guess. }
    property BoundPort: Word read FBoundPort;
    property Running: Boolean read IsRunning;
    property Options: TServerOptions read FOpts;
    { True when the server accepted a certificate and speaks HTTPS. }
    function UsesTls: Boolean;
  end;

function DefaultServerOptions: TServerOptions;

implementation

uses
  Unix;

const
  { _SC_NPROCESSORS_ONLN har ulik verdi per kjerne, som CLOCK_MONOTONIC. }
  ScNProcessorsOnln = {$IFDEF DARWIN} 58 {$ELSE} 84 {$ENDIF};

var
  { The address is passed to setsockopt, so the value needs a
    lifetime. }
  SockOptTrue: cint = 1;

function sysconf(Name: cint): clong; cdecl; external 'c' name 'sysconf';

function DefaultServerOptions: TServerOptions;
begin
  Result.Host := '127.0.0.1';
  Result.Port := 8080;
  Result.Workers := 0;
  Result.Backlog := 512;
  Result.ArenaBlockSize := ArenaDefaultBlockSize;
  Result.MaxBodyBytes := DefaultMaxBodyBytes;
  Result.KeepAliveTimeoutMs := 5000;
  Result.RequestTimeoutMs := 15000;
  Result.MaxRequestsPerConnection := 1000;
  Result.ReadBufferSize := 16 * 1024;
  Result.LogRequests := False;
end;

function CpuCount: Integer;
begin
  Result := Integer(sysconf(ScNProcessorsOnln));
  if Result < 1 then
    Result := 1;
end;

procedure SetTimeout(Sock: TSocket; OptName, Ms: Integer);
var
  TV: TTimeVal;
begin
  TV.tv_sec := Ms div 1000;
  TV.tv_usec := (Ms mod 1000) * 1000;
  fpSetSockOpt(Sock, SOL_SOCKET, OptName, @TV, SizeOf(TV));
end;

{ TWorker }

constructor TWorker.Create(AServer: TAskrServer; AIndex: Integer);
begin
  FServer := AServer;
  FIndex := AIndex;
  FArena := TArena.Create(AServer.Options.ArenaBlockSize);
  FBufCap := AServer.Options.ReadBufferSize;
  FBuf := GetMem(FBufCap);
  inherited Create(False);
end;

destructor TWorker.Destroy;
begin
  inherited Destroy;
  FreeMem(FBuf);
  FArena.Free;
end;

procedure TWorker.EnsureCapacity(Need: SizeInt);
var
  NewCap: SizeInt;
begin
  if Need <= FBufCap then
    Exit;
  NewCap := FBufCap;
  while NewCap < Need do
    NewCap := NewCap * 2;
  FBuf := ReAllocMem(FBuf, NewCap);
  FBufCap := NewCap;
end;

procedure TWorker.Compact;
begin
  if FBufPos = 0 then
    Exit;
  if FBufPos >= FBufLen then
  begin
    FBufLen := 0;
    FBufPos := 0;
    Exit;
  end;
  Move((FBuf + FBufPos)^, FBuf^, FBufLen - FBufPos);
  Dec(FBufLen, FBufPos);
  FBufPos := 0;
end;

function TWorker.Fill(Sock: TSocket): Boolean;
var
  N: ssize_t;
begin
  if FBufLen >= FBufCap then
    EnsureCapacity(FBufCap * 2);
  if FTls <> nil then
    N := FTls.Read(FBuf + FBufLen, FBufCap - FBufLen)
  else
    repeat
      N := fpRecv(Sock, FBuf + FBufLen, FBufCap - FBufLen, 0);
    until (N >= 0) or (fpGetErrno <> ESysEINTR);
  if N <= 0 then
    Exit(False);
  Inc(FBufLen, N);
  Result := True;
end;

{ Looks for CRLFCRLF. HeadLen is the head without the terminating blank
  line, Total is the number of bytes making up the whole head. Also
  tolerates bare LFLF, which some clients send. }
function TWorker.FindHeadEnd(out HeadLen, Total: SizeInt): Boolean;
var
  I: SizeInt;
begin
  HeadLen := 0;
  Total := 0;
  I := FBufPos;
  while I + 1 < FBufLen do
  begin
    if (FBuf[I] = 10) and (FBuf[I + 1] = 10) then
    begin
      HeadLen := I - FBufPos + 1;
      Total := I + 2 - FBufPos;
      Exit(True);
    end;
    if (I + 3 < FBufLen) and (FBuf[I] = 13) and (FBuf[I + 1] = 10) and
       (FBuf[I + 2] = 13) and (FBuf[I + 3] = 10) then
    begin
      HeadLen := I - FBufPos + 2;
      Total := I + 4 - FBufPos;
      Exit(True);
    end;
    Inc(I);
  end;
  Result := False;
end;

function TWorker.SendAll(Sock: TSocket; const Data: TStr): Boolean;
var
  Sent: SizeInt;
  N: ssize_t;
begin
  if FTls <> nil then
    Exit(FTls.WriteAll(Data.Data, Data.Len));
  Sent := 0;
  while Sent < Data.Len do
  begin
    N := fpSend(Sock, Data.Data + Sent, Data.Len - Sent, 0);
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

procedure TWorker.SendCannedError(Sock: TSocket; Code: Integer);
var
  S: string;
  Reason: string;
begin
  { Pre-built without an arena: used when the request was refused before
    it got an arena at all, or when the arena cannot be trusted. }
  Reason := StatusText(Code);
  S := 'HTTP/1.1 ' + IntToStr(Code) + ' ' + Reason + #13#10 +
       'Content-Type: text/plain; charset=utf-8'#13#10 +
       'Content-Length: ' + IntToStr(Length(Reason)) + #13#10 +
       'Connection: close'#13#10#13#10 + Reason;
  SendAll(Sock, Str(S));
end;

procedure TWorker.ServeConnection(Sock: TSocket; const Peer: string);
var
  HeadLen, HeadTotal: SizeInt;
  Head: TStr;
  Req: TRequest;
  Res: TResponse;
  State: TParseState;
  Out_: TStrBuilder;
  Prev: TArena;
  Count: Integer;
  Close_: Boolean;
  ErrCode: Integer;
  BodyLen: SizeInt;
  Started: Int64;
begin
  FBufLen := 0;
  FBufPos := 0;
  Count := 0;

  while FServer.IsRunning do
  begin
    Compact;

    { Waiting for a request to start. The keep-alive timeout applies
      here. }
    SetTimeout(Sock, SO_RCVTIMEO, FServer.Options.KeepAliveTimeoutMs);
    while not FindHeadEnd(HeadLen, HeadTotal) do
    begin
      if FBufLen - FBufPos > MaxHeaderBytes then
      begin
        SendCannedError(Sock, 431);
        Exit;
      end;
      if not Fill(Sock) then
        Exit;   { a normal close or a timeout — not an error }
      { From the first byte onwards the request has started. }
      SetTimeout(Sock, SO_RCVTIMEO, FServer.Options.RequestTimeoutMs);
    end;

    Started := MonotonicMs;
    FArena.Reset;
    Prev := UseArena(FArena);
    try
      Head := StrDup(FArena, StrRef(FBuf + FBufPos, HeadLen));
      Inc(FBufPos, HeadTotal);

      Req := TRequest.Create;
      State := Req.ParseHead(Head, FServer.Options.MaxBodyBytes);

      if State <> psOk then
      begin
        case State of
          psUriTooLong:         ErrCode := 414;
          psHeadersTooLarge:    ErrCode := 431;
          psBodyTooLarge:       ErrCode := 413;
          psUnsupportedVersion: ErrCode := 505;
          psNotImplemented:     ErrCode := 501;
        else
          ErrCode := 400;
        end;
        SendCannedError(Sock, ErrCode);
        Exit;
      end;

      { Read the body. The read buffer may grow here; the head is safe in
        the arena. }
      BodyLen := SizeInt(Req.ContentLength);
      if BodyLen > 0 then
      begin
        SetTimeout(Sock, SO_RCVTIMEO, FServer.Options.RequestTimeoutMs);
        EnsureCapacity(FBufPos + BodyLen);
        while FBufLen - FBufPos < BodyLen do
          if not Fill(Sock) then
            Exit;
        Req.SetBody(StrRef(FBuf + FBufPos, BodyLen));
        Inc(FBufPos, BodyLen);
      end;

      Req.SetRemoteAddr(StrDup(FArena, Peer));

      { Make the request ambient, so Inertia() and similar helpers find it
        without every controller having to pass it along. }
      UseRequest(Req);

      Inc(Count);
      Inc(FRequests);
      Close_ := (not Req.KeepAlive) or (not FServer.IsRunning) or
                ((FServer.Options.MaxRequestsPerConnection > 0) and
                 (Count >= FServer.Options.MaxRequestsPerConnection));

      try
        Res := FServer.CallHandler(Req);
        if Res = nil then
          Res := ErrorResponse(404);
      except
        on E: Exception do
        begin
          { The handler is user code. An unhandled exception should cost this
            request, not the worker.

            The body says 'Internal Server Error' and nothing else -- no
            class name, no message, no stack. E.Message is where the SQL
            is, or the path, or the value; it goes to the log on the next
            line, which is the one place that can be read by somebody
            entitled to read it. A framework that helpfully returns it
            has published a reconnaissance endpoint on every route. }
          Res := ErrorResponse(500);
          Close_ := True;
          { An exception from user code is always logged, whatever LogRequests
            says. It is not a request line, it is an error — and a 500
            that leaves no trace is a 500 nobody can debug. }
          LogException(E, 'unhandled exception in handler',
            ['method', Askr.Http.Types.MethodName(Req.Method),
             'path', Req.Path.ToString]);
        end;
      end;

      { Conditional GET, in one place rather than in every handler. A
        response that carries an ETag and matches what the client already
        has becomes a 304 with no body; TResponse decides, including the
        rule that a response setting a cookie never does.

        Only GET and HEAD: If-None-Match on other methods is a
        precondition, answered with 412, which Askr does not do -- and
        turning a POST into a 304 would drop the write. }
      if (Req.Method = hmGet) or (Req.Method = hmHead) then
        Res.NotModifiedIfMatches(Req.Header('if-none-match').ToString);

      Out_.Init(FArena, 1024 + Res.Body.Len);
      Res.WriteTo(Out_, Close_, Req.Method = hmHead);

      if not SendAll(Sock, Out_.ToStr) then
        Exit;

      if FServer.Options.LogRequests then
        LogInfo('request',
          ['method', Askr.Http.Types.MethodName(Req.Method),
           'path', Req.Path.ToString,
           'status', Res.StatusCode,
           'ms', MonotonicMs - Started,
           'arena', Int64(FArena.BytesLive)]);

      if Close_ then
        Exit;
    finally
      UseRequest(nil);
      UseArena(Prev);
    end;

    { A single large request must not make the worker hold on to the
      memory. The buffer is released only when nothing is left in it: a
      client pipelining a request right after a large body would
      otherwise have it discarded. That took both pipelining and a body
      over sixteen times the buffer, so it did not show up — but uploads
      make both of those more common. }
    if (FBufCap > FServer.Options.ReadBufferSize * 16) and
       (FBufPos >= FBufLen) then
    begin
      FreeMem(FBuf);
      FBufCap := FServer.Options.ReadBufferSize;
      FBuf := GetMem(FBufCap);
      FBufLen := 0;
      FBufPos := 0;
    end;
  end;
end;

procedure TWorker.Execute;
var
  Sock: TSocket;
  Addr: TInetSockAddr;
  Len: TSockLen;
  Peer: string;
begin
  while FServer.IsRunning do
  begin
    Len := SizeOf(Addr);
    Sock := fpAccept(FServer.FListen, @Addr, @Len);
    if Sock < 0 then
    begin
      if fpGetErrno = ESysEINTR then
        Continue;
      { The listening socket was closed by Stop, or the kernel is out of
        file handles. In both cases looking at FRunning is the right
        response. }
      if not FServer.IsRunning then
        Break;
      Sleep(5);
      Continue;
    end;

    Peer := NetAddrToStr(Addr.sin_addr);
    SetTimeout(Sock, SO_SNDTIMEO, FServer.Options.RequestTimeoutMs);
    fpSetSockOpt(Sock, IPPROTO_TCP, TCP_NODELAY, @SockOptTrue, SizeOf(SockOptTrue));

    FTls := nil;
    if FServer.FTlsCtx <> nil then
      try
        { The handshake happens here rather than in ServeConnection, because
          a client that cannot manage it should cost one closed socket and
          nothing more — not an arena, not a log line per request. }
        FTls := TTlsConn.Create(FServer.FTlsCtx, Sock);
      except
        on E: Exception do
        begin
          FTls := nil;
          CloseSocket(Sock);
          Continue;
        end;
      end;

    try
      try
        ServeConnection(Sock, Peer);
      except
        on E: Exception do
          LogException(E, 'worker failed', ['worker', FIndex]);
      end;
    finally
      if FTls <> nil then
      begin
        FTls.Free;
        FTls := nil;
      end;
      CloseSocket(Sock);
    end;
  end;
end;

{ TAskrServer }

constructor TAskrServer.Create(const AOpts: TServerOptions);
begin
  inherited Create;
  FOpts := AOpts;
  if FOpts.Workers <= 0 then
    FOpts.Workers := CpuCount;
  if FOpts.ReadBufferSize < 4096 then
    FOpts.ReadBufferSize := 4096;
  FListen := -1;
end;

destructor TAskrServer.Destroy;
begin
  Stop;
  FreeAndNil(FTlsCtx);
  inherited Destroy;
end;

procedure TAskrServer.SetHandler(AHandler: THandlerMethod);
begin
  FHandlerMethod := AHandler;
  FHandlerFunc := nil;
end;

procedure TAskrServer.SetHandler(AHandler: THandlerFunc);
begin
  FHandlerFunc := AHandler;
  FHandlerMethod := nil;
end;

function TAskrServer.CallHandler(Req: TRequest): TResponse;
begin
  if Assigned(FHandlerMethod) then
    Result := FHandlerMethod(Req)
  else if Assigned(FHandlerFunc) then
    Result := FHandlerFunc(Req)
  else
    Result := ErrorResponse(500, 'No handler registered');
end;

function TAskrServer.UsesTls: Boolean;
begin
  Result := FTlsCtx <> nil;
end;

function TAskrServer.IsRunning: Boolean;
begin
  Result := InterLockedExchangeAdd(FRunning, 0) <> 0;
end;

procedure TAskrServer.OpenListener;
var
  Addr: TInetSockAddr;
  Len: TSockLen;
  Host: in_addr;
begin
  FListen := fpSocket(AF_INET, SOCK_STREAM, 0);
  if FListen < 0 then
    raise EServerError.CreateFmt('socket() failed: %d', [fpGetErrno]);

  fpSetSockOpt(FListen, SOL_SOCKET, SO_REUSEADDR, @SockOptTrue, SizeOf(SockOptTrue));

  Host := StrToNetAddr(FOpts.Host);
  { StrToNetAddr reports failure by returning 0.0.0.0, which is also a
    valid address to listen on. So we compare against the text instead. }
  if (Host.s_addr = 0) and (FOpts.Host <> '0.0.0.0') then
    raise EServerError.CreateFmt('Invalid listen address: %s', [FOpts.Host]);

  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := HToNS(FOpts.Port);
  Addr.sin_addr := Host;

  if fpBind(FListen, @Addr, SizeOf(Addr)) <> 0 then
  begin
    CloseSocket(FListen);
    FListen := -1;
    raise EServerError.CreateFmt('bind(%s:%d) failed: %d',
      [FOpts.Host, FOpts.Port, fpGetErrno]);
  end;

  if fpListen(FListen, FOpts.Backlog) <> 0 then
  begin
    CloseSocket(FListen);
    FListen := -1;
    raise EServerError.CreateFmt('listen() failed: %d', [fpGetErrno]);
  end;

  { With Port = 0 the kernel chooses. Read it back, or nobody knows where
    we are. }
  Len := SizeOf(Addr);
  if fpGetSockName(FListen, @Addr, @Len) = 0 then
    FBoundPort := NToHs(Addr.sin_port)
  else
    FBoundPort := FOpts.Port;
end;

procedure TAskrServer.Start;
var
  I: Integer;
begin
  if IsRunning then
    Exit;

  { Without this, a client that closes early kills the whole process. }
  fpSignal(SIGPIPE, SignalHandler(SIG_IGN));

  { The certificate is read before the listening socket opens. A
    misspelled path should give an error at startup, not a port that
    accepts and then refuses everything. }
  if (FOpts.TlsCertFile <> '') or (FOpts.TlsKeyFile <> '') then
  begin
    if (FOpts.TlsCertFile = '') or (FOpts.TlsKeyFile = '') then
      raise EServerError.Create(
        'TLS needs both TlsCertFile and TlsKeyFile; only one is set');
    FTlsCtx := TTlsContext.Create(trServer);
    FTlsCtx.UseCertificate(FOpts.TlsCertFile, FOpts.TlsKeyFile);
  end;

  OpenListener;
  InterLockedExchange(FRunning, 1);

  SetLength(FWorkers, FOpts.Workers);
  for I := 0 to High(FWorkers) do
    FWorkers[I] := TWorker.Create(Self, I);
end;

procedure TAskrServer.Run;
begin
  Start;
  while IsRunning do
    Sleep(50);
end;

procedure TAskrServer.Stop;
var
  I: Integer;
begin
  if InterLockedExchange(FRunning, 0) = 0 then
    Exit;

  { Closing the listening socket makes accept return in every worker. }
  if FListen >= 0 then
  begin
    fpShutdown(FListen, 2);
    CloseSocket(FListen);
    FListen := -1;
  end;

  for I := 0 to High(FWorkers) do
    if FWorkers[I] <> nil then
    begin
      FWorkers[I].WaitFor;
      FWorkers[I].Free;
      FWorkers[I] := nil;
    end;
  SetLength(FWorkers, 0);
end;

function TAskrServer.TotalRequests: QWord;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FWorkers) do
    if FWorkers[I] <> nil then
      Inc(Result, FWorkers[I].Requests);
end;

function TAskrServer.TotalArenaReserved: PtrUInt;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FWorkers) do
    if FWorkers[I] <> nil then
      Inc(Result, FWorkers[I].Arena.BytesReserved);
end;

function TAskrServer.TotalArenaHighWater: PtrUInt;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FWorkers) do
    if (FWorkers[I] <> nil) and (FWorkers[I].Arena.HighWaterMark > Result) then
      Result := FWorkers[I].Arena.HighWaterMark;
end;

end.
