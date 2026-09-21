{ Askr.Urd.Query — typede spørringer.

  Dette er den delen PRD-en selv kaller den svakeste i designet, og den delen
  som avgjør om premisset holder. Pascal har ingen __callStatic, så Eloquents
  Customer::where(...) finnes ikke. To_ gjengjeld gir typede kolonner noe
  Eloquent aldri har klart: kompileringsfeil på skrivefeil og feil verditype.

      Query<TCustomer>
        .Where(Customers.Balance, GT, 0)
        .Where(Customers.Email, Like, '%@gets.no')
        .OrderBy(Customers.CreatedAt, Desc)
        .Limit(50)
        .Get;

  .Where(Customers.Balance, GT, 'abc') kompilerer ikke.

  Mekanikken: TCol<T> er en generisk record, og spesialiseringer av den er
  distinkte typer. Where er overlastet på hver av dem, med verditypen som
  følger. Det er derfor Free Pascal klarer dette uten generiske metoder —
  som kompilatoren forøvrig ikke tillater inne i en generisk klasse.

  To avvik fra PRD-en, begge tvunget fram av Free Pascal 3.2.2:

    * Eager loading heter Preload, ikke With. With er et reservert ord.
    * Inngangen er TQuery<TCustomer>.New, ikke Query<TCustomer>. En generisk
      frittstående funksjon kan ikke eksporteres fra en unit i 3.2.2:
      deklarasjon og implementasjon får ulike mangled navn på
      typeparameteren, og varianter av det samme får kompilatoren til å
      krasje. Det samme gjelder generisk klassemetode på en ikke-generisk
      klasse. Virker det på trunk, er Query<TCustomer> ett navnebytte unna. }
unit Askr.Urd.Query;

{$mode Delphi}{$H+}
{$POINTERMATH ON}

interface

uses
  SysUtils, TypInfo,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Clock,
  Askr.Urd.Driver, Askr.Urd.Model;

