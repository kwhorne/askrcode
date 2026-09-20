{ Inertia ende-til-ende: Askr serverer, Svelte rendrer.

  Steg 4 i fase 1. Kjøres med `./askr web` og åpnes i nettleser.

  Demoen bruker ingen database med vilje. Modellene lages i arenaen og fylles
  for hånd, slik at steg 4 kan kjøres nativt uten libpq — og slik at det som
  testes her er Inertia-kontrakten, ikke datalaget. Urd-demoen dekker veien
  til databasen.

  Vite-manifestet leses ved oppstart med Askrs egen JSON-parser, og gir både
  script-taggene og versjonsstrengen Inertia bruker til å oppdage at frontend
  er bygget på nytt. }
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

  { Alias fordi en nøstet spesialisering som typeargument ikke lar seg
    skrive: de to avsluttende vinkelparentesene leses som en skiftoperator. }
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
  { Data som skal overleve requesten kan ikke ligge i request-arenaen.
    PRD-ens første regel, demonstrert: dette er en vanlig heap-struktur med
    en lås, fordi flere workere skriver til den. }
  TStoredCustomer = record
    Name: string;
    Email: string;
    Balance: Currency;
  end;

var
  GLagret: array of TStoredCustomer;
  GLagretLaas: TRTLCriticalSection;

procedure SaveCustomer(const AName, AEmail: string; ABalance: Currency);
var
  N: Integer;
begin
  EnterCriticalSection(GLagretLaas);
  try
    N := Length(GLagret);
    SetLength(GLagret, N + 1);
    GLagret[N].Name := AName;
    GLagret[N].Email := AEmail;
    GLagret[N].Balance := ABalance;
  finally
    LeaveCriticalSection(GLagretLaas);
  end;
end;

const
  Name: array[0..5] of string = (
    'Ada Lovelace', 'Niklaus Wirth', 'Grace Hopper',
    'Anders Hejlsberg', 'Barbara Liskov', 'Knut W. Hørne');
  Emails: array[0..5] of string = (
    'ada@gets.no', 'niklaus@gets.no', 'grace@gets.no',
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

  { Så det som er lagt til gjennom skjemaet. }
  EnterCriticalSection(GLagretLaas);
  try
    for I := 0 to High(GLagret) do
    begin
      K := A.New<TCustomer>;
      K.Id := 100 + I;
      K.Name := GLagret[I].Name;
      K.Email := GLagret[I].Email;
      K.Balance := GLagret[I].Balance;
      K.Active := True;
      if WithOrders then
        K.Orders := A.New<TOrderList>;
      Result.Add(K);
    end;
  finally
    LeaveCriticalSection(GLagretLaas);
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

procedure LesViteManifest(const Path: string);
var
  A: TArena;
  L: TStringList;
  Root, Entry, Css, Item: PJsonValue;
  FeilPos: SizeInt;
  I: Integer;
  JsFil: string;
begin
  if not FileExists(Path) then
  begin
    WriteLn('Fant ikke ', Path, ' — kjør `npm run build` i frontend-mappa.');
    Halt(1);
  end;

  A := TArena.Create(64 * 1024);
  L := TStringList.Create;
  try
    L.LoadFromFile(Path);
    if not JsonParse(A, StrDup(A, L.Text), Root, FeilPos) then
    begin
      WriteLn('Ugyldig manifest ved posisjon ', FeilPos);
      Halt(1);
    end;

    Entry := JsonMember(Root, 'src/main.js');
    if Entry = nil then
    begin
      WriteLn('Manifestet har ingen src/main.js');
      Halt(1);
    end;

    JsFil := JsonAsString(JsonMember(Entry, 'file'));
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
      '<script type="module" src="/build/' + JsFil + '"></script>';

    { Filnavnet har allerede hash i seg, så det er en god nok versjon:
      bygges frontend på nytt, endres den, og Inertia tvinger omlasting. }
    GAssetVersion := JsFil;
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

  { Statiske filer som middleware: treffer den, stopper requesten der. }
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
  { Filnavnene har hash, så de kan caches lenge. }
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

{ Formen PRD-en skriver, med ett avvik: validering som feiler rendrer siden
  på nytt med errors som prop, i stedet for Back.WithErrors. Det siste
  krever at feilene overlever en omdirigering, altså sesjoner — som hører
  til fase 2. Inertia 3 leser props.errors fra hvilket som helst svar, så
  resultatet i frontend er det samme. }
function TAppController.Store(Req: TRequest): TResponse;
var
  K: TCustomer;
begin
  K := Req.Arena.New<TCustomer>;
  Req.FillInto(K);

  if not K.Validate then
    Exit(Inertia('Customers/New', ['errors', K.Errors, 'sendt', K]));

  SaveCustomer(K.Name, K.Email, K.Balance);

  { Rendrer lista direkte i stedet for å omdirigere til den. Flash overlever
    ikke en omdirigering uten sesjoner, og de to requestene ville dessuten
    kunne havnet på hver sin worker. Se kommentaren ved InertiaFlash. }
  InertiaFlash('suksess', 'Customer ' + K.Name + ' created_at');
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
  Linjer: TStringList;
  Rot, PublicDir: string;
  I: Integer;
begin
  InitCriticalSection(GLagretLaas);
  { Prosjektrota er der appen kjøres fra. `askr serve` setter arbeidsmappa
    dit; kjøres binæren for hånd, er det mappa man står i. }
  Rot := GetEnvironmentVariable('ASKR_WEB_ROOT');
  if Rot = '' then
    Rot := GetCurrentDir;
  Rot := ExpandFileName(Rot);
  PublicDir := IncludeTrailingPathDelimiter(Rot) + 'public';

  LesViteManifest(IncludeTrailingPathDelimiter(PublicDir) +
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

  { Rutingstabellen. Den samme funksjonen ville desktop-skallet kalt. }
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
    WriteLn(Format('Askr + Inertia 3 + Svelte 5 på http://%s:%d',
      [Opts.Host, Server.BoundPort]));
    WriteLn('Statiske filer fra ', PublicDir);
    WriteLn('Inertia-versjon ', TInertia.Version);
    Linjer := TStringList.Create;
    try
      R.Describe(Linjer);
      WriteLn('Ruter:');
      for I := 0 to Linjer.Count - 1 do
        WriteLn('  ', Linjer[I]);
    finally
      Linjer.Free;
    end;
    WriteLn('Ctrl-C for å stoppe.');
    while Server.Running do
      Sleep(50);
  finally
    Server.Free;
    R.Free;
    Statisk.Free;
    Ctrl.Free;
    DoneCriticalSection(GLagretLaas);
  end;
end.




