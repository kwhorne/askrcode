{ Askr.Ai — Claude as part of the framework.

  There is no official Pascal SDK, so this is raw HTTP against
  `POST /v1/messages`. The protocol is documented and stable; what we own
  ourselves is the serialization, and `Askr.Core.Json` is good for both
  directions.

  **The default model is `claude-opus-5`.** Not because it is the
  cheapest, but because the choice of model is the app's decision and not
  the framework's. `claude-sonnet-5` and `claude-haiku-4-5` are there for
  anyone who wants to come down in price.

  **Thinking is set as `adaptive`, never with `budget_tokens`.** The old
  form is deprecated on the 4.6 models and is **rejected with a 400** on
  Opus 5, Sonnet 5 and Fable 5. It is a trap precisely because the old
  form is the one you remember.

  **The key comes from the environment, never from the source code**, and
  is not logged. The same rule as the rest of the `.env` layer.

  Four things in order, the way LARAVEL.md sets them up: text generation,
  streaming, tool calls, structured output. Embeddings and vector search
  are not here — they come after those four, and they need `pgvector`,
  which SQLite does not have.

  ## What has NOT been tried

  **No call to the real API has been made from this repository.** There is
  no API key here. The shape of the request is built from the
  documentation and tested against a fake that holds the JSON up against
  what it is supposed to be, and the one thing that *has* been tried
  against api.anthropic.com is that TLS, DNS and the error handling work —
  a call without a key that comes back as a real 401 with Anthropic's own
  error JSON.

  That is the same caveat as the one on the Windows shell, and it stays
  until somebody has run it with a key. }
unit Askr.Ai;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Json, Askr.Core.Config,
  Askr.Core.Log,
  Askr.Http.Client;

const
  { The newest and most capable. Swapped with the Model property. }
  DefaultAiModel = 'claude-opus-5';
  AnthropicVersion = '2023-06-01';
  DefaultAiBaseUrl = 'https://api.anthropic.com';
  DefaultAiMaxTokens = 4096;
  { A tool loop that never ends is either a bug in the tools or a model
    that has gone in circles. The cap is a stop. }
  DefaultAiMaxTurns = 8;

