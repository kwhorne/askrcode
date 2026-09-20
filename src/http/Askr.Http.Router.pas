{ Askr.Http.Router — rutingstabellen.

  Den samme tabellen brukes av både web-skallet og desktop-skallet, slik
  PRD-en beskriver: App.RegisterRoutes(RegisterAppRoutes) er det eneste
  desktop-varianten trenger for å svare på de samme adressene.

      procedure RegisterAppRoutes(R: TRouter);
      begin
        R.Get('/customers', Ctrl.Index);
        R.Get('/customers/:id', Ctrl.Show);
        R.Post('/customers', Ctrl.Store);
      end;

  Mønstrene har tre slags segmenter: faste, :navn som fanger ett segment, og
  *navn som fanger resten av stien. Ingen regulære uttrykk — det er ikke
  verdt kompleksiteten, og en rute man ikke kan lese i farten er en rute som
  blir feil.

  Rutene sorteres ikke etter registreringsrekkefølge alene: en fast rute
  vinner alltid over en med parameter, og en med parameter over en wildcard.
  Ellers ville /customers/new blitt slukt av /customers/:id avhengig av
  hvilken rekkefølge noen tilfeldigvis skrev dem i. }
unit Askr.Http.Router;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, Askr.Core.Arena, Askr.Core.Text,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response;

type
  ERouterError = class(Exception);

  TRouteHandler = function(Req: TRequest): TResponse of object;
  TRouteHandlerProc = function(Req: TRequest): TResponse;

  { Kjøres før handleren. Returnerer nil for å slippe requesten videre, eller
    en respons for å stoppe den der. Eksplisitt framfor en kjede med Next:
    uten closures blir en Next-basert kjede vanskeligere å lese enn den er
    verdt. }
  TMiddleware = function(Req: TRequest): TResponse of object;
  TMiddlewareProc = function(Req: TRequest): TResponse;

  { Kjøres etter at svaret er laget, med svaret i hånden. Returverdien er
    svaret som går videre — som regel det samme objektet, endret.

    Middleware alene rekker ikke: sesjonen må skrives tilbake og kaka settes
    *etter* at handleren har kjørt, og det finnes ikke noe sted å henge det
    når det eneste hooket er «før». Filteret kjenner ikke sesjoner eller
    noe annet fra runtime-laget — det er bare et sted å stå. }
  TResponseFilter = function(Req: TRequest; Res: TResponse): TResponse of object;
  TResponseFilterProc = function(Req: TRequest; Res: TResponse): TResponse;

  TSegmentKind = (skStatic, skParam, skWildcard);

  TSegment = record
    Kind: TSegmentKind;
    Text: string;
  end;

  TRoute = class
  private
    FMethod: THttpMethod;
    FPattern: string;
    FName: string;
    FSegments: array of TSegment;
    FHandler: TRouteHandler;
    FHandlerProc: TRouteHandlerProc;
    FSpecificity: Integer;
    procedure Parse(const APattern: string);
  public
    constructor Create(AMethod: THttpMethod; const APattern: string);
    { Med og uten metodesjekk. Den siste finnes for å kunne svare 405 i
      stedet for 404 når stien finnes, men metoden er en annen. }
    function Matches(Req: TRequest; const Path: TStr): Boolean;
    function MatchesPath(Req: TRequest; const Path: TStr): Boolean;
    property Method: THttpMethod read FMethod;
    property Pattern: string read FPattern;
    property Name: string read FName write FName;
  end;

  TRouter = class
  private
    FRoutes: TList;
    FMiddleware: array of TMiddleware;
    FMiddlewareProcs: array of TMiddlewareProc;
    FFilters: array of TResponseFilter;
    FFilterProcs: array of TResponseFilterProc;
    FNotFound: TRouteHandler;
    FSorted: Boolean;
    function Add(AMethod: THttpMethod; const APattern: string): TRoute;
    procedure SortRoutes;
    { Selve rutingen, uten etterfiltre. Handle kjører filtrene rundt den,
      og alle utganger — 404, 405, en kortsluttende middleware — må gå
      gjennom det ene stedet for at filtrene skal se dem alle. }
    function Route(Req: TRequest): TResponse;
  public
    constructor Create;
    destructor Destroy; override;

    { Registrering. Den overlastede formen uten «of object» finnes for
      frittstående funksjoner. }
    procedure Get(const Pattern: string; H: TRouteHandler); overload;
    procedure Get(const Pattern: string; H: TRouteHandlerProc); overload;
    procedure Post(const Pattern: string; H: TRouteHandler); overload;
    procedure Post(const Pattern: string; H: TRouteHandlerProc); overload;
    procedure Put(const Pattern: string; H: TRouteHandler); overload;
    procedure Patch(const Pattern: string; H: TRouteHandler); overload;
    procedure Delete(const Pattern: string; H: TRouteHandler); overload;
    procedure Any(const Pattern: string; H: TRouteHandler); overload;

    { Navn på sist registrerte rute. `askr routes` lister dem i steg 6. }
    procedure AsName(const AName: string);

    procedure Use(M: TMiddleware); overload;
    procedure Use(M: TMiddlewareProc); overload;

    { Etterfiltre kjøres i motsatt rekkefølge av registreringen, slik at
      et par av Use og After omslutter hverandre som man forventer. De
      kjører også når middleware kortsluttet requesten — ellers ville en
      401 fra en guard mistet sesjonskaka si. }
    procedure After(F: TResponseFilter); overload;
    procedure After(F: TResponseFilterProc); overload;

    { Kalles når ingen rute passer. Uten en satt, svares det 404. }
    procedure SetNotFound(H: TRouteHandler);

    { Heter ikke Dispatch: det skygger for TObject.Dispatch. }
    function Handle(Req: TRequest): TResponse;

    { Til `askr routes`. Én linje per rute. }
    procedure Describe(Lines: TStrings);
    function Count: Integer;
  end;

