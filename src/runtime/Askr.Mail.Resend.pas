{ Askr.Mail.Resend — mail over Resend's HTTP API.

  A transport that does what the SMTP transport does, but over HTTPS to
  api.resend.com instead of over port 587. The message is built the same
  way: it is the same TMailMessage, and the app sees no difference.

  Why a unit of its own rather than part of Askr.Mail: this one needs the
  HTTP client, and the HTTP client needs OpenSSL. An app that sends over
  SMTP or writes to a file should link none of that. The same rule as for
  Askr.Image.Vips.

  Why HTTP rather than simply SMTP to smtp.resend.com: the provider
  answers with an id immediately, the errors are machine readable rather
  than a three-digit code with free text, and there is an idempotency key.
  The last is the one that matters in a queue: a job that fails after
  Resend accepted the message is retried, and without a key the recipient
  gets two emails.

  The key comes from RESEND_API_KEY through the configuration layer, and
  is never logged. }
unit Askr.Mail.Resend;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, StrUtils,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Json, Askr.Core.Config,
  Askr.Core.Log, Askr.Core.Crypto, Askr.Http.Client, Askr.Mail;

const
  DefaultResendBaseUrl = 'https://api.resend.com';
  DefaultResendTimeoutMs = 15000;

type
  { The error as Resend writes it, unadorned.

    Name_ is the provider's own type — 'validation_error',
    'rate_limit_exceeded', 'missing_api_key'. Retryable is our reading of
    it, and it is here because it is what the call site actually needs to
    know: should the job be retried, or should it go to the failed
    table. }
  EResendError = class(EMailError)
  private
    FStatus: Integer;
    FName: string;
    FRetryable: Boolean;
  public
    constructor Create(AStatus: Integer; const AName, AMessage: string;
      ARetryable: Boolean);
    property Status: Integer read FStatus;
    property Name_: string read FName;
    property Retryable: Boolean read FRetryable;
  end;

  { The HTTP layer underneath the transport.

    It sits behind an abstract class for the same reason as in Askr.Ai:
    without it the shape of the request cannot be checked without sending
    a real email, and it is precisely the shape that is easy to get
    wrong. }
  TResendHttp = class
  public
    function Post(const Url, ApiKey, IdempotencyKey, Body: string;
      out Status: Integer): string; virtual; abstract;
  end;

  TRealResendHttp = class(TResendHttp)
  private
    FTimeoutMs: Integer;
  public
    constructor Create(ATimeoutMs: Integer = DefaultResendTimeoutMs);
    function Post(const Url, ApiKey, IdempotencyKey, Body: string;
      out Status: Integer): string; override;
  end;

  { Answers with whatever has been queued, and keeps what it was asked to
    send. The tests read Sent to check the JSON. }
  TFakeResendHttp = class(TResendHttp)
  private
    FReplies: TStringList;
    FStatuses: array of Integer;
    FNext: Integer;
    FRequests: TStringList;
    FLastKey: string;
    FLastIdem: string;
    FLastUrl: string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Queue(const Body: string; Status: Integer = 200);
    function Post(const Url, ApiKey, IdempotencyKey, Body: string;
      out Status: Integer): string; override;
    property Sent: TStringList read FRequests;
    property LastApiKey: string read FLastKey;
    property LastIdempotency: string read FLastIdem;
    property LastUrl: string read FLastUrl;
  end;

  TResendTransport = class(TMailTransport)
  private
    FApiKey: string;
    FBaseUrl: string;
    FHttp: TResendHttp;
    FOwnsHttp: Boolean;
    FLastId: string;
    FCount: QWord;
    function BuildJson(M: TMailMessage): string;
    procedure Err(Status: Integer; const Body: string);
  public
    { An empty key means RESEND_API_KEY from the environment or .env. If it
      is missing there too, it raises at setup — not at the first
      email. }
    constructor Create(const AApiKey: string = '');
    destructor Destroy; override;
    procedure Send(M: TMailMessage); override;
    function Describe: string; override;

    { Byttes ut i tester. Standarden er TRealResendHttp. }
    procedure UseHttp(H: TResendHttp; Owns: Boolean = True);

    { The id Resend gave the last message. That is what you look up in the
      provider's own log when somebody asks whether the email went
      out. }
    property LastId: string read FLastId;
    property BaseUrl: string read FBaseUrl write FBaseUrl;
    property Count: QWord read FCount;
  end;

