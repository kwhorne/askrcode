{ Askr.Run — Rún, translated into Pascal.

  Rún exists because Free Pascal cannot express two things Askr needs: a
  generic method (`Where<T>`), and `with` as the name for eager loading —
  `with` is a reserved word. Both are real limits, verified on both 3.2.2
  and trunk, and they do not go away by waiting.

  The answer is not a new compiler. It is a transpiler that writes out the
  concrete variants Pascal can accept:

    query<M> ById(id: int) -> M for Customer, Order

  becomes `CustomerById` and `OrderById`, each with its own row type.

  The schema is read from the database **while the source is being
  translated**. Columns, types and relations appear nowhere in the Rún
  source — `with orders` works because `orders.customer_id` points at
  `customers.id`, and the database knows that already.

  The cost is measured: 3–4 ms against SQLite with up to 62 tables.
  Against Postgres it is 70 ms at 61 tables, which is more than the
  developer loop has to spare — the measurement and what follows from it
  are in the Rún document. A production variant has to cache the schema.

  The unit keeps state in global variables. That is deliberate: a
  translation is one run from start to finish, and a context record would
  only have moved the same state somewhere else. It is not thread safe,
  and is not to be used from several threads. }
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

  { What the translation cost and what it found. For logging, and for
    measuring that Rún still fits inside the developer loop. }
  TRunStats = record
    Models: Integer;
    Queries: Integer;
    Dialect: string;
    ParseMs: Int64;
    SchemaMs: Int64;
    EmitMs: Int64;
    TotalMs: Int64;
  end;

{ Translates one .run file into one Pascal unit. Raises ERunError with
  the file, the line and what was wrong. }
function Transpile(const InFile, OutFile, UnitName: string): TRunStats;

{ The unit name a .run file is to give, after the file name:
  app/Queries.run becomes App.Queries. }
function UnitNameFor(const RunFile, Namespace: string): string;

implementation

type
  { The types the language knows. They come from the schema, not from the
    source. }
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
    HasOperand: Boolean;  { "is null" has no right-hand side }
    IsParam: Boolean;
    Operand: string;      { parameter name, or the literal as written }
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
    { Empty when the query is concrete. When it is set, ModelName is the
      name of the type parameter, and For_ the list it is to be
      instantiated for. }
    TypeParam: string;
    For_: array of string;
    ModelName: string;
    Single: Boolean;      { -> M gir én rad, -> [M] gir mange }
    Wheres: array of TCmp;
    Withs: array of string;   { relations to fetch along, from the schema }
    Orders: array of TOrderTerm;
    Limit: Integer;
    Offset: Integer;
    Line: Integer;
  end;

  { A relation derived from a foreign key in the database. No declaration
    in the Rún source — the schema knows it already. }
  TRelation = record
    Name: string;         { the name you write after "with" }
    Table: string;        { tabellen som peker hit }
    ForeignKey: string;   { the column in the one that points }
    LocalKey: string;     { the column here that it points at }
  end;
  { Pascal does not take an anonymous dynamic array as a return type. }
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
  GTokens: TToken;
  GFile: string;

  GDsn: string;
  GModels: array of TModelDecl;
  GQueries: array of TQueryDecl;
  { Queries after monomorphization: one per instantiation. }
  GConcrete: array of TQueryDecl;

{ ------------------------------------------------------------- feil -- }

procedure Err(Line: Integer; const Msg: string);
begin
  raise ERunError.CreateFmt('%s:%d: %s', [GFile, Line, Msg]);
end;

{ The nearest name, for "did you mean". An error message that only says
  something does not exist is half the job when the schema is sitting right
  next to it. }
function Distance(const A, B: string): Integer;
var
  D: array of array of Integer;
  I, J, Cost: Integer;