type
  EAiError = class(Exception)
  private
    FStatus: Integer;
    FKind: string;
  public
    constructor Create(AStatus: Integer; const AKind, AMessage: string);
    { The HTTP status. 0 when the error did not come from the server. }
    property Status: Integer read FStatus;
    { Anthropic's own error type: invalid_request_error, rate_limit_error,
      overloaded_error and the rest. Empty when the reply was not an error
      JSON. }
    property Kind: string read FKind;
  end;

  TAiRole = (arUser, arAssistant);
  { adaptive lets the model decide for itself how much it thinks. The old
    form with budget_tokens is rejected with a 400 by the models here. }
  TAiThinking = (atOff, atAdaptive);

  TAiMessage = record
    Role: TAiRole;
    Text: string;
    { Set when the message is the answer to a tool call. }
    ToolUseId: string;
    IsToolResult: Boolean;
    IsError: Boolean;
  end;

  TAiToolCall = record
    Id: string;
    Name: string;
    { The arguments as JSON, the way the model sent them. }
    InputJson: string;
  end;

  TAiUsage = record
    InputTokens: Int64;
    OutputTokens: Int64;
  end;

  TAiResponse = record
    Text: string;
    { The thinking, when it is switched on and the model shows it. }
    Thinking: string;
    StopReason: string;
    Model: string;
    Usage: TAiUsage;
    ToolCalls: array of TAiToolCall;
    { The whole reply, for what the API gives that we have not picked
      out. }
    Raw: string;
    function WantsTool: Boolean;
    function ToolCallCount: Integer;
  end;

  { A tool the model can call. The handler gets the arguments as JSON and
    gives the result back as text — the model reads it as text either way,
    and demanding JSON out would have been a rule without a reason. }
  TAiToolHandler = function(const InputJson: string): string of object;
  TAiToolHandlerProc = function(const InputJson: string): string;

  TAiTool = record
    Name: string;
    Description: string;
    { The `input_schema` object, raw. A JSON Schema of type object. }
    SchemaJson: string;
    Handler: TAiToolHandler;
    HandlerProc: TAiToolHandlerProc;
  end;

  { Called for every chunk of text that arrives. False aborts the
    stream. }
  TAiDeltaCallback = function(const Delta: string): Boolean of object;
  TAiDeltaCallbackProc = function(const Delta: string): Boolean;

  { How the request gets out. It exists as its own type so that tests can
    avoid the network — the same move as TNullTransport in Askr.Mail. }
  TAiTransport = class abstract
  public
    function Post(const Url, ApiKey, Body: string;
      out Status: Integer): string; virtual; abstract;
    function PostStream(const Url, ApiKey, Body: string;
      Cb: TStreamCallback; out Status: Integer): string; virtual; abstract;
  end;

  THttpAiTransport = class(TAiTransport)
  private
    FTimeoutMs: Integer;
  public
    constructor Create(ATimeoutMs: Integer = 120000);
    function Post(const Url, ApiKey, Body: string;
      out Status: Integer): string; override;
    function PostStream(const Url, ApiKey, Body: string;
      Cb: TStreamCallback; out Status: Integer): string; override;
  end;

  { For tests. The replies are put in beforehand; the requests are kept so
    that a test can assert what was actually sent. }
  TFakeAiTransport = class(TAiTransport)
  private
    FReplies: array of string;
    FStatuses: array of Integer;
    FNext: Integer;
    FRequests: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Enqueue(const Body: string; Status: Integer = 200);
    { An SSE stream: the text is delivered as it is, in one chunk. }
    procedure EnqueueStream(const SseBody: string);
    function Post(const Url, ApiKey, Body: string;
      out Status: Integer): string; override;
    function PostStream(const Url, ApiKey, Body: string;
      Cb: TStreamCallback; out Status: Integer): string; override;
    { The JSON that was sent, in order. }
    property Sent: TStringList read FRequests;
  end;

  TAiClient = class
  private
    FApiKey: string;
    FBaseUrl: string;
    FModel: string;
    FSystem: string;
    FMaxTokens: Integer;
    FTemperature: Double;
    FHasTemperature: Boolean;
    FThinking: TAiThinking;
    FTools: array of TAiTool;
    FTransport: TAiTransport;
    FOwnsTransport: Boolean;
    FMaxTurns: Integer;
    FDelta: TAiDeltaCallback;
    FDeltaProc: TAiDeltaCallbackProc;
    FSseRest: string;
    FStreamText: string;
    FStreamStop: string;
    FStreamUsage: TAiUsage;
    function BuildBody(const Messages: array of TAiMessage;
      Streaming: Boolean; const ForceTool: string): string;
    function ParseResponse(const Json: string): TAiResponse;
    procedure RaiseFor(Status: Integer; const Body: string);
    function OnChunk(const Chunk: string): Boolean;
    procedure HandleSseLine(const Line: string);
    function RunTool(const Call: TAiToolCall): string;
    function SendForcing(const Messages: array of TAiMessage;
      const ForceTool: string): TAiResponse;
  public
    { The key from ANTHROPIC_API_KEY, through the configuration layer.
      Raises when it is missing — the message names the key, never a
      value. }
    constructor Create; overload;
    constructor Create(const AApiKey: string); overload;
    destructor Destroy; override;

    { The simplest call there is. }
    function Ask(const Prompt: string): string;
    { Én runde med hele meldingslista. }
    function Send(const Messages: array of TAiMessage): TAiResponse;

    { Streams the reply. The callback gets the chunks of text as they
      arrive; the reply that is returned has the whole text collected, so
      both are there. }
    function Stream(const Prompt: string;
      Cb: TAiDeltaCallback): TAiResponse; overload;
    function Stream(const Prompt: string;
      Cb: TAiDeltaCallbackProc): TAiResponse; overload;
    function StreamMessages(const Messages: array of TAiMessage;
      Cb: TAiDeltaCallbackProc): TAiResponse;

    { Tools. The name has to be the same as in the schema. }
    procedure AddTool(const Name_, Description, SchemaJson: string;
      H: TAiToolHandler); overload;
    procedure AddTool(const Name_, Description, SchemaJson: string;
      H: TAiToolHandlerProc); overload;
    procedure ClearTools;
    function ToolCount: Integer;

    { Runs the loop: send, run the tools the model asked for, send the
      results back, repeat. Stops when the model is finished or MaxTurns
      is used up. }
    function RunTools(const Prompt: string): TAiResponse;

    { Structured output through a tool the model is forced to use.

      That is the shape that works across models and that cannot answer
      with prose alongside it. The result is JSON that follows the schema.
      The schema is the `input_schema` object, that is, a JSON Schema of
      type object. }
    function Structured(const Prompt, SchemaJson: string): string;

    property Model: string read FModel write FModel;
    property System_: string read FSystem write FSystem;
    property MaxTokens: Integer read FMaxTokens write FMaxTokens;
    property Thinking: TAiThinking read FThinking write FThinking;
    property MaxTurns: Integer read FMaxTurns write FMaxTurns;
    property BaseUrl: string read FBaseUrl write FBaseUrl;
    { If it is not set, no temperature is sent and the API uses its own. }
    procedure SetTemperature(V: Double);
    procedure ClearTemperature;
    { Byttes ut i tester. Klienten overtar eierskapet. }
    procedure UseTransport(T: TAiTransport; Owns: Boolean = True);
  end;

