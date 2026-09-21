{ Askr.Ai — Claude som en del av rammeverket.

  Det finnes ingen offisiell Pascal-SDK, så dette er rå HTTP mot
  `POST /v1/messages`. Protokollen er dokumentert og stabil; det vi eier
  selv er serialiseringen, og `Askr.Core.Json` duger til begge veier.

  **Standardmodellen er `claude-opus-5`.** Ikke fordi den er billigst, men
  fordi modellvalg er appens avgjørelse og ikke rammeverkets.
  `claude-sonnet-5` og `claude-haiku-4-5` er der for den som vil ned i pris.

  **Tenkning settes som `adaptive`, aldri med `budget_tokens`.** Den gamle
  formen er avviklet på 4.6-modellene og blir **avvist med 400** på Opus 5,
  Sonnet 5 og Fable 5. Det er en felle akkurat fordi den gamle formen er
  den man husker.

  **Nøkkelen kommer fra miljøet, aldri fra kildekoden**, og logges ikke.
  Samme regel som resten av `.env`-laget.

  Fire ting i rekkefølge, slik LARAVEL.md setter dem opp: tekstgenerering,
  strømming, verktøykall, strukturert utdata. Embeddings og vektorsøk er
  ikke her — de hører til etter disse fire, og de krever `pgvector`, som
  SQLite ikke har.

  ## What som IKKE er prøvd

  **Ingen kall til det ekte API-et er gjort fra dette repoet.** Det finnes
  ingen API-nøkkel her. Formen på requesten er bygget etter dokumentasjonen
  og testet mot en fake som holder JSON-en opp mot det den skal være, og
  den ene tingen som *er* prøvd mot api.anthropic.com er at TLS, DNS og
  feilhåndteringen virker — et kall uten nøkkel som kommer tilbake som en
  ekte 401 med Anthropics egen feil-JSON.

  Det er det samme forbeholdet som står på Windows-skallet, og det skal stå
  til noen har kjørt det med en nøkkel. }
unit Askr.Ai;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Json, Askr.Core.Config,
  Askr.Core.Log,
  Askr.Http.Client;

const
  { Den nyeste og mest kapable. Byttes med Model-propertyen. }
  DefaultAiModel = 'claude-opus-5';
  AnthropicVersion = '2023-06-01';
  DefaultAiBaseUrl = 'https://api.anthropic.com';
  DefaultAiMaxTokens = 4096;
  { En verktøyløkke som ikke tar slutt er enten en feil i verktøyene eller
    en modell som har gått i ring. Taket er en sperre. }
  DefaultAiMaxTurns = 8;

