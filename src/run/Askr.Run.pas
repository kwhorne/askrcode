{ Askr.Run — Rún, oversatt til Pascal.

  Rún finnes fordi Free Pascal ikke kan uttrykke to ting Askr trenger:
  en generisk metode (`Where<T>`), og `with` som navn på eager loading —
  `with` er et reservert ord. Begge er ekte grenser, verifisert på både
  3.2.2 og trunk, og de forsvinner ikke ved å vente.

  Svaret er ikke en ny kompilator. Det er en transpiler som skriver ut de
  konkrete variantene Pascal kan ta imot:

    query<M> ById(id: int) -> M for Customer, Order

  blir `CustomerById` og `OrderById`, hver med sin egen radtype.

  Skjemaet leses fra databasen **mens kilden oversettes**. Kolonner, typer
  og relasjoner står ingen steder i Rún-kilden — `with orders` virker fordi
  `orders.customer_id` peker på `customers.id`, og det vet databasen
  allerede.

  Kostnaden er målt: 3–4 ms mot SQLite med opptil 62 tabeller. Mot Postgres
  er den 70 ms ved 61 tabeller, som er mer enn utviklerløkka har å gå på —
  se LARAVEL.md og Rún-dokumentet. En produksjonsvariant må cache skjemaet.

  Uniten holder tilstand i globale variabler. Det er med vilje: en
  oversettelse er én kjøring fra start til slutt, og en kontekst-record
  hadde bare flyttet den samme tilstanden et annet sted. Den er ikke
  trådsikker, og skal ikke brukes fra flere tråder. }
unit Askr.Run;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Clock,
  Askr.Urd.Driver, Askr.Urd.Sqlite, Askr.Urd.Pg, Askr.Urd.MySql,
  Askr.Norn.Introspect;

type
  ERunError = class(Exception);

  { Det oversettelsen kostet og hva den fant. To_ logging og til å måle
    at Rún fortsatt får plass i utviklerløkka. }
  TRunStats = record
    Models: Integer;
    Queries: Integer;
    Dialect: string;
    ParseMs: Int64;
    SchemaMs: Int64;
    EmitMs: Int64;
    TotalMs: Int64;
  end;

{ Oversetter én .run-fil til én Pascal-unit. Kaster ERunError med fil, linje
  og hva som var galt. }
function Transpile(const InFile, OutFile, UnitName: string): TRunStats;

{ Unit-navnet en .run-fil skal gi, etter filnavnet: app/Queries.run blir
  App.Queries. }
function UnitNameFor(const RunFile, Namespace: string): string;

implementation

type
  { Typene språket kjenner. De kommer fra skjemaet, ikke fra kilden. }
  TRunKind = (rkInt, rkText, rkBool, rkMoney, rkFloat, rkTime);

  TToken = record
    Text_: string;
    Line: Integer;
    Kind: (tkEnd, tkIdent, tkString, tkNumber, tkOp);
  end;

  TParamDecl = record
    Name: string;
    Kind: TRunKind;
  end;

  TCmp = record
    Col: string;
    Op: string;           { ==, !=, <, <=, >, >=, like, is, is not }
    HasOperand: Boolean;  { «is null» har ingen høyreside }
    IsParam: Boolean;
    Operand: string;      { parameternavn, eller literalen slik den sto }
    LitKind: TRunKind;
    Line: Integer;
  end;

  TOrderTerm = record
    Col: string;
    Desc: Boolean;
    Line: Integer;
  end;

  TQueryDecl = record
    Name: string;
    Params: array of TParamDecl;
    { Tom når spørringen er konkret. Er den satt, er ModelName navnet på
      typeparameteren, og For_ listen den skal instansieres for. }
    TypeParam: string;
    For_: array of string;
    ModelName: string;
    Single: Boolean;      { -> M gir én rad, -> [M] gir mange }
    Wheres: array of TCmp;
    Withs: array of string;   { relasjoner å hente med, fra skjemaet }
    Orders: array of TOrderTerm;
    Limit: Integer;
    Offset: Integer;
    Line: Integer;
  end;

  { En relasjon utledet av en fremmednøkkel i databasen. Ingen erklæring
    i Rún-kilden — skjemaet vet det allerede. }
  TRelation = record
    Name: string;         { navnet man skriver etter «with» }
    Table: string;        { tabellen som peker hit }
    ForeignKey: string;   { kolonnen i den som peker }
    LocalKey: string;     { kolonnen her den peker på }
  end;
  { Pascal tar ikke en anonym dynamisk array som returtype. }
  TRelationArray = array of TRelation;

  TModelDecl = record
    Name: string;
    Table: string;
    Line: Integer;
  end;

var
  GSrc: string;
  GPos: Integer;
  GLine: Integer;
  GTok: TToken;
  GFile: string;

  GDsn: string;
  GModels: array of TModelDecl;
  GQueries: array of TQueryDecl;
  { Spørringer etter monomorfisering: én per instansiering. }
  GConcrete: array of TQueryDecl;

{ ------------------------------------------------------------- feil -- }

procedure Err(Line: Integer; const Msg: string);
begin
  raise ERunError.CreateFmt('%s:%d: %s', [GFile, Line, Msg]);
end;

{ Nærmeste navn, til «mente du». En feilmelding som bare sier at noe ikke
  finnes er halve jobben når skjemaet står rett ved siden av. }
function Avstand(const A, B: string): Integer;
var
  D: array of array of Integer;
  I, J, Kost: Integer;
