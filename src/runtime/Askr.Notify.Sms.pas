{ Askr.Notify.Sms — a notification as a text message.

      uses Askr.Notify.Sms;     // registers the channel
      ...
      SetSms(SmsFromConfig);    // at startup

  A transport sends; the channel finds the number and the text. Two
  transports are here: Twilio, over its REST API, and a log that writes
  each message to storage/logs/sms.log for development. Another provider
  is a TSmsTransport with a Send.

  **A number is E.164 or it is refused**, before anything goes out:
  a plus, a country code, and the rest, 8 to 15 digits in all. A number
  written for a person -- spaces, a leading zero -- would reach the
  provider, which charges for the attempt or delivers it somewhere else.

  **There is no idempotency key.** Twilio has none for sending, so a job
  retried after Twilio took the message but before the answer came back
  sends it twice. Said, not hidden.

  **Twilio itself has not been sent to from here.** The request is held
  to Twilio's documented form by a test that reads the bytes sent to a
  local server; a message delivered by Twilio is a different claim, and
  it is not made until someone has done it with a real account.

  The auth token comes from TWILIO_TOKEN and is never logged, and no
  error carries it. }
unit Askr.Notify.Sms;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Askr.Notify;

type
  { What the provider said, unadorned. Code is Twilio's own number --
    21211 for a number it will not send to -- and 0 when there was none. }
  ESmsError = class(ENotifyError)
  private
    FStatus: Integer;
    FCode: Integer;
  public
    constructor Create(AStatus, ACode: Integer; const AMessage: string);
    property Status: Integer read FStatus;
    property Code: Integer read FCode;
  end;

  TSmsTransport = class
  public
    { Sends Body to the E.164 number To_, and gives the provider's id for
      the message. }
    function Send(const To_, Body: string): string; virtual; abstract;
    function Describe: string; virtual; abstract;
  end;

  TTwilioSms = class(TSmsTransport)
  private
    FSid, FToken, FFrom, FBaseUrl: string;
  public
    { From is a number, or a Messaging Service -- the SID that starts
      with MG -- which picks the number itself. }
    constructor Create(const AAccountSid, AAuthToken, AFrom: string);
    function Send(const To_, Body: string): string; override;
    function Describe: string; override;
    { For a test server. }
    property BaseUrl: string read FBaseUrl write FBaseUrl;
  end;

  TLogSms = class(TSmsTransport)
  private
    FPath: string;
    FCount: Integer;
  public
    constructor Create(const APath: string = 'storage/logs/sms.log');
    function Send(const To_, Body: string): string; override;
    function Describe: string; override;
  end;

  TSmsChannel = class(TNotificationChannel)
  public
    procedure Send(const N: TNotifiable; Notice: TNotification;
      const Uid: string); override;
  end;

function Sms: TSmsTransport;
{ Owns it. }
procedure SetSms(ATransport: TSmsTransport);

{ The transport sms.driver names: 'log', unless set, or 'twilio', with
  twilio.sid, twilio.token and twilio.from. An unknown name raises: a typo
  in production would otherwise look like messages going out. }
function SmsFromConfig: TSmsTransport;

{ Raises unless Number is E.164. }
procedure CheckPhoneNumber(const Number: string);

implementation

uses
  Classes, DateUtils, Askr.Core.Arena, Askr.Core.Text, Askr.Core.Json,
  Askr.Core.Config, Askr.Core.Crypto, Askr.Http.Client;

var
  GSms: TSmsTransport = nil;

constructor ESmsError.Create(AStatus, ACode: Integer; const AMessage: string);
begin
  inherited Create(AMessage);
  FStatus := AStatus;
  FCode := ACode;
end;

procedure CheckPhoneNumber(const Number: string);
var
  I: Integer;
  Ok: Boolean;
begin
  Ok := (Length(Number) >= 9) and (Length(Number) <= 16) and (Number[1] = '+') and
    (Number[2] in ['1'..'9']);
  if Ok then
    for I := 3 to Length(Number) do
      if not (Number[I] in ['0'..'9']) then
      begin
        Ok := False;
        Break;
      end;
  if not Ok then
    raise ENotifyError.CreateFmt('"%s" is not a phone number a text message can go ' +
      'to: write it E.164, as +4791234567', [Number]);
end;

{ ------------------------------------------------------------- Twilio -- }

function RawBytes(const S: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(S));
  if S <> '' then
    Move(S[1], Result[0], Length(S));
end;

constructor TTwilioSms.Create(const AAccountSid, AAuthToken, AFrom: string);
begin
  inherited Create;
  if (AAccountSid = '') or (AAuthToken = '') or (AFrom = '') then
    raise ENotifyError.Create('Twilio needs an account SID, an auth token and a ' +
      'number or Messaging Service to send from');
  FSid := AAccountSid;
  FToken := AAuthToken;
  FFrom := AFrom;
  FBaseUrl := 'https://api.twilio.com';
