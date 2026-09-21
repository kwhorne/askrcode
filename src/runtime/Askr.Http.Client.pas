{ Askr.Http.Client — talking to somebody else over HTTP.

  Askr has had a server since step 1 and no client. That has been fine
  right up until something has to go out: a webhook, a file to S3, a
  notification to Slack, a call to Anthropic's API. All four were waiting
  on this file.

  **TLS is on, and the certificate is checked.** A client that does not
  verify is worse than no client — it looks as though it works, and it
  does until somebody stands in the middle. `Askr.Tls` does both the chain
  and the host name, and `Insecure` exists for a self-signed certificate
  in development. It says so in the log every single time it is used,
  deliberately.

  **The body is an ordinary string, not an arena slice.** The client is
  also called from queue workers and from start-up, where there is no
  surrounding arena, and a reply that has to outlive the request is the
  usual case. Call `StrDup` yourself if it is to go into an arena.

  **No compression.** The client does not ask for gzip, and so it does not
  get it. Binding zlib to save bandwidth on an API call is the wrong
  trade — it is one more dependency, and Askr has to start on a machine
  without it.

  What is **not** here: HTTP/2, proxy support, a cookie jar, automatic
  retries. All four are real needs for somebody; none of them are for what
  is queued up behind this file. }
unit Askr.Http.Client;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, Sockets, BaseUnix, netdb, ctypes,
  Askr.Core.Text, Askr.Core.Clock, Askr.Core.Log,
  Askr.Http.Types, Askr.Tls;

const
  DefaultConnectTimeoutMs = 10000;
  DefaultReadTimeoutMs = 30000;
  { A redirect chain that never ends is either a bug at the other end or a
    trap. }
  DefaultMaxRedirects = 5;
  { A reply without a Content-Length can in principle last forever. The
    cap is not an optimization, it is a stop. }
  DefaultMaxResponseBytes = 32 * 1024 * 1024;