begin
  SetLength(D, Length(A) + 1, Length(B) + 1);
  for I := 0 to Length(A) do D[I][0] := I;
  for J := 0 to Length(B) do D[0][J] := J;
  for I := 1 to Length(A) do
    for J := 1 to Length(B) do
    begin
      if LowerCase(A[I]) = LowerCase(B[J]) then Kost := 0 else Kost := 1;
      D[I][J] := D[I - 1][J] + 1;
      if D[I][J - 1] + 1 < D[I][J] then D[I][J] := D[I][J - 1] + 1;
      if D[I - 1][J - 1] + Kost < D[I][J] then D[I][J] := D[I - 1][J - 1] + Kost;
    end;
  Result := D[Length(A)][Length(B)];
end;

function Mente(const Ukjent: string; const Kandidater: TStringArray): string;
var
  I, Best, D: Integer;
begin
  Result := '';
  Best := MaxInt;
  for I := 0 to High(Kandidater) do
  begin
    D := Avstand(Ukjent, Kandidater[I]);
    if D < Best then
    begin
      Best := D;
      Result := Kandidater[I];
    end;
  end;
  { Over en tredjedel av navnet er feil — da er gjettet verre enn ingenting. }
  if (Result = '') or (Best > (Length(Ukjent) div 2) + 1) then
    Result := '';
end;

{ ------------------------------------------------------------ lexer -- }

procedure NextToken;
var
  Start: Integer;
