{ Askr.Urd.Grid — serversiden av datagriden.

  Dette er halvparten Lauf ikke kan ha, og som ingen ren frontend kan gjøre:
  sortering, søk og paginering skjer i databasen, ikke i nettleseren. En
  grid som henter hundre tusen rader for å sortere dem i JavaScript er feil
  svar for Askr — databasen står der allerede, den har indeksene, og den er
  raskere enn nettverket.

      function TCustomerController.Index(Req: TRequest): TResponse;
      var
        G: TGrid<TCustomer>;
      begin
        G := TGrid<TCustomer>.New;
        G.Read(Req)
         .Sortable('name', Customers.Name)
         .Sortable('balance', Customers.Balance)
         .Searchable([Customers.Name, Customers.Email])
         .DefaultSort('name');

        Result := Inertia('Customers/Index',
          ['rows', G.Rows(TQuery<TCustomer>.New),
           'grid', G]);
      end;

  **Sorteringskolonnen kommer fra en URL, og den når aldri SQL-en.**
  `TQuery.OrderBy` tar en typet `TCol`, ikke en streng, så en kolonne som
  ikke er registrert med `Sortable` finnes rett og slett ikke å sortere på.
  Det er ikke en sjekk vi har husket å skrive; det er en konsekvens av at
  datalaget er typet. En grid som setter sammen «ORDER BY » + parameteren er
  den klassiske injeksjonen, og den formen lar seg ikke skrive her.

  Totalen telles med `Count`, som bygger sin egen `SELECT count(*)` og ser
  bort fra limit og offset. Den må kjøres før sidene, ellers teller man
  siden i stedet for treffene.

  Det som *ikke* ligger her, med vilje: kolonnefiltre per felt. De krever en
  operator per type og en måte å uttrykke «og/eller» på, og det er et eget
  spørsmål om hvor mye av et spørrespråk en URL skal bære. Fritekstsøk over
  navngitte kolonner dekker det de fleste lister trenger. }
unit Askr.Urd.Grid;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Math,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Json,
  Askr.Http.Request,
  Askr.Urd.Driver, Askr.Urd.Model, Askr.Urd.Query;

type
  EGridError = class(Exception);

  { Typen bare velger riktig OrderBy-overlast. TCol<T> er den samme recorden
    uansett T, så navnet og tabellen lagres, og kinden sier hvilken vei
    kallet skal gå når sorteringen settes på. }
  TGridColKind = (gkInt, gkStr, gkCurrency, gkFloat, gkBool, gkDateTime);

  TGridCol = record
    Key: string;
    Name: ShortString;
    Table: ShortString;
    Kind: TGridColKind;
  end;

  TGrid<M: TModel> = class(TJsonWritable)
  private
    FCols: array of TGridCol;
    FSearch: array of TGridCol;
    FSort: string;
    FDir: TSqlDir;
    FDefaultSort: string;
    FDefaultDir: TSqlDir;
    FPage: Integer;
    FPerPage: Integer;
    FMaxPerPage: Integer;
    { Det klienten ba om, holdt for seg. Slås sammen med standarden og
      taket først i EffectivePer, slik at rekkefølgen på Read og PerPage
      ikke betyr noe. Et API der kallrekkefølgen stille endrer oppførselen
      er en felle, og den traff med én gang. }
    FClientPer: Integer;
    FQuery: string;
    FTotal: Int64;
    FRan: Boolean;
    function Find(const Key: string; out C: TGridCol): Boolean;
    procedure Add(const Key: string; const AName, ATable: ShortString;
      Kind: TGridColKind);
    function EffectiveSort: string;
    function EffectiveDir: TSqlDir;
    function EffectivePer: Integer;
  public
    constructor Create;

    { Inngangen, av samme grunn som TQuery.New: en nøstet spesialisering
      som typeargument — Arena.New<TGrid<TCustomer>> — leses som en
      skiftoperator og lar seg ikke skrive. }
    class function New: TGrid<M>;

    { Leser sort, dir, page, per og q fra spørrestrengen. }
    function Read(Req: TRequest): TGrid<M>;

    { Hvitelisten. En kolonne som ikke står her kan ikke sorteres på. }
    function Sortable(const Key: string; const Col: TColInt64): TGrid<M>; overload;
    function Sortable(const Key: string; const Col: TColStr): TGrid<M>; overload;
    function Sortable(const Key: string; const Col: TColCurrency): TGrid<M>; overload;
    function Sortable(const Key: string; const Col: TColFloat): TGrid<M>; overload;
    function Sortable(const Key: string; const Col: TColBool): TGrid<M>; overload;
    function Sortable(const Key: string; const Col: TColDateTime): TGrid<M>; overload;

    { Fritekstsøk. ILike mot hver kolonne, med OR mellom dem. }
    function Searchable(const Cols: array of TColStr): TGrid<M>;

    function DefaultSort(const Key: string; Dir: TSqlDir = Asc): TGrid<M>;
    { Standard sidestørrelse, og taket klienten kan be om. Without et tak kan
      hvem som helst be om per=1000000 og be databasen om alt. }
    function PerPage(N: Integer; Max: Integer = 200): TGrid<M>;

    { Teller totalen, legger på søk og sortering, og henter siden.
      Spørringen kommer fra kalleren, slik at den kan ha sine egne Where —
      en grid over «mine ordre» er fortsatt en grid. }
    function Rows(Q: TQuery<M>): TModelList<M>;

    { Legges i payloaden som en egen prop. Frontend leser den for å vite
      hvilken kolonne som er sortert, hvilken side den står på og hvor
      mange treff det er. }
    procedure WriteJson(var W: TJsonWriter); override;

    property Total: Int64 read FTotal;
    property Page: Integer read FPage;
    property Size: Integer read EffectivePer;
    property Search: string read FQuery;
  end;