implementation

constructor EResendError.Create(AStatus: Integer;
  const AName, AMessage: string; ARetryable: Boolean);
begin
  inherited Create(AMessage);
  FStatus := AStatus;
  FName := AName;
  FRetryable := ARetryable;
end;

{ ------------------------------------------------------------ HTTP-laget -- }

constructor TRealResendHttp.Create(ATimeoutMs: Integer);
begin
  inherited Create;
  FTimeoutMs := ATimeoutMs;
end;

function TRealResendHttp.Post(const Url, ApiKey, IdempotencyKey,
  Body: string; out Status: Integer): string;
var
  C: THttpClient;
  R: THttpResponse;
begin
  C := THttpClient.Create;
  try
    C.ConnectTimeoutMs := FTimeoutMs;
    C.ReadTimeoutMs := FTimeoutMs;
    C.WithBearer(ApiKey);
    if IdempotencyKey <> '' then
      C.WithHeader('Idempotency-Key', IdempotencyKey);
    R := C.Post(Url, Body, 'application/json');
    Status := R.Status;
    Result := R.Body;
  finally
    C.Free;
  end;
end;

constructor TFakeResendHttp.Create;
begin
  inherited Create;
  FReplies := TStringList.Create;
  FRequests := TStringList.Create;
end;

destructor TFakeResendHttp.Destroy;
begin
  FReplies.Free;
  FRequests.Free;
  inherited Destroy;
end;

procedure TFakeResendHttp.Queue(const Body: string; Status: Integer);
begin
  FReplies.Add(Body);
  SetLength(FStatuses, Length(FStatuses) + 1);
  FStatuses[High(FStatuses)] := Status;
end;

function TFakeResendHttp.Post(const Url, ApiKey, IdempotencyKey,
  Body: string; out Status: Integer): string;
begin
  FRequests.Add(Body);
  FLastKey := ApiKey;
  FLastIdem := IdempotencyKey;
  FLastUrl := Url;
  if FNext >= FReplies.Count then
    raise EResendError.Create(0, 'fake',
      'The fake Resend transport has no more queued responses.', False);
  Status := FStatuses[FNext];
  Result := FReplies[FNext];
  Inc(FNext);
end;

{ ------------------------------------------------------------ transporten -- }

constructor TResendTransport.Create(const AApiKey: string);
begin
  inherited Create;
  FApiKey := AApiKey;
  if FApiKey = '' then
    FApiKey := Cfg('resend.api.key', '');
  if FApiKey = '' then
    raise EResendError.Create(0, 'config',
      'No Resend API key. Set RESEND_API_KEY in the environment or in ' +
      '.env, or pass the key to TResendTransport.Create.', False);
  FBaseUrl := Cfg('resend.base.url', DefaultResendBaseUrl);
  FHttp := TRealResendHttp.Create(
    Integer(CfgInt('resend.timeout.ms', DefaultResendTimeoutMs)));
  FOwnsHttp := True;
end;

destructor TResendTransport.Destroy;
begin
  if FOwnsHttp then
    FHttp.Free;
  inherited Destroy;
end;

procedure TResendTransport.UseHttp(H: TResendHttp; Owns: Boolean);
begin
  if FOwnsHttp then
    FHttp.Free;
  FHttp := H;
  FOwnsHttp := Owns;
end;

function TResendTransport.Describe: string;
begin
  { Never the key. The output has to be safe to paste into a bug report,
    just like askr config. }
  Result := 'resend (' + FBaseUrl + ')';