begin
  { Hvitrom og #-kommentarer. }
  while GPos <= Length(GSrc) do
  begin
    if GSrc[GPos] = #10 then
    begin
      Inc(GLine);
      Inc(GPos);
    end
    else if GSrc[GPos] in [' ', #9, #13] then
      Inc(GPos)
    else if GSrc[GPos] = '#' then
      while (GPos <= Length(GSrc)) and (GSrc[GPos] <> #10) do Inc(GPos)
    else
      Break;
  end;

  GTok.Line := GLine;
  if GPos > Length(GSrc) then
  begin
    GTok.Kind := tkEnd;
    GTok.Text_ := '';
    Exit;
  end;

  if GSrc[GPos] = '"' then
  begin
    Inc(GPos);
    Start := GPos;
    while (GPos <= Length(GSrc)) and (GSrc[GPos] <> '"') do Inc(GPos);
    GTok.Kind := tkString;
    GTok.Text_ := Copy(GSrc, Start, GPos - Start);
    Inc(GPos);
    Exit;
  end;

  if GSrc[GPos] in ['0'..'9', '-'] then
  begin
    Start := GPos;
    if GSrc[GPos] = '-' then Inc(GPos);
    while (GPos <= Length(GSrc)) and (GSrc[GPos] in ['0'..'9', '.']) do Inc(GPos);
    if GPos > Start + Ord(GSrc[Start] = '-') then
    begin
      GTok.Kind := tkNumber;
      GTok.Text_ := Copy(GSrc, Start, GPos - Start);
      Exit;
    end;
    GPos := Start;
  end;

  if GSrc[GPos] in ['a'..'z', 'A'..'Z', '_'] then
  begin
    Start := GPos;
    while (GPos <= Length(GSrc)) and
          (GSrc[GPos] in ['a'..'z', 'A'..'Z', '0'..'9', '_']) do Inc(GPos);
    GTok.Kind := tkIdent;
    GTok.Text_ := Copy(GSrc, Start, GPos - Start);
    Exit;
  end;

  { Tegn som kan være to tegn lange. }
  Start := GPos;
  if (GPos + 1 <= Length(GSrc)) then
  begin
    GTok.Text_ := Copy(GSrc, GPos, 2);
    if (GTok.Text_ = '==') or (GTok.Text_ = '!=') or (GTok.Text_ = '<=') or
       (GTok.Text_ = '>=') or (GTok.Text_ = '->') then
    begin
      Inc(GPos, 2);
      GTok.Kind := tkOp;
      Exit;
    end;
  end;
  GTok.Kind := tkOp;
  GTok.Text_ := GSrc[Start];
  Inc(GPos);
end;

function ErIdent(const S: string): Boolean;
begin
  Result := (GTok.Kind = tkIdent) and (GTok.Text_ = S);
end;

procedure Expect(const S: string);
begin
  if (GTok.Text_ <> S) or
     ((GTok.Kind <> tkIdent) and (GTok.Kind <> tkOp)) then
    Err(GTok.Line, Format('expected "%s", found "%s"', [S, GTok.Text_]));
  NextToken;
end;

function ExpectIdent: string;
begin
  if GTok.Kind <> tkIdent then
    Err(GTok.Line, Format('expected a name, found "%s"', [GTok.Text_]));
  Result := GTok.Text_;
  NextToken;
end;

{ ----------------------------------------------------------- parser -- }

function KindFromName(const S: string; Line: Integer): TRunKind;
begin
  if S = 'int' then Exit(rkInt);
  if S = 'text' then Exit(rkText);
  if S = 'bool' then Exit(rkBool);
  if S = 'money' then Exit(rkMoney);
  if S = 'float' then Exit(rkFloat);
  if S = 'time' then Exit(rkTime);
  Err(Line, Format('unknown type "%s". Known: int, text, bool, money, ' +
    'float, time', [S]));
  Result := rkText;
end;

procedure ParseModel;
var
  M: TModelDecl;
begin
  M.Line := GTok.Line;
  NextToken;
  M.Name := ExpectIdent;
  Expect('from');
  M.Table := ExpectIdent;
  SetLength(GModels, Length(GModels) + 1);
  GModels[High(GModels)] := M;
end;

procedure ParseQuery;
var
  Q: TQueryDecl;
  P: TParamDecl;
  W: TCmp;
  O: TOrderTerm;
begin
  FillChar(Q, SizeOf(Q), 0);
  Q.Line := GTok.Line;
  NextToken;

  { query<M> er en generisk spørring. Én erklæring, én konkret funksjon per
    modell i for-lista. Det er dette Pascal ikke kan uttrykke, og grunnen
    til at Rún finnes. }
  if GTok.Text_ = '<' then
  begin
    NextToken;
    Q.TypeParam := ExpectIdent;
    Expect('>');
  end;

  Q.Name := ExpectIdent;

  Expect('(');
  while GTok.Text_ <> ')' do
  begin
    P.Name := ExpectIdent;
    Expect(':');
    P.Kind := KindFromName(ExpectIdent, GTok.Line);
    SetLength(Q.Params, Length(Q.Params) + 1);
    Q.Params[High(Q.Params)] := P;
    if GTok.Text_ = ',' then
      NextToken;
  end;
  Expect(')');

  { -> M gir én rad, -> [M] gir mange. }
  if GTok.Text_ = '->' then
  begin
    NextToken;
    if GTok.Text_ = '[' then
    begin
      NextToken;
      ExpectIdent;
      Expect(']');
    end
    else
    begin
      ExpectIdent;
      Q.Single := True;
    end;
  end;

  if ErIdent('for') then
  begin
    if Q.TypeParam = '' then
      Err(GTok.Line, '"for" belongs to a generic query: query<M> Name(...) -> M for A, B');
    NextToken;
    repeat
      SetLength(Q.For_, Length(Q.For_) + 1);
      Q.For_[High(Q.For_)] := ExpectIdent;
      if GTok.Text_ = ',' then
        NextToken
      else
        Break;
    until False;
  end;
  if (Q.TypeParam <> '') and (Length(Q.For_) = 0) then
    Err(Q.Line, Format('the generic query "%s" is missing "for". ' +
      'Write "for Customer, Order" after the return type.', [Q.Name]));

  { En generisk spørring som bare henter på primærnøkkel trenger ingen
    kropp — «from M where id == id» er underforstått. }
  if (Q.TypeParam <> '') and (GTok.Text_ <> ':') then
  begin
    Q.ModelName := Q.TypeParam;
    Q.Single := True;
    SetLength(Q.Wheres, 1);
    FillChar(Q.Wheres[0], SizeOf(TCmp), 0);
    Q.Wheres[0].Col := 'id';
    Q.Wheres[0].Op := '==';
    Q.Wheres[0].HasOperand := True;
    Q.Wheres[0].IsParam := True;
    Q.Wheres[0].Operand := Q.Params[0].Name;
    Q.Wheres[0].Line := Q.Line;
    SetLength(GQueries, Length(GQueries) + 1);
    GQueries[High(GQueries)] := Q;
    Exit;
  end;

  Expect(':');
  Expect('from');
  Q.ModelName := ExpectIdent;
  if (Q.TypeParam <> '') and (Q.ModelName <> Q.TypeParam) then
    Err(GTok.Line, Format('a generic query selects from "%s", not "%s"', [Q.TypeParam, Q.ModelName]));

  while (GTok.Kind = tkIdent) and
        ((GTok.Text_ = 'where') or (GTok.Text_ = 'order') or
         (GTok.Text_ = 'limit') or (GTok.Text_ = 'offset') or
         (GTok.Text_ = 'with')) do
  begin
    if GTok.Text_ = 'where' then
    begin
      NextToken;
      repeat
        FillChar(W, SizeOf(W), 0);
        W.Line := GTok.Line;
        W.Col := ExpectIdent;

        { «is null» og «is not null» har ingen høyreside. }
        if ErIdent('is') then
        begin
          NextToken;
          if ErIdent('not') then
          begin
            NextToken;
            W.Op := 'is not';
          end
          else
            W.Op := 'is';
          if not ErIdent('null') then
            Err(GTok.Line, '"is" must be followed by "null" or "not null"');
          NextToken;
          W.HasOperand := False;
        end
        else
        begin
          if ErIdent('like') then
          begin
            W.Op := 'like';
            NextToken;
          end
          else
          begin
            if GTok.Kind <> tkOp then
              Err(GTok.Line, 'ventet en sammenlikning');
            W.Op := GTok.Text_;
            if (W.Op <> '==') and (W.Op <> '!=') and (W.Op <> '<') and
               (W.Op <> '<=') and (W.Op <> '>') and (W.Op <> '>=') then
              Err(GTok.Line, Format('"%s" is not a comparison', [W.Op]));
            NextToken;
          end;
          W.HasOperand := True;
          case GTok.Kind of
            tkString:
              begin
                W.IsParam := False;
                W.Operand := GTok.Text_;
                W.LitKind := rkText;
              end;
            tkNumber:
              begin
                W.IsParam := False;
                W.Operand := GTok.Text_;
                if Pos('.', GTok.Text_) > 0 then
                  W.LitKind := rkFloat
                else
                  W.LitKind := rkInt;
              end;
            tkIdent:
              if (GTok.Text_ = 'true') or (GTok.Text_ = 'false') then
              begin
                W.IsParam := False;
                W.Operand := GTok.Text_;
                W.LitKind := rkBool;
              end
              else
              begin
                W.IsParam := True;
                W.Operand := GTok.Text_;
              end;
          else
            Err(GTok.Line, 'expected a value or a parameter name');
          end;
          NextToken;
        end;

        SetLength(Q.Wheres, Length(Q.Wheres) + 1);
        Q.Wheres[High(Q.Wheres)] := W;
        if ErIdent('and') then
          NextToken
        else
          Break;
      until False;
    end
    else if GTok.Text_ = 'with' then
    begin
      { «with» er reservert i Pascal og kan ikke brukes til eager loading
        der. Her kan det. Relasjonen slås opp i fremmednøklene i skjemaet —
        den erklæres ikke. }
      NextToken;
      repeat
        SetLength(Q.Withs, Length(Q.Withs) + 1);
        Q.Withs[High(Q.Withs)] := ExpectIdent;
        if GTok.Text_ = ',' then
          NextToken
        else
          Break;
      until False;
    end
    else if GTok.Text_ = 'order' then
    begin
      NextToken;
      Expect('by');
      repeat
        FillChar(O, SizeOf(O), 0);
        O.Line := GTok.Line;
        O.Col := ExpectIdent;
        if ErIdent('desc') then
        begin
          O.Desc := True;
          NextToken;
        end
        else if ErIdent('asc') then
          NextToken;
        SetLength(Q.Orders, Length(Q.Orders) + 1);
        Q.Orders[High(Q.Orders)] := O;
        if GTok.Text_ = ',' then
          NextToken
        else
          Break;
      until False;
    end
    else if GTok.Text_ = 'offset' then
    begin
      NextToken;
      if GTok.Kind <> tkNumber then
        Err(GTok.Line, 'offset expects a number');
      Q.Offset := StrToIntDef(GTok.Text_, 0);
      NextToken;
    end
    else
    begin
      NextToken;
      if GTok.Kind <> tkNumber then
        Err(GTok.Line, 'limit expects a number');
      Q.Limit := StrToIntDef(GTok.Text_, 0);
      NextToken;
    end;
  end;

  SetLength(GQueries, Length(GQueries) + 1);
  GQueries[High(GQueries)] := Q;
end;

procedure Parse(const Src: string);
begin
  GSrc := Src;
  GPos := 1;
  GLine := 1;
  NextToken;

  if not ErIdent('db') then
    Err(GTok.Line, 'the file must start with db "<dsn>"');
  NextToken;
  if GTok.Kind <> tkString then
    Err(GTok.Line, 'db expects a quoted DSN');
  GDsn := GTok.Text_;
  NextToken;

  while GTok.Kind <> tkEnd do
  begin
    if ErIdent('model') then
      ParseModel
    else if ErIdent('query') then
      ParseQuery
    else
      Err(GTok.Line,
        Format('expected "model" or "query", found "%s"', [GTok.Text_]));
  end;
end;

{ -------------------------------------------------- comptime: skjemaet -- }

var
  GSchema: TDbSchema;
  GConn: TDbConnection;
  GDialect: TSqlDialect;

function KindFromSql(const SqlType: string; Scale: Integer): TRunKind;
var
  A: string;
begin
  { Samme oversettelse Norn bruker til kodegenerering. Poenget med spiken er
    ikke hvordan skjemaet leses, men når. }
  A := ColAliasFor(SqlType, Scale);
  if A = 'TColInt64' then Exit(rkInt);
  if A = 'TColBool' then Exit(rkBool);
  if A = 'TColCurrency' then Exit(rkMoney);
  if A = 'TColFloat' then Exit(rkFloat);
  if A = 'TColDateTime' then Exit(rkTime);
  Result := rkText;
end;

function KindName(K: TRunKind): string;
const
  N: array[TRunKind] of string =
    ('int', 'text', 'bool', 'money', 'float', 'time');
begin
  Result := N[K];
end;

function PascalType(K: TRunKind): string;
const
  N: array[TRunKind] of string =
    ('Int64', 'string', 'Boolean', 'Currency', 'Double', 'TDateTime');
begin
  Result := N[K];
end;

{ « Mente du X?» bare når gjettet er verdt noe. }
function IfThenText(const Gjett: string): string;
begin
  if Gjett = '' then
    Result := ''
  else
    Result := Format(' Did you mean "%s"?', [Gjett]);
end;

function TableFor(const ModelName: string; Line: Integer): TDbTable;
var
  I, J: Integer;
  Name: TStringArray;
  Table_: string;
begin
  for I := 0 to High(GModels) do
    if GModels[I].Name = ModelName then
    begin
      Table_ := GModels[I].Table;
      Result := GSchema.Table(Table_);
      if Result = nil then
      begin
        SetLength(Name, GSchema.TableCount);
        for J := 0 to GSchema.TableCount - 1 do
          Name[J] := GSchema.TableAt(J).Name;
        Err(Line, Format('table "%s" does not exist in the database.%s',
          [Table_, IfThenText(Mente(Table_, Name))]));
      end;
      Exit;
    end;
  Err(Line, Format('unknown model "%s"', [ModelName]));
  Result := nil;
end;

{ Pascal-navn for en kolonne: customer_id blir CustomerId. }
function PascalName(const Col: string): string;
var
  I: Integer;
  Big: Boolean;
begin
  Result := '';
  Big := True;
  for I := 1 to Length(Col) do
    if Col[I] = '_' then
      Big := True
    else
    begin
      if Big then
        Result := Result + UpCase(Col[I])
      else
        Result := Result + Col[I];
      Big := False;
    end;
end;

function SiterIdent(const S: string): string;
begin
  if GDialect = sdMySql then
    Result := '`' + StringReplace(S, '`', '``', [rfReplaceAll]) + '`'
  else
    Result := '"' + StringReplace(S, '"', '""', [rfReplaceAll]) + '"';
end;

function Plassholder(N: Integer): string;
begin
  { Dialekten er kjent ved comptime, fordi DSN-en står i kilden. Rún-koden
    nevner den aldri. }
  if GDialect = sdPostgres then
    Result := '$' + IntToStr(N)
  else
    Result := '?';
end;

{ --------------------------------------------- comptime: typesjekk + emit -- }

function ColumnKind(T: TDbTable; const Col: string; Line: Integer): TRunKind;
var
  Idx, I: Integer;
  C: TDbColumn;
  Name: TStringArray;
begin
  Idx := T.IndexOfColumn(Col);
  if Idx < 0 then
  begin
    SetLength(Name, T.ColumnCount);
    for I := 0 to T.ColumnCount - 1 do
      Name[I] := T.Column(I).Name;
    Err(Line, Format('table "%s" has no column "%s".%s',
      [T.Name, Col, IfThenText(Mente(Col, Name))]));
  end;
  C := T.Column(Idx);
  Result := KindFromSql(C.SqlType, C.Scale);
end;

function ParamKind(const Q: TQueryDecl; const Name: string;
  Line: Integer): TRunKind;
var
  I: Integer;
  Kandidater: TStringArray;
begin
  for I := 0 to High(Q.Params) do
    if Q.Params[I].Name = Name then
      Exit(Q.Params[I].Kind);
  SetLength(Kandidater, Length(Q.Params));
  for I := 0 to High(Q.Params) do
    Kandidater[I] := Q.Params[I].Name;
  Err(Line, Format('"%s" is neither a parameter nor a value.%s',
    [Name, IfThenText(Mente(Name, Kandidater))]));
  Result := rkText;
end;

{ Den avgjørende sjekken. Typen på venstresiden kommer fra databasen, typen
  på høyresiden fra kilden — og de må stemme. Det er dette Pascal ikke kan
  gjøre uten enten kodegenerering eller tjueen overlastinger. }
procedure CheckComparison(T: TDbTable; const Q: TQueryDecl;
  const W: TCmp);
var
  Venstre, Hoyre: TRunKind;
begin
  Venstre := ColumnKind(T, W.Col, W.Line);
  if W.IsParam then
    Hoyre := ParamKind(Q, W.Operand, W.Line)
  else
    Hoyre := W.LitKind;

  { int mot money og float er greit — tallene er tall. Alt annet er det ikke. }
  if Venstre = Hoyre then
    Exit;
  if (Venstre in [rkInt, rkMoney, rkFloat]) and
     (Hoyre in [rkInt, rkMoney, rkFloat]) then
    Exit;

  Err(W.Line, Format(
    '"%s" is %s in table %s, but is compared with %s. ' +
    'The schema was read from %s.',
    [W.Col, KindName(Venstre), T.Name, KindName(Hoyre), GDsn]));
end;

{ Relasjoner utledes av fremmednøklene i databasen. Ingen erklæring i
  Rún-kilden: peker orders.customer_id på customers.id, så har Customer en
  relasjon som heter «orders». Det er hele poenget med comptime — skjemaet
  vet dette allerede, og da skal ingen skrive det en gang til. }
function RelasjonerFor(T: TDbTable): TRelationArray;
var
  I, J: Integer;
  Annen: TDbTable;
  FK: TDbForeignKey;
  R: TRelation;
begin
  Result := nil;
  for I := 0 to GSchema.TableCount - 1 do
  begin
    Annen := GSchema.TableAt(I);
    for J := 0 to Annen.ForeignKeyCount - 1 do
    begin
      FK := Annen.ForeignKey(J);
      if not SameText(FK.RefTable, T.Name) then
        Continue;
      R.Name := Annen.Name;
      R.Table := Annen.Name;
      R.ForeignKey := FK.Column;
      R.LocalKey := FK.RefColumn;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := R;
    end;
  end;
end;

function FindRelation(T: TDbTable; const Name: string;
  Line: Integer): TRelation;
var
  Rels: TRelationArray;
  I: Integer;
  Name_: TStringArray;
begin
  Rels := RelasjonerFor(T);
  for I := 0 to High(Rels) do
    if SameText(Rels[I].Name, Name) then
      Exit(Rels[I]);
  SetLength(Name_, Length(Rels));
  for I := 0 to High(Rels) do
    Name_[I] := Rels[I].Name;
  if Length(Name_) = 0 then
    Err(Line, Format('nothing points at %s, so it has no relations to ' +
      'load with "with"', [T.Name]))
  else
    Err(Line, Format('%s has no relation "%s".%s',
      [T.Name, Name, IfThenText(Mente(Name, Name_))]));
  Result.Name := '';
end;

{ Modellnavnet for en tabell, slik at en relasjon kan peke på en radtype
  som faktisk blir skrevet ut. }
function ModelForTable(const Table: string): string;
var
  I: Integer;
begin
  for I := 0 to High(GModels) do
    if SameText(GModels[I].Table, Table) then
      Exit(GModels[I].Name);
  Result := '';
end;

{ Radtypene må skrives ut i avhengighetsrekkefølge. En Customer-record som
  har et felt av typen TOrderRowArray må komme etter TOrderRow, fordi Pascal
  ikke tillater fremoverreferanse til en record. Relasjonene peker motsatt
  vei av fremmednøklene, så rekkefølgen følger av skjemaet — og en syklus
  mellom to tabeller er en ekte begrensning som må sies fra om, ikke skjules.
  Dybdeførst med de tre vanlige markørene. }
procedure SortModels(out Order_: TStringArray);
var
  Mark: array of Byte;   { 0 urørt, 1 under arbeid, 2 ferdig }
  Ut: TStringArray;

  function IndeksFor(const Name: string): Integer;
  var
    K: Integer;
  begin
    for K := 0 to High(GModels) do
      if GModels[K].Name = Name then
        Exit(K);
    Result := -1;
  end;

  procedure Besok(Idx: Integer);
  var
    T: TDbTable;
    Rels: TRelationArray;
    K, D: Integer;
    RelModel: string;
  begin
    if Mark[Idx] = 2 then
      Exit;
    if Mark[Idx] = 1 then
      Err(GModels[Idx].Line, Format(
        'the models form a relation cycle through "%s". Pascal records ' +
        'cannot reference each other, so one of the relations has to go.',
        [GModels[Idx].Name]));
    Mark[Idx] := 1;
    T := GSchema.Table(GModels[Idx].Table);
    if T <> nil then
    begin
      Rels := RelasjonerFor(T);
      for K := 0 to High(Rels) do
      begin
        RelModel := ModelForTable(Rels[K].Table);
        if RelModel = '' then
          Continue;
        D := IndeksFor(RelModel);
        if (D >= 0) and (D <> Idx) then
          Besok(D);
      end;
    end;
    Mark[Idx] := 2;
    SetLength(Ut, Length(Ut) + 1);
    Ut[High(Ut)] := GModels[Idx].Name;
  end;

var
  I: Integer;
begin
  SetLength(Mark, Length(GModels));
  Ut := nil;
  for I := 0 to High(GModels) do
    Besok(I);
  Order_ := Ut;
end;

{ Monomorfisering. En generisk spørring blir én konkret per modell i
  for-lista, med typeparameteren byttet ut. Dette er svaret på at
  Where<T> er umulig i Pascal: vi skriver ut de konkrete variantene i
  stedet for å kreve dem av kompilatoren. }
procedure Monomorfiser;
var
  I, J: Integer;
  Q, K: TQueryDecl;
begin
  GConcrete := nil;
  for I := 0 to High(GQueries) do
  begin
    Q := GQueries[I];
    if Q.TypeParam = '' then
    begin
      SetLength(GConcrete, Length(GConcrete) + 1);
      GConcrete[High(GConcrete)] := Q;
      Continue;
    end;
    for J := 0 to High(Q.For_) do
    begin
      K := Q;
      K.TypeParam := '';
      K.For_ := nil;
      K.ModelName := Q.For_[J];
      K.Name := Q.For_[J] + Q.Name;
      SetLength(GConcrete, Length(GConcrete) + 1);
      GConcrete[High(GConcrete)] := K;
    end;
  end;
end;

function SqlOp(const Op: string): string;
begin
  if Op = '==' then Exit('=');
  if Op = '!=' then Exit('<>');
  if Op = 'like' then Exit('LIKE');
  if Op = 'is' then Exit('IS NULL');
  if Op = 'is not' then Exit('IS NOT NULL');
  Result := Op;
end;

function BindUttrykk(const Q: TQueryDecl; const W: TCmp): string;
var
  K: TRunKind;
begin
  if W.IsParam then
  begin
    K := ParamKind(Q, W.Operand, W.Line);
    case K of
      rkFloat: Result := Format('DbParam(A, FloatToSql(%s))',
        [PascalName(W.Operand)]);
      rkTime: Result := Format('DbParamDateTime(A, %s)',
        [PascalName(W.Operand)]);
    else
      Result := Format('DbParam(A, %s)', [PascalName(W.Operand)]);
    end;
    Exit;
  end;
  case W.LitKind of
    rkText: Result := Format('DbParam(A, %s)', [QuotedStr(W.Operand)]);
    rkBool: Result := Format('DbParam(A, %s)', [W.Operand]);
    rkFloat: Result := Format('DbParam(A, FloatToSql(%s))', [W.Operand]);
  else
    Result := Format('DbParam(A, Int64(%s))', [W.Operand]);
  end;
end;

function ColumnList(T: TDbTable): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to T.ColumnCount - 1 do
  begin
    if I > 0 then Result := Result + ', ';
    Result := Result + SiterIdent(T.Column(I).Name);
  end;
end;

function EmitQuery(var Ut: TStringList; const Q: TQueryDecl;
  Grensesnitt: Boolean): string;
var
  T, RT: TDbTable;
  I, PNo: Integer;
  Sql, Args, Bind, RowType, Ret: string;
  Rel: TRelation;
  RelModel: string;
begin
  T := TableFor(Q.ModelName, Q.Line);
  RowType := 'T' + Q.ModelName + 'Row';

  Args := '';
  for I := 0 to High(Q.Params) do
    Args := Args + '; ' + PascalName(Q.Params[I].Name) + ': ' +
      PascalType(Q.Params[I].Kind);
  if Q.Single then
  begin
    Args := Args + '; out Found: Boolean';
    Ret := RowType;
  end
  else
    Ret := RowType + 'Array';

  Result := Format('function %s(A: TArena; C: TDbConnection%s): %s;',
    [Q.Name, Args, Ret]);
  if Grensesnitt then
  begin
    Ut.Add(Result);
    Exit;
  end;

  Sql := 'SELECT ' + ColumnList(T) + ' FROM ' + SiterIdent(T.Name);

  PNo := 0;
  Bind := '';
  if Length(Q.Wheres) > 0 then
  begin
    Sql := Sql + ' WHERE ';
    for I := 0 to High(Q.Wheres) do
    begin
      CheckComparison(T, Q, Q.Wheres[I]);
      if I > 0 then Sql := Sql + ' AND ';
      Sql := Sql + SiterIdent(Q.Wheres[I].Col) + ' ';
      if Q.Wheres[I].HasOperand then
      begin
        Inc(PNo);
        Sql := Sql + SqlOp(Q.Wheres[I].Op) + ' ' + Plassholder(PNo);
        if Bind <> '' then Bind := Bind + ', ';
        Bind := Bind + BindUttrykk(Q, Q.Wheres[I]);
      end
      else
        Sql := Sql + SqlOp(Q.Wheres[I].Op);
    end;
  end;

  if Length(Q.Orders) > 0 then
  begin
    Sql := Sql + ' ORDER BY ';
    for I := 0 to High(Q.Orders) do
    begin
      ColumnKind(T, Q.Orders[I].Col, Q.Orders[I].Line);
      if I > 0 then Sql := Sql + ', ';
      Sql := Sql + SiterIdent(Q.Orders[I].Col);
      if Q.Orders[I].Desc then Sql := Sql + ' DESC';
    end;
  end;
  if Q.Single then
    Sql := Sql + ' LIMIT 1'
  else if Q.Limit > 0 then
    Sql := Sql + ' LIMIT ' + IntToStr(Q.Limit);
  if Q.Offset > 0 then
    Sql := Sql + ' OFFSET ' + IntToStr(Q.Offset);

  Ut.Add(Result);
  Ut.Add('var');
  Ut.Add('  R: TDbResult;');
  Ut.Add('  I: Integer;');
  if not Q.Single then
    Ut.Add('  Rows: ' + RowType + 'Array;');
  if Length(Q.Withs) > 0 then
  begin
    Ut.Add('  Ids: TStrBuilder;');
    Ut.Add('  RR: TDbResult;');
    Ut.Add('  J: Integer;');
  end;
  Ut.Add('begin');
  if Q.Single then
    Ut.Add('  Result := Default(' + RowType + ');');
  Ut.Add('  R := C.ExecParams(A,');
  Ut.Add('    ' + QuotedStr(Sql) + ',');
  Ut.Add('    [' + Bind + ']);');

  if Q.Single then
  begin
    Ut.Add('  Found := R.RowCount > 0;');
    Ut.Add('  if Found then');
    Ut.Add('    Result := Read' + Q.ModelName + 'Row(R, 0);');
    Ut.Add('end;');
    Ut.Add('');
    Exit;
  end;

  Ut.Add('  SetLength(Rows, R.RowCount);');
  Ut.Add('  for I := 0 to R.RowCount - 1 do');
  Ut.Add('    Rows[I] := Read' + Q.ModelName + 'Row(R, I);');

  { Eager loading: én spørring per relasjon, ikke én per rad. Det er
    forskjellen på «with» og en løkke, og grunnen til at den er verdt et
    eget nøkkelord. }
  for I := 0 to High(Q.Withs) do
  begin
    Rel := FindRelation(T, Q.Withs[I], Q.Line);
    RelModel := ModelForTable(Rel.Table);
    if RelModel = '' then
      Err(Q.Line, Format('the relation "%s" points at table %s, which has ' +
        'no model. Add: model <Name> from %s',
        [Rel.Name, Rel.Table, Rel.Table]));
    RT := GSchema.Table(Rel.Table);

    Ut.Add('');
    Ut.Add('  { ' + Rel.Name + ': ' + Rel.Table + '.' + Rel.ForeignKey +
           ' -> ' + T.Name + '.' + Rel.LocalKey + ', read from the schema }');
    Ut.Add('  if Length(Rows) > 0 then');
    Ut.Add('  begin');
    Ut.Add('    Ids.Init(A, 128);');
    Ut.Add('    for I := 0 to High(Rows) do');
    Ut.Add('    begin');
    Ut.Add('      if I > 0 then Ids.Append('','');');
    Ut.Add('      Ids.Append(IntToStr(Rows[I].' +
           PascalName(Rel.LocalKey) + '));');
    Ut.Add('    end;');
    Ut.Add('    RR := C.Exec(A,');
    Ut.Add('      ' + QuotedStr('SELECT ' + ColumnList(RT) + ' FROM ' +
           SiterIdent(RT.Name) + ' WHERE ' + SiterIdent(Rel.ForeignKey) +
           ' IN (') + ' + Ids.ToString + '')'');');
    Ut.Add('    for I := 0 to High(Rows) do');
    Ut.Add('      for J := 0 to RR.RowCount - 1 do');
    Ut.Add('        if Rows[I].' + PascalName(Rel.LocalKey) +
           ' = StrToInt64Def(RR.Value(J, ' +
           IntToStr(RT.IndexOfColumn(Rel.ForeignKey)) + ').ToString, -1) then');
    Ut.Add('        begin');
    Ut.Add('          SetLength(Rows[I].' + PascalName(Rel.Name) + ',');
    Ut.Add('            Length(Rows[I].' + PascalName(Rel.Name) + ') + 1);');
    Ut.Add('          Rows[I].' + PascalName(Rel.Name) +
           '[High(Rows[I].' + PascalName(Rel.Name) + ')] :=');
    Ut.Add('            Read' + RelModel + 'Row(RR, J);');
    Ut.Add('        end;');
    Ut.Add('  end;');
  end;

  Ut.Add('  Result := Rows;');
  Ut.Add('end;');
  Ut.Add('');
end;

procedure EmitRowType(var Ut: TStringList; const M: TModelDecl;
  Grensesnitt: Boolean);
var
  T: TDbTable;
  I: Integer;
  K: TRunKind;
  C: TDbColumn;
  Rels: TRelationArray;
  RelModel: string;
begin
  T := GSchema.Table(M.Table);
  Rels := RelasjonerFor(T);

  if Grensesnitt then
  begin
    Ut.Add(Format('  { %s — fields and types read from the schema at comptime }',
      [M.Table]));
    Ut.Add('  T' + M.Name + 'Row = record');
    for I := 0 to T.ColumnCount - 1 do
    begin
      C := T.Column(I);
      K := KindFromSql(C.SqlType, C.Scale);
      Ut.Add(Format('    %s: %s;   { %s }',
        [PascalName(C.Name), PascalType(K), C.SqlType]));
    end;
    for I := 0 to High(Rels) do
    begin
      RelModel := ModelForTable(Rels[I].Table);
      if RelModel <> '' then
        Ut.Add(Format('    %s: T%sRowArray;   { %s.%s }',
          [PascalName(Rels[I].Name), RelModel, Rels[I].Table,
           Rels[I].ForeignKey]));
    end;
    Ut.Add('  end;');
    Ut.Add('  T' + M.Name + 'RowArray = array of T' + M.Name + 'Row;');
    Ut.Add('');
    Exit;
  end;

  Ut.Add(Format('function Read%sRow(R: TDbResult; Row: Integer): T%sRow;',
    [M.Name, M.Name]));
  Ut.Add('var');
  Ut.Add(Format('  Row_: T%sRow;', [M.Name]));
  Ut.Add('begin');
  for I := 0 to T.ColumnCount - 1 do
  begin
    C := T.Column(I);
    K := KindFromSql(C.SqlType, C.Scale);
    case K of
      rkInt: Ut.Add(Format('  SqlToInt64(R.Value(Row, %d), Row_.%s);',
        [I, PascalName(C.Name)]));
      rkBool: Ut.Add(Format('  SqlToBool(R.Value(Row, %d), Row_.%s);',
        [I, PascalName(C.Name)]));
      rkMoney: Ut.Add(Format('  SqlToCurrency(R.Value(Row, %d), Row_.%s);',
        [I, PascalName(C.Name)]));
      rkFloat: Ut.Add(Format('  SqlToFloat(R.Value(Row, %d), Row_.%s);',
        [I, PascalName(C.Name)]));
      rkTime: Ut.Add(Format('  SqlToDateTime(R.Value(Row, %d), Row_.%s);',
        [I, PascalName(C.Name)]));
    else
      Ut.Add(Format('  Row_.%s := R.Value(Row, %d).ToString;',
        [PascalName(C.Name), I]));
    end;
  end;
  Ut.Add('  Result := Row_;');
  Ut.Add('end;');
  Ut.Add('');
end;

function ModellIndeks(const Name: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(GModels) do
    if GModels[I].Name = Name then
      Exit(I);
  Result := 0;
end;

{ Som engangsprogram spilte global tilstand ingen rolle — prosessen døde
  etter én oversettelse. Som unit kalles Transpile én gang per .run-fil, og
  da må alt nullstilles først. Without dette arver fil nummer to modellene fra
  fil nummer én, og feilmeldingene blir meningsløse. }
procedure ResetState;
begin
  GSrc := '';
  GPos := 1;
  GLine := 1;
  GDsn := '';
  GFile := '';
  GModels := nil;
  GQueries := nil;
  GConcrete := nil;
  GSchema := nil;
  GConn := nil;
  { TToken har et strengfelt. FillChar over den ville etterlatt en
    referanse som ingen slipper. }
  GTok.Text_ := '';
  GTok.Line := 0;
  GTok.Kind := tkEnd;
end;

function Transpile(const InFile, OutFile, UnitName: string): TRunStats;
var
  Source_: TStringList;
  Ut: TStringList;
  I: Integer;
  T0, TWasRead, TSkjema, TEmit: Int64;
  Orden: TStringArray;
begin
  ResetState;
  T0 := MonotonicMs;
  GFile := InFile;
  Source_ := TStringList.Create;
  Ut := TStringList.Create;
  try
    Source_.LoadFromFile(InFile);
    Parse(Source_.Text);
    TWasRead := MonotonicMs - T0;

    { **Comptime.** Databasen åpnes mens kilden oversettes, og skjemaet
      leses derfra. Ingenting av dette finnes på disk etterpå. }
    GConn := OpenDbConnection(GDsn);
    GDialect := GConn.Dialect;
    GSchema := IntrospectSchema(GConn);
    TSkjema := MonotonicMs - T0 - TWasRead;

    for I := 0 to High(GModels) do
      if GSchema.Table(GModels[I].Table) = nil then
        TableFor(GModels[I].Name, GModels[I].Line);

    Ut.Add('{ GENERATED BY askr build (Rún) — DO NOT EDIT.');
    Ut.Add('');
    Ut.Add('  Emitted from ' + ExtractFileName(InFile) + ', with the schema');
    Ut.Add('  read from ' + GDsn + ' at that same moment. This file is an');
    Ut.Add('  intermediate: it belongs in the build directory, not in source. }');
    Ut.Add('unit ' + UnitName + ';');
    Ut.Add('');
    Ut.Add('{$mode Delphi}{$H+}');
    Ut.Add('');
    Ut.Add('interface');
    Ut.Add('');
    Ut.Add('uses');
    Ut.Add('  SysUtils, Askr.Core.Arena, Askr.Core.Text, Askr.Urd.Driver;');
    Ut.Add('');
    Ut.Add('type');
    SortModels(Orden);
    for I := 0 to High(Orden) do
      EmitRowType(Ut, GModels[ModellIndeks(Orden[I])], True);
    Monomorfiser;
    for I := 0 to High(GConcrete) do
      EmitQuery(Ut, GConcrete[I], True);
    Ut.Add('');
    Ut.Add('implementation');
    Ut.Add('');
    for I := 0 to High(Orden) do
      EmitRowType(Ut, GModels[ModellIndeks(Orden[I])], False);
    for I := 0 to High(GConcrete) do
      EmitQuery(Ut, GConcrete[I], False);
    Ut.Add('end.');

    ForceDirectories(ExtractFilePath(OutFile));
    Ut.SaveToFile(OutFile);
    TEmit := MonotonicMs - T0 - TWasRead - TSkjema;

    Result.Models := Length(GModels);
    Result.Queries := Length(GConcrete);
    Result.Dialect := Copy(GDsn, 1, Pos(':', GDsn) - 1);
    Result.ParseMs := TWasRead;
    Result.SchemaMs := TSkjema;
    Result.EmitMs := TEmit;
    Result.TotalMs := MonotonicMs - T0;
  finally
    GSchema.Free;
    GConn.Free;
    Ut.Free;
    Source_.Free;
  end;
end;

function UnitNameFor(const RunFile, Namespace: string): string;
var
  Base: string;
begin
  Base := ChangeFileExt(ExtractFileName(RunFile), '');
  if Base = '' then
    Base := 'Queries';
  Base := UpCase(Base[1]) + Copy(Base, 2, MaxInt);
  if Namespace = '' then
    Result := Base
  else
    Result := Namespace + '.' + Base;
end;

end.
