{ Inertia end to end: Askr serves, Svelte renders.

  Step 4 of phase 1. Run with `./askr web` and open it in a browser.

  The demo deliberately uses no database. The models are made in the arena
  and filled by hand, so that step 4 can run natively without libpq — and
  so that what is tested here is the Inertia contract, not the data layer.
  The Urd demo covers the way to the database.

  The Vite manifest is read at start-up with Askr's own JSON parser, and
  gives both the script tags and the version string Inertia uses to notice
  that the frontend has been rebuilt. }
program InertiaDemo;

{$mode Delphi}{$H+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  SysUtils, Classes, BaseUnix,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Json,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response, Askr.Http.Server,
  Askr.Http.Static, Askr.Http.Router,
  Askr.Urd.Model, Askr.Urd.Query, Askr.Urd.Bind, Askr.Inertia;

var
  Server: TAskrServer;

type
  TOrder = class(TModel)
  private
    FId: Int64;
    FCustomerId: Int64;
    FTotal: Currency;
    FStatus: string;
  published
    property Id: Int64 read FId write FId;
    property CustomerId: Int64 read FCustomerId write FCustomerId;
    property Total: Currency read FTotal write FTotal;
    property Status: string read FStatus write FStatus;
  end;

  { An alias, because a nested specialization as a type argument cannot be
    written: the two closing angle brackets are read as a shift
    operator. }
  TOrderList = TModelList<TOrder>;

  TCustomer = class(TModel)
  private
    FId: Int64;
    FName: string;
    FEmail: string;
    FBalance: Currency;
    FActive: Boolean;
  published
    Orders: TOrderList;
    property Id: Int64 read FId write FId;
    property Name: string read FName write FName;
    property Email: string read FEmail write FEmail;
    property Balance: Currency read FBalance write FBalance;
    property Active: Boolean read FActive write FActive;
  public
    class procedure Describe(S: TSchema); override;
    procedure Rules(V: TValidator); override;
  end;

  TCustomerList = TModelList<TCustomer>;

class procedure TCustomer.Describe(S: TSchema);
begin
  S.Table('customers');
  S.HasMany('Orders', TOrder, 'customer_id');
end;

procedure TCustomer.Rules(V: TValidator);
begin
  V.Field('Name').Required.MaxLen(120);
  V.Field('Email').Required.Email;
  V.Field('Balance').Min(0).Max(1000000);
end;

type
  { Data that has to outlive the request cannot live in the request arena.
    The PRD's first rule, demonstrated: this is an ordinary heap structure
    with a lock, because several workers write to it. }
  TStoredCustomer = record
    Name: string;
    Email: string;
    Balance: Currency;
  end;

var
  GStored: array of TStoredCustomer;
  GStoredLock: TRTLCriticalSection;

procedure SaveCustomer(const AName, AEmail: string; ABalance: Currency);
var
  N: Integer;
begin
  EnterCriticalSection(GStoredLock);
  try
    N := Length(GStored);
    SetLength(GStored, N + 1);
    GStored[N].Name := AName;
    GStored[N].Email := AEmail;
    GStored[N].Balance := ABalance;
  finally
    LeaveCriticalSection(GStoredLock);
  end;
end;

const
  Name: array[0..5] of string = (
    'Ada Lovelace', 'Niklaus Wirth', 'Grace Hopper',
    'Anders Hejlsberg', 'Barbara Liskov', 'Ada Lovelace');
  Emails: array[0..5] of string = (
    'ada@gets.no', 'niklaus@example.com', 'grace@gets.no',
    '', 'barbara@gets.no', 'kh@gets.no');

{ Bygger testdata i request-arenaen. Alt forsvinner ved Reset. }
function MakeCustomers(A: TArena; WithOrders: Boolean): TCustomerList;
var
  I, J: Integer;
  K: TCustomer;
  O: TOrder;
begin
  Result := A.New<TCustomerList>;
  for I := 0 to High(Name) do
  begin
    K := A.New<TCustomer>;
    K.Id := I + 1;
    K.Name := Name[I];
    K.Email := Emails[I];
    K.Balance := (I + 1) * 1250 + I * 0.5;
    K.Active := I mod 3 <> 2;
    if WithOrders then
    begin
      K.Orders := A.New<TOrderList>;
      for J := 1 to I do
      begin
        O := A.New<TOrder>;
        O.Id := I * 10 + J;
        O.CustomerId := K.Id;
        O.Total := J * 249.5;
        if J mod 2 = 0 then
          O.Status := 'sendt'
        else
          O.Status := 'new';
        K.Orders.Add(O);
      end;
    end;
    Result.Add(K);
  end;

  { Then what has been added through the form. }
  EnterCriticalSection(GStoredLock);
  try
    for I := 0 to High(GStored) do
    begin
      K := A.New<TCustomer>;
      K.Id := 100 + I;
      K.Name := GStored[I].Name;
      K.Email := GStored[I].Email;
      K.Balance := GStored[I].Balance;
      K.Active := True;
      if WithOrders then
        K.Orders := A.New<TOrderList>;
      Result.Add(K);
    end;
  finally
    LeaveCriticalSection(GStoredLock);
  end;
end;

function FindCustomer(L: TCustomerList; Id: Int64): TCustomer;
var
  I: Integer;
begin
  for I := 0 to L.Count - 1 do
    if L[I].Id = Id then
      Exit(L[I]);
  Result := nil;
end;

{ ------------------------------------------------------- Vite-manifestet -- }

var
  GHeadTags: string = '';
  GAssetVersion: string = 'dev';

procedure ReadViteManifest(const Path: string);
var
  A: TArena;
  L: TStringList;
  Root, Entry, Css, Item: PJsonValue;
  ErrPos: SizeInt;
  I: Integer;
  JsFile: string;
begin
  if not FileExists(Path) then
  begin
    WriteLn('Could not find ', Path, ' — run `npm run build` in the frontend directory.');
    Halt(1);
  end;

  A := TArena.Create(64 * 1024);
  L := TStringList.Create;
  try
    L.LoadFromFile(Path);
    if not JsonParse(A, StrDup(A, L.Text), Root, ErrPos) then
    begin
      WriteLn('Invalid manifest at position ', ErrPos);
      Halt(1);
    end;

    Entry := JsonMember(Root, 'src/main.js');
    if Entry = nil then
    begin
      WriteLn('The manifest has no src/main.js');
      Halt(1);
    end;

    JsFile := JsonAsString(JsonMember(Entry, 'file'));
    GHeadTags := '';
    Css := JsonMember(Entry, 'css');
    if Css <> nil then
      for I := 0 to Css^.Count - 1 do
      begin
        Item := JsonAt(Css, I);
        GHeadTags := GHeadTags +
          '<link rel="stylesheet" href="/build/' + JsonAsString(Item) + '">' + #10 + '  ';
      end;
    GHeadTags := GHeadTags +
      '<script type="module" src="/build/' + JsFile + '"></script>';

    { The file name already has a hash in it, so it is a good enough
      version: rebuild the frontend and it changes, and Inertia forces a
      reload. }
    GAssetVersion := JsFile;
  finally
    L.Free;
    A.Free;
  end;
end;

{ ------------------------------------------------------------- kontroller -- }

type
  TAppController = class
  public
    function Home(Req: TRequest): TResponse;
    function Index(Req: TRequest): TResponse;
    function Show(Req: TRequest): TResponse;
    function NyttSkjema(Req: TRequest): TResponse;
    function Store(Req: TRequest): TResponse;
  end;

  { Static files as middleware: if it matches, the request stops
    there. }
  TStaticMiddleware = class
  private
    FStatic: TStaticFiles;
  public
    constructor Create(const PublicDir: string);
    destructor Destroy; override;
    function Handle(Req: TRequest): TResponse;
  end;

constructor TStaticMiddleware.Create(const PublicDir: string);
begin
  inherited Create;
  FStatic := TStaticFiles.Create(PublicDir);
  { The file names have hashes, so they can be cached for a long
    time. }
  FStatic.MaxAge := 31536000;
end;

destructor TStaticMiddleware.Destroy;
begin
  FStatic.Free;
  inherited Destroy;
end;

function TStaticMiddleware.Handle(Req: TRequest): TResponse;
begin
  Result := FStatic.Serve(Req);
end;



function TAppController.Home(Req: TRequest): TResponse;
var
  A: TArena;
begin
  A := Req.Arena;
  Result := Inertia('Home',
    ['rammeverk', 'Askr',
     'versjon', TInertia.Version,
     'arena', Int64(A.BytesLive),
     'reservert', Int64(A.BytesReserved),
     'requests', Int64(Server.TotalRequests)]);
end;

function TAppController.Index(Req: TRequest): TResponse;
var
  Customers: TCustomerList;
begin
  Customers := MakeCustomers(Req.Arena, True);
  Result := Inertia('Customers/Index',
    ['customers', Customers,
     'total', Int64(Customers.Count),
     'generert', FormatDateTime('hh:nn:ss', Now)]);
end;

function TAppController.NyttSkjema(Req: TRequest): TResponse;
begin
  Result := Inertia('Customers/New', ['errors', nil]);
end;

{ The shape the PRD writes, with one departure: a validation that fails
  renders the page again with errors as a prop, rather than
  Back.WithErrors. The latter requires the errors to survive a redirect,
  that is, sessions — which belong to phase 2. Inertia 3 reads props.errors
  from any reply at all, so the result in the frontend is the same. }
function TAppController.Store(Req: TRequest): TResponse;
var
  K: TCustomer;
begin
  K := Req.Arena.New<TCustomer>;
  Req.FillInto(K);

  if not K.Validate then
    Exit(Inertia('Customers/New', ['errors', K.Errors, 'sendt', K]));

  SaveCustomer(K.Name, K.Email, K.Balance);

  { Renders the list directly instead of redirecting to it. Flash does not
    survive a redirect without sessions, and the two requests could
    moreover land on different workers. See the comment at
    InertiaFlash. }
  InertiaFlash('success', 'Customer ' + K.Name + ' was created.');
  Result := Index(Req);
end;

function TAppController.Show(Req: TRequest): TResponse;
var
  Customers: TCustomerList;
begin
  Customers := MakeCustomers(Req.Arena, True);
  Result := Inertia('Customers/Show',
    ['customer', FindCustomer(Customers, Req.IntParam('id'))]);
end;

{ ------------------------------------------------------------------ main -- }

procedure HandleSignal(Sig: cint); cdecl;
begin
  if Server <> nil then
    Server.Stop;
end;

var
  Opts: TServerOptions;
  Ctrl: TAppController;
  Statisk: TStaticMiddleware;
  R: TRouter;
  Lines: TStringList;
  Root, PublicDir: string;
  I: Integer;
begin
  InitCriticalSection(GStoredLock);
  { The project root is where the app is run from. `askr serve` sets the
    working directory there; run the binary by hand and it is the directory
    you are standing in. }
  Root := GetEnvironmentVariable('ASKR_WEB_ROOT');
  if Root = '' then
    Root := GetCurrentDir;
  Root := ExpandFileName(Root);
  PublicDir := IncludeTrailingPathDelimiter(Root) + 'public';

  ReadViteManifest(IncludeTrailingPathDelimiter(PublicDir) +
    'build' + PathDelim + '.vite' + PathDelim + 'manifest.json');

  TInertia.SetVersion(GAssetVersion);
  TInertia.SetRootTemplate(
    '<!DOCTYPE html>' + #10 +
    '<html lang="no">' + #10 +
    '<head>' + #10 +
    '  <meta charset="utf-8">' + #10 +
    '  <meta name="viewport" content="width=device-width, initial-scale=1">' + #10 +
    '  <title>Askr</title>' + #10 +
    '  ' + GHeadTags + #10 +
    '</head>' + #10 +
    '<body>' + #10 +
    '  <script data-page="{{root}}" type="application/json">{{page}}</script>' + #10 +
    '  <div id="{{root}}"></div>' + #10 +
    '</body>' + #10 +
    '</html>' + #10);

  Opts := DefaultServerOptions;
  Opts.Port := 8080;
  Opts.LogRequests := True;
  if ParamCount >= 1 then
    Opts.Port := Word(StrToIntDef(ParamStr(1), 8080));
  if ParamCount >= 2 then
    Opts.Host := ParamStr(2);

  Ctrl := TAppController.Create;
  Statisk := TStaticMiddleware.Create(PublicDir);
  R := TRouter.Create;

  { The routing table. The same function the desktop shell would call. }
  R.Use(Statisk.Handle);
  R.Get('/', Ctrl.Home);                     R.AsName('home');
  R.Get('/customers', Ctrl.Index);           R.AsName('customers.index');
  R.Get('/customers/new', Ctrl.NyttSkjema);  R.AsName('customers.create');
  R.Get('/customers/:id', Ctrl.Show);        R.AsName('customers.show');
  R.Post('/customers', Ctrl.Store);          R.AsName('customers.store');

  Server := TAskrServer.Create(Opts);
  try
    Server.SetHandler(R.Handle);
    fpSignal(SIGINT, @HandleSignal);
    fpSignal(SIGTERM, @HandleSignal);
    Server.Start;
    WriteLn(Format('Askr + Inertia 3 + Svelte 5 on http://%s:%d',
      [Opts.Host, Server.BoundPort]));
    WriteLn('Statiske filer fra ', PublicDir);
    WriteLn('Inertia-versjon ', TInertia.Version);
    Lines := TStringList.Create;
    try
      R.Describe(Lines);
      WriteLn('Ruter:');
      for I := 0 to Lines.Count - 1 do
        WriteLn('  ', Lines[I]);
    finally
      Lines.Free;
    end;
    WriteLn('Ctrl-C to stop.');
    while Server.Running do
      Sleep(50);
  finally
    Server.Free;
    R.Free;
    Statisk.Free;
    Ctrl.Free;
    DoneCriticalSection(GStoredLock);
  end;
end.




