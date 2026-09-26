{ Askr.Factory — rows for a test, without writing every column.

      C := TFactory<TCustomer>.Create;
      try
        Ada := C.Values(['name', 'Ada']).Insert;
        Rest := C.InsertMany(3);
        ...
      finally
        C.Free;
      end;

  A factory fills every column a row needs from the model's own mapping,
  with a value that fits the column and is different from the last one --
  so a unique column stays unique across factories and tests. Values
  overrides a column; State runs a procedure of yours on each model, for
  what a column name cannot tell.

  **What it fills, and with what.** A string is its column's name and a
  number -- except where the name says more: an email address for email, a
  link for url, a UUID for uuid, and for password_hash the hash of
  'password', computed once, because a real one takes a noticeable fraction
  of a second each. Integers count, money and floats count by a quarter, a
  boolean is False, a date is today and a datetime now. A column the model
  marks EmptyIsNull or ZeroIsNull is nullable, and stays null; a key to a
  parent is left for Insert. The
  primary key and the columns the model manages -- the timestamps,
  deleted_at -- are left to the model.

  **Parents are made too.** Insert makes a row for each BelongsTo the model
  has, unless the foreign key was given, so a factory for orders does not
  need one for customers first. Make saves nothing and makes no parents.

  **Insert validates.** A row the model's own rules refuse is an error that
  says which, rather than a row no request could have made -- give the
  column a value with Values, or a State.

  **The rows live as long as the arena they were made in**: the one around
  the factory, or, when there is none -- a test often has none -- the
  factory's own, which goes when the factory is freed. A model has to live
  in an arena to be validated and saved. }
unit Askr.Factory;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, Askr.Core.Arena, Askr.Urd.Driver, Askr.Urd.Model;

type
  EFactoryError = class(Exception);

  { N is the model's number, different for every model any factory
    makes. }
  TFactoryState = procedure(M: TModel; N: Int64);
  TModelArray = array of TModel;

  TModelFactory = class
  private
    FModelClass: TModelClass;
    FValues: TStringList;
    FStates: array of TFactoryState;
    FArena: TArena;
    FConn: TDbConnection;
    { The ambient arena, or the factory's own when there is none: a model
      has to live in one to be validated and saved. }
    function EnterArena: TArena;
    function MakeIn: TModel;
    function InsertIn: TModel;
  public
    constructor Create(AClass: TModelClass; AConn: TDbConnection = nil);
    destructor Destroy; override;
    { Column and value in pairs, as Trans takes them: the value for that
      column in every model made from here on. }
    procedure SetValues(const Pairs: array of const);
    procedure AddState(S: TFactoryState);
    { One model, filled, not saved. }
    function MakeModel: TModel;
    { One model, filled, its parents made, validated and saved. }
    function InsertModel: TModel;
    property ModelClass: TModelClass read FModelClass;
  end;

  TFactory<M: TModel> = class(TModelFactory)
  public
    type TItems = array of M;
    constructor Create(AConn: TDbConnection = nil);
    function Values(const Pairs: array of const): TFactory<M>;
    function State(S: TFactoryState): TFactory<M>;
    function Make: M;
    function Insert: M;
    function MakeMany(Count: Integer): TItems;
    function InsertMany(Count: Integer): TItems;
  end;

{ The next number, for every factory in the process. }
function NextFactoryNumber: Int64;
{ What a factory puts in a column it is not told about. Exposed for a
  generic method, which cannot call a routine the unit keeps to itself. }
function SampleFor(M: TModel; const C: TColumnInfo; N: Int64): string;
procedure SetColumnText(M: TModel; const C: TColumnInfo; const Value: string);

implementation

uses
  TypInfo, DateUtils, Askr.Core.Crypto, Askr.Core.Lang;

var
  GNumber: Int64 = 0;
  GPasswordHash: string = '';

function NextFactoryNumber: Int64;
begin
  Result := InterLockedIncrement64(GNumber);
end;

function DotSettings: TFormatSettings;
begin
  Result := DefaultFormatSettings;
  Result.DecimalSeparator := '.';
  Result.ThousandSeparator := #0;
end;

function Has(const Column, Part: string): Boolean;
begin
  Result := Pos(Part, LowerCase(Column)) > 0;
end;

function NewUuid: string;
var
  B: TBytes;
  H: string;
begin
  B := RandomBytes(16);
  B[6] := (B[6] and $0F) or $40;
  B[8] := (B[8] and $3F) or $80;
  H := LowerCase(HexEncode(B));
  Result := Copy(H, 1, 8) + '-' + Copy(H, 9, 4) + '-' + Copy(H, 13, 4) + '-' +
    Copy(H, 17, 4) + '-' + Copy(H, 21, 12);
end;

function SampleFor(M: TModel; const C: TColumnInfo; N: Int64): string;
var
  Col: string;