type
  EHttpClientError = class(Exception);

  THeaderPair = record
    Name: string;
    Value: string;
  end;

  { The reply. Header names are compared case-insensitively, the way HTTP
    says. }
  THttpResponse = record
    Status: Integer;
    Reason: string;
    Headers: array of THeaderPair;
    Body: string;
    { Adressen svaret faktisk kom fra, etter eventuelle omdirigeringer. }
    FinalUrl: string;
    Redirects: Integer;
    ElapsedMs: Int64;

    function Header(const AName: string): string;
    function HasHeader(const AName: string): Boolean;
    function ContentType: string;
    function IsJson: Boolean;
    { 200–299. }
    function Ok: Boolean;
  end;

  { Called for every chunk that comes in when the reply is streamed.
    Return False to abort — that is how an SSE listener stops listening.

    Streaming exists because a long reply otherwise has to sit entirely in
    memory before the caller sees any of it, and because an API that sends
    events never closes the connection by itself. }
  TStreamCallback = function(const Chunk: string): Boolean of object;
  TStreamCallbackProc = function(const Chunk: string): Boolean;

  THttpClient = class
  private
    FHeaders: array of THeaderPair;
    FConnectTimeoutMs: Integer;
    FReadTimeoutMs: Integer;
    FMaxRedirects: Integer;
    FMaxResponseBytes: Int64;
    FInsecure: Boolean;
    FUserAgent: string;
    FLastUrl: string;
    { While streaming, one of these is set. }
    FStream: TStreamCallback;
    FStreamProc: TStreamCallbackProc;
    function Send(const Method, Url, Body, ContentType: string;
      Depth: Integer): THttpResponse;
    function Emit(const Chunk: string): Boolean;
  public
    constructor Create;

    { A header that goes along with every request from this client. The
      same name twice replaces. }
    function WithHeader(const AName, AValue: string): THttpClient;
    { Authorization: Bearer … — the most common of them all. }
    function WithBearer(const Token: string): THttpClient;
    procedure ClearHeaders;

    function Get(const Url: string): THttpResponse;
    function Delete(const Url: string): THttpResponse;
    function Post(const Url, Body: string;
      const ContentType: string = 'application/json'): THttpResponse;
    function Put(const Url, Body: string;
      const ContentType: string = 'application/json'): THttpResponse;
    function Patch(const Url, Body: string;
      const ContentType: string = 'application/json'): THttpResponse;
    function Request(const Method, Url, Body, ContentType: string): THttpResponse;

    { Like Post, but the body is delivered chunk by chunk to the callback
      as it arrives. The reply's Body is then empty. }
    function Stream(const Method, Url, Body, ContentType: string;
      Cb: TStreamCallback): THttpResponse; overload;
    function Stream(const Method, Url, Body, ContentType: string;
      Cb: TStreamCallbackProc): THttpResponse; overload;

    property ConnectTimeoutMs: Integer read FConnectTimeoutMs
      write FConnectTimeoutMs;
    property ReadTimeoutMs: Integer read FReadTimeoutMs write FReadTimeoutMs;
    property MaxRedirects: Integer read FMaxRedirects write FMaxRedirects;
    property MaxResponseBytes: Int64 read FMaxResponseBytes
      write FMaxResponseBytes;
    { Turns off the certificate check. For a self-signed certificate in
      development, and nothing else. Every request logs a warning. }
    property Insecure: Boolean read FInsecure write FInsecure;
    property UserAgent: string read FUserAgent write FUserAgent;
  end;

{ Splits a URL. Returns False on anything that is not an http or https
  address. Port is set to 80 or 443 when it is not there. }
function ParseUrl(const Url: string; out Scheme, Host: string;
  out Port: Word; out PathAndQuery: string): Boolean;

{ Percent-encoding of one value for a query string or a form. }
function UrlEncodeValue(const S: string): string;

implementation

{ ---------------------------------------------------------------- URL -- }

function ParseUrl(const Url: string; out Scheme, Host: string;
  out Port: Word; out PathAndQuery: string): Boolean;
var
  Rest, Vert: string;
  P: Integer;
begin
  Scheme := '';
  Host := '';
  Port := 0;
  PathAndQuery := '/';
  Result := False;

  P := Pos('://', Url);
  if P = 0 then
    Exit;
  Scheme := LowerCase(Copy(Url, 1, P - 1));
  if (Scheme <> 'http') and (Scheme <> 'https') then
    Exit;
  Rest := Copy(Url, P + 3, MaxInt);
  if Rest = '' then
    Exit;

  { The host ends at the first / ? or #. }
  P := 1;
  while (P <= Length(Rest)) and (Rest[P] <> '/') and (Rest[P] <> '?') and
        (Rest[P] <> '#') do
    Inc(P);
  Vert := Copy(Rest, 1, P - 1);
  if P <= Length(Rest) then
  begin
    PathAndQuery := Copy(Rest, P, MaxInt);
    { The fragment is never sent to the server. }
    P := Pos('#', PathAndQuery);
    if P > 0 then
      PathAndQuery := Copy(PathAndQuery, 1, P - 1);
    if PathAndQuery = '' then
      PathAndQuery := '/';
    if PathAndQuery[1] = '?' then
      PathAndQuery := '/' + PathAndQuery;
  end;

  { User info in the address is ignored — it does not belong in a URL, and
    pretending it is not there is safer than passing it on. }
  P := Pos('@', Vert);
  if P > 0 then
    Vert := Copy(Vert, P + 1, MaxInt);

  P := Pos(':', Vert);
  if P > 0 then
  begin
    Host := Copy(Vert, 1, P - 1);
    Port := Word(StrToIntDef(Copy(Vert, P + 1, MaxInt), 0));
    if Port = 0 then
      Exit;
  end
  else
  begin
    Host := Vert;
    if Scheme = 'https' then
      Port := 443
    else
      Port := 80;
  end;
  Result := Host <> '';
end;

function UrlEncodeValue(const S: string): string;
const
  Hex: array[0..15] of Char = '0123456789ABCDEF';
var
  I: Integer;
  C: Char;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if ((C >= 'A') and (C <= 'Z')) or ((C >= 'a') and (C <= 'z')) or
       ((C >= '0') and (C <= '9')) or (C = '-') or (C = '_') or
       (C = '.') or (C = '~') then
      Result := Result + C
    else
      Result := Result + '%' + Hex[Ord(C) shr 4] + Hex[Ord(C) and $0F];
  end;
end;

{ ----------------------------------------------------------- THttpResponse -- }

function THttpResponse.Header(const AName: string): string;
var
  I: Integer;
begin
  for I := 0 to High(Headers) do
    if SameText(Headers[I].Name, AName) then
      Exit(Headers[I].Value);
  Result := '';
end;

function THttpResponse.HasHeader(const AName: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(Headers) do
    if SameText(Headers[I].Name, AName) then
      Exit(True);
  Result := False;
end;

function THttpResponse.ContentType: string;
begin
  Result := Header('Content-Type');
end;

function THttpResponse.IsJson: Boolean;
var
  T: string;
begin
  T := LowerCase(ContentType);
  Result := (Pos('application/json', T) > 0) or (Pos('+json', T) > 0);
end;

function THttpResponse.Ok: Boolean;
begin
  Result := (Status >= 200) and (Status <= 299);
end;

{ ------------------------------------------------------------ forbindelse -- }

type
  { One connection, with or without TLS. It gathers the socket and the TLS
    together so that reading and writing look the same to the rest of the
    code. }
  TConn = class
  private
    FSock: TSocket;
    FTls: TTlsConn;
    FCtx: TTlsContext;
  public
    constructor Create(const Host: string; Port: Word; UseTls, NoVerify: Boolean;
      ConnectMs, ReadMs: Integer);
    destructor Destroy; override;
    procedure SendAll(const S: string);
    { Leser inntil Max bytes. Tom streng betyr at motparten lukket. }
    function Read(Max: Integer): string;
  end;

{ getaddrinfo from libc, not FPC's netdb.

  netdb has its own DNS implementation that reads /etc/resolv.conf and
  speaks UDP itself. It misses where the system manages: in a container
  with Docker Desktop's name server `getent hosts` answered while netdb
  gave up entirely. getaddrinfo goes the way the system itself goes —
  nsswitch, /etc/hosts, DNS, mDNS — and it is what every other program
  uses.

  netdb is kept as a fallback for a system without a working getaddrinfo,
  and because the /etc/hosts path there has been tried. }
const
  AI_ADDRCONFIG = {$IFDEF DARWIN} $00000400 {$ELSE} $0020 {$ENDIF};

type
  PAddrInfo = ^TAddrInfo;
  TAddrInfo = record
    ai_flags: cint;
    ai_family: cint;
    ai_socktype: cint;
    ai_protocol: cint;
{$IFDEF DARWIN}
    ai_addrlen: cuint32;
    ai_canonname: PAnsiChar;
    ai_addr: Pointer;
{$ELSE}
    ai_addrlen: cuint32;
    ai_addr: Pointer;
    ai_canonname: PAnsiChar;
{$ENDIF}
    ai_next: PAddrInfo;
  end;

function getaddrinfo(Node, Service: PAnsiChar; Hints: PAddrInfo;
  out Res: PAddrInfo): cint; cdecl; external 'c' name 'getaddrinfo';
procedure freeaddrinfo(Res: PAddrInfo); cdecl; external 'c' name 'freeaddrinfo';

{ The first IPv4 address for the name. False when the lookup gave none.

  IPv4 only: the rest of Askr uses TInetSockAddr, and IPv6 requires a
  different address family the whole way through. It is a documented limit
  in the server from step 1, and the client inherits it. }
function SlaaOppIPv4(const Host: string; out Addr: TInAddr): Boolean;
var
  Hints: TAddrInfo;
  Res, Cur: PAddrInfo;
  Sa: PInetSockAddr;
begin
  Result := False;
  FillChar(Addr, SizeOf(Addr), 0);
  FillChar(Hints, SizeOf(Hints), 0);
  Hints.ai_family := AF_INET;
  Hints.ai_socktype := SOCK_STREAM;
  Hints.ai_flags := AI_ADDRCONFIG;
  Res := nil;
  if getaddrinfo(PAnsiChar(AnsiString(Host)), nil, @Hints, Res) <> 0 then
    Exit;
  try
    Cur := Res;
    while Cur <> nil do
    begin
      if (Cur^.ai_family = AF_INET) and (Cur^.ai_addr <> nil) then
      begin
        Sa := PInetSockAddr(Cur^.ai_addr);
        Addr := Sa^.sin_addr;
        Exit(True);
      end;
      Cur := Cur^.ai_next;
    end;
  finally
    freeaddrinfo(Res);
  end;
end;

procedure SetTimeout(Sock: TSocket; Which, Ms: Integer);
var
  Tv: TTimeVal;
begin
  Tv.tv_sec := Ms div 1000;
  Tv.tv_usec := (Ms mod 1000) * 1000;
  fpSetSockOpt(Sock, SOL_SOCKET, Which, @Tv, SizeOf(Tv));
end;

constructor TConn.Create(const Host: string; Port: Word;
  UseTls, NoVerify: Boolean; ConnectMs, ReadMs: Integer);
var
  Addr: TInetSockAddr;
  Vert: THostEntry;
begin
  inherited Create;
  FSock := fpSocket(AF_INET, SOCK_STREAM, 0);
  if FSock < 0 then
    raise EHttpClientError.Create('Could not create a socket');

  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := HToNS(Port);
  Addr.sin_addr := StrToNetAddr(Host);
  if Addr.sin_addr.s_addr = 0 then
  begin
    { getaddrinfo first — it does what the system does. netdb as a
      fallback; there GetHostByName returns the address in the host's byte
      order and ResolveHostByName in the network's, and getting that wrong
      gives an address that looks valid and points the wrong way. }
    if not SlaaOppIPv4(Host, Addr.sin_addr) then
    begin
      if GetHostByName(Host, Vert) then
        Addr.sin_addr.s_addr := HToNL(Vert.Addr.s_addr)
      else if ResolveHostByName(Host, Vert) then
        Addr.sin_addr := Vert.Addr
      else
      begin
        CloseSocket(FSock);
        FSock := -1;
        raise EHttpClientError.CreateFmt('Could not resolve %s', [Host]);
      end;
    end;
  end;

  SetTimeout(FSock, SO_SNDTIMEO, ConnectMs);
  SetTimeout(FSock, SO_RCVTIMEO, ReadMs);

  if fpConnect(FSock, @Addr, SizeOf(Addr)) <> 0 then
  begin
    CloseSocket(FSock);
    FSock := -1;
    raise EHttpClientError.CreateFmt('Could not connect to %s:%d',
      [Host, Port]);
  end;

  if not UseTls then
    Exit;

  if not TlsAvailable then
  begin
    CloseSocket(FSock);
    FSock := -1;
    raise EHttpClientError.Create(
      'https needs OpenSSL, and it could not be loaded. Install it, or ' +
      'use http for a local service.');
  end;

  try
    FCtx := TTlsContext.Create(trClient);
    if NoVerify then
      FCtx.SetVerifyPeer(False);
    { The host name is sent both as SNI and as the expected name in the
      certificate. TTlsConn does both. }
    FTls := TTlsConn.Create(FCtx, FSock, Host);
  except
    FTls.Free;
    FTls := nil;
    FCtx.Free;
    FCtx := nil;
    CloseSocket(FSock);
    FSock := -1;
    raise;
  end;
end;

destructor TConn.Destroy;
begin
  FTls.Free;
  FCtx.Free;
  if FSock >= 0 then
    CloseSocket(FSock);
  inherited Destroy;
end;

procedure TConn.SendAll(const S: string);
var
  SentBytes, N: SizeInt;
begin
  SentBytes := 0;
  while SentBytes < Length(S) do
  begin
    if FTls <> nil then
      N := FTls.Write(PByte(@S[1]) + SentBytes, Length(S) - SentBytes)
    else
      N := fpSend(FSock, PByte(@S[1]) + SentBytes, Length(S) - SentBytes, 0);
    if N <= 0 then
      raise EHttpClientError.Create('The connection closed while sending');
    Inc(SentBytes, N);
  end;
end;

function TConn.Read(Max: Integer): string;
var
  Buf: array of Byte;
  N: SizeInt;
begin
  Result := '';
  SetLength(Buf, Max);
  if FTls <> nil then
    N := FTls.Read(@Buf[0], Max)
  else
    N := fpRecv(FSock, @Buf[0], Max, 0);
  if N <= 0 then
    Exit('');
  SetLength(Result, N);
  Move(Buf[0], Result[1], N);
end;

{ ------------------------------------------------------------ THttpClient -- }

constructor THttpClient.Create;
begin
  inherited Create;
  FConnectTimeoutMs := DefaultConnectTimeoutMs;
  FReadTimeoutMs := DefaultReadTimeoutMs;
  FMaxRedirects := DefaultMaxRedirects;
  FMaxResponseBytes := DefaultMaxResponseBytes;
  FUserAgent := 'Askr/1.0';
end;

function THttpClient.WithHeader(const AName, AValue: string): THttpClient;
var
  I, N: Integer;
begin
  Result := Self;
  for I := 0 to High(FHeaders) do
    if SameText(FHeaders[I].Name, AName) then
    begin
      FHeaders[I].Value := AValue;
      Exit;
    end;
  N := Length(FHeaders);
  SetLength(FHeaders, N + 1);
  FHeaders[N].Name := AName;
  FHeaders[N].Value := AValue;
end;

function THttpClient.WithBearer(const Token: string): THttpClient;
begin
  Result := WithHeader('Authorization', 'Bearer ' + Token);
end;

procedure THttpClient.ClearHeaders;
begin
  SetLength(FHeaders, 0);
end;

function THttpClient.Emit(const Chunk: string): Boolean;
begin
  if Assigned(FStream) then
    Exit(FStream(Chunk));
  if Assigned(FStreamProc) then
    Exit(FStreamProc(Chunk));
  Result := True;
end;

{ Reads a line ending in CRLF out of the buffer. False when the line is
  not whole yet. }
function TakeLine(var Buf: string; out Line: string): Boolean;
var
  P: Integer;
begin
  Line := '';
  P := Pos(#13#10, Buf);
  if P = 0 then
    Exit(False);
  Line := Copy(Buf, 1, P - 1);
  System.Delete(Buf, 1, P + 1);
  Result := True;
end;

function THttpClient.Send(const Method, Url, Body, ContentType: string;
  Depth: Integer): THttpResponse;
var
  Scheme, Host, Path_, Line_, Name_, Value_, Ny: string;
  Port: Word;
  C: TConn;
  Req, Buf, Bit: string;
  I, P, ContentLength, Chunk: Integer;
  HeaderDone, Chunked, LukkVedSlutt, Avbrutt: Boolean;
  WasRead: Int64;
  T0: Int64;
begin
  { Not FillChar: THttpResponse has both strings and a dynamic array, and
    FillChar over managed fields leaves references nobody releases. The
    same trap as in Askr.Run. }
  Result.Status := 0;
  Result.Reason := '';
  Result.Headers := nil;
  Result.Body := '';
  Result.FinalUrl := Url;
  Result.Redirects := 0;
  Result.ElapsedMs := 0;

  if Depth > FMaxRedirects then
    raise EHttpClientError.CreateFmt(
      'Too many redirects (%d) starting at %s', [FMaxRedirects, FLastUrl]);

  if not ParseUrl(Url, Scheme, Host, Port, Path_) then
    raise EHttpClientError.CreateFmt(
      '"%s" is not an http or https URL', [Url]);

  if FInsecure and (Scheme = 'https') then
    { Every time, not only the first. A setup that quietly stopped
      verifying is exactly the bug that goes unnoticed. }
    LogWarn('TLS certificate verification is off', ['host', Host]);

  T0 := MonotonicMs;

  { The request. Host is required in HTTP/1.1. Connection: close because
    the client does not reuse connections — one request, one socket. }
  Req := Method + ' ' + Path_ + ' HTTP/1.1'#13#10;
  if ((Scheme = 'https') and (Port <> 443)) or
     ((Scheme = 'http') and (Port <> 80)) then
    Req := Req + 'Host: ' + Host + ':' + IntToStr(Port) + #13#10
  else
    Req := Req + 'Host: ' + Host + #13#10;
  Req := Req + 'User-Agent: ' + FUserAgent + #13#10 +
    'Connection: close'#13#10 +
    { No gzip: without zlib we cannot unpack it, and a client that asks
      for something it cannot read is a bug waiting to happen. }
    'Accept-Encoding: identity'#13#10;
  for I := 0 to High(FHeaders) do
    Req := Req + FHeaders[I].Name + ': ' + FHeaders[I].Value + #13#10;
  if Body <> '' then
  begin
    if ContentType <> '' then
      Req := Req + 'Content-Type: ' + ContentType + #13#10;
    Req := Req + 'Content-Length: ' + IntToStr(Length(Body)) + #13#10;
  end;
  Req := Req + #13#10 + Body;

  C := TConn.Create(Host, Port, Scheme = 'https', FInsecure,
    FConnectTimeoutMs, FReadTimeoutMs);
  try
    C.SendAll(Req);

    Buf := '';
    HeaderDone := False;
    Chunked := False;
    ContentLength := -1;
    LukkVedSlutt := False;
    WasRead := 0;

    { --- statuslinje og headere --- }
    while not HeaderDone do
    begin
      Bit := C.Read(16 * 1024);
      if Bit = '' then
        raise EHttpClientError.CreateFmt(
          'The connection closed before the response head was complete (%s)',
          [Url]);
      Buf := Buf + Bit;
      P := Pos(#13#10#13#10, Buf);
      if P = 0 then
        Continue;

      { Statuslinja. }
      if not TakeLine(Buf, Line_) then
        raise EHttpClientError.Create('Malformed response');
      if Copy(Line_, 1, 5) <> 'HTTP/' then
        raise EHttpClientError.CreateFmt(
          'The response did not start with a status line (%s)', [Url]);
      P := Pos(' ', Line_);
      Result.Status := StrToIntDef(Copy(Line_, P + 1, 3), 0);
      Result.Reason := Trim(Copy(Line_, P + 5, MaxInt));
      if Result.Status = 0 then
        raise EHttpClientError.CreateFmt(
          'The response had no status code (%s)', [Url]);

      while TakeLine(Buf, Line_) do
      begin
        if Line_ = '' then
        begin
          HeaderDone := True;
          Break;
        end;
        P := Pos(':', Line_);
        if P = 0 then
          Continue;
        Name_ := Trim(Copy(Line_, 1, P - 1));
        Value_ := Trim(Copy(Line_, P + 1, MaxInt));
        I := Length(Result.Headers);
        SetLength(Result.Headers, I + 1);
        Result.Headers[I].Name := Name_;
        Result.Headers[I].Value := Value_;
        if SameText(Name_, 'Content-Length') then
          ContentLength := StrToIntDef(Value_, -1)
        else if SameText(Name_, 'Transfer-Encoding') and
                (Pos('chunked', LowerCase(Value_)) > 0) then
          Chunked := True;
      end;
    end;

    { --- omdirigering --- }
    { `in [301, …]` does not work: a Pascal set holds 0..255. }
    if ((Result.Status = 301) or (Result.Status = 302) or
        (Result.Status = 303) or (Result.Status = 307) or
        (Result.Status = 308)) and (FMaxRedirects > 0) then
    begin
      Ny := Result.Header('Location');
      if Ny <> '' then
      begin
        { Relativ Location er lovlig og vanlig. }
        if Pos('://', Ny) = 0 then
        begin
          if (Ny <> '') and (Ny[1] = '/') then
            Ny := Scheme + '://' + Host + ':' + IntToStr(Port) + Ny
          else
            Ny := Scheme + '://' + Host + ':' + IntToStr(Port) + '/' + Ny;
        end;
        FLastUrl := Url;
        { 303 — and in practice 301 and 302 — become GET. 307 and 308 keep
          the method, and that is the whole reason they exist. }
        if (Result.Status = 307) or (Result.Status = 308) then
          Result := Send(Method, Ny, Body, ContentType, Depth + 1)
        else
          Result := Send('GET', Ny, '', '', Depth + 1);
        Result.Redirects := Depth + 1;
        Exit;
      end;
    end;

    { --- kroppen --- }
    if (ContentLength < 0) and not Chunked then
      { Neither a length nor chunked: the body lasts until the connection
        closes. That is legal in HTTP/1.1 together with Connection:
        close. }
      LukkVedSlutt := True;

    if Chunked then
    begin
      repeat
        { The size line is hexadecimal, and may have a semicolon with
          extensions after it. }
        while not TakeLine(Buf, Line_) do
        begin
          Bit := C.Read(16 * 1024);
          if Bit = '' then
            raise EHttpClientError.Create(
              'The connection closed inside a chunked body');
          Buf := Buf + Bit;
        end;
        P := Pos(';', Line_);
        if P > 0 then
          Line_ := Copy(Line_, 1, P - 1);
        Chunk := StrToIntDef('$' + Trim(Line_), -1);
        if Chunk < 0 then
          raise EHttpClientError.CreateFmt(
            'Malformed chunk size "%s"', [Line_]);
        if Chunk = 0 then
          Break;

        { The chunk plus the CRLF after it. }
        while Length(Buf) < Chunk + 2 do
        begin
          Bit := C.Read(16 * 1024);
          if Bit = '' then
            raise EHttpClientError.Create(
              'The connection closed inside a chunked body');
          Buf := Buf + Bit;
        end;
        Inc(WasRead, Chunk);
        if WasRead > FMaxResponseBytes then
          raise EHttpClientError.CreateFmt(
            'The response exceeded %d bytes', [FMaxResponseBytes]);
        Bit := Copy(Buf, 1, Chunk);
        System.Delete(Buf, 1, Chunk + 2);
        if Assigned(FStream) or Assigned(FStreamProc) then
        begin
          if not Emit(Bit) then
            Break;
        end
        else
          Result.Body := Result.Body + Bit;
      until False;
    end
    else
    begin
      { What is already in the buffer is the beginning of the body. }
      Avbrutt := False;
      if Buf <> '' then
      begin
        Inc(WasRead, Length(Buf));
        if Assigned(FStream) or Assigned(FStreamProc) then
          { The answer from the first chunk counts just as much as from the
            others. If it were ignored here, the client read on after the
            callback had said stop — and for an SSE stream that means it
            never stops. }
          Avbrutt := not Emit(Buf)
        else
          Result.Body := Buf;
        Buf := '';
      end;
      while (not Avbrutt) and (LukkVedSlutt or (WasRead < ContentLength)) do
      begin
        Bit := C.Read(64 * 1024);
        if Bit = '' then
          Break;
        Inc(WasRead, Length(Bit));
        if WasRead > FMaxResponseBytes then
          raise EHttpClientError.CreateFmt(
            'The response exceeded %d bytes', [FMaxResponseBytes]);
        if Assigned(FStream) or Assigned(FStreamProc) then
        begin
          if not Emit(Bit) then
            Break;
        end
        else
          Result.Body := Result.Body + Bit;
      end;
    end;
  finally
    C.Free;
  end;

  Result.FinalUrl := Url;
  Result.ElapsedMs := MonotonicMs - T0;
end;

function THttpClient.Request(const Method, Url, Body,
  ContentType: string): THttpResponse;
begin
  FStream := nil;
  FStreamProc := nil;
  FLastUrl := Url;
  Result := Send(Method, Url, Body, ContentType, 0);
end;

function THttpClient.Get(const Url: string): THttpResponse;
begin
  Result := Request('GET', Url, '', '');
end;

function THttpClient.Delete(const Url: string): THttpResponse;
begin
  Result := Request('DELETE', Url, '', '');
end;

function THttpClient.Post(const Url, Body, ContentType: string): THttpResponse;
begin
  Result := Request('POST', Url, Body, ContentType);
end;

function THttpClient.Put(const Url, Body, ContentType: string): THttpResponse;
begin
  Result := Request('PUT', Url, Body, ContentType);
end;

function THttpClient.Patch(const Url, Body, ContentType: string): THttpResponse;
begin
  Result := Request('PATCH', Url, Body, ContentType);
end;

function THttpClient.Stream(const Method, Url, Body, ContentType: string;
  Cb: TStreamCallback): THttpResponse;
begin
  FStream := Cb;
  FStreamProc := nil;
  FLastUrl := Url;
  try
    Result := Send(Method, Url, Body, ContentType, 0);
  finally
    FStream := nil;
  end;
end;

function THttpClient.Stream(const Method, Url, Body, ContentType: string;
  Cb: TStreamCallbackProc): THttpResponse;
begin
  FStream := nil;
  FStreamProc := Cb;
  FLastUrl := Url;
  try
    Result := Send(Method, Url, Body, ContentType, 0);
  finally
    FStreamProc := nil;
  end;
end;

end.