type
  { Genereres av Norn i steg 3. To_ da skrives disse for hånd. }
  TCol<T> = record
    Name: ShortString;
    Table: ShortString;
  end;

  TColInt64 = TCol<Int64>;
  TColStr = TCol<string>;
  TColCurrency = TCol<Currency>;
  TColFloat = TCol<Double>;
  TColBool = TCol<Boolean>;
  TColDateTime = TCol<TDateTime>;

  { Navnene er korte fordi de står midt i en spørring og leses som operatorer. }
  TSqlOp = (Eq, Ne, GT, GTE, LT, LTE, Like, ILike);
  TSqlDir = (Asc, Desc);

  EQueryError = class(EDbError);

  PWhereTerm = ^TWhereTerm;
  TWhereTerm = record
    Table: ShortString;
    Column: ShortString;
    Op: TSqlOp;
    Param: TDbParam;
    { Null-sjekk har ingen parameter. }
    NullCheck: Boolean;
    WantNull: Boolean;
    { IN-liste: ParamFirst..ParamFirst+ParamCount-1 i FInParams. }
    InList: Boolean;
    ParamFirst: Integer;
    ParamCount: Integer;
    { Bindes med OR til leddet foran i stedet for AND. En gruppe slike
      settes i parentes ved bygging, slik at presedensen blir
      `a = 1 AND (b ILIKE x OR c ILIKE x)` og ikke noe annet. }
    OrPrev: Boolean;
  end;

  POrderTerm = ^TOrderTerm;
  TOrderTerm = record
    Table: ShortString;
    Column: ShortString;
    Dir: TSqlDir;
  end;

  { Arver Count, Item og IsEmpty fra TModelListBase, slik at serialisering og
    eager loading kan jobbe med lista uten å kjenne M. }
  TModelList<M: TModel> = class(TModelListBase)
  private
    function GetItem(Index: Integer): M;
  public
    procedure Add(AItem: M);
    function First: M;
    property Items[Index: Integer]: M read GetItem; default;
  end;

  TQuery<M: TModel> = class(TArenaObject)
  private
    FModelClass: TModelClass;
    FMeta: TModelMeta;
    FConn: TDbConnection;
    FWheres: PWhereTerm;
    FWhereCount: Integer;
    FWhereCapacity: Integer;
    FOrders: POrderTerm;
    FOrderCount: Integer;
    FOrderCapacity: Integer;
    FInParams: PDbParam;
    FInCount: Integer;
    FInCapacity: Integer;
    FPreloads: array of string;
    FLimit: Integer;
    FOffset: Integer;
    FTrashed: (tsUten, tsMed, tsBare);
    function AddWhere: PWhereTerm;
    function AddOrder: POrderTerm;
    function AddInParam(const P: TDbParam): Integer;
    function SoftDeleteClause(out Bare: Boolean): Boolean;
    function SoftDeleteAll: Int64;
    procedure BuildWhere(var B: TStrBuilder; var ParamNo: Integer;
      var Params: TArray<TDbParam>);
    procedure BuildTail(var B: TStrBuilder);
    function Conn: TDbConnection;
    procedure LoadRelation(List: TModelList<M>; const RelName: string);
  public
    constructor Create(AModelClass: TModelClass; AConn: TDbConnection = nil);

    { Inngangen:  TQuery<TCustomer>.New.Where(...).Get

      PRD-en skriver Query<TCustomer>. Den formen krever en generisk
      frittstående funksjon eksportert fra en unit, og det klarer ikke
      Free Pascal 3.2.2 — se kommentaren nederst i denne fila. Klassemetoden
      gir samme typesikkerhet og fire tegn mer å skrive. }
    class function New: TQuery<M>;
    { Samme, mot en bestemt forbindelse i stedet for den omgivende. }
    class function Using(AConn: TDbConnection): TQuery<M>;

    { Myktslettede rader utelates som standard. Det er hele poenget med
      soft deletes: en glemt `WHERE deleted_at IS NULL` er akkurat den
      feilen mekanismen skal gjøre umulig.

      WithTrashed tar dem med, OnlyTrashed viser bare dem. På en modell
      uten SoftDeletes gjør begge ingenting. }
    function WithTrashed: TQuery<M>;
    function OnlyTrashed: TQuery<M>;

    function Where(const Col: TColInt64; Op: TSqlOp; Value: Int64): TQuery<M>; overload;
    function Where(const Col: TColStr; Op: TSqlOp; const Value: string): TQuery<M>; overload;
    function Where(const Col: TColCurrency; Op: TSqlOp; Value: Currency): TQuery<M>; overload;
    function Where(const Col: TColFloat; Op: TSqlOp; Value: Double): TQuery<M>; overload;
    function Where(const Col: TColBool; Op: TSqlOp; Value: Boolean): TQuery<M>; overload;
    function Where(const Col: TColDateTime; Op: TSqlOp; Value: TDateTime): TQuery<M>; overload;

    { Fritekstsøk over flere kolonner: ett uttrykk, OR mellom kolonnene.

      Without denne har TQuery bare AND, og «finn Ada i navn eller e-post» lar
      seg ikke uttrykke. Den er med vilje smal — én operator, ett uttrykk,
      ingen nøsting — fordi et generelt grupperingsspråk er et større
      spørsmål enn det en liste trenger. Tom tekst eller tom kolonneliste
      legger ikke på noe ledd. }
    function WhereAnyLike(const Cols: array of TColStr;
      const Text: string; CaseSensitive: Boolean = False): TQuery<M>;

    function WhereIn(const Col: TColInt64; const Values: array of Int64): TQuery<M>; overload;
    function WhereIn(const Col: TColStr; const Values: array of string): TQuery<M>; overload;

    function WhereNull(const Col: TColInt64): TQuery<M>; overload;
    function WhereNull(const Col: TColStr): TQuery<M>; overload;
    function WhereNull(const Col: TColCurrency): TQuery<M>; overload;
    function WhereNull(const Col: TColDateTime): TQuery<M>; overload;
    function WhereNotNull(const Col: TColInt64): TQuery<M>; overload;
    function WhereNotNull(const Col: TColStr): TQuery<M>; overload;
    function WhereNotNull(const Col: TColCurrency): TQuery<M>; overload;
    function WhereNotNull(const Col: TColDateTime): TQuery<M>; overload;

    function OrderBy(const Col: TColInt64; Dir: TSqlDir = Asc): TQuery<M>; overload;
    function OrderBy(const Col: TColStr; Dir: TSqlDir = Asc): TQuery<M>; overload;
    function OrderBy(const Col: TColCurrency; Dir: TSqlDir = Asc): TQuery<M>; overload;
    function OrderBy(const Col: TColFloat; Dir: TSqlDir = Asc): TQuery<M>; overload;
    function OrderBy(const Col: TColDateTime; Dir: TSqlDir = Asc): TQuery<M>; overload;

    function Limit(N: Integer): TQuery<M>;
    function Offset(N: Integer): TQuery<M>;

    { Eager loading. Heter ikke With fordi with er et reservert ord. }
    function Preload(const Relations: array of string): TQuery<M>;

    function Get: TModelList<M>;
    function First: M;
    function Find(Id: Int64): M;
    function Count: Int64;
    function Paginate(Page, PerPage: Integer): TModelList<M>;
    { Sletter alt som matcher. Returnerer antall rader. }
    { With_ SoftDeletes setter denne deleted_at, som Model.Delete gjør.
      ForceDeleteAll sletter uansett. RestoreAll tar de myktslettede
      tilbake. }
    function DeleteAll: Int64;
    function ForceDeleteAll: Int64;
    function RestoreAll: Int64;

    { SQL-en spørringen ville kjørt. Finnes for feilsøking og for tester som
      ikke vil ha en database. }
    function ToSql: string;
  end;

{ Ligger i interface fordi generiske metoder i FPC 3.2.2 ikke får referere
  symboler som bare finnes i implementation-seksjonen. }
function OpText(Op: TSqlOp; Dialect: TSqlDialect): string;

{ Hjelper til å skrive kolonnekonstanter for hånd inntil Norn genererer dem. }
function ColInt64(const ATable, AName: string): TColInt64;
function ColStr(const ATable, AName: string): TColStr;
function ColCurrency(const ATable, AName: string): TColCurrency;
function ColFloat(const ATable, AName: string): TColFloat;
function ColBool(const ATable, AName: string): TColBool;
function ColDateTime(const ATable, AName: string): TColDateTime;

implementation

function ColInt64(const ATable, AName: string): TColInt64;
begin
  Result.Table := ATable;
  Result.Name := AName;
end;

function ColStr(const ATable, AName: string): TColStr;
begin
  Result.Table := ATable;
  Result.Name := AName;
