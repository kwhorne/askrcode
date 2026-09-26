{ Askr.Notify — tell a person something, on the channels they are reached
  on.

      type
        TOrderShipped = class(TNotification)
        private
          FOrderId: Int64;
        public
          function Via(const N: TNotifiable): TStringArray; override;
          function ToMail(const N: TNotifiable): TMailMessage; override;
          function ToSms(const N: TNotifiable): string; override;
        published
          property OrderId: Int64 read FOrderId write FOrderId;
        end;

      function TOrderShipped.Via(const N: TNotifiable): TStringArray;
      begin
        Result := [ChannelMail, ChannelDatabase];
        if N.Phone <> '' then
          Result := Result + [ChannelSms];
      end;
      ...
      Notice := TOrderShipped.Create;
      Notice.OrderId := O.Id;
      NotifyLater(NotifiableFor(U.Id, U.Email).WithPhone(U.Phone), Notice);

  A notification says what to tell; Via says where, per person; the
  channels do the sending. Mail is here. The database, Slack and SMS are
  units of their own -- Askr.Notify.Db, Askr.Notify.Slack, Askr.Notify.Sms
  -- so an app that only mails links none of what they need.

  **The framework does not own the user model**, so a notifiable is a
  record the app fills: the id it signs in with, and the addresses it
  has. The same rule as Askr.Auth.

  **A notification is carried the way an event is**: it is a TEvent, and
  its published properties are what crosses the queue. Keep ids, not
  objects.

  **NotifyLater queues one job per channel.** A text message that fails is
  retried without the mail going out again. Every job for one person
  carries the same id, made when it was queued: the mail uses it as its
  idempotency key, and the database row as its key, so a retry after the
  first attempt got through does not deliver twice there. Slack and SMS
  have no such key, and a retry can send twice -- said, not hidden.

  **Notify sends on every channel before it raises.** A failed text
  message is no reason for the row in the database not to be written. The
  exception afterwards names each channel that failed.

  **A channel name nothing has registered raises before anything is
  sent**, where Notify or NotifyLater is called. A typo would otherwise
  be a message that silently never went. Use the constants. }
unit Askr.Notify;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Askr.Events, Askr.Queue, Askr.Mail;

const
  ChannelMail = 'mail';
  ChannelDatabase = 'database';
  ChannelSlack = 'slack';
  ChannelSms = 'sms';

type
  ENotifyError = class(Exception);

  { Who is told. Id is the app's own user id, as text -- the one Login
    takes -- and may be empty for someone who is not a user: an address,
    a Slack channel for the people on call. }
  TNotifiable = record
    Id: string;
    Name: string;
    Email: string;
    { E.164: +4791234567. }
    Phone: string;
    { A Slack incoming webhook. Empty uses slack.webhook. }
    Slack: string;
    { The language the notification is written in. Empty is the default
      locale -- a queue worker has no request to take one from. }
    Locale: string;
    function WithName(const AName: string): TNotifiable;
    function WithPhone(const APhone: string): TNotifiable;
    function WithSlack(const AWebhook: string): TNotifiable;
    function WithLocale(const ALocale: string): TNotifiable;
  end;

  TNotification = class(TEvent)
  public
    { The channels this person is told on. Raises unless overridden: a
      notification that goes nowhere should be one somebody chose. An
      override may give [] for a person who wants none. }
    function Via(const N: TNotifiable): TStringArray; virtual;
    { The mail. Sent to N.Email unless it has recipients of its own. }
    function ToMail(const N: TNotifiable): TMailMessage; virtual;
    { A JSON object for the database. The published properties unless
      overridden. }
    function ToDatabase(const N: TNotifiable): string; virtual;
    { The text of a Slack message, or a whole payload when it starts with
      a brace -- blocks and all. }
    function ToSlack(const N: TNotifiable): string; virtual;
    function ToSms(const N: TNotifiable): string; virtual;
  end;

  TNotificationClass = class of TNotification;

  { Sends one notification to one person. Uid is the same for every
    channel and every retry of one notification to one person. }
  TNotificationChannel = class
  public
    procedure Send(const N: TNotifiable; Notice: TNotification;
      const Uid: string); virtual; abstract;
  end;

function NotifiableFor(const Id, Email: string): TNotifiable;

{ Registers a channel under Name, and owns it. At startup, before
  anything is sent: the list is read without a lock. }
procedure RegisterChannel(const Name: string; C: TNotificationChannel);
function ChannelNamed(const Name: string): TNotificationChannel;

