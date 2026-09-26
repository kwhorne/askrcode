{ Askr.Events — something happened, and whoever cares hears of it.

      type
        TUserRegistered = class(TEvent)
        private
          FUserId: Int64;
          FEmail: string;
        published
          property UserId: Int64 read FUserId write FUserId;
          property Email: string read FEmail write FEmail;
        end;

      Listen(TUserRegistered, @AddToNewsletter);
      ListenQueued(Queue, TUserRegistered, 'welcome-mail', @SendWelcome);
      ...
      E := TUserRegistered.Create;
      E.UserId := U.Id;
      E.Email := U.Email;
      DispatchEvent(E);

  The code that registers a user does not need to know that a newsletter
  and a welcome mail follow. They listen; it says what happened.

  **A listener runs where it is told to.** Listen runs it now, in the
  dispatching code, before DispatchEvent returns -- and an exception from
  it comes out of DispatchEvent, because a listener that failed quietly is
  a welcome mail nobody knows was never sent. ListenQueued runs it in the
  queue instead: the event crosses as JSON, is built again in the worker,
  and gets the queue's retries and its failed table. What should not hold
  up a request, or should survive a failure, goes there.

  **What crosses the queue is the published properties**: strings,
  integers, booleans, enumerations, Currency, floats and TDateTime.
  ListenQueued refuses a class with anything else published and names the
  property -- an object or a list would arrive empty, and nothing would say
  so. Keep ids, not objects: a model loaded in the request is not the row
  the worker sees a second later.

  **DispatchEvent owns the event** and frees it when every listener has
  had it.

  Listeners are registered at startup, before the server takes requests;
  the lists are read by every worker without a lock. Named DispatchEvent,
  not Dispatch: inside a class that is TObject.Dispatch. }
unit Askr.Events;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Askr.Queue;

type
  EEventError = class(Exception);

  {$M+}
  TEvent = class
  public
    { Virtual, so a queued listener's worker can build the event from its
      class alone. }
    constructor Create; virtual;
  end;
  {$M-}

  TEventClass = class of TEvent;
  TListener = procedure(E: TEvent);

{ L hears every event of AClass and of its subclasses, now, in the order
  the listeners were registered. }
procedure Listen(AClass: TEventClass; L: TListener);
{ L hears them in Q's workers instead, under Name, which is the job's name
  and has to be unique. Raises when AClass has a published property that
  cannot cross the queue. }
procedure ListenQueued(Q: TQueue; AClass: TEventClass; const Name: string;
  L: TListener);
{ Tells every listener, then frees E. }
procedure DispatchEvent(E: TEvent);
{ Makes AClass known by name to this process's queue workers. A queued
  listener gets the class that was dispatched -- a subclass with its own
  fields, too -- and has to find it by name. The class a listener asks for
  and every class dispatched here are known already; with a durable queue a
  job can reach another process of the same binary that never dispatched
  it, so register there, at startup, what may arrive. }
procedure RegisterEvent(AClass: TEventClass);

{ The published properties as JSON, and back. Exposed for a test, and for
  anything else that has to carry an event. }
function EventToJson(E: TEvent): string;
function EventFromJson(AClass: TEventClass; const Json: string): TEvent;

{ Forgets every listener. For tests. }
procedure ClearListeners;

implementation

uses
  TypInfo, Askr.Core.Arena, Askr.Core.Text, Askr.Core.Json;

type
  TListenerEntry = record
    EventClass: TEventClass;
    Listener: TListener;
    { Empty for one that runs now. }
    JobName: string;
    Queue: TQueue;
  end;

var
  GListeners: array of TListenerEntry;
  GKnown: array of TEventClass;

procedure RegisterEvent(AClass: TEventClass);
var
  I: Integer;
begin
  for I := 0 to High(GKnown) do
    if GKnown[I] = AClass then
      Exit
    else if SameText(GKnown[I].ClassName, AClass.ClassName) then
      raise EEventError.CreateFmt('Two event classes are called %s, and a queue ' +
        'finds a class by its name', [AClass.ClassName]);
  I := Length(GKnown);
  SetLength(GKnown, I + 1);
  GKnown[I] := AClass;
end;

function KnownEvent(const Name: string): TEventClass;
var
  I: Integer;
begin
  for I := 0 to High(GKnown) do
    if SameText(GKnown[I].ClassName, Name) then
      Exit(GKnown[I]);
  Result := nil;
end;

constructor TEvent.Create;
begin
  inherited Create;
end;

const
  JobPrefix = 'askr.event:';

function DotSettings: TFormatSettings;
begin
  Result := DefaultFormatSettings;
  Result.DecimalSeparator := '.';
  Result.ThousandSeparator := #0;
end;

function IsDateTime(P: PPropInfo): Boolean;
var
  N: string;
begin
  N := string(P^.PropType^.Name);
  Result := SameText(N, 'TDateTime') or SameText(N, 'TDate') or SameText(N, 'TTime');
end;