end;

function ColCurrency(const ATable, AName: string): TColCurrency;
begin
  Result.Table := ATable;
  Result.Name := AName;
end;

function ColFloat(const ATable, AName: string): TColFloat;
begin
  Result.Table := ATable;
  Result.Name := AName;
end;

function ColBool(const ATable, AName: string): TColBool;
begin
  Result.Table := ATable;
  Result.Name := AName;
end;

function ColDateTime(const ATable, AName: string): TColDateTime;
begin
  Result.Table := ATable;
  Result.Name := AName;
end;

{ ILIKE finnes bare i Postgres.

  I MySQL og SQLite er LIKE allerede ufølsomt for store og små bokstaver —
  i MySQL fordi kollasjonen er det (utf8mb4 med ai_ci, som er standarden), i
  SQLite fordi den innebygde LIKE er det for ASCII. Den siste er verdt å
  vite: SQLite skiller fortsatt «é» fra «É», fordi ICU ikke er med i den
  vanlige byggingen. Det er en reell forskjell mellom dialektene, og den
  skal stå skrevet i stedet for å oppdages.

  Før dette ble ILIKE sendt ordrett til alle tre, og en spørring med ILike
  mot SQLite feilet med «near "ILIKE": syntax error». }
function OpText(Op: TSqlOp; Dialect: TSqlDialect): string;
begin
  case Op of
    Eq:    Result := ' = ';
    Ne:    Result := ' <> ';
    GT:    Result := ' > ';
    GTE:   Result := ' >= ';
    LT:    Result := ' < ';
    LTE:   Result := ' <= ';
    Like:  Result := ' LIKE ';
    ILike:
      if Dialect = sdPostgres then
        Result := ' ILIKE '
      else
        Result := ' LIKE ';
  end;
  { Ingen else: alle TSqlOp er dekket. Se kommentaren i Askr.Urd.Model. }
end;

{ TModelList<M> }

procedure TModelList<M>.Add(AItem: M);
begin
  AddPointer(Pointer(AItem));
end;

function TModelList<M>.GetItem(Index: Integer): M;
begin
  if (Index < 0) or (Index >= Count) then
    raise EQueryError.CreateFmt('Indeks %d utenfor 0..%d', [Index, Count - 1]);
  Result := M(Item(Index));
end;

function TModelList<M>.First: M;
begin
  Result := M(Item(0));
end;

{ TQuery<M> }

constructor TQuery<M>.Create(AModelClass: TModelClass; AConn: TDbConnection);
begin
  inherited Create;
  FModelClass := AModelClass;
  FMeta := AModelClass.Meta;
  FConn := AConn;
  FLimit := -1;
  FOffset := -1;
end;

function TQuery<M>.Conn: TDbConnection;
begin
  if FConn <> nil then
    Exit(FConn);
  Result := CurrentDb;
  if Result = nil then
    raise EQueryError.Create(
      'No database connection. Pass one to Query, or set the ambient ' +
      'one with UseDb.');
end;

function TQuery<M>.AddWhere: PWhereTerm;
var
  NewCap: Integer;
  NewPtr: PWhereTerm;
begin
  if FWhereCount >= FWhereCapacity then
  begin
    if FWhereCapacity = 0 then
      NewCap := 8
    else
      NewCap := FWhereCapacity * 2;
    NewPtr := PWhereTerm(Arena.AllocZero(PtrUInt(NewCap) * SizeOf(TWhereTerm)));
    if FWhereCount > 0 then
      Move(FWheres^, NewPtr^, PtrUInt(FWhereCount) * SizeOf(TWhereTerm));
    FWheres := NewPtr;
    FWhereCapacity := NewCap;
  end;
  Result := FWheres + FWhereCount;
  Inc(FWhereCount);
end;

function TQuery<M>.AddOrder: POrderTerm;
var
  NewCap: Integer;
  NewPtr: POrderTerm;
begin
  if FOrderCount >= FOrderCapacity then
  begin
    if FOrderCapacity = 0 then
      NewCap := 4
    else
      NewCap := FOrderCapacity * 2;
    NewPtr := POrderTerm(Arena.AllocZero(PtrUInt(NewCap) * SizeOf(TOrderTerm)));
    if FOrderCount > 0 then
      Move(FOrders^, NewPtr^, PtrUInt(FOrderCount) * SizeOf(TOrderTerm));
    FOrders := NewPtr;
    FOrderCapacity := NewCap;
  end;
  Result := FOrders + FOrderCount;
  Inc(FOrderCount);
end;

function TQuery<M>.AddInParam(const P: TDbParam): Integer;
var
  NewCap: Integer;
  NewPtr: PDbParam;
begin
  if FInCount >= FInCapacity then
  begin
    if FInCapacity = 0 then
      NewCap := 16
    else
      NewCap := FInCapacity * 2;
    NewPtr := PDbParam(Arena.AllocZero(PtrUInt(NewCap) * SizeOf(TDbParam)));
    if FInCount > 0 then
      Move(FInParams^, NewPtr^, PtrUInt(FInCount) * SizeOf(TDbParam));
    FInParams := NewPtr;
    FInCapacity := NewCap;
  end;
  FInParams[FInCount] := P;
  Result := FInCount;
  Inc(FInCount);
end;

