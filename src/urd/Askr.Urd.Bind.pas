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
  Askr.Http.Types, Askr.Http.Request,
  Askr.Urd.Driver, Askr.Urd.Model;

type
  TRequestBindHelper = class helper for TRequest
  public
    { Fyller modellens published properties fra requesten. }
    procedure FillInto(M: TModel);
    { One value, whether it came as JSON, form or query. }
    function Input(const AName: string): TStr;
    function HasInput(const AName: string): Boolean;
    function InputInt(const AName: string; Default: Int64 = 0): Int64;
    function InputBool(const AName: string; Default: Boolean = False): Boolean;
  end;

implementation

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

procedure TRequestBindHelper.FillInto(M: TModel);
var
  Meta: TModelMeta;
  I, PkIdx: Integer;
  Col: TColumnInfo;
  S: TStr;
  I64: Int64;
  Cur: Currency;
  Dbl: Double;
  Dt: TDateTime;
  B: Boolean;
begin
  if M = nil then
    Exit;
  Meta := M.Meta;
  PkIdx := Meta.PrimaryKeyIndex;

  for I := 0 to Meta.ColumnCount - 1 do
  begin
    if I = PkIdx then
      Continue;
    Col := Meta.Columns[I];
    if not HasInput(Col.ColumnName) then
      Continue;

    case Col.Kind of
      ckBoolean:
        SetOrdProp(M, Col.Prop,
          Ord(InputBool(Col.ColumnName, GetOrdProp(M, Col.Prop) <> 0)));
      ckString:
        SetStrProp(M, Col.Prop, Input(Col.ColumnName).ToString);
      ckInteger:
        begin
          S := Input(Col.ColumnName);
          if SqlToInt64(S, I64) then
            SetInt64Prop(M, Col.Prop, I64)
          else if S.Len = 0 then
            SetInt64Prop(M, Col.Prop, 0);
        end;
      ckCurrency:
        begin
          S := Input(Col.ColumnName);
          if SqlToCurrency(S, Cur) then
            SetFloatProp(M, Col.Prop, Cur)
          else if S.Len = 0 then
            SetFloatProp(M, Col.Prop, 0);
        end;
      ckFloat:
        begin
          S := Input(Col.ColumnName);
          if SqlToFloat(S, Dbl) then
            SetFloatProp(M, Col.Prop, Dbl)
          else if S.Len = 0 then
            SetFloatProp(M, Col.Prop, 0);
        end;
      ckDateTime:
        begin
          S := Input(Col.ColumnName);
          if SqlToDateTime(S, Dt) then
            SetFloatProp(M, Col.Prop, Dt)
          else if S.Len = 0 then
            SetFloatProp(M, Col.Prop, 0);
        end;
      ckEnum:
        begin
          S := Input(Col.ColumnName);
          if SqlToInt64(S, I64) then
            SetOrdProp(M, Col.Prop, LongInt(I64));
        end;
    end;
  end;
end;

end.