{ Helpers for building message lists. }
function UserMsg(const Text: string): TAiMessage;
function AssistantMsg(const Text: string): TAiMessage;
function ToolResultMsg(const ToolUseId, Result_: string;
  IsError: Boolean = False): TAiMessage;

implementation

{ --------------------------------------------------------------- feil -- }

constructor EAiError.Create(AStatus: Integer; const AKind, AMessage: string);
begin
  inherited Create(AMessage);
  FStatus := AStatus;
  FKind := AKind;
end;

{ ----------------------------------------------------------- meldinger -- }

function UserMsg(const Text: string): TAiMessage;
begin
  Result.Role := arUser;
  Result.Text := Text;
  Result.ToolUseId := '';
  Result.IsToolResult := False;
  Result.IsError := False;
end;

function AssistantMsg(const Text: string): TAiMessage;
begin
  Result := UserMsg(Text);
  Result.Role := arAssistant;
end;

function ToolResultMsg(const ToolUseId, Result_: string;
  IsError: Boolean): TAiMessage;
begin
  { A tool result is a user message with a tool_result block. That is not
    obvious, and it is the most common mistake when you build the loop
    yourself. }
  Result := UserMsg(Result_);
  Result.ToolUseId := ToolUseId;
  Result.IsToolResult := True;
  Result.IsError := IsError;
end;

{ ---------------------------------------------------------- TAiResponse -- }

function TAiResponse.WantsTool: Boolean;
begin
  Result := Length(ToolCalls) > 0;
end;

function TAiResponse.ToolCallCount: Integer;
begin
  Result := Length(ToolCalls);
end;

{ --------------------------------------------------------- transporter -- }

constructor THttpAiTransport.Create(ATimeoutMs: Integer);
begin
  inherited Create;
  FTimeoutMs := ATimeoutMs;
end;

function LagKlient(const ApiKey: string; TimeoutMs: Integer): THttpClient;
begin
  Result := THttpClient.Create;
  Result.ReadTimeoutMs := TimeoutMs;
  { x-api-key, not Authorization: Bearer. Anthropic uses its own header,
    and a Bearer token here gives a 401 with no explanation. }
  Result.WithHeader('x-api-key', ApiKey);
  Result.WithHeader('anthropic-version', AnthropicVersion);
  Result.WithHeader('content-type', 'application/json');
end;

function THttpAiTransport.Post(const Url, ApiKey, Body: string;
  out Status: Integer): string;
var
  K: THttpClient;
  R: THttpResponse;
begin
  K := LagKlient(ApiKey, FTimeoutMs);
  try
    R := K.Post(Url, Body, 'application/json');
    Status := R.Status;
    Result := R.Body;
  finally
    K.Free;
  end;
end;

function THttpAiTransport.PostStream(const Url, ApiKey, Body: string;
  Cb: TStreamCallback; out Status: Integer): string;
var
  K: THttpClient;
  R: THttpResponse;