function TQuery<M>.Where(const Col: TColInt64; Op: TSqlOp; Value: Int64): TQuery<M>;
var
  W: PWhereTerm;
begin
  W := AddWhere;
  W^.Table := Col.Table;
  W^.Column := Col.Name;
  W^.Op := Op;
  W^.Param := DbParam(Arena, Value);
  Result := Self;
end;

function TQuery<M>.Where(const Col: TColStr; Op: TSqlOp; const Value: string): TQuery<M>;
var
  W: PWhereTerm;
begin
  W := AddWhere;
  W^.Table := Col.Table;
  W^.Column := Col.Name;
  W^.Op := Op;
  W^.Param := DbParam(Arena, Value);
  Result := Self;
end;

function TQuery<M>.Where(const Col: TColCurrency; Op: TSqlOp; Value: Currency): TQuery<M>;
var
  W: PWhereTerm;
begin
  W := AddWhere;
  W^.Table := Col.Table;
  W^.Column := Col.Name;
  W^.Op := Op;
  W^.Param := DbParam(Arena, Value);
  Result := Self;
end;

function TQuery<M>.Where(const Col: TColFloat; Op: TSqlOp; Value: Double): TQuery<M>;
var
  W: PWhereTerm;
begin
  W := AddWhere;
  W^.Table := Col.Table;
  W^.Column := Col.Name;
  W^.Op := Op;
  W^.Param := DbParam(Arena, FloatToSql(Value));
  Result := Self;
end;

function TQuery<M>.Where(const Col: TColBool; Op: TSqlOp; Value: Boolean): TQuery<M>;
var
  W: PWhereTerm;
begin
  W := AddWhere;
  W^.Table := Col.Table;
  W^.Column := Col.Name;
  W^.Op := Op;
  W^.Param := DbParam(Arena, Value);
  Result := Self;
end;

function TQuery<M>.Where(const Col: TColDateTime; Op: TSqlOp; Value: TDateTime): TQuery<M>;
var
  W: PWhereTerm;
begin
  W := AddWhere;
  W^.Table := Col.Table;
  W^.Column := Col.Name;
  W^.Op := Op;
  W^.Param := DbParamDateTime(Arena, Value);
  Result := Self;
end;

function TQuery<M>.WhereAnyLike(const Cols: array of TColStr;
  const Text: string; CaseSensitive: Boolean): TQuery<M>;
var
  I: Integer;
  W: PWhereTerm;
  Op: TSqlOp;
  Moenster: string;
begin
  Result := Self;
  if (Length(Cols) = 0) or (Text = '') then
    Exit;

  if CaseSensitive then
    Op := Like
  else
    Op := ILike;
  Moenster := '%' + Text + '%';

  for I := 0 to High(Cols) do
  begin
    W := AddWhere;
    W^.Table := Cols[I].Table;
    W^.Column := Cols[I].Name;
    W^.Op := Op;
    W^.Param := DbParam(Arena, Moenster);
    { Første ledd i gruppa bindes som vanlig til det som står foran; de
      andre med OR. Parentesen settes ved bygging. }
    W^.OrPrev := I > 0;
  end;
end;

function TQuery<M>.WhereIn(const Col: TColInt64; const Values: array of Int64): TQuery<M>;
var
  W: PWhereTerm;
  I, First_: Integer;
begin
  W := AddWhere;
  W^.Table := Col.Table;
  W^.Column := Col.Name;
  W^.InList := True;
  First_ := FInCount;
  for I := 0 to High(Values) do
    AddInParam(DbParam(Arena, Values[I]));
  W^.ParamFirst := First_;
  W^.ParamCount := Length(Values);
  Result := Self;
end;

function TQuery<M>.WhereIn(const Col: TColStr; const Values: array of string): TQuery<M>;
var
  W: PWhereTerm;
  I, First_: Integer;
begin
  W := AddWhere;
  W^.Table := Col.Table;
  W^.Column := Col.Name;
  W^.InList := True;
  First_ := FInCount;
  for I := 0 to High(Values) do
    AddInParam(DbParam(Arena, Values[I]));
  W^.ParamFirst := First_;
  W^.ParamCount := Length(Values);
  Result := Self;
end;

function TQuery<M>.WhereNull(const Col: TColInt64): TQuery<M>;
var W: PWhereTerm;
begin
  W := AddWhere; W^.Table := Col.Table; W^.Column := Col.Name;
  W^.NullCheck := True; W^.WantNull := True; Result := Self;
end;

function TQuery<M>.WhereNull(const Col: TColStr): TQuery<M>;
var W: PWhereTerm;
begin
  W := AddWhere; W^.Table := Col.Table; W^.Column := Col.Name;
  W^.NullCheck := True; W^.WantNull := True; Result := Self;
end;

function TQuery<M>.WhereNull(const Col: TColCurrency): TQuery<M>;
var W: PWhereTerm;
begin
  W := AddWhere; W^.Table := Col.Table; W^.Column := Col.Name;
  W^.NullCheck := True; W^.WantNull := True; Result := Self;
end;

function TQuery<M>.WhereNull(const Col: TColDateTime): TQuery<M>;
var W: PWhereTerm;
begin
  W := AddWhere; W^.Table := Col.Table; W^.Column := Col.Name;
  W^.NullCheck := True; W^.WantNull := True; Result := Self;
end;

