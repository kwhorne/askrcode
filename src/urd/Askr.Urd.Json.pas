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
  begin
    { A column the model said never leaves.

      One check, because every path funnels here: a model on its own, a
      list, a relation on a parent, and an Inertia prop all end up in
      WriteModel. Putting it at the four call sites instead is how one of
      them ends up shipping the hash. }
    if Meta.IsHidden(Meta.Columns[I].ColumnName) then
      Continue;
    WriteColumn(W, M, Meta.Columns[I]);
  end;

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
  { No list is an empty list, not null.

    A consumer of a list is going to iterate it, and `null` is the one
    value that makes that a crash rather than a no-op -- in JavaScript,
    in Swift, in anything with a type for a list. The two states worth
    telling apart are "here are the rows" and "you did not ask for
    this", and the second is said by leaving the key out, which is
    already the rule for a relation that was never loaded.

    Before this a nil list serialised as `null`, so a list endpoint that
    matched nothing handed its caller something to crash on. }
  if L = nil then
  begin
    W.BeginArray;
    W.EndArray;
    Exit;
  end;
  W.BeginArray;
  for I := 0 to L.Count - 1 do
    WriteModel(W, L.Item(I));
  W.EndArray;
end;

end.
