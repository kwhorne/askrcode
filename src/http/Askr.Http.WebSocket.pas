{ Askr.Http.WebSocket — a connection both ends can write to.

      type
        TChat = class(TWsHandler)
          procedure Text(C: TWsConnection; const Msg: string); override;
        end;

      procedure TChat.Text(C: TWsConnection; const Msg: string);
      begin
        Broadcast('room.' + C.Tag, 'said', Msg);
      end;

      // the route
      function TRooms.Join(Req: TRequest): TResponse;
      begin
        Result := AcceptWebSocket(Req, Chat, ['room.1'], Askr.Auth.Id);
      end;

  RFC 6455. A server-sent event stream goes one way; a websocket goes
  both, for what the browser has to say often and fast -- a game, a shared
  cursor, a chat. What a browser says now and then is an ordinary request,
  and a stream is simpler for everything the server says.

  **A websocket does not hold a worker**, for the same reason a stream
  does not: the worker answers 101 and hands the connection to a thread of
  its own. Bytes the client sent right behind the handshake go with it.

  **The origin is checked.** A browser sends its cookies with a websocket
  handshake from any site, and a server that took it would let any page
  open a socket as the signed-in user -- cross-site websocket hijacking.
  A handshake whose Origin is not app.url's, or one added with
  AddWebSocketOrigin, is refused 403. A client that sends no Origin is not
  a browser, and is let through: it has no cookies of anybody else's.

  **The handler runs in the connection's thread**, one message at a time,
  with an arena reset between messages -- like a request. One handler
  object serves every connection, from as many threads, so it keeps no
  state of its own that is not guarded. The session is not there: the
  route passes what it needs, the user id above all, and the connection
  keeps it.

  **Broadcast reaches websockets too.** A channel given to AcceptWebSocket
  or joined later gets every Broadcast on it as a text message:
  {"id":..,"event":..,"data":..}, with the data as the string it was sent
  as.

  Held to the Autobahn test suite by ./askr ws:check: every case except
  compression and the performance runs, which this does not do. }
unit Askr.Http.WebSocket;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs, Sockets, BaseUnix,
  Askr.Core.Arena, Askr.Core.Text, Askr.Http.Request, Askr.Http.Response,
  Askr.Http.Stream, Askr.Tls;