begin
  K := LagKlient(ApiKey, FTimeoutMs);
  try
    R := K.Stream('POST', Url, Body, 'application/json', Cb);
    Status := R.Status;
    { On an error the body is not a stream but an ordinary error JSON — and
      the callback has already had it. It is not returned here. }
    Result := R.Body;
  finally
    K.Free;
  end;
end;

constructor TFakeAiTransport.Create;
begin
  inherited Create;
  FRequests := TStringList.Create;
end;

destructor TFakeAiTransport.Destroy;
begin
  FRequests.Free;
  inherited Destroy;
end;

procedure TFakeAiTransport.Enqueue(const Body: string; Status: Integer);
var
  N: Integer;
begin
  N := Length(FReplies);
  SetLength(FReplies, N + 1);
  SetLength(FStatuses, N + 1);
  FReplies[N] := Body;
  FStatuses[N] := Status;
end;

procedure TFakeAiTransport.EnqueueStream(const SseBody: string);
begin
  Enqueue(SseBody, 200);
end;

function TFakeAiTransport.Post(const Url, ApiKey, Body: string;
  out Status: Integer): string;
begin
  FRequests.Add(Body);
  if FNext > High(FReplies) then
    raise EAiError.Create(0, 'fake',
      'The fake transport has no more queued responses.');
  Status := FStatuses[FNext];
  Result := FReplies[FNext];
  Inc(FNext);
end;

function TFakeAiTransport.PostStream(const Url, ApiKey, Body: string;
  Cb: TStreamCallback; out Status: Integer): string;
var
  S: string;
begin
  FRequests.Add(Body);
  if FNext > High(FReplies) then
    raise EAiError.Create(0, 'fake',
      'The fake transport has no more queued responses.');
  Status := FStatuses[FNext];
  S := FReplies[FNext];
  Inc(FNext);
  { The whole stream in one chunk. That is enough to test the SSE parser,
    and the splitting across chunks is tested separately in the HTTP
    client. }
  if Assigned(Cb) then
    Cb(S);
  if Status <> 200 then
    Exit(S);
  Result := '';
end;

{ ------------------------------------------------------------ TAiClient -- }

constructor TAiClient.Create;
begin
  { The key from the configuration layer: environment, then .env. CfgOrFail
    names the key and where it looked, never a value. }
  Create(CfgOrFail('anthropic.api.key'));
end;

constructor TAiClient.Create(const AApiKey: string);
begin
  inherited Create;
  if Trim(AApiKey) = '' then
    raise EAiError.Create(0, 'config',
      'No Anthropic API key. Set ANTHROPIC_API_KEY in the environment ' +
      'or in .env.');
  FApiKey := AApiKey;
  FBaseUrl := Cfg('anthropic.base.url', DefaultAiBaseUrl);
  FModel := Cfg('anthropic.model', DefaultAiModel);
  FMaxTokens := DefaultAiMaxTokens;
  FMaxTurns := DefaultAiMaxTurns;
  FThinking := atOff;
  FTransport := THttpAiTransport.Create;
  FOwnsTransport := True;
end;

destructor TAiClient.Destroy;
begin
  if FOwnsTransport then
    FTransport.Free;
  inherited Destroy;
end;

procedure TAiClient.UseTransport(T: TAiTransport; Owns: Boolean);
begin
  if FOwnsTransport then
    FTransport.Free;
  FTransport := T;
  FOwnsTransport := Owns;
end;

procedure TAiClient.SetTemperature(V: Double);
begin
  FTemperature := V;
  FHasTemperature := True;
end;

procedure TAiClient.ClearTemperature;
begin
  FHasTemperature := False;
end;

procedure TAiClient.AddTool(const Name_, Description, SchemaJson: string;
  H: TAiToolHandler);
var
  N: Integer;
begin
  N := Length(FTools);
  SetLength(FTools, N + 1);
  FTools[N].Name := Name_;
  FTools[N].Description := Description;
  FTools[N].SchemaJson := SchemaJson;
  FTools[N].Handler := H;
  FTools[N].HandlerProc := nil;
end;

procedure TAiClient.AddTool(const Name_, Description, SchemaJson: string;
  H: TAiToolHandlerProc);
var
  N: Integer;
begin
  N := Length(FTools);
  SetLength(FTools, N + 1);
  FTools[N].Name := Name_;
  FTools[N].Description := Description;
  FTools[N].SchemaJson := SchemaJson;
  FTools[N].Handler := nil;
  FTools[N].HandlerProc := H;
