{ Askr.Live -- a page that finds out its props went stale.

      // the page's handler: this page listens on the gadgets channel
      LiveOn(['gadgets']);
      Result := Inertia('Gadgets/Index', ['gadgets', Grid]);

      // wherever a gadget changes: a handler, a job, another process's
      // broadcast
      PropsChanged('gadgets', ['gadgets']);

  and in the layout, once, from @askrcode/lauf/inertia:

      <Live />

  Every open page listening on the channel reloads the props named, and
  only those: an Inertia partial reload, so the page keeps its scroll, its
  form input and its open dropdown. The idea is Phoenix LiveView's -- the
  server says when a view is out of date -- without a socket per view or
  state kept on the server: the event names props, and the page fetches
  them again as it would on any visit.

  **The page that was shown decides what it may listen to.** LiveOn signs
  the stream's URL, channels and all, under APP_KEY, bound to the signed-in
  user, and the browser gets it as the askrLive prop. /_askr/live opens
  only a URL signed here, for the user asking, within a day. There is no
  list of channels a browser may ask for, because the handler that
  rendered the page already did the checking: a channel per user --
  'user.' + Id -- stays that user's, and a copied URL is no use to anyone
  else.

  **An event carries names, never values.** Everyone on the channel hears
  it, so what changed is fetched through the page's own handler, with that
  viewer's own authorisation. A prop that is not the viewer's to see is
  never in the event to begin with.

  **Each open page is a stream**, and a stream is a thread. See
  Askr.Http.Stream for what that costs; a page that does not call LiveOn
  opens none. }
unit Askr.Live;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Askr.Http.Types, Askr.Http.Request, Askr.Http.Response,
  Askr.Http.Router;

type
  ELiveError = class(Exception);

const
  LivePath = '/_askr/live';
  { The SSE event PropsChanged sends and Lauf's <Live /> listens for. }
  LiveEvent = 'askr.stale';
  { How long a page's signed stream URL opens a stream: a tab left open
    overnight still reconnects in the morning. }
  LiveLifetimeSeconds = 24 * 60 * 60;

{ The page being built listens on these channels. Call it in the handler,
  before Inertia(...). Channel names are letters, digits and . _ : - }
procedure LiveOn(const Channels: array of string);

{ Every page listening on Channel reloads these props. Prop names are
  identifiers: letters, digits and _. }
procedure PropsChanged(const Channel: string; const Props: array of string);

{ The stream route, /_askr/live. After UseAuth: the URL is bound to who is
  signed in. }
procedure UseLive(R: TRouter);

implementation

uses
  Askr.Core.Text, Askr.Signed, Askr.Http.Stream, Askr.Inertia, Askr.Auth;

function ValidChannel(const S: string): Boolean;
var
  I: Integer;
begin
  if S = '' then
    Exit(False);
  for I := 1 to Length(S) do
    if not (S[I] in ['A'..'Z', 'a'..'z', '0'..'9', '.', '_', ':', '-']) then
      Exit(False);
  Result := True;
end;

function ValidProp(const S: string): Boolean;
var
  I: Integer;
begin
  if S = '' then
    Exit(False);
  for I := 1 to Length(S) do
    if not (S[I] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) then
      Exit(False);
  Result := True;
end;

{ The user id as hex: any id at all, and nothing in it a query needs
  escaped. }
function UserKey(const UserId: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(UserId) do
    Result := Result + IntToHex(Ord(UserId[I]), 2);
end;

procedure LiveOn(const Channels: array of string);
var
  I: Integer;
  List: string;
begin
  if Length(Channels) = 0 then
    raise ELiveError.Create('LiveOn needs at least one channel');
  List := '';
  for I := 0 to High(Channels) do
  begin
    if not ValidChannel(Channels[I]) then
      raise ELiveError.CreateFmt('"%s" is not a channel name: letters, ' +
        'digits and . _ : - only', [Channels[I]]);
    if I > 0 then
      List := List + ',';
    List := List + Channels[I];
  end;
  InertiaLiveUrl(SignedPath(LivePath + '?channels=' + List + '&user=' +
    UserKey(Id), LiveLifetimeSeconds));
end;

procedure PropsChanged(const Channel: string; const Props: array of string);
var
  I: Integer;
  Data: string;
begin
  if not ValidChannel(Channel) then
    raise ELiveError.CreateFmt('"%s" is not a channel name: letters, ' +
      'digits and . _ : - only', [Channel]);
  if Length(Props) = 0 then
    raise ELiveError.Create('PropsChanged needs at least one prop');
  Data := '{"props":[';
  for I := 0 to High(Props) do
  begin
    { Checked, so the names go into the JSON as they are. }
    if not ValidProp(Props[I]) then
      raise ELiveError.CreateFmt('"%s" is not a prop name: letters, ' +
        'digits and _ only', [Props[I]]);
    if I > 0 then
      Data := Data + ',';
    Data := Data + '"' + Props[I] + '"';
  end;
  Data := Data + ']}';
  Broadcast(Channel, LiveEvent, Data);
end;

function SplitChannels(const List: string): TArray<string>;
var
  Rest: string;
  P: Integer;
begin
  Result := nil;
  Rest := List;
  while Rest <> '' do
  begin
    P := Pos(',', Rest);
    if P = 0 then
      P := Length(Rest) + 1;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Copy(Rest, 1, P - 1);
    Delete(Rest, 1, P);
  end;
end;

{ 403 for all of it -- changed, expired, someone else's. EventSource does
  not reconnect after a status other than 200, so a page whose URL has
  gone stale stops asking instead of asking every three seconds. }
{ The channels are not checked again here. Only LiveOn signs, and LiveOn
  refuses a bad name, so a URL whose signature holds has good ones -- a
  check here was a mutation that survived. }
function OpenLive(Req: TRequest): TResponse;
begin
  if CheckSignature(Req) <> scValid then
    Exit(ErrorResponse(403));
  if Req.Query('user').ToString <> UserKey(Id) then
    Exit(ErrorResponse(403));
  Result := StreamEvents(SplitChannels(Req.Query('channels').ToString));
end;

procedure UseLive(R: TRouter);
begin
  R.Get(LivePath, OpenLive);
end;

end.
