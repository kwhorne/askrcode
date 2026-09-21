{ Askr.Mail — mail, with transports you can swap.

  A message is built the same way wherever it ends up. The transport
  decides what actually happens: in development it is written to a file or
  to the terminal, in production it goes over SMTP or a provider's HTTP
  API.

  The SMTP transport requires STARTTLS by default. If you want plaintext —
  against a relay on loopback, or against Mailpit in development — you say
  smtpPlain. That way round is deliberate: a setup that quietly falls back
  to plaintext when the server does not offer encryption is worse than one
  that stops and says so.

  TLS assumes OpenSSL is on the machine. See Askr.Tls; on macOS it has to
  be installed by hand.

  The queue is the natural place to send from: SMTP is slow, and a request
  should not wait on somebody else's server. }
unit Askr.Mail;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, Sockets, BaseUnix,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Clock, Askr.Core.Config,
  Askr.Core.Crypto, netdb, Askr.Tls;

type
  EMailError = class(Exception);

  TMailAddress = record
    Address: string;
    Name_: string;
  end;

  { Named, because a property cannot have an anonymous array type — and
    transports outside this unit need to read the recipients structurally,
    not only as finished rendered text. }
  TMailAddressArray = array of TMailAddress;

  TMailMessage = class
  private
    FFrom: TMailAddress;
    FTo: TMailAddressArray;
    FCc: TMailAddressArray;
    FBcc: TMailAddressArray;
    FSubject: string;
    FText: string;
    FHtml: string;
    FHeaders: TStringList;
    FMessageId: string;
    FIdempotency: string;
    function Recipients: TStringArray;
  public
    constructor Create;
    destructor Destroy; override;

    function From(const AAddress: string;
      const AName: string = ''): TMailMessage;
    function AddTo(const AAddress: string;
      const AName: string = ''): TMailMessage;
    function Cc(const AAddress: string;
      const AName: string = ''): TMailMessage;
    function Bcc(const AAddress: string;
      const AName: string = ''): TMailMessage;
    function Subject(const S: string): TMailMessage;
    function Text(const S: string): TMailMessage;
    function Html(const S: string): TMailMessage;
    function Header(const Name_, Value: string): TMailMessage;

    { A key that makes it safe to send the message again. Providers that
      support it refuse the second send rather than delivering two emails;
      the SMTP transport ignores it.

      The point is the queue: a job that fails after the provider accepted
      the message is retried, and without a key that survives the retry
      the recipient gets two. Set it to something that is the same across
      a retry — the job id, the order number — never to anything
      random. }
    function Idempotency(const Key: string): TMailMessage;

    { The Message-ID, created if it does not exist yet. Render uses the same
      one, so there are not two ways of getting at it. }
    function EnsureMessageId: string;

    { The whole message as RFC 5322 text. Bcc is left out of the head but is
      in the recipient list — that is the whole point of Bcc. }
    function Render: string;
    property AllRecipients: TStringArray read Recipients;
    property Sender: TMailAddress read FFrom;

    { Read access for transports that build their own format rather than
      sending the RFC 5322 text. The names are not the same as the
      builders' — Subject is already a setter. }
    property ToList: TMailAddressArray read FTo;
    property CcList: TMailAddressArray read FCc;
    property BccList: TMailAddressArray read FBcc;
    property SubjectLine: string read FSubject;
    property TextBody: string read FText;
    property HtmlBody: string read FHtml;
    property ExtraHeaders: TStringList read FHeaders;
    property IdempotencyKey: string read FIdempotency;
  end;

  TMailTransport = class
  public
    procedure Send(M: TMailMessage); virtual; abstract;
    function Describe: string; virtual; abstract;
  end;

  { Writes the message to a file, or to stdout when the path is empty. The
    default in development: nothing is sent, everything can be read. }
  TLogTransport = class(TMailTransport)
  private
    FPath: string;
    FCount: Integer;
  public
    constructor Create(const APath: string = '');
    procedure Send(M: TMailMessage); override;
    function Describe: string; override;
    property Count: Integer read FCount;
  end;

  { Discards everything. It exists for tests that want no side
    effects. }
  TNullTransport = class(TMailTransport)
  private
    FCount: Integer;
    FLast: string;
  public
    procedure Send(M: TMailMessage); override;
    function Describe: string; override;
    property Count: Integer read FCount;
    property LastMessage: string read FLast;
  end;

  { How the connection is secured.

    smtpStartTls is the default because it is the right answer in nearly
    every case, and because an arrangement that quietly falls back to
    plaintext is worse than one that says so. If you want plaintext, you
    say so. }
  TSmtpSecurity = (
    { No encryption. For a local relay on loopback, and nowhere else. }
    smtpPlain,
    { Require STARTTLS. If the server does not offer it, the send is
      aborted. }
    smtpStartTls,
    { TLS from the first byte, with no plaintext phase. Usually port
      465. }
    smtpTlsDirect);

  TSmtpTransport = class(TMailTransport)
  private
    FHost: string;
    FPort: Word;
    FTimeoutMs: Integer;
    FSock: TSocket;
    FSecurity: TSmtpSecurity;
    FVerifyPeer: Boolean;
    FCtx: TTlsContext;
    FTls: TTlsConn;
    FEhlo: string;
    FUsername: string;
    FPassword: string;
    FAllowPlainAuth: Boolean;
    procedure Authenticate;
    function OffersMechanism(const Mech: string): Boolean;
    function ReadLine: string;
    function Expect(const Code: string): string;
    procedure SendLine(const S: string);
    procedure Connect;
    procedure StartTls;
    { EHLO, and collecting what the server says it can do. }
    procedure Greet;
    function Offers(const Capability: string): Boolean;
  public
    constructor Create(const AHost: string; APort: Word = 25;
      ASecurity: TSmtpSecurity = smtpStartTls);
    destructor Destroy; override;
    procedure Send(M: TMailMessage); override;
    function Describe: string; override;

    { The username and password for the relay. An empty username means no
      AUTH — a relay on loopback often does not have it.

      AUTH is never sent over an unencrypted connection. The password in
      PLAIN and LOGIN goes over the wire in the clear, and a setup that
      sends it anyway has given the password to everyone watching the
      traffic. If you want smtpPlain and AUTH at the same time, it has to
      be against loopback, and then AllowPlainAuth says so explicitly. }
    procedure Credentials(const AUser, APassword: string);
    property TimeoutMs: Integer read FTimeoutMs write FTimeoutMs;
    property AllowPlainAuth: Boolean read FAllowPlainAuth
      write FAllowPlainAuth;
    { Off only for self-signed certificates in tests. A client that does not
      verify has encryption, but no idea who it is talking to. }
    property VerifyPeer: Boolean read FVerifyPeer write FVerifyPeer;
    property Security: TSmtpSecurity read FSecurity;
  end;

  TMailer = class
  private
    FTransport: TMailTransport;
    FOwnsTransport: Boolean;
    FDefaultFrom: TMailAddress;
    FSent: QWord;
  public
    constructor Create(ATransport: TMailTransport; AOwns: Boolean = True);
    destructor Destroy; override;
    function Message_: TMailMessage;
    procedure Send(M: TMailMessage; FreeAfter: Boolean = True);
    procedure SetDefaultFrom(const AAddress, AName: string);
    property Transport: TMailTransport read FTransport;
    property Sent: QWord read FSent;
  end;

function Mail: TMailer;
procedure SetMail(AMailer: TMailer);

{ The address as it should appear in a header: "Name" <address>, or just
  the address. Exported because transports outside this unit need exactly
  the same quoting — a comma in an unquoted name splits the address field
  in two, and then the wrong person gets the mail. }
function FormatMailAddress(const A: TMailAddress): string;

type
  { One transport built out of the configuration. The name it registers
    under is what mail.transport is set to. }
  TMailTransportFactory = function: TMailTransport;

{ Makes a transport name available to MailFromConfig. Askr.Mail.Resend
  registers 'resend' in its initialization — an app that does not use that
  unit does not link the HTTP client, and mail.transport = resend then
  says what is missing rather than quietly falling back to something
  else. }
procedure RegisterMailTransport(const Name_: string;
  F: TMailTransportFactory);

{ The transport mail.transport points at. 'log' is the default, because
  it is the right answer in development: nothing is sent, everything can
  be read.

  'smtp' reads mail.host, mail.port, mail.username, mail.password and
  mail.encryption; 'null' discards everything. An unknown name raises and
  says which ones exist — a typo here would otherwise send the production
  mail to a log file. }
function MailFromConfig: TMailTransport;

implementation

var
  GMailer: TMailer = nil;

function Mail: TMailer;
begin
  if GMailer = nil then
    raise EMailError.Create('No mailer is configured. Call SetMail at startup.');
  Result := GMailer;
end;

procedure SetMail(AMailer: TMailer);
begin
  GMailer := AMailer;
end;

function FormatMailAddress(const A: TMailAddress): string;
begin
  if A.Name_ = '' then
    Result := A.Address
  else
    { The name is always quoted. A comma in an unquoted name splits the
      address field in two, and then the wrong person gets the mail. }
    Result := '"' + StringReplace(A.Name_, '"', '''', [rfReplaceAll]) +
      '" <' + A.Address + '>';
end;

function Fold(const A: TMailAddress): string;
begin
  Result := FormatMailAddress(A);
end;

function FoldList(const L: array of TMailAddress): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(L) do
  begin
    if I > 0 then
      Result := Result + ', ';
    Result := Result + Fold(L[I]);
  end;
end;

{ TMailMessage }

constructor TMailMessage.Create;
begin
  inherited Create;
  FHeaders := TStringList.Create;
end;

destructor TMailMessage.Destroy;
begin
  FHeaders.Free;
  inherited Destroy;
end;

function TMailMessage.From(const AAddress, AName: string): TMailMessage;
begin
  FFrom.Address := AAddress;
  FFrom.Name_ := AName;
  Result := Self;
end;

function TMailMessage.AddTo(const AAddress, AName: string): TMailMessage;
var
  I: Integer;
begin
  I := Length(FTo);
  SetLength(FTo, I + 1);
  FTo[I].Address := AAddress;
  FTo[I].Name_ := AName;
  Result := Self;
end;

function TMailMessage.Cc(const AAddress, AName: string): TMailMessage;
var
  I: Integer;
begin
  I := Length(FCc);
  SetLength(FCc, I + 1);
  FCc[I].Address := AAddress;
  FCc[I].Name_ := AName;
  Result := Self;
end;

function TMailMessage.Bcc(const AAddress, AName: string): TMailMessage;
var
  I: Integer;
begin
  I := Length(FBcc);
  SetLength(FBcc, I + 1);
  FBcc[I].Address := AAddress;
  FBcc[I].Name_ := AName;
  Result := Self;
end;

function TMailMessage.Subject(const S: string): TMailMessage;
begin
  FSubject := S;
  Result := Self;
end;

function TMailMessage.Text(const S: string): TMailMessage;
begin
  FText := S;
  Result := Self;
end;

function TMailMessage.Html(const S: string): TMailMessage;
begin
  FHtml := S;
  Result := Self;
end;

function TMailMessage.Header(const Name_, Value: string): TMailMessage;
var
  I: Integer;
begin
  { Not Values[Name_] := Value: an empty value deletes the entry on 3.3.1
    and stays on 3.2.2. Header('X-Foo', '') has to mean the same on
    both. }
  I := FHeaders.IndexOfName(Name_);
  if I >= 0 then
    FHeaders[I] := Name_ + '=' + Value
  else
    FHeaders.Add(Name_ + '=' + Value);
  Result := Self;
end;

function TMailMessage.Idempotency(const Key: string): TMailMessage;
begin
  FIdempotency := Key;
  Result := Self;
end;

function TMailMessage.EnsureMessageId: string;
begin
  if FMessageId = '' then
    FMessageId := Format('<%d.%d@askr>', [UnixNow, Random(1000000)]);
  Result := FMessageId;
end;

function TMailMessage.Recipients: TStringArray;
var
  I, N: Integer;
begin
  Result := nil;
  N := Length(FTo) + Length(FCc) + Length(FBcc);
  SetLength(Result, N);
  N := 0;
  for I := 0 to High(FTo) do begin Result[N] := FTo[I].Address; Inc(N); end;
  for I := 0 to High(FCc) do begin Result[N] := FCc[I].Address; Inc(N); end;
  for I := 0 to High(FBcc) do begin Result[N] := FBcc[I].Address; Inc(N); end;
end;

{ Encoding as quoted-printable would be more correct, but 8bit with
  UTF-8 is accepted by everything in use, and it keeps the text readable
  in the log. }
function TMailMessage.Render: string;
var
  A: TArena;
  B: TStrBuilder;
  Boundary: string;
  I: Integer;
begin
  if FFrom.Address = '' then
    raise EMailError.Create('The message has no sender');
  if Length(FTo) + Length(FCc) + Length(FBcc) = 0 then
    raise EMailError.Create('The message has no recipients');

  EnsureMessageId;

  A := TArena.Create(16 * 1024);
  try
    B.Init(A, 4096);
    B.Append('From: ' + Fold(FFrom) + #13#10);
    if Length(FTo) > 0 then
      B.Append('To: ' + FoldList(FTo) + #13#10);
    if Length(FCc) > 0 then
      B.Append('Cc: ' + FoldList(FCc) + #13#10);
    B.Append('Subject: ' + FSubject + #13#10);
    B.Append('Date: ');
    AppendHttpDateNow(B);
    B.Append(#13#10);
    B.Append('Message-ID: ' + FMessageId + #13#10);
    B.Append('MIME-Version: 1.0'#13#10);
    for I := 0 to FHeaders.Count - 1 do
      B.Append(FHeaders.Names[I] + ': ' +
        FHeaders.ValueFromIndex[I] + #13#10);

    if (FHtml <> '') and (FText <> '') then
    begin
      Boundary := Format('askr-%d-%d', [UnixNow, Random(1000000)]);
      B.Append('Content-Type: multipart/alternative; boundary="' +
        Boundary + '"'#13#10#13#10);
      B.Append('--' + Boundary + #13#10);
      B.Append('Content-Type: text/plain; charset=utf-8'#13#10);
      B.Append('Content-Transfer-Encoding: 8bit'#13#10#13#10);
      B.Append(FText + #13#10#13#10);
      B.Append('--' + Boundary + #13#10);
      B.Append('Content-Type: text/html; charset=utf-8'#13#10);
      B.Append('Content-Transfer-Encoding: 8bit'#13#10#13#10);
      B.Append(FHtml + #13#10#13#10);
      B.Append('--' + Boundary + '--'#13#10);
    end
    else if FHtml <> '' then
    begin
      B.Append('Content-Type: text/html; charset=utf-8'#13#10);
      B.Append('Content-Transfer-Encoding: 8bit'#13#10#13#10);
      B.Append(FHtml);
    end
    else
    begin
      B.Append('Content-Type: text/plain; charset=utf-8'#13#10);
      B.Append('Content-Transfer-Encoding: 8bit'#13#10#13#10);
      B.Append(FText);
    end;
    Result := B.ToString;
  finally
    A.Free;
  end;
end;

{ TLogTransport }

constructor TLogTransport.Create(const APath: string);
begin
  inherited Create;
  FPath := APath;
end;

procedure TLogTransport.Send(M: TMailMessage);
var
  L: TStringList;
  Text_: string;
begin
  Text_ := '=== ' + FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) +
    ' ===' + LineEnding + M.Render + LineEnding;
  Inc(FCount);
  if FPath = '' then
  begin
    Write(Text_);
    Exit;
  end;
  { The directory is created. A log transport that fails because storage/
    does not exist is useless exactly where it is supposed to help — the
    first time somebody tries a password reset in development. }
  ForceDirectories(ExtractFilePath(ExpandFileName(FPath)));
  L := TStringList.Create;
  try
    if FileExists(FPath) then
      L.LoadFromFile(FPath);
    L.Add(Text_);
    L.SaveToFile(FPath);
  finally
    L.Free;
  end;
end;

function TLogTransport.Describe: string;
begin
  if FPath = '' then
    Result := 'log (stdout)'
  else
    Result := 'log (' + FPath + ')';
end;

{ TNullTransport }

procedure TNullTransport.Send(M: TMailMessage);
begin
  FLast := M.Render;
  Inc(FCount);
end;

function TNullTransport.Describe: string;
begin
  Result := 'null';
end;

{ TSmtpTransport }

constructor TSmtpTransport.Create(const AHost: string; APort: Word;
  ASecurity: TSmtpSecurity);
begin
  inherited Create;
  FHost := AHost;
  FPort := APort;
  FTimeoutMs := 15000;
  FSock := -1;
  FSecurity := ASecurity;
  FVerifyPeer := True;
end;

destructor TSmtpTransport.Destroy;
begin
  FreeAndNil(FTls);
  FreeAndNil(FCtx);
  inherited Destroy;
end;

function TSmtpTransport.Describe: string;
const
  Name_: array[TSmtpSecurity] of string =
    ('uten TLS', 'STARTTLS', 'TLS');
begin
  Result := Format('smtp %s:%d (%s)', [FHost, FPort, Name_[FSecurity]]);
  if (FSecurity <> smtpPlain) and not FVerifyPeer then
    Result := Result + ', uverifisert';
end;

procedure TSmtpTransport.SendLine(const S: string);
var
  Line_: string;
begin
  Line_ := S + #13#10;
  if FTls <> nil then
  begin
    if not FTls.WriteAll(PChar(Line_), Length(Line_)) then
      raise EMailError.Create('SMTP: writing over TLS failed');
  end
  else
    fpSend(FSock, PChar(Line_), Length(Line_), 0);
end;

function TSmtpTransport.ReadLine: string;
var
  C: Char;
  N: ssize_t;
begin
  Result := '';
  repeat
    if FTls <> nil then
      N := FTls.Read(@C, 1)
    else
      N := fpRecv(FSock, @C, 1, 0);
    if N <= 0 then
      raise EMailError.Create('The SMTP connection closed');
    if C = #10 then
      Break;
    if C <> #13 then
      Result := Result + C;
  until False;
end;

function TSmtpTransport.Expect(const Code: string): string;
var
  All_: string;
begin
  { A multi-line reply: "250-something" continues, "250 something"
    ends. }
  All_ := '';
  repeat
    Result := ReadLine;
    if Copy(Result, 1, 3) <> Code then
      raise EMailError.CreateFmt('SMTP expected %s, got: %s', [Code, Result]);
    All_ := All_ + Result + #10;
  until (Length(Result) < 4) or (Result[4] <> '-');
  { The whole reply is kept, not only the last line: it is the preceding
    lines where the server lists what it can do, STARTTLS included. }
  FEhlo := All_;
end;

function TSmtpTransport.Offers(const Capability: string): Boolean;
begin
  { The lines look like "250-STARTTLS". A plain substring search would
    also hit "250-SIZE 35651584" if anything were called SIZE; so we
    require the name to come right after the code and the separator. }
  Result := (Pos(#10'250-' + Capability, #10 + FEhlo) > 0) or
            (Pos(#10'250 ' + Capability, #10 + FEhlo) > 0);
end;

procedure TSmtpTransport.Greet;
begin
  SendLine('EHLO askr');
  Expect('250');
end;

function TSmtpTransport.OffersMechanism(const Mech: string): Boolean;
var
  Lines: TStringList;
  I, P: Integer;
  L: string;
begin
  { The mechanisms are a word list on the AUTH line: "250-AUTH PLAIN
    LOGIN". A raw substring search would say yes to LOGIN because of
    XOAUTH2-LOGIN or similar, so we look for the whole word on that
    particular line. }
  Result := False;
  Lines := TStringList.Create;
  try
    Lines.Text := FEhlo;
    for I := 0 to Lines.Count - 1 do
    begin
      L := UpperCase(Lines[I]);
      if (Copy(L, 1, 8) <> '250-AUTH') and (Copy(L, 1, 8) <> '250 AUTH') then
        Continue;
      { Spaces around it, so the word has to stand alone. }
      P := Pos(' ' + UpperCase(Mech) + ' ', Copy(L, 9, MaxInt) + ' ');
      if P > 0 then
        Exit(True);
    end;
  finally
    Lines.Free;
  end;
end;

procedure TSmtpTransport.Credentials(const AUser, APassword: string);
begin
  FUsername := AUser;
  FPassword := APassword;
end;

procedure TSmtpTransport.Authenticate;
var
  Kryptert: Boolean;
begin
  if FUsername = '' then
    Exit;

  Kryptert := FTls <> nil;
  if (not Kryptert) and (not FAllowPlainAuth) then
    raise EMailError.CreateFmt(
      'Refusing to send the password to %s:%d in the clear. Use STARTTLS, ' +
      'or set AllowPlainAuth if this really is a relay on loopback.',
      [FHost, FPort]);

  { PLAIN is preferred: one round trip instead of three. LOGIN is here
    because some older relays only have that. }
  if OffersMechanism('PLAIN') then
  begin
    SendLine('AUTH PLAIN ' + Base64Encode(
      BytesOf(#0 + FUsername + #0 + FPassword)));
    Expect('235');
  end
  else if OffersMechanism('LOGIN') then
  begin
    SendLine('AUTH LOGIN');
    Expect('334');
    SendLine(Base64Encode(BytesOf(FUsername)));
    Expect('334');
    SendLine(Base64Encode(BytesOf(FPassword)));
    Expect('235');
  end
  else
    raise EMailError.CreateFmt(
      '%s:%d offers no AUTH mechanism Askr can use (PLAIN or LOGIN), ' +
      'but a username was configured.', [FHost, FPort]);
end;

procedure TSmtpTransport.StartTls;
begin
  if FCtx = nil then
  begin
    FCtx := TTlsContext.Create(trClient);
    FCtx.SetVerifyPeer(FVerifyPeer);
  end;
  { The host name goes along as SNI. If FHost is an IP address we skip it
    — SNI with an IP is not allowed, and servers given one answer
    badly. }
  if StrToNetAddr(FHost).s_addr <> 0 then
    FTls := TTlsConn.Create(FCtx, FSock)
  else
    FTls := TTlsConn.Create(FCtx, FSock, FHost);
end;

procedure TSmtpTransport.Connect;
var
  Addr: TInetSockAddr;
  TV: TTimeVal;
  Vert: THostEntry;
begin
  FSock := fpSocket(AF_INET, SOCK_STREAM, 0);
  if FSock < 0 then
    raise EMailError.Create('Could not create a socket');

  TV.tv_sec := FTimeoutMs div 1000;
  TV.tv_usec := (FTimeoutMs mod 1000) * 1000;
  fpSetSockOpt(FSock, SOL_SOCKET, SO_RCVTIMEO, @TV, SizeOf(TV));
  fpSetSockOpt(FSock, SOL_SOCKET, SO_SNDTIMEO, @TV, SizeOf(TV));

  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := HToNS(FPort);
  Addr.sin_addr := StrToNetAddr(FHost);
  if Addr.sin_addr.s_addr = 0 then
  begin
    { Two lookups, in the order the system itself uses: /etc/hosts first,
      then DNS. netdb splits them into two functions that return the
      address in different byte orders — GetHostByName in the host's,
      ResolveHostByName in the network's. Getting that wrong gives an
      address that looks valid and points the wrong way. }
    if GetHostByName(FHost, Vert) then
      Addr.sin_addr.s_addr := HToNL(Vert.Addr.s_addr)
    else if ResolveHostByName(FHost, Vert) then
      Addr.sin_addr := Vert.Addr
    else
      raise EMailError.CreateFmt(
        'Could not resolve the SMTP host %s', [FHost]);
  end;
  if fpConnect(FSock, @Addr, SizeOf(Addr)) <> 0 then
    raise EMailError.CreateFmt('Could not connect to %s:%d', [FHost, FPort]);
end;

procedure TSmtpTransport.Send(M: TMailMessage);
var
  Mottakere: TStringArray;
  I: Integer;
  Body: string;
begin
  Connect;
  try
    if FSecurity = smtpTlsDirect then
      { No plaintext phase at all: the handshake first, then the 220. }
      StartTls;

    Expect('220');
    Greet;

    if FSecurity = smtpStartTls then
    begin
      if not Offers('STARTTLS') then
        raise EMailError.CreateFmt(
          '%s:%d does not offer STARTTLS. Pass smtpPlain to the constructor ' +
          'if plain text is really what you want.', [FHost, FPort]);
      SendLine('STARTTLS');
      Expect('220');
      StartTls;
      { RFC 3207: everything the server said before the handshake is
        unprotected and has to be forgotten. Hence a fresh EHLO. }
      Greet;
    end;

    Authenticate;

    SendLine('MAIL FROM:<' + M.Sender.Address + '>');
    Expect('250');

    Mottakere := M.AllRecipients;
    for I := 0 to High(Mottakere) do
    begin
      SendLine('RCPT TO:<' + Mottakere[I] + '>');
      Expect('250');
    end;

    SendLine('DATA');
    Expect('354');
    Body := M.Render;
    { A line that is only a full stop ends DATA. Such a line in the
      content has to be doubled, or the message is cut off there. }
    Body := StringReplace(Body, #13#10'.'#13#10, #13#10'..'#13#10,
      [rfReplaceAll]);
    SendLine(Body);
    SendLine('.');
    Expect('250');

    SendLine('QUIT');
  finally
    if FTls <> nil then
    begin
      FTls.Shutdown;
      FreeAndNil(FTls);
    end;
    CloseSocket(FSock);
    FSock := -1;
  end;
end;

{ TMailer }

constructor TMailer.Create(ATransport: TMailTransport; AOwns: Boolean);
begin
  inherited Create;
  if ATransport = nil then
    raise EMailError.Create('Mailer without a transport');
  FTransport := ATransport;
  FOwnsTransport := AOwns;
end;

destructor TMailer.Destroy;
begin
  if FOwnsTransport then
    FTransport.Free;
  inherited Destroy;
end;

procedure TMailer.SetDefaultFrom(const AAddress, AName: string);
begin
  FDefaultFrom.Address := AAddress;
  FDefaultFrom.Name_ := AName;
end;

function TMailer.Message_: TMailMessage;
begin
  Result := TMailMessage.Create;
  if FDefaultFrom.Address <> '' then
    Result.From(FDefaultFrom.Address, FDefaultFrom.Name_);
end;

procedure TMailer.Send(M: TMailMessage; FreeAfter: Boolean);
begin
  try
    FTransport.Send(M);
    Inc(FSent);
  finally
    if FreeAfter then
      M.Free;
  end;
end;

{ ---------------------------------------------------- transportregister -- }

type
  TMailFactoryEntry = record
    Name_: string;
    Factory: TMailTransportFactory;
  end;

var
  GFactories: array of TMailFactoryEntry;

procedure RegisterMailTransport(const Name_: string;
  F: TMailTransportFactory);
var
  I: Integer;
  Nkl: string;
begin
  { An ordinary record array with a linear search, not a TStringList with
    Objects: a procedure variable cannot be cast to TObject in Delphi mode
    — the compiler reads it as a call. The same reason as the handler
    table in the queue. }
  Nkl := LowerCase(Name_);
  for I := 0 to High(GFactories) do
    if GFactories[I].Name_ = Nkl then
    begin
      GFactories[I].Factory := F;
      Exit;
    end;
  SetLength(GFactories, Length(GFactories) + 1);
  GFactories[High(GFactories)].Name_ := Nkl;
  GFactories[High(GFactories)].Factory := F;
end;

function KjenteTransporter: string;
var
  I: Integer;
begin
  Result := 'log, null, smtp';
  for I := 0 to High(GFactories) do
    Result := Result + ', ' + GFactories[I].Name_;
end;

function SmtpFromConfig: TMailTransport;
var
  Sikkerhet: TSmtpSecurity;
  Kryptering: string;
  T: TSmtpTransport;
begin
  Kryptering := LowerCase(Cfg('mail.encryption', 'tls'));
  if Kryptering = 'none' then
    Sikkerhet := smtpPlain
  else if Kryptering = 'ssl' then
    Sikkerhet := smtpTlsDirect
  else if (Kryptering = 'tls') or (Kryptering = 'starttls') then
    Sikkerhet := smtpStartTls
  else
    raise EMailError.CreateFmt(
      'Unknown mail.encryption %s. Use tls, ssl or none.', [Kryptering]);

  T := TSmtpTransport.Create(CfgOrFail('mail.host'),
    Word(CfgInt('mail.port', 587)), Sikkerhet);
  T.Credentials(Cfg('mail.username', ''), Cfg('mail.password', ''));
  Result := T;
end;

function MailFromConfig: TMailTransport;
var
  Name_: string;
  I: Integer;
begin
  Name_ := LowerCase(Cfg('mail.transport', 'log'));

  if Name_ = 'log' then
    Exit(TLogTransport.Create(Cfg('mail.log', 'storage/mail.log')));
  if Name_ = 'null' then
    Exit(TNullTransport.Create);
  if Name_ = 'smtp' then
    Exit(SmtpFromConfig);

  for I := 0 to High(GFactories) do
    if GFactories[I].Name_ = Name_ then
      Exit(GFactories[I].Factory());

  { Do not fall back to log. A typo in production would then look like the
    mail going out, and the only thing that knew otherwise was a file
    nobody reads. The same rule as for a gate that does not exist. }
  raise EMailError.CreateFmt(
    'Unknown mail transport %s. Available: %s. A transport from another ' +
    'unit has to be linked in before it can be named here.',
    [Name_, KjenteTransporter]);
end;

initialization
  Randomize;

end.