implementation

{ Kolonnenavnene fra Norn er ShortString. Sammenligningen mot nøkkelen fra
  URL-en er på vår egen Key, ikke på kolonnenavnet — en app skal kunne kalle
  kolonnen noe annet utad enn den heter i databasen. }

class function TGrid<M>.New: TGrid<M>;
begin
  Result := TGrid<M>.Create;
end;

constructor TGrid<M>.Create;
begin
  inherited Create;
  FPage := 1;
  FPerPage := 25;
  FMaxPerPage := 200;
  FDir := Asc;
  FDefaultDir := Asc;
end;

procedure TGrid<M>.Add(const Key: string; const AName, ATable: ShortString;
  Kind: TGridColKind);
var
  N: Integer;
begin
  N := Length(FCols);
  SetLength(FCols, N + 1);
  FCols[N].Key := Key;
  FCols[N].Name := AName;
  FCols[N].Table := ATable;
  FCols[N].Kind := Kind;
end;

function TGrid<M>.Find(const Key: string; out C: TGridCol): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FCols) do
    if FCols[I].Key = Key then
    begin
      C := FCols[I];
      Exit(True);
    end;
  Result := False;
end;

function TGrid<M>.Sortable(const Key: string; const Col: TColInt64): TGrid<M>;
begin
  Add(Key, Col.Name, Col.Table, gkInt);
  Result := Self;
end;

function TGrid<M>.Sortable(const Key: string; const Col: TColStr): TGrid<M>;
begin
  Add(Key, Col.Name, Col.Table, gkStr);
  Result := Self;
end;

function TGrid<M>.Sortable(const Key: string; const Col: TColCurrency): TGrid<M>;
begin
  Add(Key, Col.Name, Col.Table, gkCurrency);
  Result := Self;
end;

function TGrid<M>.Sortable(const Key: string; const Col: TColFloat): TGrid<M>;
begin
  Add(Key, Col.Name, Col.Table, gkFloat);
  Result := Self;
end;

function TGrid<M>.Sortable(const Key: string; const Col: TColBool): TGrid<M>;
begin
  Add(Key, Col.Name, Col.Table, gkBool);
  Result := Self;
end;

function TGrid<M>.Sortable(const Key: string; const Col: TColDateTime): TGrid<M>;
begin
  Add(Key, Col.Name, Col.Table, gkDateTime);
  Result := Self;
end;

function TGrid<M>.Searchable(const Cols: array of TColStr): TGrid<M>;
var
  I, N: Integer;
begin
  N := Length(FSearch);
  SetLength(FSearch, N + Length(Cols));
  for I := 0 to High(Cols) do
  begin
    FSearch[N + I].Key := '';
    FSearch[N + I].Name := Cols[I].Name;
    FSearch[N + I].Table := Cols[I].Table;
    FSearch[N + I].Kind := gkStr;
  end;
  Result := Self;
end;

function TGrid<M>.DefaultSort(const Key: string; Dir: TSqlDir): TGrid<M>;
begin
  FDefaultSort := Key;
  FDefaultDir := Dir;
  Result := Self;
end;

function TGrid<M>.PerPage(N: Integer; Max: Integer): TGrid<M>;
begin
  if N > 0 then
    FPerPage := N;
  if Max > 0 then
    FMaxPerPage := Max;
  Result := Self;
end;

function TGrid<M>.EffectivePer: Integer;
begin
  if FClientPer > 0 then
    Result := FClientPer
  else
    Result := FPerPage;
  Result := Min(Max(1, Result), FMaxPerPage);
end;

function TGrid<M>.Read(Req: TRequest): TGrid<M>;
var
  S: TStr;
  N: Integer;
