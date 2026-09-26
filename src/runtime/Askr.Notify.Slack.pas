{ Askr.Notify.Slack — a notification as a message in a Slack channel.

      uses Askr.Notify.Slack;   // registers the channel

      function TDeployFailed.ToSlack(const N: TNotifiable): string;
      begin
        Result := 'Deploy of ' + Commit + ' failed';
      end;

  Over an incoming webhook: a URL Slack makes for one channel, which is
  the permission to post there and nothing else. It comes from the
  recipient's Slack field, or from slack.webhook -- SLACK_WEBHOOK in the
  environment -- for the team's own channel.

  **The webhook URL is a secret**, since anyone who has it can post. It
  goes in no error message and no log line; an error says what Slack
  answered, which is a word like no_service.

  **HTTPS, or HTTP to this machine.** A webhook over plain HTTP would put
  the secret on the wire. Loopback is let through for a test server.

  A unit of its own because it needs the HTTP client: an app that only
  mails links none of it. }
unit Askr.Notify.Slack;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Askr.Notify;

type
  TSlackChannel = class(TNotificationChannel)
  private
    FTimeoutMs: Integer;
  public
    constructor Create;
    procedure Send(const N: TNotifiable; Notice: TNotification;
      const Uid: string); override;
    property TimeoutMs: Integer read FTimeoutMs write FTimeoutMs;
  end;

(* The JSON Slack is sent for what ToSlack gave: a payload as it is when
   it starts with a brace, and otherwise the text as {"text": ...}. *)
function SlackPayload(const S: string): string;

{ Raises unless Url is one the channel will post to. }
procedure CheckWebhookUrl(const Url: string);

implementation

uses
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Json, Askr.Core.Config,
  Askr.Http.Client;

constructor TSlackChannel.Create;
begin
  inherited Create;
  FTimeoutMs := 15000;
end;

function SlackPayload(const S: string): string;
var
  A: TArena;
  W: TJsonWriter;
  Root: PJsonValue;
  ErrorAt: SizeInt;
begin
  A := TArena.Create(Length(S) * 2 + 1024);
  try
    if (Trim(S) <> '') and (Trim(S)[1] = '{') then
    begin
      if not JsonParse(A, StrDup(A, S), Root, ErrorAt) or (Root^.Kind <> jkObject) then
        raise ENotifyError.Create('ToSlack gave something that starts with a brace ' +
          'and is not a JSON object');
      Exit(Trim(S));
    end;
    if Trim(S) = '' then
      raise ENotifyError.Create('ToSlack gave no text');
    W.Init(A, Length(S) + 32);
    W.BeginObject;
    W.Field('text', S);
    W.EndObject;
    Result := W.ToString;
  finally
    A.Free;
  end;
end;

procedure CheckWebhookUrl(const Url: string);
var
  Scheme, Host, Rest: string;
  Port: Word;
begin
  if not ParseUrl(Url, Scheme, Host, Port, Rest) then
    raise ENotifyError.Create('The Slack webhook is not a URL');
  if SameText(Scheme, 'https') then
    Exit;
  if SameText(Scheme, 'http') and ((Host = '127.0.0.1') or SameText(Host, 'localhost')) then
    Exit;
  { The host is said, not the URL: the path is the secret. }
  raise ENotifyError.CreateFmt('The Slack webhook for %s is not HTTPS, and would ' +
    'put its secret on the wire', [Host]);
end;

{ Slack's answer, for an error: short, one line, and never the URL. }
function Said(const Body: string): string;
var
  I: Integer;
begin
  Result := Copy(Body, 1, 120);
  for I := 1 to Length(Result) do
    if Result[I] < ' ' then
      Result[I] := ' ';
  Result := Trim(Result);
end;

procedure TSlackChannel.Send(const N: TNotifiable; Notice: TNotification;
  const Uid: string);
var
  Url, Payload: string;
  C: THttpClient;
  R: THttpResponse;
begin
  Url := N.Slack;
  if Url = '' then
    Url := Cfg('slack.webhook', '');
  if Url = '' then
    raise ENotifyError.CreateFmt('%s goes to Slack, and there is no webhook: set ' +
      'SLACK_WEBHOOK, or give the recipient one', [Notice.ClassName]);
  CheckWebhookUrl(Url);
  Payload := SlackPayload(Notice.ToSlack(N));
  C := THttpClient.Create;
  try
    C.ConnectTimeoutMs := FTimeoutMs;
    C.ReadTimeoutMs := FTimeoutMs;
    { A webhook that answers with a redirect is not Slack. }
    C.MaxRedirects := 0;
    try
      R := C.Post(Url, Payload, 'application/json');
    except
      { The client's own errors quote the URL, and this one is the
        secret. }
      on E: Exception do
        raise ENotifyError.CreateFmt('Could not reach the Slack webhook for %s: %s',
          [Notice.ClassName, StringReplace(E.Message, Url, '(the webhook)',
            [rfReplaceAll])]);
    end;
  finally
    C.Free;
  end;
  if (R.Status < 200) or (R.Status > 299) then
    raise ENotifyError.CreateFmt('Slack refused %s: %d %s',
      [Notice.ClassName, R.Status, Said(R.Body)]);
end;

initialization
  RegisterChannel(ChannelSlack, TSlackChannel.Create);

end.
