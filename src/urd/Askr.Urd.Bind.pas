{ Askr.Urd.Bind — from request to model.

      C := Req.Arena.New<TCustomer>;
      Req.FillInto(C);

  FillInto is a class helper on TRequest. That is deliberate: the HTTP
  layer must not know about Urd — the desktop shell and a pure JSON
  service use TRequest with no data layer at all. The helper turns the
  dependency the right way round and still gives the form the PRD writes.

  Three sources are read, in this order: the JSON body, the form body
  (application/x-www-form-urlencoded) and the query string. Only fields
  that were actually sent are touched, so a partial update does not clear
  the rest.

  The primary key is never filled from a request. That is not a missing
  convenience — it is the whole point: without that rule a client can
  overwrite any row it likes by sending an id along. }
unit Askr.Urd.Bind;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, TypInfo, Askr.Core.Arena, Askr.Core.Text, Askr.Core.Json,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response,
  Askr.Urd.Driver, Askr.Urd.Model;

type
  TRequestBindHelper = class helper for TRequest
  public
    { Fyller modellens published properties fra requesten. }
    procedure FillInto(M: TModel); overload;
    { Only the columns named, and nothing else the request carries.

        Req.FillInto(C, [Customers.Name.Name, Customers.Email.Name]);

      The one-argument form fills every column the model maps, so a
      client that adds `is_admin` to the body sets it.
      This is the form for a handler that knows which fields its form
      has -- which `askr make resource` always does. A name the model
      does not map raises: skipping it would look like a field that
      saved. }
    procedure FillInto(M: TModel; const Only: array of string); overload;
    { One value, whether it came as JSON, form or query. }
    function Input(const AName: string): TStr;
    function HasInput(const AName: string): Boolean;
    function InputInt(const AName: string; Default: Int64 = 0): Int64;
    function InputBool(const AName: string; Default: Boolean = False): Boolean;
    { The ids a request sent under AName, for a BelongsToMany:

        HasTags := Req.InputIds('tag_ids', TagIds, M.Errors);

      A JSON array -- of numbers, or of numeric strings, as a form library
      may send them -- or form and query fields named `tag_ids[]` or
      `tag_ids`, repeated. False when the key was not sent at all, which
      is a PATCH leaving the relation alone; True with an empty array when
      it was sent empty, which is a form with every box unticked.

      An HTML form sends nothing for no ticked boxes, so it cannot say
      "none" by itself. A hidden `tag_ids[]` with an empty value can: an
      empty entry is left out without complaint, and the key is present.

      An entry that is not a positive whole number is a message on AName
      in Errors, not a list that quietly got shorter. Call it after
      Validate, which starts Errors afresh. }
    function InputIds(const AName: string; out Ids: TArray<Int64>;
      Errors: TErrors): Boolean;
  end;

{ A failed validation, for a client that is not a browser.

      if not C.Validate(Errs) then
        if Req.AcceptsJson then
          Exit(ValidationProblem(Errs))
        else
          Exit(BackWithErrors(Errs));

  422 and a problem document with an `errors` member: field to message,
  the same object BackWithErrors flashes for Inertia. Two shapes for the
  same failure would mean two things to write, and one of them would go
  stale.

  **The fields are keyed on the column name**, because TErrors is -- rules
  are written with the property name, errors come back keyed on the
  column. That is the existing rule and this does not change it: a client
  posting `released_on` should be told which field it got wrong in the
  name it used.

  It lives here rather than in Askr.Http.Response for the same reason
  FillInto does: the HTTP layer must not know about Urd. TErrors is a Urd
  type, so the function that turns one into a response belongs on this
  side of the line. }
function ValidationProblem(E: TErrors;
  const Detail: string = 'The request body did not validate.'): TResponse;

implementation

uses
  Askr.Http.Multipart, Askr.Core.Lang;

function ValidationProblem(E: TErrors; const Detail: string): TResponse;
var
  W: TJsonWriter;
begin
  W.Init(CurrentArena, 512);
  BeginProblem(W, 422, Detail);
  W.Key('errors');
  E.WriteJson(W);
  Result := ProblemFrom(W, 422);
end;

type
  TJsonCache = record
    Req: TRequest;
    Root: PJsonValue;
    Parsed: Boolean;
  end;

threadvar
  GJson: TJsonCache;

procedure GlemJsonCache(Data: Pointer);
begin
  GJson.Req := nil;
  GJson.Root := nil;
  GJson.Parsed := False;
end;

{ The JSON body is parsed once per request. Without this, a FillInto
  across twenty fields would parse it twenty times.

  The cache cannot be keyed on the request pointer alone: the arena reuses
  the same addresses, so the next request often lands exactly where the
  previous one was and would inherit the cache. So it is cleared by
  Arena.Defer at Reset — which is precisely what that mechanism is
  for. }
function JsonRoot(Req: TRequest): PJsonValue;
var
  ErrPos: SizeInt;
