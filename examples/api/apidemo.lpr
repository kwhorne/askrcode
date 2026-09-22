{ A small API, whole: tokens, scopes, a list envelope, CORS, a rate
  limit, and a document that describes all of it.

  It is the fixture behind `./askr api:check`, and it is an example
  because that is what it is for -- somewhere to look at the pieces
  wired together, rather than a paragraph claiming they fit.

      ./askr api:check

  builds this, starts it, and asks it the questions the layer promises
  answers to: the document is really OpenAPI (a validator says so, not
  this file), the envelope has data and meta and links, a bad token is a
  401 problem document, a preflight is a 204 with the right headers, and
  the limiter refuses with Retry-After.

  The database is a file it creates itself, so there is nothing to set
  up and nothing left behind that matters. }
program apidemo;

{$mode Delphi}{$H+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  SysUtils, Math,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Config, Askr.Core.Log,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response,
  Askr.Http.Router, Askr.Http.Server, Askr.Http.Cors, Askr.Http.RateLimit,
  Askr.Urd.Driver, Askr.Urd.Sqlite, Askr.Urd.Model, Askr.Urd.Query,
  Askr.Urd.Grid,
  Askr.Urd.Bind, Askr.Urd.Json, Askr.Auth, Askr.Auth.Token, Askr.OpenApi, Askr.Console;

type
  { A generated primary key, a couple of ordinary columns, and one that
    must never leave the process -- so the document has something to
    leave out. }
  TWidget = class(TModel)
  private
    FId: Int64;
    FName: string;
    FTier: string;
    FPrice: Currency;
    FSupplierCode: string;
  published
    property Id: Int64 read FId write FId;
    property Name: string read FName write FName;
    property Tier: string read FTier write FTier;
    property Price: Currency read FPrice write FPrice;
    property SupplierCode: string read FSupplierCode write FSupplierCode;
  public
    class procedure Describe(S: TSchema); override;
    class procedure HideFromJson(H: TJsonHidden); override;
    procedure Rules(V: TValidator); override;
  end;

const
  { What `askr schema` generates from the real database. }
  Widgets: record
    Id: TColInt64;
    Name: TColStr;
    Tier: TColStr;
    Price: TColCurrency;
    SupplierCode: TColStr;
  end = (
    Id: (Name: 'id'; Table: 'widgets');
    Name: (Name: 'name'; Table: 'widgets');
    Tier: (Name: 'tier'; Table: 'widgets');
    Price: (Name: 'price'; Table: 'widgets');
    SupplierCode: (Name: 'supplier_code'; Table: 'widgets'));

class procedure TWidget.Describe(S: TSchema);
begin
  S.Table('widgets');
end;

class procedure TWidget.HideFromJson(H: TJsonHidden);
begin
  H.Add(Widgets.SupplierCode);
end;

procedure TWidget.Rules(V: TValidator);
begin
  V.Field('Name').Required.MaxLen(60);
  V.Field('Tier').OneOf(['gold', 'silver']);
end;

type
  TWidgetCtl = class
  public
    function Index(Req: TRequest): TResponse;
    function Show(Req: TRequest): TResponse;
    function Store(Req: TRequest): TResponse;
  end;

function TWidgetCtl.Index(Req: TRequest): TResponse;
var
  G: TGrid<TWidget>;
begin
  AuthorizeScope('widgets:read');
  G := TGrid<TWidget>.New;
  G.Read(Req)
   .Sortable('name', Widgets.Name)
   .Sortable('price', Widgets.Price)
   .Searchable([Widgets.Name])
   .DefaultSort('name')
   .PerPage(2, 50);
  Result := G.ListResponse(G.Rows(TQuery<TWidget>.New));
end;

function TWidgetCtl.Show(Req: TRequest): TResponse;
var
  W: TWidget;
begin
  AuthorizeScope('widgets:read');
  W := TQuery<TWidget>.New.Find(Req.Param('id').ToIntDef(0));
  if W = nil then
    Exit(Problem(404, 'No widget with that id.'));
  Result := RespondModel(W);
end;

function TWidgetCtl.Store(Req: TRequest): TResponse;
var
  W: TWidget;
begin
  AuthorizeScope('widgets:write');
  W := Req.Arena.New<TWidget>;
  Req.FillInto(W);
  if not W.Validate then
    Exit(ValidationProblem(W.Errors));
  W.Save;
  Result := RespondModel(W, 201);
end;

{ ------------------------------------------------------------ the doc -- }

procedure AppApiDoc(D: TOpenApi);
begin
  D.Title('Widget API').Version('1.0')
   .Description('The fixture behind ./askr api:check.')
   .Covers('/api');

  D.Get('/api/widgets').Summary('Every widget, a page at a time')
   .ReturnsList(TWidget).Secured('widgets:read');

  D.Get('/api/widgets/:id').Summary('One widget')
   .Returns(TWidget).Secured('widgets:read');

  D.Post('/api/widgets').Summary('Add a widget')
   .Body(TWidget).Returns(TWidget, 201).Secured('widgets:write');
end;

{ ----------------------------------------------------------- plumbing -- }

var
  Db: TDbConnection;
  Server: TAskrServer;
  Opts: TServerOptions;
  R: TRouter;
  Ctl: TWidgetCtl;
  DbFile: string;
  A: TArena;

function LeaseDb(Req: TRequest): TResponse;
begin
  UseDb(Db);
  Result := nil;
end;

procedure Seed;
var
  I: Integer;
  Prev: TArena;
begin
  A := TArena.Create(16 * 1024);
  { The query builder allocates in the ambient arena, as everything in
    Urd does -- a request has one because the worker set it, and a
    startup path has to set its own. }
  Prev := UseArena(A);
  try
    Db.Exec(A, 'CREATE TABLE IF NOT EXISTS widgets (' +
      'id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, tier TEXT, ' +
      'price NUMERIC, supplier_code TEXT)');
    if TQuery<TWidget>.New.Count > 0 then
      Exit;
    for I := 1 to 5 do
      Db.Exec(A, Format(
        'INSERT INTO widgets (name, tier, price, supplier_code) ' +
        'VALUES (''Widget %d'', ''gold'', %d.50, ''SUP-%d'')', [I, I * 10, I]));
  finally
    UseArena(Prev);
    A.Free;
  end;
end;

begin
  DbFile := GetEnvironmentVariable('APIDEMO_DB');
  if DbFile = '' then
    DbFile := 'apidemo.sqlite';

  Db := OpenDbConnection('sqlite:' + DbFile);
  UseDb(Db);
  EnsureTokenSchema(Db);
  Seed;

  Ctl := TWidgetCtl.Create;
  R := TRouter.Create;

  { First: a preflight carries no credentials, so anything that refuses
    a request without one would refuse every preflight. }
  UseCors(R);
  Cors.AllowOrigin('https://app.example')
      .AllowMethods(['GET', 'POST'])
      .AllowHeaders(['Content-Type', 'Authorization']);

  R.Use(@LeaseDb);
  UseTokenAuth(R);
  { After the token, so a bucket can be named after it. }
  RateLimit.PerMinute(60).Burst(20).KeyBy(@TokenRateKey);
  UseRateLimit(R);

  R.Get('/api/widgets', Ctl.Index);
  R.Get('/api/widgets/:id', Ctl.Show);
  R.Post('/api/widgets', Ctl.Store);
  UseOpenApi(R, @AppApiDoc);

  SetConsoleDsn('sqlite:' + DbFile);
  SetConsoleRouter(R);
  if RunConsole then
  begin
    R.Free;
    Ctl.Free;
    Db.Free;
    Exit;
  end;

  Opts := DefaultServerOptions;
  Opts.Port := Word(StrToIntDef(ParamStr(1), 8351));
  { Loopback by default, and whatever is asked for otherwise. Inside a
    container loopback means the container's own, which nothing outside
    can reach -- so the gate passes 0.0.0.0 there. }
  if ParamCount >= 2 then
    Opts.Host := ParamStr(2)
  else
    Opts.Host := '127.0.0.1';
  SetLogLevel(llWarn);
  Server := TAskrServer.Create(Opts);
  try
    Server.SetHandler(R.Handle);
    WriteLn('apidemo on http://127.0.0.1:', Opts.Port);
    Flush(Output);
    Server.Run;
  finally
    Server.Free;
    R.Free;
    Ctl.Free;
    Db.Free;
  end;
end.