begin
  Result := Self;
  if Req = nil then
    Exit;

  S := Req.Query('sort');
  if S.Len > 0 then
    FSort := S.ToString;

  S := Req.Query('dir');
  if S.EqualsStr('desc') then
    FDir := Desc
  else
    FDir := Asc;

  S := Req.Query('page');
  if S.Len > 0 then
  begin
    N := StrToIntDef(S.ToString, 1);
    if N > 0 then
      FPage := N;
  end;

  S := Req.Query('per');
  if S.Len > 0 then
  begin
    N := StrToIntDef(S.ToString, 0);
    { Taket gjelder også det klienten ber om. Without det er per=1000000 en
      måte å be databasen om hele tabellen på. }
    if N > 0 then
      FClientPer := N;
  end;

  FQuery := Trim(Req.Query('q').ToString);
end;

function TGrid<M>.EffectiveSort: string;
var
  C: TGridCol;
begin
  { En ukjent kolonne faller tilbake til standarden i stillhet. Alternativet
    — en feilmelding — gjør at en gammel bokmerket URL velter siden, og
    sorteringen er ikke noe å feile på. }
  if (FSort <> '') and Find(FSort, C) then
    Exit(FSort);
  Result := FDefaultSort;
end;

function TGrid<M>.EffectiveDir: TSqlDir;
var
  C: TGridCol;
begin
  if (FSort <> '') and Find(FSort, C) then
    Exit(FDir);
  Result := FDefaultDir;
end;

function TGrid<M>.Rows(Q: TQuery<M>): TModelList<M>;
var
  C: TGridCol;
  I: Integer;
  Key: string;
  Dir: TSqlDir;
  ColI: TColInt64;
  ColS: TColStr;
  ColC: TColCurrency;
  ColF: TColFloat;
  ColB: TColBool;
  ColD: TColDateTime;
  SokeKol: array of TColStr;
begin
  if Q = nil then
    raise EGridError.Create('Grid.Rows needs a query');

  { Søket først, slik at det er med i tellingen. WhereAnyLike setter OR
    mellom kolonnene og parentes rundt gruppa, slik at et Where kalleren
    allerede hadde lagt på fortsatt gjelder. }
  if (FQuery <> '') and (Length(FSearch) > 0) then
  begin
    SetLength(SokeKol, Length(FSearch));
    for I := 0 to High(FSearch) do
    begin
      SokeKol[I].Name := FSearch[I].Name;
      SokeKol[I].Table := FSearch[I].Table;
    end;
    Q.WhereAnyLike(SokeKol, FQuery);
  end;

  { Count ser bort fra limit og offset og må kjøres før siden hentes —
    ellers teller man raden på siden i stedet for treffene. }
  FTotal := Q.Count;
  FRan := True;

  Key := EffectiveSort;
  Dir := EffectiveDir;
  if (Key <> '') and Find(Key, C) then
  begin
    case C.Kind of
      gkInt:
        begin
          ColI.Name := C.Name; ColI.Table := C.Table;
          Q.OrderBy(ColI, Dir);
        end;
      gkStr:
        begin
          ColS.Name := C.Name; ColS.Table := C.Table;
          Q.OrderBy(ColS, Dir);
        end;
      gkCurrency:
        begin
          ColC.Name := C.Name; ColC.Table := C.Table;
          Q.OrderBy(ColC, Dir);
        end;
      gkFloat:
        begin
          ColF.Name := C.Name; ColF.Table := C.Table;
          Q.OrderBy(ColF, Dir);
        end;
      gkDateTime:
        begin
          ColD.Name := C.Name; ColD.Table := C.Table;
          Q.OrderBy(ColD, Dir);
        end;
      gkBool:
        begin
          ColB.Name := C.Name; ColB.Table := C.Table;
          { TQuery har ingen OrderBy for bool — et boolsk felt er sjelden en
            meningsfull sortering, og heller enn å finne på en oversettelse
            lar vi den stå usortert. }
        end;
    end;
  end;

  { En side utenfor området gir tom liste, ikke en feil. Det skjer når noen
    sletter rader mens du står på siste side. }
  Result := Q.Paginate(FPage, EffectivePer);
end;

procedure TGrid<M>.WriteJson(var W: TJsonWriter);
var
  Pages: Int64;
begin
  Pages := Max(1, (FTotal + EffectivePer - 1) div EffectivePer);

  W.BeginObject;
  W.Field('sort', EffectiveSort);
  if EffectiveDir = Desc then
    W.Field('dir', 'desc')
  else
    W.Field('dir', 'asc');
  W.Field('page', Int64(FPage));
  W.Field('per', Int64(EffectivePer));
  W.Field('q', FQuery);
  { Has_ ikke Rows kjørt, er totalen ikke målt — og da skal den ikke stå der
    som om den var det. }
  if FRan then
  begin
    W.Field('total', FTotal);
    W.Field('pages', Pages);
  end
  else
  begin
    W.FieldNull('total');
    W.FieldNull('pages');
  end;
  W.EndObject;
end;

end.
