{ Askr.Session — sessions in the same process.

  This closes the gap from step 5. The PRD writes

      Exit(Back.WithErrors(C.Errors));
      Redirect('/customers').With('flash', 'Customer created');

  and both assume something survives a redirect. Without sessions it did
  not, and validation had to re-render the page instead.

  The store lives in the process, like the queue and the cache. That is a
  deliberate limit and not an oversight: one binary, no sidecar. If the
  app scales to several nodes the store has to be replaced — the interface
  is separated out so that is one class, not a pervasive change.

  Flash has the classic semantics: what is written in one request can be
  read in the next, and is gone after that. That is why there are two maps
  and not one — what can be read now, and what is being written for next
  time.

  The session object is an arena object. The values are copied into the
  store at Commit and out into the arena at Start, the same boundary as in
  the cache and for the same reason. }
unit Askr.Session;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Clock, Askr.Core.Json,
  Askr.Core.Crypto,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response, Askr.Http.Router;

type
  ESessionError = class(Exception);

  TSessionPair = record
    Key: string;
    Value: string;
  end;

  { The session as a request sees it. Lives in the request arena. }
  TSession = class(TArenaObject)
  private
    FId: string;
    FData: array of TSessionPair;
    FFlashIn: array of TSessionPair;    { readable now }
    FFlashOut: array of TSessionPair;   { written for next request }
    FDirty: Boolean;
    FNew: Boolean;
    function IndexIn(const Arr: array of TSessionPair;
      const Key: string): Integer;
  public
    function Get(const Key: string; const Default: string = ''): string;
    function Has(const Key: string): Boolean;
    procedure Put(const Key, Value: string);
    procedure Forget(const Key: string);
    procedure Clear;

    { Readable in the next request, then gone. }
    procedure Flash(const Key, Value: string);
    function GetFlash(const Key: string; const Default: string = ''): string;
    function HasFlash(const Key: string): Boolean;
    { Whether there is any readable flash at all. The validation errors do
      not count — they are their own prop in the Inertia payload, not a
      message, and HasErrors answers for them. }
    function HasAnyFlash: Boolean;
    { Keeps what came in, so it is there next time as well. }
    procedure Reflash;

    { Validation errors as JSON, stored as flash. This is what makes
      Back.WithErrors possible. }
    procedure FlashErrorsJson(const Json: TStr);
    function ErrorsJson: string;
    function HasErrors: Boolean;

    { Writes the flash pairs into an object that is already open. }
    procedure WriteFlashInto(var W: TJsonWriter);

    property Id: string read FId;
    property IsNew: Boolean read FNew;
    property Dirty: Boolean read FDirty;
  end;

  TSessionStore = class
  private
    FLock: TCriticalSection;
    FKeys: TStringList;          { id -> indeks i FSlots }
    FSlots: array of record
      Id: string;
      Data: array of TSessionPair;
      Flash: array of TSessionPair;
      ExpiresAt: Int64;
      InUse: Boolean;
    end;
    FFree: array of Integer;
    FLifetime: Integer;
    FCookieName: string;
    FSecure: Boolean;
    FCreated, FResumed, FExpired: QWord;
    procedure Sweep;
    function SlotFor(const Id: string): Integer;
  public
    constructor Create(ALifetimeSeconds: Integer = 7200);
    destructor Destroy; override;

    { Reads the session cookie and fetches the state into the arena.
      Creates a new session when the cookie is missing or expired. }
    function Start(Req: TRequest): TSession;
    { Writes the state back and sets the cookie on the response. Rotates
      the flash: what was read is gone, what was written becomes
      readable. }
    procedure Commit(S: TSession; Res: TResponse);

    { Gives the session a new id and throws the old one away. The data
      comes along.

      This has to happen at sign-in. Otherwise: an attacker sets your
      cookie to an id he knows *before* you sign in, you sign in to that
      very session, and he is signed in as you. It is called session
      fixation, and the only thing that stops it is the id changing at the
      moment the privileges do. }
    procedure Regenerate(S: TSession);

    procedure Destroy_(const Id: string);
    function Count: Integer;

    property CookieName: string read FCookieName write FCookieName;
    { Set this when the app runs behind HTTPS. }
    property Secure: Boolean read FSecure write FSecure;
    property Lifetime: Integer read FLifetime write FLifetime;
    property Created: QWord read FCreated;
    property Resumed: QWord read FResumed;
    property Expired: QWord read FExpired;
  end;

function Sessions: TSessionStore;
procedure SetSessions(AStore: TSessionStore);