type
  EAiError = class(Exception)
  private
    FStatus: Integer;
    FKind: string;
  public
    constructor Create(AStatus: Integer; const AKind, AMessage: string);
    { HTTP-statusen. 0 når feilen ikke kom fra tjeneren. }
    property Status: Integer read FStatus;
    { Anthropics egen feiltype: invalid_request_error, rate_limit_error,
      overloaded_error og resten. Tom når svaret ikke var en feil-JSON. }
    property Kind: string read FKind;
  end;

  TAiRole = (arUser, arAssistant);
  { adaptive lar modellen selv avgjøre hvor mye den tenker. Den gamle
    formen med budget_tokens avvises med 400 av modellene her. }
  TAiThinking = (atOff, atAdaptive);

  TAiMessage = record
    Role: TAiRole;
    Text: string;
    { Satt når meldingen er svaret på et verktøykall. }
    ToolUseId: string;
    IsToolResult: Boolean;
    IsError: Boolean;
  end;

  TAiToolCall = record
    Id: string;
    Name: string;
    { Argumentene som JSON, slik modellen sendte dem. }
    InputJson: string;
  end;

  TAiUsage = record
    InputTokens: Int64;
    OutputTokens: Int64;
  end;

  TAiResponse = record
    Text: string;
    { Tenkningen, når den er slått på og modellen viser den. }
    Thinking: string;
    StopReason: string;
    Model: string;
    Usage: TAiUsage;
    ToolCalls: array of TAiToolCall;
    { Hele svaret, til det API-et gir som vi ikke har plukket ut. }
    Raw: string;
    function WantsTool: Boolean;
    function ToolCallCount: Integer;
  end;

  { Et verktøy modellen kan kalle. Handleren får argumentene som JSON og
    gir resultatet tilbake som tekst — modellen leser det som tekst
    uansett, og å kreve JSON ut ville vært en regel uten grunn. }
  TAiToolHandler = function(const InputJson: string): string of object;
  TAiToolHandlerProc = function(const InputJson: string): string;

  TAiTool = record
    Name: string;
    Description: string;
    { `input_schema`-objektet, rått. Et JSON Schema av typen object. }
    SchemaJson: string;
    Handler: TAiToolHandler;
    HandlerProc: TAiToolHandlerProc;
  end;

  { Kalles for hver tekstbit som kommer. False avbryter strømmen. }
  TAiDeltaCallback = function(const Delta: string): Boolean of object;
  TAiDeltaCallbackProc = function(const Delta: string): Boolean;

  { Hvordan requesten kommer seg ut. Finnes som egen type for at tester
    skal slippe nett — samme grep som TNullTransport i Askr.Mail. }
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

  { To_ tester. Svarene legges inn på forhånd; requestene tas vare på slik
    at en test kan hevde om hva som faktisk ble sendt. }
  TFakeAiTransport = class(TAiTransport)
  private
    FReplies: array of string;
    FStatuser: array of Integer;
    FNext: Integer;
    FSendt: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Enqueue(const Body: string; Status: Integer = 200);
    { SSE-strøm: teksten leveres som den er, i én bit. }
    procedure EnqueueStream(const SseBody: string);
    function Post(const Url, ApiKey, Body: string;
      out Status: Integer): string; override;
    function PostStream(const Url, ApiKey, Body: string;
      Cb: TStreamCallback; out Status: Integer): string; override;
    { JSON-en som ble sendt, i rekkefølge. }
    property Sent: TStringList read FSendt;
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
    { Nøkkelen fra ANTHROPIC_API_KEY, gjennom konfigurasjonslaget. Kaster
      når den mangler — meldingen nevner nøkkelen, aldri en verdi. }
    constructor Create; overload;
    constructor Create(const AApiKey: string); overload;
    destructor Destroy; override;

    { Det enkleste kallet som finnes. }
    function Ask(const Prompt: string): string;
    { Én runde med hele meldingslista. }
    function Send(const Messages: array of TAiMessage): TAiResponse;

    { Strømmer svaret. Callbacken får tekstbitene etter hvert; svaret som
      returneres har hele teksten samlet, slik at begge deler er der. }
    function Stream(const Prompt: string;
      Cb: TAiDeltaCallback): TAiResponse; overload;
    function Stream(const Prompt: string;
      Cb: TAiDeltaCallbackProc): TAiResponse; overload;
    function StreamMessages(const Messages: array of TAiMessage;
      Cb: TAiDeltaCallbackProc): TAiResponse;

    { Verktøy. Navnet må være det samme som i skjemaet. }
    procedure AddTool(const Name_, Description, SchemaJson: string;
      H: TAiToolHandler); overload;
    procedure AddTool(const Name_, Description, SchemaJson: string;
      H: TAiToolHandlerProc); overload;
    procedure ClearTools;
    function ToolCount: Integer;

    { Kjører løkka: send, utfør verktøyene modellen ba om, send resultatene
      tilbake, gjenta. Stopper når modellen er ferdig eller MaxTurns er
      brukt opp. }
    function RunTools(const Prompt: string): TAiResponse;

    { Strukturert utdata gjennom et verktøy modellen tvinges til å bruke.

      Det er den formen som virker på tvers av modeller og som ikke kan
      svare med prosa ved siden av. Resultatet er JSON som følger skjemaet.
      Skjemaet er `input_schema`-objektet, altså et JSON Schema av typen
      object. }
    function Structured(const Prompt, SchemaJson: string): string;

    property Model: string read FModel write FModel;
    property System_: string read FSystem write FSystem;
    property MaxTokens: Integer read FMaxTokens write FMaxTokens;
    property Thinking: TAiThinking read FThinking write FThinking;
    property MaxTurns: Integer read FMaxTurns write FMaxTurns;
    property BaseUrl: string read FBaseUrl write FBaseUrl;
    { Settes den ikke, sendes ingen temperature og API-et bruker sin egen. }
    procedure SetTemperature(V: Double);
    procedure ClearTemperature;
    { Byttes ut i tester. Klienten overtar eierskapet. }
    procedure UseTransport(T: TAiTransport; Owns: Boolean = True);
  end;

{ Hjelpere til å bygge meldingslister. }
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
  { Et verktøyresultat er en user-melding med en tool_result-blokk. Det er
    ikke åpenbart, og det er den vanligste feilen når man bygger løkka selv. }
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
  { x-api-key, ikke Authorization: Bearer. Anthropic bruker sin egen
    header, og en Bearer-token her gir 401 uten forklaring. }
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
    { Ved feil er kroppen ikke en strøm, men en vanlig feil-JSON — og den
      har callbacken allerede fått. Den returneres ikke her. }
    Result := R.Body;
  finally
    K.Free;
  end;
end;

constructor TFakeAiTransport.Create;
begin
  inherited Create;
  FSendt := TStringList.Create;
end;

destructor TFakeAiTransport.Destroy;
begin
  FSendt.Free;
  inherited Destroy;
end;

procedure TFakeAiTransport.Enqueue(const Body: string; Status: Integer);
var
  N: Integer;
