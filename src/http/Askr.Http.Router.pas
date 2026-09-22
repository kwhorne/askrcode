{ Askr.Http.Router — the routing table.

  The same table is used by both the web shell and the desktop shell, as
  the PRD describes: App.RegisterRoutes(RegisterAppRoutes) is all the
  desktop variant needs to answer the same addresses.

      procedure RegisterAppRoutes(R: TRouter);
      begin
        R.Get('/customers', Ctrl.Index);
        R.Get('/customers/:id', Ctrl.Show);
        R.Post('/customers', Ctrl.Store);
      end;

  Patterns have three kinds of segment: literal, :name which captures one
  segment, and *name which captures the rest of the path. No regular
  expressions — they are not worth the complexity, and a route you cannot
  read at a glance is a route that ends up wrong.

  Routes are not sorted by registration order alone: a literal route
  always beats one with a parameter, and one with a parameter beats a
  wildcard. Otherwise /customers/new would be swallowed by
  /customers/:id depending on the order somebody happened to write
  them in. }
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

  { Runs before the handler. Returns nil to let the request through, or a
    response to stop it there. Explicit rather than a chain with Next:
    without closures a Next-based chain is harder to read than it is
    worth. }
  TMiddleware = function(Req: TRequest): TResponse of object;
  TMiddlewareProc = function(Req: TRequest): TResponse;

  { Runs after the response is made, with the response in hand. The return
    value is the response that travels on — usually the same object,
    modified.

    Middleware alone is not enough: the session has to be written back and
    the cookie set *after* the handler has run, and there is nowhere to
    hang that when the only hook is "before". The filter knows nothing
    about sessions or anything else from the runtime layer — it is only
    somewhere to stand. }
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
    { With and without the method check. The second exists so a 405 can be
      answered instead of a 404 when the path exists but the method is
      another. }
    function Matches(Req: TRequest; const Path: TStr): Boolean;
    function MatchesPath(Req: TRequest; const Path: TStr): Boolean;
    property Method: THttpMethod read FMethod;
    property Pattern: string read FPattern;
    property Name: string read FName write FName;
  end;

  TRouter = class
  private
    FRoutes: TList;
    { One list, not one per kind.

      There used to be two of each -- methods and plain procedures -- and
      Route ran every method before every procedure. Registration order
      was silently rewritten, and which of the two a piece of middleware
      happened to be was decided by how it was written rather than by
      anything a reader could see.

      It cost a real bug: a generated app registered R.Use(@LeaseDb),
      which is a procedure, and then UseTokenAuth, which is a class
      method -- so the token middleware asked for the database connection
      before the connection was leased, on every request that carried a
      token. Found by running it against a real app; nothing in the suite
      could see it, because a test that registers one kind never
      notices. }
    FBefore: array of record
      M: TMiddleware;
      P: TMiddlewareProc;
    end;
    FAfter: array of record
      F: TResponseFilter;
      P: TResponseFilterProc;
    end;
    FNotFound: TRouteHandler;
    FSorted: Boolean;
    function Add(AMethod: THttpMethod; const APattern: string): TRoute;
    procedure SortRoutes;
    { The routing itself, without the after-filters. Handle runs the
      filters around it, and every exit — 404, 405, a short-circuiting
      middleware — has to go through that one place for the filters to
      see them all. }
    function Route(Req: TRequest): TResponse;
    function RunAfter(Req: TRequest; Res: TResponse): TResponse;
  public
    constructor Create;
    destructor Destroy; override;

    { Registration. The overload without "of object" exists for free
      functions. }
    procedure Get(const Pattern: string; H: TRouteHandler); overload;
    procedure Get(const Pattern: string; H: TRouteHandlerProc); overload;
    procedure Post(const Pattern: string; H: TRouteHandler); overload;
    procedure Post(const Pattern: string; H: TRouteHandlerProc); overload;
    procedure Put(const Pattern: string; H: TRouteHandler); overload;
    procedure Patch(const Pattern: string; H: TRouteHandler); overload;
    procedure Delete(const Pattern: string; H: TRouteHandler); overload;
    procedure Any(const Pattern: string; H: TRouteHandler); overload;

    { Names the most recently registered route. `askr routes` lists them in
      step 6. }
    procedure AsName(const AName: string);

    { Middleware runs in the order it was registered, whether it is a
      method or a plain procedure. }
    procedure Use(M: TMiddleware); overload;
    procedure Use(M: TMiddlewareProc); overload;

    { After-filters run in the reverse order of registration, so that a
      pair of Use and After wraps around each other the way you expect.
      They also run when middleware short-circuited the request —
      otherwise a 401 from a guard would lose its session cookie. }
    procedure After(F: TResponseFilter); overload;
    procedure After(F: TResponseFilterProc); overload;

    { Called when no route matches. Without one set, the answer is 404. }
    procedure SetNotFound(H: TRouteHandler);

    { Not called Dispatch: that shadows TObject.Dispatch. }
    function Handle(Req: TRequest): TResponse;

    { To_ `askr routes`. Én linje per rute. }
    procedure Describe(Lines: TStrings);
    function Count: Integer;
    { The routes as data rather than as lines, for something that has to
      compare against them -- the OpenAPI document and its drift check.
      Sorted the same way Describe sorts them. }
    function RouteAt(Index: Integer): TRoute;
  end;

