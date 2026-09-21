{ Askr.Cli.Proxy — the dev server's front towards the browser.

  The app runs on an internal port and is swapped out when the code
  changes. The proxy listens on the port the developer actually uses, and
  survives the swap.

  This is what the PRD means by the dev server queuing incoming requests
  while the code is swapped rather than showing an error page: during a
  rebuild the proxy holds the connection open instead of connecting to a
  port nobody is listening on. The browser sees a request that takes a
  little longer, not an error.

  The relay is raw TCP, not HTTP. It is simpler, and it means that Vite's
  HMR socket and everything else that is not ordinary HTTP passes through
  unchanged. }
unit Askr.Cli.Proxy;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs, Sockets, BaseUnix, Unix,
  Askr.Core.Clock;

type
  TDevProxy = class;

  TRelay = class(TThread)
  private
    FProxy: TDevProxy;
    FClient: TSocket;
    procedure Pump(A, B: TSocket);
    procedure SendErrorPage(const Msg: string);
  protected
    procedure Execute; override;
  public
    constructor Create(AProxy: TDevProxy; AClient: TSocket);
  end;

  TDevProxy = class
  private
    FListen: TSocket;
    FPublicPort: Word;
    FBackendPort: Word;
    FRunning: LongInt;
    FPaused: LongInt;
    FLock: TCriticalSection;
    FError: string;
    FAcceptor: TThread;
    FHeldTotal: LongInt;
    FHeldMaxMs: LongInt;
    function IsRunning: Boolean;
    { Waits until the rebuild is finished. False if it took too long. }
    function WaitForReady(TimeoutMs: Integer; out HeldMs: Integer): Boolean;
  public
    constructor Create(APublicPort, ABackendPort: Word);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;

    { Called around a rebuild. Resume with an empty error message means the
      build went well; otherwise the message is shown in the browser. }
    procedure Pause;
    procedure Resume(const AError: string);
    { Empty when the last build went well. }
    function BuildError: string;

    property PublicPort: Word read FPublicPort;
    property BackendPort: Word read FBackendPort write FBackendPort;
    { How many requests have been held, and the longest hold. The numbers
      are what show whether the queuing actually works. }
    property HeldTotal: LongInt read FHeldTotal;
    property HeldMaxMs: LongInt read FHeldMaxMs;
  end;

implementation

type
  TAcceptor = class(TThread)
  private
    FProxy: TDevProxy;
  protected
    procedure Execute; override;
  public
    constructor Create(AProxy: TDevProxy);
  end;

const
  { How long a request is held before we give up and say so. A rebuild
    that takes longer than this is something the developer needs to know
    about anyway. }
  MaxHoldMs = 15000;

var
  SockOptOn: cint = 1;

{ TDevProxy }

constructor TDevProxy.Create(APublicPort, ABackendPort: Word);
begin
  inherited Create;
  FPublicPort := APublicPort;
  FBackendPort := ABackendPort;
  FLock := TCriticalSection.Create;
  FListen := -1;
end;

destructor TDevProxy.Destroy;
begin
  Stop;
  FLock.Free;
  inherited Destroy;
end;

function TDevProxy.IsRunning: Boolean;
begin
  Result := InterLockedExchangeAdd(FRunning, 0) <> 0;
end;

function TDevProxy.BuildError: string;
begin
  FLock.Acquire;
  try
    Result := FError;
  finally
    FLock.Release;
  end;
end;

procedure TDevProxy.Pause;
begin
  InterLockedExchange(FPaused, 1);
end;

procedure TDevProxy.Resume(const AError: string);
begin
  FLock.Acquire;
  try
    FError := AError;
  finally
    FLock.Release;
  end;
  InterLockedExchange(FPaused, 0);
end;

function TDevProxy.WaitForReady(TimeoutMs: Integer; out HeldMs: Integer): Boolean;
var
  Start: Int64;
