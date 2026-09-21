{ Askr.Mail.Resend — e-post over Resends HTTP-API.

  En transport som gjør det SMTP-transporten gjør, men over HTTPS mot
  api.resend.com i stedet for over port 587. Meldingen bygges likt: det er
  den samme TMailMessage, og appen ser ingen forskjell.

  Hvorfor en egen unit, og ikke i Askr.Mail: denne trenger HTTP-klienten,
  og HTTP-klienten trenger OpenSSL. En app som sender over SMTP eller
  skriver til en fil skal ikke linke inn noe av det. Samme regel som for
  Askr.Image.Vips.

  Hvorfor HTTP og ikke bare SMTP mot smtp.resend.com: providern svarer med
  en id med én gang, feilene er maskinlesbare i stedet for en tresifret
  kode med fritekst, og det finnes en idempotensnøkkel. Det siste er det
  som betyr noe i en kø: en jobb som feiler etter at Resend tok imot
  meldingen prøves på nytt, og uten en nøkkel får mottakeren to eposter.

  Nøkkelen kommer fra RESEND_API_KEY gjennom konfigurasjonslaget, og
  logges aldri. }
unit Askr.Mail.Resend;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, StrUtils,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Json, Askr.Core.Config,
  Askr.Core.Log, Askr.Http.Client, Askr.Mail;

const
  DefaultResendBaseUrl = 'https://api.resend.com';
  DefaultResendTimeoutMs = 15000;

type
  { Feilen slik Resend skriver den, uten pynt.

    Name_ er providerens egen type — 'validation_error',
    'rate_limit_exceeded', 'missing_api_key'. Retryable er vår tolkning av
    den, og den er med fordi det er det kallstedet faktisk trenger å vite:
    skal jobben prøves igjen, eller skal den til feiltabellen. }
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

  { HTTP-laget under transporten.

    Det ligger bak en abstrakt klasse av samme grunn som i Askr.Ai: uten
    den kan ikke forespørselsformen prøves uten å sende en ekte epost, og
    det er nettopp formen som er lett å ta feil av. }
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

  { Svarer med det den har fått i kø, og tar vare på det den ble bedt om
    å sende. Testene leser Sent for å sjekke JSON-en. }
  TFakeResendHttp = class(TResendHttp)
  private
    FSvar: TStringList;
    FStatuser: array of Integer;
    FNeste: Integer;
    FSendt: TStringList;
    FLastKey: string;
    FLastIdem: string;
    FLastUrl: string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Queue(const Body: string; Status: Integer = 200);
    function Post(const Url, ApiKey, IdempotencyKey, Body: string;
      out Status: Integer): string; override;
    property Sent: TStringList read FSendt;
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
    procedure Feil(Status: Integer; const Body: string);
  public
    { Tom nøkkel betyr RESEND_API_KEY fra miljøet eller .env. Mangler den
      også der, kastes det ved oppsett — ikke ved første epost. }
    constructor Create(const AApiKey: string = '');
    destructor Destroy; override;
    procedure Send(M: TMailMessage); override;
    function Describe: string; override;

    { Byttes ut i tester. Standarden er TRealResendHttp. }
    procedure UseHttp(H: TResendHttp; Owns: Boolean = True);

    { Id-en Resend ga den siste meldingen. Den er det man slår opp på i
      providerens egen logg når noen spør om eposten gikk ut. }
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
  FSvar := TStringList.Create;
  FSendt := TStringList.Create;
end;

destructor TFakeResendHttp.Destroy;
begin
  FSvar.Free;
  FSendt.Free;
  inherited Destroy;
end;

procedure TFakeResendHttp.Queue(const Body: string; Status: Integer);
begin
  FSvar.Add(Body);
  SetLength(FStatuser, Length(FStatuser) + 1);
  FStatuser[High(FStatuser)] := Status;
end;

function TFakeResendHttp.Post(const Url, ApiKey, IdempotencyKey,
  Body: string; out Status: Integer): string;
begin
  FSendt.Add(Body);
  FLastKey := ApiKey;
  FLastIdem := IdempotencyKey;
  FLastUrl := Url;
  if FNeste >= FSvar.Count then
    raise EResendError.Create(0, 'fake',
      'The fake Resend transport has no more queued responses.', False);
  Status := FStatuser[FNeste];
  Result := FSvar[FNeste];
  Inc(FNeste);
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
  { Aldri nøkkelen. Utskriften skal være trygg å lime inn i en
    feilrapport, akkurat som askr config. }
  Result := 'resend (' + FBaseUrl + ')';
end;