begin
  if (GJson.Req = Req) and GJson.Parsed then
    Exit(GJson.Root);

  GJson.Req := Req;
  GJson.Root := nil;
  GJson.Parsed := True;
  Req.Arena.Defer(GlemJsonCache, nil);
  if Req.IsJson and (Req.Body.Len > 0) then
    if not JsonParse(Req.Arena, Req.Body, GJson.Root, ErrPos) then
      GJson.Root := nil;
  Result := GJson.Root;
end;

function TRequestBindHelper.HasInput(const AName: string): Boolean;
var
  Root: PJsonValue;
  V: TStr;
begin
  Root := JsonRoot(Self);
  if Root <> nil then
    if JsonMember(Root, AName) <> nil then
      Exit(True);
  if ContentType.StartsWithStr('application/x-www-form-urlencoded') then
    if QueryValue(Arena, Body, AName, V) then
      Exit(True);
  Result := QueryValue(Arena, QueryString, AName, V);
end;

function TRequestBindHelper.Input(const AName: string): TStr;
var
  Root: PJsonValue;
  M: PJsonValue;
  V: TStr;
begin
  Root := JsonRoot(Self);
  if Root <> nil then
  begin
    M := JsonMember(Root, AName);
    if M <> nil then
      Exit(JsonAsStr(M));
  end;
  if ContentType.StartsWithStr('application/x-www-form-urlencoded') then
    if QueryValue(Arena, Body, AName, V) then
      Exit(V);
  if QueryValue(Arena, QueryString, AName, V) then
    Exit(V);
  Result := StrEmpty;
end;

function TRequestBindHelper.InputInt(const AName: string; Default: Int64): Int64;
begin
  Result := Input(AName).ToIntDef(Default);
end;

function TRequestBindHelper.InputBool(const AName: string;
  Default: Boolean): Boolean;
var
  Root, M: PJsonValue;
  S: TStr;
begin
  Root := JsonRoot(Self);
  if Root <> nil then
  begin
    M := JsonMember(Root, AName);
    if M <> nil then
      Exit(JsonAsBool(M, Default));
  end;
  S := Input(AName);
  if S.Len = 0 then
    Exit(Default);
  if not SqlToBool(S, Result) then
    Result := Default;
end;

procedure FillColumns(Req: TRequest; M: TModel; const Only: array of string;
  UseOnly: Boolean);
var
  Meta: TModelMeta;
  I, J, PkIdx: Integer;
  Found: Boolean;
  Col: TColumnInfo;
  S: TStr;
  I64: Int64;
  Cur: Currency;
  Dbl: Double;
  Dt: TDateTime;
begin
  if M = nil then
    Exit;
  Meta := M.Meta;
  PkIdx := Meta.PrimaryKeyIndex;

  for J := 0 to High(Only) do
  begin
    if Meta.IndexOfColumn(Only[J]) < 0 then
      raise EModelError.CreateFmt(
        'FillInto was told to fill %s, and %s maps no column of that name.',
        [Only[J], M.ClassName]);
    if Meta.IsManaged(Only[J]) then
      raise EModelError.CreateFmt(
        'FillInto was told to fill %s, which %s sets itself. A request ' +
        'never does, so it is not filled from one.', [Only[J], M.ClassName]);
  end;

  for I := 0 to Meta.ColumnCount - 1 do
  begin
    if I = PkIdx then
      Continue;
    Col := Meta.Columns[I];
    { created_at, updated_at and deleted_at are the model's, like the
      key: a client that added created_at to the body used to set it,
      and the one-argument form is what most handlers call. }
    if Meta.IsManaged(Col.ColumnName) then
      Continue;
    if UseOnly then
    begin
      Found := False;
      for J := 0 to High(Only) do
        if Only[J] = Col.ColumnName then
          Found := True;
      if not Found then
        Continue;
    end;
    if not Req.HasInput(Col.ColumnName) then
      Continue;

    case Col.Kind of
      ckBoolean:
        SetOrdProp(M, Col.Prop,
          Ord(Req.InputBool(Col.ColumnName, GetOrdProp(M, Col.Prop) <> 0)));
      ckString:
        SetStrProp(M, Col.Prop, Req.Input(Col.ColumnName).ToString);
      ckInteger:
        begin
          S := Req.Input(Col.ColumnName);
          if SqlToInt64(S, I64) then
            SetInt64Prop(M, Col.Prop, I64)
          else if S.Len = 0 then
            SetInt64Prop(M, Col.Prop, 0);
        end;
      ckCurrency:
        begin
          S := Req.Input(Col.ColumnName);
          if SqlToCurrency(S, Cur) then
            SetFloatProp(M, Col.Prop, Cur)
          else if S.Len = 0 then
            SetFloatProp(M, Col.Prop, 0);
        end;
      ckFloat:
        begin
          S := Req.Input(Col.ColumnName);
          if SqlToFloat(S, Dbl) then
            SetFloatProp(M, Col.Prop, Dbl)
          else if S.Len = 0 then
            SetFloatProp(M, Col.Prop, 0);
        end;
      ckDateTime:
        begin
          S := Req.Input(Col.ColumnName);
          if SqlToDateTime(S, Dt) then
            SetFloatProp(M, Col.Prop, Dt)
          else if S.Len = 0 then
            SetFloatProp(M, Col.Prop, 0);
        end;
      ckEnum:
        begin
          S := Req.Input(Col.ColumnName);
          if SqlToInt64(S, I64) then
            SetOrdProp(M, Col.Prop, LongInt(I64));
        end;
    end;
  end;
