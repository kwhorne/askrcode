{ Minste kjørende Askr-app: arena og HTTP-vert, som er steg 1 i fase 1.

  Ruting, kontrollere og validering kommer i steg 5, så handleren her matcher
  stien for hånd. Poenget er å vise at arena-modellen holder: hver request får
  en nullstilt arena, alt som allokeres underveis forsvinner i én operasjon,
  og RSS flater ut etter noen hundre requests. }
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
  { En vanlig klasse som lever i request-arenaen. Ingen try/finally, ingen
    Free — verten gjør Arena.Reset før neste request. Slik kommer også
    TModel til å se ut når Urd lander i steg 2. }
  TGreeting = class(TArenaObject)
  private
    FName: TStr;
    FCount: Integer;
  public
    constructor Create(const AName: TStr);
    function Render: TStr;
  end;

  { Kontrollerene i PRD-en er metoder på en klasse. Verten tar imot begge
    deler, så dette er formen appene faktisk kommer til å bruke. }
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
    Exit(RespondText('Askr kjører. Prøv /hello?name=Knut, /echo eller /stats' + LineEnding));

  if Req.Path.EqualsStr('/hello') then
  begin
    { Allokert i arenaen fordi TGreeting arver TArenaObject og verten har satt
      den omgivende arenaen. Constructoren kjører som normalt. }
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
    { Tallene over gjelder den workeren som tok akkurat denne requesten.
      De under gjelder hele serveren. }
    B.Append(',"server_arena_reservert":');
    B.AppendInt(Server.TotalArenaReserved);
    B.Append(',"server_arena_topp":');
    B.AppendInt(Server.TotalArenaHighWater);
    B.Append(',"requests":');
    B.AppendInt(Int64(Server.TotalRequests));
    B.Append('}');
    Exit(RespondJson('').WithBody(B.ToStr));
  end;

  Result := RespondJson('{"feil":"Fant ikke ruten"}', 404);
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
    WriteLn(Format('Askr lytter på http://%s:%d med %d workere',
      [Opts.Host, Server.BoundPort, Server.Options.Workers]));
    WriteLn('Ctrl-C for å stoppe.');
    while Server.Running do
      Sleep(50);

    WriteLn(Format('Stoppet etter %d requests.', [Server.TotalRequests]));
  finally
    Server.Free;
    Controller.Free;
  end;
end.
