{ Askr.Urd.Json — modeller til JSON, via den samme RTTI-en Urd mapper med.

  En modell serialiseres med kolonnenavnene, ikke property-navnene. Det er
  snake_case i JSON og PascalCase i Pascal, som er konvensjonen på begge
  sider og det en Svelte-utvikler forventer å se i props.

  Relasjoner som er lastet blir nøstet med, under samme navn i snake_case. En relasjon som ikke er lastet
  utelates helt — ikke satt til null. Forskjellen er viktig: null betyr «ingen
  ordre», mens fravær betyr «ikke spurt om». }
unit Askr.Urd.Json;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, TypInfo, Askr.Core.Arena, Askr.Core.Text, Askr.Core.Json,
  Askr.Urd.Driver, Askr.Urd.Model;

{ Skriver modellen som et JSON-objekt på gjeldende posisjon i W. }
procedure WriteModel(var W: TJsonWriter; M: TModel);
{ Skriver lista som en JSON-array. }
procedure WriteModelList(var W: TJsonWriter; L: TModelListBase);

implementation

procedure WriteColumn(var W: TJsonWriter; M: TModel; const Col: TColumnInfo);
begin
  W.Key(Col.ColumnName);
  case Col.Kind of
    ckInteger:
      W.Int(GetInt64Prop(M, Col.Prop));
    ckString:
      W.Str(GetStrProp(M, Col.Prop));
    ckCurrency:
      W.Money(Currency(GetFloatProp(M, Col.Prop)));
    ckFloat:
      W.Num(GetFloatProp(M, Col.Prop));
    ckBoolean:
      W.Bool(GetOrdProp(M, Col.Prop) <> 0);
    ckDateTime:
      { ISO 8601, som er det JavaScript forstår uten hjelp. }
      W.Str(DateTimeToSql(GetFloatProp(M, Col.Prop)));
    ckEnum:
      W.Int(GetOrdProp(M, Col.Prop));
  end;
end;

procedure WriteModel(var W: TJsonWriter; M: TModel);
var
  Meta: TModelMeta;
  I: Integer;
  Rel: TRelationInfo;
  Slot: PPointer;
  Child: TObject;
begin
  if M = nil then
  begin
    W.Null;
    Exit;
  end;

  Meta := M.Meta;
  W.BeginObject;
  for I := 0 to Meta.ColumnCount - 1 do
    WriteColumn(W, M, Meta.Columns[I]);

  for I := 0 to Meta.RelationCount - 1 do
  begin
    Rel := Meta.Relations[I];
    Slot := PPointer(M.FieldAddress(Rel.Name));
    if Slot = nil then
      Continue;
    Child := TObject(Slot^);
    if Child = nil then
      { Ikke lastet. Utelates, slik at frontend kan skille det fra tomt. }
      Continue;
    { Samme konvensjon som kolonnene: snake_case ut, PascalCase inn.
      Relasjonen heter Orders i Pascal og orders i JSON. }
    W.Key(SnakeCase(Rel.Name));
    if Child is TModelListBase then
      WriteModelList(W, TModelListBase(Child))
    else if Child is TModel then
      WriteModel(W, TModel(Child))
    else
      W.Null;
  end;
  W.EndObject;
end;

procedure WriteModelList(var W: TJsonWriter; L: TModelListBase);
var
  I: Integer;
begin
  if L = nil then
  begin
    W.Null;
    Exit;
  end;
  W.BeginArray;
  for I := 0 to L.Count - 1 do
    WriteModel(W, L.Item(I));
  W.EndArray;
end;

end.
