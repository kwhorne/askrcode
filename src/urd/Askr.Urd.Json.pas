{ Askr.Urd.Json — models to JSON, through the same RTTI Urd maps with.

  A model is serialised with the column names, not the property names.
  That is snake_case in JSON and PascalCase in Pascal, which is the
  convention on both sides and what a Svelte developer expects to see in
  props.

  Loaded relations are nested along, under the same name in snake_case. A
  relation that is not loaded is left out entirely — not set to null. The
  difference matters: null means "no orders", while absence means "did not
  ask". }
unit Askr.Urd.Json;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, TypInfo, Askr.Core.Arena, Askr.Core.Text, Askr.Core.Json,
  Askr.Urd.Driver, Askr.Urd.Model;

{ Writes the model as a JSON object at the current position in W. }
procedure WriteModel(var W: TJsonWriter; M: TModel);
{ Writes the list as a JSON array. }
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
      W.Money(PropAsCurrency(M, Col.Prop));
    ckFloat:
      W.Num(GetFloatProp(M, Col.Prop));
    ckBoolean:
      W.Bool(GetOrdProp(M, Col.Prop) <> 0);
    ckDateTime:
      { ISO 8601, which is what JavaScript understands unaided. }
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
      { Not loaded. Left out, so the frontend can tell it from empty. }
      Continue;
    { The same convention as the columns: snake_case out, PascalCase in.
      The relation is called Orders in Pascal and orders in JSON. }
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