function TQuery<M>.WhereNotNull(const Col: TColInt64): TQuery<M>;
var W: PWhereTerm;
begin
  W := AddWhere; W^.Table := Col.Table; W^.Column := Col.Name;
  W^.NullCheck := True; Result := Self;
end;

function TQuery<M>.WhereNotNull(const Col: TColStr): TQuery<M>;
var W: PWhereTerm;
begin
  W := AddWhere; W^.Table := Col.Table; W^.Column := Col.Name;
  W^.NullCheck := True; Result := Self;
end;

function TQuery<M>.WhereNotNull(const Col: TColCurrency): TQuery<M>;
var W: PWhereTerm;
begin
  W := AddWhere; W^.Table := Col.Table; W^.Column := Col.Name;
  W^.NullCheck := True; Result := Self;
end;

function TQuery<M>.WhereNotNull(const Col: TColDateTime): TQuery<M>;
var W: PWhereTerm;
begin
  W := AddWhere; W^.Table := Col.Table; W^.Column := Col.Name;
  W^.NullCheck := True; Result := Self;
end;

function TQuery<M>.OrderBy(const Col: TColInt64; Dir: TSqlDir): TQuery<M>;
var O: POrderTerm;
begin
  O := AddOrder; O^.Table := Col.Table; O^.Column := Col.Name; O^.Dir := Dir;
  Result := Self;
end;

function TQuery<M>.OrderBy(const Col: TColStr; Dir: TSqlDir): TQuery<M>;
var O: POrderTerm;
begin
  O := AddOrder; O^.Table := Col.Table; O^.Column := Col.Name; O^.Dir := Dir;
  Result := Self;
end;

function TQuery<M>.OrderBy(const Col: TColCurrency; Dir: TSqlDir): TQuery<M>;
var O: POrderTerm;
begin
  O := AddOrder; O^.Table := Col.Table; O^.Column := Col.Name; O^.Dir := Dir;
  Result := Self;
end;

function TQuery<M>.OrderBy(const Col: TColFloat; Dir: TSqlDir): TQuery<M>;
var O: POrderTerm;
begin
  O := AddOrder; O^.Table := Col.Table; O^.Column := Col.Name; O^.Dir := Dir;
  Result := Self;
end;

function TQuery<M>.OrderBy(const Col: TColDateTime; Dir: TSqlDir): TQuery<M>;
var O: POrderTerm;
begin
  O := AddOrder; O^.Table := Col.Table; O^.Column := Col.Name; O^.Dir := Dir;
  Result := Self;
end;

function TQuery<M>.Limit(N: Integer): TQuery<M>;
begin
  FLimit := N;
  Result := Self;
end;

function TQuery<M>.Offset(N: Integer): TQuery<M>;
begin
  FOffset := N;
  Result := Self;
end;

function TQuery<M>.Preload(const Relations: array of string): TQuery<M>;
var
  I, N: Integer;
begin
  N := Length(FPreloads);
  SetLength(FPreloads, N + Length(Relations));
  for I := 0 to High(Relations) do
  begin
    if FMeta.IndexOfRelation(Relations[I]) < 0 then
      raise EQueryError.CreateFmt('%s has no relation "%s"',
        [FMeta.ModelClass.ClassName, Relations[I]]);
    FPreloads[N + I] := Relations[I];
  end;
  Result := Self;
end;

function TQuery<M>.WithTrashed: TQuery<M>;
begin
  FTrashed := tsMed;
  Result := Self;
end;

function TQuery<M>.OnlyTrashed: TQuery<M>;
begin
  FTrashed := tsBare;
  Result := Self;
end;

{ Sant når spørringen skal ha et ekstra ledd om deleted_at. }
function TQuery<M>.SoftDeleteClause(out Bare: Boolean): Boolean;
begin
  Bare := FTrashed = tsBare;
  Result := FMeta.SoftDeletes and (FTrashed <> tsMed);
end;

procedure TQuery<M>.BuildWhere(var B: TStrBuilder; var ParamNo: Integer;
  var Params: TArray<TDbParam>);
var
  I, J: Integer;
  W: PWhereTerm;
  C: TDbConnection;
  Filter, BareSlettede, Foerste: Boolean;

  { Lukker en OR-gruppe når leddet vi nettopp skrev var det siste i den. }
  procedure LukkGruppe(Idx: Integer);
  var
    IGruppe, LastInGroup: Boolean;
  begin
    IGruppe := (FWheres + Idx)^.OrPrev or
      ((Idx + 1 < FWhereCount) and (FWheres + Idx + 1)^.OrPrev);
    LastInGroup := (Idx + 1 >= FWhereCount) or
      not (FWheres + Idx + 1)^.OrPrev;
    if IGruppe and LastInGroup then
      B.AppendByte(Ord(')'));
  end;