{ Sends now, on each channel Via gives, and frees Notice. }
procedure Notify(const N: TNotifiable; Notice: TNotification); overload;
procedure Notify(const Ns: array of TNotifiable; Notice: TNotification); overload;

{ Queues a job per person and channel, and frees Notice. Via is asked
  now, while the request knows what the person wants. }
procedure NotifyLater(const N: TNotifiable; Notice: TNotification); overload;
procedure NotifyLater(const Ns: array of TNotifiable; Notice: TNotification); overload;

{ The queue NotifyLater uses, and whose workers send. At startup, in
  every process that runs the queue's workers. }
procedure UseNotificationQueue(Q: TQueue);

{ Makes a notification class known by name to this process's workers --
  RegisterEvent under its own name. A class that was sent from here is
  known already. }
procedure RegisterNotification(AClass: TNotificationClass);

{ For a test. From here on a notification of one of these classes -- of
  any class, when none are given -- is recorded instead of sent: Via is
  asked, and each channel's To... is called and thrown away, so one that
  would fail fails, but nothing goes anywhere and nothing is queued. }
procedure FakeNotifications(const Classes: array of TNotificationClass);
procedure StopFakingNotifications;
{ How many of AClass were sent, to ToId when it is given. }
function NotificationsSent(AClass: TNotificationClass; const ToId: string = ''): Integer;
{ The channels one went on, comma separated: 'mail,sms'. }
function SentNotificationChannels(AClass: TNotificationClass; Index: Integer = 0): string;
{ Its published properties as they were when it was sent. }
function SentNotificationJson(AClass: TNotificationClass; Index: Integer = 0): string;

implementation

uses
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Json, Askr.Core.Crypto,
  Askr.Core.Lang;

const
  JobName = 'askr.notify';

type
  TChannelEntry = record
    Name: string;
    Channel: TNotificationChannel;
  end;

  TSentRecord = record
    NotificationClass: TNotificationClass;
    ToId: string;
    Channels: string;
    Json: string;
  end;

var
  GChannels: array of TChannelEntry;
  GQueue: TQueue = nil;
  GFaking: Boolean = False;
  GFakeClasses: array of TNotificationClass;
  GSent: array of TSentRecord;

{ TNotifiable }

function NotifiableFor(const Id, Email: string): TNotifiable;
begin
  Result.Id := Id;
  Result.Name := '';
  Result.Email := Email;
  Result.Phone := '';
  Result.Slack := '';
  Result.Locale := '';
end;

function TNotifiable.WithName(const AName: string): TNotifiable;
begin
  Result := Self;
  Result.Name := AName;
end;

function TNotifiable.WithPhone(const APhone: string): TNotifiable;
begin
  Result := Self;
  Result.Phone := APhone;
end;

function TNotifiable.WithSlack(const AWebhook: string): TNotifiable;
begin
  Result := Self;
  Result.Slack := AWebhook;
end;

function TNotifiable.WithLocale(const ALocale: string): TNotifiable;
begin
  Result := Self;
  Result.Locale := ALocale;
end;

{ TNotification }

function TNotification.Via(const N: TNotifiable): TStringArray;
begin
  Result := nil;
  raise ENotifyError.CreateFmt('%s does not say where it goes: override Via',
    [ClassName]);
end;

function TNotification.ToMail(const N: TNotifiable): TMailMessage;
begin
  Result := nil;
  raise ENotifyError.CreateFmt('%s goes by mail, and has no ToMail', [ClassName]);
end;

function TNotification.ToDatabase(const N: TNotifiable): string;
begin
  Result := EventToJson(Self);
end;

function TNotification.ToSlack(const N: TNotifiable): string;
begin
  Result := '';
  raise ENotifyError.CreateFmt('%s goes to Slack, and has no ToSlack', [ClassName]);
end;

function TNotification.ToSms(const N: TNotifiable): string;
begin
  Result := '';
  raise ENotifyError.CreateFmt('%s goes by text message, and has no ToSms', [ClassName]);
end;

{ ------------------------------------------------------------ channels -- }

procedure RegisterChannel(const Name: string; C: TNotificationChannel);
var
  I: Integer;
begin
  if (Name = '') or (C = nil) then
    raise ENotifyError.Create('A channel needs a name and an object');
  for I := 0 to High(GChannels) do
    if SameText(GChannels[I].Name, Name) then
    begin
      if GChannels[I].Channel <> C then
        GChannels[I].Channel.Free;
      GChannels[I].Channel := C;
      Exit;
    end;
  I := Length(GChannels);
  SetLength(GChannels, I + 1);
  GChannels[I].Name := LowerCase(Name);
  GChannels[I].Channel := C;
end;

function ChannelNamed(const Name: string): TNotificationChannel;
var
  I: Integer;
begin
  for I := 0 to High(GChannels) do
    if SameText(GChannels[I].Name, Name) then
      Exit(GChannels[I].Channel);
  Result := nil;
end;

{ Every channel Via gives, or an exception naming the first nothing has
  registered -- before anything is sent. The unit that registers each of
  the built-in ones is named, since forgetting it is the likely cause. }
function ResolveChannels(Notice: TNotification; const Names: TStringArray): TStringArray;
var
  I: Integer;
  Hint: string;
begin
  Result := nil;
  SetLength(Result, Length(Names));
  for I := 0 to High(Names) do
  begin
    if ChannelNamed(Names[I]) = nil then
    begin
      if SameText(Names[I], ChannelDatabase) then
        Hint := ' Use Askr.Notify.Db and call UseDatabaseNotifications at startup.'
      else if SameText(Names[I], ChannelSlack) then
        Hint := ' Use Askr.Notify.Slack.'
      else if SameText(Names[I], ChannelSms) then
        Hint := ' Use Askr.Notify.Sms.'
      else
        Hint := ' RegisterChannel it at startup.';
      raise ENotifyError.CreateFmt('%s goes by "%s", and no channel is registered ' +
        'by that name.%s', [Notice.ClassName, Names[I], Hint]);
    end;
    Result[I] := LowerCase(Names[I]);
  end;
end;

{ Sends on one channel in N's locale. }
procedure SendOn(const Channel: string; const N: TNotifiable; Notice: TNotification;
  const Uid: string);
var
  Prev: string;
begin
  if N.Locale = '' then
  begin
    ChannelNamed(Channel).Send(N, Notice, Uid);
    Exit;
  end;
  Prev := UseLocale(N.Locale);
  try
    ChannelNamed(Channel).Send(N, Notice, Uid);
  finally
    UseLocale(Prev);
  end;
end;

{ ---------------------------------------------------------------- mail -- }

function Who(const N: TNotifiable): string;
begin
  if N.Id <> '' then
    Result := 'user ' + N.Id
  else
    Result := 'the recipient';
end;


type
  TMailChannel = class(TNotificationChannel)
  public
    procedure Send(const N: TNotifiable; Notice: TNotification;
      const Uid: string); override;
  end;

procedure TMailChannel.Send(const N: TNotifiable; Notice: TNotification;
  const Uid: string);
var
  M: TMailMessage;
begin
  M := Notice.ToMail(N);
  if M = nil then
    raise ENotifyError.CreateFmt('%s.ToMail gave no message', [Notice.ClassName]);
  try
    if Length(M.AllRecipients) = 0 then
    begin
      if N.Email = '' then
        raise ENotifyError.CreateFmt('%s goes by mail, and %s has no address',
          [Notice.ClassName, Who(N)]);
      M.AddTo(N.Email, N.Name);
    end;
    if (M.IdempotencyKey = '') and (Uid <> '') then
      M.Idempotency('notification-' + Uid);
  except
    M.Free;
    raise;
  end;
  Mail.Send(M);
end;

{ --------------------------------------------------------------- fakes -- }

function Faked(Notice: TNotification): Boolean;
var
  I: Integer;
begin
  Result := False;
  if not GFaking then
    Exit;
  if Length(GFakeClasses) = 0 then
    Exit(True);
  for I := 0 to High(GFakeClasses) do
    if Notice.InheritsFrom(GFakeClasses[I]) then
      Exit(True);
end;

{ What a real send would have built, built and thrown away, and a record
  of it. A fake that took what a real channel refuses is a test that is
  green on a notification that never goes. }
procedure RecordFake(const N: TNotifiable; Notice: TNotification;
  const Channels: TStringArray);
var
  I: Integer;
  M: TMailMessage;
  Joined: string;
begin
  Joined := '';
  for I := 0 to High(Channels) do
  begin
    if Channels[I] = ChannelMail then
    begin
      M := Notice.ToMail(N);
      M.Free;
    end
    else if Channels[I] = ChannelDatabase then
      Notice.ToDatabase(N)
    else if Channels[I] = ChannelSlack then
      Notice.ToSlack(N)
    else if Channels[I] = ChannelSms then
      Notice.ToSms(N);
    if Joined <> '' then
      Joined := Joined + ',';
    Joined := Joined + Channels[I];
  end;
  I := Length(GSent);
  SetLength(GSent, I + 1);
  GSent[I].NotificationClass := TNotificationClass(Notice.ClassType);
  GSent[I].ToId := N.Id;
  GSent[I].Channels := Joined;
  GSent[I].Json := EventToJson(Notice);
end;

{ ---------------------------------------------------------------- send -- }

procedure NotifyOne(const N: TNotifiable; Notice: TNotification);
var
  Channels: TStringArray;
  I: Integer;
  Uid, Failed, First: string;
begin
  Channels := ResolveChannels(Notice, Notice.Via(N));
  if Faked(Notice) then
  begin
    RecordFake(N, Notice, Channels);
    Exit;
  end;
  Uid := LowerCase(RandomHex(16));
  Failed := '';
  First := '';
  for I := 0 to High(Channels) do
    try
      SendOn(Channels[I], N, Notice, Uid);
    except
      on E: Exception do
      begin
        if Failed <> '' then
          Failed := Failed + ', ';
        Failed := Failed + Channels[I];
        if First = '' then
          First := E.Message;
      end;
    end;
  if Failed <> '' then
    raise ENotifyError.CreateFmt('%s to %s did not go by %s: %s',
      [Notice.ClassName, Who(N), Failed, First]);
end;

procedure Notify(const N: TNotifiable; Notice: TNotification);
begin
  try
    NotifyOne(N, Notice);
  finally
    Notice.Free;
  end;
end;

procedure Notify(const Ns: array of TNotifiable; Notice: TNotification);
var
  I: Integer;
  Errors: string;
begin
  Errors := '';
  try
    { One who could not be told is no reason for the rest not to be. }
    for I := 0 to High(Ns) do
      try
        NotifyOne(Ns[I], Notice);
      except
        on E: Exception do
        begin
          if Errors <> '' then
            Errors := Errors + '; ';
          Errors := Errors + E.Message;
        end;
      end;
  finally
    Notice.Free;
  end;
  if Errors <> '' then
    raise ENotifyError.Create(Errors);
end;

{ --------------------------------------------------------------- queue -- }

procedure WriteNotifiable(var W: TJsonWriter; const N: TNotifiable);
begin
  W.BeginObject;
  W.Field('id', N.Id);
  W.Field('name', N.Name);
  W.Field('email', N.Email);
  W.Field('phone', N.Phone);
  W.Field('slack', N.Slack);
  W.Field('locale', N.Locale);
  W.EndObject;
end;

function JobPayload(const N: TNotifiable; Notice: TNotification;
  const Channel, Uid, Data: string): string;
var
  A: TArena;
  W: TJsonWriter;
begin
  A := TArena.Create(4096);
  try
    W.Init(A, 512);
    W.BeginObject;
    W.Key('notification'); W.Str(Notice.ClassName);
    W.Key('channel'); W.Str(Channel);
    W.Key('uid'); W.Str(Uid);
    W.Key('to'); WriteNotifiable(W, N);
    W.Key('data'); W.Raw(StrDup(A, Data));
    W.EndObject;
    Result := W.ToString;
  finally
    A.Free;
  end;
end;

procedure NotifyLaterOne(const N: TNotifiable; Notice: TNotification);
var
  Channels: TStringArray;
  I: Integer;
  Uid, Data: string;
begin
  Channels := ResolveChannels(Notice, Notice.Via(N));
  if Faked(Notice) then
  begin
    RecordFake(N, Notice, Channels);
    Exit;
  end;
  if Length(Channels) = 0 then
    Exit;
  if GQueue = nil then
    raise ENotifyError.Create('NotifyLater needs a queue: call ' +
      'UseNotificationQueue at startup');
  Uid := LowerCase(RandomHex(16));
  Data := EventToJson(Notice);
  for I := 0 to High(Channels) do
    GQueue.Push(JobName, JobPayload(N, Notice, Channels[I], Uid, Data));
end;

procedure CheckCarried(Notice: TNotification);
var
  Bad: string;
begin
  Bad := UncarriedProperty(TEventClass(Notice.ClassType));
  if Bad <> '' then
    raise ENotifyError.CreateFmt('%s.%s cannot cross the queue: only strings, ' +
      'numbers, booleans, enumerations and dates can. Carry an id instead.',
      [Notice.ClassName, Bad]);
  RegisterEvent(TEventClass(Notice.ClassType));
end;

procedure NotifyLater(const N: TNotifiable; Notice: TNotification);
begin
  try
    CheckCarried(Notice);
    NotifyLaterOne(N, Notice);
  finally
    Notice.Free;
  end;
end;

procedure NotifyLater(const Ns: array of TNotifiable; Notice: TNotification);
var
  I: Integer;
begin
  try
    CheckCarried(Notice);
    for I := 0 to High(Ns) do
      NotifyLaterOne(Ns[I], Notice);
  finally
    Notice.Free;
  end;
end;

{ The worker's side: the notification built again, sent on the one
  channel the job is for. }
procedure RunJob(const Ctx: TJobContext);
var
  A: TArena;
  Root, T: PJsonValue;
  ErrorAt: SizeInt;
  ClassName_, Channel, Uid, Data: string;
  N: TNotifiable;
  Cls: TEventClass;
  Notice: TEvent;
begin
  A := TArena.Create(4096);
  try
    if not JsonParse(A, Ctx.Payload, Root, ErrorAt) or (Root^.Kind <> jkObject) then
      raise ENotifyError.Create('The job is not a notification');
    ClassName_ := JsonAsString(JsonMember(Root, 'notification'));
    Channel := JsonAsString(JsonMember(Root, 'channel'));
    Uid := JsonAsString(JsonMember(Root, 'uid'));
    Data := JsonToString(A, JsonMember(Root, 'data'));
    T := JsonMember(Root, 'to');
    N := NotifiableFor(JsonAsString(JsonMember(T, 'id')),
      JsonAsString(JsonMember(T, 'email')));
    N.Name := JsonAsString(JsonMember(T, 'name'));
    N.Phone := JsonAsString(JsonMember(T, 'phone'));
    N.Slack := JsonAsString(JsonMember(T, 'slack'));
    N.Locale := JsonAsString(JsonMember(T, 'locale'));
  finally
    A.Free;
  end;
  Cls := EventClassNamed(ClassName_);
  if (Cls = nil) or not Cls.InheritsFrom(TNotification) then
    raise ENotifyError.CreateFmt('%s is not a notification this process knows. ' +
      'Call RegisterNotification(%s) at startup, where the queue''s workers run.',
      [ClassName_, ClassName_]);
  if ChannelNamed(Channel) = nil then
    raise ENotifyError.CreateFmt('The channel "%s" is not registered in the process ' +
      'that runs the queue''s workers', [Channel]);
  Notice := EventFromJson(Cls, Data);
  try
    SendOn(Channel, N, TNotification(Notice), Uid);
  finally
    Notice.Free;
  end;
end;

procedure UseNotificationQueue(Q: TQueue);
begin
  GQueue := Q;
  if Q <> nil then
    Q.Handle(JobName, RunJob);
end;

procedure RegisterNotification(AClass: TNotificationClass);
begin
  RegisterEvent(AClass);
end;

{ --------------------------------------------------------------- fakes -- }

procedure FakeNotifications(const Classes: array of TNotificationClass);
var
  I: Integer;
begin
  GFaking := True;
  GFakeClasses := nil;
  SetLength(GFakeClasses, Length(Classes));
  for I := 0 to High(Classes) do
    GFakeClasses[I] := Classes[I];
  GSent := nil;
end;

procedure StopFakingNotifications;
begin
  GFaking := False;
  GFakeClasses := nil;
  GSent := nil;
end;

function NotificationsSent(AClass: TNotificationClass; const ToId: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(GSent) do
    if GSent[I].NotificationClass.InheritsFrom(AClass) and
       ((ToId = '') or (GSent[I].ToId = ToId)) then
      Inc(Result);
end;

function FindSent(AClass: TNotificationClass; Index: Integer): Integer;
var
  I, N: Integer;
begin
  N := 0;
  for I := 0 to High(GSent) do
    if GSent[I].NotificationClass.InheritsFrom(AClass) then
    begin
      if N = Index then
        Exit(I);
      Inc(N);
    end;
  raise ENotifyError.CreateFmt('No %s number %d was sent', [AClass.ClassName, Index]);
end;

function SentNotificationChannels(AClass: TNotificationClass; Index: Integer): string;
begin
  Result := GSent[FindSent(AClass, Index)].Channels;
end;

function SentNotificationJson(AClass: TNotificationClass; Index: Integer): string;
begin
  Result := GSent[FindSent(AClass, Index)].Json;
end;

initialization
  RegisterChannel(ChannelMail, TMailChannel.Create);

end.