procedure SkrivAdresser(var W: TJsonWriter; const AName: string;
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
  Navn, Verdi, Svar: string;
  HarHoder: Boolean;
begin
  if M.Sender.Address = '' then
    raise EMailError.Create('The message has no sender');
  if Length(M.ToList) + Length(M.CcList) + Length(M.BccList) = 0 then
    raise EMailError.Create('The message has no recipients');
  if (M.TextBody = '') and (M.HtmlBody = '') then
    { SMTP ville sendt en tom text/plain. Resend avviser den med 422 og en
      melding om at html eller text må være satt, og den feilen er lettere
      å forstå her enn over nettet. }
    raise EMailError.Create(
      'The message has neither a text nor an html body');

  A := TArena.Create(16 * 1024);
  try
    W.Init(A, 4096);
    W.BeginObject;
    W.Field('from', FormatMailAddress(M.Sender));
    SkrivAdresser(W, 'to', M.ToList);
    SkrivAdresser(W, 'cc', M.CcList);
    SkrivAdresser(W, 'bcc', M.BccList);
    W.Field('subject', M.SubjectLine);
    if M.HtmlBody <> '' then
      W.Field('html', M.HtmlBody);
    if M.TextBody <> '' then
      W.Field('text', M.TextBody);

    { Reply-To settes i Askr med Header('Reply-To', …), fordi det er et
      hode. Resend har et eget felt for det og avviser det som hode, så
      det flyttes over — og tas ut av headers-objektet nedenfor. }
    Svar := '';
    for I := 0 to M.ExtraHeaders.Count - 1 do
      if SameText(M.ExtraHeaders.Names[I], 'Reply-To') then
        Svar := M.ExtraHeaders.ValueFromIndex[I];
    if Svar <> '' then
    begin
      { Resend tar reply_to som streng eller liste. Vi sender alltid
        lista: flere Reply-To er lov i RFC 5322, og én adresse i en
        ettelementsliste betyr det samme som adressen alene. }
      W.Key('reply_to');
      W.BeginArray;
      for K := 1 to WordCount(Svar, [',']) do
        if Trim(ExtractWord(K, Svar, [','])) <> '' then
          W.Str(Trim(ExtractWord(K, Svar, [','])));
      W.EndArray;
    end;

    HarHoder := False;
    for I := 0 to M.ExtraHeaders.Count - 1 do
    begin
      Navn := M.ExtraHeaders.Names[I];
      if SameText(Navn, 'Reply-To') then
        Continue;
      Verdi := M.ExtraHeaders.ValueFromIndex[I];
      if not HarHoder then
      begin
        W.Key('headers');
        W.BeginObject;
        HarHoder := True;
      end;
      W.Field(Navn, Verdi);
    end;
    if HarHoder then
      W.EndObject;

    W.EndObject;
    Result := W.ToString;
  finally
    A.Free;
  end;
end;

function KanProeves(Status: Integer; const Navn: string): Boolean;
begin
  { 5xx og et ekte rate limit går over av seg selv. Kvote gjør det ikke —
    ikke innenfor noen backoff en kø har — så den skal til feiltabellen
    der et menneske ser den, ikke rundt i løkka til forsøkene er brukt
    opp. En valideringsfeil blir aldri riktigere av å sendes igjen. }
  if Status >= 500 then
    Exit(True);
  if Status = 408 then
    Exit(True);
  if Navn = 'rate_limit_exceeded' then
    Exit(True);
  if Navn = 'concurrent_idempotent_requests' then
    Exit(True);
  Result := False;
end;

procedure TResendTransport.Feil(Status: Integer; const Body: string);
var
  A: TArena;
  Root: PJsonValue;
  ErrPos: SizeInt;
  Navn, Msg, Pynt: string;
begin
  Navn := '';
  Msg := '';
  A := TArena.Create(16 * 1024);
  try
    if JsonParse(A, Str(Body), Root, ErrPos) then
    begin
      { Feltet har hatt flere navn: name i den eldre formen, error_type i
        den nyere. Begge leses, og type for sikkerhets skyld — en feil vi
        ikke klarer å navngi skal fortsatt komme fram med status og
        tekst. }
      Navn := JsonAsString(JsonMember(Root, 'name'));
      if Navn = '' then
        Navn := JsonAsString(JsonMember(Root, 'error_type'));
      if Navn = '' then
        Navn := JsonAsString(JsonMember(Root, 'type'));
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

  if Navn <> '' then
    Pynt := ' (' + Navn + ')'
  else
    Pynt := '';

  raise EResendError.Create(Status, Navn,
    Format('Resend API error %d%s: %s', [Status, Pynt, Msg]),
    KanProeves(Status, Navn));
end;

procedure TResendTransport.Send(M: TMailMessage);
var
  Body, Svar, Idem: string;
  Status: Integer;
  A: TArena;
  Root: PJsonValue;
  ErrPos: SizeInt;
begin
  Body := BuildJson(M);

  { Kallerens egen nøkkel når den finnes. Ellers Message-ID-en, som er
    stabil så lenge det er samme objekt — men ikke over en kø som bygger
    meldingen på nytt. Det er derfor Idempotency finnes å sette. }
  Idem := M.IdempotencyKey;
  if Idem = '' then
    Idem := M.EnsureMessageId;

  try
    Svar := FHttp.Post(FBaseUrl + '/emails', FApiKey, Idem, Body, Status);
  except
    on E: EResendError do
      raise;
    on E: EHttpClientError do
      { Nettverket, ikke providern. Alltid verdt et nytt forsøk: vi vet
        ikke om meldingen kom fram, og idempotensnøkkelen gjør det trygt
        å spørre igjen. }
      raise EResendError.Create(0, 'network',
        'Could not reach the Resend API: ' + E.Message, True);
  end;

  if (Status < 200) or (Status > 299) then
    Feil(Status, Svar);

  FLastId := '';
  A := TArena.Create(8 * 1024);
  try
    if JsonParse(A, Str(Svar), Root, ErrPos) then
      FLastId := JsonAsString(JsonMember(Root, 'id'));
  finally
    A.Free;
  end;

  Inc(FCount);
  { Id-en og antall mottakere, ikke adressene og aldri nøkkelen. Det er
    nok til å finne meldingen igjen hos providern, og en epostadresse er
    personopplysning som ikke hører hjemme i en driftslogg. }
  LogInfo('mail sent', ['provider', 'resend', 'id', FLastId,
    'recipients', Length(M.AllRecipients)]);
end;

{ --------------------------------------------------------- registrering -- }

function LagResend: TMailTransport;
begin
  Result := TResendTransport.Create;
end;

initialization
  { Gjør mail.transport = resend mulig. Uniten må være linket inn for at
    navnet skal finnes — MailFromConfig sier fra når det ikke er det, i
    stedet for å falle tilbake til loggfila. }
  RegisterMailTransport('resend', @LagResend);

end.