begin
  HeldMs := 0;
  if InterLockedExchangeAdd(FPaused, 0) = 0 then
    Exit(True);

  Start := MonotonicMs;
  InterLockedIncrement(FHeldTotal);
  while InterLockedExchangeAdd(FPaused, 0) <> 0 do
  begin
    if MonotonicMs - Start > TimeoutMs then
    begin
      HeldMs := Integer(MonotonicMs - Start);
      Exit(False);
    end;
    Sleep(2);
  end;
  HeldMs := Integer(MonotonicMs - Start);

  FLock.Acquire;
  try
    if HeldMs > FHeldMaxMs then
      FHeldMaxMs := HeldMs;
  finally
    FLock.Release;
  end;
  Result := True;
end;

procedure TDevProxy.Start;
var
  Addr: TInetSockAddr;
begin
  if IsRunning then
    Exit;
  fpSignal(SIGPIPE, SignalHandler(SIG_IGN));

  FListen := fpSocket(AF_INET, SOCK_STREAM, 0);
  if FListen < 0 then
    raise Exception.Create('dev proxy: socket() failed');
  fpSetSockOpt(FListen, SOL_SOCKET, SO_REUSEADDR, @SockOptOn, SizeOf(SockOptOn));

  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := HToNS(FPublicPort);
  Addr.sin_addr := StrToNetAddr('127.0.0.1');
  if fpBind(FListen, @Addr, SizeOf(Addr)) <> 0 then
  begin
    CloseSocket(FListen);
    FListen := -1;
    raise Exception.CreateFmt('dev proxy: port %d is in use', [FPublicPort]);
  end;
  fpListen(FListen, 128);

  InterLockedExchange(FRunning, 1);
  FAcceptor := TAcceptor.Create(Self);
end;

procedure TDevProxy.Stop;
begin
  if InterLockedExchange(FRunning, 0) = 0 then
    Exit;
  if FListen >= 0 then
  begin
    fpShutdown(FListen, 2);
    CloseSocket(FListen);
    FListen := -1;
  end;
  if FAcceptor <> nil then
  begin
    FAcceptor.WaitFor;
    FAcceptor.Free;
    FAcceptor := nil;
  end;
end;

{ TAcceptor }

constructor TAcceptor.Create(AProxy: TDevProxy);
begin
  FProxy := AProxy;
  inherited Create(False);
end;

procedure TAcceptor.Execute;
var
  Sock: TSocket;
  Addr: TInetSockAddr;
  Len: TSockLen;
begin
  while FProxy.IsRunning do
  begin
    Len := SizeOf(Addr);
    Sock := fpAccept(FProxy.FListen, @Addr, @Len);
    if Sock < 0 then
    begin
      if fpGetErrno = ESysEINTR then
        Continue;
      if not FProxy.IsRunning then
        Break;
      Sleep(5);
      Continue;
    end;
    { One thread per connection. A dev server has one user; this is not
      where scalability matters. }
    TRelay.Create(FProxy, Sock);
  end;
end;

{ TRelay }

constructor TRelay.Create(AProxy: TDevProxy; AClient: TSocket);
begin
  FProxy := AProxy;
  FClient := AClient;
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure TRelay.SendErrorPage(const Msg: string);
var
  Body, Head: string;
  Escaped: string;
  I: Integer;
begin
  Escaped := '';
  for I := 1 to Length(Msg) do
    case Msg[I] of
      '<': Escaped := Escaped + '&lt;';
      '>': Escaped := Escaped + '&gt;';
      '&': Escaped := Escaped + '&amp;';
    else
      Escaped := Escaped + Msg[I];
    end;

  Body :=
    '<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">' +
    '<title>Build failed</title><style>' +
    'body{font:14px ui-monospace,SFMono-Regular,Menlo,monospace;' +
    'background:#1c1917;color:#e7e5e4;margin:0;padding:2.5rem}' +
    'h1{font-size:1rem;letter-spacing:.08em;text-transform:uppercase;' +
    'color:#f87171;margin:0 0 1.25rem}' +
    'pre{white-space:pre-wrap;line-height:1.55;margin:0}' +
    'p{color:#a8a29e;margin:1.5rem 0 0}' +
    '</style></head><body><h1>Build failed</h1><pre>' + Escaped +
    '</pre><p>Save a file again and the dev server will retry.</p>' +
    '</body></html>';

  Head := 'HTTP/1.1 500 Internal Server Error'#13#10 +
    'Content-Type: text/html; charset=utf-8'#13#10 +
    'Content-Length: ' + IntToStr(Length(Body)) + #13#10 +
    'Cache-Control: no-store'#13#10 +
    'Connection: close'#13#10#13#10;
  fpSend(FClient, PChar(Head), Length(Head), 0);
  fpSend(FClient, PChar(Body), Length(Body), 0);
