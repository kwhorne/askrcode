{ Askr.OpenApi — the API described, from what is already true.

  There was no document here for a long time, and the reason was written
  down: Askr knows its routes but not which of them are public, what they
  accept or what they return, and a document generated from the route
  table alone would be a confident description of the wrong thing.

  That reason still holds. What changed is the division of labour, and it
  is the same one as the sitemap: **the application declares, the
  framework generates.**

      procedure AppApiDoc(D: TOpenApi);
      begin
        D.Title('Shop').Version('1.0').Covers('/api');

        D.Get('/api/customers').Summary('Every customer')
         .ReturnsList(TCustomer).Secured('customers:read');
        D.Get('/api/customers/:id').Summary('One customer')
         .Returns(TCustomer).Secured('customers:read');
        D.Post('/api/customers').Summary('Create one')
         .Body(TCustomer).Returns(TCustomer, 201).Secured('customers:write');
      end;

      UseOpenApi(R, @AppApiDoc);

  Every line there says something the framework cannot know. Everything
  else is filled in from what it does know, and cannot drift from it:

    * The schemas come from the model's own metadata -- the same
      TModelMeta that WriteModel serialises from, honouring HideFromJson.
      A column that never leaves the process is not in the document
      either, and a column that is renamed is renamed in both.
    * Path parameters come from the route pattern, typed from the model
      when the name matches one of its columns.
    * A list gets page, per, sort, dir and q, because that is what
      TGrid.Read reads.
    * The error responses come from what is actually wired up: 401 when
      the operation is secured, 403 when it names a scope, 422 when it
      takes a body, 429 when the rate limiter is running. All of them
      are problem documents, because that is what Askr answers with.

  THE DRIFT GATE IS THE POINT

  A declaration that can disagree with the code is a worse lie than no
  declaration, because it is believed. So `Problems` checks **both
  directions**: every path described must be a route that exists, and
  every route under a covered prefix must be described. One direction
  alone lets half of it rot -- the same argument as the AGENTS.md check
  in the MCP gate, which had to be made both ways for the same reason.

  `askr openapi --check` is that check with an exit code. }
unit Askr.OpenApi;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Json, Askr.Core.Url,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response, Askr.Http.Router,
  Askr.Http.RateLimit,
  Askr.Urd.Model;

type
  EOpenApiError = class(Exception);

  TApiStatus = record
    Code: Integer;
    Text: string;
  end;

  { One operation: a method and a path. Everything on it is something the
    framework cannot work out for itself. }
  TApiOp = class
  private
    FMethod: THttpMethod;
    FPath: string;
    FSummary: string;
    FTag: string;
    FBody: TModelClass;
    FReturns: TModelClass;
    FList: Boolean;
    FOkStatus: Integer;
    FSecured: Boolean;
    FScope: string;
    FExtra: array of TApiStatus;
  public
    constructor Create(AMethod: THttpMethod; const APath: string);
    function Summary(const S: string): TApiOp;
    { Groups operations in a reader. Without one the first path segment
      is used, which is what most people would have typed anyway. }
    function Tag(const S: string): TApiOp;
    { The request body is this model's insertable columns. The primary
      key is left out, because a request never fills one. }
    function Body(C: TModelClass): TApiOp;
    { Answers with one of these. }
    function Returns(C: TModelClass; AStatus: Integer = 200): TApiOp;
    { Answers with the list envelope over these: data, meta, links. }
    function ReturnsList(C: TModelClass): TApiOp;
    { Another status this can answer with, in words. }
    { 204 and no body -- what a delete answers. Returns would describe a
      body that is not there, and Answers describes an error. }
    function NoContent: TApiOp;
    function Answers(Code: Integer; const Text_: string): TApiOp;
    { Needs a bearer token, and optionally a scope. The 401 and the 403
      are then written for you. }
    function Secured(const Scope: string = ''): TApiOp;

    property Method: THttpMethod read FMethod;
    property Path: string read FPath;
  end;

  TOpenApi = class
  private
    FTitle: string;
    FVersion: string;
    FDescription: string;
    FCovers: array of string;
    FOps: TList;
    function GetOpCount: Integer;
    function ModelIndex(C: TModelClass): Integer;
    procedure Collect(C: TModelClass);
    function IsCovered(const Path_: string): Boolean;
  public
    FModels: array of TModelClass;
    constructor Create;
    destructor Destroy; override;

    function Title(const S: string): TOpenApi;
    function Version(const S: string): TOpenApi;
    function Description(const S: string): TOpenApi;
    { Which paths are the API. Every route under one of these has to be
      described, or `askr openapi --check` says which are missing. Say
      Covers('/') when the whole site is the API. }
    function Covers(const Prefix: string): TOpenApi;

    function Operation(M: THttpMethod; const Path_: string): TApiOp;
    function Get(const Path_: string): TApiOp;
    function Post(const Path_: string): TApiOp;
    function Put(const Path_: string): TApiOp;
    function Patch(const Path_: string): TApiOp;
    function Delete(const Path_: string): TApiOp;

    { The document, as OpenAPI 3.1 JSON. }
    function ToJson: string;

    { Everything that does not line up with the router, in both
      directions. Empty means the document and the routes agree. }
    function Problems(R: TRouter): TStringArray;

    property OpCount: Integer read GetOpCount;
  end;

  { Fills the document. Called per request, so it can describe what is
    running now -- the 429 appears only when the rate limiter does. }
  TApiDocSource = procedure(D: TOpenApi);