end;

{ The raw values under AName or AName[] in an urlencoded string, in the
  order sent. }
procedure CollectUrlEncoded(A: TArena; const Source: TStr; const AName: string;
  var Found: Boolean; var Raw: TStringArray);
var
  Rest, Pair, K, V: TStr;
  Key: string;
begin
  Rest := Source;
  while Rest.Len > 0 do
  begin
    Rest.SplitAt(Ord('&'), Pair, Rest);
    if Pair.Len = 0 then
      Continue;
    if not Pair.SplitAt(Ord('='), K, V) then
      V := StrEmpty;
    Key := UrlDecode(A, K, True).ToString;
    if (Key = AName) or (Key = AName + '[]') then
    begin
      Found := True;
      SetLength(Raw, Length(Raw) + 1);
      Raw[High(Raw)] := UrlDecode(A, V, True).ToString;
    end;
  end;
end;

{ A JSON value as the message names it: a scalar quoted as sent, anything
  else by what it is -- an empty string for an object would be a message
  that says nothing. }
function JsonShown(V: PJsonValue): string;
begin
  case V^.Kind of
    jkString, jkNumber: Result := '"' + V^.Text.ToString + '"';
    jkBool: if V^.BoolValue then Result := 'true' else Result := 'false';
    jkNull: Result := 'null';
    jkArray: Result := 'a list';
    jkObject: Result := 'an object';
  end;
end;

function TRequestBindHelper.InputIds(const AName: string;
  out Ids: TArray<Int64>; Errors: TErrors): Boolean;
var
  Root, V, E: PJsonValue;
  Raw: TStringArray;
  Found: Boolean;
  I, N: Integer;
  Id: Int64;
  Bad: string;
  Out_: TArray<Int64>;
  F: PMultipartField;
begin
  if Errors = nil then
    raise EValidationError.Create(
      'InputIds needs the errors to add to: pass M.Errors, after Validate');
  Ids := nil;
  Raw := nil;
  Found := False;
  Bad := '';

  Root := JsonRoot(Self);
  if Root <> nil then
  begin
    V := JsonMember(Root, AName);
    if V <> nil then
    begin
      Found := True;
      if V^.Kind <> jkArray then
        Bad := JsonShown(V)
      else
      begin
        E := V^.First;
        while E <> nil do
        begin
          if E^.Kind in [jkNumber, jkString] then
          begin
            SetLength(Raw, Length(Raw) + 1);
            Raw[High(Raw)] := E^.Text.ToString;
          end
          else if Bad = '' then
            Bad := JsonShown(E);
          E := E^.Next;
        end;
      end;
    end;
  end;

  if not Found then
  begin
    if IsMultipart then
    begin
      for I := 0 to Multipart.FieldCount - 1 do
      begin
        F := Multipart.FieldAt(I);
        if F^.Name.EqualsStr(AName) or F^.Name.EqualsStr(AName + '[]') then
        begin
          Found := True;
          SetLength(Raw, Length(Raw) + 1);
          Raw[High(Raw)] := F^.Value.ToString;
        end;
      end;
    end
    else if ContentType.StartsWithStr('application/x-www-form-urlencoded') then
      CollectUrlEncoded(Arena, Body, AName, Found, Raw);
  end;
  if not Found then
    CollectUrlEncoded(Arena, QueryString, AName, Found, Raw);

  SetLength(Out_, Length(Raw));
  N := 0;
  for I := 0 to High(Raw) do
  begin
    if Raw[I] = '' then
      Continue;
    if TryStrToInt64(Raw[I], Id) and (Id > 0) then
    begin
      Out_[N] := Id;
      Inc(N);
    end
    else if Bad = '' then
      Bad := '"' + Raw[I] + '"';
  end;
  SetLength(Out_, N);
  Ids := Out_;

  if Bad <> '' then
    Errors.Add(AName, Trans('validation.ids_list', ['attribute', AttributeName(AName),
      'value', Bad]));
  Result := Found;
end;

procedure TRequestBindHelper.FillInto(M: TModel);
begin
  FillColumns(Self, M, [], False);
end;

procedure TRequestBindHelper.FillInto(M: TModel; const Only: array of string);
begin
  FillColumns(Self, M, Only, True);
end;


end.
