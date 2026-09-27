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
  them in.

  **Groups.** A group is a prefix, the middleware its routes need beyond
  the router's own, and what they do without:

      Admin := R.Group('/admin');
      Admin.Use(@RequireAdmin);
      Admin.Get('/users', Users.Index);         // /admin/users

      R.Group('/hooks').WithoutCsrf.Post('/stripe', Stripe.Webhook);

  An object and not a block, because anonymous procedures do not exist
  in FPC 3.2.2.

  **The route is found before any middleware runs.** The router's own
  middleware then runs, then the group's, from the outermost group in,
  then the handler. Matching first is what lets middleware that covers
  every route -- CSRF, the rate limit -- ask whether this route's group
  does without it: RouteExcludes(ExcludeCsrf). Nothing in Askr rewrites
  the method or the path in middleware, so what matches first is what
  would have matched after. }
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

  TRouteGroup = class;

  TRoute = class
  private
    FGroup: TRouteGroup;
    FMethod: THttpMethod;
    FPattern: string;
    FName: string;
    FSegments: array of TSegment;
    FHandler: TRouteHandler;
    FHandlerProc: TRouteHandlerProc;
    FSpecificity: Integer;
    FOwner: string;
    procedure Parse(const APattern: string);
    function Shape: string;
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
    { The group it was added through, or nil. }
    property Group: TRouteGroup read FGroup;
    { The pattern as parsed: /gadgets/:id/edit is a static, a param and a
      static. For askr routes:gen. }
    function SegmentCount: Integer;
    function SegmentAt(Index: Integer): TSegment;
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
    FOwner: string;
    FGroups: TList;
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

    { Who the routes added from here on belong to, for the message when
      one is added twice: UsePlugins sets it to 'the plugin stripe' while
      a plugin adds its routes. '' is the app. }
    property Owner: string read FOwner write FOwner;

    { A group of routes under Prefix -- '' for none -- with middleware and
      exclusions of its own. The router owns it. }
    function Group(const Prefix: string): TRouteGroup;

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

  TMiddlewareEntry = record
    M: TMiddleware;
    P: TMiddlewareProc;
  end;
  TMiddlewareChain = array of TMiddlewareEntry;

  TRouteGroup = class
  private
    FRouter: TRouter;
    FParent: TRouteGroup;
    FPrefix: string;
    FBefore: array of TMiddlewareEntry;
    FExcluded: array of string;
    function Add(AMethod: THttpMethod; const APattern: string): TRoute;
    { Its own middleware and its parents', outermost first. }
    function Middleware: TMiddlewareChain;
  public
    { A group inside this one: its prefix after this one's, its
      middleware after this one's, and everything this one does without. }
    function Group(const Prefix: string): TRouteGroup;

    procedure Use(M: TMiddleware); overload;
    procedure Use(M: TMiddlewareProc); overload;

    { What the group's routes do without, for middleware that covers
      every route to ask about. Returns the group, so it chains:
      R.Group('/hooks').WithoutCsrf.WithoutRateLimit. }
    function Without(const What: string): TRouteGroup;
    function WithoutCsrf: TRouteGroup;
    function WithoutRateLimit: TRouteGroup;
    { This group or one it is inside said Without(What). }
    function Excludes(const What: string): Boolean;

    procedure Get(const Pattern: string; H: TRouteHandler); overload;
    procedure Get(const Pattern: string; H: TRouteHandlerProc); overload;
    procedure Post(const Pattern: string; H: TRouteHandler); overload;
    procedure Post(const Pattern: string; H: TRouteHandlerProc); overload;
    procedure Put(const Pattern: string; H: TRouteHandler); overload;
    procedure Patch(const Pattern: string; H: TRouteHandler); overload;
    procedure Delete(const Pattern: string; H: TRouteHandler); overload;
    procedure Any(const Pattern: string; H: TRouteHandler); overload;

    { The whole prefix, its parents' included. }
    property Prefix: string read FPrefix;
    property Router: TRouter read FRouter;
  end;

const
  { The names a group does without, as the framework's middleware asks
    for them. }
  ExcludeCsrf = 'csrf';
  ExcludeRateLimit = 'rate-limit';

{ The route this request matched, or nil -- set before any middleware
  runs, for this thread's request. }
function MatchedRoute: TRoute;
{ The matched route's group does without What. False when nothing
  matched: a request for no route has nothing to be excused by. }
function RouteExcludes(const What: string): Boolean;

{ The path for Pattern with its parameters filled in, in order:

      FillRoute('/gadgets/:id/edit', ['7'])    // /gadgets/7/edit

  Each value is percent-encoded, and the router decodes it to the same
  parameter. A slash cannot be in one: the path is decoded before it is
  split, so an encoded slash splits it all the same, and the link would go
  to another route. That is refused, as is an empty value and the wrong
  count. A wildcard keeps its slashes. What App.Routes calls; see askr
  routes:gen. }
function FillRoute(const Pattern: string; const Values: array of string): string;

implementation

uses
  Askr.Core.Log, Askr.Core.Telemetry;

threadvar
  GMatched: TRoute;

function MatchedRoute: TRoute;
begin
  Result := GMatched;
end;

function RouteExcludes(const What: string): Boolean;
begin
  Result := (GMatched <> nil) and (GMatched.FGroup <> nil) and
    GMatched.FGroup.Excludes(What);
end;

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

function TRoute.SegmentCount: Integer;
begin
  Result := Length(FSegments);
end;

function TRoute.SegmentAt(Index: Integer): TSegment;
begin
  Result := FSegments[Index];
end;

{ Unreserved characters as they are, every other byte as %XX -- UTF-8
  included, byte by byte. KeepSlash for a wildcard. }
function EncodeSegment(const S: string; KeepSlash: Boolean): string;
const
  Hex = '0123456789ABCDEF';
var
  I: Integer;
  C: Char;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if (C in ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~']) or
       (KeepSlash and (C = '/')) then
      Result := Result + C
    else
      Result := Result + '%' + Hex[(Ord(C) shr 4) + 1] + Hex[(Ord(C) and 15) + 1];
  end;
end;

function FillRoute(const Pattern: string; const Values: array of string): string;
var
  R: TRoute;
  I, Used: Integer;
begin
  R := TRoute.Create(hmGet, Pattern);
  try
    Result := '';
    Used := 0;
    for I := 0 to High(R.FSegments) do
      case R.FSegments[I].Kind of
        skStatic:
          Result := Result + '/' + R.FSegments[I].Text;
        skParam, skWildcard:
          begin
            if Used > High(Values) then
              raise ERouterError.CreateFmt('%s needs more values than the %d given',
                [Pattern, Length(Values)]);
            if Values[Used] = '' then
              raise ERouterError.CreateFmt('%s: the value for :%s is empty, ' +
                'and a path with an empty segment is another path',
                [Pattern, R.FSegments[I].Text]);
            if (R.FSegments[I].Kind = skParam) and (Pos('/', Values[Used]) > 0) then
              raise ERouterError.CreateFmt('%s: the value for :%s has a slash in ' +
                'it, and the router would read it as two segments -- a ' +
                'wildcard (*%s) takes one', [Pattern, R.FSegments[I].Text,
                R.FSegments[I].Text]);
            Result := Result + '/' +
              EncodeSegment(Values[Used], R.FSegments[I].Kind = skWildcard);
            Inc(Used);
          end;
      end;
    if Used <> Length(Values) then
      raise ERouterError.CreateFmt('%s takes %d value(s), not %d',
        [Pattern, Used, Length(Values)]);
    if Result = '' then
      Result := '/';
  finally
    R.Free;
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
  FGroups := TList.Create;
end;

destructor TRouter.Destroy;
var
  I: Integer;
begin
  for I := 0 to FRoutes.Count - 1 do
    TRoute(FRoutes[I]).Free;
  FRoutes.Free;
  for I := 0 to FGroups.Count - 1 do
    TRouteGroup(FGroups[I]).Free;
  FGroups.Free;
  inherited Destroy;
end;

{ '/admin', never '/admin/' or 'admin'; '' for no prefix. A wildcard has
  to be the last segment of a route, and a prefix is never the last. }
function CleanPrefix(const Prefix: string): string;
begin
  Result := Prefix;
  while (Length(Result) > 0) and (Result[Length(Result)] = '/') do
    SetLength(Result, Length(Result) - 1);
  if (Result <> '') and (Result[1] <> '/') then
    raise ERouterError.CreateFmt(
      'A group''s prefix starts with /: %s', [Prefix]);
  if Pos('*', Result) > 0 then
    raise ERouterError.CreateFmt(
      'A group''s prefix cannot have a wildcard, which has to be the last ' +
      'segment of a route: %s', [Prefix]);
end;

function NewGroup(ARouter: TRouter; AParent: TRouteGroup;
  const APrefix: string): TRouteGroup;
begin
  Result := TRouteGroup.Create;
  Result.FRouter := ARouter;
  Result.FParent := AParent;
  if AParent <> nil then
    Result.FPrefix := AParent.FPrefix + CleanPrefix(APrefix)
  else
    Result.FPrefix := CleanPrefix(APrefix);
  ARouter.FGroups.Add(Result);
end;

function TRouter.Group(const Prefix: string): TRouteGroup;
begin
  Result := NewGroup(Self, nil, Prefix);
end;

{ ---------------------------------------------------------------- group -- }

function TRouteGroup.Group(const Prefix: string): TRouteGroup;
begin
  Result := NewGroup(FRouter, Self, Prefix);
end;

function TRouteGroup.Add(AMethod: THttpMethod; const APattern: string): TRoute;
var
  Full: string;
begin
  { /admin + / is /admin, and /admin + /users is /admin/users. }
  if (APattern = '') or (APattern = '/') then
    Full := FPrefix
  else
    Full := FPrefix + APattern;
  if Full = '' then
    Full := '/';
  Result := FRouter.Add(AMethod, Full);
  Result.FGroup := Self;
end;

procedure TRouteGroup.Use(M: TMiddleware);
begin
  SetLength(FBefore, Length(FBefore) + 1);
  FBefore[High(FBefore)].M := M;
  FBefore[High(FBefore)].P := nil;
end;

procedure TRouteGroup.Use(M: TMiddlewareProc);
begin
  SetLength(FBefore, Length(FBefore) + 1);
  FBefore[High(FBefore)].M := nil;
  FBefore[High(FBefore)].P := M;
end;

function TRouteGroup.Middleware: TMiddlewareChain;
var
  Chain: array of TRouteGroup;
  G: TRouteGroup;
  I, J, N: Integer;
begin
  Chain := nil;
  G := Self;
  while G <> nil do
  begin
    SetLength(Chain, Length(Chain) + 1);
    Chain[High(Chain)] := G;
    G := G.FParent;
  end;
  N := 0;
  for I := 0 to High(Chain) do
    Inc(N, Length(Chain[I].FBefore));
  SetLength(Result, N);
  N := 0;
  for I := High(Chain) downto 0 do
    for J := 0 to High(Chain[I].FBefore) do
    begin
      Result[N] := Chain[I].FBefore[J];
      Inc(N);
    end;
end;

function TRouteGroup.Without(const What: string): TRouteGroup;
begin
  SetLength(FExcluded, Length(FExcluded) + 1);
  FExcluded[High(FExcluded)] := What;
  Result := Self;
end;

function TRouteGroup.WithoutCsrf: TRouteGroup;
begin
  Result := Without(ExcludeCsrf);
end;

function TRouteGroup.WithoutRateLimit: TRouteGroup;
begin
  Result := Without(ExcludeRateLimit);
end;

function TRouteGroup.Excludes(const What: string): Boolean;
var
  G: TRouteGroup;
  I: Integer;
begin
  G := Self;
  while G <> nil do
  begin
    for I := 0 to High(G.FExcluded) do
      if G.FExcluded[I] = What then
        Exit(True);
    G := G.FParent;
  end;
  Result := False;
end;

procedure TRouteGroup.Get(const Pattern: string; H: TRouteHandler);
begin
  Add(hmGet, Pattern).FHandler := H;
end;

procedure TRouteGroup.Get(const Pattern: string; H: TRouteHandlerProc);
begin
  Add(hmGet, Pattern).FHandlerProc := H;
end;

procedure TRouteGroup.Post(const Pattern: string; H: TRouteHandler);
begin
  Add(hmPost, Pattern).FHandler := H;
end;

procedure TRouteGroup.Post(const Pattern: string; H: TRouteHandlerProc);
begin
  Add(hmPost, Pattern).FHandlerProc := H;
end;

procedure TRouteGroup.Put(const Pattern: string; H: TRouteHandler);
begin
  Add(hmPut, Pattern).FHandler := H;
end;

procedure TRouteGroup.Patch(const Pattern: string; H: TRouteHandler);
begin
  Add(hmPatch, Pattern).FHandler := H;
end;

procedure TRouteGroup.Delete(const Pattern: string; H: TRouteHandler);
begin
  Add(hmDelete, Pattern).FHandler := H;
end;

procedure TRouteGroup.Any(const Pattern: string; H: TRouteHandler);
begin
  Add(hmUnknown, Pattern).FHandler := H;
end;

{ ---------------------------------------------------------------- router -- }

{ The route as the router reads it, with the parameter names taken out:
  /orders/:id and /orders/:slug are one route, and so are /about and
  /about/ -- Parse skips empty segments. Built from the parsed segments,
  not the text, so it cannot disagree with what matches. }
function TRoute.Shape: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(FSegments) do
    case FSegments[I].Kind of
      skStatic: Result := Result + '/' + FSegments[I].Text;
      skParam: Result := Result + '/:';
      skWildcard: Result := Result + '/*';
    end;
end;

function TRouter.Add(AMethod: THttpMethod; const APattern: string): TRoute;
var
  I: Integer;
  Owned: string;
  Other: TRoute;
begin
  { A second route with the same method and shape would never answer:
    the first always matches before it. Said where it is added -- by a
    plugin, UsePlugins names the plugin -- rather than found out when the
    wrong page comes back. }
  Result := TRoute.Create(AMethod, APattern);
  for I := 0 to FRoutes.Count - 1 do
  begin
    Other := TRoute(FRoutes[I]);
    if (Other.Method = AMethod) and (Other.Shape = Result.Shape) then
    begin
      if Other.FOwner <> '' then
        Owned := ', by ' + Other.FOwner
      else
        Owned := '';
      Result.Free;
      raise ERouterError.CreateFmt('%s %s is registered twice (first as %s%s): the ' +
        'second would never answer', [Askr.Http.Types.MethodName(AMethod), APattern,
        Other.Pattern, Owned]);
    end;
  end;
  Result.FOwner := FOwner;
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
{ askr.request: the route that matched -- its pattern, so /orders/:id is
  one line on a dashboard and not one per order -- and the status that
  went out. The path is there too, for the log; it has no query string. }
procedure RequestTelemetry(Req: TRequest; Started: Int64; Status_: Integer);
var
  Pattern: string;
begin
  if Started = 0 then
    Exit;
  if GMatched <> nil then
    Pattern := GMatched.Pattern
  else
    Pattern := '';
  EmitSince('askr.request', Started,
    ['method', Askr.Http.Types.MethodName(Req.Method),
     'route', Pattern,
     'path', Req.Path.ToString,
     'status', IntToStr(Status_)]);
end;

function TRouter.Handle(Req: TRequest): TResponse;
var
  Status_: Integer;
  Started: Int64;
begin
  Started := TelemetryStart;
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
        RequestTelemetry(Req, Started, Status_);
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
      RequestTelemetry(Req, Started, 500);
      raise;
    end;
  end;
  Result := RunAfter(Req, Result);
  if Result <> nil then
    RequestTelemetry(Req, Started, Result.StatusCode)
  else
    RequestTelemetry(Req, Started, 0);
end;

function TRouter.Route(Req: TRequest): TResponse;
var
  I: Integer;
  R, Matched: TRoute;
  MethodMatched: Boolean;
  Chain: TMiddlewareChain;
begin
  SortRoutes;

  { The route first, so middleware can ask about it. The parameters are
    the matched route's from here on. }
  Req.ClearParams;
  Matched := nil;
  MethodMatched := False;
  for I := 0 to FRoutes.Count - 1 do
  begin
    R := TRoute(FRoutes[I]);
    if R.Matches(Req, Req.Path) then
    begin
      Matched := R;
      Break;
    end;
    { Samme sti, annen metode: da er 405 riktigere enn 404. }
    Req.ClearParams;
    if R.MatchesPath(Req, Req.Path) then
      MethodMatched := True;
    Req.ClearParams;
  end;
  GMatched := Matched;

  for I := 0 to High(FBefore) do
  begin
    if Assigned(FBefore[I].M) then
      Result := FBefore[I].M(Req)
    else
      Result := FBefore[I].P(Req);
    if Result <> nil then
      Exit;
  end;

  if Matched = nil then
  begin
    if MethodMatched then
      Exit(ErrorResponse(405));
    if Assigned(FNotFound) then
      Exit(FNotFound(Req));
    Exit(ErrorResponse(404));
  end;

  if Matched.FGroup <> nil then
  begin
    Chain := Matched.FGroup.Middleware;
    for I := 0 to High(Chain) do
    begin
      if Assigned(Chain[I].M) then
        Result := Chain[I].M(Req)
      else
        Result := Chain[I].P(Req);
      if Result <> nil then
        Exit;
    end;
  end;

  if Assigned(Matched.FHandler) then
    Exit(Matched.FHandler(Req));
  if Assigned(Matched.FHandlerProc) then
    Exit(Matched.FHandlerProc(Req));
  raise ERouterError.CreateFmt('Route %s has no handler', [Matched.Pattern]);
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