{ Serves GET /openapi.json. Register it after the static files, so an
  application's own document wins. }
procedure UseOpenApi(R: TRouter; Source: TApiDocSource);

{ The source that was registered, or nil. `askr openapi` reads it: the
  console runs inside the application binary, which is the only place
  the routes and the declaration both exist. }
function ApiDocSource: TApiDocSource;

{ Builds a document from the registered source. Raises when there is
  none, rather than returning an empty document that reads as "this API
  has nothing in it". }
function BuildApiDoc: TOpenApi;

implementation

uses
  Askr.Urd.Json;

var
  GSource: TApiDocSource = nil;

function ApiDocSource: TApiDocSource;
begin
  Result := GSource;
end;

{ ---------------------------------------------------------------- op -- }

constructor TApiOp.Create(AMethod: THttpMethod; const APath: string);
begin
  inherited Create;
  FMethod := AMethod;
  FPath := APath;
  FOkStatus := 200;
end;

function TApiOp.Summary(const S: string): TApiOp;
begin
  FSummary := S;
  Result := Self;
end;

function TApiOp.Tag(const S: string): TApiOp;
begin
  FTag := S;
  Result := Self;
end;

function TApiOp.Body(C: TModelClass): TApiOp;
begin
  FBody := C;
  Result := Self;
end;

function TApiOp.Returns(C: TModelClass; AStatus: Integer): TApiOp;
begin
  FReturns := C;
  FList := False;
  FOkStatus := AStatus;
  Result := Self;
end;

function TApiOp.ReturnsList(C: TModelClass): TApiOp;
begin
  FReturns := C;
  FList := True;
  FOkStatus := 200;
  Result := Self;
end;

function TApiOp.NoContent: TApiOp;
begin
  FReturns := nil;
  FList := False;
  FOkStatus := 204;
  Result := Self;
end;

function TApiOp.Answers(Code: Integer; const Text_: string): TApiOp;
begin
  SetLength(FExtra, Length(FExtra) + 1);
  FExtra[High(FExtra)].Code := Code;
  FExtra[High(FExtra)].Text := Text_;
  Result := Self;
end;

function TApiOp.Secured(const Scope: string): TApiOp;
begin
  FSecured := True;
  FScope := Scope;
  Result := Self;
end;

{ ---------------------------------------------------------- document -- }

constructor TOpenApi.Create;
begin
  inherited Create;
  FOps := TList.Create;
  FVersion := '1.0.0';
end;

destructor TOpenApi.Destroy;
var
  I: Integer;
begin
  for I := 0 to FOps.Count - 1 do
    TApiOp(FOps[I]).Free;
  FOps.Free;
  inherited Destroy;
end;

function TOpenApi.GetOpCount: Integer;
begin
  Result := FOps.Count;
end;

function TOpenApi.Title(const S: string): TOpenApi;
begin
  FTitle := S;
  Result := Self;
end;

function TOpenApi.Version(const S: string): TOpenApi;
begin
  FVersion := S;
  Result := Self;
end;

function TOpenApi.Description(const S: string): TOpenApi;
begin
  FDescription := S;
  Result := Self;
end;

function TOpenApi.Covers(const Prefix: string): TOpenApi;
begin
  Result := Self;
  if Prefix = '' then
    Exit;
  SetLength(FCovers, Length(FCovers) + 1);
  FCovers[High(FCovers)] := Prefix;
end;

function TOpenApi.Operation(M: THttpMethod; const Path_: string): TApiOp;
begin
  if (Path_ = '') or (Path_[1] <> '/') then
    raise EOpenApiError.CreateFmt(
      'An operation path starts with a slash and is written exactly as ' +
      'the route is: %s', [Path_]);
  Result := TApiOp.Create(M, Path_);
  FOps.Add(Result);
end;

function TOpenApi.Get(const Path_: string): TApiOp;
begin
  Result := Operation(hmGet, Path_);
end;

function TOpenApi.Post(const Path_: string): TApiOp;
begin
  Result := Operation(hmPost, Path_);
end;

function TOpenApi.Put(const Path_: string): TApiOp;
begin
  Result := Operation(hmPut, Path_);
end;

function TOpenApi.Patch(const Path_: string): TApiOp;
begin
  Result := Operation(hmPatch, Path_);
end;

function TOpenApi.Delete(const Path_: string): TApiOp;
begin
  Result := Operation(hmDelete, Path_);
end;

function TOpenApi.ModelIndex(C: TModelClass): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FModels) do
    if FModels[I] = C then
      Exit(I);
  Result := -1;
end;

procedure TOpenApi.Collect(C: TModelClass);
begin
  if (C = nil) or (ModelIndex(C) >= 0) then
    Exit;
  SetLength(FModels, Length(FModels) + 1);
  FModels[High(FModels)] := C;
end;

function TOpenApi.IsCovered(const Path_: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FCovers) do
    if (FCovers[I] = '/') or (Copy(Path_, 1, Length(FCovers[I])) = FCovers[I]) then
      Exit(True);
  Result := False;
end;

{ ------------------------------------------------------------- drift -- }

function TOpenApi.Problems(R: TRouter): TStringArray;
var
  I, J: Integer;
  Op: TApiOp;
  Rt: TRoute;
  Found: Boolean;

  procedure Say(const S: string);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := S;
  end;

begin
  Result := nil;
  if R = nil then
  begin
    Say('There is no router to compare against.');
    Exit;
  end;

  if Length(FCovers) = 0 then
    Say('Nothing says which paths are the API. Call Covers(''/api''), ' +
      'or Covers(''/'') when the whole site is. Without it only half the ' +
      'check can run: a described path is verified, but a route nobody ' +
      'described goes unnoticed.');

  if Trim(FTitle) = '' then
    Say('The document has no title.');

  { Every described path is a route that exists. }
  for I := 0 to FOps.Count - 1 do
  begin
    Op := TApiOp(FOps[I]);
    Found := False;
    for J := 0 to R.Count - 1 do
    begin
      Rt := R.RouteAt(J);
      if (Rt.Method = Op.Method) and (Rt.Pattern = Op.Path) then
      begin
        Found := True;
        Break;
      end;
    end;
    if not Found then
      Say(Format('%s %s is described but is not a route.',
        [Askr.Http.Types.MethodName(Op.Method), Op.Path]));
  end;

  { And every route under a covered prefix is described. }
  for J := 0 to R.Count - 1 do
  begin
    Rt := R.RouteAt(J);
    if not IsCovered(Rt.Pattern) then
      Continue;
    { The document itself, and anything the framework answers. }
    if Rt.Pattern = '/openapi.json' then
      Continue;
    if Pos('*', Rt.Pattern) > 0 then
    begin
      Say(Format('%s %s catches the rest of the path, and OpenAPI has no ' +
        'way to say that. Move it out of the covered paths, or describe ' +
        'the routes it stands for.',
        [Askr.Http.Types.MethodName(Rt.Method), Rt.Pattern]));
      Continue;
    end;
    Found := False;
    for I := 0 to FOps.Count - 1 do
    begin
      Op := TApiOp(FOps[I]);
      if (Op.Method = Rt.Method) and (Op.Path = Rt.Pattern) then
      begin
        Found := True;
        Break;
      end;
    end;
    if not Found then
      Say(Format('%s %s is a route under a covered path and nothing ' +
        'describes it.',
        [Askr.Http.Types.MethodName(Rt.Method), Rt.Pattern]));
  end;
end;

{ -------------------------------------------------------------- json -- }

{ TCustomer becomes Customer. The leading T is a Pascal convention and
  means nothing to whoever reads the document. }
function ModelName(C: TModelClass): string;
begin
  Result := C.ClassName;
  if (Length(Result) > 1) and (Result[1] = 'T') then
    System.Delete(Result, 1, 1);
end;

(* /customers/:id becomes /customers/{id} in OpenAPI's spelling. The
   braces are why this comment is in the star form: one inside a Pascal
   comment opens a nested comment. *)
function OpenApiPath(const Pattern: string): string;
var
  I: Integer;
  Seg: string;
  Parts: TStringList;
begin
  Result := '';
  Parts := TStringList.Create;
  try
    Parts.Delimiter := '/';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := Copy(Pattern, 2, MaxInt);
    for I := 0 to Parts.Count - 1 do
    begin
      Seg := Parts[I];
      if Seg = '' then
        Continue;
      if Seg[1] = ':' then
        Result := Result + '/{' + Copy(Seg, 2, MaxInt) + '}'
      else
        Result := Result + '/' + Seg;
    end;
  finally
    Parts.Free;
  end;
  if Result = '' then
    Result := '/';
end;

{ The parameter names in a pattern, in order. }
function PathParams(const Pattern: string): TStringArray;
var
  I: Integer;
  Seg: string;
  Parts: TStringList;
begin
  Result := nil;
  Parts := TStringList.Create;
  try
    Parts.Delimiter := '/';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := Copy(Pattern, 2, MaxInt);
    for I := 0 to Parts.Count - 1 do
    begin
      Seg := Parts[I];
      if (Seg <> '') and (Seg[1] = ':') then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Copy(Seg, 2, MaxInt);
      end;
    end;
  finally
    Parts.Free;
  end;
end;

{ What the serialiser actually puts on the wire for this kind of column.

  Not what would be nicest: a TDateTime goes out through DateTimeToSql,
  which writes `2026-09-22 13:00:00` -- a space instead of a T, and no
  zone. That is not RFC 3339, so it is **not** declared as
  `format: date-time`. A generated client that believed that would build
  a date parser that fails on every row. The form is described in words
  instead, which is true. }
procedure WriteKindSchema(var W: TJsonWriter; Kind: TColumnKind;
  ReadOnly_: Boolean = False);
begin
  W.BeginObject;
  if ReadOnly_ then
    W.Field('readOnly', True);
  case Kind of
    ckInteger:
      begin
        W.Field('type', 'integer');
        W.Field('format', 'int64');
      end;
    ckString:
      W.Field('type', 'string');
    ckCurrency:
      begin
        W.Field('type', 'number');
        { Currency is an Int64 scaled by 10000, and that is exactly what
          comes out. }
        W.Key('multipleOf');
        W.Raw(Askr.Core.Text.Str('0.0001'));
      end;
    ckFloat:
      W.Field('type', 'number');
    ckBoolean:
      W.Field('type', 'boolean');
    ckDateTime:
      begin
        { null as well: an unset date goes out as null, and a model
          cannot say which of its dates are never unset. }
        W.Key('type');
        W.Raw(Askr.Core.Text.Str('["string","null"]'));
        W.Field('example', '2026-09-22 13:00:00');
        W.Field('description',
          'Date and time as YYYY-MM-DD HH:MM:SS, or null when it is not ' +
          'set. Not RFC 3339: there is no T between date and time, and ' +
          'no time zone.');
      end;
    ckEnum:
      begin
        W.Field('type', 'integer');
        W.Field('description', 'The ordinal of an enumeration.');
      end;
  end;
  W.EndObject;
end;

{ The columns of a model, as they go out (Outgoing) or as they may come
  in (not Outgoing).

  Outgoing: every column that is not hidden, and all of them are always
  there -- WriteColumn writes a value for each, so none of them is ever
  absent and none is ever null.

  Incoming: the insertable ones, which leaves out a generated primary
  key. There is no `required` list: which fields an application insists
  on lives in TModel.Rules, and that is code that runs rather than a
  declaration that can be read. Guessing at it would be the one thing
  this unit exists not to do. }
procedure WriteModelSchema(var W: TJsonWriter; C: TModelClass;
  Outgoing: Boolean);
var
  Meta: TModelMeta;
  I: Integer;
  Col: TColumnInfo;
  Any: Boolean;
begin
  Meta := C.Meta;
  W.BeginObject;
  W.Field('type', 'object');
  W.Field('title', ModelName(C));
  W.Key('properties');
  W.BeginObject;
  for I := 0 to Meta.ColumnCount - 1 do
  begin
    Col := Meta.Columns[I];
    { The same check the serialiser makes, from the same place. A column
      that never leaves the process is not in the document either. }
    if Meta.IsHidden(Col.ColumnName) then
      Continue;
    { A request carries only what FillInto fills, which is not the
      columns the model sets itself -- the key, the timestamps, deleted_at.
      Going out they are there, marked readOnly. Before this the request
      body listed created_at, and a client that believed it set nothing. }
    if not Outgoing and (not Col.Insertable or Meta.IsManaged(Col.ColumnName)) then
      Continue;
    W.Key(Col.ColumnName);
    if Outgoing and Meta.IsManaged(Col.ColumnName) then
      WriteKindSchema(W, Col.Kind, True)
    else
      WriteKindSchema(W, Col.Kind);
  end;
  W.EndObject;

  if Outgoing then
  begin
    Any := False;
    for I := 0 to Meta.ColumnCount - 1 do
      if not Meta.IsHidden(Meta.Columns[I].ColumnName) then
        Any := True;
    if Any then
    begin
      W.Key('required');
      W.BeginArray;
      for I := 0 to Meta.ColumnCount - 1 do
        if not Meta.IsHidden(Meta.Columns[I].ColumnName) then
          W.Str(Meta.Columns[I].ColumnName);
      W.EndArray;
    end;
  end;
  W.EndObject;
end;

{ The envelope TGrid.ListResponse writes. }
procedure WriteListSchema(var W: TJsonWriter; const ItemRef: string);
begin
  W.BeginObject;
  W.Field('type', 'object');
  W.Key('properties');
  W.BeginObject;

  W.Key('data');
  W.BeginObject;
  W.Field('type', 'array');
  W.Field('description', 'Always an array. Empty when nothing matched.');
  W.Key('items');
  W.BeginObject;
  W.Field('$ref', ItemRef);
  W.EndObject;
  W.EndObject;

  W.Key('meta');
  W.BeginObject;
  W.Field('type', 'object');
  W.Key('properties');
  W.BeginObject;
  W.Key('page');   W.BeginObject; W.Field('type', 'integer'); W.EndObject;
  W.Key('per');    W.BeginObject; W.Field('type', 'integer'); W.EndObject;
  W.Key('total');  W.BeginObject; W.Field('type', 'integer'); W.EndObject;
  W.Key('pages');  W.BeginObject; W.Field('type', 'integer'); W.EndObject;
  W.Key('sort');   W.BeginObject; W.Field('type', 'string'); W.EndObject;
  W.Key('dir');    W.BeginObject; W.Field('type', 'string'); W.EndObject;
  W.Key('q');      W.BeginObject; W.Field('type', 'string'); W.EndObject;
  W.EndObject;
  W.EndObject;

  W.Key('links');
  W.BeginObject;
  W.Field('type', 'object');
  W.Field('description',
    'Relative paths with the query string carried forward and only page ' +
    'replaced. Null at the ends.');
  W.Key('properties');
  W.BeginObject;
  W.Key('prev');
  W.BeginObject;
  W.Field('type', 'string');
  W.EndObject;
  W.Key('next');
  W.BeginObject;
  W.Field('type', 'string');
  W.EndObject;
  W.EndObject;
  W.EndObject;

  W.EndObject;
  W.EndObject;
end;

{ RFC 9457, which is what every error here is. }
procedure WriteProblemSchema(var W: TJsonWriter);
begin
  W.BeginObject;
  W.Field('type', 'object');
  W.Field('title', 'Problem');
  W.Field('description',
    'RFC 9457, served as application/problem+json. The detail never ' +
    'carries an exception message.');
  W.Key('properties');
  W.BeginObject;
  W.Key('type');   W.BeginObject; W.Field('type', 'string'); W.EndObject;
  W.Key('title');  W.BeginObject; W.Field('type', 'string'); W.EndObject;
  W.Key('status'); W.BeginObject; W.Field('type', 'integer'); W.EndObject;
  W.Key('detail'); W.BeginObject; W.Field('type', 'string'); W.EndObject;
  W.Key('errors');
  W.BeginObject;
  W.Field('type', 'object');
  W.Field('description',
    'On a 422 only: the field that failed, keyed on the column name, ' +
    'and what was wrong with it.');
  W.Key('additionalProperties');
  W.BeginObject;
  W.Field('type', 'string');
  W.EndObject;
  W.EndObject;
  W.EndObject;
  W.Key('required');
  W.BeginArray;
  W.Str('type');
  W.Str('title');
  W.Str('status');
  W.EndArray;
  W.EndObject;
end;

procedure WriteProblemResponse(var W: TJsonWriter; const Desc: string);
begin
  W.BeginObject;
  W.Field('description', Desc);
  W.Key('content');
  W.BeginObject;
  W.Key('application/problem+json');
  W.BeginObject;
  W.Key('schema');
  W.BeginObject;
  W.Field('$ref', '#/components/schemas/Problem');
  W.EndObject;
  W.EndObject;
  W.EndObject;
  W.EndObject;
end;

{ The kind of a named column, when the model has one by that name. Used
  to type a path parameter: an id in a path is whatever id is on the
  model this operation is about. }
function ColumnKindOf(C: TModelClass; const Name_: string;
  out Kind: TColumnKind): Boolean;
var
  Meta: TModelMeta;
  I: Integer;
begin
  Result := False;
  if C = nil then
    Exit;
  Meta := C.Meta;
  I := Meta.IndexOfColumn(Name_);
  if I < 0 then
    Exit;
  Kind := Meta.Columns[I].Kind;
  Result := True;
end;

procedure WriteQueryParam(var W: TJsonWriter; const Name_, Desc, Typ: string);
begin
  W.BeginObject;
  W.Field('name', Name_);
  W.Field('in', 'query');
  W.Field('required', False);
  W.Field('description', Desc);
  W.Key('schema');
  W.BeginObject;
  W.Field('type', Typ);
  W.EndObject;
  W.EndObject;
end;

{ The last segment of a path that is not a parameter. }
function LastPlainSegment(const Pattern: string): string;
var
  Parts: TStringList;
  I: Integer;
begin
  Result := '';
  Parts := TStringList.Create;
  try
    Parts.Delimiter := '/';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := Copy(Pattern, 2, MaxInt);
    for I := 0 to Parts.Count - 1 do
      if (Parts[I] <> '') and (Parts[I][1] <> ':') and (Parts[I][1] <> '*') then
        Result := Parts[I];
  finally
    Parts.Free;
  end;
end;

function OperationId(Op: TApiOp): string;
var
  I: Integer;
  C: Char;
begin
  Result := LowerCase(Askr.Http.Types.MethodName(Op.Method));
  for I := 1 to Length(Op.Path) do
  begin
    C := Op.Path[I];
    if ((C >= 'a') and (C <= 'z')) or ((C >= 'A') and (C <= 'Z')) or
       ((C >= '0') and (C <= '9')) then
      Result := Result + C
    else if (Result <> '') and (Result[Length(Result)] <> '_') then
      Result := Result + '_';
  end;
  while (Result <> '') and (Result[Length(Result)] = '_') do
    System.Delete(Result, Length(Result), 1);
end;

procedure WriteOperation(var W: TJsonWriter; Op: TApiOp);
var
  Params: TStringArray;
  I: Integer;
  Kind: TColumnKind;
  Tag_: string;
begin
  W.BeginObject;
  if Op.FSummary <> '' then
    W.Field('summary', Op.FSummary);
  W.Field('operationId', OperationId(Op));

  Tag_ := Op.FTag;
  if Tag_ = '' then
    { The last plain segment in the path. /api/customers and
      /api/customers/:id both group under "customers", which is what
      whoever wrote the paths already said. }
    Tag_ := LastPlainSegment(Op.Path);
  if Tag_ <> '' then
  begin
    W.Key('tags');
    W.BeginArray;
    W.Str(Tag_);
    W.EndArray;
  end;

  Params := PathParams(Op.Path);
  if (Length(Params) > 0) or Op.FList then
  begin
    W.Key('parameters');
    W.BeginArray;
    for I := 0 to High(Params) do
    begin
      W.BeginObject;
      W.Field('name', Params[I]);
      W.Field('in', 'path');
      W.Field('required', True);
      W.Key('schema');
      if ColumnKindOf(Op.FReturns, Params[I], Kind) or
         ColumnKindOf(Op.FBody, Params[I], Kind) then
        WriteKindSchema(W, Kind)
      else
      begin
        W.BeginObject;
        W.Field('type', 'string');
        W.EndObject;
      end;
      W.EndObject;
    end;
    if Op.FList then
    begin
      { Exactly what TGrid.Read reads, and nothing else. }
      WriteQueryParam(W, 'page', 'Which page, from 1.', 'integer');
      WriteQueryParam(W, 'per', 'Rows per page, up to the cap the ' +
        'application set.', 'integer');
      WriteQueryParam(W, 'sort', 'A column the application marked ' +
        'sortable. An unknown one falls back to the default.', 'string');
      WriteQueryParam(W, 'dir', 'asc or desc.', 'string');
      WriteQueryParam(W, 'q', 'Free text over the searchable columns.',
        'string');
    end;
    W.EndArray;
  end;

  if Op.FBody <> nil then
  begin
    W.Key('requestBody');
    W.BeginObject;
    W.Field('required', True);
    W.Key('content');
    W.BeginObject;
    W.Key('application/json');
    W.BeginObject;
    W.Key('schema');
    W.BeginObject;
    W.Field('$ref', '#/components/schemas/' + ModelName(Op.FBody) + 'Input');
    W.EndObject;
    W.EndObject;
    W.EndObject;
    W.EndObject;
  end;

  W.Key('responses');
  W.BeginObject;

  W.Key(IntToStr(Op.FOkStatus));
  W.BeginObject;
  W.Field('description', StatusText(Op.FOkStatus));
  if Op.FReturns <> nil then
  begin
    W.Key('content');
    W.BeginObject;
    W.Key('application/json');
    W.BeginObject;
    W.Key('schema');
    W.BeginObject;
    if Op.FList then
      W.Field('$ref', '#/components/schemas/' + ModelName(Op.FReturns) + 'List')
    else
      W.Field('$ref', '#/components/schemas/' + ModelName(Op.FReturns));
    W.EndObject;
    W.EndObject;
    W.EndObject;
  end;
  W.EndObject;

  for I := 0 to High(Op.FExtra) do
  begin
    W.Key(IntToStr(Op.FExtra[I].Code));
    WriteProblemResponse(W, Op.FExtra[I].Text);
  end;

  { The ones the framework answers by itself, and only when it does. }
  if Op.FSecured then
  begin
    W.Key('401');
    WriteProblemResponse(W, 'No token, or one that is not valid.');
    if Op.FScope <> '' then
    begin
      W.Key('403');
      WriteProblemResponse(W,
        'The token is valid but does not carry the scope ' + Op.FScope + '.');
    end;
  end;
  if Length(Params) > 0 then
  begin
    W.Key('404');
    WriteProblemResponse(W, 'No such thing.');
  end;
  if Op.FBody <> nil then
  begin
    W.Key('422');
    WriteProblemResponse(W,
      'The body did not validate. The errors member is keyed on the ' +
      'column name.');
  end;
  if RateLimit.Enabled then
  begin
    W.Key('429');
    WriteProblemResponse(W,
      'Over the rate limit. Retry-After says how long to wait.');
  end;
  W.EndObject;

  if Op.FSecured then
  begin
    W.Key('security');
    W.BeginArray;
    W.BeginObject;
    W.Key('bearerAuth');
    W.BeginArray;
    if Op.FScope <> '' then
      W.Str(Op.FScope);
    W.EndArray;
    W.EndObject;
    W.EndArray;
  end;

  W.EndObject;
end;

function TOpenApi.ToJson: string;
var
  A: TArena;
  W: TJsonWriter;
  I, J: Integer;
  Op: TApiOp;
  Paths: TStringList;
  Path_, Origin: string;
  AnySecured: Boolean;
begin
  for I := 0 to FOps.Count - 1 do
  begin
    Op := TApiOp(FOps[I]);
    Collect(Op.FReturns);
    Collect(Op.FBody);
  end;

  A := TArena.Create(64 * 1024);
  Paths := TStringList.Create;
  try
    Paths.Duplicates := dupIgnore;
    Paths.Sorted := False;
    for I := 0 to FOps.Count - 1 do
    begin
      Path_ := OpenApiPath(TApiOp(FOps[I]).Path);
      if Paths.IndexOf(Path_) < 0 then
        Paths.Add(Path_);
    end;

    W.Init(A, 16 * 1024);
    W.BeginObject;
    W.Field('openapi', '3.1.0');

    W.Key('info');
    W.BeginObject;
    W.Field('title', FTitle);
    W.Field('version', FVersion);
    if FDescription <> '' then
      W.Field('description', FDescription);
    W.EndObject;

    { Only when there is somewhere truthful to get an origin from.
      app.url, never the request -- the same rule as the sitemap, and the
      whole argument in Askr.Core.Url. }
    Origin := AppUrl;
    if Origin <> '' then
    begin
      W.Key('servers');
      W.BeginArray;
      W.BeginObject;
      W.Field('url', Origin);
      W.EndObject;
      W.EndArray;
    end;

    W.Key('paths');
    W.BeginObject;
    for I := 0 to Paths.Count - 1 do
    begin
      W.Key(Paths[I]);
      W.BeginObject;
      for J := 0 to FOps.Count - 1 do
      begin
        Op := TApiOp(FOps[J]);
        if OpenApiPath(Op.Path) <> Paths[I] then
          Continue;
        W.Key(LowerCase(Askr.Http.Types.MethodName(Op.Method)));
        WriteOperation(W, Op);
      end;
      W.EndObject;
    end;
    W.EndObject;

    AnySecured := False;
    for I := 0 to FOps.Count - 1 do
      if TApiOp(FOps[I]).FSecured then
        AnySecured := True;

    W.Key('components');
    W.BeginObject;
    W.Key('schemas');
    W.BeginObject;
    W.Key('Problem');
    WriteProblemSchema(W);
    for I := 0 to High(FModels) do
    begin
      W.Key(ModelName(FModels[I]));
      WriteModelSchema(W, FModels[I], True);
    end;
    { The input shape is a different schema from the output shape: a
      request never fills a generated primary key. }
    for I := 0 to FOps.Count - 1 do
    begin
      Op := TApiOp(FOps[I]);
      if (Op.FBody <> nil) and
         (ModelIndex(Op.FBody) >= 0) then
      begin
        W.Key(ModelName(Op.FBody) + 'Input');
        WriteModelSchema(W, Op.FBody, False);
      end;
    end;
    for I := 0 to FOps.Count - 1 do
    begin
      Op := TApiOp(FOps[I]);
      if Op.FList and (Op.FReturns <> nil) then
      begin
        W.Key(ModelName(Op.FReturns) + 'List');
        WriteListSchema(W, '#/components/schemas/' + ModelName(Op.FReturns));
      end;
    end;
    W.EndObject;

    if AnySecured then
    begin
      W.Key('securitySchemes');
      W.BeginObject;
      W.Key('bearerAuth');
      W.BeginObject;
      W.Field('type', 'http');
      W.Field('scheme', 'bearer');
      W.Field('description',
        'An Askr API token: Authorization: Bearer askr_...');
      W.EndObject;
      W.EndObject;
    end;
    W.EndObject;

    W.EndObject;
    Result := W.ToString;
  finally
    Paths.Free;
    A.Free;
  end;
end;

{ ------------------------------------------------------------- routes -- }

function BuildApiDoc: TOpenApi;
begin
  if not Assigned(GSource) then
    raise EOpenApiError.Create(
      'Nothing has described this API. Write a TApiDocSource and pass ' +
      'it to UseOpenApi. An empty document would read as "this API has ' +
      'nothing in it", which is a different claim.');
  Result := TOpenApi.Create;
  try
    GSource(Result);
  except
    Result.Free;
    raise;
  end;
end;

function ServeDoc(Req: TRequest): TResponse;
var
  D: TOpenApi;
begin
  D := BuildApiDoc;
  try
    Result := Respond(200)
      .WithContentType('application/json; charset=utf-8')
      .WithBody(D.ToJson);
  finally
    D.Free;
  end;
end;

procedure UseOpenApi(R: TRouter; Source: TApiDocSource);
begin
  if not Assigned(Source) then
    raise EOpenApiError.Create('UseOpenApi needs something to describe.');
  GSource := Source;
  R.Get('/openapi.json', @ServeDoc);
end;


end.