begin
  SetLength(D, Length(A) + 1, Length(B) + 1);
  for I := 0 to Length(A) do D[I][0] := I;
  for J := 0 to Length(B) do D[0][J] := J;
  for I := 1 to Length(A) do
    for J := 1 to Length(B) do
    begin
      if LowerCase(A[I]) = LowerCase(B[J]) then Cost := 0 else Cost := 1;
      D[I][J] := D[I - 1][J] + 1;
      if D[I][J - 1] + 1 < D[I][J] then D[I][J] := D[I][J - 1] + 1;
      if D[I - 1][J - 1] + Cost < D[I][J] then D[I][J] := D[I - 1][J - 1] + Cost;
    end;
  Result := D[Length(A)][Length(B)];
end;

function DidYouMean(const Unknown_: string; const Candidates: TStringArray): string;
var
  I, Best, D: Integer;
begin
  Result := '';
  Best := MaxInt;
  for I := 0 to High(Candidates) do
  begin
    D := Distance(Unknown_, Candidates[I]);
    if D < Best then
    begin
      Best := D;
      Result := Candidates[I];
    end;
  end;
  { Over en tredjedel av navnet er feil — da er gjettet verre enn ingenting. }
  if (Result = '') or (Best > (Length(Unknown_) div 2) + 1) then
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

  GTokens.Line := GLine;
  if GPos > Length(GSrc) then
  begin
    GTokens.Kind := tkEnd;
    GTokens.Text_ := '';
    Exit;
  end;

  if GSrc[GPos] = '"' then
  begin
    Inc(GPos);
    Start := GPos;
    while (GPos <= Length(GSrc)) and (GSrc[GPos] <> '"') do Inc(GPos);
    GTokens.Kind := tkString;
    GTokens.Text_ := Copy(GSrc, Start, GPos - Start);
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
      GTokens.Kind := tkNumber;
      GTokens.Text_ := Copy(GSrc, Start, GPos - Start);
      Exit;
    end;
    GPos := Start;
  end;

  if GSrc[GPos] in ['a'..'z', 'A'..'Z', '_'] then
  begin
    Start := GPos;
    while (GPos <= Length(GSrc)) and
          (GSrc[GPos] in ['a'..'z', 'A'..'Z', '0'..'9', '_']) do Inc(GPos);
    GTokens.Kind := tkIdent;
    GTokens.Text_ := Copy(GSrc, Start, GPos - Start);
    Exit;
  end;

  { Characters that can be two characters long. }
  Start := GPos;
  if (GPos + 1 <= Length(GSrc)) then
  begin
    GTokens.Text_ := Copy(GSrc, GPos, 2);
    if (GTokens.Text_ = '==') or (GTokens.Text_ = '!=') or (GTokens.Text_ = '<=') or
       (GTokens.Text_ = '>=') or (GTokens.Text_ = '->') then
    begin
      Inc(GPos, 2);
      GTokens.Kind := tkOp;
      Exit;
    end;
  end;
  GTokens.Kind := tkOp;
  GTokens.Text_ := GSrc[Start];
  Inc(GPos);
end;

function IsIdent(const S: string): Boolean;
begin
  Result := (GTokens.Kind = tkIdent) and (GTokens.Text_ = S);
end;

procedure Expect(const S: string);
begin
  if (GTokens.Text_ <> S) or
     ((GTokens.Kind <> tkIdent) and (GTokens.Kind <> tkOp)) then
    Err(GTokens.Line, Format('expected "%s", found "%s"', [S, GTokens.Text_]));
  NextToken;
end;