end;

procedure TAiClient.ClearTools;
begin
  SetLength(FTools, 0);
end;

function TAiClient.ToolCount: Integer;
begin
  Result := Length(FTools);
end;

{ ------------------------------------------------------------- bygging -- }

function TAiClient.BuildBody(const Messages: array of TAiMessage;
  Streaming: Boolean; const ForceTool: string): string;
var
  A: TArena;
  W: TJsonWriter;
  I: Integer;
begin
  A := TArena.Create(64 * 1024);
  try
    W.Init(A, 8 * 1024);
    W.BeginObject;
    W.Field('model', FModel);
    W.Field('max_tokens', Int64(FMaxTokens));
    if FSystem <> '' then
      W.Field('system', FSystem);
    if FHasTemperature then
    begin
      W.Key('temperature');
      W.Num(FTemperature);
    end;
    if Streaming then
      W.Field('stream', True);

    if FThinking = atAdaptive then
    begin
      { `adaptive`, not `budget_tokens`. The old form is rejected with a
        400 by the models here, and it is exactly the one you
        remember. }
      W.Key('thinking');
      W.BeginObject;
      W.Field('type', 'adaptive');
      W.EndObject;
    end;

    if Length(FTools) > 0 then
    begin
      W.Key('tools');
      W.BeginArray;
      for I := 0 to High(FTools) do
      begin
        W.BeginObject;
        W.Field('name', FTools[I].Name);
        W.Field('description', FTools[I].Description);
        W.FieldRaw('input_schema', Str(FTools[I].SchemaJson));
        W.EndObject;
      end;
      W.EndArray;
      if ForceTool <> '' then
      begin
        { tool_choice with a name forces the model to that particular tool.
          That is how structured output becomes structured and not
          prose. }
        W.Key('tool_choice');
        W.BeginObject;
        W.Field('type', 'tool');
        W.Field('name', ForceTool);
        W.EndObject;
      end;
    end;

    W.Key('messages');
    W.BeginArray;
    for I := 0 to High(Messages) do
    begin
      W.BeginObject;
      if Messages[I].Role = arUser then
        W.Field('role', 'user')
      else
        W.Field('role', 'assistant');
      if Messages[I].IsToolResult then
      begin
        { A tool result is a block in a user message, not a role of its
          own. }
        W.Key('content');
        W.BeginArray;
        W.BeginObject;
        W.Field('type', 'tool_result');
        W.Field('tool_use_id', Messages[I].ToolUseId);
        W.Field('content', Messages[I].Text);
        if Messages[I].IsError then
          W.Field('is_error', True);
        W.EndObject;
        W.EndArray;
      end
      else
        W.Field('content', Messages[I].Text);
      W.EndObject;
    end;
    W.EndArray;
    W.EndObject;
    Result := W.ToString;
  finally
    A.Free;
  end;
end;

{ ------------------------------------------------------------- lesing -- }

procedure TAiClient.RaiseFor(Status: Integer; const Body: string);
var
  A: TArena;
  Root, Err: PJsonValue;
  ErrAt: SizeInt;
  Kind, Msg, Suffix: string;
begin
  Kind := '';
  Msg := '';
  A := TArena.Create(16 * 1024);
  try
    if JsonParse(A, Str(Body), Root, ErrAt) then
    begin
      Err := JsonMember(Root, 'error');
      if Err <> nil then
      begin
        Kind := JsonAsString(JsonMember(Err, 'type'));
        Msg := JsonAsString(JsonMember(Err, 'message'));
      end;
    end;
  finally
    A.Free;
  end;
  if Msg = '' then
    { The body may be HTML from an intermediate proxy. Then the first few
      characters are more useful than nothing, but not the whole page. }
    Msg := Trim(Copy(Body, 1, 300));
  if Msg = '' then
    Msg := 'The request failed with no message';
  { The parentheses belong to the message text. Kind is to be the type the
    way the API writes it, so that calling code can compare against it —
    `overloaded_error` to try again, `invalid_request_error` to leave it
    alone. }
  if Kind <> '' then
    Suffix := ' (' + Kind + ')'
  else
    Suffix := '';
  raise EAiError.Create(Status, Kind,
    Format('Anthropic API error %d%s: %s', [Status, Suffix, Msg]));
