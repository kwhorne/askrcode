{ Askr.Urd.Bind — fra request til modell.

      C := Req.Arena.New<TCustomer>;
      Req.FillInto(C);

  FillInto er en class helper på TRequest. Det er med vilje: HTTP-laget skal
  ikke kjenne til Urd — desktop-skallet og en ren JSON-tjeneste bruker
  TRequest uten datalag i det hele tatt. Helperen snur avhengigheten riktig
  vei og gir likevel formen PRD-en skriver.

  Tre kilder leses, i denne rekkefølgen: JSON-kropp, skjemakropp
  (application/x-www-form-urlencoded) og query-streng. Bare felter som
  faktisk er sendt røres, slik at en delvis oppdatering ikke nullstiller
  resten.

  Primærnøkkelen fylles aldri fra en request. Det er ikke en bekvemmelighet
  som mangler — det er hele poenget: uten den regelen kan en klient overskrive
  hvilken rad som helst ved å sende med en id. }
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
    { Én verdi, uavhengig av om den kom som JSON, skjema eller query. }
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

{ JSON-kroppen parses én gang per request. Uten dette ville FillInto over
  tjue felter parset den tjue ganger.

  Cachen kan ikke nøkles på request-pekeren alene: arenaen gjenbruker de
  samme adressene, så neste request lander ofte nøyaktig der forrige lå og
  ville arvet cachen. Derfor ryddes den av Arena.Defer ved Reset — som er
  nettopp det den mekanismen finnes til. }
function JsonRoot(Req: TRequest): PJsonValue;
var
  FeilPos: SizeInt;
begin
  if (GJson.Req = Req) and GJson.Parsed then
    Exit(GJson.Root);

  GJson.Req := Req;
  GJson.Root := nil;
  GJson.Parsed := True;
  Req.Arena.Defer(GlemJsonCache, nil);
  if Req.IsJson and (Req.Body.Len > 0) then
    if not JsonParse(Req.Arena, Req.Body, GJson.Root, FeilPos) then
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