function ExpectIdent: string;
begin
  if GTokens.Kind <> tkIdent then
    Err(GTokens.Line, Format('expected a name, found "%s"', [GTokens.Text_]));
  Result := GTokens.Text_;
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
  M.Line := GTokens.Line;
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
  Q.Line := GTokens.Line;
  NextToken;

  { query<M> is a generic query. One declaration, one concrete function per
    model in the for list. This is what Pascal cannot express, and the
    reason Rún exists. }
  if GTokens.Text_ = '<' then
  begin
    NextToken;
    Q.TypeParam := ExpectIdent;
    Expect('>');
  end;

  Q.Name := ExpectIdent;

  Expect('(');
  while GTokens.Text_ <> ')' do
  begin
    P.Name := ExpectIdent;
    Expect(':');
    P.Kind := KindFromName(ExpectIdent, GTokens.Line);
    SetLength(Q.Params, Length(Q.Params) + 1);
    Q.Params[High(Q.Params)] := P;
    if GTokens.Text_ = ',' then
      NextToken;
  end;
  Expect(')');

  { -> M gir én rad, -> [M] gir mange. }
  if GTokens.Text_ = '->' then
  begin
    NextToken;
    if GTokens.Text_ = '[' then
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

  if IsIdent('for') then
  begin
    if Q.TypeParam = '' then
      Err(GTokens.Line, '"for" belongs to a generic query: query<M> Name(...) -> M for A, B');
    NextToken;
    repeat
      SetLength(Q.For_, Length(Q.For_) + 1);
      Q.For_[High(Q.For_)] := ExpectIdent;
      if GTokens.Text_ = ',' then
        NextToken
      else
        Break;
    until False;
  end;
  if (Q.TypeParam <> '') and (Length(Q.For_) = 0) then
    Err(Q.Line, Format('the generic query "%s" is missing "for". ' +
      'Write "for Customer, Order" after the return type.', [Q.Name]));

  { A generic query that only fetches on the primary key needs no body —
    "from M where id == id" is understood. }
  if (Q.TypeParam <> '') and (GTokens.Text_ <> ':') then
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
    Err(GTokens.Line, Format('a generic query selects from "%s", not "%s"', [Q.TypeParam, Q.ModelName]));

  while (GTokens.Kind = tkIdent) and
        ((GTokens.Text_ = 'where') or (GTokens.Text_ = 'order') or
         (GTokens.Text_ = 'limit') or (GTokens.Text_ = 'offset') or
         (GTokens.Text_ = 'with')) do
  begin
    if GTokens.Text_ = 'where' then
    begin
      NextToken;
      repeat
        FillChar(W, SizeOf(W), 0);
        W.Line := GTokens.Line;
        W.Col := ExpectIdent;

        { "is null" and "is not null" have no right-hand side. }
        if IsIdent('is') then
        begin
          NextToken;
          if IsIdent('not') then
          begin
            NextToken;
            W.Op := 'is not';
          end
          else
            W.Op := 'is';
          if not IsIdent('null') then
            Err(GTokens.Line, '"is" must be followed by "null" or "not null"');
          NextToken;
          W.HasOperand := False;
        end
        else
        begin
          if IsIdent('like') then
          begin
            W.Op := 'like';
            NextToken;
          end
          else
          begin
            if GTokens.Kind <> tkOp then
              Err(GTokens.Line, 'ventet en sammenlikning');
            W.Op := GTokens.Text_;
            if (W.Op <> '==') and (W.Op <> '!=') and (W.Op <> '<') and
               (W.Op <> '<=') and (W.Op <> '>') and (W.Op <> '>=') then
              Err(GTokens.Line, Format('"%s" is not a comparison', [W.Op]));
            NextToken;
          end;
          W.HasOperand := True;
          case GTokens.Kind of
            tkString:
              begin
                W.IsParam := False;
                W.Operand := GTokens.Text_;
                W.LitKind := rkText;
              end;
            tkNumber:
              begin
                W.IsParam := False;
                W.Operand := GTokens.Text_;
                if Pos('.', GTokens.Text_) > 0 then
                  W.LitKind := rkFloat
                else
                  W.LitKind := rkInt;
              end;
            tkIdent:
              if (GTokens.Text_ = 'true') or (GTokens.Text_ = 'false') then
              begin
                W.IsParam := False;
                W.Operand := GTokens.Text_;
                W.LitKind := rkBool;
              end
              else
              begin
                W.IsParam := True;
                W.Operand := GTokens.Text_;
              end;
          else
            Err(GTokens.Line, 'expected a value or a parameter name');
          end;
          NextToken;
        end;

        SetLength(Q.Wheres, Length(Q.Wheres) + 1);
        Q.Wheres[High(Q.Wheres)] := W;
        if IsIdent('and') then
          NextToken
        else
          Break;
      until False;
    end
    else if GTokens.Text_ = 'with' then
    begin
      { "with" is reserved in Pascal and cannot be used for eager loading
        there. Here it can. The relation is looked up in the foreign keys
        in the schema — it is not declared. }
      NextToken;
      repeat
        SetLength(Q.Withs, Length(Q.Withs) + 1);
        Q.Withs[High(Q.Withs)] := ExpectIdent;
        if GTokens.Text_ = ',' then
          NextToken
        else
          Break;
      until False;
    end
    else if GTokens.Text_ = 'order' then
    begin
      NextToken;
      Expect('by');
      repeat
        FillChar(O, SizeOf(O), 0);
        O.Line := GTokens.Line;
        O.Col := ExpectIdent;
        if IsIdent('desc') then
        begin
          O.Desc := True;
          NextToken;
        end
        else if IsIdent('asc') then
          NextToken;
        SetLength(Q.Orders, Length(Q.Orders) + 1);
        Q.Orders[High(Q.Orders)] := O;
        if GTokens.Text_ = ',' then
          NextToken
        else
          Break;
      until False;
    end
    else if GTokens.Text_ = 'offset' then
    begin
      NextToken;
      if GTokens.Kind <> tkNumber then
        Err(GTokens.Line, 'offset expects a number');
      Q.Offset := StrToIntDef(GTokens.Text_, 0);
      NextToken;
    end
    else
    begin
      NextToken;
      if GTokens.Kind <> tkNumber then
        Err(GTokens.Line, 'limit expects a number');
      Q.Limit := StrToIntDef(GTokens.Text_, 0);
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

  if not IsIdent('db') then
    Err(GTokens.Line, 'the file must start with db "<dsn>"');
  NextToken;
  if GTokens.Kind <> tkString then
    Err(GTokens.Line, 'db expects a quoted DSN');
  GDsn := GTokens.Text_;
  NextToken;

  while GTokens.Kind <> tkEnd do
  begin
    if IsIdent('model') then
      ParseModel
    else if IsIdent('query') then
      ParseQuery
    else
      Err(GTokens.Line,
        Format('expected "model" or "query", found "%s"', [GTokens.Text_]));
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
  { The same translation Norn uses for code generation. The point of the
    spike is not how the schema is read, but when. }
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