end;

function TAiClient.ParseResponse(const Json: string): TAiResponse;
var
  A: TArena;
  Root, Content, Blokk, U, Inp: PJsonValue;
  Err: SizeInt;
  T: string;
  N: Integer;
begin
  Result.Text := '';
  Result.Thinking := '';
  Result.StopReason := '';
  Result.Model := '';
  Result.Usage.InputTokens := 0;
  Result.Usage.OutputTokens := 0;
  Result.ToolCalls := nil;
  Result.Raw := Json;

  A := TArena.Create(256 * 1024);
  try
    if not JsonParse(A, Str(Json), Root, Err) then
      raise EAiError.Create(0, 'parse',
        Format('The response was not valid JSON (at byte %d)', [Err]));

    Result.StopReason := JsonAsString(JsonMember(Root, 'stop_reason'));
    Result.Model := JsonAsString(JsonMember(Root, 'model'));

    U := JsonMember(Root, 'usage');
    if U <> nil then
    begin
      Result.Usage.InputTokens := JsonAsInt(JsonMember(U, 'input_tokens'));
      Result.Usage.OutputTokens := JsonAsInt(JsonMember(U, 'output_tokens'));
    end;

    Content := JsonMember(Root, 'content');
    if Content <> nil then
    begin
      Blokk := Content^.First;
      N := 0;
      while Blokk <> nil do
      begin
        T := JsonAsString(JsonMember(Blokk, 'type'));
        if T = 'text' then
          Result.Text := Result.Text + JsonAsString(JsonMember(Blokk, 'text'))
        else if T = 'thinking' then
          Result.Thinking := Result.Thinking +
            JsonAsString(JsonMember(Blokk, 'thinking'))
        else if T = 'tool_use' then
        begin
          SetLength(Result.ToolCalls, N + 1);
          Result.ToolCalls[N].Id := JsonAsString(JsonMember(Blokk, 'id'));
          Result.ToolCalls[N].Name := JsonAsString(JsonMember(Blokk, 'name'));
          Inp := JsonMember(Blokk, 'input');
          { The arguments are passed on as JSON text. Taking them apart here
            would have required the framework to know which fields the tool
            has — and that is precisely what the tool knows itself. }
          if Inp <> nil then
            Result.ToolCalls[N].InputJson := JsonToString(A, Inp)
          else
            Result.ToolCalls[N].InputJson := '{}';
          Inc(N);
        end;
        Blokk := Blokk^.Next;
      end;
    end;
  finally
    A.Free;
  end;
end;

{ ------------------------------------------------------------- kallene -- }

function TAiClient.SendForcing(const Messages: array of TAiMessage;
  const ForceTool: string): TAiResponse;
var
  Body, Reply: string;
  Status: Integer;
begin
  Body := BuildBody(Messages, False, ForceTool);
  Reply := FTransport.Post(FBaseUrl + '/v1/messages', FApiKey, Body, Status);
  if (Status < 200) or (Status > 299) then
    RaiseFor(Status, Reply);
  Result := ParseResponse(Reply);
end;

function TAiClient.Send(const Messages: array of TAiMessage): TAiResponse;
begin
  Result := SendForcing(Messages, '');
end;

function TAiClient.Ask(const Prompt: string): string;
begin
  Result := Send([UserMsg(Prompt)]).Text;
end;

{ ---------------------------------------------------------- streaming -- }

function TAiClient.OnChunk(const Chunk: string): Boolean;
var
  Buf, Line: string;
  P: Integer;