end;

procedure WriteAddresses(var W: TJsonWriter; const AName: string;
  const L: TMailAddressArray);
var
  I: Integer;
begin
  if Length(L) = 0 then
    Exit;
  W.Key(AName);
  W.BeginArray;
  for I := 0 to High(L) do
    W.Str(FormatMailAddress(L[I]));
  W.EndArray;
end;

function TResendTransport.BuildJson(M: TMailMessage): string;
var
  A: TArena;
  W: TJsonWriter;
  I, K: Integer;
  Name_, Value_, Reply: string;
  HasHeaders: Boolean;
begin
  if M.Sender.Address = '' then
    raise EMailError.Create('The message has no sender');
  if Length(M.ToList) + Length(M.CcList) + Length(M.BccList) = 0 then
    raise EMailError.Create('The message has no recipients');
  if (M.TextBody = '') and (M.HtmlBody = '') then
    { SMTP would send an empty text/plain. Resend refuses it with a 422 and
      a message saying html or text has to be set, and that error is
      easier to understand here than over the network. }
    raise EMailError.Create(
      'The message has neither a text nor an html body');

  A := TArena.Create(16 * 1024);
  try
    W.Init(A, 4096);
    W.BeginObject;
    W.Field('from', FormatMailAddress(M.Sender));
    WriteAddresses(W, 'to', M.ToList);
    WriteAddresses(W, 'cc', M.CcList);
    WriteAddresses(W, 'bcc', M.BccList);
    W.Field('subject', M.SubjectLine);
    if M.HtmlBody <> '' then
      W.Field('html', M.HtmlBody);
    if M.TextBody <> '' then
      W.Field('text', M.TextBody);

    { Reply-To is set in Askr with Header('Reply-To', ...), because it is a
      header. Resend has a field of its own for it and refuses it as a
      header, so it is moved over — and taken out of the headers object
      below. }
    Reply := '';
    for I := 0 to M.ExtraHeaders.Count - 1 do
      if SameText(M.ExtraHeaders.Names[I], 'Reply-To') then
        Reply := M.ExtraHeaders.ValueFromIndex[I];
    if Reply <> '' then
    begin
      { Resend takes reply_to as a string or a list. We always send the
        list: several Reply-To addresses are legal in RFC 5322, and one
        address in a single-element list means the same as the address
        alone. }
      W.Key('reply_to');
      W.BeginArray;
      for K := 1 to WordCount(Reply, [',']) do
        if Trim(ExtractWord(K, Reply, [','])) <> '' then
          W.Str(Trim(ExtractWord(K, Reply, [','])));
      W.EndArray;
    end;

    HasHeaders := False;
    for I := 0 to M.ExtraHeaders.Count - 1 do
    begin
      Name_ := M.ExtraHeaders.Names[I];
      if SameText(Name_, 'Reply-To') then
        Continue;
      Value_ := M.ExtraHeaders.ValueFromIndex[I];
      if not HasHeaders then
      begin
        W.Key('headers');
        W.BeginObject;
        HasHeaders := True;
      end;
      W.Field(Name_, Value_);
    end;
    if HasHeaders then
      W.EndObject;

    { Base64, which is what Resend takes a file's bytes as. The type goes
      with it, rather than leaving Resend to guess from the name. }
    if Length(M.Attachments) > 0 then
    begin
      W.Key('attachments');
      W.BeginArray;
      for I := 0 to High(M.Attachments) do
      begin
        W.BeginObject;
        W.Field('filename', M.Attachments[I].FileName);
        W.Field('content', Base64Encode(M.Attachments[I].Data));
        W.Field('content_type', M.Attachments[I].ContentType);
        W.EndObject;
      end;
      W.EndArray;
    end;

    W.EndObject;
    Result := W.ToString;
  finally
    A.Free;
  end;
end;

