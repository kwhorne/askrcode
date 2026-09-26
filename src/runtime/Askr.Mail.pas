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
  SysUtils, Classes, StrUtils, Sockets, BaseUnix,
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

  { A file that goes with a message. The bytes are held, not the path:
    what was attached is what is sent, even if the file changes or goes
    before a queue gets to it. }
  TMailAttachment = record
    FileName: string;
    ContentType: string;
    Data: TBytes;
  end;
  TMailAttachmentArray = array of TMailAttachment;

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
    FAttachments: TMailAttachmentArray;
    function Recipients: TStringArray;
    function RenderWith(AttachmentBodies: Boolean): string;
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

    { A file from disk, read now: a path that is not there is an error here,
      where the message is built, not when a queue gets to it. The name the
      recipient sees is the file's own unless one is given, and the type
      follows the name unless one is given. }
    function Attach(const Path: string; const AName: string = '';
      const AContentType: string = ''): TMailMessage;
    { Bytes made in memory -- an invoice rendered to PDF, a CSV export. }
    function AttachData(const AName: string; const Data: TBytes;
      const AContentType: string = ''): TMailMessage;

    (* The bodies from mail/<Name>.html and mail/<Name>.txt next to
       askr.toml -- at least one of them -- with each {{name}} filled from
       Args, pairs as Trans takes them. A value is escaped in the html and
       written as it is in the text.

       mail/<Name>.<locale>.html is taken first, for the request's locale
       and then its language, so a welcome can be written per language
       while the subject comes from Trans. When mail/layout.html or
       mail/layout.txt is there, the body goes into it at {{content}}.

       A placeholder Args does not fill raises, and so does a template
       that is not there: a mail with {{name}} in it is a mail a customer
       reads. Star form, because a brace in a brace comment opens a nested
       one. *)
    function Template(const Name: string;
      const Args: array of const): TMailMessage;

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
    { The same, with each attachment's bytes left out and a line saying
      what they were. For the log transport: a log with a PDF in base64 in
      it is not something anyone reads. }
    function RenderSummary: string;
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
    property Attachments: TMailAttachmentArray read FAttachments;
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

  { What a TMailFake kept of one message: the addresses joined with ', ',
    and the attachments by name. }
  TSentMail = record
    From, ToList, Cc, Bcc, Subject, Text, Html: string;
    Attachments: TStringArray;
    Idempotency: string;
  end;

  { For a test: keeps every message instead of sending it. FakeMail puts
    one in the mailer; StopFakingMail puts the real transport back. }
  TMailFake = class(TMailTransport)
  private
    FSent: array of TSentMail;
  public
    procedure Send(M: TMailMessage); override;
    function Describe: string; override;
    function Count: Integer;
    { How many were sent to Address, in To, Cc or Bcc. }
    function SentTo(const Address: string): Integer;
    function Sent(Index: Integer): TSentMail;
    function Last: TSentMail;
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

{ For a test: every mail from here on goes to the returned fake -- which
  renders it first, so one a real transport would refuse is refused --
  until StopFakingMail. With no mailer set, it makes one for the fake. }
function FakeMail: TMailFake;
procedure StopFakingMail;

{ The address as it should appear in a header: "Name" <address>, or just
  the address. Exported because transports outside this unit need exactly
  the same quoting — a comma in an unquoted name splits the address field
  in two, and then the wrong person gets the mail. }
function FormatMailAddress(const A: TMailAddress): string;

(* Where Template looks: mail/ next to askr.toml unless set. For a test,
   and for an app that keeps them elsewhere. '' puts it back. *)
procedure SetMailTemplateDir(const Dir: string);

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

uses
  Askr.Core.Lang, Askr.Core.Mime;

var
  GMailer: TMailer = nil;
  GTemplateDir: string = '';

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

{ A header value on one line. CR or LF would end the header and start
  another of the sender's choosing -- a subject from a contact form is
  text a visitor wrote. }
