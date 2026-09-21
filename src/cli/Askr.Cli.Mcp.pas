{ Askr.Cli.Mcp — the MCP server, as JSON-RPC over stdio.

  WHY IT LIVES IN THE TOOL AND NOT IN THE APP

  Laravel Boost runs its server from the application, because PHP always
  runs. An Askr app is a compiled binary: if it does not compile, there is
  no app to ask — and that is exactly the moment an agent most needs to be
  told what is wrong.

  So the server is part of `askr`, which is built from the pinned release
  and does not depend on the project compiling. Tools that need the app
  shell out to its binary; when that fails, they answer with the compiler's
  diagnostics, which is the useful answer anyway.

  That is the whole architectural bet of this layer, and there is a check
  for it: `./askr mcp:check` breaks a project on purpose and requires the
  handshake to go through regardless.

  STDOUT BELONGS TO THE PROTOCOL

  Every byte on stdout is a JSON-RPC message. One stray WriteLn anywhere
  under McpServe and the client sees a parse error instead of a reply, with
  nothing to say where it came from.

  That is not a style rule, it is the one way this layer breaks silently.
  The tool path reaches code written for a terminal, where writing to stdout
  is the right thing to do: the package layer used to say `askr.toml points
  at X but that is not an Askr checkout` and then Halt, which both corrupted
  the stream and killed the server mid-reply. Both are gone — those failures
  are raised as ECliFatal and answered as tool errors — and no path a tool
  can reach writes to stdout any more.

  `./askr mcp:check` is what holds that: four scenarios, each requiring
  every line on stdout to be one JSON object. It is the only measurement of
  it, because the hazard needs a real process with real pipes.

  A tool that shells out has to capture the child's output, not let it
  inherit — it needs the text for the reply anyway, so the two requirements
  point the same way. Redirecting `Output` inside this process would look
  like a guard and not be one: it moves where this process's Text writes,
  not where file descriptor 1 points, so a child would still write straight
  onto the channel. If a blanket guard is ever wanted, it has to be dup2 at
  the descriptor, and it has to come with a scenario that proves it.

  THE PROTOCOL VERSION

  We answer with the version the client asked for. The three methods here —
  initialize, tools/list, tools/call — have the same shape across every MCP
  revision so far, so claiming a single one would refuse clients we can in
  fact serve. If a future revision changes them, this is the line that has
  to stop being a passthrough. }
unit Askr.Cli.Mcp;

{$mode Delphi}{$H+}

interface

uses
  SysUtils,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Json;

type
  { A tool. Returns the text the agent sees; sets IsError when the tool
    could not run at all — no project, no compiler — as opposed to running
    and reporting bad news. A failing build is a successful call with a
    result that says it failed, and conflating the two would make an agent
    retry the wrong thing. }
  TMcpTool = function(A: TArena; Args: PJsonValue;
    out IsError: Boolean): string;

{ Makes a tool available. The registry is a record array with a linear
  search, for the same reason the queue's handler table is: a procedure
  variable cannot be cast to TObject in Delphi mode.

  Tools register themselves from wherever they belong — the build tool
  knows about projects and compilers, and this unit must not. }
procedure RegisterMcpTool(const Name_, Description_, InputSchema: string;
  Fn: TMcpTool);

{ One JSON-RPC line in, one line out. Returns an empty string for a
  notification, which by the specification gets no reply at all.

  Split out from the loop so that the protocol can be tested without a
  process — the same reason the router is tested without a socket. }
function McpHandle(A: TArena; const Line_: string): string;

{ The stdio loop. Reads newline-delimited JSON-RPC from stdin and writes it
  to stdout until end of input. }
procedure McpServe;

const
  McpServerName = 'askr';

  { When the client sends no protocolVersion at all — which is not legal,
    but costs nothing to survive. }
  McpFallbackProtocol = '2025-06-18';

implementation

uses
  Askr.Core.Version;

type
  TMcpToolEntry = record
    Name_: string;
    Description_: string;
    InputSchema: string;
    Fn: TMcpTool;
  end;

var
  Tools: array of TMcpToolEntry;

procedure RegisterMcpTool(const Name_, Description_, InputSchema: string;
  Fn: TMcpTool);
var
  N: Integer;
begin
  N := Length(Tools);
  SetLength(Tools, N + 1);
  Tools[N].Name_ := Name_;
  Tools[N].Description_ := Description_;
  Tools[N].InputSchema := InputSchema;
  Tools[N].Fn := Fn;
end;

