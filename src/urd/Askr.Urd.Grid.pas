{ Askr.Urd.Grid — the server side of the data grid.

  This is the half Lauf cannot have, and that no pure frontend can do:
  sorting, searching and pagination happen in the database, not in the
  browser. A grid that fetches a hundred thousand rows to sort them in
  JavaScript is the wrong answer for Askr — the database is already there,
  it has the indexes, and it is faster than the network.

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

  **The sort column comes from a URL, and it never reaches the SQL.**
  `TQuery.OrderBy` takes a typed `TCol`, not a string, so a column not
  registered with `Sortable` simply does not exist to sort by. That is not
  a check we remembered to write; it is a consequence of the data layer
  being typed. A grid that concatenates "ORDER BY " + the parameter is the
  classic injection, and that shape cannot be written here.

  The total is counted with `Count`, which builds its own `SELECT
  count(*)` and ignores limit and offset. It has to run before the page,
  or you count the page instead of the matches.

  What is deliberately *not* here: per-field column filters. They need an
  operator per type and a way to express "and/or", and that is a separate
  question about how much of a query language a URL should carry.
  Free-text search over named columns covers what most lists need. }
unit Askr.Urd.Grid;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Math,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Json,
  Askr.Http.Request, Askr.Http.Response,
  Askr.Urd.Driver, Askr.Urd.Model, Askr.Urd.Query, Askr.Urd.Json;