begin
  Result := True;
  { SSE is line based, and a line can be split between two chunks. The
    remainder is kept until next time — without it you lose every line that
    happens to cross a buffer boundary, and it looks as if the model is
    skipping words. }
  Buf := FSseRest + Chunk;
  FSseRest := '';
  repeat
    P := Pos(#10, Buf);
    if P = 0 then
    begin
      FSseRest := Buf;
      Break;
    end;
    Line := Copy(Buf, 1, P - 1);
    System.Delete(Buf, 1, P);
    { CRLF eller LF — begge forekommer. }
    if (Line <> '') and (Line[Length(Line)] = #13) then
      System.Delete(Line, Length(Line), 1);
    HandleSseLine(Line);
    { The check has to be inside the loop. A whole SSE stream can arrive in
      one chunk, and then a stop after the first delta would not get to
      take effect before all the others had already been delivered. }
    if FStreamStop = 'abort' then
    begin
      FSseRest := '';
      Exit(False);
    end;
  until False;
end;

procedure TAiClient.HandleSseLine(const Line: string);
var
  Data: string;
  A: TArena;
  Root, D, U: PJsonValue;
  Err: SizeInt;
  T, Bit: string;
  Fortsett: Boolean;
begin
  { Only data lines mean anything. The `event:` lines repeat what is in
    the JSON's own `type`, and comment lines (`:`) are heartbeats. }
  if Copy(Line, 1, 5) <> 'data:' then
    Exit;
  Data := Trim(Copy(Line, 6, MaxInt));
  if (Data = '') or (Data = '[DONE]') then
    Exit;

  A := TArena.Create(32 * 1024);
  try
    if not JsonParse(A, Str(Data), Root, Err) then
      Exit;
    T := JsonAsString(JsonMember(Root, 'type'));

    if T = 'content_block_delta' then
    begin
      D := JsonMember(Root, 'delta');
      if D = nil then
        Exit;
      if JsonAsString(JsonMember(D, 'type')) = 'text_delta' then
      begin
        Bit := JsonAsString(JsonMember(D, 'text'));
        if Bit = '' then
          Exit;
        FStreamText := FStreamText + Bit;
        Fortsett := True;
        if Assigned(FDelta) then
          Fortsett := FDelta(Bit)
        else if Assigned(FDeltaProc) then
          Fortsett := FDeltaProc(Bit);
        if not Fortsett then
          FStreamStop := 'abort';
      end;
    end
    else if T = 'message_delta' then
    begin
      D := JsonMember(Root, 'delta');
      if (D <> nil) and (FStreamStop <> 'abort') then
        FStreamStop := JsonAsString(JsonMember(D, 'stop_reason'));
      U := JsonMember(Root, 'usage');
      if U <> nil then
        FStreamUsage.OutputTokens := JsonAsInt(JsonMember(U, 'output_tokens'));
    end
    else if T = 'message_start' then
    begin
      D := JsonMember(Root, 'message');
      if D <> nil then
      begin
        U := JsonMember(D, 'usage');
        if U <> nil then
          FStreamUsage.InputTokens := JsonAsInt(JsonMember(U, 'input_tokens'));
      end;
    end
    else if T = 'error' then
    begin
      D := JsonMember(Root, 'error');
      if D <> nil then
        raise EAiError.Create(0, JsonAsString(JsonMember(D, 'type')),
          'Anthropic streaming error: ' +
          JsonAsString(JsonMember(D, 'message')));
    end;
  finally
    A.Free;
  end;
end;

function TAiClient.StreamMessages(const Messages: array of TAiMessage;
  Cb: TAiDeltaCallbackProc): TAiResponse;
var
  Body, Reply: string;
  Status: Integer;
begin
  FDeltaProc := Cb;
  FSseRest := '';
  FStreamText := '';
  FStreamStop := '';
  FStreamUsage.InputTokens := 0;
  FStreamUsage.OutputTokens := 0;
  try
    Body := BuildBody(Messages, True, '');
    Reply := FTransport.PostStream(FBaseUrl + '/v1/messages', FApiKey, Body,
      OnChunk, Status);
    if (Status < 200) or (Status > 299) then
      { On an error the body is not a stream. The callback has had it, but
        it is not text the model has written — it is an error. }
      RaiseFor(Status, FStreamText + Reply);
  finally
    FDeltaProc := nil;
    FDelta := nil;
  end;

  Result.Text := FStreamText;
  Result.Thinking := '';
  Result.StopReason := FStreamStop;
  Result.Model := FModel;
  Result.Usage := FStreamUsage;
  Result.ToolCalls := nil;
  Result.Raw := '';
end;

function TAiClient.Stream(const Prompt: string;
  Cb: TAiDeltaCallbackProc): TAiResponse;
begin
  Result := StreamMessages([UserMsg(Prompt)], Cb);
end;

function TAiClient.Stream(const Prompt: string;
  Cb: TAiDeltaCallback): TAiResponse;
var
  Body, Reply: string;
  Status: Integer;
begin
  FDelta := Cb;
  FSseRest := '';
  FStreamText := '';
  FStreamStop := '';
  FStreamUsage.InputTokens := 0;
  FStreamUsage.OutputTokens := 0;
  try
    Body := BuildBody([UserMsg(Prompt)], True, '');
    Reply := FTransport.PostStream(FBaseUrl + '/v1/messages', FApiKey, Body,
      OnChunk, Status);
    if (Status < 200) or (Status > 299) then
      RaiseFor(Status, FStreamText + Reply);
  finally
    FDelta := nil;
  end;
  Result.Text := FStreamText;
  Result.Thinking := '';
  Result.StopReason := FStreamStop;
  Result.Model := FModel;
  Result.Usage := FStreamUsage;
  Result.ToolCalls := nil;
  Result.Raw := '';
end;

{ ------------------------------------------------------------ tools -- }

function TAiClient.RunTool(const Call: TAiToolCall): string;
var
  I: Integer;
begin
  for I := 0 to High(FTools) do
    if FTools[I].Name = Call.Name then
    begin
      if Assigned(FTools[I].Handler) then
        Exit(FTools[I].Handler(Call.InputJson));
      if Assigned(FTools[I].HandlerProc) then
        Exit(FTools[I].HandlerProc(Call.InputJson));
      Break;
    end;
  { The model asked for a tool that does not exist. Raising here would
    have taken down the whole loop; telling the model lets it correct
    itself. }
  Result := 'Error: no such tool "' + Call.Name + '".';
end;

function TAiClient.RunTools(const Prompt: string): TAiResponse;
var
  Msgs: array of TAiMessage;
  Reply: TAiResponse;
  I, Runde, N: Integer;
  Resultat: string;
begin
  SetLength(Msgs, 1);
  Msgs[0] := UserMsg(Prompt);

  for Runde := 1 to FMaxTurns do
  begin
    Reply := Send(Msgs);
    if not Reply.WantsTool then
      Exit(Reply);

    { The model's own turn has to be in the history, or it does not know
      what it asked for itself. The text is enough: the tool calls are not
      repeated, and the tool_result blocks point back with an id. }
    N := Length(Msgs);
    SetLength(Msgs, N + 1 + Length(Reply.ToolCalls));
    Msgs[N] := AssistantMsg(Reply.Text);
    for I := 0 to High(Reply.ToolCalls) do
    begin
      try
        Resultat := RunTool(Reply.ToolCalls[I]);
        Msgs[N + 1 + I] := ToolResultMsg(Reply.ToolCalls[I].Id, Resultat);
      except
        on E: Exception do
          { A tool that raises is not a reason to take down the loop. The
            model gets the error and can try something else. }
          Msgs[N + 1 + I] := ToolResultMsg(Reply.ToolCalls[I].Id,
            E.ClassName + ': ' + E.Message, True);
      end;
    end;
  end;

  raise EAiError.Create(0, 'max_turns',
    Format('The tool loop did not finish within %d turns', [FMaxTurns]));
end;

{ --------------------------------------------------- strukturert utdata -- }

function TAiClient.Structured(const Prompt, SchemaJson: string): string;
const
  Verktoey = 'respond';
var
  Stored: array of TAiTool;
  Reply: TAiResponse;
begin
  { The tools are set aside and put back. Structured must not change the
    client it was called on. }
  Stored := Copy(FTools, 0, Length(FTools));
  try
    SetLength(FTools, 0);
    AddTool(Verktoey,
      'Respond with the requested structured data. Use this tool and ' +
      'nothing else.', SchemaJson, TAiToolHandlerProc(nil));
    { Send builds without tool_choice. Without it the model can answer with
      prose instead, and then "structured" is only a hope. }
    Reply := SendForcing([UserMsg(Prompt)], Verktoey);
    if not Reply.WantsTool then
      raise EAiError.Create(0, 'no_structured_output',
        'The model answered with text instead of the requested structure.');
    Result := Reply.ToolCalls[0].InputJson;
  finally
    FTools := Stored;
  end;
end;

end.