end;

{ A two-way relay with select. Two threads per connection would have been
  easier to write, but twice as many threads to clean up. }
procedure TRelay.Pump(A, B: TSocket);
var
  FDS: TFDSet;
  MaxFd: Integer;
  N: Integer;
  Buf: array[0..16383] of Byte;
  Got: ssize_t;

  function Forward_(From_, To_: TSocket): Boolean;
  var
    R, Sent, W: ssize_t;
  begin
    R := fpRecv(From_, @Buf[0], SizeOf(Buf), 0);
    if R <= 0 then
      Exit(False);
    Sent := 0;
    while Sent < R do
    begin
      W := fpSend(To_, @Buf[Sent], R - Sent, 0);
      if W <= 0 then
        Exit(False);
      Inc(Sent, W);
    end;
    Result := True;
  end;

begin
  if A > B then
    MaxFd := A
  else
    MaxFd := B;
  while True do
  begin
    fpFD_ZERO(FDS);
    fpFD_SET(A, FDS);
    fpFD_SET(B, FDS);
    N := fpSelect(MaxFd + 1, @FDS, nil, nil, 60000);
    if N < 0 then
    begin
      if fpGetErrno = ESysEINTR then
        Continue;
      Break;
    end;
    if N = 0 then
      Break;
    if fpFD_ISSET(A, FDS) = 1 then
      if not Forward_(A, B) then
        Break;
    if fpFD_ISSET(B, FDS) = 1 then
      if not Forward_(B, A) then
        Break;
  end;
end;

procedure TRelay.Execute;
var
  Backend: TSocket;
  Addr: TInetSockAddr;
  HeldMs: Integer;
  Err: string;
begin
  try
    { This is where the queuing happens: if a rebuild is under way, the
      connection is held instead of connecting to a port nobody is
      listening on. }
    if not FProxy.WaitForReady(MaxHoldMs, HeldMs) then
    begin
      SendErrorPage('The build took longer than ' + IntToStr(MaxHoldMs div 1000) +
        ' sekunder. Se terminalen.');
      Exit;
    end;

    Err := FProxy.BuildError;
    if Err <> '' then
    begin
      SendErrorPage(Err);
      Exit;
    end;

    Backend := fpSocket(AF_INET, SOCK_STREAM, 0);
    if Backend < 0 then
      Exit;
    FillChar(Addr, SizeOf(Addr), 0);
    Addr.sin_family := AF_INET;
    Addr.sin_port := HToNS(FProxy.BackendPort);
    Addr.sin_addr := StrToNetAddr('127.0.0.1');
    if fpConnect(Backend, @Addr, SizeOf(Addr)) <> 0 then
    begin
      CloseSocket(Backend);
      SendErrorPage('The app is not answering on port ' +
        IntToStr(FProxy.BackendPort) + '.');
      Exit;
    end;

    fpSetSockOpt(Backend, IPPROTO_TCP, TCP_NODELAY, @SockOptOn,
      SizeOf(SockOptOn));
    fpSetSockOpt(FClient, IPPROTO_TCP, TCP_NODELAY, @SockOptOn,
      SizeOf(SockOptOn));
    try
      Pump(FClient, Backend);
    finally
      CloseSocket(Backend);
    end;
  finally
    CloseSocket(FClient);
  end;
end;

end.