type
  EGridError = class(Exception);

  { The type only picks the right OrderBy overload. TCol<T> is the same
    record whatever T is, so the name and the table are stored and the
    kind says which way the call should go when the sort is applied. }
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
    { What the client asked for, kept separate. Merged with the default and
      the cap only in EffectivePer, so the order of Read and PerPage does
      not matter. An API where the call order silently changes behaviour
      is a trap, and it caught us immediately. }
    FClientPer: Integer;
    FQuery: string;
    { The path and the raw query string of the request this was read
      from, kept so a next link can be built without losing the
      application's own parameters. Empty when no request was read. }
    FPath: string;
    FQueryString: string;
    FTotal: Int64;
    FRan: Boolean;
    function LinkTo(PageNo: Int64): string;
    function Find(const Key: string; out C: TGridCol): Boolean;
    procedure Add(const Key: string; const AName, ATable: ShortString;
      Kind: TGridColKind);
    function EffectiveSort: string;
    function EffectiveDir: TSqlDir;
    function EffectivePer: Integer;
  public
    constructor Create;

    { The entry point, for the same reason as TQuery.New: a nested
      specialisation as a type argument — Arena.New<TGrid<TCustomer>> —
      reads as a shift operator and cannot be written. }
    class function New: TGrid<M>;

    { Reads sort, dir, page, per and q from the query string. }
    function Read(Req: TRequest): TGrid<M>;

    { The whitelist. A column not listed here cannot be sorted by. }
    function Sortable(const Key: string; const Col: TColInt64): TGrid<M>; overload;
    function Sortable(const Key: string; const Col: TColStr): TGrid<M>; overload;
    function Sortable(const Key: string; const Col: TColCurrency): TGrid<M>; overload;
    function Sortable(const Key: string; const Col: TColFloat): TGrid<M>; overload;
    function Sortable(const Key: string; const Col: TColBool): TGrid<M>; overload;
    function Sortable(const Key: string; const Col: TColDateTime): TGrid<M>; overload;

    { Free-text search. ILike against each column, with OR between them. }
    function Searchable(const Cols: array of TColStr): TGrid<M>;

    function DefaultSort(const Key: string; Dir: TSqlDir = Asc): TGrid<M>;
    { The default page size, and the cap a client may ask for. Without a cap
      anyone can ask for per=1000000 and ask the database for
      everything. }
    function PerPage(N: Integer; Max: Integer = 200): TGrid<M>;

    { Counts the total, applies search and sorting, and fetches the page.
      The query comes from the caller, so it can carry its own Where — a
      grid over "my orders" is still a grid. }
    function Rows(Q: TQuery<M>): TModelList<M>;

    { Goes into the payload as a prop of its own. The frontend reads it to
      know which column is sorted, which page it is on and how many
      matches there are. }
    procedure WriteJson(var W: TJsonWriter); override;

    (* The same list for a caller that is not the data grid component:

         "data": [...]
         "meta": "page":1, "per":25, "total":137, "pages":6,
                 "sort":"name", "dir":"asc", "q":""
         "links": "prev":null, "next":"/customers?sort=name&page=2"

       -- an object with those three keys, written without the braces
       because a brace in a Pascal comment opens a nested one.

       `data` is an array whatever happens: never null, never missing.
       `total` comes from Rows, which counts before it fetches, and
       building this without calling Rows first raises rather than
       reporting a total nobody measured.

       The links are relative and carry the whole query string forward
       with only `page` replaced, so a filter the application added is
       still there on page two. *)
    procedure WriteListInto(var W: TJsonWriter; Rows_: TModelList<M>);
    { The same thing as a complete response. }
    function ListResponse(Rows_: TModelList<M>): TResponse;

    property Total: Int64 read FTotal;
    property Page: Integer read FPage;
    property Size: Integer read EffectivePer;
    property Search: string read FQuery;
  end;

implementation

{ The column names from Norn are ShortStrings. The comparison against the
  key from the URL is on our own Key, not on the column name — an app must
  be able to call a column something else on the outside than it is called
  in the database. }

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
    { The cap applies to what the client asks for as well. Without it
      per=1000000 is a way to ask the database for the whole table. }
    if N > 0 then
      FClientPer := N;
  end;

  FQuery := Trim(Req.Query('q').ToString);
  FPath := Req.Path.ToString;
  FQueryString := Req.QueryString.ToString;
end;

function TGrid<M>.EffectiveSort: string;
var
  C: TGridCol;
begin
  { An unknown column falls back to the default silently. The alternative
    — an error — means an old bookmarked URL brings the page down, and
    sorting is not something to fail on. }
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

  { The search first, so it is included in the count. WhereAnyLike puts OR
    between the columns and a parenthesis around the group, so a Where the
    caller had already added still applies. }
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

  { Count ignores limit and offset and has to run before the page is
    fetched — otherwise you count the row on the page instead of the
    matches. }
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
          { TQuery has no OrderBy for bool — a boolean field is rarely a
            meaningful sort, and rather than invent a translation we leave
            it unsorted. }
        end;
    end;
  end;

  { A page outside the range gives an empty list, not an error. That
    happens when somebody deletes rows while you are on the last page. }
  Result := Q.Paginate(FPage, EffectivePer);
end;

{ ------------------------------------------------------ list payload -- }

{ Everything after the path, with page= replaced.

  The whole query string is carried over rather than rebuilt from what
  the grid knows about, because a list usually carries more than sort and
  search -- `?status=open&assignee=me` is the application's, and a next
  link that quietly dropped it would page through a different list than
  the one the caller asked for. }
function TGrid<M>.LinkTo(PageNo: Int64): string;
var
  Rest, One, Kept: string;
  P: Integer;
begin
  Kept := '';
  Rest := FQueryString;
  while Rest <> '' do
  begin
    P := Pos('&', Rest);
    if P = 0 then
    begin
      One := Rest;
      Rest := '';
    end
    else
    begin
      One := Copy(Rest, 1, P - 1);
      Rest := Copy(Rest, P + 1, MaxInt);
    end;
    if One = '' then
      Continue;
    if (Copy(One, 1, 5) = 'page=') or (One = 'page') then
      Continue;
    if Kept <> '' then
      Kept := Kept + '&';
    Kept := Kept + One;
  end;

  if Kept <> '' then
    Kept := Kept + '&';
  Result := FPath + '?' + Kept + 'page=' + IntToStr(PageNo);
end;

procedure TGrid<M>.WriteListInto(var W: TJsonWriter; Rows_: TModelList<M>);
var
  Pages: Int64;
begin
  { A total that was never measured must not be written as if it had
    been. Rows is what measures it, and a payload built without it would
    say total 0 for a list that has rows in it. }
  if not FRan then
    raise EGridError.Create(
      'The list has no total: call Grid.Rows before building the ' +
      'payload. It is Rows that counts the matches, and a total nobody ' +
      'measured is worse than none.');

  Pages := Max(1, (FTotal + EffectivePer - 1) div EffectivePer);

  W.BeginObject;
  { Always an array, and always called the same thing. A client of a list
    endpoint iterates this key; there is no shape of reply where handing
    it null is the more useful answer. }
  W.Key('data');
  WriteModelList(W, Rows_);

  W.Key('meta');
  W.BeginObject;
  W.Field('page', Int64(FPage));
  W.Field('per', Int64(EffectivePer));
  W.Field('total', FTotal);
  W.Field('pages', Pages);
  W.Field('sort', EffectiveSort);
  if EffectiveDir = Desc then
    W.Field('dir', 'desc')
  else
    W.Field('dir', 'asc');
  W.Field('q', FQuery);
  W.EndObject;

  { Relative, on purpose. An absolute one would need an origin, and the
    only truthful source of that is app.url -- which a list endpoint has
    no business requiring. The caller just made this request, so it has
    the origin already. }
  W.Key('links');
  W.BeginObject;
  if FPath = '' then
  begin
    { No path means the grid was never given a request. Saying null is
      the honest answer; guessing a path is not. }
    W.FieldNull('prev');
    W.FieldNull('next');
  end
  else
  begin
    if FPage > 1 then
      W.Field('prev', LinkTo(FPage - 1))
    else
      W.FieldNull('prev');
    if FPage < Pages then
      W.Field('next', LinkTo(FPage + 1))
    else
      W.FieldNull('next');
  end;
  W.EndObject;
  W.EndObject;
end;

function TGrid<M>.ListResponse(Rows_: TModelList<M>): TResponse;
var
  W: TJsonWriter;
begin
  W.Init(CurrentArena, 4096);
  WriteListInto(W, Rows_);
  Result := Respond(200)
    .WithContentType('application/json; charset=utf-8')
    .WithBody(W.ToStr);
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
  { If Rows has not run, the total has not been measured — and then it
    must not sit there as if it had. }
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
