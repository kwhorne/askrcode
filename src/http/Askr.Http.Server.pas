{ Askr.Http.Server — HTTP/1.1-vert med én arena per worker.

  Modellen er den PRD-en beskriver: N worker-tråder, hver med sin egen arena,
  som alle blokkerer i accept på den samme lyttesocketen. Kjernen fordeler
  tilkoblingene. Ingen event-løkke, ingen tilstandsmaskin — én tråd følger én
  tilkobling fra start til slutt, og hele requesten ryddes med ett Arena.Reset.

  Lesebufferet eies av workeren og ligger _ikke_ i arenaen. Det er med vilje:
  bufferet må overleve Reset for at keep-alive og pipelining skal virke, og
  det gjenbrukes på tvers av tilkoblinger slik at arenaen bare får se det som
  faktisk er utledet av requesten.

  Hodet kopieres inn i arenaen før parsing. Det koster én memcpy på noen
  hundre bytes, og til gjengjeld kan lesebufferet vokse når kroppen kommer
  uten at utsnittene i TRequest blir hengende.

  Programmer som bruker denne enheten må ha cthreads først i uses på Unix. }
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
    { Tid vi venter på at en ny request skal begynne på en åpen tilkobling. }
    KeepAliveTimeoutMs: Integer;
    { Tid vi venter på at en påbegynt request skal bli ferdig lest. }
    RequestTimeoutMs: Integer;
    { Etter dette antallet stenges tilkoblingen, slik at lastbalansering og
      arenaer får en naturlig grense. 0 = ubegrenset. }
    MaxRequestsPerConnection: Integer;
    { Lesebufferet krymper tilbake hit etter en stor request. }
    ReadBufferSize: SizeInt;
    LogRequests: Boolean;
    { PEM-filer. Er begge satt, snakker serveren HTTPS i stedet for HTTP.
      Det er ingen egen port og ingen omdirigering: én server, én protokoll.
      Vil man ha begge deler, kjører man to servere. }
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
    { Ikke-nil når tilkoblingen er kryptert. Lever like lenge som én
      tilkobling, og eier ikke socketen. }
    FTls: TTlsConn;
    procedure EnsureCapacity(Need: SizeInt);
    procedure Compact;
    { Leser minst én byte til. False = motparten lukket eller timeout. }
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

    { Åpner lyttesocketen og starter workerne. Returnerer med en gang. }
    procedure Start;
    { Start, og blokker til Stop kalles. }
    procedure Run;
    procedure Stop;

    function TotalRequests: QWord;
    { Summert over workerne. Flater dette ut under vedvarende last, holder
      arena-premisset; vokser det, gjør det ikke. }
    function TotalArenaReserved: PtrUInt;
    function TotalArenaHighWater: PtrUInt;
    { Faktisk port. Er Port satt til 0 er dette porten kjernen valgte, som er
      det tester trenger for å slippe å gjette. }
    property BoundPort: Word read FBoundPort;
    property Running: Boolean read IsRunning;
    property Options: TServerOptions read FOpts;
    { True når serveren tok imot et sertifikat og snakker HTTPS. }
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
  { Adressen sendes til setsockopt, så verdien må ha en levetid. }
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

{ Leter etter CRLFCRLF. HeadLen er hodet uten den avsluttende tomme linjen,
  Total er antall bytes som utgjør hele hodet. Tåler også bare LFLF, som
  enkelte klienter sender. }
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
  { Ferdigbygget uten arena: brukes når requesten ble avvist før den fikk en
    arena i det hele tatt, eller når arenaen ikke er til å stole på. }
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

    { Vent på starten av en request. Her gjelder keep-alive-timeouten. }
    SetTimeout(Sock, SO_RCVTIMEO, FServer.Options.KeepAliveTimeoutMs);
    while not FindHeadEnd(HeadLen, HeadTotal) do
    begin
      if FBufLen - FBufPos > MaxHeaderBytes then
      begin
        SendCannedError(Sock, 431);
        Exit;
      end;
      if not Fill(Sock) then
        Exit;   { normal stengning eller timeout — ikke en feil }
      { Fra og med første byte er requesten påbegynt. }
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

      { Les kroppen. Lesebufferet kan vokse her; hodet ligger trygt i arenaen. }
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

      { Gjør requesten omgivende, slik at Inertia() og liknende hjelpere
        finner den uten at hver kontroller må sende den videre. }
      UseRequest(Req);

      Inc(Count);
      Inc(FRequests);
      Close_ := (not Req.KeepAlive) or (not FServer.IsRunning) or
                ((FServer.Options.MaxRequestsPerConnection > 0) and
                 (Count >= FServer.Options.MaxRequestsPerConnection));

      try
        Res := FServer.CallHandler(Req);
        if Res = nil then
          Res := RespondText('Not Found', 404);
      except
        on E: Exception do
        begin
          { Handleren er brukerkode. En upåaktet exception skal koste denne
            requesten, ikke workeren. }
          Res := RespondText('Internal Server Error', 500);
          Close_ := True;
          { En exception fra brukerkode logges alltid, uansett LogRequests.
            Det er ikke en request-linje, det er en feil — og en 500 som
            ikke etterlater seg et spor er en 500 ingen kan feilsøke. }
          LogException(E, 'unhandled exception in handler',
            ['method', Askr.Http.Types.MethodName(Req.Method),
             'path', Req.Path.ToString]);
        end;
      end;

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

    { En enkelt stor request skal ikke få workeren til å holde på minnet.
      Bufferet slippes bare når det ikke ligger noe igjen i det: en klient
      som pipeliner en request rett etter en stor kropp ville ellers fått
      den forkastet. Det krevde både pipelining og en kropp over seksten
      ganger bufferet, så det viste seg ikke — men opplasting gjør begge
      deler vanligere. }
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
      { Lyttesocketen ble lukket av Stop, eller kjernen er tom for
        filhåndtak. I begge tilfeller er det riktig å se på FRunning. }
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
        { Håndtrykket skjer her, ikke i ServeConnection, fordi en klient som
          ikke får det til skal koste én lukket socket og ingenting mer —
          ikke en arena, ikke en logglinje per request. }
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
    Result := RespondText('No handler registered', 500);
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
  { StrToNetAddr melder feil ved å returnere 0.0.0.0, som også er en gyldig
    adresse å lytte på. Derfor sammenliknes det mot teksten. }
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

  { Med Port = 0 velger kjernen. Les den tilbake, ellers vet ingen hvor vi er. }
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

  { Uten dette dreper en klient som lukker tidlig hele prosessen. }
  fpSignal(SIGPIPE, SignalHandler(SIG_IGN));

  { Sertifikatet leses før lyttesocketen åpnes. En feilstavet sti skal gi
    en feilmelding ved oppstart, ikke en port som tar imot og så avviser alt. }
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

  { Å lukke lyttesocketen får accept til å returnere i alle workerne. }
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