{ Wires the sessions onto the router: starts the session before
  middleware and writes it back after the response is made.

  Before this, every app had to call Start, UseSession and Commit by hand
  around each request, and if you forgot Commit nothing was saved — with
  no error anywhere. Requires SetSessions to have been called first. }
procedure UseSessions(R: TRouter);

{ The ambient session for the current thread, following the same pattern
  as UseArena, UseDb and UseRequest. The host sets it after Start and
  clears it after Commit. }
function CurrentSession: TSession;
function UseSession(S: TSession): TSession;

{ One named cookie out of the Cookie header. It lives here because the
  session needs it first; Askr.Auth uses the same one for the "remember
  me" cookie, and two parsers of the same header would sooner or later
  disagree. }
function CookieValue(Req: TRequest; const Name_: string): string;

{ The key validation errors are stored under. }
const
  ErrorsFlashKey = '_errors';

implementation

threadvar
  GCurrent: TSession;

var
  GStore: TSessionStore = nil;

function CurrentSession: TSession;
begin
  Result := GCurrent;
end;

function UseSession(S: TSession): TSession;
begin
  Result := GCurrent;
  GCurrent := S;
end;

function Sessions: TSessionStore;
begin
  if GStore = nil then
    raise ESessionError.Create(
      'No session store is configured. Call SetSessions at startup.');
  Result := GStore;
end;

procedure SetSessions(AStore: TSessionStore);
begin
  GStore := AStore;
end;