begin
  Filter := SoftDeleteClause(BareSlettede);
  if (FWhereCount = 0) and not Filter then
    Exit;
  C := Conn;
  B.Append(' WHERE ');
  Foerste := True;

  if Filter then
  begin
    { Kvalifisert med tabellnavnet, slik at leddet også holder når
      spørringen får en join. }
    C.AppendIdentStr(B, FMeta.Table);
    B.AppendByte(Ord('.'));
    C.AppendIdentStr(B, FMeta.DeletedAtColumn);
    if BareSlettede then
      B.Append(' IS NOT NULL')
    else
      B.Append(' IS NULL');
    Foerste := False;
  end;

  for I := 0 to FWhereCount - 1 do
  begin
    W := FWheres + I;
    if W^.OrPrev then
      B.Append(' OR ')
    else
    begin
      if not Foerste then
        B.Append(' AND ');
      Foerste := False;
      { Starten på en OR-gruppe: parentesen må rundt hele gruppa, ellers
        binder AND seg til det første leddet alene. }
      if (I + 1 < FWhereCount) and (FWheres + I + 1)^.OrPrev then
        B.AppendByte(Ord('('));
    end;
    if W^.Table <> '' then
    begin
      C.AppendIdentStr(B, string(W^.Table));
      B.AppendByte(Ord('.'));
    end;
    C.AppendIdentStr(B, string(W^.Column));

    if W^.NullCheck then
    begin
      if W^.WantNull then
        B.Append(' IS NULL')
      else
        B.Append(' IS NOT NULL');
      LukkGruppe(I);
      Continue;
    end;

    if W^.InList then
    begin
      if W^.ParamCount = 0 then
      begin
        { IN () er ugyldig SQL. En tom liste matcher ingenting. }
        B.Append(' IN (NULL)');
        Continue;
      end;
      B.Append(' IN (');
      for J := 0 to W^.ParamCount - 1 do
      begin
        if J > 0 then
          B.Append(', ');
        Inc(ParamNo);
        C.AppendPlaceholder(B, ParamNo);
        SetLength(Params, ParamNo);
        Params[ParamNo - 1] := FInParams[W^.ParamFirst + J];
      end;
      B.AppendByte(Ord(')'));
      LukkGruppe(I);
      Continue;
    end;

    B.Append(OpText(W^.Op, C.Dialect));
    Inc(ParamNo);
    C.AppendPlaceholder(B, ParamNo);
    SetLength(Params, ParamNo);
    Params[ParamNo - 1] := W^.Param;
    LukkGruppe(I);
  end;
end;

procedure TQuery<M>.BuildTail(var B: TStrBuilder);
var
  I: Integer;
  O: POrderTerm;
  C: TDbConnection;
begin
  C := Conn;
  if FOrderCount > 0 then
  begin
    B.Append(' ORDER BY ');
    for I := 0 to FOrderCount - 1 do
    begin
      O := FOrders + I;
      if I > 0 then
        B.Append(', ');
      if O^.Table <> '' then
      begin
        C.AppendIdentStr(B, string(O^.Table));
        B.AppendByte(Ord('.'));
      end;
      C.AppendIdentStr(B, string(O^.Column));
      if O^.Dir = Desc then
        B.Append(' DESC');
    end;
  end;
  if FLimit >= 0 then
  begin
    B.Append(' LIMIT ');
    B.AppendInt(FLimit);
  end;
  if FOffset > 0 then
  begin
    B.Append(' OFFSET ');
    B.AppendInt(FOffset);
  end;
end;

function TQuery<M>.ToSql: string;
var
  B: TStrBuilder;
  Params: TArray<TDbParam>;
  ParamNo, I: Integer;
  C: TDbConnection;
  Mark: TArenaMark;
begin
  C := Conn;
  Mark := Arena.Mark;
  try
    B.Init(Arena, 256);
    B.Append('SELECT ');
    for I := 0 to FMeta.ColumnCount - 1 do
    begin
      if I > 0 then
        B.Append(', ');
      C.AppendIdentStr(B, FMeta.Table);
      B.AppendByte(Ord('.'));
      C.AppendIdentStr(B, FMeta.Columns[I].ColumnName);
    end;
    B.Append(' FROM ');
    C.AppendIdentStr(B, FMeta.Table);
    ParamNo := 0;
    BuildWhere(B, ParamNo, Params);
    BuildTail(B);
    Result := B.ToString;
  finally
    Arena.Rewind(Mark);
  end;
end;

function TQuery<M>.Get: TModelList<M>;
var
  B: TStrBuilder;
  Params: TArray<TDbParam>;
  ParamNo, I, J: Integer;
  C: TDbConnection;
  R: TDbResult;
  Item: M;
  Sql: string;
  Mark: TArenaMark;
begin
  C := Conn;
  Mark := Arena.Mark;
  try
    B.Init(Arena, 256);
    B.Append('SELECT ');
    for I := 0 to FMeta.ColumnCount - 1 do
    begin
      if I > 0 then
        B.Append(', ');
      C.AppendIdentStr(B, FMeta.Table);
      B.AppendByte(Ord('.'));
      C.AppendIdentStr(B, FMeta.Columns[I].ColumnName);
    end;
    B.Append(' FROM ');
    C.AppendIdentStr(B, FMeta.Table);
    ParamNo := 0;
    BuildWhere(B, ParamNo, Params);
    BuildTail(B);
    Sql := B.ToString;
  finally
    { SQL-teksten er kopiert ut; byggebufferet trengs ikke. Parametrene ligger
      i egne allokeringer som er eldre enn merket og overlever. }
    Arena.Rewind(Mark);
  end;

  R := C.ExecParams(Arena, Sql, Params);
  Result := TModelList<M>.Create;
  for I := 0 to R.RowCount - 1 do
  begin
    Item := M.Create;
    Item.Hydrate(R, I);
    Result.Add(Item);
  end;

  for J := 0 to High(FPreloads) do
    LoadRelation(Result, FPreloads[J]);