end;

function TTwilioSms.Send(const To_, Body: string): string;
var
  C: THttpClient;
  R: THttpResponse;
  Form: string;
  A: TArena;
  Root: PJsonValue;
  ErrorAt: SizeInt;
  Code: Integer;
  Msg: string;
begin
  if Copy(FFrom, 1, 2) = 'MG' then
    Form := 'MessagingServiceSid=' + UrlEncodeValue(FFrom)
  else
    Form := 'From=' + UrlEncodeValue(FFrom);
  Form := 'To=' + UrlEncodeValue(To_) + '&' + Form + '&Body=' + UrlEncodeValue(Body);
  C := THttpClient.Create;
  try
    C.MaxRedirects := 0;
    C.WithHeader('Authorization', 'Basic ' +
      Base64Encode(RawBytes(FSid + ':' + FToken)));
    R := C.Post(FBaseUrl + '/2010-04-01/Accounts/' + UrlEncodeValue(FSid) +
      '/Messages.json', Form, 'application/x-www-form-urlencoded');
  finally
    C.Free;
  end;
  A := TArena.Create(Length(R.Body) * 2 + 1024);
  try
    Root := nil;
    if not JsonParse(A, StrDup(A, R.Body), Root, ErrorAt) or (Root^.Kind <> jkObject) then
      Root := nil;
    if (R.Status >= 200) and (R.Status <= 299) then
    begin
      Result := JsonAsString(JsonMember(Root, 'sid'));
      if Result = '' then
        raise ESmsError.Create(R.Status, 0, 'Twilio answered without a message SID');
      Exit;
    end;
    // {"code":21211,"message":"The 'To' number ... is not valid","status":400}
    // -- or, from something in between, not JSON at all.
    Code := JsonAsInt(JsonMember(Root, 'code'), 0);
    Msg := JsonAsString(JsonMember(Root, 'message'));
    if Msg = '' then
      Msg := Trim(Copy(R.Body, 1, 120));
    raise ESmsError.Create(R.Status, Code,
      Format('Twilio refused the message: %d %d %s', [R.Status, Code, Msg]));
  finally
    A.Free;
  end;
end;

function TTwilioSms.Describe: string;
begin
  { Never the token. }
  Result := 'twilio (' + FSid + ', from ' + FFrom + ')';
end;

{ ----------------------------------------------------------------- log -- }

constructor TLogSms.Create(const APath: string);
begin
  inherited Create;
  FPath := APath;
end;

function TLogSms.Send(const To_, Body: string): string;
var
  F: TextFile;
begin
  ForceDirectories(ExtractFilePath(ExpandFileName(FPath)));
  AssignFile(F, FPath);
  if FileExists(FPath) then
    Append(F)
  else
    Rewrite(F);
  try
    WriteLn(F, FormatDateTime('yyyy-mm-dd hh:nn:ss', Now), '  to ', To_);
    WriteLn(F, Body);
    WriteLn(F);
  finally
    CloseFile(F);
  end;
  Inc(FCount);
  Result := 'log-' + IntToStr(FCount);
end;

function TLogSms.Describe: string;
begin
  Result := 'log (' + FPath + ')';
end;

{ ------------------------------------------------------------- channel -- }

procedure TSmsChannel.Send(const N: TNotifiable; Notice: TNotification;
  const Uid: string);
var
  Body: string;
begin
  if N.Phone = '' then
    raise ENotifyError.CreateFmt('%s goes by text message, and the recipient has ' +
      'no phone number', [Notice.ClassName]);
  CheckPhoneNumber(N.Phone);
  Body := Notice.ToSms(N);
  if Trim(Body) = '' then
    raise ENotifyError.CreateFmt('%s.ToSms gave no text', [Notice.ClassName]);
  Sms.Send(N.Phone, Body);
end;

function Sms: TSmsTransport;
begin
  if GSms = nil then
    raise ENotifyError.Create('No SMS transport is set. Call SetSms(SmsFromConfig) ' +
      'at startup.');
  Result := GSms;
end;

procedure SetSms(ATransport: TSmsTransport);
begin
  if GSms <> ATransport then
    GSms.Free;
  GSms := ATransport;
end;

function SmsFromConfig: TSmsTransport;
var
  Name_: string;
begin
  Name_ := LowerCase(Cfg('sms.driver', 'log'));
  if Name_ = 'log' then
    Exit(TLogSms.Create);
  if Name_ = 'twilio' then
    Exit(TTwilioSms.Create(Cfg('twilio.sid', ''), Cfg('twilio.token', ''),
      Cfg('twilio.from', '')));
  raise ENotifyError.CreateFmt('sms.driver is "%s", and the drivers are log and twilio',
    [Name_]);
end;

initialization
  RegisterChannel(ChannelSms, TSmsChannel.Create);

finalization
  GSms.Free;

end.