begin
  Col := C.ColumnName;
  case C.Kind of
    ckString:
      if Has(Col, 'email') then
        Result := Format('user%d@example.test', [N])
      else if Has(Col, 'url') or Has(Col, 'website') or Has(Col, 'link') then
        Result := Format('https://example.test/%d', [N])
      else if Has(Col, 'uuid') then
        Result := NewUuid
      else if SameText(Col, 'password_hash') then
      begin
        { Once: a real hash takes a noticeable part of a second, and a
          test making twenty users should not take seconds for it. }
        if GPasswordHash = '' then
          GPasswordHash := HashPassword('password');
        Result := GPasswordHash;
      end
      else if Has(Col, 'hash') or Has(Col, 'token') then
        Result := RandomHex(16)
      else
        Result := Format('%s %d', [StringReplace(Col, '_', ' ', [rfReplaceAll]), N]);
    ckInteger: Result := IntToStr(N);
    { Small enough for a NUMERIC(12,2), and a quarter so both decimals
      are used. }
    ckCurrency, ckFloat: Result := FloatToStr((N mod 100000) + 0.25, DotSettings);
    ckBoolean: Result := 'false';
    ckDateTime: Result := '';
    ckEnum: Result := '';
  end;
end;

procedure SetColumnText(M: TModel; const C: TColumnInfo; const Value: string);
var
  P: PPropInfo;
  V: Currency;
  D: TDateTime;
begin
  P := C.Prop;
  case C.Kind of
    ckString: SetStrProp(M, P, Value);
    ckInteger:
      if P^.PropType^.Kind in [tkInt64, tkQWord] then
        SetInt64Prop(M, P, StrToInt64(Value))
      else
        SetOrdProp(M, P, StrToInt64(Value));
    ckCurrency:
      begin
        V := StrToCurr(Value, DotSettings);
        SetFloatProp(M, P, V);
      end;
    ckFloat: SetFloatProp(M, P, StrToFloat(Value, DotSettings));
    ckBoolean: SetOrdProp(M, P, Ord(SameText(Value, 'true') or (Value = '1')));
    ckEnum: SetEnumProp(M, P, Value);
    ckDateTime:
      begin
        if Length(Value) >= 19 then
          D := EncodeDateTime(StrToInt(Copy(Value, 1, 4)), StrToInt(Copy(Value, 6, 2)),
            StrToInt(Copy(Value, 9, 2)), StrToInt(Copy(Value, 12, 2)),
            StrToInt(Copy(Value, 15, 2)), StrToInt(Copy(Value, 18, 2)), 0)
        else
          D := EncodeDate(StrToInt(Copy(Value, 1, 4)), StrToInt(Copy(Value, 6, 2)),
            StrToInt(Copy(Value, 9, 2)));
        SetFloatProp(M, P, D);
      end;
  end;
end;