end;

procedure TQuery<M>.LoadRelation(List: TModelList<M>; const RelName: string);
var
  Rel: TRelationInfo;
  RelIdx, I, J, Col: Integer;
  Keys: TArray<Int64>;
  Params: TArray<TDbParam>;
  B: TStrBuilder;
  C: TDbConnection;
  R: TDbResult;
  ChildMeta: TModelMeta;
  Sql: string;
  Mark: TArenaMark;
  Slot: PPointer;
  Child: TModel;
  Owner: TModel;
  ParentKey: Int64;
  FkIdx: Integer;
begin
  if List.Count = 0 then
    Exit;
  RelIdx := FMeta.IndexOfRelation(RelName);
  if RelIdx < 0 then
    Exit;
  Rel := FMeta.Relations[RelIdx];
  ChildMeta := Rel.Target.Meta;
  C := Conn;

  { Nøklene å slå opp på. For HasMany og HasOne er det foreldrenes
    primærnøkkel; for BelongsTo er det fremmednøkkelen i foreldreraden. }
  SetLength(Keys, List.Count);
  if Rel.Kind = rkBelongsTo then
  begin
    FkIdx := FMeta.IndexOfColumn(Rel.ForeignKey);
    if FkIdx < 0 then
      raise EQueryError.CreateFmt('%s is missing column "%s" for relation "%s"',
        [FMeta.ModelClass.ClassName, Rel.ForeignKey, RelName]);
    for I := 0 to List.Count - 1 do
      Keys[I] := GetInt64Prop(List[I], FMeta.Columns[FkIdx].Prop);
  end
  else
    for I := 0 to List.Count - 1 do
      Keys[I] := List[I].PrimaryKeyValue;

  { Parametrene må allokeres FØR merket. Ligger de etter, spoler Rewind
    bumppekeren tilbake forbi dem, og de neste allokeringene — ExecParams sine
    egne nullterminerte kopier — skriver over verdiene mens de leses. }
  SetLength(Params, Length(Keys));
  for I := 0 to High(Keys) do
    Params[I] := DbParam(Arena, Keys[I]);

  Mark := Arena.Mark;
  try
    B.Init(Arena, 256);
    B.Append('SELECT ');
    for I := 0 to ChildMeta.ColumnCount - 1 do
    begin
      if I > 0 then
        B.Append(', ');
      C.AppendIdentStr(B, ChildMeta.Columns[I].ColumnName);
    end;
    B.Append(' FROM ');
    C.AppendIdentStr(B, ChildMeta.Table);
    B.Append(' WHERE ');
    if Rel.Kind = rkBelongsTo then
      C.AppendIdentStr(B, Rel.LocalKey)
    else
      C.AppendIdentStr(B, Rel.ForeignKey);
    B.Append(' IN (');
    for I := 0 to High(Keys) do
    begin
      if I > 0 then
        B.Append(', ');
      C.AppendPlaceholder(B, I + 1);
    end;
    B.AppendByte(Ord(')'));
    Sql := B.ToString;
  finally
    Arena.Rewind(Mark);
  end;

  { Én spørring for hele settet. Det er dette som gjør at en løkke over
    relasjonen ikke blir N+1. }
  R := C.ExecParams(Arena, Sql, Params);

  { Barna legges i et published felt på foreldremodellen, funnet med
    FieldAddress. Feltet må hete det samme som relasjonen. }
  for I := 0 to List.Count - 1 do
  begin
    Slot := PPointer(List[I].FieldAddress(RelName));
    if Slot = nil then
      raise EQueryError.CreateFmt(
        '%s is missing a published field "%s" to hold the relation',
        [FMeta.ModelClass.ClassName, RelName]);
    if Rel.Kind = rkHasMany then
      Slot^ := Pointer(TModelListBase.Create)
    else
      Slot^ := nil;
  end;

  if Rel.Kind = rkBelongsTo then
    Col := R.IndexOfField(Rel.LocalKey)
  else
    Col := R.IndexOfField(Rel.ForeignKey);

  for J := 0 to R.RowCount - 1 do
  begin
    Child := TModel(Rel.Target.NewInstance);
    Child.Create;
    Child.Hydrate(R, J);
    if Col < 0 then
      Continue;
    ParentKey := R.Value(J, Col).ToIntDef(0);
    for I := 0 to List.Count - 1 do
    begin
      Owner := List[I];
      if Keys[I] <> ParentKey then
        Continue;
      Slot := PPointer(Owner.FieldAddress(RelName));
      if Rel.Kind = rkHasMany then
        TModelListBase(Slot^).AddModel(Child)
      else
        Slot^ := Pointer(Child);
      if Rel.Kind <> rkHasMany then
        Break;
    end;
  end;
end;

function TQuery<M>.First: M;
var
  L: TModelList<M>;
begin
  FLimit := 1;
  L := Get;
  Result := L.First;
end;

function TQuery<M>.Find(Id: Int64): M;
var
  Col: TColInt64;
begin
  Col := ColInt64(FMeta.Table, FMeta.PrimaryKey);
  Result := Where(Col, Eq, Id).First;
end;

function TQuery<M>.Count: Int64;
var
  B: TStrBuilder;
  Params: TArray<TDbParam>;
  ParamNo: Integer;
  C: TDbConnection;
  R: TDbResult;
  Sql: string;
  Mark: TArenaMark;