type
  EWebSocketError = class(Exception);

  TWsConnection = class;

  { What the application does with a connection. Override what it needs;
    the defaults do nothing. }
  TWsHandler = class
  public
    procedure Opened(C: TWsConnection); virtual;
    procedure Text(C: TWsConnection; const Msg: string); virtual;
    procedure Binary(C: TWsConnection; const Data: TBytes); virtual;
    { Code is what the client closed with, or 1006 when it went without
      closing. }
    procedure Closed(C: TWsConnection; Code: Word); virtual;
  end;

  TWsConnection = class(TThread)
  private
    FSock: TSocket;
    FTls: TTlsConn;
    FHandler: TWsHandler;
    FChannels: TStringList;
    FUserId: string;
    FTag: string;
    FBuf: string;
    FSendLock: TCriticalSection;
    FClosing: Boolean;
    FArena: TArena;
    function Fill: Integer;
    function Need(N: Integer): Boolean;
    function SendFrame(Opcode: Byte; const Payload: string): Boolean;
    procedure Fail(Code: Word);
  protected
    procedure Execute; override;
  public
    constructor Create(ASock: TSocket; ATls: TTlsConn; AHandler: TWsHandler;
      const AChannels, AUserId, ALeftover: string);
    destructor Destroy; override;
    { Safe from any thread: a handler answering, a broadcast, a job. }
    procedure SendText(const S: string);
    procedure SendBinary(const B: TBytes);
    procedure Close(Code: Word = 1000; const Reason: string = '');
    procedure Join(const Channel: string);
    procedure Leave(const Channel: string);
    function Listens(const Channel: string): Boolean;
    { Who the route said this is. }
    property UserId: string read FUserId;
    { Anything the handler wants to keep on the connection. }
    property Tag: string read FTag write FTag;
    { Reset before each message, as a request's is. }
    property Arena: TArena read FArena;
  end;

{ The response that makes this request a websocket: 101 when the
  handshake is one, and 400, 403 or 426 when it is not. Channels get every
  Broadcast; UserId is kept on the connection. }
function AcceptWebSocket(Req: TRequest; Handler: TWsHandler;
  const Channels: array of string; const UserId: string = ''): TResponse;
{ Another origin whose pages may open a websocket here, as
  scheme://host[:port]. app.url's is allowed already. }
procedure AddWebSocketOrigin(const Origin: string);
{ The value of Sec-WebSocket-Accept for a key. Exposed for the test. }
function WebSocketAccept(const Key: string): string;
function OpenWebSockets: Integer;
{ The largest message taken, in bytes; a larger one closes with 1009. 1 MB
  unless set. }
procedure SetWebSocketMaxMessage(Bytes: Integer);
{ How long a connection may be quiet before a ping, in ms. 30 s. }
procedure SetWebSocketPing(Ms: Integer);

{ The server's side. }
function WebSocketSlotFree: Boolean;
procedure StartWebSocket(Upgrade: TObject; Sock: TSocket; Tls: TTlsConn;
  const Leftover: string);
procedure StopWebSockets;

implementation

uses
  Askr.Core.Crypto, Askr.Core.Url, Askr.Core.Log, Askr.Core.Json;

const
  WsGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

type
  { What AcceptWebSocket leaves on the response for the server. }
  TWsUpgrade = class
    Handler: TWsHandler;
    Channels: string;
    UserId: string;
  end;

var
  GLock: TCriticalSection;
  GConnections: TList;
  GOrigins: TStringList;
  GMaxMessage: Integer = 1024 * 1024;
  GPingMs: Integer = 30000;
  GStopping: Boolean = False;
  GMaxConnections: Integer = 1000;

procedure SetWebSocketMaxMessage(Bytes: Integer);
begin
  GMaxMessage := Bytes;
end;

procedure SetWebSocketPing(Ms: Integer);
begin
  GPingMs := Ms;
end;

procedure AddWebSocketOrigin(const Origin: string);
begin
  GLock.Acquire;
  try
    GOrigins.Add(LowerCase(Origin));
  finally
    GLock.Release;
  end;
end;

{ TWsHandler }

procedure TWsHandler.Opened(C: TWsConnection);
begin
end;

procedure TWsHandler.Text(C: TWsConnection; const Msg: string);
begin
end;

procedure TWsHandler.Binary(C: TWsConnection; const Data: TBytes);
begin
end;

procedure TWsHandler.Closed(C: TWsConnection; Code: Word);
begin
end;

function WebSocketAccept(const Key: string): string;
var
  D: TSha1Digest;
  B: TBytes;
  S: string;
begin
  S := Key + WsGuid;
  B := nil;
  SetLength(B, Length(S));
  Move(S[1], B[0], Length(S));
  D := Sha1(B);
  SetLength(B, 20);
  Move(D[0], B[0], 20);
  Result := Base64Encode(B);
end;

{ scheme://host[:port] of a URL, lower case. }
function OriginOf(const Url: string): string;
var
  P: Integer;
  Rest: string;
begin
  P := Pos('://', Url);
  if P = 0 then
    Exit('');
  Rest := Copy(Url, P + 3, MaxInt);
  if Pos('/', Rest) > 0 then
    Rest := Copy(Rest, 1, Pos('/', Rest) - 1);
  Result := LowerCase(Copy(Url, 1, P + 2) + Rest);
end;

function OriginAllowed(const Origin: string): Boolean;
var
  O: string;
begin
  O := LowerCase(Origin);
  if (AppUrl <> '') and (O = OriginOf(AppUrl)) then
    Exit(True);
  GLock.Acquire;
  try
    Result := GOrigins.IndexOf(O) >= 0;
  finally
    GLock.Release;
  end;
end;

function HasToken(const Header, Token: string): Boolean;
begin
  Result := Pos(LowerCase(Token), LowerCase(Header)) > 0;
end;

function AcceptWebSocket(Req: TRequest; Handler: TWsHandler;
  const Channels: array of string; const UserId: string): TResponse;
var
  Key, Origin, All: string;
  U: TWsUpgrade;
  I, J: Integer;
begin
  if Handler = nil then
    raise EWebSocketError.Create('AcceptWebSocket needs a handler');
  All := '';
  for I := 0 to High(Channels) do
  begin
    for J := 1 to Length(Channels[I]) do
      if not (Channels[I][J] in ['A'..'Z', 'a'..'z', '0'..'9', '.', '_', ':', '-']) then
        raise EWebSocketError.CreateFmt('"%s" is not a channel name', [Channels[I]]);
    if All <> '' then
      All := All + ',';
    All := All + Channels[I];
  end;
  if not HasToken(Req.Header('upgrade').ToString, 'websocket') or
     not HasToken(Req.Header('connection').ToString, 'upgrade') then
    Exit(ErrorResponse(400, 'This route is a websocket: it wants Upgrade: websocket'));
  if Trim(Req.Header('sec-websocket-version').ToString) <> '13' then
    Exit(ErrorResponse(426).WithHeader('Sec-WebSocket-Version', '13'));
  Key := Trim(Req.Header('sec-websocket-key').ToString);
  if Length(Base64Decode(Key)) <> 16 then
    Exit(ErrorResponse(400, 'Sec-WebSocket-Key is not 16 bytes of base64'));
  Origin := Trim(Req.Header('origin').ToString);
  if (Origin <> '') and not OriginAllowed(Origin) then
    Exit(ErrorResponse(403, 'Websockets from ' + Origin + ' are not taken here'));
  U := TWsUpgrade.Create;
  U.Handler := Handler;
  U.Channels := All;
  U.UserId := UserId;
  Result := Respond(101)
    .WithHeader('Upgrade', 'websocket')
    .WithHeader('Connection', 'Upgrade')
    .WithHeader('Sec-WebSocket-Accept', WebSocketAccept(Key));
  Result.MarkUpgrade(U);
end;

function OpenWebSockets: Integer;
begin
  GLock.Acquire;
  try
    Result := GConnections.Count;
  finally
    GLock.Release;
  end;
end;

function WebSocketSlotFree: Boolean;
begin
  Result := (not GStopping) and (OpenWebSockets < GMaxConnections);
end;

procedure StartWebSocket(Upgrade: TObject; Sock: TSocket; Tls: TTlsConn;
  const Leftover: string);
var
  U: TWsUpgrade;
  C: TWsConnection;
begin
  U := TWsUpgrade(Upgrade);
  try
    C := TWsConnection.Create(Sock, Tls, U.Handler, U.Channels, U.UserId, Leftover);
  finally
    U.Free;
  end;
  GLock.Acquire;
  try
    GConnections.Add(C);
  finally
    GLock.Release;
  end;
  C.Start;
end;

procedure StopWebSockets;
var
  I, Waited: Integer;
begin
  GLock.Acquire;
  try
    GStopping := True;
    for I := 0 to GConnections.Count - 1 do
    begin
      TWsConnection(GConnections[I]).FClosing := True;
      { A thread blocked in recv wakes when the socket is shut. }
      fpShutdown(TWsConnection(GConnections[I]).FSock, 2);
    end;
  finally
    GLock.Release;
  end;
  Waited := 0;
  while (OpenWebSockets > 0) and (Waited < 2000) do
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

{ A broadcast, as a text message to every websocket on the channel. Sent
  under the lock: a connection frees itself when its thread ends, and it
  leaves the list under this lock first, so nothing here can reach one
  that has gone. A client that does not read is bounded by the send
  timeout the worker set on its socket. }
procedure DeliverBroadcast(Id: Int64; const Channel, Event, Data: string);
var
  I: Integer;
  A: TArena;
  W: TJsonWriter;
  Msg: string;
  C: TWsConnection;
begin
  A := TArena.Create(1024);
  try
    W.Init(A, 256);
    W.BeginObject;
    W.Field('id', Id);
    W.Field('event', Event);
    W.Field('data', Data);
    W.EndObject;
    Msg := W.ToString;
  finally
    A.Free;
  end;
  GLock.Acquire;
  try
    for I := 0 to GConnections.Count - 1 do
    begin
      C := TWsConnection(GConnections[I]);
      if (not C.FClosing) and (C.FChannels.IndexOf(Channel) >= 0) then
        C.SendFrame($1, Msg);
    end;
  finally
    GLock.Release;
  end;
end;

{ ------------------------------------------------------------ UTF-8 -- }

{ Strict: no overlong forms, no surrogates, nothing past U+10FFFF. A
  websocket closes with 1007 on text that is not UTF-8, and a lenient
  check is one Autobahn fails. }
function ValidUtf8(const S: string): Boolean;
var
  I, N, Need: Integer;
  B: Byte;
  Cp, Min: Cardinal;
begin
  I := 1;
  N := Length(S);
  while I <= N do
  begin
    B := Ord(S[I]);
    if B < $80 then
    begin
      Inc(I);
      Continue;
    end
    else if (B and $E0) = $C0 then begin Need := 1; Cp := B and $1F; Min := $80; end
    else if (B and $F0) = $E0 then begin Need := 2; Cp := B and $0F; Min := $800; end
    else if (B and $F8) = $F0 then begin Need := 3; Cp := B and $07; Min := $10000; end
    else
      Exit(False);
    if I + Need > N then
      Exit(False);
    while Need > 0 do
    begin
      Inc(I);
      B := Ord(S[I]);
      if (B and $C0) <> $80 then
        Exit(False);
      Cp := (Cp shl 6) or (B and $3F);
      Dec(Need);
    end;
    if (Cp < Min) or (Cp > $10FFFF) or ((Cp >= $D800) and (Cp <= $DFFF)) then
      Exit(False);
    Inc(I);
  end;
  Result := True;
end;

function ValidCloseCode(Code: Word): Boolean;
begin
  Result := ((Code >= 1000) and (Code <= 1003)) or ((Code >= 1007) and (Code <= 1011)) or
    ((Code >= 3000) and (Code <= 4999));
end;

{ TWsConnection }

constructor TWsConnection.Create(ASock: TSocket; ATls: TTlsConn;
  AHandler: TWsHandler; const AChannels, AUserId, ALeftover: string);
begin
  FSock := ASock;
  FTls := ATls;
  FHandler := AHandler;
  FUserId := AUserId;
  FBuf := ALeftover;
  FChannels := TStringList.Create;
  FChannels.StrictDelimiter := True;
  FChannels.Delimiter := ',';
  FChannels.DelimitedText := AChannels;
  FSendLock := TCriticalSection.Create;
  FArena := TArena.Create(16 * 1024);
  FreeOnTerminate := True;
  inherited Create(True, 256 * 1024);
end;

destructor TWsConnection.Destroy;
begin
  FArena.Free;
  FSendLock.Free;
  FChannels.Free;
  inherited Destroy;
end;

function TWsConnection.Listens(const Channel: string): Boolean;
begin
  GLock.Acquire;
  try
    Result := FChannels.IndexOf(Channel) >= 0;
  finally
    GLock.Release;
  end;
end;

procedure TWsConnection.Join(const Channel: string);
begin
  GLock.Acquire;
  try
    if FChannels.IndexOf(Channel) < 0 then
      FChannels.Add(Channel);
  finally
    GLock.Release;
  end;
end;

procedure TWsConnection.Leave(const Channel: string);
var
  I: Integer;
begin
  GLock.Acquire;
  try
    I := FChannels.IndexOf(Channel);
    if I >= 0 then
      FChannels.Delete(I);
  finally
    GLock.Release;
  end;
end;

{ Bytes, as many as come: > 0, 0 for a quiet timeout, < 0 for a closed or
  broken connection. }
function TWsConnection.Fill: Integer;
var
  Tmp: array[0..16383] of Byte;
  E: Integer;
begin
  if FTls <> nil then
    Result := FTls.Read(@Tmp[0], SizeOf(Tmp))
  else
    Result := fpRecv(FSock, @Tmp[0], SizeOf(Tmp), 0);
  if Result > 0 then
  begin
    SetLength(FBuf, Length(FBuf) + Result);
    Move(Tmp[0], FBuf[Length(FBuf) - Result + 1], Result);
    Exit;
  end;
  if Result = 0 then
    Exit(-1);
  E := fpGetErrno;
  if (E = ESysEAGAIN) or (E = ESysEWOULDBLOCK) or (E = ESysEINTR) then
    Result := 0
  else
    Result := -1;
end;

{ At least N bytes in the buffer, waiting as long as it takes -- a ping
  when it goes quiet, and giving up when the connection does. }
function TWsConnection.Need(N: Integer): Boolean;
var
  R, Quiet: Integer;
begin
  Quiet := 0;
  while Length(FBuf) < N do
  begin
    if FClosing and (Quiet > 0) then
      Exit(False);
    R := Fill;
    if R < 0 then
      Exit(False);
    if R = 0 then
    begin
      Inc(Quiet);
      { Quiet twice over: the client stopped answering pings. }
      if Quiet > 2 then
        Exit(False);
      if not SendFrame($9, '') then
        Exit(False);
    end
    else
      Quiet := 0;
  end;
  Result := True;
end;

function TWsConnection.SendFrame(Opcode: Byte; const Payload: string): Boolean;
var
  H: string;
  L: Int64;
  I, Sent, N: Integer;
  All: string;
begin
  L := Length(Payload);
  H := Chr($80 or Opcode);
  if L < 126 then
    H := H + Chr(L)
  else if L < 65536 then
    H := H + Chr(126) + Chr(L shr 8) + Chr(L and $FF)
  else
  begin
    H := H + Chr(127);
    for I := 7 downto 0 do
      H := H + Chr((L shr (8 * I)) and $FF);
  end;
  All := H + Payload;
  FSendLock.Acquire;
  try
    if FTls <> nil then
      Exit(FTls.WriteAll(@All[1], Length(All)));
    Sent := 0;
    while Sent < Length(All) do
    begin
      N := fpSend(FSock, @All[Sent + 1], Length(All) - Sent, 0);
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
  finally
    FSendLock.Release;
  end;
end;

procedure TWsConnection.SendText(const S: string);
begin
  SendFrame($1, S);
end;

procedure TWsConnection.SendBinary(const B: TBytes);
var
  S: string;
begin
  S := '';
  SetLength(S, Length(B));
  if Length(B) > 0 then
    Move(B[0], S[1], Length(B));
  SendFrame($2, S);
end;

procedure TWsConnection.Close(Code: Word; const Reason: string);
begin
  if FClosing then
    Exit;
  FClosing := True;
  SendFrame($8, Chr(Code shr 8) + Chr(Code and $FF) + Reason);
end;

{ A protocol fault: the close the RFC names, and the connection goes. }
procedure TWsConnection.Fail(Code: Word);
begin
  if not FClosing then
  begin
    FClosing := True;
    SendFrame($8, Chr(Code shr 8) + Chr(Code and $FF));
  end;
end;

procedure TWsConnection.Execute;
var
  B0, B1, Opcode: Byte;
  Fin, Masked: Boolean;
  Len: Int64;
  HeadLen, I: Integer;
  Mask: array[0..3] of Byte;
  Payload, Message_: string;
  MessageOp: Byte;
  CloseCode: Word;
  Prev: TArena;
  Data: TBytes;
  TV: TTimeVal;
begin
  CloseCode := 1006;
  MessageOp := 0;
  Message_ := '';
  TV.tv_sec := GPingMs div 1000;
  TV.tv_usec := (GPingMs mod 1000) * 1000;
  fpSetSockOpt(FSock, SOL_SOCKET, SO_RCVTIMEO, @TV, SizeOf(TV));
  try
    Prev := UseArena(FArena);
    try
      try
        FHandler.Opened(Self);
      finally
        UseArena(Prev);
      end;
      while not FClosing or (Length(FBuf) > 0) do
      begin
        if not Need(2) then
          Break;
        B0 := Ord(FBuf[1]);
        B1 := Ord(FBuf[2]);
        Fin := (B0 and $80) <> 0;
        Opcode := B0 and $0F;
        Masked := (B1 and $80) <> 0;
        Len := B1 and $7F;
        HeadLen := 2;
        { No extension is agreed, so no reserved bit may be set, and a
          client's frames are always masked. }
        if ((B0 and $70) <> 0) or not Masked then
        begin
          Fail(1002);
          Break;
        end;
        if Len = 126 then
        begin
          if not Need(4) then Break;
          Len := (Ord(FBuf[3]) shl 8) or Ord(FBuf[4]);
          HeadLen := 4;
        end
        else if Len = 127 then
        begin
          if not Need(10) then Break;
          Len := 0;
          for I := 3 to 10 do
            Len := (Len shl 8) or Ord(FBuf[I]);
          HeadLen := 10;
        end;
        if (Len < 0) or (Len > GMaxMessage) or
           (Length(Message_) + Len > GMaxMessage) then
        begin
          Fail(1009);
          Break;
        end;
        if not Need(HeadLen + 4 + Integer(Len)) then
          Break;
        for I := 0 to 3 do
          Mask[I] := Ord(FBuf[HeadLen + 1 + I]);
        Payload := Copy(FBuf, HeadLen + 5, Integer(Len));
        Delete(FBuf, 1, HeadLen + 4 + Integer(Len));
        for I := 1 to Length(Payload) do
          Payload[I] := Chr(Ord(Payload[I]) xor Mask[(I - 1) mod 4]);

        if Opcode >= $8 then
        begin
          { A control frame: whole, short, and answered at once, even in
            the middle of a fragmented message. }
          if (not Fin) or (Length(Payload) > 125) then
          begin
            Fail(1002);
            Break;
          end;
          case Opcode of
            $8:
              begin
                if Length(Payload) = 1 then
                begin
                  Fail(1002);
                  Break;
                end;
                if Length(Payload) >= 2 then
                begin
                  CloseCode := (Ord(Payload[1]) shl 8) or Ord(Payload[2]);
                  if not ValidCloseCode(CloseCode) then
                  begin
                    Fail(1002);
                    Break;
                  end;
                  if not ValidUtf8(Copy(Payload, 3, MaxInt)) then
                  begin
                    Fail(1007);
                    Break;
                  end;
                end
                else
                  CloseCode := 1005;
                { The close comes back with the same code, and then the
                  connection goes. }
                if not FClosing then
                begin
                  FClosing := True;
                  if CloseCode = 1005 then
                    SendFrame($8, '')
                  else
                    SendFrame($8, Copy(Payload, 1, 2));
                end;
                Break;
              end;
            $9: SendFrame($A, Payload);
            $A: ;
          else
            Fail(1002);
            Break;
          end;
          Continue;
        end;

        case Opcode of
          $0:
            if MessageOp = 0 then
            begin
              { A continuation of nothing. }
              Fail(1002);
              Break;
            end;
          $1, $2:
            if MessageOp <> 0 then
            begin
              { A new message before the last one ended. }
              Fail(1002);
              Break;
            end
            else
              MessageOp := Opcode;
        else
          Fail(1002);
          Break;
        end;
        Message_ := Message_ + Payload;
        if not Fin then
          Continue;

        if (MessageOp = $1) and not ValidUtf8(Message_) then
        begin
          Fail(1007);
          Break;
        end;
        FArena.Reset;
        Prev := UseArena(FArena);
        try
          try
            if MessageOp = $1 then
              FHandler.Text(Self, Message_)
            else
            begin
              Data := nil;
              SetLength(Data, Length(Message_));
              if Message_ <> '' then
                Move(Message_[1], Data[0], Length(Message_));
              FHandler.Binary(Self, Data);
            end;
          except
            on E: Exception do
            begin
              LogException(E, 'websocket handler failed', ['user', FUserId]);
              Fail(1011);
            end;
          end;
        finally
          UseArena(Prev);
        end;
        MessageOp := 0;
        Message_ := '';
      end;
    finally
      Prev := UseArena(FArena);
      try
        try
          FHandler.Closed(Self, CloseCode);
        except
          on E: Exception do
            LogException(E, 'websocket handler failed on close', ['user', FUserId]);
        end;
      finally
        UseArena(Prev);
      end;
    end;
  finally
    GLock.Acquire;
    try
      GConnections.Remove(Self);
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
  GConnections := TList.Create;
  GOrigins := TStringList.Create;
  AddBroadcastSink(DeliverBroadcast);

finalization
  GOrigins.Free;
  GConnections.Free;
  GLock.Free;

end.