function IsParentKey(Meta: TModelMeta; const Column: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to Meta.RelationCount - 1 do
    if (Meta.Relations[I].Kind = rkBelongsTo) and
       SameText(Meta.Relations[I].ForeignKey, Column) then
      Exit(True);
  Result := False;
end;

function GetOrdOrInt64(M: TModel; P: PPropInfo): Int64;
begin
  if P^.PropType^.Kind in [tkInt64, tkQWord] then
    Result := GetInt64Prop(M, P)
  else
    Result := GetOrdProp(M, P);
end;

{ TModelFactory }

constructor TModelFactory.Create(AClass: TModelClass; AConn: TDbConnection);
begin
  inherited Create;
  if AClass = nil then
    raise EFactoryError.Create('A factory needs a model class');
  FModelClass := AClass;
  FConn := AConn;
  FValues := TStringList.Create;
end;

destructor TModelFactory.Destroy;
begin
  FArena.Free;
  FValues.Free;
  inherited Destroy;
end;

function TModelFactory.EnterArena: TArena;
begin
  Result := CurrentArena;
  if Result <> nil then
    Exit;
  if FArena = nil then
    FArena := TArena.Create(64 * 1024);
  UseArena(FArena);
end;

function TModelFactory.MakeModel: TModel;
var
  Prev: TArena;
begin
  Prev := CurrentArena;
  EnterArena;
  try
    Result := MakeIn;
  finally
    UseArena(Prev);
  end;
end;

function TModelFactory.InsertModel: TModel;
var
  Prev: TArena;
begin
  Prev := CurrentArena;
  EnterArena;
  try
    Result := InsertIn;
  finally
    UseArena(Prev);
  end;
end;

procedure TModelFactory.SetValues(const Pairs: array of const);
var
  I, K: Integer;
  Col: string;
begin
  if Odd(Length(Pairs)) then
    raise EFactoryError.Create('Values takes column and value in pairs');
  for I := 0 to Length(Pairs) div 2 - 1 do
  begin
    Col := ArgText(Pairs[I * 2]);
    if FModelClass.Meta.IndexOfColumn(Col) < 0 then
      raise EFactoryError.CreateFmt('%s has no column %s', [FModelClass.ClassName, Col]);
    { Not Values[] := -- an empty value deletes the entry on 3.3.1. }
    K := FValues.IndexOfName(Col);
    if K >= 0 then
      FValues[K] := Col + '=' + ArgText(Pairs[I * 2 + 1])
    else
      FValues.Add(Col + '=' + ArgText(Pairs[I * 2 + 1]));
  end;
end;

procedure TModelFactory.AddState(S: TFactoryState);
var
  I: Integer;
begin
  I := Length(FStates);
  SetLength(FStates, I + 1);
  FStates[I] := S;
end;

function TModelFactory.MakeIn: TModel;
var
  Meta: TModelMeta;
  I, K: Integer;
  C: TColumnInfo;
  N: Int64;
  S: string;
begin
  Meta := FModelClass.Meta;
  Result := TModel(FModelClass.NewInstance);
  N := NextFactoryNumber;
  for I := 0 to Meta.ColumnCount - 1 do
  begin
    C := Meta.Columns[I];
    K := FValues.IndexOfName(C.ColumnName);
    if K >= 0 then
    begin
      SetColumnText(Result, C, FValues.ValueFromIndex[K]);
      Continue;
    end;
    { The key and the columns the model sets itself are the model's; a
      nullable column stays null. }
    if (not C.Insertable) or Meta.IsManaged(C.ColumnName) or C.EmptyIsNull or
       C.ZeroIsNull then
      Continue;
    { A key to a parent is not a number to count with: it would point at a
      row that is not there. Insert makes the parent and fills it. }
    if IsParentKey(Meta, C.ColumnName) then
      Continue;
    if C.Kind = ckDateTime then
    begin
      { Seconds, as SQL keeps them; a date for a TDate. }
      if SameText(string(C.Prop^.PropType^.Name), 'TDate') then
        SetFloatProp(Result, C.Prop, Date)
      else
        SetFloatProp(Result, C.Prop, RecodeMilliSecond(Now, 0));
      Continue;
    end;
    S := SampleFor(Result, C, N);
    if S <> '' then
      SetColumnText(Result, C, S);
  end;
  for I := 0 to High(FStates) do
    FStates[I](Result, N);
end;

function TModelFactory.InsertIn: TModel;
var
  Meta: TModelMeta;
  I, Col: Integer;
  R: TRelationInfo;
  Parent: TModelFactory;
  P: TModel;
  Msg: string;
begin
  Result := MakeIn;
  Meta := FModelClass.Meta;
  { A parent for each BelongsTo whose key nobody gave, made the same way. }
  for I := 0 to Meta.RelationCount - 1 do
  begin
    R := Meta.Relations[I];
    if R.Kind <> rkBelongsTo then
      Continue;
    Col := Meta.IndexOfColumn(R.ForeignKey);
    if (Col < 0) or Meta.Columns[Col].ZeroIsNull then
      Continue;
    { A key given with Values is set already, and not zero. }
    if GetOrdOrInt64(Result, Meta.Columns[Col].Prop) <> 0 then
      Continue;
    { Made in the arena this one is in, so it lives as long. }
    Parent := TModelFactory.Create(R.Target, FConn);
    try
      P := Parent.InsertIn;
      SetColumnText(Result, Meta.Columns[Col], IntToStr(P.PrimaryKeyValue));
    finally
      Parent.Free;
    end;
  end;
  if not Result.Validate then
  begin
    Msg := '';
    for I := 0 to Result.Errors.Count - 1 do
    begin
      if Msg <> '' then
        Msg := Msg + '; ';
      Msg := Msg + Result.Errors.Field(I) + ': ' + Result.Errors.Message(I);
    end;
    raise EFactoryError.CreateFmt('A %s from the factory does not pass its own rules: ' +
      '%s. Give the column a value with Values, or a State.', [FModelClass.ClassName, Msg]);
  end;
  Result.Save(FConn);
end;

{ TFactory<M> }

constructor TFactory<M>.Create(AConn: TDbConnection);
begin
  inherited Create(M, AConn);
end;

function TFactory<M>.Values(const Pairs: array of const): TFactory<M>;
begin
  SetValues(Pairs);
  Result := Self;
end;

function TFactory<M>.State(S: TFactoryState): TFactory<M>;
begin
  AddState(S);
  Result := Self;
end;

function TFactory<M>.Make: M;
begin
  Result := M(MakeModel);
end;

function TFactory<M>.Insert: M;
begin
  Result := M(InsertModel);
end;

function TFactory<M>.MakeMany(Count: Integer): TItems;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Count);
  for I := 0 to Count - 1 do
    Result[I] := M(MakeModel);
end;

function TFactory<M>.InsertMany(Count: Integer): TItems;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Count);
  for I := 0 to Count - 1 do
    Result[I] := M(InsertModel);
end;

end.