begin
  C := Conn;
  Mark := Arena.Mark;
  try
    B.Init(Arena, 128);
    B.Append('SELECT count(*) FROM ');
    C.AppendIdentStr(B, FMeta.Table);
    ParamNo := 0;
    BuildWhere(B, ParamNo, Params);
    Sql := B.ToString;
  finally
    Arena.Rewind(Mark);
  end;
  R := C.ExecParams(Arena, Sql, Params);
  if R.IsEmpty then
    Exit(0);
  Result := R.AsInt64(0, 0);
end;

function TQuery<M>.Paginate(Page, PerPage: Integer): TModelList<M>;
begin
  if Page < 1 then
    Page := 1;
  if PerPage < 1 then
    PerPage := 25;
  FLimit := PerPage;
  FOffset := (Page - 1) * PerPage;
  Result := Get;
end;

function TQuery<M>.DeleteAll: Int64;
var
  B: TStrBuilder;
  Params: TArray<TDbParam>;
  ParamNo: Integer;
  C: TDbConnection;
  R: TDbResult;
  Sql: string;
  Mark: TArenaMark;
begin
  { With_ SoftDeletes gjør DeleteAll det samme som Model.Delete. Alternativet
    — at én sletter mykt og den andre hardt — er den slags forskjell ingen
    husker før en tabell er tom. }
  if FMeta.SoftDeletes then
    Exit(SoftDeleteAll);

  C := Conn;
  Mark := Arena.Mark;
  try
    B.Init(Arena, 128);
    B.Append('DELETE FROM ');
    C.AppendIdentStr(B, FMeta.Table);
    ParamNo := 0;
    BuildWhere(B, ParamNo, Params);
    Sql := B.ToString;
  finally
    Arena.Rewind(Mark);
  end;
  R := C.ExecParams(Arena, Sql, Params);
  Result := R.AffectedRows;
end;

function TQuery<M>.SoftDeleteAll: Int64;
var
  B: TStrBuilder;
  Params: TArray<TDbParam>;
  ParamNo: Integer;
  C: TDbConnection;
  R: TDbResult;
  Sql: string;
  Mark: TArenaMark;
begin
  C := Conn;
  Mark := Arena.Mark;
  try
    { Tidsstempelet er parameter nummer én, og de øvrige leddene teller
      videre derfra. Bommer man på det, peker hvert filter én plass feil. }
    SetLength(Params, 1);
    Params[0] := DbParamDateTime(Arena, UtcNow);
    ParamNo := 1;

    B.Init(Arena, 160);
    B.Append('UPDATE ');
    C.AppendIdentStr(B, FMeta.Table);
    B.Append(' SET ');
    C.AppendIdentStr(B, FMeta.DeletedAtColumn);
    B.Append(' = ');
    C.AppendPlaceholder(B, 1);
    BuildWhere(B, ParamNo, Params);
    Sql := B.ToString;
  finally
    Arena.Rewind(Mark);
  end;
  R := C.ExecParams(Arena, Sql, Params);
  Result := R.AffectedRows;
end;

function TQuery<M>.ForceDeleteAll: Int64;
var
  B: TStrBuilder;
  Params: TArray<TDbParam>;
  ParamNo: Integer;
  C: TDbConnection;
  R: TDbResult;
  Sql: string;
  Mark: TArenaMark;
begin
  C := Conn;
  Mark := Arena.Mark;
  try
    B.Init(Arena, 128);
    B.Append('DELETE FROM ');
    C.AppendIdentStr(B, FMeta.Table);
    ParamNo := 0;
    BuildWhere(B, ParamNo, Params);
    Sql := B.ToString;
  finally
    Arena.Rewind(Mark);
  end;
  R := C.ExecParams(Arena, Sql, Params);
  Result := R.AffectedRows;
end;

function TQuery<M>.RestoreAll: Int64;
var
  B: TStrBuilder;
  Params: TArray<TDbParam>;
  ParamNo: Integer;
  C: TDbConnection;
  R: TDbResult;
  Sql: string;
  Mark: TArenaMark;
begin
  if not FMeta.SoftDeletes then
    raise EDbError.CreateFmt('%s has no soft deletes; nothing to restore.',
      [FMeta.ModelClass.ClassName]);
  { Bare de slettede er kandidater, med mindre kalleren har sagt noe
    annet. }
  if FTrashed = tsUten then
    FTrashed := tsBare;
  C := Conn;
  Mark := Arena.Mark;
  try
    SetLength(Params, 0);
    ParamNo := 0;
    B.Init(Arena, 160);
    B.Append('UPDATE ');
    C.AppendIdentStr(B, FMeta.Table);
    B.Append(' SET ');
    C.AppendIdentStr(B, FMeta.DeletedAtColumn);
    B.Append(' = NULL');
    BuildWhere(B, ParamNo, Params);
    Sql := B.ToString;
  finally
    Arena.Rewind(Mark);
  end;
  R := C.ExecParams(Arena, Sql, Params);
  Result := R.AffectedRows;
end;

class function TQuery<M>.New: TQuery<M>;
begin
  Result := TQuery<M>.Create(M, nil);
end;

class function TQuery<M>.Using(AConn: TDbConnection): TQuery<M>;
begin
  Result := TQuery<M>.Create(M, AConn);
end;

end.