{ " Did you mean X?" only when the guess is worth something. }
function IfThenText(const Guess: string): string;
begin
  if Guess = '' then
    Result := ''
  else
    Result := Format(' Did you mean "%s"?', [Guess]);
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
          [Table_, IfThenText(DidYouMean(Table_, Name))]));
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

function QuoteIdent_(const S: string): string;
begin
  if GDialect = sdMySql then
    Result := '`' + StringReplace(S, '`', '``', [rfReplaceAll]) + '`'
  else
    Result := '"' + StringReplace(S, '"', '""', [rfReplaceAll]) + '"';
end;

function Placeholder(N: Integer): string;
begin
  { The dialect is known at comptime, because the DSN is in the source.
    The Rún code never mentions it. }
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
      [T.Name, Col, IfThenText(DidYouMean(Col, Name))]));
  end;
  C := T.Column(Idx);
  Result := KindFromSql(C.SqlType, C.Scale);
end;

function ParamKind(const Q: TQueryDecl; const Name: string;
  Line: Integer): TRunKind;
var
  I: Integer;
  Candidates: TStringArray;
begin
  for I := 0 to High(Q.Params) do
    if Q.Params[I].Name = Name then
      Exit(Q.Params[I].Kind);
  SetLength(Candidates, Length(Q.Params));
  for I := 0 to High(Q.Params) do
    Candidates[I] := Q.Params[I].Name;
  Err(Line, Format('"%s" is neither a parameter nor a value.%s',
    [Name, IfThenText(DidYouMean(Name, Candidates))]));
  Result := rkText;
