{ Askr.Urd.Model — models, schema and RTTI mapping.

  A model is an ordinary class. The published section is not decoration:
  it is where Free Pascal puts RTTI, and it is the key to Urd mapping
  fields without code generation.

      type
        TCustomer = class(TModel)
        published
          property Id: Int64 read FId write FId;
          property Name: string read FName write FName;
        public
          class procedure Describe(S: TSchema); override;
        end;

  The conventions are the usual ones and can be overridden in Describe:
  the class name without the T, snake_cased and pluralised, becomes the
  table name; property names in snake_case become column names; and "id"
  is the primary key.

  Models are arena objects. That they can have string properties without
  leaking is down to the finalisation in Askr.Core.Arena: classes with
  fields the compiler manages get a Defer that runs at Reset. }
unit Askr.Urd.Model;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, TypInfo, SyncObjs,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Clock, Askr.Core.Json,
  Askr.Core.Lang, Askr.Urd.Driver;

type
  TModel = class;
  TModelClass = class of TModel;

  { A non-generic base for TModelList<M>.

    It exists so serialisation and eager loading can handle a list without
    knowing the element type. Without it every consumer would have to be
    specialised per model, and that is exactly the boilerplate generics
    were supposed to remove. }
  TModelListBase = class(TArenaObject)
  protected
    FItems: PPointer;
    FCount: Integer;
    FCapacity: Integer;
    procedure AddPointer(P: Pointer);
  public
    { Adds without knowing the element type. Used by eager loading, which
      builds the list before it knows what static type it will get. }
    procedure AddModel(AModel: TModel);
    function Count: Integer;
    { The element as a TModel. The generic subclass gives the same element
      with the right static type. }
    function Item(Index: Integer): TModel;
    function IsEmpty: Boolean;
  end;

  EModelError = class(EDbError);

  TColumnKind = (ckInteger, ckString, ckCurrency, ckFloat, ckBoolean,
                 ckDateTime, ckEnum);

  TColumnInfo = record
    PropName: string;
    ColumnName: string;
    Prop: PPropInfo;
    Kind: TColumnKind;
    { False for a generated primary key: the database sets it. }
    Insertable: Boolean;
    { An empty string goes in as NULL. Set with TSchema.EmptyIsNull. }
    EmptyIsNull: Boolean;
    { Zero goes in as NULL and out as null. Set with TSchema.ZeroIsNull. }
    ZeroIsNull: Boolean;
  end;

  TRelationKind = (rkHasMany, rkBelongsTo, rkHasOne, rkBelongsToMany);

  TRelationInfo = record
    Name: string;
    Kind: TRelationKind;
    Target: TModelClass;
    { The column on the "many" side that points back. }
    ForeignKey: string;
    { The column on the "one" side being pointed at, normally the primary
      key. }
    LocalKey: string;
    { BelongsToMany only. The table between the two, and its column that
      points at the target; ForeignKey is then its column that points
      back here. }
    Pivot: string;
    PivotRelatedKey: string;
  end;

  { Columns a model never puts in JSON.

    `WriteModel` writes every mapped column, which is the right default for
    a query builder and the wrong one for anything that leaves the process.
    A model with a `PasswordHash` property -- which `askr new --auth`
    generates -- serialises the hash into any JSON response or Inertia prop
    that carries the model. Measured, not feared.

    So a model says what must never go out, once, next to the model rather
    than at every place that serialises it. Naming a column that does not
    exist is a compile error, because the argument is the typed constant
    `askr schema` generates and not a string. }
  TJsonHidden = class
  private
    FNames: array of string;
  public
    { The column name, snake_case, as it appears in JSON.

      Callers do not use this: the typed `Add` overloads are a class
      helper in Askr.Urd.Query, because the typed column lives there and
      this unit is below it. The same arrangement as `Req.FillInto`, and
      for the same reason -- a dependency in this direction would make
      every model drag the query builder in. }
    procedure AddColumn(const ColumnName: string);
    function Has(const ColumnName: string): Boolean;
    function Count: Integer;
  end;

  TModelMeta = class
  private
    FModelClass: TModelClass;
    FTable: string;
    FPrimaryKey: string;
    FAutoIncrement: Boolean;
    FColumns: array of TColumnInfo;
    FRelations: array of TRelationInfo;
    FHasTimestamps: Boolean;
    FCreatedAtColumn: string;
    FUpdatedAtColumn: string;
    FSoftDeletes: Boolean;
    FDeletedAtColumn: string;
    FHidden: TJsonHidden;
    function GetColumn(Index: Integer): TColumnInfo;
    function GetRelation(Index: Integer): TRelationInfo;
  public
    destructor Destroy; override;
    { True when this column never goes in JSON. Asked by the
      serialisers; a caller building its own payload should ask too. }
    function IsHidden(const ColumnName: string): Boolean;
    { True for a column the model sets itself and a request never does:
      the primary key, created_at and updated_at with Timestamps, and
      deleted_at with SoftDeletes. FillInto skips them and the OpenAPI
      document marks them readOnly -- one rule, asked in both places, so
      what a request may set and what the document says it may set
      cannot disagree. }
    function IsManaged(const ColumnName: string): Boolean;
    function ColumnCount: Integer;
    function RelationCount: Integer;
    function IndexOfColumn(const AColumnName: string): Integer;
    function IndexOfProp(const APropName: string): Integer;
    function IndexOfRelation(const AName: string): Integer;
    function PrimaryKeyIndex: Integer;

    property ModelClass: TModelClass read FModelClass;
    property Table: string read FTable;
    property PrimaryKey: string read FPrimaryKey;
    property AutoIncrement: Boolean read FAutoIncrement;
    property Columns[Index: Integer]: TColumnInfo read GetColumn;
    property Relations[Index: Integer]: TRelationInfo read GetRelation;

    { The schema builder in Norn can write created_at and updated_at, but
      until now the model did not touch them: the database's DEFAULT set
      created_at at INSERT, and updated_at stayed at that value
      forever. }
    property HasTimestamps: Boolean read FHasTimestamps;
    property CreatedAtColumn: string read FCreatedAtColumn;
    property UpdatedAtColumn: string read FUpdatedAtColumn;
    property SoftDeletes: Boolean read FSoftDeletes;
    property DeletedAtColumn: string read FDeletedAtColumn;
  end;

  { Handed to Describe. Everything here overrides the conventions. }
  TSchema = class
  private
    FMeta: TModelMeta;
  public
    constructor Create(AMeta: TModelMeta);
    procedure Table(const AName: string);
    { AutoIncrement = False when the app sets the key itself, a UUID for
      instance. }
    procedure PrimaryKey(const AName: string; AAutoIncrement: Boolean = True);
    { Overstyrer kolonnenavnet for en property. }
    procedure Column(const APropName, AColumnName: string);
    { The property is not mapped to any column. }
    procedure Ignore(const APropName: string);

    { An empty string in this property is written as NULL.

      Pascal has no null string, so a nullable text column set from a
      model was never NULL: an empty field went in as '', and WhereNull
      found nothing. It is the TDateTime problem again, for strings -- and
      for a JSON or a UUID column it is worse than wrong, because '' is
      not a value there at all. Postgres and MySQL both refuse it, and the
      save fails. Found when `askr make model` round-tripped a nullable
      json column on each database.

      It has to be asked for, rather than done for every string: in a
      column that is NOT NULL, '' is a legitimate value distinct from
      absent, and turning it into NULL would make the save fail instead.
      `askr make model` asks for it on every column its spec marked with
      a `?`. The property has to be a mapped string, or this raises --
      a setting that silently did nothing would look like it worked. }
    procedure EmptyIsNull(const APropName: string);

    { Zero is NULL, for an integer that refers to a row: no table has a
      row 0, so 0 is how Pascal says "none". It goes in as NULL -- without
      this a nullable reference could never be NULL, and an empty select
      wrote a foreign key to a row that is not there -- and comes out in
      JSON as null. `askr make model` asks for it on every references
      column. An integer property only, or this raises. }
    procedure ZeroIsNull(const APropName: string);

    { The model sets created_at at INSERT and updated_at at both.

      The columns have to exist as published TDateTime properties on the
      model — CreatedAt and UpdatedAt by convention. If they do not,
      Describe raises immediately rather than letting the timestamps
      quietly fail to be set. }
    procedure Timestamps(const ACreatedAt: string = 'created_at';
      const AUpdatedAt: string = 'updated_at');

    { Delete sets deleted_at instead of deleting the row, and queries leave
      the deleted ones out unless somebody asks for them.

      The point is not to make deletion reversible for fun: it is that a
      row other rows point at must not vanish from under them. The column
      has to exist as a published TDateTime property, normally
      DeletedAt. }
    procedure SoftDeletes(const AColumn: string = 'deleted_at');
    procedure HasMany(const AName: string; ATarget: TModelClass;
      const AForeignKey: string; const ALocalKey: string = '');
    procedure HasOne(const AName: string; ATarget: TModelClass;
      const AForeignKey: string; const ALocalKey: string = '');
    procedure BelongsTo(const AName: string; ATarget: TModelClass;
      const AForeignKey: string; const AOwnerKey: string = '');
    { Many rows on each side, joined through a pivot table that holds a
      pair of keys and nothing else:

          S.BelongsToMany('Tags', TTag);

      is posts to tags through `post_tag`, where `post_id` points here and
      `tag_id` points there. The pivot is the two singular names in
      alphabetical order, as in Laravel; name it when yours is different.

      It is loaded with Preload like any relation, into a published
      `TModelList<TTag>` field of the same name, and the rows in it are
      changed with Attach, Detach and Sync on the model. }
    procedure BelongsToMany(const AName: string; ATarget: TModelClass;
      const APivot: string = ''; const AForeignPivotKey: string = '';
      const ARelatedPivotKey: string = '');
  end;

  EValidationError = class(EDbError);

  TErrorEntry = record
    Field: string;
    Message: string;
  end;

  { The errors from one validation. Lives in the arena and goes away with
    the request. }
  TErrors = class(TArenaObject)
  private
    FItems: array of TErrorEntry;
  public
    procedure Add(const AField, AMessage: string);
    function Count: Integer;
    function IsEmpty: Boolean;
    function Field(Index: Integer): string;
    function Message(Index: Integer): string;
    function Has(const AField: string): Boolean;
    { The first message for the field, or an empty string. }
    function First(const AField: string): string;
    { Writes the errors as a JSON object: field to message. That is the
      shape Inertia expects in props.errors. }
    procedure WriteJson(var W: TJsonWriter);
  end;

  TValidator = class;

  { The chain of rules for one field. Each rule returns Self. }
  TFieldRules = class
  private
    FValidator: TValidator;
    FPropName: string;
    FColumn: string;
    FCol: TColumnInfo;
    FFound: Boolean;
    FFailed: Boolean;
    FLastMessage: string;
    function AsStr: string;
    function AsNum: Currency;
    function IsBlank: Boolean;
    procedure Fail(const AMessage: string);
  public
    function Required: TFieldRules;
    function MinLen(N: Integer): TFieldRules;
    function MaxLen(N: Integer): TFieldRules;
    function Email: TFieldRules;
    function Min(V: Currency): TFieldRules;
    function Max(V: Currency): TFieldRules;
    function Between(Lo, Hi: Currency): TFieldRules;
    function OneOf(const Values: array of string): TFieldRules;
    { The same value as another field — a password and its
      confirmation. }
    function SameAs(const OtherProp: string): TFieldRules;
    { No other row in the table has this value. Uses the ambient
      connection, and skips the row itself when the model is stored. }
    function UniqueIn(const ATable: string; const AColumn: string = ''): TFieldRules;
    { UniqueIn on the model's own table and column -- the common case, and
      the one a generator can write without knowing the table's name. }
    function Unique: TFieldRules;
    { The value is a row in ATable: a reference that points at something.
      Blank passes -- that is Required's to refuse -- so a nullable
      reference is checked only when it is set. Without it, a key to a row
      that is not there failed in the database, as a 500, instead of on
      the form. A soft-deleted row is still a row here. }
    function Exists(const ATable: string; const AColumn: string = 'id'): TFieldRules;
    { Overstyrer meldingen til regelen rett foran. }
    function Says(const AMessage: string): TFieldRules;
    property Column: string read FColumn;
  end;

  TValidator = class
  private
    FModel: TModel;
    FMeta: TModelMeta;
    FErrors: TErrors;
    FRules: array of TFieldRules;
  public
    constructor Create(AModel: TModel; AErrors: TErrors);
    destructor Destroy; override;
    function Field(const APropName: string): TFieldRules;
    property Errors: TErrors read FErrors;
    property Model: TModel read FModel;
  end;

  { $M+ is what lets models have a published section at all, and what
    makes Free Pascal put RTTI there. Without it the whole mapping would
    need code generation. }
  {$M+}
  TModel = class(TArenaObject)
  private
    FPersisted: Boolean;
    FErrors: TErrors;
  public
    { Overridden by the model to change the table name, the columns and the
      relations. }
    class procedure Describe(S: TSchema); virtual;
    { Columns this model never puts in JSON. Override and add them; the
      default hides nothing, which is what a model with nothing to hide
      wants.

        class procedure TUser.HideFromJson(H: TJsonHidden);
        begin
          H.Add(Users.PasswordHash);
        end;

      It is about serialisation only. A hidden column is still selected,
      still written, still queryable -- it just never leaves the process
      in a payload. }
    class procedure HideFromJson(H: TJsonHidden); virtual;
    { Built once per class and cached. }
    class function Meta: TModelMeta;

    { Fills the fields from one row. Columns not present in the result are
      left alone, so a SELECT with fewer columns works. }
    procedure Hydrate(R: TDbResult; Row: Integer);

    function PrimaryKeyValue: Int64;
    procedure SetPrimaryKeyValue(Value: Int64);

    { The rules for the model, the way the PRD writes them:

      procedure TCustomer.Rules(V: TValidator);
      begin
        V.Field('Name').Required.MaxLen(120);
      end; }
    procedure Rules(V: TValidator); virtual;
    { Runs Rules. False when something failed; the errors are then in
      Errors. }
    function Validate: Boolean;
    function Errors: TErrors;

    { INSERT when the row is new, otherwise UPDATE. Uses the ambient
      connection when none is given. }
    procedure Save(Conn: TDbConnection = nil);
    { Deletes the row — or sets deleted_at when the model has
      SoftDeletes. }
    procedure Delete(Conn: TDbConnection = nil);
    { Deletes the row for good, even when the model has SoftDeletes. }
    procedure ForceDelete(Conn: TDbConnection = nil);
    { Brings a soft-deleted row back. Raises when the model has no
      SoftDeletes — calling Restore there is a misunderstanding, not a
      no-op. }
    procedure Restore(Conn: TDbConnection = nil);
    { True when deleted_at is set. False for a model without
      SoftDeletes. }
    function IsTrashed: Boolean;

    { The rows of a BelongsToMany relation, changed through its pivot.
      The model has to be saved: the pivot row points at its id.

      Attach adds the ids that are not there already, so attaching twice
      is not a unique violation. Detach removes the ones given, and an
      empty list removes nothing -- DetachAll is the one that empties.
      Sync makes the pivot exactly the ids given, an empty list included,
      and does it in a transaction: an id the database refuses leaves the
      rows as they were, not half-changed. Inside a transaction the
      caller opened, the caller's commit decides.

      Nothing here checks that an id is a row. The pivot's foreign keys
      refuse one that is not; a form should check first, so the refusal
      is a message on the field and not a 500. }
    procedure Attach(const Relation: string; const Ids: array of Int64;
      Conn: TDbConnection = nil);
    procedure Detach(const Relation: string; const Ids: array of Int64;
      Conn: TDbConnection = nil);
    procedure DetachAll(const Relation: string; Conn: TDbConnection = nil);
    procedure Sync(const Relation: string; const Ids: array of Int64;
      Conn: TDbConnection = nil);
    { The ids in the pivot for this model, in order. What an edit form
      ticks. A row that is soft-deleted is still attached, so it is here
      -- Preload leaves it out, because it is not a row to show. }
    function RelatedIds(const Relation: string;
      Conn: TDbConnection = nil): TArray<Int64>;

    { Events. Virtual methods, not observers registered at runtime: the
      compiler sees them, and there is no reflection to go through.

      They run in this order:
        Save:    BeforeSave, BeforeInsert|BeforeUpdate, SQL,
                 AfterInsert|AfterUpdate, AfterSave
        Delete:  BeforeDelete, SQL, AfterDelete

      To cancel: raise. That is the one way in Pascal the call site
      cannot overlook, and a Save that quietly failed to save would be
      worse than an exception. }
    procedure BeforeSave; virtual;
    procedure AfterSave; virtual;
    procedure BeforeInsert; virtual;
    procedure AfterInsert; virtual;
    procedure BeforeUpdate; virtual;
    procedure AfterUpdate; virtual;
    procedure BeforeDelete; virtual;
    procedure AfterDelete; virtual;

    { True when the row exists in the database — set by Hydrate and by
      Save. }
    property Persisted: Boolean read FPersisted write FPersisted;
  end;
  {$M-}

{ The ambient connection for the current thread, following the same
  pattern as UseArena. The host sets it at the start of a request, so
  Model.Save can be written without arguments. }
function CurrentDb: TDbConnection;
function UseDb(C: TDbConnection): TDbConnection;

{ The conventions, exposed because Norn uses the same ones in step
  3. }
function SnakeCase(const S: string): string;
function Pluralize(const S: string): string;
function TableNameFor(AClass: TClass): string;

{ Every id is a row in ATable -- the ids a form sent for a BelongsToMany,
  checked before Sync so a refusal is a message on the field and not a
  foreign key's 500. One query for the whole list, on the ambient
  connection; the ids that are missing are named on AField:

      tag_ids contains 999, which does not match a row in tags

  An empty list is nothing to check. }
function IdsExist(Errors: TErrors; const AField, ATable: string;
  const Ids: array of Int64; const AColumn: string = 'id'): Boolean;

{ The column a BelongsTo points at in the other table: the one named in
  BelongsTo, or the other model's primary key. Asked when a relation is
  loaded, not while the model is described. }
function OwnerKeyOf(const Rel: TRelationInfo): string;

{ The name a request sends a BelongsToMany's ids under: the pivot's key
  to the other table, plural -- tag_id, so tag_ids. One rule, asked by
  the generated controllers, the OpenAPI document and the form, so the
  three cannot name it differently. }
function IdsInputName(const Rel: TRelationInfo): string;

{ A published property read as Currency.

  GetFloatProp returns Extended, and Currency(Extended) is not a legal
  typecast: on x86_64 Extended is 80 bits and a type of its own, so the
  compiler refuses it. On aarch64 Extended is an alias for Double and the
  same line compiles — which is why this stood until the framework was
  built for x86_64 for the first time.

  Assignment is a defined conversion on both, and it is the rule the rest
  of Askr already follows for money: never typecast into Currency, assign
  into it. A typecast there reinterprets the scaled int64 instead of
  converting the value. }
function PropAsCurrency(Instance: TObject; PropInfo: PPropInfo): Currency;

implementation

threadvar
  GCurrentDb: TDbConnection;

function PropAsCurrency(Instance: TObject; PropInfo: PPropInfo): Currency;
begin
  Result := GetFloatProp(Instance, PropInfo);
end;

{ TModelListBase }

procedure TModelListBase.AddPointer(P: Pointer);
var
  NewCap: Integer;
  NewItems: PPointer;
begin
  if FCount >= FCapacity then
  begin
    if FCapacity = 0 then
      NewCap := 16
    else
      NewCap := FCapacity * 2;
    NewItems := PPointer(Arena.Alloc(PtrUInt(NewCap) * SizeOf(Pointer)));
    if FCount > 0 then
      Move(FItems^, NewItems^, PtrUInt(FCount) * SizeOf(Pointer));
    FItems := NewItems;
    FCapacity := NewCap;
  end;
  PPointer(PByte(FItems) + PtrUInt(FCount) * SizeOf(Pointer))^ := P;
  Inc(FCount);
end;

procedure TModelListBase.AddModel(AModel: TModel);
begin
  AddPointer(Pointer(AModel));
end;

function TModelListBase.Count: Integer;
begin
  Result := FCount;
end;

function TModelListBase.Item(Index: Integer): TModel;
begin
  if (Index < 0) or (Index >= FCount) then
    Exit(nil);
  Result := TModel(PPointer(PByte(FItems) + PtrUInt(Index) * SizeOf(Pointer))^);
end;

function TModelListBase.IsEmpty: Boolean;
begin
  Result := FCount = 0;
end;

var
  GMetaLock: TCriticalSection;
  GMetas: array of TModelMeta;

function CurrentDb: TDbConnection;
begin
  Result := GCurrentDb;
end;

function UseDb(C: TDbConnection): TDbConnection;
begin
  Result := GCurrentDb;
  GCurrentDb := C;
end;

function IsUpper(C: Char): Boolean; inline;
begin
  Result := (C >= 'A') and (C <= 'Z');
end;

function IsLowerOrDigit(C: Char): Boolean; inline;
begin
  Result := ((C >= 'a') and (C <= 'z')) or ((C >= '0') and (C <= '9'));
end;

function SnakeCase(const S: string): string;
var
  I, N: Integer;
  NeedsUnderscore: Boolean;
begin
  Result := '';
  N := Length(S);
  for I := 1 to N do
  begin
    if IsUpper(S[I]) and (I > 1) then
    begin
      { Break before a capital following a lower-case letter — CreatedAt —
        and before the last one in an abbreviation — HTTPCode becomes
        http_code. }
      NeedsUnderscore := IsLowerOrDigit(S[I - 1]) or
        ((I < N) and IsUpper(S[I - 1]) and not IsUpper(S[I + 1]) and
         (S[I + 1] <> '_'));
      if NeedsUnderscore and (Result <> '') and
         (Result[Length(Result)] <> '_') then
        Result := Result + '_';
    end;
    Result := Result + LowerCase(S[I]);
  end;
end;

function EndsWithStr(const S, Suffix: string): Boolean;
begin
  Result := (Length(S) >= Length(Suffix)) and
    (Copy(S, Length(S) - Length(Suffix) + 1, Length(Suffix)) = Suffix);
end;

function Pluralize(const S: string): string;
var
  Last: Char;
begin
  if S = '' then
    Exit('');
  Last := S[Length(S)];
  if (Last = 'y') and (Length(S) > 1) and
     not (S[Length(S) - 1] in ['a', 'e', 'i', 'o', 'u']) then
    Result := Copy(S, 1, Length(S) - 1) + 'ies'
  else if (Last in ['s', 'x', 'z']) or EndsWithStr(S, 'ch') or
          EndsWithStr(S, 'sh') then
    Result := S + 'es'
  else
    Result := S + 's';
end;

function TableNameFor(AClass: TClass): string;
var
  N: string;
begin
  N := AClass.ClassName;
  { A leading T before a capital is Pascal convention, not part of the
    name. }
  if (Length(N) > 1) and (N[1] = 'T') and IsUpper(N[2]) then
    N := Copy(N, 2, Length(N) - 1);
  Result := Pluralize(SnakeCase(N));
end;

{ TModelMeta }

function TModelMeta.ColumnCount: Integer;
begin
  Result := Length(FColumns);
end;

function TModelMeta.RelationCount: Integer;
begin
  Result := Length(FRelations);
end;

function TModelMeta.GetColumn(Index: Integer): TColumnInfo;
begin
  Result := FColumns[Index];
end;

function TModelMeta.GetRelation(Index: Integer): TRelationInfo;
begin
  Result := FRelations[Index];
end;

function TModelMeta.IndexOfColumn(const AColumnName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FColumns) do
    if SameText(FColumns[I].ColumnName, AColumnName) then
      Exit(I);
  Result := -1;
end;

function TModelMeta.IndexOfProp(const APropName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FColumns) do
    if SameText(FColumns[I].PropName, APropName) then
      Exit(I);
  Result := -1;
end;

function TModelMeta.IndexOfRelation(const AName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FRelations) do
    if SameText(FRelations[I].Name, AName) then
      Exit(I);
  Result := -1;
end;

function TModelMeta.PrimaryKeyIndex: Integer;
begin
  Result := IndexOfColumn(FPrimaryKey);
end;

{ TSchema }

constructor TSchema.Create(AMeta: TModelMeta);
begin
  inherited Create;
  FMeta := AMeta;
end;

procedure TSchema.Table(const AName: string);
begin
  FMeta.FTable := AName;
end;

procedure TSchema.PrimaryKey(const AName: string; AAutoIncrement: Boolean);
begin
  FMeta.FPrimaryKey := AName;
  FMeta.FAutoIncrement := AAutoIncrement;
end;

procedure TSchema.Column(const APropName, AColumnName: string);
var
  I: Integer;
begin
  I := FMeta.IndexOfProp(APropName);
  if I < 0 then
    raise EModelError.CreateFmt('%s has no published property "%s"',
      [FMeta.FModelClass.ClassName, APropName]);
  FMeta.FColumns[I].ColumnName := AColumnName;
end;

procedure TSchema.Ignore(const APropName: string);
var
  I, J: Integer;
begin
  I := FMeta.IndexOfProp(APropName);
  if I < 0 then
    Exit;
  for J := I to High(FMeta.FColumns) - 1 do
    FMeta.FColumns[J] := FMeta.FColumns[J + 1];
  SetLength(FMeta.FColumns, Length(FMeta.FColumns) - 1);
end;

procedure TSchema.EmptyIsNull(const APropName: string);
var
  I: Integer;
begin
  I := FMeta.IndexOfProp(APropName);
  if I < 0 then
    raise EModelError.CreateFmt(
      '%s: EmptyIsNull(''%s'') names no mapped property. Check the ' +
      'spelling -- it is the property name, not the column.',
      [FMeta.ModelClass.ClassName, APropName]);
  if FMeta.FColumns[I].Kind <> ckString then
    raise EModelError.CreateFmt(
      '%s: EmptyIsNull(''%s'') is for a string property. A TDateTime of ' +
      'zero is written as NULL already; for an integer that refers to a ' +
      'row, use ZeroIsNull.',
      [FMeta.ModelClass.ClassName, APropName]);
  FMeta.FColumns[I].EmptyIsNull := True;
end;

procedure TSchema.ZeroIsNull(const APropName: string);
var
  I: Integer;
begin
  I := FMeta.IndexOfProp(APropName);
  if I < 0 then
    raise EModelError.CreateFmt(
      '%s: ZeroIsNull(''%s'') names no mapped property. Check the ' +
      'spelling -- it is the property name, not the column.',
      [FMeta.ModelClass.ClassName, APropName]);
  if FMeta.FColumns[I].Kind <> ckInteger then
    raise EModelError.CreateFmt(
      '%s: ZeroIsNull(''%s'') is for an integer property, the id of a ' +
      'row somewhere else.',
      [FMeta.ModelClass.ClassName, APropName]);
  FMeta.FColumns[I].ZeroIsNull := True;
end;

{ Common to Timestamps and SoftDeletes: the column has to exist as a
  mapped TDateTime property. Without the check the field would quietly
  fail to be set, and it would look as if the timestamps worked. }
procedure RequireDateTimeColumn(Meta: TModelMeta; const AColumn, AWhat: string);
var
  I: Integer;
begin
  I := Meta.IndexOfColumn(AColumn);
  if I < 0 then
    raise EModelError.CreateFmt(
      '%s.%s needs a mapped column "%s". Add a published TDateTime ' +
      'property for it (the convention maps %s to "%s").',
      [Meta.ModelClass.ClassName, AWhat, AColumn,
       'CreatedAt/UpdatedAt/DeletedAt', AColumn]);
  if Meta.Columns[I].Kind <> ckDateTime then
    raise EModelError.CreateFmt(
      '%s.%s needs "%s" to be a TDateTime property, not %s.',
      [Meta.ModelClass.ClassName, AWhat, AColumn,
       GetEnumName(TypeInfo(TColumnKind), Ord(Meta.Columns[I].Kind))]);
end;

procedure TSchema.Timestamps(const ACreatedAt, AUpdatedAt: string);
begin
  RequireDateTimeColumn(FMeta, ACreatedAt, 'Timestamps');
  RequireDateTimeColumn(FMeta, AUpdatedAt, 'Timestamps');
  FMeta.FHasTimestamps := True;
  FMeta.FCreatedAtColumn := ACreatedAt;
  FMeta.FUpdatedAtColumn := AUpdatedAt;
end;

procedure TSchema.SoftDeletes(const AColumn: string);
begin
  RequireDateTimeColumn(FMeta, AColumn, 'SoftDeletes');
  FMeta.FSoftDeletes := True;
  FMeta.FDeletedAtColumn := AColumn;
end;

procedure AddRelation(Meta: TModelMeta; Kind: TRelationKind;
  const AName: string; ATarget: TModelClass;
  const AForeignKey, ALocalKey: string);
var
  N: Integer;
begin
  N := Length(Meta.FRelations);
  SetLength(Meta.FRelations, N + 1);
  Meta.FRelations[N].Name := AName;
  Meta.FRelations[N].Kind := Kind;
  Meta.FRelations[N].Target := ATarget;
  Meta.FRelations[N].ForeignKey := AForeignKey;
  if ALocalKey <> '' then
    Meta.FRelations[N].LocalKey := ALocalKey
  else
    Meta.FRelations[N].LocalKey := Meta.FPrimaryKey;
end;

procedure TSchema.HasMany(const AName: string; ATarget: TModelClass;
  const AForeignKey: string; const ALocalKey: string);
begin
  AddRelation(FMeta, rkHasMany, AName, ATarget, AForeignKey, ALocalKey);
end;

procedure TSchema.HasOne(const AName: string; ATarget: TModelClass;
  const AForeignKey: string; const ALocalKey: string);
begin
  AddRelation(FMeta, rkHasOne, AName, ATarget, AForeignKey, ALocalKey);
end;

{ The name a model goes by in a pivot: TPostTag is post_tag. The table
  name without the plural, from the class and not from the meta -- two
  models that name each other in Describe would otherwise each build the
  other's meta while their own was half made. }
function SingularNameFor(AClass: TClass): string;
var
  N: string;
begin
  N := AClass.ClassName;
  if (Length(N) > 1) and (N[1] = 'T') and IsUpper(N[2]) then
    N := Copy(N, 2, Length(N) - 1);
  Result := SnakeCase(N);
end;

procedure TSchema.BelongsToMany(const AName: string; ATarget: TModelClass;
  const APivot, AForeignPivotKey, ARelatedPivotKey: string);
var
  Mine, Theirs: string;
  N: Integer;
begin
  Mine := SingularNameFor(FMeta.FModelClass);
  Theirs := SingularNameFor(ATarget);
  AddRelation(FMeta, rkBelongsToMany, AName, ATarget, AForeignPivotKey, '');
  N := High(FMeta.FRelations);
  if AForeignPivotKey = '' then
    FMeta.FRelations[N].ForeignKey := Mine + '_id';
  if ARelatedPivotKey <> '' then
    FMeta.FRelations[N].PivotRelatedKey := ARelatedPivotKey
  else
    FMeta.FRelations[N].PivotRelatedKey := Theirs + '_id';
  if APivot <> '' then
    FMeta.FRelations[N].Pivot := APivot
  else if Mine < Theirs then
    FMeta.FRelations[N].Pivot := Mine + '_' + Theirs
  else
    FMeta.FRelations[N].Pivot := Theirs + '_' + Mine;
end;

procedure TSchema.BelongsTo(const AName: string; ATarget: TModelClass;
  const AForeignKey: string; const AOwnerKey: string);
begin
  { On the owning side the foreign key points out of this model, and
    LocalKey is the column in the target table -- as given, or '' until
    OwnerKeyOf asks. Not ATarget.Meta.PrimaryKey here: two models that
    each belong to the other would build each other's meta while their
    own was half made, round and round until the stack ran out. }
  AddRelation(FMeta, rkBelongsTo, AName, ATarget, AForeignKey, '');
  FMeta.FRelations[High(FMeta.FRelations)].LocalKey := AOwnerKey;
end;

function OwnerKeyOf(const Rel: TRelationInfo): string;
begin
  Result := Rel.LocalKey;
  if Result = '' then
    Result := Rel.Target.Meta.PrimaryKey;
end;

{ Building the meta }

function ColumnKindOf(Prop: PPropInfo; out Kind: TColumnKind): Boolean;
var
  TI: PTypeInfo;
  TypeName: string;
begin
  TI := Prop^.PropType;
  TypeName := string(TI^.Name);
  case TI^.Kind of
    tkInteger, tkInt64, tkQWord:
      Kind := ckInteger;
    tkAString, tkUString, tkString, tkWString:
      Kind := ckString;
    tkBool:
      Kind := ckBoolean;
    tkEnumeration:
      Kind := ckEnum;
    tkFloat:
      begin
        if GetTypeData(TI)^.FloatType = ftCurr then
          Kind := ckCurrency
        else if SameText(TypeName, 'TDateTime') or SameText(TypeName, 'TDate') or
                SameText(TypeName, 'TTime') then
          Kind := ckDateTime
        else
          Kind := ckFloat;
      end;
  else
    { Classes, records, sets and arrays are not mapped. They are not
      columns. }
    Kind := ckString;
    Exit(False);
  end;
  Result := True;
end;

function BuildMeta(AClass: TModelClass): TModelMeta;
var
  Props: PPropList;
  Count, I, N: Integer;
  Kind: TColumnKind;
  S: TSchema;
  PkIndex: Integer;
begin
  Result := TModelMeta.Create;
  Result.FModelClass := AClass;
  Result.FTable := TableNameFor(AClass);
  Result.FPrimaryKey := 'id';
  Result.FAutoIncrement := True;

  Props := nil;
  Count := GetPropList(AClass.ClassInfo, Props);
  try
    for I := 0 to Count - 1 do
    begin
      if not ColumnKindOf(Props^[I], Kind) then
        Continue;
      N := Length(Result.FColumns);
      SetLength(Result.FColumns, N + 1);
      Result.FColumns[N].PropName := string(Props^[I]^.Name);
      Result.FColumns[N].ColumnName := SnakeCase(string(Props^[I]^.Name));
      Result.FColumns[N].Prop := Props^[I];
      Result.FColumns[N].Kind := Kind;
      Result.FColumns[N].Insertable := True;
      Result.FColumns[N].EmptyIsNull := False;
      Result.FColumns[N].ZeroIsNull := False;
    end;
  finally
    if Props <> nil then
      FreeMem(Props);
  end;

  S := TSchema.Create(Result);
  try
    AClass.Describe(S);
  finally
    S.Free;
  end;

  { Asked once, with the meta, rather than on every serialisation. }
  Result.FHidden := TJsonHidden.Create;
  AClass.HideFromJson(Result.FHidden);

  { After Describe, because the primary key may have been changed
    there. }
  PkIndex := Result.PrimaryKeyIndex;
  if (PkIndex >= 0) and Result.FAutoIncrement then
    Result.FColumns[PkIndex].Insertable := False;
end;

destructor TModelMeta.Destroy;
begin
  FHidden.Free;
  inherited Destroy;
end;

function TModelMeta.IsHidden(const ColumnName: string): Boolean;
begin
  Result := (FHidden <> nil) and FHidden.Has(ColumnName);
end;

function TModelMeta.IsManaged(const ColumnName: string): Boolean;
begin
  Result := (ColumnName = FPrimaryKey) or
    (FHasTimestamps and ((ColumnName = FCreatedAtColumn) or
                         (ColumnName = FUpdatedAtColumn))) or
    (FSoftDeletes and (ColumnName = FDeletedAtColumn));
end;

class function TModel.Meta: TModelMeta;
var
  I: Integer;
  M: TModelMeta;
begin
  GMetaLock.Acquire;
  try
    for I := 0 to High(GMetas) do
      if GMetas[I].FModelClass = TModelClass(Self) then
        Exit(GMetas[I]);
  finally
    GMetaLock.Release;
  end;

  { Built outside the lock: Describe is user code and may look up the
    meta for other models, which would deadlock against itself. }
  M := BuildMeta(TModelClass(Self));

  GMetaLock.Acquire;
  try
    for I := 0 to High(GMetas) do
      if GMetas[I].FModelClass = TModelClass(Self) then
      begin
        { Another thread got there first. }
        M.Free;
        Exit(GMetas[I]);
      end;
    SetLength(GMetas, Length(GMetas) + 1);
    GMetas[High(GMetas)] := M;
    Result := M;
  finally
    GMetaLock.Release;
  end;
end;

class procedure TModel.Describe(S: TSchema);
begin
  { The conventions hold. Models needing something else override. }
end;

class procedure TModel.HideFromJson(H: TJsonHidden);
begin
  { Nothing by default. A model with a secret in it says so. }
end;

procedure TJsonHidden.AddColumn(const ColumnName: string);
var
  N: Integer;
begin
  if Has(ColumnName) then
    Exit;
  N := Length(FNames);
  SetLength(FNames, N + 1);
  FNames[N] := ColumnName;
end;

function TJsonHidden.Has(const ColumnName: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(FNames) do
    if SameText(FNames[I], ColumnName) then
      Exit(True);
end;

function TJsonHidden.Count: Integer;
begin
  Result := Length(FNames);
end;

{ TErrors }

procedure TErrors.Add(const AField, AMessage: string);
var
  N: Integer;
begin
  N := Length(FItems);
  SetLength(FItems, N + 1);
  FItems[N].Field := AField;
  FItems[N].Message := AMessage;
end;

function TErrors.Count: Integer;
begin
  Result := Length(FItems);
end;

function TErrors.IsEmpty: Boolean;
begin
  Result := Length(FItems) = 0;
end;

function TErrors.Field(Index: Integer): string;
begin
  Result := FItems[Index].Field;
end;

function TErrors.Message(Index: Integer): string;
begin
  Result := FItems[Index].Message;
end;

function TErrors.Has(const AField: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FItems) do
    if SameText(FItems[I].Field, AField) then
      Exit(True);
  Result := False;
end;

function TErrors.First(const AField: string): string;
var
  I: Integer;
begin
  for I := 0 to High(FItems) do
    if SameText(FItems[I].Field, AField) then
      Exit(FItems[I].Message);
  Result := '';
end;

procedure TErrors.WriteJson(var W: TJsonWriter);
var
  I, J: Integer;
  Seen: Boolean;
begin
  W.BeginObject;
  for I := 0 to High(FItems) do
  begin
    { The first message per field wins, as in Laravel. }
    Seen := False;
    for J := 0 to I - 1 do
      if SameText(FItems[J].Field, FItems[I].Field) then
      begin
        Seen := True;
        Break;
      end;
    if Seen then
      Continue;
    W.Field(FItems[I].Field, FItems[I].Message);
  end;
  W.EndObject;
end;

{ TFieldRules }

procedure TFieldRules.Fail(const AMessage: string);
begin
  { Only the first error per field is reported. Otherwise the user gets
    five messages about the same empty field. }
  if FFailed then
    Exit;
  FFailed := True;
  FLastMessage := AMessage;
  FValidator.Errors.Add(FColumn, AMessage);
end;

function TFieldRules.AsStr: string;
begin
  if not FFound then
    Exit('');
  case FCol.Kind of
    ckString: Result := GetStrProp(FValidator.Model, FCol.Prop);
    ckInteger: Result := IntToStr(GetInt64Prop(FValidator.Model, FCol.Prop));
    ckCurrency: Result := CurrencyToSql(
      PropAsCurrency(FValidator.Model, FCol.Prop));
    ckFloat: Result := FloatToSql(GetFloatProp(FValidator.Model, FCol.Prop));
    ckDateTime: Result := DateTimeToSql(GetFloatProp(FValidator.Model, FCol.Prop));
    ckBoolean:
      if GetOrdProp(FValidator.Model, FCol.Prop) <> 0 then
        Result := '1'
      else
        Result := '0';
    ckEnum: Result := IntToStr(GetOrdProp(FValidator.Model, FCol.Prop));
  end;
end;

function TFieldRules.AsNum: Currency;
begin
  Result := 0;
  if not FFound then
    Exit;
  case FCol.Kind of
    ckInteger: Result := GetInt64Prop(FValidator.Model, FCol.Prop);
    ckCurrency, ckFloat: Result := GetFloatProp(FValidator.Model, FCol.Prop);
    ckBoolean, ckEnum: Result := GetOrdProp(FValidator.Model, FCol.Prop);
    ckString: SqlToCurrency(Str(AsStr), Result);
    ckDateTime: Result := GetFloatProp(FValidator.Model, FCol.Prop);
  end;
end;

function TFieldRules.IsBlank: Boolean;
begin
  case FCol.Kind of
    ckString: Result := Trim(GetStrProp(FValidator.Model, FCol.Prop)) = '';
    ckInteger, ckCurrency, ckFloat: Result := AsNum = 0;
    ckDateTime: Result := GetFloatProp(FValidator.Model, FCol.Prop) = 0;
  else
    Result := False;
  end;
end;

function TFieldRules.Required: TFieldRules;
begin
  Result := Self;
  if not FFound then
    Exit;
  if IsBlank then
    Fail(Trans('validation.required', ['attribute', AttributeName(FColumn)]));
end;

function TFieldRules.MinLen(N: Integer): TFieldRules;
begin
  Result := Self;
  if FFailed or not FFound then
    Exit;
  if Length(AsStr) < N then
    Fail(TransCount('validation.min_length', N, ['attribute', AttributeName(FColumn), 'min', N]));
end;

function TFieldRules.MaxLen(N: Integer): TFieldRules;
begin
  Result := Self;
  if FFailed or not FFound then
    Exit;
  if Length(AsStr) > N then
    Fail(TransCount('validation.max_length', N, ['attribute', AttributeName(FColumn), 'max', N]));
end;

{ Deliberately loose. A strict email validation refuses valid
  addresses, and the only way to know whether an address works is to send
  to it. }
function LooksLikeEmail(const S: string): Boolean;
var
  At, Dot, I: Integer;
begin
  At := 0;
  for I := 1 to Length(S) do
  begin
    if S[I] = '@' then
    begin
      if At <> 0 then
        Exit(False);
      At := I;
    end;
    if S[I] <= ' ' then
      Exit(False);
  end;
  if (At < 2) or (At = Length(S)) then
    Exit(False);
  Dot := 0;
  for I := At + 1 to Length(S) do
    if S[I] = '.' then
      Dot := I;
  Result := (Dot > At + 1) and (Dot < Length(S));
end;

function TFieldRules.Email: TFieldRules;
begin
  Result := Self;
  if FFailed or not FFound then
    Exit;
  if AsStr = '' then
    Exit;
  if not LooksLikeEmail(AsStr) then
    Fail(Trans('validation.email', ['attribute', AttributeName(FColumn)]));
end;

{ CurrencyToSql gives 0.0000. In a message to a user that is 0. }
function Readable(V: Currency): string;
begin
  Result := CurrencyToSql(V);
  if Pos('.', Result) > 0 then
  begin
    while (Length(Result) > 0) and (Result[Length(Result)] = '0') do
      Delete(Result, Length(Result), 1);
    if (Length(Result) > 0) and (Result[Length(Result)] = '.') then
      Delete(Result, Length(Result), 1);
  end;
end;

function TFieldRules.Min(V: Currency): TFieldRules;
begin
  Result := Self;
  if FFailed or not FFound then
    Exit;
  if AsNum < V then
    Fail(Trans('validation.min', ['attribute', AttributeName(FColumn), 'min', Readable(V)]));
end;

function TFieldRules.Max(V: Currency): TFieldRules;
begin
  Result := Self;
  if FFailed or not FFound then
    Exit;
  if AsNum > V then
    Fail(Trans('validation.max', ['attribute', AttributeName(FColumn), 'max', Readable(V)]));
end;

function TFieldRules.Between(Lo, Hi: Currency): TFieldRules;
begin
  Result := Self;
  if FFailed or not FFound then
    Exit;
  if (AsNum < Lo) or (AsNum > Hi) then
    Fail(Trans('validation.between', ['attribute', AttributeName(FColumn),
      'min', Readable(Lo), 'max', Readable(Hi)]));
end;

function TFieldRules.OneOf(const Values: array of string): TFieldRules;
var
  I: Integer;
  V: string;
begin
  Result := Self;
  if FFailed or not FFound then
    Exit;
  V := AsStr;
  for I := 0 to High(Values) do
    if Values[I] = V then
      Exit;
  Fail(Trans('validation.one_of', ['attribute', AttributeName(FColumn)]));
end;

function TFieldRules.SameAs(const OtherProp: string): TFieldRules;
var
  Idx: Integer;
begin
  Result := Self;
  if FFailed or not FFound then
    Exit;
  Idx := FValidator.FMeta.IndexOfProp(OtherProp);
  if Idx < 0 then
    raise EValidationError.CreateFmt(
      '%s has no published property "%s"',
      [FValidator.FMeta.ModelClass.ClassName, OtherProp]);
  if GetStrProp(FValidator.Model, FValidator.FMeta.Columns[Idx].Prop) <> AsStr then
    Fail(Trans('validation.same_as', ['attribute', AttributeName(FColumn),
      'other', AttributeName(FValidator.FMeta.Columns[Idx].ColumnName)]));
end;

function TFieldRules.UniqueIn(const ATable: string;
  const AColumn: string): TFieldRules;
var
  C: TDbConnection;
  A: TArena;
  B: TStrBuilder;
  R: TDbResult;
  Col: string;
  Mark: TArenaMark;
  Pk: Int64;
  Sql: string;
begin
  Result := Self;
  if FFailed or not FFound then
    Exit;
  if AsStr = '' then
    Exit;

  C := CurrentDb;
  if C = nil then
    raise EValidationError.Create(
      'UniqueIn needs a database connection. Set the ambient one with UseDb.');

  Col := AColumn;
  if Col = '' then
    Col := FColumn;
  A := FValidator.Model.Arena;
  Pk := FValidator.Model.PrimaryKeyValue;

  Mark := A.Mark;
  try
    B.Init(A, 192);
    B.Append('SELECT 1 FROM ');
    C.AppendIdentStr(B, ATable);
    B.Append(' WHERE ');
    C.AppendIdentStr(B, Col);
    B.Append(' = ');
    C.AppendPlaceholder(B, 1);
    { A stored row must not collide with itself. }
    if FValidator.Model.Persisted and (Pk <> 0) then
    begin
      B.Append(' AND ');
      C.AppendIdentStr(B, FValidator.FMeta.PrimaryKey);
      B.Append(' <> ');
      C.AppendPlaceholder(B, 2);
    end;
    B.Append(' LIMIT 1');
    Sql := B.ToString;
  finally
    A.Rewind(Mark);
  end;

  if FValidator.Model.Persisted and (Pk <> 0) then
    R := C.ExecParams(A, Sql, [DbParam(A, AsStr), DbParam(A, Pk)])
  else
    R := C.ExecParams(A, Sql, [DbParam(A, AsStr)]);

  if not R.IsEmpty then
    Fail(Trans('validation.unique', ['attribute', AttributeName(FColumn)]));
end;

function TFieldRules.Unique: TFieldRules;
begin
  Result := UniqueIn(FValidator.FMeta.Table);
end;

function TFieldRules.Exists(const ATable: string;
  const AColumn: string): TFieldRules;
var
  C: TDbConnection;
  A: TArena;
  B: TStrBuilder;
  R: TDbResult;
  Mark: TArenaMark;
  Sql: string;
  P: TDbParam;
begin
  Result := Self;
  if FFailed or not FFound or IsBlank then
    Exit;

  C := CurrentDb;
  if C = nil then
    raise EValidationError.Create(
      'Exists needs a database connection. Set the ambient one with UseDb.');

  A := FValidator.Model.Arena;
  Mark := A.Mark;
  try
    B.Init(A, 128);
    B.Append('SELECT 1 FROM ');
    C.AppendIdentStr(B, ATable);
    B.Append(' WHERE ');
    C.AppendIdentStr(B, AColumn);
    B.Append(' = ');
    C.AppendPlaceholder(B, 1);
    B.Append(' LIMIT 1');
    Sql := B.ToString;
  finally
    A.Rewind(Mark);
  end;

  { An id is compared as the number it is. As text it would work in some
    databases and fail to match in others. }
  if FCol.Kind = ckInteger then
    P := DbParam(A, GetInt64Prop(FValidator.Model, FCol.Prop))
  else
    P := DbParam(A, AsStr);
  R := C.ExecParams(A, Sql, [P]);
  if R.IsEmpty then
    Fail(Trans('validation.exists', ['attribute', AttributeName(FColumn), 'table', ATable]));
end;

function TFieldRules.Says(const AMessage: string): TFieldRules;
var
  I: Integer;
begin
  Result := Self;
  if not FFailed then
    Exit;
  { Replaces the most recently added message for this field. }
  for I := FValidator.Errors.Count - 1 downto 0 do
    if FValidator.Errors.FItems[I].Field = FColumn then
    begin
      FValidator.Errors.FItems[I].Message := AMessage;
      Break;
    end;
end;

{ TValidator }

constructor TValidator.Create(AModel: TModel; AErrors: TErrors);
begin
  inherited Create;
  FModel := AModel;
  FMeta := AModel.Meta;
  FErrors := AErrors;
end;

destructor TValidator.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FRules) do
    FRules[I].Free;
  inherited Destroy;
end;

function TValidator.Field(const APropName: string): TFieldRules;
var
  Idx, N: Integer;
begin
  Result := TFieldRules.Create;
  Result.FValidator := Self;
  Result.FPropName := APropName;

  Idx := FMeta.IndexOfProp(APropName);
  if Idx < 0 then
    raise EValidationError.CreateFmt(
      '%s has no published property "%s". Rules are written with the ' +
      'property name, not the column name.',
      [FMeta.ModelClass.ClassName, APropName]);

  Result.FCol := FMeta.Columns[Idx];
  Result.FColumn := Result.FCol.ColumnName;
  Result.FFound := True;

  N := Length(FRules);
  SetLength(FRules, N + 1);
  FRules[N] := Result;
end;

{ Validering av en modell }

procedure TModel.Rules(V: TValidator);
begin
  { No rules unless the model says otherwise. }
end;

{ The events. Empty here; the model overrides what it needs. }
procedure TModel.BeforeSave; begin end;
procedure TModel.AfterSave; begin end;
procedure TModel.BeforeInsert; begin end;
procedure TModel.AfterInsert; begin end;
procedure TModel.BeforeUpdate; begin end;
procedure TModel.AfterUpdate; begin end;
procedure TModel.BeforeDelete; begin end;
procedure TModel.AfterDelete; begin end;

function TModel.IsTrashed: Boolean;
var
  M: TModelMeta;
  I: Integer;
begin
  M := Meta;
  if not M.SoftDeletes then
    Exit(False);
  I := M.IndexOfColumn(M.DeletedAtColumn);
  if I < 0 then
    Exit(False);
  Result := GetFloatProp(Self, M.Columns[I].Prop) <> 0;
end;

function TModel.Validate: Boolean;
var
  V: TValidator;
  Prev: TArena;
begin
  if Arena = nil then
    raise EValidationError.Create(
      'Validation requires the model to live in an arena');

  Prev := UseArena(Arena);
  try
    FErrors := TErrors.Create;
  finally
    UseArena(Prev);
  end;

  V := TValidator.Create(Self, FErrors);
  try
    Rules(V);
  finally
    V.Free;
  end;
  Result := FErrors.IsEmpty;
end;

function TModel.Errors: TErrors;
begin
  if FErrors = nil then
    Validate;
  Result := FErrors;
end;

procedure TModel.Hydrate(R: TDbResult; Row: Integer);
var
  M: TModelMeta;
  I, Col: Integer;
  V: TStr;
  I64: Int64;
  Cur: Currency;
  Dbl: Double;
  Bool: Boolean;
  Dt: TDateTime;
begin
  M := Meta;
  for I := 0 to M.ColumnCount - 1 do
  begin
    Col := R.IndexOfField(M.Columns[I].ColumnName);
    if Col < 0 then
      Continue;
    if R.IsNull(Row, Col) then
      Continue;   { feltet er allerede nullstilt av InitInstance }

    V := R.Value(Row, Col);
    case M.Columns[I].Kind of
      ckInteger:
        if SqlToInt64(V, I64) then
          SetInt64Prop(Self, M.Columns[I].Prop, I64);
      ckString:
        SetStrProp(Self, M.Columns[I].Prop, V.ToString);
      ckCurrency:
        if SqlToCurrency(V, Cur) then
          SetFloatProp(Self, M.Columns[I].Prop, Cur);
      ckFloat:
        if SqlToFloat(V, Dbl) then
          SetFloatProp(Self, M.Columns[I].Prop, Dbl);
      ckBoolean:
        if SqlToBool(V, Bool) then
          SetOrdProp(Self, M.Columns[I].Prop, Ord(Bool));
      ckDateTime:
        if SqlToDateTime(V, Dt) then
          SetFloatProp(Self, M.Columns[I].Prop, Dt);
      ckEnum:
        if SqlToInt64(V, I64) then
          SetOrdProp(Self, M.Columns[I].Prop, LongInt(I64));
    end;
  end;
  FPersisted := True;
end;

function TModel.PrimaryKeyValue: Int64;
var
  M: TModelMeta;
  I: Integer;
begin
  M := Meta;
  I := M.PrimaryKeyIndex;
  if I < 0 then
    Exit(0);
  Result := GetInt64Prop(Self, M.Columns[I].Prop);
end;

procedure TModel.SetPrimaryKeyValue(Value: Int64);
var
  M: TModelMeta;
  I: Integer;
begin
  M := Meta;
  I := M.PrimaryKeyIndex;
  if I >= 0 then
    SetInt64Prop(Self, M.Columns[I].Prop, Value);
end;

function ParamFor(A: TArena; Model: TModel; const Col: TColumnInfo): TDbParam;
var
  S: string;
begin
  case Col.Kind of
    ckInteger:
      if Col.ZeroIsNull and (GetInt64Prop(Model, Col.Prop) = 0) then
        Result := DbNull
      else
        Result := DbParam(A, GetInt64Prop(Model, Col.Prop));
    ckString:
      begin
        S := GetStrProp(Model, Col.Prop);
        if Col.EmptyIsNull and (S = '') then
          Result := DbNull
        else
          Result := DbParam(A, S);
      end;
    ckCurrency:
      Result := DbParam(A, PropAsCurrency(Model, Col.Prop));
    ckFloat:
      Result := DbParam(A, FloatToSql(GetFloatProp(Model, Col.Prop)));
    ckBoolean:
      Result := DbParam(A, GetOrdProp(Model, Col.Prop) <> 0);
    ckDateTime:
      { A TDateTime of zero means "not set". Pascal has no null, and 0 is
        30 December 1899 — a date nobody means. Before this it went into
        the database as a real value, and a nullable column was never
        NULL. That is exactly what soft deletes rest on: deleted_at IS
        NULL is the difference between deleted and not.

        If the column is NOT NULL this gives a constraint error instead of
        a silently wrong date. That is the right way to fail. }
      if GetFloatProp(Model, Col.Prop) = 0 then
        Result := DbNull
      else
        Result := DbParamDateTime(A, GetFloatProp(Model, Col.Prop));
    ckEnum:
      Result := DbParam(A, Int64(GetOrdProp(Model, Col.Prop)));
  end;
  { No else: every TColumnKind is covered. If a new one arrives it
    becomes a warning about an uninitialised result rather than a silent
    DbNull. }
end;

function IdsExist(Errors: TErrors; const AField, ATable: string;
  const Ids: array of Int64; const AColumn: string): Boolean;
var
  C: TDbConnection;
  A: TArena;
  B: TStrBuilder;
  R: TDbResult;
  Params: array of TDbParam;
  Found: array of Int64;
  I, J: Integer;
  Missing: string;
  Hit: Boolean;
begin
  Result := True;
  if Length(Ids) = 0 then
    Exit;
  C := CurrentDb;
  if C = nil then
    raise EValidationError.Create(
      'IdsExist needs a database connection. Set the ambient one with UseDb.');
  A := TArena.Create(4 * 1024);
  try
    SetLength(Params, Length(Ids));
    for I := 0 to High(Ids) do
      Params[I] := DbParam(A, Ids[I]);
    B.Init(A, 128);
    B.Append('SELECT ');
    C.AppendIdentStr(B, AColumn);
    B.Append(' FROM ');
    C.AppendIdentStr(B, ATable);
    B.Append(' WHERE ');
    C.AppendIdentStr(B, AColumn);
    B.Append(' IN (');
    for I := 0 to High(Ids) do
    begin
      if I > 0 then
        B.Append(', ');
      C.AppendPlaceholder(B, I + 1);
    end;
    B.AppendByte(Ord(')'));
    R := C.ExecParams(A, B.ToString, Params);
    SetLength(Found, R.RowCount);
    for I := 0 to R.RowCount - 1 do
      Found[I] := R.AsInt64(I, 0);
  finally
    A.Free;
  end;

  Missing := '';
  for I := 0 to High(Ids) do
  begin
    Hit := False;
    for J := 0 to High(Found) do
      if Found[J] = Ids[I] then
      begin
        Hit := True;
        Break;
      end;
    if not Hit then
    begin
      if Missing <> '' then
        Missing := Missing + ', ';
      Missing := Missing + IntToStr(Ids[I]);
    end;
  end;
  if Missing = '' then
    Exit;
  Errors.Add(AField, Trans('validation.ids_exist', ['attribute', AttributeName(AField),
    'ids', Missing, 'table', ATable]));
  Result := False;
end;

function IdsInputName(const Rel: TRelationInfo): string;
begin
  Result := Rel.PivotRelatedKey + 's';
end;

function RequireDb(Conn: TDbConnection): TDbConnection;
begin
  if Conn <> nil then
    Exit(Conn);
  Result := CurrentDb;
  if Result = nil then
    raise EModelError.Create(
      'No database connection. Pass one in, or set the ambient one with ' +
      'UseDb — the host normally does that at the start of a request.');
end;

{ ------------------------------------------------------- the pivot -- }

function ManyToManyOf(M: TModelMeta; const Relation, Caller: string):
  TRelationInfo;
var
  Idx: Integer;
begin
  Idx := M.IndexOfRelation(Relation);
  if Idx < 0 then
    raise EModelError.CreateFmt('%s: %s has no relation "%s"',
      [Caller, M.ModelClass.ClassName, Relation]);
  Result := M.Relations[Idx];
  if Result.Kind <> rkBelongsToMany then
    raise EModelError.CreateFmt(
      '%s: "%s" on %s is not a BelongsToMany relation, so it has no pivot',
      [Caller, Relation, M.ModelClass.ClassName]);
end;

function PivotIdent(C: TDbConnection; A: TArena; const Name_: string): string;
var
  B: TStrBuilder;
begin
  B.Init(A, Length(Name_) + 4);
  C.AppendIdentStr(B, Name_);
  Result := B.ToString;
end;

function PivotPh(C: TDbConnection; A: TArena; Index: Integer): string;
var
  B: TStrBuilder;
begin
  B.Init(A, 8);
  C.AppendPlaceholder(B, Index);
  Result := B.ToString;
end;

{ Each id once, in the order first given. Zero and below are refused: no
  table has that row, and in Pascal zero is how "none" is said -- letting
  it through would write a pivot row to nothing. }
function DistinctIds(const Ids: array of Int64; const Caller: string):
  TArray<Int64>;
var
  I, J, N: Integer;
  Seen: Boolean;
  Out_: TArray<Int64>;
begin
  SetLength(Out_, Length(Ids));
  N := 0;
  for I := 0 to High(Ids) do
  begin
    if Ids[I] <= 0 then
      raise EModelError.CreateFmt('%s: %d is not the id of a row', [Caller, Ids[I]]);
    Seen := False;
    for J := 0 to N - 1 do
      if Out_[J] = Ids[I] then
      begin
        Seen := True;
        Break;
      end;
    if not Seen then
    begin
      Out_[N] := Ids[I];
      Inc(N);
    end;
  end;
  SetLength(Out_, N);
  Result := Out_;
end;

function HasId(const Ids: TArray<Int64>; Id: Int64): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(Ids) do
    if Ids[I] = Id then
      Exit(True);
  Result := False;
end;

function PivotIdsOf(C: TDbConnection; A: TArena; const Rel: TRelationInfo;
  OwnerId: Int64): TArray<Int64>;
var
  R: TDbResult;
  I: Integer;
  Out_: TArray<Int64>;
begin
  R := C.ExecParams(A, 'SELECT ' + PivotIdent(C, A, Rel.PivotRelatedKey) +
    ' FROM ' + PivotIdent(C, A, Rel.Pivot) +
    ' WHERE ' + PivotIdent(C, A, Rel.ForeignKey) + ' = ' + PivotPh(C, A, 1) +
    ' ORDER BY ' + PivotIdent(C, A, Rel.PivotRelatedKey),
    [DbParam(A, OwnerId)]);
  SetLength(Out_, R.RowCount);
  for I := 0 to R.RowCount - 1 do
    Out_[I] := R.AsInt64(I, 0);
  Result := Out_;
end;

procedure PivotInsert(C: TDbConnection; A: TArena; const Rel: TRelationInfo;
  OwnerId, Id: Int64);
begin
  C.ExecParams(A, 'INSERT INTO ' + PivotIdent(C, A, Rel.Pivot) + ' (' +
    PivotIdent(C, A, Rel.ForeignKey) + ', ' +
    PivotIdent(C, A, Rel.PivotRelatedKey) + ') VALUES (' +
    PivotPh(C, A, 1) + ', ' + PivotPh(C, A, 2) + ')',
    [DbParam(A, OwnerId), DbParam(A, Id)]);
end;

{ Removes the given ids, or all of them when All. Never all by accident:
  an empty list with All false is nothing to do. }
procedure PivotDelete(C: TDbConnection; A: TArena; const Rel: TRelationInfo;
  OwnerId: Int64; const Ids: TArray<Int64>; All: Boolean);
var
  Sql: string;
  Params: array of TDbParam;
  I: Integer;
begin
  if not All and (Length(Ids) = 0) then
    Exit;
  Sql := 'DELETE FROM ' + PivotIdent(C, A, Rel.Pivot) + ' WHERE ' +
    PivotIdent(C, A, Rel.ForeignKey) + ' = ' + PivotPh(C, A, 1);
  SetLength(Params, 1);
  Params[0] := DbParam(A, OwnerId);
  if not All then
  begin
    Sql := Sql + ' AND ' + PivotIdent(C, A, Rel.PivotRelatedKey) + ' IN (';
    SetLength(Params, Length(Ids) + 1);
    for I := 0 to High(Ids) do
    begin
      if I > 0 then
        Sql := Sql + ', ';
      Sql := Sql + PivotPh(C, A, I + 2);
      Params[I + 1] := DbParam(A, Ids[I]);
    end;
    Sql := Sql + ')';
  end;
  C.ExecParams(A, Sql, Params);
end;

{ The id the pivot rows point at. A model that has never been saved has
  none, and a pivot row to id 0 is a row to nothing. }
function OwnerIdFor(M: TModel; const Caller: string): Int64;
begin
  Result := M.PrimaryKeyValue;
  if not M.Persisted or (Result = 0) then
    raise EModelError.CreateFmt(
      '%s: save the %s first -- the pivot row points at its id, and it has none yet',
      [Caller, M.ClassName]);
end;

function TModel.RelatedIds(const Relation: string;
  Conn: TDbConnection): TArray<Int64>;
var
  Rel: TRelationInfo;
  C: TDbConnection;
  A: TArena;
begin
  Rel := ManyToManyOf(Meta, Relation, 'RelatedIds');
  C := RequireDb(Conn);
  A := TArena.Create(4 * 1024);
  try
    Result := PivotIdsOf(C, A, Rel, OwnerIdFor(Self, 'RelatedIds'));
  finally
    A.Free;
  end;
end;

procedure TModel.Attach(const Relation: string; const Ids: array of Int64;
  Conn: TDbConnection);
var
  Rel: TRelationInfo;
  C: TDbConnection;
  A: TArena;
  Wanted, Have: TArray<Int64>;
  OwnerId: Int64;
  I: Integer;
  Own: Boolean;
begin
  Rel := ManyToManyOf(Meta, Relation, 'Attach');
  OwnerId := OwnerIdFor(Self, 'Attach');
  Wanted := DistinctIds(Ids, 'Attach');
  if Length(Wanted) = 0 then
    Exit;
  C := RequireDb(Conn);
  A := TArena.Create(8 * 1024);
  Own := not C.InTransaction;
  try
    if Own then
      C.StartTransaction;
    try
      Have := PivotIdsOf(C, A, Rel, OwnerId);
      for I := 0 to High(Wanted) do
        if not HasId(Have, Wanted[I]) then
          PivotInsert(C, A, Rel, OwnerId, Wanted[I]);
      if Own then
        C.Commit;
    except
      if Own then
        C.Rollback;
      raise;
    end;
  finally
    A.Free;
  end;
end;

procedure TModel.Detach(const Relation: string; const Ids: array of Int64;
  Conn: TDbConnection);
var
  Rel: TRelationInfo;
  A: TArena;
  Gone: TArray<Int64>;
  OwnerId: Int64;
  C: TDbConnection;
begin
  Rel := ManyToManyOf(Meta, Relation, 'Detach');
  OwnerId := OwnerIdFor(Self, 'Detach');
  Gone := DistinctIds(Ids, 'Detach');
  if Length(Gone) = 0 then
    Exit;
  C := RequireDb(Conn);
  A := TArena.Create(4 * 1024);
  try
    PivotDelete(C, A, Rel, OwnerId, Gone, False);
  finally
    A.Free;
  end;
end;

procedure TModel.DetachAll(const Relation: string; Conn: TDbConnection);
var
  Rel: TRelationInfo;
  A: TArena;
  OwnerId: Int64;
  C: TDbConnection;
begin
  Rel := ManyToManyOf(Meta, Relation, 'DetachAll');
  OwnerId := OwnerIdFor(Self, 'DetachAll');
  C := RequireDb(Conn);
  A := TArena.Create(4 * 1024);
  try
    PivotDelete(C, A, Rel, OwnerId, nil, True);
  finally
    A.Free;
  end;
end;

procedure TModel.Sync(const Relation: string; const Ids: array of Int64;
  Conn: TDbConnection);
var
  Rel: TRelationInfo;
  C: TDbConnection;
  A: TArena;
  Wanted, Have, Gone: TArray<Int64>;
  OwnerId: Int64;
  I, N: Integer;
  Own: Boolean;
begin
  Rel := ManyToManyOf(Meta, Relation, 'Sync');
  OwnerId := OwnerIdFor(Self, 'Sync');
  Wanted := DistinctIds(Ids, 'Sync');
  C := RequireDb(Conn);
  A := TArena.Create(8 * 1024);
  Own := not C.InTransaction;
  try
    if Own then
      C.StartTransaction;
    try
      Have := PivotIdsOf(C, A, Rel, OwnerId);
      SetLength(Gone, Length(Have));
      N := 0;
      for I := 0 to High(Have) do
        if not HasId(Wanted, Have[I]) then
        begin
          Gone[N] := Have[I];
          Inc(N);
        end;
      SetLength(Gone, N);
      PivotDelete(C, A, Rel, OwnerId, Gone, False);
      for I := 0 to High(Wanted) do
        if not HasId(Have, Wanted[I]) then
          PivotInsert(C, A, Rel, OwnerId, Wanted[I]);
      if Own then
        C.Commit;
    except
      if Own then
        C.Rollback;
      raise;
    end;
  finally
    A.Free;
  end;
end;

procedure TModel.Save(Conn: TDbConnection);
var
  C: TDbConnection;
  M: TModelMeta;
  A: TArena;
  B: TStrBuilder;
  Params: array of TDbParam;
  I, N, PkIdx, TsIdx: Integer;
  Sql: string;
  NewId: Int64;
  Mark: TArenaMark;
  Now_: TDateTime;
  WasNew: Boolean;
begin
  C := RequireDb(Conn);
  M := Meta;
  A := Arena;
  if A = nil then
    raise EModelError.Create('Save requires the model to live in an arena');

  PkIdx := M.PrimaryKeyIndex;
  { Read before the SQL runs: INSERT sets FPersisted, and afterwards
    everything looks like an update. }
  WasNew := not FPersisted;

  BeforeSave;
  if FPersisted then
    BeforeUpdate
  else
    BeforeInsert;

  { The timestamps are set here, not by the database's DEFAULT. Before
    this, created_at was set by DEFAULT and updated_at never touched again
    — a row updated ten times looked as fresh as when it was made. }
  if M.HasTimestamps then
  begin
    Now_ := UtcNow;
    if not FPersisted then
    begin
      TsIdx := M.IndexOfColumn(M.CreatedAtColumn);
      { Only when it is not already set: an import preserving original
        times must not have them overwritten. }
      if (TsIdx >= 0) and (GetFloatProp(Self, M.Columns[TsIdx].Prop) = 0) then
        SetFloatProp(Self, M.Columns[TsIdx].Prop, Now_);
    end;
    TsIdx := M.IndexOfColumn(M.UpdatedAtColumn);
    if TsIdx >= 0 then
      SetFloatProp(Self, M.Columns[TsIdx].Prop, Now_);
  end;

  Mark := A.Mark;
  try
    SetLength(Params, 0);
    B.Init(A, 256);

    if not FPersisted then
    begin
      B.Append('INSERT INTO ');
      C.AppendIdentStr(B, M.Table);
      B.Append(' (');
      N := 0;
      for I := 0 to M.ColumnCount - 1 do
      begin
        if not M.Columns[I].Insertable then
          Continue;
        if N > 0 then
          B.Append(', ');
        C.AppendIdentStr(B, M.Columns[I].ColumnName);
        Inc(N);
      end;
      B.Append(') VALUES (');
      SetLength(Params, N);
      N := 0;
      for I := 0 to M.ColumnCount - 1 do
      begin
        if not M.Columns[I].Insertable then
          Continue;
        if N > 0 then
          B.Append(', ');
        C.AppendPlaceholder(B, N + 1);
        Params[N] := ParamFor(A, Self, M.Columns[I]);
        Inc(N);
      end;
      B.AppendByte(Ord(')'));
      Sql := B.ToString;

      if M.AutoIncrement and (PkIdx >= 0) then
      begin
        NewId := C.InsertGetId(A, Sql, Params, M.PrimaryKey);
        if NewId <> 0 then
          SetPrimaryKeyValue(NewId);
      end
      else
        C.ExecParams(A, Sql, Params);
      FPersisted := True;
    end
    else
    begin
      if PkIdx < 0 then
        raise EModelError.CreateFmt(
          '%s has no primary key "%s" and cannot be updated',
          [M.ModelClass.ClassName, M.PrimaryKey]);

      B.Append('UPDATE ');
      C.AppendIdentStr(B, M.Table);
      B.Append(' SET ');
      N := 0;
      SetLength(Params, M.ColumnCount);
      for I := 0 to M.ColumnCount - 1 do
      begin
        if I = PkIdx then
          Continue;
        if N > 0 then
          B.Append(', ');
        C.AppendIdentStr(B, M.Columns[I].ColumnName);
        B.Append(' = ');
        C.AppendPlaceholder(B, N + 1);
        Params[N] := ParamFor(A, Self, M.Columns[I]);
        Inc(N);
      end;
      B.Append(' WHERE ');
      C.AppendIdentStr(B, M.PrimaryKey);
      B.Append(' = ');
      C.AppendPlaceholder(B, N + 1);
      Params[N] := ParamFor(A, Self, M.Columns[PkIdx]);
      Inc(N);
      SetLength(Params, N);
      Sql := B.ToString;
      C.ExecParams(A, Sql, Params);
    end;
  finally
    { The SQL text and the parameters are not needed after the call. }
    A.Rewind(Mark);
  end;

  if WasNew then
    AfterInsert
  else
    AfterUpdate;
  AfterSave;
end;

{ Common to Delete, ForceDelete and Restore: set a TDateTime column and
  write the row. All three are "update one column on one row". }
procedure SetDateAndSave(Model: TModel; C: TDbConnection; A: TArena;
  M: TModelMeta; ColIdx, PkIdx: Integer; Value_: TDateTime);
var
  B: TStrBuilder;
  Mark: TArenaMark;
begin
  SetFloatProp(Model, M.Columns[ColIdx].Prop, Value_);
  Mark := A.Mark;
  try
    B.Init(A, 160);
    B.Append('UPDATE ');
    C.AppendIdentStr(B, M.Table);
    B.Append(' SET ');
    C.AppendIdentStr(B, M.Columns[ColIdx].ColumnName);
    B.Append(' = ');
    C.AppendPlaceholder(B, 1);
    B.Append(' WHERE ');
    C.AppendIdentStr(B, M.PrimaryKey);
    B.Append(' = ');
    C.AppendPlaceholder(B, 2);
    C.ExecParams(A, B.ToString,
      [ParamFor(A, Model, M.Columns[ColIdx]),
       ParamFor(A, Model, M.Columns[PkIdx])]);
  finally
    A.Rewind(Mark);
  end;
end;

procedure TModel.ForceDelete(Conn: TDbConnection);
var
  C: TDbConnection;
  M: TModelMeta;
  A: TArena;
  B: TStrBuilder;
  Mark: TArenaMark;
  PkIdx: Integer;
begin
  C := RequireDb(Conn);
  M := Meta;
  A := Arena;
  if A = nil then
    raise EModelError.Create('Delete requires the model to live in an arena');
  PkIdx := M.PrimaryKeyIndex;
  if PkIdx < 0 then
    raise EModelError.CreateFmt('%s has no primary key',
      [M.ModelClass.ClassName]);

  BeforeDelete;
  Mark := A.Mark;
  try
    B.Init(A, 128);
    B.Append('DELETE FROM ');
    C.AppendIdentStr(B, M.Table);
    B.Append(' WHERE ');
    C.AppendIdentStr(B, M.PrimaryKey);
    B.Append(' = ');
    C.AppendPlaceholder(B, 1);
    C.ExecParams(A, B.ToString, [ParamFor(A, Self, M.Columns[PkIdx])]);
  finally
    A.Rewind(Mark);
  end;
  FPersisted := False;
  AfterDelete;
end;

procedure TModel.Restore(Conn: TDbConnection);
var
  C: TDbConnection;
  M: TModelMeta;
  A: TArena;
  PkIdx, PartIdx: Integer;
begin
  M := Meta;
  if not M.SoftDeletes then
    raise EModelError.CreateFmt(
      '%s has no soft deletes; there is nothing to restore. Add ' +
      'S.SoftDeletes in Describe if that is what you meant.',
      [M.ModelClass.ClassName]);
  C := RequireDb(Conn);
  A := Arena;
  if A = nil then
    raise EModelError.Create('Restore requires the model to live in an arena');
  PkIdx := M.PrimaryKeyIndex;
  PartIdx := M.IndexOfColumn(M.DeletedAtColumn);
  if (PkIdx < 0) or (PartIdx < 0) then
    raise EModelError.CreateFmt('%s cannot be restored',
      [M.ModelClass.ClassName]);
  { 0 is "not set" for a TDateTime here, and ParamFor writes NULL for it.
    That is the same rule the rest of the date layer uses. }
  SetDateAndSave(Self, C, A, M, PartIdx, PkIdx, 0);
end;

procedure TModel.Delete(Conn: TDbConnection);
var
  C: TDbConnection;
  M: TModelMeta;
  A: TArena;
  PkIdx, PartIdx: Integer;
begin
  M := Meta;
  if not M.SoftDeletes then
  begin
    ForceDelete(Conn);
    Exit;
  end;

  C := RequireDb(Conn);
  A := Arena;
  if A = nil then
    raise EModelError.Create('Delete requires the model to live in an arena');
  PkIdx := M.PrimaryKeyIndex;
  PartIdx := M.IndexOfColumn(M.DeletedAtColumn);
  if (PkIdx < 0) or (PartIdx < 0) then
    raise EModelError.CreateFmt('%s has no primary key',
      [M.ModelClass.ClassName]);

  BeforeDelete;
  SetDateAndSave(Self, C, A, M, PartIdx, PkIdx, UtcNow);
  { The row still exists. Persisted stays set, so a following Save
    updates it rather than inserting a new one. }
  AfterDelete;
end;

initialization
  GMetaLock := TCriticalSection.Create;

finalization
  GMetaLock.Free;

end.
