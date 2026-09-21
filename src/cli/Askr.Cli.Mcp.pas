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
  nothing to say where it came from. Diagnostics go to stderr.

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
begin
  W.Init(A, 128);
  W.BeginObject;
  W.Field('jsonrpc', '2.0');
  WriteId(W, Id);
  W.Key('result');
  W.BeginObject;
  W.Key('tools');
  W.BeginArray;
  { Empty on purpose. The tools arrive in the steps after this one; the
    point of this one is that the handshake and the transport hold. }
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
    Result := ErrorReply(A, Id, -32602,
      'No such tool: ' + JsonAsString(JsonMember(Params, 'name')))
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