implementation

{ TRoute }

constructor TRoute.Create(AMethod: THttpMethod; const APattern: string);
begin
  inherited Create;
  FMethod := AMethod;
  FPattern := APattern;
  Parse(APattern);
end;

procedure TRoute.Parse(const APattern: string);
var
  Parts: TStringList;
  I, N: Integer;
  S: string;
begin
  if (APattern = '') or (APattern[1] <> '/') then
    raise ERouterError.CreateFmt('A route pattern must start with /: %s',
      [APattern]);

  Parts := TStringList.Create;
  try
    Parts.Delimiter := '/';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := Copy(APattern, 2, MaxInt);
    FSpecificity := 0;
    for I := 0 to Parts.Count - 1 do
    begin
      S := Parts[I];
      if S = '' then
        Continue;
      N := Length(FSegments);
      SetLength(FSegments, N + 1);
      if S[1] = ':' then
      begin
        FSegments[N].Kind := skParam;
        FSegments[N].Text := Copy(S, 2, MaxInt);
        Inc(FSpecificity, 2);
      end
      else if S[1] = '*' then
      begin
        FSegments[N].Kind := skWildcard;
        FSegments[N].Text := Copy(S, 2, MaxInt);
        Inc(FSpecificity, 1);
        { Alt etter en wildcard er uansett fanget. }
        Break;
      end
      else
      begin
        FSegments[N].Kind := skStatic;
        FSegments[N].Text := S;
        Inc(FSpecificity, 3);
      end;
    end;
  finally
    Parts.Free;
  end;
end;

function TRoute.Matches(Req: TRequest; const Path: TStr): Boolean;
begin
  Result := False;
  if (FMethod <> hmUnknown) and (Req.Method <> FMethod) then
  begin
    { HEAD behandles som GET; verten utelater kroppen. }
    if not ((FMethod = hmGet) and (Req.Method = hmHead)) then
      Exit;
  end;
  Result := MatchesPath(Req, Path);
end;

function TRoute.MatchesPath(Req: TRequest; const Path: TStr): Boolean;
var
  Rest, Seg: TStr;
  I: Integer;
begin
  Result := False;
  Rest := Path;
  if (Rest.Len > 0) and (Rest.Data^ = Ord('/')) then
    Rest := Rest.Slice(1);

  for I := 0 to High(FSegments) do
  begin
    if FSegments[I].Kind = skWildcard then
    begin
      Req.SetParam(FSegments[I].Text, Rest);
      Exit(True);
    end;

    if Rest.Len = 0 then
      Exit(False);
    Rest.SplitAt(Ord('/'), Seg, Rest);

    case FSegments[I].Kind of
      skStatic:
        if not Seg.EqualsStr(FSegments[I].Text) then
          Exit(False);
      skParam:
        begin
          if Seg.Len = 0 then
            Exit(False);
          Req.SetParam(FSegments[I].Text, Seg);
        end;
      skWildcard:
        { Håndtert før SplitAt over; kan ikke nås her. }
        Exit(False);
    end;
  end;

  { Overflødige segmenter betyr en annen rute. }
  Result := Rest.Len = 0;
end;

{ TRouter }

constructor TRouter.Create;
begin
  inherited Create;
  FRoutes := TList.Create;
end;

destructor TRouter.Destroy;
var
  I: Integer;
begin
  for I := 0 to FRoutes.Count - 1 do
    TRoute(FRoutes[I]).Free;
  FRoutes.Free;
  inherited Destroy;
end;

function TRouter.Add(AMethod: THttpMethod; const APattern: string): TRoute;
begin
  Result := TRoute.Create(AMethod, APattern);
  FRoutes.Add(Result);
  FSorted := False;
end;

procedure TRouter.Get(const Pattern: string; H: TRouteHandler);
begin
  Add(hmGet, Pattern).FHandler := H;
end;

procedure TRouter.Get(const Pattern: string; H: TRouteHandlerProc);
begin
  Add(hmGet, Pattern).FHandlerProc := H;
end;

procedure TRouter.Post(const Pattern: string; H: TRouteHandler);
begin
  Add(hmPost, Pattern).FHandler := H;
end;

procedure TRouter.Post(const Pattern: string; H: TRouteHandlerProc);
begin
  Add(hmPost, Pattern).FHandlerProc := H;
end;