function OneLine(const S: string): string;
begin
  Result := StringReplace(StringReplace(S, #13, ' ', [rfReplaceAll]),
    #10, ' ', [rfReplaceAll]);
end;

function IsPlainAscii(const S: string): Boolean;
var
  I: Integer;
begin
  for I := 1 to Length(S) do
    if (Ord(S[I]) < 32) or (Ord(S[I]) > 126) then
      Exit(False);
  Result := True;
end;

function BytesOfText(const S: string; Start, Len: Integer): TBytes;
begin
  Result := nil;
  SetLength(Result, Len);
  if Len > 0 then
    Move(S[Start], Result[0], Len);
end;

{ RFC 2047. A header is ASCII, so text with anything else in it goes as
  encoded words, =?UTF-8?B?...?=. Each word holds at most 39 bytes -- 64
  characters, so the first still fits a 78-character line after
  "Subject: " -- and never ends in the middle of a UTF-8 sequence: a reader
  decodes each word on its own, and half a character is a question
  mark. }
function EncodeHeaderText(const S: string): string;
var
  I, Start: Integer;
begin
  if IsPlainAscii(S) then
    Exit(S);
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    Start := I;
    I := Start + 39;
    if I > Length(S) + 1 then
      I := Length(S) + 1;
    while (I <= Length(S)) and (I > Start + 1) and ((Ord(S[I]) and $C0) = $80) do
      Dec(I);
    if Result <> '' then
      Result := Result + #13#10' ';
    Result := Result + '=?UTF-8?B?' +
      Base64Encode(BytesOfText(S, Start, I - Start)) + '?=';
  end;
end;

{ An address in a header. A plain name is quoted -- a comma in an unquoted
  one splits the field in two -- and any other is encoded words, which
  cannot be quoted. }
function Fold(const A: TMailAddress): string;
var
  Name_: string;
begin
  Name_ := OneLine(A.Name_);
  if Name_ = '' then
    Result := OneLine(A.Address)
  else if IsPlainAscii(Name_) then
    Result := '"' + StringReplace(Name_, '"', '''', [rfReplaceAll]) +
      '" <' + OneLine(A.Address) + '>'
  else
    Result := EncodeHeaderText(Name_) + ' <' + OneLine(A.Address) + '>';
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

{ An address goes into MAIL FROM and RCPT TO as it is. A line break in
  one would end the command and start one of the sender's choosing --
  another RCPT TO, or a whole second message -- so it is refused where it
  is added, with the angle brackets and spaces no address has. }
procedure CheckAddress(const A: string);
var
  I: Integer;
begin
  for I := 1 to Length(A) do
    if (Ord(A[I]) <= 32) or (A[I] = '<') or (A[I] = '>') then
      raise EMailError.Create('"' + OneLine(A) + '" is not an address: it has ' +
        'a line break, a space or an angle bracket in it');
end;

function TMailMessage.From(const AAddress, AName: string): TMailMessage;
begin
  CheckAddress(AAddress);
  FFrom.Address := AAddress;
  FFrom.Name_ := AName;
  Result := Self;
end;

function TMailMessage.AddTo(const AAddress, AName: string): TMailMessage;
var
  I: Integer;
begin
  CheckAddress(AAddress);
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
  CheckAddress(AAddress);
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
  CheckAddress(AAddress);
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

{ The last part of a path, without what could break the header it goes
  in. The name is shown to the recipient and nothing else: it never
  becomes a path on this side. }
function CleanFileName(const S: string): string;
var
  I: Integer;
  N: string;
begin
  N := S;
  for I := Length(N) downto 1 do
    if (N[I] = '/') or (N[I] = '\') then
    begin
      N := Copy(N, I + 1, MaxInt);
      Break;
    end;
  Result := '';
  for I := 1 to Length(N) do
    if (Ord(N[I]) >= 32) and (N[I] <> '"') then
      Result := Result + N[I];
  Result := Trim(Result);
end;

function TMailMessage.AttachData(const AName: string; const Data: TBytes;
  const AContentType: string): TMailMessage;
var
  I: Integer;
  N: string;
begin
  N := CleanFileName(AName);
  if N = '' then
    raise EMailError.Create('An attachment needs a file name the recipient ' +
      'can see, and "' + AName + '" has none left once the path is taken off');
  I := Length(FAttachments);
  SetLength(FAttachments, I + 1);
  FAttachments[I].FileName := N;
  if AContentType <> '' then
    FAttachments[I].ContentType := OneLine(AContentType)
  else
    FAttachments[I].ContentType := ContentTypeForExt(ExtractFileExt(N));
  FAttachments[I].Data := Copy(Data);
  Result := Self;
end;

function TMailMessage.Attach(const Path, AName, AContentType: string): TMailMessage;
var
  F: TFileStream;
  Data: TBytes;
begin
  if not FileExists(Path) then
    raise EMailError.Create('Cannot attach ' + Path + ': there is no such file');
  Data := nil;
  F := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Data, F.Size);
    if F.Size > 0 then
      F.ReadBuffer(Data[0], F.Size);
  finally
    F.Free;
  end;
  if AName <> '' then
    Result := AttachData(AName, Data, AContentType)
  else
    Result := AttachData(ExtractFileName(Path), Data, AContentType);
end;

procedure SetMailTemplateDir(const Dir: string);
begin
  GTemplateDir := Dir;
end;

function TemplateDir: string;
begin
  if GTemplateDir <> '' then
    Result := GTemplateDir
  else if ConfigFile <> '' then
    Result := ExtractFilePath(ConfigFile) + 'mail'
  else
    Result := 'mail';
  Result := IncludeTrailingPathDelimiter(Result);
end;

{ The file as it is, less one line break at the end: an editor ends a
  file with one, and inside a layout it would be a blank line before the
  footer. }
function ReadWhole(const Path: string): string;
var
  F: TFileStream;
begin
  F := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
  try
    Result := '';
    SetLength(Result, F.Size);
    if F.Size > 0 then
      F.ReadBuffer(Result[1], F.Size);
  finally
    F.Free;
  end;
  if (Result <> '') and (Result[Length(Result)] = #10) then
    SetLength(Result, Length(Result) - 1);
  if (Result <> '') and (Result[Length(Result)] = #13) then
    SetLength(Result, Length(Result) - 1);
end;

(* The file for Name with extension Ext: the locale's own, then its
   language's, then the plain one. '' when there is none. *)
function FindTemplate(const Name, Ext: string): string;
var
  Loc, Lang_: string;
begin
  Loc := StringReplace(CurrentLocale, '_', '-', [rfReplaceAll]);
  if Loc <> '' then
  begin
    Result := TemplateDir + Name + '.' + Loc + Ext;
    if FileExists(Result) then
      Exit;
    if Pos('-', Loc) > 0 then
    begin
      Lang_ := Copy(Loc, 1, Pos('-', Loc) - 1);
      Result := TemplateDir + Name + '.' + Lang_ + Ext;
      if FileExists(Result) then
        Exit;
    end;
  end;
  Result := TemplateDir + Name + Ext;
  if not FileExists(Result) then
    Result := '';
end;

(* Text with each {{name}} filled in, in one pass, so a value that itself
   holds {{something}} is written as it is and never read again.
   {{{name}}} is the value as it is, unescaped, for html built in Pascal --
   rows of an order, say. Content is what {{content}} becomes in a layout,
   as it is. A placeholder nothing fills raises, naming it and the file. *)
function FillTemplate(const Text_, Path: string; const Args: array of const;
  Escape: Boolean; const Content: string; HasContent: Boolean): string;
var
  I, J, K, Open_: Integer;
  Name_, Value, Close_: string;
  Found, Raw: Boolean;
begin
  Result := '';
  I := 1;
  while I <= Length(Text_) do
  begin
    if (I < Length(Text_)) and (Text_[I] = '{') and (Text_[I + 1] = '{') then
    begin
      Raw := (I + 2 <= Length(Text_)) and (Text_[I + 2] = '{');
      if Raw then
      begin
        Open_ := 3;
        Close_ := '}}}';
      end
      else
      begin
        Open_ := 2;
        Close_ := '}}';
      end;
      J := PosEx(Close_, Text_, I + Open_);
      if J > 0 then
      begin
        Name_ := Trim(Copy(Text_, I + Open_, J - I - Open_));
        Found := False;
        Value := '';
        if HasContent and (Name_ = 'content') then
        begin
          Value := Content;
          Found := True;
        end
        else
          for K := 0 to Length(Args) div 2 - 1 do
            if ArgText(Args[K * 2]) = Name_ then
            begin
              Value := ArgText(Args[K * 2 + 1]);
              if Escape and not Raw then
                Value := HtmlEscape(Value);
              Found := True;
              Break;
            end;
        if not Found then
          raise EMailError.Create(Path + ' has ' + Copy(Text_, I, J - I + Length(Close_)) +
            ', and nothing fills it. Pass ' + Name_ + ' to Template, or take it out of the file.');
        Result := Result + Value;
        I := J + Length(Close_);
        Continue;
      end;
    end;
    Result := Result + Text_[I];
    Inc(I);
  end;
end;

(* One body: the template for Ext, in the layout for Ext when there is
   one. '' when the template has no file with that extension. *)
function RenderTemplate(const Name, Ext: string; const Args: array of const;
  Escape: Boolean): string;
var
  Path, Layout: string;
begin
  Result := '';
  Path := FindTemplate(Name, Ext);
  if Path = '' then
    Exit;
  Result := FillTemplate(ReadWhole(Path), Path, Args, Escape, '', False);
  Layout := FindTemplate('layout', Ext);
  if Layout <> '' then
    Result := FillTemplate(ReadWhole(Layout), Layout, Args, Escape, Result, True);
end;

function TMailMessage.Template(const Name: string;
  const Args: array of const): TMailMessage;
var
  I: Integer;
  Html_, Text_: string;
begin
  { A name is a file under mail/, chosen by code; it still never reaches
    above it. }
  if (Name = '') or (Pos('..', Name) > 0) or (Name[1] = '/') then
    raise EMailError.Create('"' + Name + '" is not a template name: a name ' +
      'is a path under mail/, like welcome or auth/verify');
  for I := 1 to Length(Name) do
    if not (Name[I] in ['a'..'z', 'A'..'Z', '0'..'9', '_', '-', '/', '.']) then
      raise EMailError.Create('"' + Name + '" is not a template name: use ' +
        'letters, digits, _, - and /');
  if Odd(Length(Args)) then
    raise EMailError.Create('Template takes its values in pairs, name and value');
  Html_ := RenderTemplate(Name, '.html', Args, True);
  Text_ := RenderTemplate(Name, '.txt', Args, False);
  if (Html_ = '') and (Text_ = '') then
    raise EMailError.Create('There is no mail template ' + Name + ': looked for ' +
      TemplateDir + Name + '.html and ' + TemplateDir + Name + '.txt');
  if Html_ <> '' then
    FHtml := Html_;
  if Text_ <> '' then
    FText := Text_;
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

{ Every line break as CRLF. SMTP says so, and a server that refuses a
  bare LF -- Postfix since the smuggling fixes of 2023 -- refuses the
  whole mail; a text body written in Pascal has #10 in it. }
function CrLf(const S: string): string;
begin
  Result := StringReplace(S, #13#10, #10, [rfReplaceAll]);
  Result := StringReplace(Result, #13, #10, [rfReplaceAll]);
  Result := StringReplace(Result, #10, #13#10, [rfReplaceAll]);
end;

function Base64Lines(const Data: TBytes): string;
var
  S: string;
  I: Integer;
begin
  S := Base64Encode(Data);
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    Result := Result + Copy(S, I, 76) + #13#10;
    Inc(I, 76);
  end;
end;

{ RFC 2231: a parameter value in UTF-8, with every byte that is not a
  plain letter, digit or one of a few marks as %XX. }
function Rfc2231(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    if S[I] in ['A'..'Z', 'a'..'z', '0'..'9', '!', '#', '$', '&', '+', '-',
        '.', '^', '_', '`', '|', '~'] then
      Result := Result + S[I]
    else
      Result := Result + '%' + IntToHex(Ord(S[I]), 2);
end;

{ Name*=UTF-8''value, or split into Name*0*=, Name*1*= ... when it would
  not fit a line: RFC 2231's continuations, which a reader joins before
  it decodes. A piece never ends inside a %XX. }
function Rfc2231Param(const Name_, Value: string): string;
var
  Enc, Piece: string;
  I, N, Cut: Integer;
begin
  Enc := Rfc2231(Value);
  if Length(Name_) + Length(Enc) + 10 <= 76 then
    Exit(Name_ + '*=UTF-8''''' + Enc);
  Result := '';
  N := 0;
  I := 1;
  while I <= Length(Enc) do
  begin
    Cut := I + 56;
    if Cut > Length(Enc) + 1 then
      Cut := Length(Enc) + 1;
    { Back off a %XX cut in two. }
    if (Cut <= Length(Enc)) and (Cut - 1 >= I) and (Enc[Cut - 1] = '%') then
      Dec(Cut)
    else if (Cut <= Length(Enc)) and (Cut - 2 >= I) and (Enc[Cut - 2] = '%') then
      Dec(Cut, 2);
    Piece := Copy(Enc, I, Cut - I);
    if N > 0 then
      Result := Result + ';'#13#10' ';
    if N = 0 then
      Result := Result + Name_ + '*0*=UTF-8''''' + Piece
    else
      Result := Result + Name_ + '*' + IntToStr(N) + '*=' + Piece;
    Inc(N);
    I := Cut;
  end;
end;

{ Encoding as quoted-printable would be more correct, but 8bit with
  UTF-8 is accepted by everything in use, and it keeps the text readable
  in the log. An attachment is base64, because a file is bytes. }
function TMailMessage.RenderWith(AttachmentBodies: Boolean): string;
var
  A: TArena;
  B: TStrBuilder;
  Boundary, Mixed: string;
  I: Integer;

  { The text and html parts, as one part of their own. }
  procedure AppendBody;
  begin
    if (FHtml <> '') and (FText <> '') then
    begin
      Boundary := Format('askr-%d-%d', [UnixNow, Random(1000000)]);
      B.Append('Content-Type: multipart/alternative; boundary="' +
        Boundary + '"'#13#10#13#10);
      B.Append('--' + Boundary + #13#10);
      B.Append('Content-Type: text/plain; charset=utf-8'#13#10);
      B.Append('Content-Transfer-Encoding: 8bit'#13#10#13#10);
      B.Append(CrLf(FText) + #13#10#13#10);
      B.Append('--' + Boundary + #13#10);
      B.Append('Content-Type: text/html; charset=utf-8'#13#10);
      B.Append('Content-Transfer-Encoding: 8bit'#13#10#13#10);
      B.Append(CrLf(FHtml) + #13#10#13#10);
      B.Append('--' + Boundary + '--'#13#10);
    end
    else if FHtml <> '' then
    begin
      B.Append('Content-Type: text/html; charset=utf-8'#13#10);
      B.Append('Content-Transfer-Encoding: 8bit'#13#10#13#10);
      B.Append(CrLf(FHtml));
    end
    else
    begin
      B.Append('Content-Type: text/plain; charset=utf-8'#13#10);
      B.Append('Content-Transfer-Encoding: 8bit'#13#10#13#10);
      B.Append(CrLf(FText));
    end;
  end;

  { A plain name as it is. Any other goes as RFC 2231 in the disposition,
    which is the one modern readers use, and as encoded words in the
    type's name, which is what older Outlook reads. Not both forms in the
    disposition: readers disagree on which of two wins, and Python's own
    parser takes the plain fallback -- underscores where the letters
    were. Each parameter on a line of its own, so no line passes 78. }
  procedure AppendAttachment(const Att: TMailAttachment);
  begin
    B.Append('--' + Mixed + #13#10);
    if IsPlainAscii(Att.FileName) then
    begin
      B.Append('Content-Type: ' + Att.ContentType + ';'#13#10' name="' +
        Att.FileName + '"'#13#10);
      B.Append('Content-Disposition: attachment;'#13#10' filename="' +
        Att.FileName + '"'#13#10);
    end
    else
    begin
      B.Append('Content-Type: ' + Att.ContentType + ';'#13#10' name="' +
        EncodeHeaderText(Att.FileName) + '"'#13#10);
      B.Append('Content-Disposition: attachment;'#13#10' ' +
        Rfc2231Param('filename', Att.FileName) + #13#10);
    end;
    B.Append('Content-Transfer-Encoding: base64'#13#10#13#10);
    if AttachmentBodies then
      B.Append(Base64Lines(Att.Data))
    else
      B.Append(Format('[%d bytes of %s, left out of the log]'#13#10,
        [Length(Att.Data), Att.ContentType]));
  end;

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
    B.Append('Subject: ' + EncodeHeaderText(OneLine(FSubject)) + #13#10);
    B.Append('Date: ');
    AppendHttpDateNow(B);
    B.Append(#13#10);
    B.Append('Message-ID: ' + FMessageId + #13#10);
    B.Append('MIME-Version: 1.0'#13#10);
    for I := 0 to FHeaders.Count - 1 do
      B.Append(OneLine(FHeaders.Names[I]) + ': ' +
        OneLine(FHeaders.ValueFromIndex[I]) + #13#10);

    if Length(FAttachments) = 0 then
      AppendBody
    else
    begin
      Mixed := Format('askr-mixed-%d-%d', [UnixNow, Random(1000000)]);
      B.Append('Content-Type: multipart/mixed; boundary="' + Mixed +
        '"'#13#10#13#10);
      B.Append('--' + Mixed + #13#10);
      AppendBody;
      B.Append(#13#10);
      for I := 0 to High(FAttachments) do
        AppendAttachment(FAttachments[I]);
      B.Append('--' + Mixed + '--'#13#10);
    end;
    Result := B.ToString;
  finally
    A.Free;
  end;
end;

function TMailMessage.Render: string;
begin
  Result := RenderWith(True);
end;

function TMailMessage.RenderSummary: string;
begin
  Result := RenderWith(False);
end;

{ TMailFake }

function JoinAddresses(const L: TMailAddressArray): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(L) do
  begin
    if I > 0 then
      Result := Result + ', ';
    Result := Result + L[I].Address;
  end;
end;

procedure TMailFake.Send(M: TMailMessage);
var
  I: Integer;
  S: TSentMail;
begin
  { Rendered first, and thrown away: a message a real transport would
    refuse -- no sender, no recipient -- is refused here too. A fake that
    took it would be a test that passes on mail that never goes. }
  M.Render;
  S.From := M.Sender.Address;
  S.ToList := JoinAddresses(M.ToList);
  S.Cc := JoinAddresses(M.CcList);
  S.Bcc := JoinAddresses(M.BccList);
  S.Subject := M.SubjectLine;
  S.Text := M.TextBody;
  S.Html := M.HtmlBody;
  S.Idempotency := M.IdempotencyKey;
  S.Attachments := nil;
  SetLength(S.Attachments, Length(M.Attachments));
  for I := 0 to High(M.Attachments) do
    S.Attachments[I] := M.Attachments[I].FileName;
  I := Length(FSent);
  SetLength(FSent, I + 1);
  FSent[I] := S;
end;

function TMailFake.Describe: string;
begin
  Result := 'fake (' + IntToStr(Length(FSent)) + ' sent)';
end;

function TMailFake.Count: Integer;
begin
  Result := Length(FSent);
end;

function TMailFake.SentTo(const Address: string): Integer;
var
  I: Integer;
  All: string;
begin
  Result := 0;
  for I := 0 to High(FSent) do
  begin
    All := ', ' + LowerCase(FSent[I].ToList + ', ' + FSent[I].Cc + ', ' + FSent[I].Bcc) + ',';
    if Pos(', ' + LowerCase(Address) + ',', All) > 0 then
      Inc(Result);
  end;
end;

function TMailFake.Sent(Index: Integer): TSentMail;
begin
  if (Index < 0) or (Index > High(FSent)) then
    raise EMailError.CreateFmt('No mail number %d was sent; %d were', [Index, Length(FSent)]);
  Result := FSent[Index];
end;

function TMailFake.Last: TSentMail;
begin
  Result := Sent(High(FSent));
end;

var
  GFake: TMailFake = nil;
  GFakeMadeMailer: Boolean = False;
  GRealTransport: TMailTransport = nil;
  GRealOwns: Boolean = False;

function FakeMail: TMailFake;
begin
  if GFake <> nil then
    StopFakingMail;
  GFake := TMailFake.Create;
  if GMailer = nil then
  begin
    GMailer := TMailer.Create(GFake, False);
    GFakeMadeMailer := True;
  end
  else
  begin
    GRealTransport := GMailer.FTransport;
    GRealOwns := GMailer.FOwnsTransport;
    GMailer.FTransport := GFake;
    GMailer.FOwnsTransport := False;
    GFakeMadeMailer := False;
  end;
  Result := GFake;
end;

procedure StopFakingMail;
begin
  if GFake = nil then
    Exit;
  if GFakeMadeMailer then
  begin
    GMailer.Free;
    GMailer := nil;
  end
  else
  begin
    GMailer.FTransport := GRealTransport;
    GMailer.FOwnsTransport := GRealOwns;
  end;
  FreeAndNil(GFake);
  GRealTransport := nil;
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
    ' ===' + LineEnding + M.RenderSummary + LineEnding;
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
  Encrypted: Boolean;
begin
  if FUsername = '' then
    Exit;

  Encrypted := FTls <> nil;
  if (not Encrypted) and (not FAllowPlainAuth) then
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
  Host: THostEntry;
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
    if GetHostByName(FHost, Host) then
      Addr.sin_addr.s_addr := HToNL(Host.Addr.s_addr)
    else if ResolveHostByName(FHost, Host) then
      Addr.sin_addr := Host.Addr
    else
      raise EMailError.CreateFmt(
        'Could not resolve the SMTP host %s', [FHost]);
  end;
  if fpConnect(FSock, @Addr, SizeOf(Addr)) <> 0 then
    raise EMailError.CreateFmt('Could not connect to %s:%d', [FHost, FPort]);
end;

procedure TSmtpTransport.Send(M: TMailMessage);
var
  Recipients: TStringArray;
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

    Recipients := M.AllRecipients;
    for I := 0 to High(Recipients) do
    begin
      SendLine('RCPT TO:<' + Recipients[I] + '>');
      Expect('250');
    end;

    SendLine('DATA');
    Expect('354');
    Body := M.Render;
    { RFC 5321: every line that starts with a full stop gets a second one,
      which the server takes off again. Not only a line that is only a
      full stop -- that one ends DATA and cuts the mail short -- but any:
      a line starting .hidden would otherwise arrive as hidden. Render
      has made every line break CRLF, so this finds them all. }
    Body := StringReplace(Body, #13#10'.', #13#10'..', [rfReplaceAll]);
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
  NClasses: string;
begin
  { An ordinary record array with a linear search, not a TStringList with
    Objects: a procedure variable cannot be cast to TObject in Delphi mode
    — the compiler reads it as a call. The same reason as the handler
    table in the queue. }
  NClasses := LowerCase(Name_);
  for I := 0 to High(GFactories) do
    if GFactories[I].Name_ = NClasses then
    begin
      GFactories[I].Factory := F;
      Exit;
    end;
  SetLength(GFactories, Length(GFactories) + 1);
  GFactories[High(GFactories)].Name_ := NClasses;
  GFactories[High(GFactories)].Factory := F;
end;

function KnownTransports: string;
var
  I: Integer;
begin
  Result := 'log, null, smtp';
  for I := 0 to High(GFactories) do
    Result := Result + ', ' + GFactories[I].Name_;
end;

function SmtpFromConfig: TMailTransport;
var
  Security: TSmtpSecurity;
  Encryption: string;
  T: TSmtpTransport;
begin
  Encryption := LowerCase(Cfg('mail.encryption', 'tls'));
  if Encryption = 'none' then
    Security := smtpPlain
  else if Encryption = 'ssl' then
    Security := smtpTlsDirect
  else if (Encryption = 'tls') or (Encryption = 'starttls') then
    Security := smtpStartTls
  else
    raise EMailError.CreateFmt(
      'Unknown mail.encryption %s. Use tls, ssl or none.', [Encryption]);

  T := TSmtpTransport.Create(CfgOrFail('mail.host'),
    Word(CfgInt('mail.port', 587)), Security);
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
    [Name_, KnownTransports]);
end;

initialization
  Randomize;

end.