begin
  N := Length(FReplies);
  SetLength(FReplies, N + 1);
  SetLength(FStatuser, N + 1);
  FReplies[N] := Body;
  FStatuser[N] := Status;
end;

procedure TFakeAiTransport.EnqueueStream(const SseBody: string);
begin
  Enqueue(SseBody, 200);
end;

function TFakeAiTransport.Post(const Url, ApiKey, Body: string;
  out Status: Integer): string;
begin
  FSendt.Add(Body);
  if FNext > High(FReplies) then
    raise EAiError.Create(0, 'fake',
      'The fake transport has no more queued responses.');
  Status := FStatuser[FNext];
  Result := FReplies[FNext];
  Inc(FNext);
end;

function TFakeAiTransport.PostStream(const Url, ApiKey, Body: string;
  Cb: TStreamCallback; out Status: Integer): string;
var
  S: string;
begin
  FSendt.Add(Body);
  if FNext > High(FReplies) then
    raise EAiError.Create(0, 'fake',
      'The fake transport has no more queued responses.');
  Status := FStatuser[FNext];
  S := FReplies[FNext];
  Inc(FNext);
  { Hele strømmen i én bit. Det holder til å teste SSE-parseren, og
    oppdelingen på tvers av biter testes for seg i HTTP-klienten. }
  if Assigned(Cb) then
    Cb(S);
  if Status <> 200 then
    Exit(S);
  Result := '';
end;

{ ------------------------------------------------------------ TAiClient -- }

constructor TAiClient.Create;
begin
  { Nøkkelen fra konfigurasjonslaget: miljø, så .env. CfgOrFail nevner
    nøkkelen og hvor det ble lett, aldri en verdi. }
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
      { `adaptive`, ikke `budget_tokens`. Den gamle formen avvises med 400
        av modellene her, og den er akkurat den man husker. }
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
        { tool_choice med et navn tvinger modellen til nettopp det
          verktøyet. Det er slik strukturert utdata blir strukturert og
          ikke prosa. }
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
        { Et verktøyresultat er en blokk i en user-melding, ikke en egen
          rolle. }
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
    { Kroppen kan være HTML fra en mellomliggende proxy. Da er de første
      tegnene mer nyttig enn ingenting, men ikke hele siden. }
    Msg := Trim(Copy(Body, 1, 300));
  if Msg = '' then
    Msg := 'The request failed with no message';
  { Parentesene hører til meldingsteksten. Kind skal være typen slik
    API-et skriver den, slik at kallende kode kan sammenligne på den —
    `overloaded_error` for å prøve igjen, `invalid_request_error` for å
    la være. }
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
          { Argumentene gis videre som JSON-tekst. Å plukke dem fra
            hverandre her ville krevd at rammeverket visste hvilke felter
            verktøyet har — og det er nettopp det verktøyet vet selv. }
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

{ ---------------------------------------------------------- strømming -- }

function TAiClient.OnChunk(const Chunk: string): Boolean;
var
  Buf, Line: string;
  P: Integer;
begin
  Result := True;
  { SSE er linjebasert, og en linje kan bli delt mellom to biter. Resten
    tas vare på til neste gang — uten det mister man hver linje som
    tilfeldigvis krysser en buffergrense, og det ser ut som at modellen
    hopper over ord. }
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
    { Sjekken må stå inne i løkka. En hel SSE-strøm kan komme i én bit,
      og da ville et stopp etter første delta ikke fått virke før alle
      de andre alt var levert. }
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
  { Bare data-linjer betyr noe. `event:`-linjene gjentar det som står i
    JSON-ens egen `type`, og kommentarlinjer (`:`) er holdepulser. }
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
      { Ved feil er kroppen ikke en strøm. Den har callbacken fått, men den
        er ikke tekst modellen har skrevet — den er en feil. }
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

{ ---------------------------------------------------------- verktøy -- }

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
  { Modellen ba om et verktøy som ikke finnes. Å kaste her ville tatt ned
    hele løkka; å si fra til modellen lar den rette seg selv. }
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

    { Modellens egen tur må med i historikken, ellers vet den ikke hva den
      selv ba om. Teksten holder: verktøykallene gjentas ikke, og
      tool_result-blokkene peker tilbake med id. }
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
          { Et verktøy som kaster er ikke en grunn til å ta ned løkka.
            Modellen får feilen og kan prøve noe annet. }
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
  { Verktøyene legges til side og settes tilbake. Structured skal ikke
    endre klienten den ble kalt på. }
  Stored := Copy(FTools, 0, Length(FTools));
  try
    SetLength(FTools, 0);
    AddTool(Verktoey,
      'Respond with the requested structured data. Use this tool and ' +
      'nothing else.', SchemaJson, TAiToolHandlerProc(nil));
    { Send bygger uten tool_choice. Without det kan modellen svare med prosa
      i stedet, og da er «strukturert» bare et håp. }
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