implementation

uses
  Askr.Core.Log;

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
        { Handled before the SplitAt above; unreachable here. }
        Exit(False);
    end;
  end;

  { Leftover segments mean a different route. }
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
  N := Length(FBefore);
  SetLength(FBefore, N + 1);
  FBefore[N].M := M;
  FBefore[N].P := nil;
end;

procedure TRouter.Use(M: TMiddlewareProc);
var
  N: Integer;
begin
  N := Length(FBefore);
  SetLength(FBefore, N + 1);
  FBefore[N].M := nil;
  FBefore[N].P := M;
end;

procedure TRouter.After(F: TResponseFilter);
var
  N: Integer;
begin
  N := Length(FAfter);
  SetLength(FAfter, N + 1);
  FAfter[N].F := F;
  FAfter[N].P := nil;
end;

procedure TRouter.After(F: TResponseFilterProc);
var
  N: Integer;
begin
  N := Length(FAfter);
  SetLength(FAfter, N + 1);
  FAfter[N].F := nil;
  FAfter[N].P := F;
end;

procedure TRouter.SetNotFound(H: TRouteHandler);
begin
  FNotFound := H;
end;

function CompareRoutes(Item1, Item2: Pointer): Integer;
begin
  { Most specific first: a literal segment beats a parameter, a parameter
    beats a wildcard. Equal specificity keeps registration order, which
    TList.Sort does not guarantee — hence the pattern as a tiebreak. }
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

function TRouter.RunAfter(Req: TRequest; Res: TResponse): TResponse;
var
  I: Integer;
begin
  Result := Res;
  { Reverse order: Use(A); After(A2); Use(B); After(B2) should give
    A, B, handler, B2, A2. }
  for I := High(FAfter) downto 0 do
    if Assigned(FAfter[I].F) then
      Result := FAfter[I].F(Req, Result)
    else
      Result := FAfter[I].P(Req, Result);
end;

{ **The after-filters run however the handler ended.** They already ran
  when middleware cut a request short; they did not when a handler
  raised, and that is where they matter most. ReleaseDb is one: every 403
  from AuthorizeScope, and every 500, kept its pooled connection -- forty
  refusals, measured, and every request after them answered 500. The
  session was not written, and a 401 went out without the challenge the
  token filter adds -- which is how it was found: a generated API, driven
  over a socket, answered 401 with no WWW-Authenticate.

  An exception that says which status it is below 500 is an answer, and
  is answered here, logged as the server logged it. Anything else runs
  the filters with a 500 in hand, for what they clean up, and is raised
  again so the server logs it as the fault it is and closes the
  connection. }
function TRouter.Handle(Req: TRequest): TResponse;
var
  Status_: Integer;
begin
  try
    Result := Route(Req);
  except
    on E: EHttpError do
    begin
      Status_ := E.HttpStatus;
      if Status_ >= 500 then
      begin
        try
          RunAfter(Req, ErrorResponse(Status_));
        except
          { The fault that brought us here is the one to report. }
        end;
        raise;
      end;
      { Below 500 it is not a fault, so it is not logged as one. The
        message is kept, because "why did this 403" is the question that
        gets asked. }
      LogInfo('request refused',
        ['status', Int64(Status_),
         'method', Askr.Http.Types.MethodName(Req.Method),
         'path', Req.Path.ToString,
         'reason', E.Message]);
      Result := ErrorResponse(Status_, E.PublicDetail);
    end;
    on E: Exception do
    begin
      try
        RunAfter(Req, ErrorResponse(500));
      except
      end;
      raise;
    end;
  end;
  Result := RunAfter(Req, Result);
end;

function TRouter.Route(Req: TRequest): TResponse;
var
  I: Integer;
  R: TRoute;
  MethodMatched: Boolean;
begin
  SortRoutes;

  for I := 0 to High(FBefore) do
  begin
    if Assigned(FBefore[I].M) then
      Result := FBefore[I].M(Req)
    else
      Result := FBefore[I].P(Req);
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
    Exit(ErrorResponse(405));

  if Assigned(FNotFound) then
    Exit(FNotFound(Req));
  Result := ErrorResponse(404);
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

function TRouter.RouteAt(Index: Integer): TRoute;
begin
  SortRoutes;
  if (Index < 0) or (Index >= FRoutes.Count) then
    Exit(nil);
  Result := TRoute(FRoutes[Index]);
end;

end.