end;

{ The decisive check. The type on the left-hand side comes from the
  database, the type on the right from the source — and they have to match.
  This is what Pascal cannot do without either code generation or twenty-one
  overloads. }
procedure CheckComparison(T: TDbTable; const Q: TQueryDecl;
  const W: TCmp);
var
  Left_, Right_: TRunKind;
begin
  Left_ := ColumnKind(T, W.Col, W.Line);
  if W.IsParam then
    Right_ := ParamKind(Q, W.Operand, W.Line)
  else
    Right_ := W.LitKind;

  { int against money and float is fine — numbers are numbers. Anything
    else is not. }
  if Left_ = Right_ then
    Exit;
  if (Left_ in [rkInt, rkMoney, rkFloat]) and
     (Right_ in [rkInt, rkMoney, rkFloat]) then
    Exit;

  Err(W.Line, Format(
    '"%s" is %s in table %s, but is compared with %s. ' +
    'The schema was read from %s.',
    [W.Col, KindName(Left_), T.Name, KindName(Right_), GDsn]));
end;

{ Relations are derived from the foreign keys in the database. No
  declaration in the Rún source: if orders.customer_id points at
  customers.id, then Customer has a relation called "orders". That is the
  whole point of comptime — the schema knows this already, and then nobody
  should write it a second time. }
function RelationsFor(T: TDbTable): TRelationArray;
var
  I, J: Integer;
  Other: TDbTable;
  FK: TDbForeignKey;
  R: TRelation;
begin
  Result := nil;
  for I := 0 to GSchema.TableCount - 1 do
  begin
    Other := GSchema.TableAt(I);
    for J := 0 to Other.ForeignKeyCount - 1 do
    begin
      FK := Other.ForeignKey(J);
      if not SameText(FK.RefTable, T.Name) then
        Continue;
      R.Name := Other.Name;
      R.Table := Other.Name;
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
  Rels := RelationsFor(T);
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
      [T.Name, Name, IfThenText(DidYouMean(Name, Name_))]));
  Result.Name := '';
end;

{ The model name for a table, so that a relation can point at a row type
  that is actually written out. }
function ModelForTable(const Table: string): string;
var
  I: Integer;
begin
  for I := 0 to High(GModels) do
    if SameText(GModels[I].Table, Table) then
      Exit(GModels[I].Name);
  Result := '';
end;

{ The row types have to be written out in dependency order. A Customer
  record that has a field of type TOrderRowArray must come after TOrderRow,
  because Pascal does not allow a forward reference to a record. The
  relations point the opposite way from the foreign keys, so the order
  follows from the schema — and a cycle between two tables is a real
  limitation that has to be reported, not hidden. Depth first with the three
  usual marks. }
procedure SortModels(out Order_: TStringArray);
var
  Mark: array of Byte;   { 0 untouched, 1 in progress, 2 done }
  Ut: TStringArray;

  function IndexFor(const Name: string): Integer;
  var
    K: Integer;
  begin
    for K := 0 to High(GModels) do
      if GModels[K].Name = Name then
        Exit(K);
    Result := -1;
  end;

  procedure Visit(Idx: Integer);
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
      Rels := RelationsFor(T);
      for K := 0 to High(Rels) do
      begin
        RelModel := ModelForTable(Rels[K].Table);
        if RelModel = '' then
          Continue;
        D := IndexFor(RelModel);
        if (D >= 0) and (D <> Idx) then
          Visit(D);
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
    Visit(I);
  Order_ := Ut;
end;

{ Monomorphization. A generic query becomes one concrete query per model
  in the for list, with the type parameter substituted. This is the answer
  to Where<T> being impossible in Pascal: we write out the concrete variants
  instead of demanding them of the compiler. }
procedure Monomorphize;
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

function BindExpr(const Q: TQueryDecl; const W: TCmp): string;
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
    Result := Result + QuoteIdent_(T.Column(I).Name);
  end;
end;