procedure TRouter.Put(const Pattern: string; H: TRouteHandler);
begin
  Add(hmPut, Pattern).FHandler := H;
end;

procedure TRouter.Patch(const Pattern: string; H: TRouteHandler);
begin
  Add(hmPatch, Pattern).FHandler := H;
end;

procedure TRouter.Delete(const Pattern: string; H: TRouteHandler);
begin
  Add(hmDelete, Pattern).FHandler := H;
end;

procedure TRouter.Any(const Pattern: string; H: TRouteHandler);
begin
  Add(hmUnknown, Pattern).FHandler := H;
end;

procedure TRouter.AsName(const AName: string);
begin
  if FRoutes.Count = 0 then
    raise ERouterError.Create('AsName with no route to name');
  TRoute(FRoutes[FRoutes.Count - 1]).Name := AName;
end;

procedure TRouter.Use(M: TMiddleware);
var
  N: Integer;
begin
  N := Length(FMiddleware);
  SetLength(FMiddleware, N + 1);
  FMiddleware[N] := M;
end;

procedure TRouter.Use(M: TMiddlewareProc);
var
  N: Integer;
begin
  N := Length(FMiddlewareProcs);
  SetLength(FMiddlewareProcs, N + 1);
  FMiddlewareProcs[N] := M;
end;

procedure TRouter.After(F: TResponseFilter);
begin
  SetLength(FFilters, Length(FFilters) + 1);
  FFilters[High(FFilters)] := F;
end;

procedure TRouter.After(F: TResponseFilterProc);
begin
  SetLength(FFilterProcs, Length(FFilterProcs) + 1);
  FFilterProcs[High(FFilterProcs)] := F;
end;

procedure TRouter.SetNotFound(H: TRouteHandler);
begin
  FNotFound := H;
end;

function CompareRoutes(Item1, Item2: Pointer): Integer;
begin
  { Mest spesifikke først: fast segment slår parameter, parameter slår
    wildcard. Lik spesifisitet beholder registreringsrekkefølgen, som
    TList.Sort ikke garanterer — derfor brukes mønsteret som tiebreak. }
  Result := TRoute(Item2).FSpecificity - TRoute(Item1).FSpecificity;
  if Result = 0 then
    Result := Length(TRoute(Item2).FSegments) - Length(TRoute(Item1).FSegments);
  if Result = 0 then
    Result := CompareStr(TRoute(Item1).FPattern, TRoute(Item2).FPattern);
end;

procedure TRouter.SortRoutes;
begin
  if FSorted then
    Exit;
  FRoutes.Sort(CompareRoutes);
  FSorted := True;
end;

function TRouter.Handle(Req: TRequest): TResponse;
var
  I: Integer;
begin
  Result := Route(Req);
  { Motsatt rekkefølge: Use(A); After(A'); Use(B); After(B') skal gi
    A, B, handler, B', A'. }
  for I := High(FFilterProcs) downto 0 do
    Result := FFilterProcs[I](Req, Result);
  for I := High(FFilters) downto 0 do
    Result := FFilters[I](Req, Result);
end;

function TRouter.Route(Req: TRequest): TResponse;
var
  I: Integer;
  R: TRoute;
  MethodMatched: Boolean;
begin
  SortRoutes;

  for I := 0 to High(FMiddleware) do
  begin
    Result := FMiddleware[I](Req);
    if Result <> nil then
      Exit;
  end;
  for I := 0 to High(FMiddlewareProcs) do
  begin
    Result := FMiddlewareProcs[I](Req);
    if Result <> nil then
      Exit;
  end;

  Req.ClearParams;
  MethodMatched := False;
  for I := 0 to FRoutes.Count - 1 do
  begin
    R := TRoute(FRoutes[I]);
    if R.Matches(Req, Req.Path) then
    begin
      if Assigned(R.FHandler) then
        Exit(R.FHandler(Req));
      if Assigned(R.FHandlerProc) then
        Exit(R.FHandlerProc(Req));
      raise ERouterError.CreateFmt('Route %s has no handler', [R.Pattern]);
    end;
    { Samme sti, annen metode: da er 405 riktigere enn 404. }
    Req.ClearParams;
    if R.MatchesPath(Req, Req.Path) then
      MethodMatched := True;
    Req.ClearParams;
  end;

  if MethodMatched then
    Exit(RespondText('Method Not Allowed', 405));

  if Assigned(FNotFound) then
    Exit(FNotFound(Req));
  Result := RespondText('Not Found', 404);
end;

procedure TRouter.Describe(Lines: TStrings);
var
  I: Integer;
  R: TRoute;
  M, Nm: string;
begin
  SortRoutes;
  for I := 0 to FRoutes.Count - 1 do
  begin
    R := TRoute(FRoutes[I]);
    if R.Method = hmUnknown then
      M := 'ANY'
    else
      M := Askr.Http.Types.MethodName(R.Method);
    Nm := R.Name;
    if Nm <> '' then
      Nm := '  (' + Nm + ')';
    Lines.Add(Format('%-7s %s%s', [M, R.Pattern, Nm]));
  end;
end;

function TRouter.Count: Integer;
begin
  Result := FRoutes.Count;
end;

end.
