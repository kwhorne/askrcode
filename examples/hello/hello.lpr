{ The smallest running Askr app: the arena and the HTTP host, which is
  step 1 of phase 1.

  Routing, controllers and validation arrive in step 5, so the handler here
  matches the path by hand. The point is to show that the arena model
  holds: every request gets a reset arena, everything allocated along the
  way disappears in one operation, and RSS levels off after a few hundred
  requests. }
program Hello;

{$mode Delphi}{$H+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  SysUtils, BaseUnix,
  Askr.Core.Arena, Askr.Core.Text,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response, Askr.Http.Server;

type
  { An ordinary class that lives in the request arena. No try/finally, no
    Free — the host does Arena.Reset before the next request. This is also
    what TModel will look like when Urd lands in step 2. }
  TGreeting = class(TArenaObject)
  private
    FName: TStr;
    FCount: Integer;
  public
    constructor Create(const AName: TStr);
    function Render: TStr;
  end;

  { The controllers in the PRD are methods on a class. The host accepts
    both forms, so this is the shape apps will actually use. }
  THelloController = class
  public
    function Handle(Req: TRequest): TResponse;
  end;

constructor TGreeting.Create(const AName: TStr);
begin
  inherited Create;
  FName := AName;
  FCount := 1;
end;

function TGreeting.Render: TStr;
var
  B: TStrBuilder;
begin
  B.Init(Arena, 128);
  B.Append('{"hei":"');
  if FName.IsEmpty then
    B.Append('verden')
  else
    B.Append(FName);
  B.Append('","antall":');
  B.AppendInt(FCount);
  B.Append('}');
  Result := B.ToStr;
end;

var
  Server: TAskrServer;

function THelloController.Handle(Req: TRequest): TResponse;
var
  G: TGreeting;
  B: TStrBuilder;
begin
  if Req.Path.EqualsStr('/') then
    Exit(RespondText('Askr is running. Try /hello?name=Ada, /echo or /stats' + LineEnding));

  if Req.Path.EqualsStr('/hello') then
  begin
    { Allocated in the arena because TGreeting inherits TArenaObject and the
      host has set the surrounding arena. The constructor runs as
      normal. }
    G := TGreeting.Create(Req.Query('name'));
    Exit(RespondJson('').WithBody(G.Render));
  end;

  if Req.Path.EqualsStr('/echo') then
  begin
    if Req.Method <> hmPost then
      Exit(RespondText('Bruk POST', 405).WithHeader('Allow', 'POST'));
    Exit(Respond(200)
      .WithContentType('application/octet-stream')
      .WithBody(Req.Body));
  end;

  if Req.Path.EqualsStr('/stats') then
  begin
    B.Init(Req.Arena, 256);
    B.Append('{"arena_live":');
    B.AppendInt(Req.Arena.BytesLive);
    B.Append(',"arena_reservert":');
    B.AppendInt(Req.Arena.BytesReserved);
    B.Append(',"arena_topp":');
    B.AppendInt(Req.Arena.HighWaterMark);
    B.Append(',"arena_blokker":');
    B.AppendInt(Req.Arena.BlockCount);
    B.Append(',"arena_resets":');
    B.AppendInt(Int64(Req.Arena.ResetCount));
    { The numbers above are for the worker that took this particular
      request. The ones below are for the whole server. }
    B.Append(',"server_arena_reservert":');
    B.AppendInt(Server.TotalArenaReserved);
    B.Append(',"server_arena_topp":');
    B.AppendInt(Server.TotalArenaHighWater);
    B.Append(',"requests":');
    B.AppendInt(Int64(Server.TotalRequests));
    B.Append('}');
    Exit(RespondJson('').WithBody(B.ToStr));
  end;

  Result := RespondJson('{"error":"No such route"}', 404);
end;

procedure HandleSignal(Sig: cint); cdecl;
begin
  if Server <> nil then
    Server.Stop;
end;

var
  Opts: TServerOptions;
  Controller: THelloController;
begin
  { hello [port] [lytteadresse] }
  Opts := DefaultServerOptions;
  Opts.Port := 8080;
  Opts.LogRequests := True;
  if ParamCount >= 1 then
    Opts.Port := Word(StrToIntDef(ParamStr(1), 8080));
  if ParamCount >= 2 then
    Opts.Host := ParamStr(2);

  Controller := THelloController.Create;
  Server := TAskrServer.Create(Opts);
  try
    Server.SetHandler(Controller.Handle);
    fpSignal(SIGINT, @HandleSignal);
    fpSignal(SIGTERM, @HandleSignal);

    Server.Start;
    WriteLn(Format('Askr is listening on http://%s:%d with %d workers',
      [Opts.Host, Server.BoundPort, Server.Options.Workers]));
    WriteLn('Ctrl-C to stop.');
    while Server.Running do
      Sleep(50);

    WriteLn(Format('Stopped after %d requests.', [Server.TotalRequests]));
  finally
    Server.Free;
    Controller.Free;
  end;
end.