function EmitQuery(var Ut: TStringList; const Q: TQueryDecl;
  Iface: Boolean): string;
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
  if Iface then
  begin
    Ut.Add(Result);
    Exit;
  end;

  Sql := 'SELECT ' + ColumnList(T) + ' FROM ' + QuoteIdent_(T.Name);

  PNo := 0;
  Bind := '';
  if Length(Q.Wheres) > 0 then
  begin
    Sql := Sql + ' WHERE ';
    for I := 0 to High(Q.Wheres) do
    begin
      CheckComparison(T, Q, Q.Wheres[I]);
      if I > 0 then Sql := Sql + ' AND ';
      Sql := Sql + QuoteIdent_(Q.Wheres[I].Col) + ' ';
      if Q.Wheres[I].HasOperand then
      begin
        Inc(PNo);
        Sql := Sql + SqlOp(Q.Wheres[I].Op) + ' ' + Placeholder(PNo);
        if Bind <> '' then Bind := Bind + ', ';
        Bind := Bind + BindExpr(Q, Q.Wheres[I]);
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
      Sql := Sql + QuoteIdent_(Q.Orders[I].Col);
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

  { Eager loading: one query per relation, not one per row. That is the
    difference between "with" and a loop, and the reason it is worth a
    keyword of its own. }
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
           QuoteIdent_(RT.Name) + ' WHERE ' + QuoteIdent_(Rel.ForeignKey) +
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
  Iface: Boolean);
var
  T: TDbTable;
  I: Integer;
  K: TRunKind;
  C: TDbColumn;
  Rels: TRelationArray;
  RelModel: string;
begin
  T := GSchema.Table(M.Table);
  Rels := RelationsFor(T);

  if Iface then
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

function ModelIndex(const Name: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(GModels) do
    if GModels[I].Name = Name then
      Exit(I);
  Result := 0;
end;

{ As a one-shot program global state did not matter — the process died
  after one translation. As a unit, Transpile is called once per .run file,
  and then everything has to be reset first. Without this the second file
  inherits the models from the first, and the error messages become
  meaningless. }
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
  { TToken has a string field. FillChar over it would have left a
    reference nobody releases. }
  GTokens.Text_ := '';
  GTokens.Line := 0;
  GTokens.Kind := tkEnd;
end;

function Transpile(const InFile, OutFile, UnitName: string): TRunStats;
var
  Source_: TStringList;
  Ut: TStringList;
  I: Integer;
  T0, TWasRead, TSchemaInfo, TEmit: Int64;
  Order_: TStringArray;
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

    { **Comptime.** The database is opened while the source is being
      translated, and the schema is read from there. None of this exists on
      disk afterwards. }
    GConn := OpenDbConnection(GDsn);
    GDialect := GConn.Dialect;
    GSchema := IntrospectSchema(GConn);
    TSchemaInfo := MonotonicMs - T0 - TWasRead;

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
    SortModels(Order_);
    for I := 0 to High(Order_) do
      EmitRowType(Ut, GModels[ModelIndex(Order_[I])], True);
    Monomorphize;
    for I := 0 to High(GConcrete) do
      EmitQuery(Ut, GConcrete[I], True);
    Ut.Add('');
    Ut.Add('implementation');
    Ut.Add('');
    for I := 0 to High(Order_) do
      EmitRowType(Ut, GModels[ModelIndex(Order_[I])], False);
    for I := 0 to High(GConcrete) do
      EmitQuery(Ut, GConcrete[I], False);
    Ut.Add('end.');

    ForceDirectories(ExtractFilePath(OutFile));
    Ut.SaveToFile(OutFile);
    TEmit := MonotonicMs - T0 - TWasRead - TSchemaInfo;

    Result.Models := Length(GModels);
    Result.Queries := Length(GConcrete);
    Result.Dialect := Copy(GDsn, 1, Pos(':', GDsn) - 1);
    Result.ParseMs := TWasRead;
    Result.SchemaMs := TSchemaInfo;
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