{ The first published property that cannot cross the queue, or ''. }
function Uncarried(AClass: TEventClass): string;
var
  Props: PPropList;
  N, I: Integer;
begin
  Result := '';
  N := GetPropList(AClass, Props);
  try
    for I := 0 to N - 1 do
      case Props^[I]^.PropType^.Kind of
        tkInteger, tkInt64, tkQWord, tkAString, tkUString, tkString, tkWString,
        tkBool, tkEnumeration, tkFloat: ;
      else
        Exit(string(Props^[I]^.Name));
      end;
  finally
    FreeMem(Props);
  end;
end;

{ A float as text that reads back as the same float. Not FloatToStrF: on
  aarch64, where Extended is Double, it stops at fifteen digits even when
  asked for seventeen, and 0.30000000000000004 came back as 0.3. System.Str
  -- Askr.Core.Text has a Str of its own -- writes
  every digit the type has, on both architectures, and StrToFloat reads it
  back exactly. }
function FloatText(E: TObject; P: PPropInfo): string;
var
  D: Double;
  S1: Single;
  X: Extended;
begin
  case GetTypeData(P^.PropType)^.FloatType of
    ftSingle:
      begin
        S1 := GetFloatProp(E, P);
        System.Str(S1, Result);
      end;
    ftDouble:
      begin
        D := GetFloatProp(E, P);
        System.Str(D, Result);
      end;
  else
    X := GetFloatProp(E, P);
    System.Str(X, Result);
  end;
  Result := Trim(Result);
end;

function JsonQuoted(const S: string): string;
var
  A: TArena;
  W: TJsonWriter;
begin
  A := TArena.Create(256);
  try
    W.Init(A, 64);
    W.Str(S);
    Result := W.ToString;
  finally
    A.Free;
  end;
end;

function EventToJson(E: TEvent): string;
var
  A: TArena;
  W: TJsonWriter;
  Props: PPropList;
  N, I: Integer;
  P: PPropInfo;
  C: Currency;
