{ An echo server for ./askr ws:check: every message comes back as it
  went, which is what the Autobahn test suite drives a server with. }
program WsEcho;

{$mode Delphi}{$H+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  SysUtils, BaseUnix,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response, Askr.Http.Server,
  Askr.Http.WebSocket, Askr.Core.Log;

type
  TEcho = class(TWsHandler)
    procedure Text(C: TWsConnection; const Msg: string); override;
    procedure Binary(C: TWsConnection; const Data: TBytes); override;
  end;

  THost = class
    function Handle(Req: TRequest): TResponse;
  end;

var
  Echo: TEcho;
  Opts: TServerOptions;
  Server: TAskrServer;
  Host: THost;

procedure TEcho.Text(C: TWsConnection; const Msg: string);
begin
  C.SendText(Msg);
end;

procedure TEcho.Binary(C: TWsConnection; const Data: TBytes);
begin
  C.SendBinary(Data);
end;

function THost.Handle(Req: TRequest): TResponse;
begin
  Result := AcceptWebSocket(Req, Echo, []);
end;

begin
  SetLogLevel(llNone);
  { The suite sends messages of 16 MB in its larger cases. }
  SetWebSocketMaxMessage(64 * 1024 * 1024);
  Echo := TEcho.Create;
  Host := THost.Create;
  Opts := DefaultServerOptions;
  Opts.Host := '0.0.0.0';
  Opts.Port := StrToIntDef(ParamStr(1), 9001);
  Opts.Workers := 4;
  Opts.RequestTimeoutMs := 60000;
  Server := TAskrServer.Create(Opts);
  Server.SetHandler(Host.Handle);
  Server.Run;
end.