function CanRetry(Status: Integer; const Name_: string): Boolean;
begin
  { 5xx and a real rate limit pass by themselves. A quota does not — not
    within any backoff a queue has — so it goes to the failed table where
    a person sees it, rather than round the loop until the attempts are
    used up. A validation error never becomes more correct by being sent
    again. }
  if Status >= 500 then
    Exit(True);
  if Status = 408 then
    Exit(True);
  if Name_ = 'rate_limit_exceeded' then
    Exit(True);
  if Name_ = 'concurrent_idempotent_requests' then
    Exit(True);
  Result := False;
end;

procedure TResendTransport.Err(Status: Integer; const Body: string);
var
  A: TArena;
  Root: PJsonValue;
  ErrPos: SizeInt;
  Name_, Msg, Suffix: string;
begin
  Name_ := '';
  Msg := '';
  A := TArena.Create(16 * 1024);
  try
    if JsonParse(A, Str(Body), Root, ErrPos) then
    begin
      { The field has had several names: name in the older form, error_type
        in the newer. Both are read, and type for good measure — an error
        we cannot name should still come through with its status and
        text. }
      Name_ := JsonAsString(JsonMember(Root, 'name'));
      if Name_ = '' then
        Name_ := JsonAsString(JsonMember(Root, 'error_type'));
      if Name_ = '' then
        Name_ := JsonAsString(JsonMember(Root, 'type'));
      Msg := JsonAsString(JsonMember(Root, 'message'));
      if Msg = '' then
        Msg := JsonAsString(JsonMember(Root, 'error'));
    end;
  finally
    A.Free;
  end;

  if Msg = '' then
    Msg := Trim(Copy(Body, 1, 300));
  if Msg = '' then
    Msg := 'no response body';

  if Name_ <> '' then
    Suffix := ' (' + Name_ + ')'
  else
    Suffix := '';

  raise EResendError.Create(Status, Name_,
    Format('Resend API error %d%s: %s', [Status, Suffix, Msg]),
    CanRetry(Status, Name_));
end;

procedure TResendTransport.Send(M: TMailMessage);
var
  Body, Reply, Idem: string;
  Status: Integer;
  A: TArena;
  Root: PJsonValue;
  ErrPos: SizeInt;
begin
  Body := BuildJson(M);

  { The caller's own key when there is one. Otherwise the Message-ID,
    which is stable as long as it is the same object — but not across a
    queue that rebuilds the message. That is why Idempotency exists to be
    set. }
  Idem := M.IdempotencyKey;
  if Idem = '' then
    Idem := M.EnsureMessageId;

  try
    Reply := FHttp.Post(FBaseUrl + '/emails', FApiKey, Idem, Body, Status);
  except
    on E: EResendError do
      raise;
    on E: EHttpClientError do
      { The network, not the provider. Always worth another attempt: we do
        not know whether the message arrived, and the idempotency key
        makes it safe to ask again. }
      raise EResendError.Create(0, 'network',
        'Could not reach the Resend API: ' + E.Message, True);
  end;

  if (Status < 200) or (Status > 299) then
    Err(Status, Reply);

  FLastId := '';
  A := TArena.Create(8 * 1024);
  try
    if JsonParse(A, Str(Reply), Root, ErrPos) then
      FLastId := JsonAsString(JsonMember(Root, 'id'));
  finally
    A.Free;
  end;

  Inc(FCount);
  { The id and the number of recipients, not the addresses and never the
    key. That is enough to find the message again at the provider, and an
    email address is personal data that does not belong in an operations
    log. }
  LogInfo('mail sent', ['provider', 'resend', 'id', FLastId,
    'recipients', Length(M.AllRecipients)]);
end;

{ --------------------------------------------------------- registrering -- }

function MakeResend: TMailTransport;
begin
  Result := TResendTransport.Create;
end;

initialization
  { Makes mail.transport = resend possible. The unit has to be linked in
    for the name to exist — MailFromConfig says so when it is not, rather
    than falling back to the log file. }
  RegisterMailTransport('resend', @MakeResend);

end.