function FindTool(const Name_: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(Tools) do
    if Tools[I].Name_ = Name_ then
      Exit(I);
end;

{ Writes a JSON-RPC id back with the type it arrived as. A string id echoed
  back as a number is a different id, and the client will not match it to
  its request. }
procedure WriteId(var W: TJsonWriter; Id: PJsonValue);
begin
  W.Key('id');
  if Id = nil then
    W.Null
  else
    case Id^.Kind of
      jkNumber: W.Num(JsonAsInt(Id));
      jkString: W.Str(JsonAsStr(Id));
    else
      W.Null;
    end;
end;

function ErrorReply(A: TArena; Id: PJsonValue; Code: Integer;
  const Message_: string): string;
var
  W: TJsonWriter;
begin
  W.Init(A, 256);
  W.BeginObject;
  W.Field('jsonrpc', '2.0');
  WriteId(W, Id);
  W.Key('error');
  W.BeginObject;
  W.Field('code', Int64(Code));
  W.Field('message', Message_);
  W.EndObject;
  W.EndObject;
  Result := W.ToString;
end;

function InitializeReply(A: TArena; Id, Params: PJsonValue): string;
var
  W: TJsonWriter;
  Proto: string;
begin
  Proto := '';
  if Params <> nil then
    Proto := JsonAsString(JsonMember(Params, 'protocolVersion'));
  if Proto = '' then
    Proto := McpFallbackProtocol;

  W.Init(A, 512);
  W.BeginObject;
  W.Field('jsonrpc', '2.0');
  WriteId(W, Id);
  W.Key('result');
  W.BeginObject;
  W.Field('protocolVersion', Proto);
  W.Key('capabilities');
  W.BeginObject;
  { Tools only. No resources, no prompts, no sampling — declaring a
    capability we do not serve is worse than declaring none. }
  W.Key('tools');
  W.BeginObject;
  W.EndObject;
  W.EndObject;
  W.Key('serverInfo');
  W.BeginObject;
  W.Field('name', McpServerName);
  W.Field('version', AskrVersion);
  W.EndObject;
  W.EndObject;
  W.EndObject;
  Result := W.ToString;
end;

function ToolsListReply(A: TArena; Id: PJsonValue): string;
var
  W: TJsonWriter;
  I: Integer;
begin
  W.Init(A, 128);
  W.BeginObject;
  W.Field('jsonrpc', '2.0');
  WriteId(W, Id);
  W.Key('result');
  W.BeginObject;
  W.Key('tools');
  W.BeginArray;
  for I := 0 to High(Tools) do
  begin
    W.BeginObject;
    W.Field('name', Tools[I].Name_);
    W.Field('description', Tools[I].Description_);
    W.Key('inputSchema');
    { Raw, because the schema is written once where the tool is registered
      and copied through unchanged. Rebuilding it here would be a second
      place for it to be wrong. }
    W.Raw(Str(Tools[I].InputSchema));
    W.EndObject;
  end;
  W.EndArray;
  W.EndObject;
  W.EndObject;
  Result := W.ToString;
end;

function EmptyResultReply(A: TArena; Id: PJsonValue): string;
var
  W: TJsonWriter;
begin
  W.Init(A, 128);
  W.BeginObject;
  W.Field('jsonrpc', '2.0');
  WriteId(W, Id);
  W.Key('result');
  W.BeginObject;
  W.EndObject;
  W.EndObject;
  Result := W.ToString;
end;

{ A tool result. `content` with one text block is what every revision of
  the protocol has understood; structuredContent needs an outputSchema
  negotiated per revision, and the text is what an agent reads anyway. }
function ToolsCallReply(A: TArena; Id, Params: PJsonValue): string;
var
  W: TJsonWriter;
  Name_, Text_: string;
  Idx: Integer;
  IsError: Boolean;
begin
  Name_ := JsonAsString(JsonMember(Params, 'name'));
  Idx := FindTool(Name_);
  if Idx < 0 then
    Exit(ErrorReply(A, Id, -32602, 'No such tool: ' + Name_));

  IsError := False;
  try
    Text_ := Tools[Idx].Fn(A, JsonMember(Params, 'arguments'), IsError);
  except
    { A tool that raises must not take down the server: the client would
      see the pipe close and have nothing to report. }
    on E: Exception do
    begin
      IsError := True;
      Text_ := E.ClassName + ': ' + E.Message;
    end;
  end;

  W.Init(A, 1024);
  W.BeginObject;
  W.Field('jsonrpc', '2.0');
  WriteId(W, Id);
  W.Key('result');
  W.BeginObject;
  W.Key('content');
  W.BeginArray;
  W.BeginObject;
  W.Field('type', 'text');
  W.Field('text', Text_);
  W.EndObject;
  W.EndArray;
  W.Field('isError', IsError);
  W.EndObject;
  W.EndObject;
  Result := W.ToString;
end;

function McpHandle(A: TArena; const Line_: string): string;
var
  Root, Id, Params: PJsonValue;
  ErrAt: SizeInt;
  Method: string;
  HasId: Boolean;
begin
  Result := '';
  if Trim(Line_) = '' then
    Exit;

  if not JsonParse(A, StrDup(A, Line_), Root, ErrAt) then
    { -32700 with a null id is what the specification asks for when the
      request could not even be read. }
    Exit(ErrorReply(A, nil, -32700, 'Parse error'));

  Id := JsonMember(Root, 'id');
  { A notification has no id and gets no reply — not even an error. An
    agent that receives one for `notifications/initialized` will treat it
    as a response to a request it never sent. }
  HasId := (Id <> nil) and not JsonIsNull(Id);
  Method := JsonAsString(JsonMember(Root, 'method'));
  Params := JsonMember(Root, 'params');

  if Method = '' then
  begin
    if HasId then
      Result := ErrorReply(A, Id, -32600, 'Invalid Request');
    Exit;
  end;

  if not HasId then
    Exit;

  if Method = 'initialize' then
    Result := InitializeReply(A, Id, Params)
  else if Method = 'ping' then
    Result := EmptyResultReply(A, Id)
  else if Method = 'tools/list' then
    Result := ToolsListReply(A, Id)
  else if Method = 'tools/call' then
    Result := ToolsCallReply(A, Id, Params)
  else
    Result := ErrorReply(A, Id, -32601, 'Method not found: ' + Method);
end;

procedure McpServe;
var
  A: TArena;
  Line_, Reply: string;
begin
  A := TArena.Create(64 * 1024);
  try
    while not EOF(Input) do
    begin
      ReadLn(Input, Line_);
      A.Reset;
      Reply := McpHandle(A, Line_);
      if Reply <> '' then
      begin
        WriteLn(Reply);
        { Without this the client waits forever on a buffer that is never
          sent, and it looks like the server hung. }
        Flush(Output);
      end;
    end;
  finally
    A.Free;
  end;
end;

end.