{ 128 random bits from the kernel, hex encoded. A session id that can be
  guessed is not a session id.

  The randomness comes from Askr.Core.Crypto, not from a separate urandom
  read here. There is one thing in the framework that talks to the
  kernel's CSPRNG, and it has the tests. }
function NewSessionId: string;
begin
  Result := RandomHex(16);
end;

function CookieValue(Req: TRequest; const Name_: string): string;
var
  H, Rest, Item, K, V: TStr;
begin
  Result := '';
  H := Req.Header('cookie');
  Rest := H;
  while Rest.Len > 0 do
  begin
    Rest.SplitAt(Ord(';'), Item, Rest);
    Item := Item.TrimSpace;
    if Item.Len = 0 then
      Continue;
    if not Item.SplitAt(Ord('='), K, V) then
      Continue;
    if K.TrimSpace.EqualsStr(Name_) then
      Exit(V.TrimSpace.ToString);
  end;
end;

{ TSession }

function TSession.IndexIn(const Arr: array of TSessionPair;
  const Key: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(Arr) do
    if Arr[I].Key = Key then
      Exit(I);
  Result := -1;
end;

function TSession.Get(const Key, Default: string): string;
var
  I: Integer;
begin
  I := IndexIn(FData, Key);
  if I < 0 then
    Exit(Default);
  Result := FData[I].Value;
end;

function TSession.Has(const Key: string): Boolean;
begin
  Result := IndexIn(FData, Key) >= 0;
end;

procedure TSession.Put(const Key, Value: string);
var
  I, N: Integer;
begin
  I := IndexIn(FData, Key);
  if I >= 0 then
    FData[I].Value := Value
  else
  begin
    N := Length(FData);
    SetLength(FData, N + 1);
    FData[N].Key := Key;
    FData[N].Value := Value;
  end;
  FDirty := True;
end;

procedure TSession.Forget(const Key: string);
var
  I, J: Integer;
begin
  I := IndexIn(FData, Key);
  if I < 0 then
    Exit;
  for J := I to High(FData) - 1 do
    FData[J] := FData[J + 1];
  SetLength(FData, Length(FData) - 1);
  FDirty := True;
end;

procedure TSession.Clear;
begin
  SetLength(FData, 0);
  SetLength(FFlashOut, 0);
  FDirty := True;
end;

procedure TSession.Flash(const Key, Value: string);
var
  I, N: Integer;
begin
  I := IndexIn(FFlashOut, Key);
  if I >= 0 then
    FFlashOut[I].Value := Value
  else
  begin
    N := Length(FFlashOut);
    SetLength(FFlashOut, N + 1);
    FFlashOut[N].Key := Key;
    FFlashOut[N].Value := Value;
  end;
  FDirty := True;
end;

function TSession.GetFlash(const Key, Default: string): string;
var
  I: Integer;
begin
  I := IndexIn(FFlashIn, Key);
  if I < 0 then
    Exit(Default);
  Result := FFlashIn[I].Value;
end;

function TSession.HasFlash(const Key: string): Boolean;
begin
  Result := IndexIn(FFlashIn, Key) >= 0;
end;

function TSession.HasAnyFlash: Boolean;
var
  I: Integer;
begin
  { The same selection WriteFlashInto writes. If the two drift apart, the
    guard ends up saying no to something that would have been written. }
  for I := 0 to High(FFlashIn) do
    if FFlashIn[I].Key <> ErrorsFlashKey then
      Exit(True);
  Result := False;
end;

procedure TSession.Reflash;
var
  I: Integer;
begin
  for I := 0 to High(FFlashIn) do
    Flash(FFlashIn[I].Key, FFlashIn[I].Value);
end;

procedure TSession.FlashErrorsJson(const Json: TStr);
begin
  Flash(ErrorsFlashKey, Json.ToString);
end;

function TSession.ErrorsJson: string;
begin
  Result := GetFlash(ErrorsFlashKey, '');
end;

function TSession.HasErrors: Boolean;
begin
  Result := HasFlash(ErrorsFlashKey) and (ErrorsJson <> '') and
    (ErrorsJson <> '{}');
end;

procedure TSession.WriteFlashInto(var W: TJsonWriter);
var
  I: Integer;
begin
  for I := 0 to High(FFlashIn) do
    { Feilene er en egen prop i Inertia-payloaden, ikke en flash-melding. }
    if FFlashIn[I].Key <> ErrorsFlashKey then
      W.Field(FFlashIn[I].Key, FFlashIn[I].Value);
end;

{ TSessionStore }

constructor TSessionStore.Create(ALifetimeSeconds: Integer);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FKeys := TStringList.Create;
  FKeys.Sorted := True;
  FKeys.Duplicates := dupIgnore;
  FLifetime := ALifetimeSeconds;
  FCookieName := 'askr_session';
end;

destructor TSessionStore.Destroy;
begin
  FKeys.Free;
  FLock.Free;
  inherited Destroy;
end;

function TSessionStore.SlotFor(const Id: string): Integer;
var
  I: Integer;
begin
  I := FKeys.IndexOf(Id);
  if I < 0 then
    Exit(-1);
  Result := PtrInt(FKeys.Objects[I]);
end;

procedure TSessionStore.Sweep;
var
  I, Slot: Integer;
  Now_: Int64;
begin
  Now_ := UnixNow;
  I := 0;
  while I < FKeys.Count do
  begin
    Slot := PtrInt(FKeys.Objects[I]);
    if FSlots[Slot].ExpiresAt <= Now_ then
    begin
      FSlots[Slot].InUse := False;
      SetLength(FSlots[Slot].Data, 0);
      SetLength(FSlots[Slot].Flash, 0);
      FSlots[Slot].Id := '';
      SetLength(FFree, Length(FFree) + 1);
      FFree[High(FFree)] := Slot;
      FKeys.Delete(I);
      Inc(FExpired);
    end
    else
      Inc(I);
  end;
end;

function TSessionStore.Start(Req: TRequest): TSession;
var
  Id: string;
  Slot, I: Integer;
  Prev: TArena;
begin
  Prev := UseArena(Req.Arena);
  try
    Result := TSession.Create;
  finally
    UseArena(Prev);
  end;

  Id := CookieValue(Req, FCookieName);

  FLock.Acquire;
  try
    { Sweeping here, not in a thread of its own: a session store that needs
      its own thread to tidy up is more machinery than the problem
      deserves. }
    if (FKeys.Count > 0) and (Random(64) = 0) then
      Sweep;

    Slot := -1;
    if Length(Id) = 32 then
      Slot := SlotFor(Id);

    if (Slot >= 0) and (FSlots[Slot].ExpiresAt > UnixNow) then
    begin
      Result.FId := Id;
      Result.FNew := False;
      { Kopieres ut i request-arenaen. Lageret beholder sitt eget. }
      SetLength(Result.FData, Length(FSlots[Slot].Data));
      for I := 0 to High(FSlots[Slot].Data) do
        Result.FData[I] := FSlots[Slot].Data[I];
      SetLength(Result.FFlashIn, Length(FSlots[Slot].Flash));
      for I := 0 to High(FSlots[Slot].Flash) do
        Result.FFlashIn[I] := FSlots[Slot].Flash[I];
      Inc(FResumed);
    end
    else
    begin
      Result.FId := NewSessionId;
      Result.FNew := True;
      Inc(FCreated);
    end;
  finally
    FLock.Release;
  end;
end;

procedure TSessionStore.Commit(S: TSession; Res: TResponse);
var
  Slot, I: Integer;
begin
  if S = nil then
    Exit;

  FLock.Acquire;
  try
    Slot := SlotFor(S.Id);
    if Slot < 0 then
    begin
      if Length(FFree) > 0 then
      begin
        Slot := FFree[High(FFree)];
        SetLength(FFree, Length(FFree) - 1);
      end
      else
      begin
        Slot := Length(FSlots);
        SetLength(FSlots, Slot + 1);
      end;
      FSlots[Slot].Id := S.Id;
      FSlots[Slot].InUse := True;
      FKeys.AddObject(S.Id, TObject(PtrInt(Slot)));
    end;

    SetLength(FSlots[Slot].Data, Length(S.FData));
    for I := 0 to High(S.FData) do
      FSlots[Slot].Data[I] := S.FData[I];

    { The flash rotates: what was read this time is gone, what was written
      becomes readable next time. }
    SetLength(FSlots[Slot].Flash, Length(S.FFlashOut));
    for I := 0 to High(S.FFlashOut) do
      FSlots[Slot].Flash[I] := S.FFlashOut[I];

    FSlots[Slot].ExpiresAt := UnixNow + FLifetime;
  finally
    FLock.Release;
  end;

  { WithCookie, not WithHeader: the latter lets the last value win per
    header name, and then the CSRF cookie and the session cookie would
    cancel each other out. HttpOnly and SameSite=Lax are the defaults
    because the alternative is remembering them. Secure is set by the app
    when it knows it is behind HTTPS. }
  Res.WithCookie(FCookieName, S.Id, FLifetime, FSecure);
end;

procedure TSessionStore.Regenerate(S: TSession);
var
  Old: string;
begin
  if S = nil then
    Exit;
  Old := S.FId;
  S.FId := NewSessionId;
  S.FNew := True;
  S.FDirty := True;
  { The old slot is deleted, not merely abandoned. An id that still works
    after being replaced is exactly the attack we are stopping. }
  if Old <> '' then
    Destroy_(Old);
end;

procedure TSessionStore.Destroy_(const Id: string);
var
  Slot, I: Integer;
begin
  FLock.Acquire;
  try
    Slot := SlotFor(Id);
    if Slot < 0 then
      Exit;
    FSlots[Slot].InUse := False;
    SetLength(FSlots[Slot].Data, 0);
    SetLength(FSlots[Slot].Flash, 0);
    FSlots[Slot].Id := '';
    SetLength(FFree, Length(FFree) + 1);
    FFree[High(FFree)] := Slot;
    I := FKeys.IndexOf(Id);
    if I >= 0 then
      FKeys.Delete(I);
  finally
    FLock.Release;
  end;
end;

function TSessionStore.Count: Integer;
begin
  FLock.Acquire;
  try
    Result := FKeys.Count;
  finally
    FLock.Release;
  end;
end;

type
  { Middleware are function pointers, and Pascal has no closures. The
    store is therefore fetched from Sessions rather than from a captured
    variable. }
  TSessionHook = class
    class function Start(Req: TRequest): TResponse;
    class function Commit(Req: TRequest; Res: TResponse): TResponse;
  end;

class function TSessionHook.Start(Req: TRequest): TResponse;
begin
  UseSession(Sessions.Start(Req));
  { nil betyr «fortsett» — sesjonen er ikke et svar. }
  Result := nil;
end;

class function TSessionHook.Commit(Req: TRequest; Res: TResponse): TResponse;
var
  S: TSession;
begin
  Result := Res;
  S := CurrentSession;

  { The threadvar is cleared FIRST, not last.

    The session lives in the request arena and goes away at Reset; the
    threadvar does not. With the cleanup at the bottom, two exits slipped
    past it — and one of them is entirely ordinary: an anonymous visitor
    who starts a session without writing to it. The next request on that
    worker then got a pointer into memory the arena had reused.

    That bug showed up as an EAccessViolation when a browser fetched a CSS
    file right after a page on the same connection — and only when the
    file fitted in the block that was already in use. A large file got a
    new block, the old memory lay untouched, and the same bug went
    silently past. }
  UseSession(nil);

  if S = nil then
    Exit;
  { A new session nobody wrote to is not stored and gets no cookie.
    Without this, every anonymous visitor — every robot, every health
    check — would get a slot in the store and a cookie to send back. The
    store lives in the process, so that is memory growing with traffic
    rather than with users.

    Sessions.Commit called directly still does as it is told. It is only
    the automatic path that holds back. }
  if S.IsNew and not S.Dirty then
    Exit;
  Sessions.Commit(S, Res);
end;

procedure UseSessions(R: TRouter);
begin
  { Sessions raises by itself if no store is set. The call is here so the
    error comes at startup rather than at the first request. }
  Sessions;
  R.Use(TSessionHook.Start);
  R.After(TSessionHook.Commit);
end;

initialization
  Randomize;


end.
