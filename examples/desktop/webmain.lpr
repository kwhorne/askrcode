{ Web-skallet. Sytten linjer kode utover oppsettet — resten er App.Routes. }
program WebMain;

{$mode Delphi}{$H+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  SysUtils, BaseUnix,
  Askr.Core.Arena, Askr.Http.Request, Askr.Http.Response, Askr.Http.Server,
  Askr.Http.Router, Askr.Urd.Driver, Askr.Urd.Model, Askr.Urd.Pool,
  Askr.Urd.Sqlite, Askr.Inertia,
  App.Routes;

var
  Server: TAskrServer;
  Pool: TDbPool;
  R: TRouter;

procedure Stop_(Sig: cint); cdecl;
begin
  if Server <> nil then
    Server.Stop;
end;

function Handle(Req: TRequest): TResponse;
var
  Prev: TDbConnection;
begin
  Prev := UseDb(Pool.Lease(Req.Arena));
  try
    Result := R.Handle(Req);
  finally
    UseDb(Prev);
  end;
end;

var
  Opts: TServerOptions;
  Dsn, Root: string;
  C: TDbConnection;
begin
  Root := GetCurrentDir;
  Dsn := GetEnvironmentVariable('ASKR_DSN');
  if Dsn = '' then
    Dsn := 'sqlite:' + IncludeTrailingPathDelimiter(Root) + 'notes.db';

  Pool := TDbPool.Create(Dsn, 4);
  C := Pool.Acquire;
  try
    EnsureSchema(C);
  finally
    Pool.Release(C);
  end;

  SetPublicDir(IncludeTrailingPathDelimiter(Root) + 'public');
  TInertia.SetHead(GetEnvironmentVariable('ASKR_HEAD'));

  R := TRouter.Create;
  RegisterAppRoutes(R);

  Opts := DefaultServerOptions;
  Opts.LogRequests := True;
  Opts.Port := 8080;
  if ParamCount >= 1 then
    Opts.Port := Word(StrToIntDef(ParamStr(1), 8080));
  if ParamCount >= 2 then
    Opts.Host := ParamStr(2);

  Server := TAskrServer.Create(Opts);
  try
    Server.SetHandler(@Handle);
    fpSignal(SIGINT, @Stop_);
    fpSignal(SIGTERM, @Stop_);
    Server.Start;
    WriteLn(Format('Notes as a web service on http://%s:%d  (%s)',
      [Opts.Host, Server.BoundPort, Dsn]));
    while Server.Running do
      Sleep(50);
  finally
    Server.Free;
    R.Free;
    Pool.Free;
  end;
end.
