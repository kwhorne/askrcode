{ An HTTPS demo. The same app as hello, with a certificate. }
program httpsdemo;

{$mode Delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  Askr.Core.Text, Askr.Http.Types, Askr.Http.Request, Askr.Http.Response,
  Askr.Http.Server;

var
  Srv: TAskrServer;
  Opts: TServerOptions;

function Behandler(Req: TRequest): TResponse;
begin
  Result := RespondText('hei fra askr over tls', 200);
end;

begin
  Opts := DefaultServerOptions;
  Opts.Host := '127.0.0.1';
  Opts.Port := StrToIntDef(ParamStr(1), 8443);
  Opts.Workers := 2;
  Opts.TlsCertFile := ParamStr(2);
  Opts.TlsKeyFile := ParamStr(3);
  Srv := TAskrServer.Create(Opts);
  Srv.SetHandler(Behandler);
  Srv.Start;
  WriteLn('listening on https://127.0.0.1:', Srv.BoundPort);
  Flush(Output);
  Srv.Run;
end.