begin
  A := TArena.Create(4096);
  N := GetPropList(E, Props);
  try
    W.Init(A, 512);
    W.BeginObject;
    for I := 0 to N - 1 do
    begin
      P := Props^[I];
      W.Key(string(P^.Name));
      case P^.PropType^.Kind of
        tkInteger: W.Int(GetOrdProp(E, P));
        tkInt64, tkQWord: W.Int(GetInt64Prop(E, P));
        tkAString, tkUString, tkString, tkWString: W.Str(GetStrProp(E, P));
        tkBool: W.Bool(GetOrdProp(E, P) <> 0);
        tkEnumeration: W.Str(GetEnumProp(E, P));
        tkFloat:
          if GetTypeData(P^.PropType)^.FloatType = ftCurr then
          begin
            { Assigned, never cast: Currency is a scaled integer. }
            C := GetFloatProp(E, P);
            W.Str(CurrToStr(C, DotSettings));
          end
          else if IsDateTime(P) then
            W.Str(FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz', GetFloatProp(E, P)))
          else
            W.Str(FloatText(E, P));
      else
        raise EEventError.CreateFmt('%s.%s cannot be written as JSON',
          [E.ClassName, string(P^.Name)]);
      end;
    end;
    W.EndObject;
    Result := W.ToString;
  finally
    FreeMem(Props);
    A.Free;
  end;
end;

function EventFromJson(AClass: TEventClass; const Json: string): TEvent;
var
  A: TArena;
  Root, V: PJsonValue;
  ErrorAt: SizeInt;
  Props: PPropList;
  N, I: Integer;
  P: PPropInfo;
  S: string;
  C: Currency;
  D: TDateTime;
begin
  A := TArena.Create(4096);
  Props := nil;
  N := 0;
  Result := AClass.Create;
  try
    if not JsonParse(A, StrDup(A, Json), Root, ErrorAt) or (Root^.Kind <> jkObject) then
      raise EEventError.CreateFmt('A %s did not come as a JSON object', [AClass.ClassName]);
    N := GetPropList(Result, Props);
    for I := 0 to N - 1 do
    begin
      P := Props^[I];
      V := JsonMember(Root, string(P^.Name));
      { A property the sender did not have -- an event from before a
        deploy that added it -- keeps what the constructor gave it.
        JsonIsNull takes a missing member as null too. }
      if JsonIsNull(V) then
        Continue;
      case P^.PropType^.Kind of
        tkInteger: SetOrdProp(Result, P, JsonAsInt(V));
        tkInt64, tkQWord: SetInt64Prop(Result, P, JsonAsInt(V));
        tkAString, tkUString, tkString, tkWString: SetStrProp(Result, P, JsonAsString(V));
        tkBool: SetOrdProp(Result, P, Ord(JsonAsBool(V)));
        tkEnumeration: SetEnumProp(Result, P, JsonAsString(V));
        tkFloat:
          begin
            S := JsonAsString(V);
            if GetTypeData(P^.PropType)^.FloatType = ftCurr then
            begin
              C := StrToCurr(S, DotSettings);
              SetFloatProp(Result, P, C);
            end
            else if IsDateTime(P) then
            begin
              D := EncodeDate(StrToInt(Copy(S, 1, 4)), StrToInt(Copy(S, 6, 2)),
                     StrToInt(Copy(S, 9, 2))) +
                   EncodeTime(StrToInt(Copy(S, 12, 2)), StrToInt(Copy(S, 15, 2)),
                     StrToInt(Copy(S, 18, 2)), StrToInt(Copy(S, 21, 3)));
              SetFloatProp(Result, P, D);
            end
            else
              SetFloatProp(Result, P, StrToFloat(S, DotSettings));
          end;
      else
        raise EEventError.CreateFmt('%s.%s cannot be read from JSON',
          [AClass.ClassName, string(P^.Name)]);
      end;
    end;
  except
    FreeMem(Props);
    Props := nil;
    Result.Free;
    A.Free;
    raise;
  end;
  FreeMem(Props);
  A.Free;
end;

procedure Listen(AClass: TEventClass; L: TListener);
var
  I: Integer;
begin
  I := Length(GListeners);
  SetLength(GListeners, I + 1);
  GListeners[I].EventClass := AClass;
  GListeners[I].Listener := L;
  GListeners[I].JobName := '';
  GListeners[I].Queue := nil;
end;

{ The worker's side of a queued listener: the event built again from the
  job, and the listener that asked for it. }
procedure RunQueued(const Ctx: TJobContext);
var
  I: Integer;
  E: TEvent;
  A: TArena;
  Root: PJsonValue;
  ErrorAt: SizeInt;
  ClassName_, Data: string;
  Cls: TEventClass;
begin
  A := TArena.Create(4096);
  try
    if not JsonParse(A, Ctx.Payload, Root, ErrorAt) or (Root^.Kind <> jkObject) then
      raise EEventError.CreateFmt('The job for %s is not an event', [Ctx.Name]);
    ClassName_ := JsonAsString(JsonMember(Root, 'event'));
    Data := JsonToString(A, JsonMember(Root, 'data'));
  finally
    A.Free;
  end;
  Cls := KnownEvent(ClassName_);
  if Cls = nil then
    raise EEventError.CreateFmt('%s is not an event this process knows. Call ' +
      'RegisterEvent(%s) at startup, where the queue''s workers run.',
      [ClassName_, ClassName_]);
  for I := 0 to High(GListeners) do
    if GListeners[I].JobName = Ctx.Name then
    begin
      E := EventFromJson(Cls, Data);
      try
        GListeners[I].Listener(E);
      finally
        E.Free;
      end;
      Exit;
    end;
  { A job for a listener that is gone -- renamed in a deploy while the job
    waited. It fails, and the failed table says so, rather than being taken
    as done. }
  raise EEventError.CreateFmt('No listener is registered as %s', [Ctx.Name]);
end;

procedure ListenQueued(Q: TQueue; AClass: TEventClass; const Name: string;
  L: TListener);
var
  I: Integer;
  Bad: string;
begin
  if Q = nil then
    raise EEventError.CreateFmt('ListenQueued for %s needs a queue', [Name]);
  if Name = '' then
    raise EEventError.Create('A queued listener needs a name: it is the job''s');
  for I := 0 to High(GListeners) do
    if GListeners[I].JobName = JobPrefix + Name then
      raise EEventError.CreateFmt('A queued listener is already registered as %s', [Name]);
  Bad := Uncarried(AClass);
  if Bad <> '' then
    raise EEventError.CreateFmt('%s.%s cannot cross the queue: only strings, ' +
      'numbers, booleans, enumerations and dates can. Carry an id instead.',
      [AClass.ClassName, Bad]);
  I := Length(GListeners);
  SetLength(GListeners, I + 1);
  GListeners[I].EventClass := AClass;
  GListeners[I].Listener := L;
  GListeners[I].JobName := JobPrefix + Name;
  GListeners[I].Queue := Q;
  RegisterEvent(AClass);
  Q.Handle(JobPrefix + Name, RunQueued);
end;

procedure DispatchEvent(E: TEvent);
var
  I: Integer;
  Json: string;
begin
  if E = nil then
    Exit;
  try
    Json := '';
    for I := 0 to High(GListeners) do
      if E.InheritsFrom(GListeners[I].EventClass) then
      begin
        if GListeners[I].JobName = '' then
          GListeners[I].Listener(E)
        else
        begin
          { Written once, the first time a queued listener needs it, and
            after the listeners before it have run -- one of them may have
            filled in a field. }
          if Json = '' then
          begin
            RegisterEvent(TEventClass(E.ClassType));
            Json := '{"event":' + JsonQuoted(E.ClassName) + ',"data":' + EventToJson(E) + '}';
          end;
          GListeners[I].Queue.Push(GListeners[I].JobName, Json);
        end;
      end;
  finally
    E.Free;
  end;
end;

procedure ClearListeners;
begin
  GListeners := nil;
  GKnown := nil;
end;

end.
