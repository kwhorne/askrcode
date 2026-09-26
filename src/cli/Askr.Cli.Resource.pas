{ Askr.Cli.Resource — `askr make resource`: a table, as pages.

  From the plan Askr.Cli.Plan reads out of a live table, this writes the
  seven actions over it: a controller, its routes, four Inertia pages in
  Lauf, a model when there is none, and a test that drives every action
  through the router.

  WHAT IT IS BUILT ON

  The controller refers to the typed columns `askr schema` writes --
  `Customers.Name`, not 'name' -- so a column that goes away later is a
  compile error in the controller, not a 500 on the page. That is the
  whole reason to generate Pascal rather than to interpret a table at run
  time, and it is why this command writes the schema units first.

  WHAT IT WILL NOT DO

  It never writes over a file that is there. A generated file is yours
  the moment it exists; regenerating it would take back what you did to
  it. A model that exists is used as it is, not rewritten.

  It edits app.lpr only at the markers `askr new` left, and says what to
  add when they are gone -- the same rule as `make auth`.

  The Svelte pages are not typed against anything. A column renamed later
  breaks the controller at compile time and leaves the pages showing a
  blank cell. That is the one place the chain is not closed, and the
  generated pages say so at the top.

  The routes are one procedure in the controller unit, called by app.lpr
  and by the test. Two lists of the same seven routes would be two lists. }
unit Askr.Cli.Resource;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes,
  Askr.Norn.Introspect, Askr.Norn.Codegen,
  Askr.Cli.Fields, Askr.Cli.Plan;

type
  { A table this one points at, as a form needs it: a select of its rows,
    labelled by one of its columns. }
  TParentInfo = record
    Rel: TPlanRelation;
    { The parent's model file is there. Without it the field is a number,
      because a select needs something to query the options with. }
    Available: Boolean;
    LabelColumn: string;
    LabelMember: string;
    SchemaVar: string;
    SchemaUnit: string;
    Plan: TResourcePlan;
  end;
  TParentInfos = array of TParentInfo;

  { A table that points at this one, as its page shows it: the rows that
    point here, labelled by one of their columns. }
  TChildInfo = record
    Rel: TPlanRelation;
    { The child's model file is there, so there is something to query
      them with. Without it the page does not list them. }
    Available: Boolean;
    LabelColumn: string;
    LabelMember: string;
    FkMember: string;
    SchemaVar: string;
    SchemaUnit: string;
    { The child's own pages are there, so a row can link to its page. }
    Linked: Boolean;
    Url: string;
  end;
  TChildInfos = array of TChildInfo;

  { A table this one is related to through a pivot, as a form needs it:
    a box to tick for each of its rows, labelled by one of its columns. }
  TManyInfo = record
    Rel: TPlanRelation;
    { The boxes are on the form. False when the other table has no model
      to query its rows with, when the model here does not declare the
      relation, or when declaring it would make two units use each other
      -- and then Why says which, and what to do. }
    Available: Boolean;
    Why: string;
    LabelColumn: string;
    LabelMember: string;
    SchemaVar: string;
    SchemaUnit: string;
    { The other table's own pages are there, so a row can link to them. }
    Linked: Boolean;
    Url: string;
    { The line Describe needs: short when the pivot and its keys are the
      ones BelongsToMany would guess, with every name otherwise. }
    DescribeLine: string;
    Plan: TResourcePlan;
  end;
  TManyInfos = array of TManyInfo;

  TGenFile = record
    Path: string;       { relative to the project root }
    Content: string;
  end;
  TGenFiles = array of TGenFile;

  { The names everything is written under, from the model and its table. }
  TResourceNames = record
    Model: string;       { Gadget }
    Plural: string;      { Gadgets }
    Url: string;         { /gadgets }
    Prop: string;        { gadget -- the Inertia prop and the JS variable }
    Human: string;       { gadget }
    HumanPlural: string; { gadgets }
    CtlUnit: string;     { App.Http.GadgetsController }
    CtlClass: string;    { TGadgetsController }
    RoutesProc: string;  { GadgetsRoutes }
    SchemaVar: string;   { Gadgets }
    SchemaUnit: string;  { App.Schema.Gadgets }
    ModelUnit: string;   { App.Models.Gadget }
    PagesDir: string;    { Gadgets }
    TestUnit: string;    { App.Tests.Gadgets }
    TestsProc: string;   { GadgetsTests }
    { The same, for --api. }
    ApiUrl: string;          { /api/gadgets }
    ApiCtlUnit: string;      { App.Http.GadgetsApiController }
    ApiCtlClass: string;     { TGadgetsApiController }
    ApiRoutesProc: string;   { GadgetsApiRoutes }
    ApiDocProc: string;      { GadgetsApiDoc }
    ApiTestUnit: string;     { App.Tests.GadgetsApi }
    ApiTestsProc: string;    { GadgetsApiTests }
    ScopeRead: string;       { gadgets:read }
    ScopeWrite: string;      { gadgets:write }
  end;

function ResourceNamesOf(const P: TResourcePlan): TResourceNames;

{ Every file a resource is, from its plan. Writes nothing, so a test can
  hold the text. WithModel adds the model unit, Web the controller, pages
  and test for a browser, Api the JSON controller and its test. }
function ResourceFiles(const P: TResourcePlan; const Parents: TParentInfos;
  const Children: TChildInfos; const Manys: TManyInfos;
  WithModel, Web, Api: Boolean): TGenFiles;

{ The tables that point at P, as its page lists them: those whose model is
  in Root, linked when their pages are there too. }
function ChildrenOf(Schema: TDbSchema; const P: TResourcePlan;
  const Root: string): TChildInfos;

{ The tables P points at, as its form needs them: a select for each
  whose model is in Root, a number for the rest. }
function ParentsOf(Schema: TDbSchema; const P: TResourcePlan;
  const Root: string): TParentInfos;

{ The tables P is related to through a pivot, as its form needs them: a
  box for each of their rows, where the other table has a model and the
  model here declares the relation -- or is being written now, and then
  it will. OwnerModelWritten says which. }
function ManysOf(Schema: TDbSchema; const P: TResourcePlan;
  const Root: string; OwnerModelWritten: Boolean): TManyInfos;

{ A database default as a JavaScript value a form can start with, or ''
  when it is not a plain literal. Exposed for the test: the three
  databases report the same default three ways. }
function DefaultLiteral(const PC: TPlanColumn): string;

{ The whole command: plan the table, refuse what cannot be one, write the
  schema units and the files, and put the routes and the tests in place.
  Prints what it did. Returns False when it refused, having said why. }
function MakeResource(const Root: string; Schema: TDbSchema;
  const ModelName, Table, Title: string; Force, Web, Api: Boolean): Boolean;

implementation

uses
  Math, Askr.Urd.Model, Askr.Cli.Scaffold;

{ ------------------------------------------------------------ names -- }

procedure Say(var A: TStringArray; const S: string);
begin
  SetLength(A, Length(A) + 1);
  A[High(A)] := S;
end;

{ seen_at -> Seen at. What a person reads over a field. }
function LabelOf(const Column: string): string;
begin
  Result := StringReplace(Column, '_', ' ', [rfReplaceAll]);
  if Result <> '' then
    Result[1] := UpCase(Result[1]);
end;

{ The label for a reference: maker_id -> Maker. }
function RefLabelOf(const Column: string): string;
begin
  Result := Column;
  if Copy(Result, Length(Result) - 2, 3) = '_id' then
    Result := Copy(Result, 1, Length(Result) - 3);
  Result := LabelOf(Result);
end;

function ResourceNamesOf(const P: TResourcePlan): TResourceNames;
begin
  Result.Model := P.Model;
  Result.Plural := PascalCase(P.Table);
  Result.Url := '/' + StringReplace(P.Table, '_', '-', [rfReplaceAll]);
  Result.Prop := SnakeCase(P.Model);
  Result.Human := StringReplace(SnakeCase(P.Model), '_', ' ', [rfReplaceAll]);
  Result.HumanPlural := StringReplace(P.Table, '_', ' ', [rfReplaceAll]);
  Result.CtlUnit := 'App.Http.' + Result.Plural + 'Controller';
  Result.CtlClass := 'T' + Result.Plural + 'Controller';
  Result.RoutesProc := Result.Plural + 'Routes';
  Result.SchemaVar := TableConstName(P.Table);
  Result.SchemaUnit := 'App.Schema.' + PascalCase(P.Table);
  Result.ModelUnit := 'App.Models.' + P.Model;
  Result.PagesDir := Result.Plural;
  Result.TestUnit := 'App.Tests.' + Result.Plural;
  Result.TestsProc := Result.Plural + 'Tests';
  Result.ApiUrl := '/api' + Result.Url;
  Result.ApiCtlUnit := 'App.Http.' + Result.Plural + 'ApiController';
  Result.ApiCtlClass := 'T' + Result.Plural + 'ApiController';
  Result.ApiRoutesProc := Result.Plural + 'ApiRoutes';
  Result.ApiDocProc := Result.Plural + 'ApiDoc';
  Result.ApiTestUnit := 'App.Tests.' + Result.Plural + 'Api';
  Result.ApiTestsProc := Result.Plural + 'ApiTests';
  Result.ScopeRead := P.Table + ':read';
  Result.ScopeWrite := P.Table + ':write';
end;

function AOrAn(const Human: string): string;
begin
  if (Human <> '') and (Pos(LowerCase(Human[1]), 'aeiou') > 0) then
    Result := 'an ' + Human
  else
    Result := 'a ' + Human;
end;

function Capital(const S: string): string;
begin
  Result := S;
  if Result <> '' then
    Result[1] := UpCase(Result[1]);
end;

{ A JavaScript string literal. The labels are made of column names, but a
  default comes from the database and can hold anything. }
function JsStr(const S: string): string;
var
  I: Integer;
begin
  Result := '''';
  for I := 1 to Length(S) do
    case S[I] of
      '''': Result := Result + '\''';
      '\': Result := Result + '\\';
      #10: Result := Result + '\n';
      #13: Result := Result + '\r';
      '<': Result := Result + '\x3c';
    else
      Result := Result + S[I];
    end;
  Result := Result + '''';
end;

{ A Pascal string literal. }
function PasStr(const S: string): string;
begin
  Result := '''' + StringReplace(S, '''', '''''', [rfReplaceAll]) + '''';
end;

{ The columns a form has, in table order. }
function EditableOf(const P: TResourcePlan): TPlanColumns;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to High(P.Columns) do
    if P.Columns[I].Editable then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := P.Columns[I];
    end;
end;

function ParentFor(const Parents: TParentInfos; const Column: string;
  out Info: TParentInfo): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(Parents) do
    if Parents[I].Rel.ForeignKey = Column then
    begin
      Info := Parents[I];
      Exit(True);
    end;
  Result := False;
end;

{ The first editable string column: what a list links from, and what a
  test changes to see an update land. '' when there is none. }
function FirstStringOf(const P: TResourcePlan): string;
var
  I: Integer;
begin
  for I := 0 to High(P.Columns) do
    if P.Columns[I].Editable and (P.Columns[I].Field.Kind = ftString) then
      Exit(P.Columns[I].Field.Column);
  Result := '';
end;

{ A database default as a JavaScript value the form can start with, or
  '' when it is not a plain literal. Postgres reports 'new'::character
  varying, MySQL new, SQLite 'new'; a function call -- now(), nextval --
  is not something a form can show, and is left to the database. }
function DefaultLiteral(const PC: TPlanColumn): string;
var
  E, L: string;
  P: Integer;
begin
  Result := '';
  E := Trim(PC.DefaultExpr);
  if E = '' then
    Exit;
  P := Pos('::', E);
  if P > 0 then
    E := Trim(Copy(E, 1, P - 1));
  L := LowerCase(E);
  if (Pos('(', E) > 0) or (L = 'null') or (Pos('current_', L) = 1) then
    Exit;
  if PC.Field.Kind = ftBool then
  begin
    if (L = 'true') or (L = '1') or (L = '''1''') or (L = '''t''') then
      Exit('true');
    if (L = 'false') or (L = '0') or (L = '''0''') or (L = '''f''') then
      Exit('false');
    Exit;
  end;
  if (Length(E) >= 2) and (E[1] = '''') and (E[Length(E)] = '''') then
    E := StringReplace(Copy(E, 2, Length(E) - 2), '''''', '''', [rfReplaceAll])
  else if not (PC.Field.Kind in [ftString, ftText, ftUuid]) then
  begin
    { A number, which is written as it is -- and nothing else is. }
    if StrToFloatDef(StringReplace(E, '.', DefaultFormatSettings.DecimalSeparator,
         []), -1.5e300) = -1.5e300 then
      Exit;
    Exit(E);
  end;
  if PC.Field.Kind in [ftInt, ftBigInt, ftMoney, ftFloat] then
    Exit(E);
  Result := JsStr(E);
end;

{ The line a model's Describe needs for Rel. The short form when the
  pivot and both keys are what BelongsToMany works out from the two class
  names; every name when they are not, since a guess that differs from
  the table is a relation to nothing. }
function ManyDescribeLine(const P: TResourcePlan; const Rel: TPlanRelation): string;
var
  Mine, Theirs, Conv: string;
begin
  Mine := SnakeCase(P.Model);
  Theirs := SnakeCase(Rel.Model);
  if Mine < Theirs then
    Conv := Mine + '_' + Theirs
  else
    Conv := Theirs + '_' + Mine;
  if (Rel.Pivot = Conv) and (Rel.ForeignKey = Mine + '_id') and
     (Rel.RelatedKey = Theirs + '_id') then
    Result := 'S.BelongsToMany(' + PasStr(Rel.Name) + ', T' + Rel.Model + ');'
  else
    Result := 'S.BelongsToMany(' + PasStr(Rel.Name) + ', T' + Rel.Model + ', ' +
      PasStr(Rel.Pivot) + ', ' + PasStr(Rel.ForeignKey) + ', ' +
      PasStr(Rel.RelatedKey) + ');';
end;

function FileText(const Path_: string): string;
var
  L: TStringList;
begin
  Result := '';
  if not FileExists(Path_) then
    Exit;
  L := TStringList.Create;
  try
    L.LoadFromFile(Path_);
    Result := L.Text;
  finally
    L.Free;
  end;
end;

function ManysOf(Schema: TDbSchema; const P: TResourcePlan;
  const Root: string; OwnerModelWritten: Boolean): TManyInfos;
var
  I, K: Integer;
  Base, Theirs, Mine: string;
  Lines: TStringArray;
begin
  Base := IncludeTrailingPathDelimiter(Root);
  Result := nil;
  Mine := FileText(Base + 'app/Models/App.Models.' + P.Model + '.pas');
  for I := 0 to High(P.Relations) do
    if P.Relations[I].Kind = prBelongsToMany then
    begin
      SetLength(Result, Length(Result) + 1);
      with Result[High(Result)] do
      begin
        Rel := P.Relations[I];
        Plan := PlanResource(Schema, Rel.Model, Rel.Table);
        DescribeLine := ManyDescribeLine(P, Rel);
        LabelColumn := Plan.DefaultSort;
        LabelMember := '';
        K := PlanColumnIndex(Plan, LabelColumn);
        if K >= 0 then
          LabelMember := Plan.Columns[K].Member;
        SchemaVar := TableConstName(Rel.Table);
        SchemaUnit := 'App.Schema.' + PascalCase(Rel.Table);
        Linked := FileExists(Base + 'app/Http/App.Http.' + PascalCase(Rel.Table) +
          'Controller.pas');
        Url := '/' + StringReplace(Rel.Table, '_', '-', [rfReplaceAll]);
        Theirs := FileText(Base + 'app/Models/App.Models.' + Rel.Model + '.pas');
        Why := '';
        if (Length(Plan.Problems) > 0) or (Theirs = '') then
          Why := Format('%s are left off the form: there is no model for them to ' +
            'query. Make one -- askr make resource %s -- and run this again ' +
            'with --force.', [Rel.Table, Rel.Model])
        else if LabelMember = '' then
          Why := Format('%s are left off the form: nothing in the table can ' +
            'label a box.', [Rel.Table])
        { Two units cannot use each other, and the relation needs this
          model to use the other one for its list type. Asked before the
          lines to add, which would otherwise tell someone to write that
          very cycle. }
        else if Pos('App.Models.' + P.Model + ';', Theirs) +
                Pos('App.Models.' + P.Model + ',', Theirs) > 0 then
          Why := Format('%s are left off the form: App.Models.%s uses ' +
            'App.Models.%s already, and two units cannot use each other. ' +
            'Keep the relation on that side, or put the two models in one ' +
            'unit.', [Rel.Table, Rel.Model, P.Model])
        else if OwnerModelWritten then
          { The model written here declares it. }
        else if (Pos('BelongsToMany(' + PasStr(Rel.Name), Mine) = 0) or
                (Pos(Rel.Name + ':', Mine) = 0) then
        begin
          Why := Format('%s are left off the form: App.Models.%s is there ' +
            'without the relation. Add these, then run this again with --force:',
            [Rel.Table, P.Model]);
          Lines := ManyToManyModelLines(P.Model, Rel.Model, Rel.Name, DescribeLine);
          for K := 0 to High(Lines) do
            Why := Why + LineEnding + Lines[K];
        end;
        Available := Why = '';
      end;
    end;
end;

{ The Pascal list the relations go in: ['Tags', 'Labels']. '' with none. }
function PreloadListOf(const Manys: TManyInfos): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Manys) do
    if Manys[I].Available then
    begin
      if Result <> '' then
        Result := Result + ', ';
      Result := Result + PasStr(Manys[I].Rel.Name);
    end;
  if Result <> '' then
    Result := '[' + Result + ']';
end;

{ The prop the choices go under: tags_choices. Not the table's name, which
  a select for a BelongsTo to the same table would use. }
function ChoicesProp(const M: TManyInfo): string;
begin
  Result := SnakeCase(M.Rel.Name) + '_choices';
end;

{ The locals a Store or an Update needs for the relations it saves. }
function ManyVarsText(const Manys: TManyInfos): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Manys) do
    if Manys[I].Available then
      Result := Result + '  ' + Manys[I].Rel.Name + 'Ids: TArray<Int64>;' + #10 +
        '  Has' + Manys[I].Rel.Name + ': Boolean;' + #10;
  if Result <> '' then
    Result := '  C: TDbConnection;' + #10 + Result;
end;

{ Validate, then the ids, then the row and its relations in one
  transaction. Fail is what a refusal answers with. Both controllers
  write it from here, so the web and the API cannot check differently. }
function ManySaveText(const Manys: TManyInfos; const Fail: string): string;
var
  I: Integer;
  M: TManyInfo;
  Col: string;
begin
  Result := '  M.Validate;' + #10;
  for I := 0 to High(Manys) do
    if Manys[I].Available then
    begin
      M := Manys[I];
      Col := '';
      if M.Plan.PrimaryKey <> 'id' then
        Col := ', ' + PasStr(M.Plan.PrimaryKey);
      Result := Result +
        '  Has' + M.Rel.Name + ' := Req.InputIds(' + PasStr(M.Rel.InputKey) + ', ' +
          M.Rel.Name + 'Ids, M.Errors);' + #10 +
        '  if Has' + M.Rel.Name + ' then' + #10 +
        '    IdsExist(M.Errors, ' + PasStr(M.Rel.InputKey) + ', ' + PasStr(M.Rel.Table) +
          ', ' + M.Rel.Name + 'Ids' + Col + ');' + #10;
    end;
  Result := Result +
    '  if not M.Errors.IsEmpty then' + #10 +
    '    Exit(' + Fail + ');' + #10 +
    '  { The row and what it is related to, together: an id the database' + #10 +
    '    refuses after all does not leave a row without them. A key the' + #10 +
    '    request did not send is left as it is. }' + #10 +
    '  C := CurrentDb;' + #10 +
    '  C.StartTransaction;' + #10 +
    '  try' + #10 +
    '    M.Save;' + #10;
  for I := 0 to High(Manys) do
    if Manys[I].Available then
      Result := Result +
        '    if Has' + Manys[I].Rel.Name + ' then' + #10 +
        '      M.Sync(' + PasStr(Manys[I].Rel.Name) + ', ' + Manys[I].Rel.Name + 'Ids);' + #10;
  Result := Result +
    '    C.Commit;' + #10 +
    '  except' + #10 +
    '    C.Rollback;' + #10 +
    '    raise;' + #10 +
    '  end;';
end;

{ ------------------------------------------------------- controller -- }

{ The procedure both controllers fill a model with. One emitter, so the
  web and the API controller cannot be written with different lists. }
function FillText(const P: TResourcePlan): string;
var
  N: TResourceNames;
  Ed: TPlanColumns;
  I: Integer;
  Only: string;
begin
  N := ResourceNamesOf(P);
  Ed := EditableOf(P);
  { The columns a request may set. Everything else a client adds to the
    body is ignored: the one-argument FillInto fills whatever the model
    maps and does not set itself -- a hidden column included. }
  Only := '';
  for I := 0 to High(Ed) do
  begin
    if Only <> '' then
      Only := Only + ',' + #10 + '    ';
    Only := Only + N.SchemaVar + '.' + Ed[I].Member + '.Name';
  end;
  Result :=
    '{ The columns the form has, and the only ones a request may set. The' + #10 +
    '  one-argument FillInto fills any column the model maps and does not' + #10 +
    '  set itself, so a client could set one the form does not have. }' + #10 +
    'procedure Fill(Req: TRequest; M: T' + N.Model + ');' + #10 +
    'begin' + #10;
  if Only = '' then
    Result := Result + '  { The table has no column a form can set. }' + #10
  else
    Result := Result + '  Req.FillInto(M, [' + Only + ']);' + #10;
  Result := Result + 'end;' + #10;
end;

{ The Index body both controllers share: the grid, its allowlist, its
  search. Returns the lines up to and including PerPage. }
function GridText(const P: TResourcePlan): string;
var
  N: TResourceNames;
  I: Integer;
  PC: TPlanColumn;
  Cols: string;
begin
  N := ResourceNamesOf(P);
  Result := '  G := TGrid<T' + N.Model + '>.New;' + #10 + '  G.Read(Req);' + #10;
  for I := 0 to High(P.Columns) do
  begin
    PC := P.Columns[I];
    if PC.Sortable and PC.Listed then
      Result := Result + '  G.Sortable(''' + PC.Field.Column + ''', ' +
        N.SchemaVar + '.' + PC.Member + ');' + #10;
  end;
  Cols := '';
  for I := 0 to High(P.Columns) do
    if P.Columns[I].Searchable then
    begin
      if Cols <> '' then
        Cols := Cols + ', ';
      Cols := Cols + N.SchemaVar + '.' + P.Columns[I].Member;
    end;
  if Cols <> '' then
    Result := Result + '  G.Searchable([' + Cols + ']);' + #10;
  Result := Result + '  G.DefaultSort(''' + P.DefaultSort + ''');' + #10 +
    '  G.PerPage(25, 200);';
end;

function ControllerText(const P: TResourcePlan;
  const Parents: TParentInfos; const Children: TChildInfos;
  const Manys: TManyInfos): string;
var
  B: TStringList;
  N: TResourceNames;
  I: Integer;
  Uses_, Opt: string;
  Par: TParentInfo;

  procedure A(const S: string);
  begin
    B.Add(S);
  end;

  { The props every form page needs besides the row: the options of each
    select. }
  function OptionProps: string;
  var
    K: Integer;
  begin
    Result := '';
    for K := 0 to High(Parents) do
      if Parents[K].Available then
        Result := Result + ', ' + PasStr(Parents[K].Rel.Table) + ', ' +
          Parents[K].Rel.Model + 'Options';
    for K := 0 to High(Manys) do
      if Manys[K].Available then
        Result := Result + ', ' + PasStr(ChoicesProp(Manys[K])) + ', ' +
          Manys[K].Rel.Name + 'Choices';
  end;

  { What an edit form ticks: the ids in each pivot. }
  function IdsProps: string;
  var
    K: Integer;
  begin
    Result := '';
    for K := 0 to High(Manys) do
      if Manys[K].Available then
        Result := Result + ',' + #10 + '     ' + PasStr(Manys[K].Rel.InputKey) +
          ', JsonIds(M.RelatedIds(' + PasStr(Manys[K].Rel.Name) + '))';
  end;

begin
  N := ResourceNamesOf(P);
  B := TStringList.Create;
  try
    Uses_ := '  ' + N.ModelUnit + ', ' + N.SchemaUnit;
    for I := 0 to High(Parents) do
      if Parents[I].Available then
        Uses_ := Uses_ + ',' + #10 + '  App.Models.' + Parents[I].Rel.Model +
          ', ' + Parents[I].SchemaUnit;
    for I := 0 to High(Children) do
      if Children[I].Available and
         (Pos('App.Models.' + Children[I].Rel.Model + ',', Uses_ + ',') = 0) then
        Uses_ := Uses_ + ',' + #10 + '  App.Models.' + Children[I].Rel.Model +
          ', ' + Children[I].SchemaUnit;
    for I := 0 to High(Manys) do
      if Manys[I].Available and
         (Pos('App.Models.' + Manys[I].Rel.Model + ',', Uses_ + ',') = 0) then
        Uses_ := Uses_ + ',' + #10 + '  App.Models.' + Manys[I].Rel.Model +
          ', ' + Manys[I].SchemaUnit;

    A('{ ' + Capital(N.HumanPlural) + ': the seven actions over the ' +
      P.Table + ' table.');
    A('');
    A('  Written by askr make resource from the table as it was. It is yours');
    A('  now: nothing regenerates it, and askr make will not write over it.');
    A('');
    A('  The columns are the typed ones from askr schema, so a column that');
    A('  goes away is a compile error here instead of a 500 on the page. The');
    A('  Svelte pages under frontend/src/pages/' + N.PagesDir + ' are not typed');
    A('  against anything, and are the one place a rename will not be caught. }');
    A('unit ' + N.CtlUnit + ';');
    A('');
    A('{$mode Delphi}{$H+}');
    A('');
    A('interface');
    A('');
    A('uses');
    A('  SysUtils,');
    A('  Askr.Http.Request, Askr.Http.Response, Askr.Http.Router,');
    A('  Askr.Inertia, Askr.Session,');
    A('  Askr.Urd.Model, Askr.Urd.Query, Askr.Urd.Grid, Askr.Urd.Bind,');
    if PreloadListOf(Manys) <> '' then
      A('  Askr.Urd.Driver, Askr.Urd.Json,');
    A(Uses_ + ';');
    A('');
    A('type');
    A('  { Add, not Create, and Remove, not Destroy: those two are TObject''s');
    A('    constructor and destructor, and a method with either name hides it. }');
    A('  ' + N.CtlClass + ' = class');
    A('  public');
    A('    function Index(Req: TRequest): TResponse;');
    A('    function Show(Req: TRequest): TResponse;');
    A('    function Add(Req: TRequest): TResponse;');
    A('    function Store(Req: TRequest): TResponse;');
    A('    function Edit(Req: TRequest): TResponse;');
    A('    function Update(Req: TRequest): TResponse;');
    A('    function Remove(Req: TRequest): TResponse;');
    A('  end;');
    A('');
    A('{ Every route of this resource. app.lpr calls it, and so does the test,');
    A('  so the two cannot list different routes. }');
    A('procedure ' + N.RoutesProc + '(R: TRouter);');
    A('');
    A('implementation');
    A('');
    A('var');
    A('  Ctl: ' + N.CtlClass + ';');
    A('');
    A('procedure ' + N.RoutesProc + '(R: TRouter);');
    A('begin');
    A('  if Ctl = nil then');
    A('    Ctl := ' + N.CtlClass + '.Create;');
    A('  R.Get(''' + N.Url + ''', Ctl.Index);');
    A('  R.Get(''' + N.Url + '/new'', Ctl.Add);');
    A('  R.Post(''' + N.Url + ''', Ctl.Store);');
    A('  R.Get(''' + N.Url + '/:id'', Ctl.Show);');
    A('  R.Get(''' + N.Url + '/:id/edit'', Ctl.Edit);');
    A('  R.Put(''' + N.Url + '/:id'', Ctl.Update);');
    A('  R.Delete(''' + N.Url + '/:id'', Ctl.Remove);');
    A('end;');
    A('');
    A('{ The row the path names, or nil. A path that is not a number is a row');
    A('  that is not there, not an error. }');
    A('function Find(Req: TRequest): T' + N.Model + ';');
    A('begin');
    A('  Result := TQuery<T' + N.Model + '>.New.Find(Req.Param(''id'').ToIntDef(0));');
    A('end;');
    A('');

    if PreloadListOf(Manys) <> '' then
    begin
      A('{ The same, with the rows it belongs to many of: for the page that');
      A('  shows them. }');
      A('function FindLoaded(Req: TRequest): T' + N.Model + ';');
      A('begin');
      A('  Result := TQuery<T' + N.Model + '>.New.Preload(' + PreloadListOf(Manys) + ')');
      A('    .Find(Req.Param(''id'').ToIntDef(0));');
      A('end;');
      A('');
    end;

    B.Add(FillText(P));

    for I := 0 to High(Manys) do
      if Manys[I].Available then
      begin
        A('{ The boxes for ' + Manys[I].Rel.InputKey + ', one per row. More than a thousand');
        A('  boxes is the wrong control, and this stops there rather than');
        A('  sending the whole table. }');
        A('function ' + Manys[I].Rel.Name + 'Choices: TModelList<T' + Manys[I].Rel.Model + '>;');
        A('begin');
        A('  Result := TQuery<T' + Manys[I].Rel.Model + '>.New');
        A('    .OrderBy(' + Manys[I].SchemaVar + '.' + Manys[I].LabelMember + ')');
        A('    .Limit(1000)');
        A('    .Get;');
        A('end;');
        A('');
      end;

    for I := 0 to High(Parents) do
      if Parents[I].Available then
      begin
        Par := Parents[I];
        Opt := Par.Rel.Model + 'Options';
        A('{ The choices for ' + Par.Rel.ForeignKey + '. A select with more than a thousand');
        A('  options is the wrong control, and this stops there rather than');
        A('  sending the whole table. }');
        A('function ' + Opt + ': TModelList<T' + Par.Rel.Model + '>;');
        A('begin');
        A('  Result := TQuery<T' + Par.Rel.Model + '>.New');
        A('    .OrderBy(' + Par.SchemaVar + '.' + Par.LabelMember + ')');
        A('    .Limit(1000)');
        A('    .Get;');
        A('end;');
        A('');
      end;

    for I := 0 to High(Children) do
      if Children[I].Available then
      begin
        A('const');
        A('  { How many rows of a table that points here the page lists. The page');
        A('    says when there are this many, rather than fetching them all. }');
        A('  Listed = 50;');
        A('');
        Break;
      end;

    A('function NotFound: TResponse;');
    A('begin');
    A('  Result := Respond(404).WithBody(''No such ' + N.Human + '.'');');
    A('end;');
    A('');
    A('procedure Flash(const Message_: string);');
    A('begin');
    A('  { Without sessions there is nowhere to keep it across the redirect. }');
    A('  if CurrentSession <> nil then');
    A('    CurrentSession.Flash(''success'', Message_);');
    A('end;');
    A('');

    { ---- Index ---- }
    A('{ Sorted, searched and paged in the database. Sortable is the allowlist:');
    A('  a key that is not named here has nothing to sort by. }');
    A('function ' + N.CtlClass + '.Index(Req: TRequest): TResponse;');
    A('var');
    A('  G: TGrid<T' + N.Model + '>;');
    A('begin');
    A(GridText(P));
    A('  Result := Inertia(''' + N.PagesDir + '/Index'',');
    A('    [''rows'', G.Rows(TQuery<T' + N.Model + '>.New), ''grid'', G]);');
    A('end;');
    A('');

    { ---- Show ---- }
    A('function ' + N.CtlClass + '.Show(Req: TRequest): TResponse;');
    A('var');
    A('  M: T' + N.Model + ';');
    A('begin');
    if PreloadListOf(Manys) <> '' then
      A('  M := FindLoaded(Req);')
    else
      A('  M := Find(Req);');
    A('  if M = nil then');
    A('    Exit(NotFound);');
    Opt := '';
    for I := 0 to High(Parents) do
      if Parents[I].Available then
        Opt := Opt + ',' + #10 + '     ' + PasStr(SnakeCase(Parents[I].Rel.Name)) +
          ', TQuery<T' + Parents[I].Rel.Model + '>.New.Find(M.' +
          P.Columns[PlanColumnIndex(P, Parents[I].Rel.ForeignKey)].Field.Prop + ')';
    for I := 0 to High(Children) do
      if Children[I].Available then
        Opt := Opt + ',' + #10 + '     ' + PasStr(SnakeCase(Children[I].Rel.Name)) +
          ', TQuery<T' + Children[I].Rel.Model + '>.New' + #10 +
          '       .Where(' + Children[I].SchemaVar + '.' + Children[I].FkMember +
          ', Eq, M.Id)' + #10 +
          '       .OrderBy(' + Children[I].SchemaVar + '.' + Children[I].LabelMember + ')' + #10 +
          '       .Limit(Listed).Get';
    if Pos('Limit(Listed)', Opt) > 0 then
      Opt := Opt + ',' + #10 + '     ''listed'', Listed';
    A('  Result := Inertia(''' + N.PagesDir + '/Show'', [''' + N.Prop + ''', M' +
      Opt + ']);');
    A('end;');
    A('');

    { ---- Add ---- }
    A('function ' + N.CtlClass + '.Add(Req: TRequest): TResponse;');
    A('begin');
    if OptionProps = '' then
      A('  Result := Inertia(''' + N.PagesDir + '/Add'', []);')
    else
      A('  Result := Inertia(''' + N.PagesDir + '/Add'', [' +
        Copy(OptionProps, 3, MaxInt) + ']);');
    A('end;');
    A('');

    { ---- Store ---- }
    A('function ' + N.CtlClass + '.Store(Req: TRequest): TResponse;');
    A('var');
    A('  M: T' + N.Model + ';');
    if ManyVarsText(Manys) <> '' then
      A(TrimRight(ManyVarsText(Manys)));
    A('begin');
    A('  M := T' + N.Model + '.Create;');
    A('  Fill(Req, M);');
    if ManyVarsText(Manys) <> '' then
      A(ManySaveText(Manys, 'BackWithErrors(M.Errors, ''' + N.Url + '/new'')'))
    else
    begin
      A('  if not M.Validate then');
      A('    Exit(BackWithErrors(M.Errors, ''' + N.Url + '/new''));');
      A('  M.Save;');
    end;
    A('  Flash(''' + Capital(N.Human) + ' created.'');');
    A('  Result := InertiaRedirect(''' + N.Url + '/'' + IntToStr(M.Id));');
    A('end;');
    A('');

    { ---- Edit ---- }
    A('function ' + N.CtlClass + '.Edit(Req: TRequest): TResponse;');
    A('var');
    A('  M: T' + N.Model + ';');
    A('begin');
    A('  M := Find(Req);');
    A('  if M = nil then');
    A('    Exit(NotFound);');
    A('  Result := Inertia(''' + N.PagesDir + '/Edit'', [''' + N.Prop + ''', M' +
      OptionProps + IdsProps + ']);');
    A('end;');
    A('');

    { ---- Update ---- }
    A('function ' + N.CtlClass + '.Update(Req: TRequest): TResponse;');
    A('var');
    A('  M: T' + N.Model + ';');
    if ManyVarsText(Manys) <> '' then
      A(TrimRight(ManyVarsText(Manys)));
    A('begin');
    A('  M := Find(Req);');
    A('  if M = nil then');
    A('    Exit(NotFound);');
    A('  Fill(Req, M);');
    if ManyVarsText(Manys) <> '' then
      A(ManySaveText(Manys, 'BackWithErrors(M.Errors, ''' + N.Url + '/'' + IntToStr(M.Id) + ''/edit'')'))
    else
    begin
      A('  if not M.Validate then');
      A('    Exit(BackWithErrors(M.Errors, ''' + N.Url + '/'' + IntToStr(M.Id) + ''/edit''));');
      A('  M.Save;');
    end;
    A('  Flash(''' + Capital(N.Human) + ' saved.'');');
    A('  Result := InertiaRedirect(''' + N.Url + '/'' + IntToStr(M.Id));');
    A('end;');
    A('');

    { ---- Remove ---- }
    A('function ' + N.CtlClass + '.Remove(Req: TRequest): TResponse;');
    A('var');
    A('  M: T' + N.Model + ';');
    A('begin');
    A('  M := Find(Req);');
    A('  if M = nil then');
    A('    Exit(NotFound);');
    if P.HasSoftDeletes then
      A('  { Soft: the model has SoftDeletes, so this sets deleted_at. }');
    A('  M.Delete;');
    A('  Flash(''' + Capital(N.Human) + ' deleted.'');');
    A('  Result := InertiaRedirect(''' + N.Url + ''');');
    A('end;');
    A('');
    A('finalization');
    A('  Ctl.Free;');
    A('');
    A('end.');
    Result := B.Text;
  finally
    B.Free;
  end;
end;


{ The same seven, less the two that are pages, as JSON for a program:
  the list envelope, problem documents, a scope per verb, and the lines
  that describe it to the OpenAPI document next to the routes they
  describe. }
function ApiControllerText(const P: TResourcePlan; const Manys: TManyInfos): string;
var
  B: TStringList;
  N: TResourceNames;
  I: Integer;
  Uses_, Loaded: string;

  procedure A(const S: string);
  begin
    B.Add(S);
  end;

  procedure Head(const Name_, Scope: string; const Vars: string = '');
  begin
    A('function ' + N.ApiCtlClass + '.' + Name_ + '(Req: TRequest): TResponse;');
    A('var');
    A('  M: T' + N.Model + ';');
    if Vars <> '' then
      A(TrimRight(Vars));
    A('begin');
    A('  AuthorizeScope(''' + Scope + ''');');
  end;

  procedure Found;
  begin
    A('  M := Find(Req);');
    A('  if M = nil then');
    A('    Exit(NotFound);');
  end;

begin
  N := ResourceNamesOf(P);
  B := TStringList.Create;
  try
    A('{ ' + Capital(N.HumanPlural) + ' as JSON, for a program: the ' + P.Table +
      ' table under ' + N.ApiUrl + '.');
    A('');
    A('  Written by askr make resource --api. It is yours now: nothing');
    A('  regenerates it, and askr make will not write over it.');
    A('');
    A('  Reading needs a token with ' + N.ScopeRead + ', writing one with');
    A('  ' + N.ScopeWrite + ':  askr token:issue <user-id> <name> --scopes=' +
      N.ScopeRead + ',' + N.ScopeWrite);
    A('');
    A('  ' + N.ApiDocProc + ' describes these routes to the OpenAPI document, and');
    A('  askr openapi --check fails when the two disagree -- a route here that');
    A('  nothing describes, or a description of a route that is gone. }');
    A('unit ' + N.ApiCtlUnit + ';');
    A('');
    A('{$mode Delphi}{$H+}');
    A('');
    A('interface');
    A('');
    A('uses');
    A('  SysUtils,');
    A('  Askr.Http.Request, Askr.Http.Response, Askr.Http.Router,');
    A('  Askr.Auth.Token, Askr.OpenApi,');
    A('  Askr.Urd.Model, Askr.Urd.Query, Askr.Urd.Grid, Askr.Urd.Bind, Askr.Urd.Json,');
    if PreloadListOf(Manys) <> '' then
      A('  Askr.Urd.Driver,');
    Uses_ := '  ' + N.ModelUnit + ', ' + N.SchemaUnit;
    for I := 0 to High(Manys) do
      if Manys[I].Available and
         (Pos('App.Models.' + Manys[I].Rel.Model + ',', Uses_ + ',') = 0) then
        Uses_ := Uses_ + ',' + #10 + '  App.Models.' + Manys[I].Rel.Model;
    A(Uses_ + ';');
    A('');
    A('type');
    A('  ' + N.ApiCtlClass + ' = class');
    A('  public');
    A('    function Index(Req: TRequest): TResponse;');
    A('    function Show(Req: TRequest): TResponse;');
    A('    function Store(Req: TRequest): TResponse;');
    A('    function Update(Req: TRequest): TResponse;');
    A('    function Remove(Req: TRequest): TResponse;');
    A('  end;');
    A('');
    A('{ The routes, called by app.lpr and by the test. }');
    A('procedure ' + N.ApiRoutesProc + '(R: TRouter);');
    A('');
    A('{ What the routes are, for the OpenAPI document. AppApiDoc calls it. }');
    A('procedure ' + N.ApiDocProc + '(D: TOpenApi);');
    A('');
    A('implementation');
    A('');
    A('var');
    A('  Ctl: ' + N.ApiCtlClass + ';');
    A('');
    A('procedure ' + N.ApiRoutesProc + '(R: TRouter);');
    A('begin');
    A('  if Ctl = nil then');
    A('    Ctl := ' + N.ApiCtlClass + '.Create;');
    A('  R.Get(''' + N.ApiUrl + ''', Ctl.Index);');
    A('  R.Get(''' + N.ApiUrl + '/:id'', Ctl.Show);');
    A('  R.Post(''' + N.ApiUrl + ''', Ctl.Store);');
    A('  R.Patch(''' + N.ApiUrl + '/:id'', Ctl.Update);');
    A('  R.Delete(''' + N.ApiUrl + '/:id'', Ctl.Remove);');
    A('end;');
    A('');
    A('procedure ' + N.ApiDocProc + '(D: TOpenApi);');
    A('begin');
    A('  D.Get(''' + N.ApiUrl + ''').Summary(''Every ' + N.Human + ', a page at a time'')');
    A('   .ReturnsList(T' + N.Model + ').Secured(''' + N.ScopeRead + ''');');
    A('  D.Get(''' + N.ApiUrl + '/:id'').Summary(''One ' + N.Human + ''')');
    A('   .Returns(T' + N.Model + ').Secured(''' + N.ScopeRead + ''');');
    A('  D.Post(''' + N.ApiUrl + ''').Summary(''Add ' + AOrAn(N.Human) + ''')');
    A('   .Body(T' + N.Model + ').Returns(T' + N.Model + ', 201).Secured(''' + N.ScopeWrite + ''');');
    A('  D.Patch(''' + N.ApiUrl + '/:id'').Summary(''Change ' + AOrAn(N.Human) +
      '; what is not sent is left as it is'')');
    A('   .Body(T' + N.Model + ').Returns(T' + N.Model + ').Secured(''' + N.ScopeWrite + ''');');
    A('  D.Delete(''' + N.ApiUrl + '/:id'').Summary(''Remove ' + AOrAn(N.Human) + ''')');
    A('   .NoContent.Secured(''' + N.ScopeWrite + ''');');
    A('end;');
    A('');
    A('{ The row the path names, or nil. }');
    A('function Find(Req: TRequest): T' + N.Model + ';');
    A('begin');
    A('  Result := TQuery<T' + N.Model + '>.New.Find(Req.Param(''id'').ToIntDef(0));');
    A('end;');
    A('');
    Loaded := PreloadListOf(Manys);
    if Loaded <> '' then
    begin
      A('{ The same, with the rows it belongs to many of: what a reply shows. }');
      A('function FindLoaded(Id: Int64): T' + N.Model + ';');
      A('begin');
      A('  Result := TQuery<T' + N.Model + '>.New.Preload(' + Loaded + ').Find(Id);');
      A('end;');
      A('');
    end;
    A('function NotFound: TResponse;');
    A('begin');
    A('  Result := Problem(404, ''No ' + N.Human + ' with that id.'');');
    A('end;');
    A('');
    B.Add(FillText(P));
    A('');
    A('{ The envelope: data, meta and links, with the search and the sort read');
    A('  off the query string and done in the database. }');
    A('function ' + N.ApiCtlClass + '.Index(Req: TRequest): TResponse;');
    A('var');
    A('  G: TGrid<T' + N.Model + '>;');
    A('begin');
    A('  AuthorizeScope(''' + N.ScopeRead + ''');');
    A(GridText(P));
    if Loaded <> '' then
      A('  Result := G.ListResponse(G.Rows(TQuery<T' + N.Model + '>.New.Preload(' +
        Loaded + ')));')
    else
      A('  Result := G.ListResponse(G.Rows(TQuery<T' + N.Model + '>.New));');
    A('end;');
    A('');
    Head('Show', N.ScopeRead);
    if Loaded <> '' then
    begin
      A('  M := FindLoaded(Req.Param(''id'').ToIntDef(0));');
      A('  if M = nil then');
      A('    Exit(NotFound);');
    end
    else
      Found;
    A('  Result := RespondModel(M);');
    A('end;');
    A('');
    Head('Store', N.ScopeWrite, ManyVarsText(Manys));
    A('  M := T' + N.Model + '.Create;');
    A('  Fill(Req, M);');
    if Loaded <> '' then
    begin
      A(ManySaveText(Manys, 'ValidationProblem(M.Errors)'));
      A('  M := FindLoaded(M.Id);');
    end
    else
    begin
      A('  if not M.Validate then');
      A('    Exit(ValidationProblem(M.Errors));');
      A('  M.Save;');
    end;
    A('  Result := RespondModel(M, 201)');
    A('    .WithHeader(''Location'', ''' + N.ApiUrl + '/'' + IntToStr(M.Id));');
    A('end;');
    A('');
    A('{ PATCH, not PUT: a field that is not in the body is left as it is,');
    A('  which is what FillInto does and what PATCH means. }');
    Head('Update', N.ScopeWrite, ManyVarsText(Manys));
    Found;
    A('  Fill(Req, M);');
    if Loaded <> '' then
    begin
      A(ManySaveText(Manys, 'ValidationProblem(M.Errors)'));
      A('  M := FindLoaded(M.Id);');
    end
    else
    begin
      A('  if not M.Validate then');
      A('    Exit(ValidationProblem(M.Errors));');
      A('  M.Save;');
    end;
    A('  Result := RespondModel(M);');
    A('end;');
    A('');
    Head('Remove', N.ScopeWrite);
    Found;
    A('  M.Delete;');
    A('  Result := Respond(204);');
    A('end;');
    A('');
    A('finalization');
    A('  Ctl.Free;');
    A('');
    A('end.');
    Result := B.Text;
  finally
    B.Free;
  end;
end;

const
  ApiDocUsesMarker = '  { askr make resource --api adds the controllers below. }';
  ApiDocCallMarker = '  { askr make resource --api adds each description below. }';

{ The one AppApiDoc, written the first time --api runs. Each resource
  after that is two lines at the markers. }
function ApiDocUnitText(const N: TResourceNames; const Title: string): string;
begin
  Result :=
    '{ The API document: what the app says about the routes under /api.' + #10 +
    '  GET /openapi.json serves it, askr openapi prints it, and' + #10 +
    '  askr openapi --check fails when a route and its description disagree.' + #10 + #10 +
    '  Written by askr make resource --api, which adds each resource at the' + #10 +
    '  two marked lines. }' + #10 +
    'unit App.Http.ApiDoc;' + #10 + #10 +
    '{$mode Delphi}{$H+}' + #10 + #10 +
    'interface' + #10 + #10 +
    'uses' + #10 +
    '  Askr.OpenApi;' + #10 + #10 +
    'procedure AppApiDoc(D: TOpenApi);' + #10 + #10 +
    'implementation' + #10 + #10 +
    'uses' + #10 +
    ApiDocUsesMarker + #10 +
    '  ' + N.ApiCtlUnit + ';' + #10 + #10 +
    'procedure AppApiDoc(D: TOpenApi);' + #10 +
    'begin' + #10 +
    '  D.Title(' + PasStr(Title) + ').Version(''1.0'').Covers(''/api'');' + #10 +
    ApiDocCallMarker + #10 +
    '  ' + N.ApiDocProc + '(D);' + #10 +
    'end;' + #10 + #10 +
    'end.' + #10;
end;

{ ------------------------------------------------------------ model -- }

function ModelText(const P: TResourcePlan; const Manys: TManyInfos): string;
var
  N: TResourceNames;
  Fields: TFieldSpecs;
  Intro, Hidden, Describe, Types, Extra: TStringArray;
  I: Integer;
  PC: TPlanColumn;
  Uses_: string;
begin
  N := ResourceNamesOf(P);
  Fields := nil;
  Hidden := nil;
  Intro := nil;
  Say(Intro, 'Written by askr make resource from the ' + P.Table + ' table as it');
  Say(Intro, 'was. After that it is yours: nothing regenerates it.');
  for I := 0 to High(P.Columns) do
  begin
    PC := P.Columns[I];
    if PC.IsPrimaryKey or PC.IsTimestamp or PC.IsSoftDelete then
      Continue;
    if not PC.Supported then
    begin
      Say(Intro, '');
      Say(Intro, PC.Field.Column + ' (' + PC.SqlType + ') is not mapped: a form or a list');
      Say(Intro, 'cannot show it.');
      Continue;
    end;
    SetLength(Fields, Length(Fields) + 1);
    Fields[High(Fields)] := PC.Field;
    if PC.LooksSecret then
      Say(Hidden, PC.Member);
  end;
  { A BelongsToMany is a list of the other model in a published field, and
    the line in Describe that says through which pivot. }
  Describe := DescribeLinesOf(P);
  Types := nil;
  Extra := nil;
  Uses_ := '';
  for I := 0 to High(Manys) do
    if Manys[I].Available then
    begin
      if Uses_ = '' then
        { TModelList is a generic in the query unit. }
        Uses_ := ', Askr.Urd.Query';
      if Pos('App.Models.' + Manys[I].Rel.Model + ',', Uses_ + ',') = 0 then
      begin
        Uses_ := Uses_ + ', App.Models.' + Manys[I].Rel.Model;
        Say(Types, 'T' + Manys[I].Rel.Model + 'List = TModelList<T' + Manys[I].Rel.Model + '>;');
      end;
      Say(Extra, Manys[I].Rel.Name + ': T' + Manys[I].Rel.Model + 'List;');
      Say(Describe, Manys[I].DescribeLine);
    end;
  Result := ModelUnitText(N.Model, Intro, Fields, P.HasTimestamps,
    P.HasSoftDeletes, Describe, RuleLinesOf(P), Hidden,
    N.SchemaUnit, N.SchemaVar, Uses_, Types, Extra);
end;

{ ------------------------------------------------------------ pages -- }

const
  PagesNote =
    '<!-- Written by askr make resource. Not typed against the table: a' + #10 +
    '     column renamed later is a compile error in the controller and a' + #10 +
    '     blank cell here. -->';

function FieldsText(const P: TResourcePlan; const Parents: TParentInfos;
  const Manys: TManyInfos): string;
var
  B: TStringList;
  Ed: TPlanColumns;
  I: Integer;
  PC: TPlanColumn;
  Req, Col, Lbl, Blank: string;
  Par: TParentInfo;
  Props: string;

  procedure A(const S: string);
  begin
    B.Add(S);
  end;

begin
  Ed := EditableOf(P);
  B := TStringList.Create;
  try
    A(PagesNote);
    A('<script module>');
    A('  // What a row from the server becomes in the form. Only the fields the');
    A('  // form has: anything else in it would be sent back on save.');
    if PreloadListOf(Manys) <> '' then
    begin
      A('  // ids is what the page was given for the boxes: the ids in each');
      A('  // pivot, as text, because a checkbox''s value is text.');
      A('  export function toForm(row, ids = {}) {');
    end
    else
      A('  export function toForm(row) {');
    A('    const r = row ?? {}');
    A('    return {');
    for I := 0 to High(Ed) do
    begin
      PC := Ed[I];
      Col := PC.Field.Column;
      case PC.Field.Kind of
        ftReferences:
          { A select holds text, and a number would match none of its
            options. }
          A('      ' + Col + ': r.' + Col + ' == null ? '''' : String(r.' + Col + '),');
        { A datetime needs nothing: the server sends 2026-01-02 03:04:05,
          and <input type="datetime-local"> takes a space as well as a T
          -- the HTML spec allows both and the input normalises to T. A
          conversion here was mutation-checked and changed nothing. A date
          does need one: the server's text has a time on it. }
        ftDate:
          A('      ' + Col + ': r.' + Col + ' ? r.' + Col + '.slice(0, 10) : '''',');
        ftBool:
          A('      ' + Col + ': !!r.' + Col + ',');
      else
        A('      ' + Col + ': r.' + Col + ' ?? '''',');
      end;
    end;
    for I := 0 to High(Manys) do
      if Manys[I].Available then
        A('      ' + Manys[I].Rel.InputKey + ': (ids.' + Manys[I].Rel.InputKey +
          ' ?? []).map(String),');
    A('    }');
    A('  }');
    A('');
    A('  // A new one starts from the database''s defaults, where they are');
    A('  // plain values. A default that is a function call is left to the');
    A('  // database, and the field starts empty.');
    Blank := '';
    for I := 0 to High(Ed) do
      if DefaultLiteral(Ed[I]) <> '' then
        Blank := Blank + '    ' + Ed[I].Field.Column + ': ' + DefaultLiteral(Ed[I]) + ',' + #10;
    if Blank = '' then
      A('  export const blank = toForm({})')
    else
    begin
      A('  export const blank = {');
      A('    ...toForm({}),');
      A(TrimRight(Blank));
      A('  }');
    end;
    A('</script>');
    A('');
    A('<script>');
    Props := '';
    for I := 0 to High(Parents) do
      if Parents[I].Available then
        Props := Props + Parents[I].Rel.Table + ' = [], ';
    for I := 0 to High(Manys) do
      if Manys[I].Available then
        Props := Props + ChoicesProp(Manys[I]) + ' = [], ';
    A('  import { Field, Input, Textarea, Select, Checkbox } from ''@askrcode/lauf''');
    if Props = '' then
      A('  let {} = $props()')
    else
      A('  let { ' + Copy(Props, 1, Length(Props) - 2) + ' } = $props()');
    A('</script>');
    A('');
    for I := 0 to High(Ed) do
    begin
      PC := Ed[I];
      Col := PC.Field.Column;
      Lbl := LabelOf(Col);
      if IsRequired(PC) then
        Req := ' required'
      else
        Req := '';
      case PC.Field.Kind of
        ftString:
          A('<Field name="' + Col + '" label="' + Lbl + '"' + Req + '><Input maxlength="' +
            IntToStr(PC.Field.Length) + '" /></Field>');
        ftText:
          A('<Field name="' + Col + '" label="' + Lbl + '"' + Req + '><Textarea rows="4" /></Field>');
        ftJson:
          A('<Field name="' + Col + '" label="' + Lbl + '"' + Req +
            ' description="JSON"><Textarea rows="6" class="font-mono" /></Field>');
        ftInt, ftBigInt:
          A('<Field name="' + Col + '" label="' + Lbl + '"' + Req +
            '><Input type="number" step="1" /></Field>');
        ftMoney, ftFloat:
          A('<Field name="' + Col + '" label="' + Lbl + '"' + Req +
            '><Input type="number" step="any" /></Field>');
        ftBool:
          { Its own label: a checkbox inside a Field would be labelled
            twice. }
          A('<Checkbox name="' + Col + '" label="' + Lbl + '" />');
        ftDateTime:
          A('<Field name="' + Col + '" label="' + Lbl + '"' + Req +
            '><Input type="datetime-local" step="1" /></Field>');
        ftDate:
          A('<Field name="' + Col + '" label="' + Lbl + '"' + Req +
            '><Input type="date" /></Field>');
        ftUuid:
          A('<Field name="' + Col + '" label="' + Lbl + '"' + Req +
            '><Input spellcheck="false" /></Field>');
        ftReferences:
          if ParentFor(Parents, Col, Par) and Par.Available then
          begin
            A('<Field name="' + Col + '" label="' + RefLabelOf(Col) + '"' + Req + '>');
            A('  <Select placeholder="Choose a ' + LowerCase(RefLabelOf(Col)) + '">');
            A('    {#each ' + Par.Rel.Table + ' as o (o.id)}');
            A('      <option value={String(o.id)}>{o.' + Par.LabelColumn + '}</option>');
            A('    {/each}');
            A('  </Select>');
            A('</Field>');
          end
          else
            A('<Field name="' + Col + '" label="' + RefLabelOf(Col) + '"' + Req +
              ' description="The id of a row in ' + PC.Field.RefTable +
              '"><Input type="number" step="1" /></Field>');
      end;
    end;
    { A box per row, with the same name: the form holds the ticked ids as
      a list, and an unticked form sends an empty one, which says "none"
      rather than "leave them". }
    for I := 0 to High(Manys) do
      if Manys[I].Available then
      begin
        A('<Field name="' + Manys[I].Rel.InputKey + '" label="' +
          LabelOf(Manys[I].Rel.Table) + '" as="fieldset">');
        A('  {#each ' + ChoicesProp(Manys[I]) + ' as o (o.id)}');
        A('    <Checkbox name="' + Manys[I].Rel.InputKey + '" value={String(o.id)} label={String(o.' +
          Manys[I].LabelColumn + ')} />');
        A('  {:else}');
        A('    <p class="text-sm text-muted">There are no ' +
          StringReplace(Manys[I].Rel.Table, '_', ' ', [rfReplaceAll]) + ' yet.</p>');
        A('  {/each}');
        A('</Field>');
      end;
    Result := B.Text;
  finally
    B.Free;
  end;
end;

{ The expression that writes a column's Value as the reader's locale
  does -- with n and d, Lauf's numbers() and dates() -- or '' when it is
  written as it comes. An integer comes as it is: a year and a quantity
  are both integers, and "2,026" is not a year. Money has at least two
  decimals and at most the four Currency holds. }
function LocaleFormatOf(Kind: TFieldType; const Value: string): string;
begin
  case Kind of
    ftMoney: Result := 'n(' + Value + ', { minimumFractionDigits: 2, maximumFractionDigits: 4 })';
    ftFloat: Result := 'n(' + Value + ')';
    ftDate: Result := 'd(' + Value + ')';
    ftDateTime: Result := 'd(' + Value + ', { dateStyle: ''medium'', timeStyle: ''short'' })';
  else
    Result := '';
  end;
end;

{ What a page needs from Lauf to write its columns: ', numbers, dates'
  for the import, and the lines that set up n and d. The list writes the
  listed columns, the page all it shows. }
procedure LocaleNeedsOf(const P: TResourcePlan; ListedOnly: Boolean;
  out Imports, Setup: string);
var
  I: Integer;
  Nums, Dates: Boolean;
  PC: TPlanColumn;
begin
  Nums := False;
  Dates := False;
  for I := 0 to High(P.Columns) do
  begin
    PC := P.Columns[I];
    if (ListedOnly and not PC.Listed) or PC.LooksSecret or not PC.Supported then
      Continue;
    case PC.Field.Kind of
      ftMoney, ftFloat: Nums := True;
      ftDate, ftDateTime: Dates := True;
    else
    end;
  end;
  Imports := '';
  Setup := '';
  if Nums then
  begin
    Imports := Imports + ', numbers';
    Setup := Setup + '  const n = numbers()' + #10;
  end;
  if Dates then
  begin
    Imports := Imports + ', dates';
    Setup := Setup + '  const d = dates()' + #10;
  end;
end;

function IndexText(const P: TResourcePlan): string;
var
  B: TStringList;
  N: TResourceNames;
  I: Integer;
  PC: TPlanColumn;
  Link, Extra, Fmt, Imports, Setup: string;

  procedure A(const S: string);
  begin
    B.Add(S);
  end;

begin
  N := ResourceNamesOf(P);
  LocaleNeedsOf(P, True, Imports, Setup);
  Link := FirstStringOf(P);
  if Link = '' then
    Link := P.PrimaryKey;
  B := TStringList.Create;
  try
    A(PagesNote);
    A('<script>');
    A('  import { router, Link } from ''@inertiajs/svelte''');
    A('  import { Heading, Button, DataGrid' + Imports + ' } from ''@askrcode/lauf''');
    A('  import Layout from ''../../Layout.svelte''');
    A('');
    A('  let { rows = [], grid = null } = $props()');
    if Setup <> '' then
    begin
      A('  // Money and dates as the reader writes them.');
      A(TrimRight(Setup));
    end;
    A('');
    A('  // The keys are the column names, and the server''s Sortable list is');
    A('  // keyed the same way: a column the server does not name cannot be');
    A('  // sorted by, whatever this says.');
    A('  const columns = [');
    for I := 0 to High(P.Columns) do
    begin
      PC := P.Columns[I];
      if not PC.Listed then
        Continue;
      Extra := '';
      if PC.Sortable then
        Extra := Extra + ', sortable: true';
      if PC.Field.Kind in [ftInt, ftBigInt, ftMoney, ftFloat, ftReferences] then
        Extra := Extra + ', align: ''right''';
      if PC.Field.Kind = ftBool then
        Extra := Extra + ', format: (v) => (v ? ''Yes'' : ''No'')';
      Fmt := LocaleFormatOf(PC.Field.Kind, 'v');
      if Fmt <> '' then
        Extra := Extra + ', format: (v) => ' + Fmt;
      if PC.Field.Column = Link then
        Extra := Extra + ', cell: linkCell';
      A('    { key: ' + JsStr(PC.Field.Column) + ', label: ' +
        JsStr(LabelOf(PC.Field.Column)) + Extra + ' },');
    end;
    A('  ]');
    A('');
    A('  // The grid says what it wants; the server does the sorting, the');
    A('  // search and the paging, and answers with the next page.');
    A('  function onstate(s) {');
    A('    router.get(''' + N.Url + ''', s, { preserveState: true, preserveScroll: true, replace: true })');
    A('  }');
    A('</script>');
    A('');
    A('{#snippet linkCell(row, value)}');
    A('  <Link href={`' + N.Url + '/${row.id}`} class="underline-offset-2 hover:underline">{value}</Link>');
    A('{/snippet}');
    A('');
    A('<svelte:head><title>' + Capital(N.HumanPlural) + '</title></svelte:head>');
    A('');
    A('<Layout>');
    A('  <div class="mb-6 flex flex-wrap items-center justify-between gap-3">');
    A('    <Heading level={1}>' + Capital(N.HumanPlural) + '</Heading>');
    A('    <Button variant="primary" href="' + N.Url + '/new">New ' + N.Human + '</Button>');
    A('  </div>');
    A('  <DataGrid caption="' + Capital(N.HumanPlural) + '" {rows} {columns} {grid} {onstate}');
    A('            empty="No ' + N.HumanPlural + ' yet"');
    A('            onrowactivate={(row) => router.visit(`' + N.Url + '/${row.id}`)} />');
    A('</Layout>');
    Result := B.Text;
  finally
    B.Free;
  end;
end;

function ShowText(const P: TResourcePlan; const Parents: TParentInfos;
  const Children: TChildInfos; const Manys: TManyInfos): string;
var
  B: TStringList;
  N: TResourceNames;
  I: Integer;
  PC: TPlanColumn;
  Col, Props, Rel, Imports, Setup: string;
  Par: TParentInfo;
  Many: Boolean;

  procedure A(const S: string);
  begin
    B.Add(S);
  end;

begin
  N := ResourceNamesOf(P);
  B := TStringList.Create;
  try
    Props := N.Prop;
    for I := 0 to High(Parents) do
      if Parents[I].Available then
        Props := Props + ', ' + SnakeCase(Parents[I].Rel.Name) + ' = null';
    Many := False;
    for I := 0 to High(Children) do
      if Children[I].Available then
      begin
        Props := Props + ', ' + SnakeCase(Children[I].Rel.Name) + ' = []';
        Many := True;
      end;
    if Many then
      Props := Props + ', listed = 50';
    A(PagesNote);
    A('<script>');
    A('  import { router, Link } from ''@inertiajs/svelte''');
    LocaleNeedsOf(P, False, Imports, Setup);
    A('  import { Heading, Button' + Imports + ' } from ''@askrcode/lauf''');
    A('  import Layout from ''../../Layout.svelte''');
    A('');
    A('  let { ' + Props + ' } = $props()');
    if Setup <> '' then
      A(TrimRight(Setup));
    A('');
    A('  function remove() {');
    A('    if (!confirm(''Delete this ' + N.Human + '?'')) return');
    A('    router.delete(`' + N.Url + '/${' + N.Prop + '.id}`)');
    A('  }');
    A('');
    A('  function shown(v) {');
    A('    if (v === null || v === undefined || v === '''') return ''—''');
    A('    if (v === true) return ''Yes''');
    A('    if (v === false) return ''No''');
    A('    return String(v)');
    A('  }');
    A('</script>');
    A('');
    A('<svelte:head><title>' + Capital(N.Human) + ' ' + '{' + N.Prop + '.id}</title></svelte:head>');
    A('');
    A('<Layout>');
    A('  <div class="mb-6 flex flex-wrap items-center justify-between gap-3">');
    A('    <Heading level={1}>' + Capital(N.Human) + ' {' + N.Prop + '.id}</Heading>');
    A('    <div class="flex gap-2">');
    A('      <Button href={`' + N.Url + '/${' + N.Prop + '.id}/edit`}>Edit</Button>');
    A('      <Button variant="danger" onclick={remove}>Delete</Button>');
    A('    </div>');
    A('  </div>');
    A('  <dl class="flex flex-col gap-3">');
    for I := 0 to High(P.Columns) do
    begin
      PC := P.Columns[I];
      if PC.LooksSecret or not PC.Supported or PC.IsSoftDelete then
        Continue;
      Col := PC.Field.Column;
      A('    <div class="flex flex-col gap-1 sm:flex-row sm:gap-4">');
      if (PC.Field.Kind = ftReferences) and ParentFor(Parents, Col, Par) and
         Par.Available then
      begin
        Rel := SnakeCase(Par.Rel.Name);
        A('      <dt class="w-40 shrink-0 text-sm text-muted">' + RefLabelOf(Col) + '</dt>');
        A('      <dd>{' + Rel + ' ? shown(' + Rel + '.' + Par.LabelColumn + ') : shown(' +
          N.Prop + '.' + Col + ')}</dd>');
      end
      else
      begin
        A('      <dt class="w-40 shrink-0 text-sm text-muted">' + LabelOf(Col) + '</dt>');
        if PC.Field.Kind in [ftJson, ftText] then
          A('      <dd class="whitespace-pre-wrap' +
            BoolToStr(PC.Field.Kind = ftJson, ' font-mono text-sm', '') +
            '">{shown(' + N.Prop + '.' + Col + ')}</dd>')
        else if LocaleFormatOf(PC.Field.Kind, Col) <> '' then
          A('      <dd>{shown(' + LocaleFormatOf(PC.Field.Kind, N.Prop + '.' + Col) + ')}</dd>')
        else
          A('      <dd>{shown(' + N.Prop + '.' + Col + ')}</dd>');
      end;
      A('    </div>');
    end;
    { What it belongs to many of: loaded with the row, and linked when
      the other table has pages of its own. }
    for I := 0 to High(Manys) do
      if Manys[I].Available then
      begin
        Rel := SnakeCase(Manys[I].Rel.Name);
        A('    <div class="flex flex-col gap-1 sm:flex-row sm:gap-4">');
        A('      <dt class="w-40 shrink-0 text-sm text-muted">' + LabelOf(Manys[I].Rel.Table) + '</dt>');
        A('      <dd>');
        A('        {#if (' + N.Prop + '.' + Rel + ' ?? []).length === 0}—{:else}');
        A('          <ul class="flex flex-wrap gap-x-3 gap-y-1">');
        A('            {#each ' + N.Prop + '.' + Rel + ' as t (t.id)}');
        if Manys[I].Linked then
          A('              <li><Link href={`' + Manys[I].Url +
            '/${t.id}`} class="underline-offset-2 hover:underline">{t.' +
            Manys[I].LabelColumn + '}</Link></li>')
        else
          A('              <li>{t.' + Manys[I].LabelColumn + '}</li>');
        A('            {/each}');
        A('          </ul>');
        A('        {/if}');
        A('      </dd>');
        A('    </div>');
      end;
    A('  </dl>');
    for I := 0 to High(Children) do
      if Children[I].Available then
      begin
        Rel := SnakeCase(Children[I].Rel.Name);
        A('');
        A('  <section class="mt-12" aria-labelledby="rows-' + Rel + '">');
        A('    <h2 id="rows-' + Rel + '" class="text-lg font-medium">' +
          Capital(StringReplace(Children[I].Rel.Table, '_', ' ', [rfReplaceAll])) + '</h2>');
        A('    {#if ' + Rel + '.length === 0}');
        A('      <p class="mt-2 text-sm text-muted">None yet.</p>');
        A('    {:else}');
        A('      <ul class="mt-3 flex flex-col border-t border-line">');
        A('        {#each ' + Rel + ' as c (c.id)}');
        if Children[I].Linked then
          A('          <li class="border-b border-line py-2"><Link href={`' + Children[I].Url +
            '/${c.id}`} class="underline-offset-2 hover:underline">{c.' +
            Children[I].LabelColumn + '}</Link></li>')
        else
          A('          <li class="border-b border-line py-2">{c.' + Children[I].LabelColumn + '}</li>');
        A('        {/each}');
        A('      </ul>');
        A('      {#if ' + Rel + '.length >= listed}');
        A('        <p class="mt-2 text-sm text-muted">The first {listed}.</p>');
        A('      {/if}');
        A('    {/if}');
        A('  </section>');
      end;
    A('  <p class="mt-8"><a href="' + N.Url + '" class="underline-offset-2 hover:underline">All ' +
      N.HumanPlural + '</a></p>');
    A('</Layout>');
    Result := B.Text;
  finally
    B.Free;
  end;
end;

function FormPageText(const P: TResourcePlan; const Parents: TParentInfos;
  const Manys: TManyInfos; Editing: Boolean): string;
var
  B: TStringList;
  N: TResourceNames;
  I: Integer;
  Props, Pass, Title, Ids: string;

  procedure A(const S: string);
  begin
    B.Add(S);
  end;

begin
  N := ResourceNamesOf(P);
  B := TStringList.Create;
  try
    Props := 'errors = {}';
    Pass := '';
    if Editing then
      Props := N.Prop + ', ' + Props;
    for I := 0 to High(Parents) do
      if Parents[I].Available then
      begin
        Props := Props + ', ' + Parents[I].Rel.Table + ' = []';
        Pass := Pass + ' {' + Parents[I].Rel.Table + '}';
      end;
    Ids := '';
    for I := 0 to High(Manys) do
      if Manys[I].Available then
      begin
        Props := Props + ', ' + ChoicesProp(Manys[I]) + ' = []';
        Pass := Pass + ' {' + ChoicesProp(Manys[I]) + '}';
        if Editing then
        begin
          Props := Props + ', ' + Manys[I].Rel.InputKey + ' = []';
          if Ids <> '' then
            Ids := Ids + ', ';
          Ids := Ids + Manys[I].Rel.InputKey;
        end;
      end;
    if Editing then
      Title := 'Edit ' + N.Human
    else
      Title := 'New ' + N.Human;
    A(PagesNote);
    A('<script>');
    A('  import { Form } from ''@askrcode/lauf/inertia''');
    A('  import { Heading, Button } from ''@askrcode/lauf''');
    A('  import Layout from ''../../Layout.svelte''');
    if Editing then
      A('  import Fields, { toForm } from ''./Fields.svelte''')
    else
      A('  import Fields, { blank } from ''./Fields.svelte''');
    A('');
    A('  let { ' + Props + ' } = $props()');
    A('</script>');
    A('');
    A('<svelte:head><title>' + Title + '</title></svelte:head>');
    A('');
    A('<Layout>');
    A('  <Heading level={1} class="mb-6">' + Title + '</Heading>');
    if Editing then
    begin
      A('  <Form action={`' + N.Url + '/${' + N.Prop + '.id}`} method="put"');
      if Ids <> '' then
        A('        data={toForm(' + N.Prop + ', { ' + Ids + ' })} {errors} class="flex flex-col gap-4">')
      else
        A('        data={toForm(' + N.Prop + ')} {errors} class="flex flex-col gap-4">');
    end
    else
    begin
      A('  <Form action="' + N.Url + '" method="post" data={blank} {errors}');
      A('        class="flex flex-col gap-4">');
    end;
    A('    <Fields' + Pass + ' />');
    A('    <div class="flex gap-2">');
    if Editing then
    begin
      A('      <Button type="submit" variant="primary">Save ' + N.Human + '</Button>');
      A('      <Button href={`' + N.Url + '/${' + N.Prop + '.id}`}>Cancel</Button>');
    end
    else
    begin
      A('      <Button type="submit" variant="primary">Create ' + N.Human + '</Button>');
      A('      <Button href="' + N.Url + '">Cancel</Button>');
    end;
    A('    </div>');
    A('  </Form>');
    A('</Layout>');
    Result := B.Text;
  finally
    B.Free;
  end;
end;

{ ------------------------------------------------------------- test -- }

{ A value the rules accept, as JSON. The reference is %d: the id of the
  parent row the test makes first. }
function SampleJson(const PC: TPlanColumn): string;
begin
  case PC.Field.Kind of
    ftString: Result := '"' + Copy('Sample', 1, PC.Field.Length) + '"';
    ftText: Result := '"Sample text"';
    ftInt, ftBigInt: Result := '1';
    ftMoney: Result := '12.5';
    ftFloat: Result := '1.5';
    ftBool: Result := 'true';
    { Without seconds, the way a browser sends it. }
    ftDateTime: Result := '"2026-01-02T03:04"';
    ftDate: Result := '"2026-01-02"';
    ftJson: Result := '"[]"';
    ftUuid: Result := '"123e4567-e89b-12d3-a456-426614174000"';
    ftReferences: Result := '%d';
  end;
end;

{ The same, as a Pascal assignment on a model: for the parent row. '' for
  a reference, which the parent cannot be given here. }
function SamplePascal(const PC: TPlanColumn): string;
begin
  { A unique column gets Seq, which the test moves on for every row: three
    rows with one value would be refused by the rule, and on a test
    database that keeps its rows, so would the next run's. }
  if PC.Field.Unique then
    case PC.Field.Kind of
      ftString, ftText, ftJson:
        { The end of Seq, as much of it as fits: a column with no length
          takes all of it, and one a single character wide takes a digit. }
        if PC.Field.Length <= 0 then
          Exit('''S'' + IntToStr(Seq)')
        else if PC.Field.Length = 1 then
          Exit('SeqTail(1)')
        else
          Exit('''S'' + SeqTail(' + IntToStr(PC.Field.Length - 1) + ')');
      { Seq whole only where it fits: a BIGINT. An INTEGER is 32 bits on
        Postgres and MySQL, money is NUMERIC(12,2), and Seq -- counted in
        thousandths of a millisecond since 2020 -- is far past both; SQLite,
        whose INTEGER is 64 bits, never said so. The end of it changes per
        row and per test unit all the same. Assigned, not cast: a Currency
        takes an Int64 as the number it is. }
      ftBigInt:
        Exit('Seq');
      ftInt:
        if Pos('tiny', LowerCase(PC.SqlType)) > 0 then
          Exit('(Seq mod 100)')
        else if (Pos('small', LowerCase(PC.SqlType)) > 0) or
                (Pos('int2', LowerCase(PC.SqlType)) > 0) then
          Exit('(Seq mod 30000)')
        else if Pos('medium', LowerCase(PC.SqlType)) > 0 then
          Exit('(Seq mod 8000000)')
        else
          Exit('(Seq mod 1000000000)');
      ftMoney, ftFloat:
        Exit('(Seq mod 1000000000)');
      { A reference is unique already -- the test makes a new parent for
        every row. A boolean can only be unique twice; there is nothing to
        vary, and a table like that makes one row per value. }
      ftReferences, ftBool: ;
      ftUuid:
        Exit('Format(''%.8d-0000-4000-8000-%.12d'', [Seq mod 100000000, Seq mod 1000000000000])');
      ftDateTime, ftDate:
        Exit('(EncodeDate(2000, 1, 1) + Seq mod 30000)');
    end;
  case PC.Field.Kind of
    ftString: Result := PasStr(Copy('Sample', 1, PC.Field.Length));
    ftText: Result := PasStr('Sample text');
    ftInt, ftBigInt: Result := '1';
    ftMoney: Result := '12.5';
    ftFloat: Result := '1.5';
    ftBool: Result := 'True';
    ftDateTime, ftDate: Result := 'EncodeDate(2026, 1, 2)';
    ftJson: Result := PasStr('[]');
    ftUuid: Result := PasStr('123e4567-e89b-12d3-a456-426614174000');
    ftReferences: Result := '';
  end;
end;

{ A Pascal expression for the JSON of a sample value. A literal, unless the
  column is unique; a reference is the caller's to fill in. }
function SampleJsonExpr(const PC: TPlanColumn): string;
begin
  if not PC.Field.Unique or (PC.Field.Kind = ftReferences) then
    Exit(PasStr(SampleJson(PC)));
  case PC.Field.Kind of
    ftInt, ftBigInt, ftMoney, ftFloat: Result := 'IntToStr(' + SamplePascal(PC) + ')';
    ftDate: Result := '''"'' + FormatDateTime(''yyyy-mm-dd'', ' + SamplePascal(PC) + ') + ''"''';
    ftDateTime: Result := '''"'' + FormatDateTime(''yyyy-mm-dd"T"hh:nn'', ' +
      SamplePascal(PC) + ') + ''"''';
  else
    Result := '''"'' + ' + SamplePascal(PC) + ' + ''"''';
  end;
end;

{ Whether the test can make a parent row: every required field of it can
  be set, and none of them is a reference of its own. }
function ParentMakeable(const Par: TParentInfo): Boolean;
var
  I: Integer;
  PC: TPlanColumn;
begin
  if not Par.Available or not Par.Plan.CanCreate or (Length(Par.Plan.Problems) > 0) then
    Exit(False);
  for I := 0 to High(Par.Plan.Columns) do
  begin
    PC := Par.Plan.Columns[I];
    if PC.Editable and not PC.Field.Nullable and not PC.HasDefault and
       (PC.Field.Kind = ftReferences) then
      Exit(False);
  end;
  Result := True;
end;

{ Whether the test can make rows in the other table of a BelongsToMany:
  the same test as for a parent. }
function ManyMakeable(const M: TManyInfo): Boolean;
var
  I: Integer;
  PC: TPlanColumn;
begin
  if not M.Available or not M.Plan.CanCreate or (Length(M.Plan.Problems) > 0) then
    Exit(False);
  for I := 0 to High(M.Plan.Columns) do
  begin
    PC := M.Plan.Columns[I];
    if PC.Editable and not PC.Field.Nullable and not PC.HasDefault and
       (PC.Field.Kind = ftReferences) then
      Exit(False);
  end;
  Result := True;
end;

function TestUnitText(const P: TResourcePlan; const Parents: TParentInfos;
  const Manys: TManyInfos; Api: Boolean; out Why: string): string;
var
  B: TStringList;
  N: TResourceNames;
  Ed: TPlanColumns;
  I, J, K: Integer;
  PC: TPlanColumn;
  Body, First, Firstmember, RequiredCol, Uses_: string;
  CtlUnit, Url, RoutesProc, TestUnit, TestsProc, RD, WR, Forged: string;
  CanWrite: Boolean;
  Par: TParentInfo;
  ParentIdx: array of Integer;
  Hidden: TStringArray;
  Mn: TManyInfo;
  AnyMany: Boolean;

  procedure A(const S: string);
  begin
    B.Add(S);
  end;

  { Whether the test makes a parent row for this reference. }
  function MadeFor(const Column: string): Boolean;
  var
    J: Integer;
  begin
    for J := 0 to High(ParentIdx) do
      if Parents[ParentIdx[J]].Rel.ForeignKey = Column then
        Exit(True);
    Result := False;
  end;

  { The JSON body with the value of Column replaced. }
  function BodyWith(const Column, Value: string): string;
  var
    J: Integer;
    V: string;
  begin
    Result := '';
    for J := 0 to High(Ed) do
    begin
      V := SampleJson(Ed[J]);
      { A reference the test has no row for is left empty -- which it can
        only be when it is nullable, or nothing here writes. }
      if (Ed[J].Field.Kind = ftReferences) and not MadeFor(Ed[J].Field.Column) then
        V := 'null';
      if Ed[J].Field.Column = Column then
        V := Value;
      if Result <> '' then
        Result := Result + ',';
      Result := Result + '"' + Ed[J].Field.Column + '":' + V;
    end;
    Result := '{' + Result + '}';
  end;

  function FirstLen(const Text_: string): string;
  begin
    Result := PasStr(Copy(Text_, 1, P.Columns[PlanColumnIndex(P, First)].Field.Length));
  end;

begin
  N := ResourceNamesOf(P);
  Ed := EditableOf(P);
  Hidden := HiddenColumnsOf(P);
  Why := '';
  if Api then
  begin
    CtlUnit := N.ApiCtlUnit;
    Url := N.ApiUrl;
    RoutesProc := N.ApiRoutesProc;
    TestUnit := N.ApiTestUnit;
    TestsProc := N.ApiTestsProc;
    RD := 'Reader';
    WR := 'Writer';
  end
  else
  begin
    CtlUnit := N.CtlUnit;
    Url := N.Url;
    RoutesProc := N.RoutesProc;
    TestUnit := N.TestUnit;
    TestsProc := N.TestsProc;
    RD := 'Client.AsInertia';
    WR := 'Client.AsInertia';
  end;

  { The actions that write need a row the rules accept. }
  CanWrite := P.CanCreate and (Length(Ed) > 0);
  if not P.CanCreate then
    Why := 'a NOT NULL column the form leaves out has no default';
  ParentIdx := nil;
  for I := 0 to High(Ed) do
    if Ed[I].Field.Kind = ftReferences then
    begin
      if not ParentFor(Parents, Ed[I].Field.Column, Par) or not ParentMakeable(Par) then
      begin
        if not Ed[I].Field.Nullable then
        begin
          CanWrite := False;
          Why := 'the test cannot make a row in ' + Ed[I].Field.RefTable +
            ' for ' + Ed[I].Field.Column + ' to point at';
        end;
        Continue;
      end;
      for K := 0 to High(Parents) do
        if Parents[K].Rel.ForeignKey = Ed[I].Field.Column then
        begin
          SetLength(ParentIdx, Length(ParentIdx) + 1);
          ParentIdx[High(ParentIdx)] := K;
        end;
    end;

  First := FirstStringOf(P);
  Firstmember := '';
  if First <> '' then
    Firstmember := P.Columns[PlanColumnIndex(P, First)].Field.Prop;
  RequiredCol := '';
  for I := 0 to High(Ed) do
    if (RequiredCol = '') and IsRequired(Ed[I]) and
       (Ed[I].Field.Kind in [ftString, ftText]) then
      RequiredCol := Ed[I].Field.Column;

  B := TStringList.Create;
  try
    Uses_ := '  ' + CtlUnit + ', ' + N.ModelUnit;
    for I := 0 to High(ParentIdx) do
      Uses_ := Uses_ + ', App.Models.' + Parents[ParentIdx[I]].Rel.Model;
    AnyMany := False;
    for I := 0 to High(Manys) do
      if CanWrite and ManyMakeable(Manys[I]) then
      begin
        AnyMany := True;
        if Pos('App.Models.' + Manys[I].Rel.Model + ',', Uses_ + ',') = 0 then
          Uses_ := Uses_ + ', App.Models.' + Manys[I].Rel.Model;
      end;

    A('{ Every action of ' + CtlUnit + ', through the router.');
    A('');
    A('  Written by askr make resource. The database is TEST_DATABASE_URL, and');
    A('  sqlite::memory: when that is not set, with the migrations run first:');
    A('  a test that wrote into the database you develop against would leave');
    A('  its rows there. Pending migrations are run on TEST_DATABASE_URL too,');
    if Api then
    begin
      A('  so point it at a database that is only for this. The tokens are');
      A('  issued there as well, one that may read and one that may write. }');
    end
    else
      A('  so point it at a database that is only for this. }');
    A('unit ' + TestUnit + ';');
    A('');
    A('{$mode Delphi}{$H+}');
    A('');
    A('interface');
    A('');
    A('procedure ' + TestsProc + ';');
    A('');
    A('implementation');
    A('');
    A('uses');
    A('  SysUtils, Askr.Core.Arena, Askr.Core.Env, Askr.Testing,');
    if Api then
      A('  Askr.Http.Response, Askr.Http.Router, Askr.Auth.Token,')
    else
      A('  Askr.Http.Response, Askr.Http.Router, Askr.Session,');
    A('  Askr.Urd.Driver, Askr.Urd.Sqlite, Askr.Urd.Pg, Askr.Urd.MySql,');
    A('  Askr.Urd.Model, Askr.Urd.Query, Askr.Norn.Migration,');
    A('  App.Migrations,');
    A(Uses_ + ';');
    A('');
    A('var');
    A('  Conn: TDbConnection;');
    A('  Arena: TArena;');
    A('  Router: TRouter;');
    A('  Client: TTestClient;');
    if Api then
      A('  ReadToken, WriteToken: string;');
    A('  { Moves on for every row, so a unique column never repeats -- not in');
    A('    this run, and not against the rows an earlier run left behind. }');
    A('  Seq: Int64;');
    A('  LastFirst: string;');
    A('');
    A('{ The last N digits of Seq, for a unique column N+1 characters wide:');
    A('  the end of the number is what changes from one row to the next, and');
    A('  the front of it is the same for every row of a run. }');
    A('function SeqTail(N: Integer): string;');
    A('begin');
    A('  Result := IntToStr(Seq);');
    A('  if Length(Result) > N then');
    A('    Result := Copy(Result, Length(Result) - N + 1, N);');
    A('end;');
    A('');
    if Api then
    begin
      A('{ Once for all of them: the database, the migrations, two tokens, and');
      A('  a router that reads them, with this resource''s routes from the same');
      A('  procedure app.lpr calls. }');
    end
    else
    begin
      A('{ Once for all of them: the database, the migrations, and a router with');
      A('  sessions -- BackWithErrors keeps the errors there -- and this');
      A('  resource''s routes, from the same procedure app.lpr calls. }');
    end;
    A('procedure Ready;');
    A('var');
    A('  M: TMigrator;');
    A('begin');
    A('  if Client <> nil then');
    A('    Exit;');
    { A thousand apart per millisecond. Every test unit counts from its
      own start, and another unit's parents are rows in the same tables:
      counting from the millisecond alone, the gadgets' test made more
      makers than milliseconds passed before the makers' test began, and a
      unique name came round twice -- on MySQL, which was fast enough. }
    A('  Seq := Trunc((Now - EncodeDate(2020, 1, 1)) * 86400000) * 1000;');
    A('  Arena := TArena.Create(64 * 1024);');
    A('  UseArena(Arena);');
    A('  Conn := OpenDbConnection(Env(''TEST_DATABASE_URL'', ''sqlite::memory:''));');
    A('  UseDb(Conn);');
    A('  M := TMigrator.Create(Conn);');
    A('  try');
    A('    M.Up;');
    A('  finally');
    A('    M.Free;');
    A('  end;');
    A('  Router := TRouter.Create;');
    if Api then
    begin
      A('  EnsureTokenSchema(Conn);');
      A('  ReadToken := IssueToken(Conn, ''test'', ''read'', [''' + N.ScopeRead + ''']);');
      A('  WriteToken := IssueToken(Conn, ''test'', ''write'',');
      A('    [''' + N.ScopeRead + ''', ''' + N.ScopeWrite + ''']);');
      A('  UseTokenAuth(Router);');
    end
    else
    begin
      A('  SetSessions(TSessionStore.Create);');
      A('  UseSessions(Router);');
    end;
    A('  ' + RoutesProc + '(Router);');
    A('  Client := TTestClient.Create(Router);');
    A('end;');
    A('');
    if Api then
    begin
      A('{ A program that asked for JSON, with one of the two tokens. }');
      A('function Reader: TTestClient;');
      A('begin');
      A('  Result := Client.WithHeader(''Accept'', ''application/json'')');
      A('    .WithHeader(''Authorization'', ''Bearer '' + ReadToken);');
      A('end;');
      A('');
      A('function Writer: TTestClient;');
      A('begin');
      A('  Result := Client.WithHeader(''Accept'', ''application/json'')');
      A('    .WithHeader(''Authorization'', ''Bearer '' + WriteToken);');
      A('end;');
      A('');
    end;
    A('function Count: Int64;');
    A('begin');
    A('  Result := TQuery<T' + N.Model + '>.New.Count;');
    A('end;');
    A('');
    if AnyMany then
    begin
      A('{ Ids as the test compares them: 3,7. }');
      A('function IdsOf(const Ids: TArray<Int64>): string;');
      A('var');
      A('  I: Integer;');
      A('begin');
      A('  Result := '''';');
      A('  for I := 0 to High(Ids) do');
      A('  begin');
      A('    if I > 0 then');
      A('      Result := Result + '','';');
      A('    Result := Result + IntToStr(Ids[I]);');
      A('  end;');
      A('end;');
      A('');
    end;
    A('{ The id at the end of a Location: ' + Url + '/7 -> 7. }');
    A('function IdIn(Res: TResponse): Int64;');
    A('var');
    A('  L: string;');
    A('begin');
    A('  L := Res.HeaderValue(''Location'');');
    A('  Result := StrToInt64Def(Copy(L, LastDelimiter(''/'', L) + 1, MaxInt), 0);');
    A('end;');
    A('');

    if CanWrite then
    begin
      { The parents first, then the body that points at them. }
      A('{ A row the rules accept, made through Store, and its id.');
      A('  Everything that follows starts from one of these. }');
      A('function Made: Int64;');
      A('var');
      A('  Res: TResponse;');
      for I := 0 to High(ParentIdx) do
        A('  P' + IntToStr(I) + ': T' + Parents[ParentIdx[I]].Rel.Model + ';');
      A('begin');
      A('  Inc(Seq);');
      for I := 0 to High(ParentIdx) do
      begin
        Par := Parents[ParentIdx[I]];
        A('  P' + IntToStr(I) + ' := T' + Par.Rel.Model + '.Create;');
        for K := 0 to High(Par.Plan.Columns) do
        begin
          PC := Par.Plan.Columns[K];
          if PC.Editable and (not PC.Field.Nullable) and (PC.Field.Kind <> ftReferences) then
            A('  P' + IntToStr(I) + '.' + PC.Field.Prop + ' := ' + SamplePascal(PC) + ';');
        end;
        A('  P' + IntToStr(I) + '.Save;');
      end;
      { The body as an expression: a literal for most columns, Seq for a
        unique one, and the parent's id for a reference. }
      Body := '';
      K := 0;
      for I := 0 to High(Ed) do
      begin
        if Body <> '' then
          Body := Body + ' + ' + PasStr(',');
        Body := Body + ' + ' + PasStr('"' + Ed[I].Field.Column + '":') + ' + ';
        if Ed[I].Field.Kind = ftReferences then
        begin
          if MadeFor(Ed[I].Field.Column) then
          begin
            Body := Body + 'IntToStr(P' + IntToStr(K) + '.Id)';
            Inc(K);
          end
          else
            Body := Body + PasStr('null');
        end
        else
          Body := Body + SampleJsonExpr(Ed[I]);
      end;
      Body := PasStr('{') + Body + ' + ' + PasStr('}');
      if First <> '' then
        A('  LastFirst := ' + SamplePascal(P.Columns[PlanColumnIndex(P, First)]) + ';');
      A('  Res := ' + WR + '.Post(''' + Url + ''', ' + Body + ');');
      if Api then
        A('  AssertStatus(Res, 201, ''a valid ' + N.Human + ' is created'');')
      else
        A('  AssertStatus(Res, 302, ''a valid ' + N.Human + ' is saved, and the browser is sent on'');');
      A('  Result := IdIn(Res);');
      A('end;');
      A('');
    end;

    { ---- the tests ---- }
    A('procedure TestList;');
    A('var');
    A('  Res: TResponse;');
    A('begin');
    A('  Ready;');
    A('  Res := ' + RD + '.Get(''' + Url + ''');');
    A('  AssertStatus(Res, 200, ''the list answers'');');
    if Api then
      A('  AssertContains(Res.Body.ToString, ''"data":['', ''with the rows in data'');')
    else
    begin
      A('  AssertContains(Res.Body.ToString, ''"component":"' + N.PagesDir + '/Index"'',');
      A('    ''with its page'');');
    end;
    A('  Res := ' + RD + '.Get(''' + Url + '?sort=nothing&dir=sideways&page=-1'');');
    A('  AssertStatus(Res, 200, ''and a sort key it does not know falls back, not over'');');
    A('end;');
    A('');
    A('procedure TestMissing;');
    A('var');
    A('  Res: TResponse;');
    A('begin');
    A('  Ready;');
    A('  Res := ' + RD + '.Get(''' + Url + '/0'');');
    A('  AssertStatus(Res, 404, ''a row that is not there is a 404'');');
    if Api then
    begin
      A('  AssertContains(Res.HeaderValue(''Content-Type''), ''application/problem+json'',');
      A('    ''as a problem document'');');
      A('  Res := ' + RD + '.Get(''' + Url + '/abc'');');
    end
    else
      A('  Res := ' + RD + '.Get(''' + Url + '/abc/edit'');');
    A('  AssertStatus(Res, 404, ''and so is a path that is not a number'');');
    A('end;');
    A('');

    if Api then
    begin
      A('{ 401 and 403 are two refusals: no token, and a token that may not. }');
      A('procedure TestTokens;');
      A('var');
      A('  Before: Int64;');
      A('begin');
      A('  Ready;');
      A('  AssertStatus(Client.WithHeader(''Accept'', ''application/json'').Get(''' + Url + '''),');
      A('    401, ''without a token the list is a 401'');');
      A('  Before := Count;');
      A('  AssertStatus(Reader.Post(''' + Url + ''', ''{}''), 403,');
      A('    ''a token that may only read cannot create'');');
      A('  AssertStatus(Reader.Delete(''' + Url + '/1''), 403, ''or delete'');');
      A('  AssertEqual(Count, Before, ''and nothing changed'');');
      A('end;');
      A('');
    end;

    if CanWrite then
    begin
      A('procedure TestStore;');
      A('var');
      A('  Before, Id: Int64;');
      A('  M: T' + N.Model + ';');
      if Api then
        A('  Res: TResponse;');
      A('begin');
      A('  Ready;');
      A('  Before := Count;');
      A('  Id := Made;');
      A('  AssertTrue(Id > 0, ''to the page of the one it made'');');
      A('  AssertEqual(Count, Before + 1, ''one more row'');');
      A('  M := TQuery<T' + N.Model + '>.New.Find(Id);');
      A('  AssertNotNil(M, ''and it can be found'');');
      if Firstmember <> '' then
        A('  AssertEqual(M.' + Firstmember + ', LastFirst, ''with what was sent'');');
      if Api then
      begin
        A('  Res := Reader.Get(''' + Url + '/'' + IntToStr(Id));');
        A('  AssertStatus(Res, 200, ''it can be read back'');');
        A('  AssertContains(Res.Body.ToString, ''"id":'' + IntToStr(Id), ''as itself'');');
        for I := 0 to High(Hidden) do
          A('  AssertNotContains(Res.Body.ToString, ''"' + Hidden[I] + '"'',' + #10 +
            '    ''and ' + Hidden[I] + ', which looks like a secret, is not in it'');');
      end
      else
      begin
        A('  AssertStatus(' + RD + '.Get(''' + Url + '/'' + IntToStr(Id)), 200,');
        A('    ''its page answers'');');
        A('  AssertStatus(' + RD + '.Get(''' + Url + '/'' + IntToStr(Id) + ''/edit''), 200,');
        A('    ''and so does its form'');');
        A('  AssertStatus(' + RD + '.Get(''' + Url + '/new''), 200,');
        A('    ''and the form for a new one'');');
      end;
      A('end;');
      A('');

      if RequiredCol <> '' then
      begin
        A('procedure TestRefused;');
        A('var');
        A('  Before: Int64;');
        A('  Res: TResponse;');
        A('begin');
        A('  Ready;');
        A('  Before := Count;');
        { The references are 0 here: the rules refuse the row before
          anything looks at them. }
        Body := StringReplace(BodyWith(RequiredCol, '""'), '%d', '0', [rfReplaceAll]);
        A('  Res := ' + WR + '.Post(''' + Url + ''', ' + PasStr(Body) + ');');
        if Api then
        begin
          A('  AssertStatus(Res, 422, ''an empty ' + RequiredCol + ' is refused'');');
          A('  AssertContains(Res.HeaderValue(''Content-Type''), ''application/problem+json'',');
          A('    ''as a problem document'');');
          A('  AssertContains(Res.Body.ToString, ''"' + RequiredCol + '":'',');
          A('    ''that names the field, as the column'');');
        end
        else
          A('  AssertStatus(Res, 302, ''an empty ' + RequiredCol + ' is sent back to the form'');');
        A('  AssertEqual(Count, Before, ''and nothing is saved'');');
        A('end;');
        A('');
      end;

      A('procedure TestUpdate;');
      A('var');
      A('  Id: Int64;');
      A('  Res: TResponse;');
      if First <> '' then
        A('  NewFirst: string;');
      if (Firstmember <> '') or (Hidden <> nil) then
        A('  M: T' + N.Model + ';');
      A('begin');
      A('  Ready;');
      A('  Id := Made;');
      { A forged id and created_at, which the model owns, and a forged
        secret, which it maps but the form does not have: the last is what
        only the named-columns FillInto keeps out. }
      Forged := '';
      for I := 0 to High(Hidden) do
        if (Forged = '') and
           (P.Columns[PlanColumnIndex(P, Hidden[I])].Field.Kind in [ftString, ftText]) then
          Forged := Hidden[I];
      if First <> '' then
      begin
        if P.Columns[PlanColumnIndex(P, First)].Field.Unique then
          A('  NewFirst := ''C'' + SeqTail(' +
            IntToStr(Max(P.Columns[PlanColumnIndex(P, First)].Field.Length, 2) - 1) + ');')
        else
          A('  NewFirst := ' + FirstLen('Changed') + ';');
        Body := PasStr('{"' + First + '":"') + ' + NewFirst + ' +
          PasStr('","id":999999,"created_at":"2001-01-01 00:00:00"');
      end
      else
        Body := PasStr('{"id":999999');
      if Forged <> '' then
        Body := Body + ' + ' + PasStr(',"' + Forged + '":"forged"');
      Body := Body + ' + ' + PasStr('}');
      if Api then
      begin
        A('  Res := Writer.Send(''PATCH'', ''' + Url + '/'' + IntToStr(Id), ' + Body +
          ', ''application/json'');');
        A('  AssertStatus(Res, 200, ''a change answers with the row as it is now'');');
      end
      else
      begin
        A('  Res := ' + WR + '.Put(''' + Url + '/'' + IntToStr(Id), ' + Body + ');');
        A('  AssertStatus(Res, 303, ''a save answers 303, so the browser does not repeat the PUT'');');
      end;
      if Firstmember <> '' then
      begin
        A('  M := TQuery<T' + N.Model + '>.New.Find(Id);');
        A('  AssertNotNil(M, ''the id in the body did not move it'');');
        A('  AssertEqual(M.' + Firstmember + ', NewFirst, ''the change is saved'');');
        if P.HasTimestamps then
          A('  AssertTrue(M.CreatedAt > EncodeDate(2002, 1, 1),' + #10 +
            '    ''and created_at, which the model sets, is not set from the body'');');
      end;
      if Forged <> '' then
      begin
        if Firstmember = '' then
          A('  M := TQuery<T' + N.Model + '>.New.Find(Id);');
        A('  AssertTrue(M.' + P.Columns[PlanColumnIndex(P, Forged)].Field.Prop +
          ' <> ''forged'',' + #10 + '    ''and ' + Forged +
          ', which the form does not have, is not set from the body either'');');
      end;
      A('end;');
      A('');

      for I := 0 to High(Manys) do
        if ManyMakeable(Manys[I]) then
        begin
          Mn := Manys[I];
          A('{ The boxes for ' + Mn.Rel.InputKey + ': what is ticked is attached, what is not');
          A('  is detached, a body without the key leaves them as they are, and an');
          A('  id to nothing is refused on the field with nothing changed. }');
          A('procedure Test' + Mn.Rel.Name + ';');
          A('var');
          A('  Id: Int64;');
          A('  Res: TResponse;');
          A('  T1, T2: T' + Mn.Rel.Model + ';');
          A('');
          A('  function Change(const Body: string): TResponse;');
          A('  begin');
          if Api then
            A('    Result := Writer.Send(''PATCH'', ''' + Url + '/'' + IntToStr(Id), Body, ''application/json'');')
          else
            A('    Result := ' + WR + '.Put(''' + Url + '/'' + IntToStr(Id), Body);');
          A('  end;');
          A('');
          A('  function Attached: string;');
          A('  begin');
          A('    Result := IdsOf(TQuery<T' + N.Model + '>.New.Find(Id).RelatedIds(' +
            PasStr(Mn.Rel.Name) + '));');
          A('  end;');
          A('');
          A('begin');
          A('  Ready;');
          for K := 1 to 2 do
          begin
            A('  Inc(Seq);');
            A('  T' + IntToStr(K) + ' := T' + Mn.Rel.Model + '.Create;');
            for J := 0 to High(Mn.Plan.Columns) do
            begin
              PC := Mn.Plan.Columns[J];
              if PC.Editable and (not PC.Field.Nullable) and (PC.Field.Kind <> ftReferences) then
                A('  T' + IntToStr(K) + '.' + PC.Field.Prop + ' := ' + SamplePascal(PC) + ';');
            end;
            A('  T' + IntToStr(K) + '.Save;');
          end;
          A('  Id := Made;');
          A('  AssertEqual(Attached, '''', ''one made without ' + Mn.Rel.InputKey + ' has none'');');
          A('  Res := Change(''{"' + Mn.Rel.InputKey + '":['' + IntToStr(T1.Id) + '','' + IntToStr(T2.Id) + '']}'');');
          if Api then
            A('  AssertStatus(Res, 200, ''the ticked ones are saved'');')
          else
            A('  AssertStatus(Res, 303, ''the ticked ones are saved'');');
          A('  AssertEqual(Attached, IntToStr(T1.Id) + '','' + IntToStr(T2.Id), ''and attached'');');
          if Api then
            A('  AssertContains(Res.Body.ToString, ''"' + SnakeCase(Mn.Rel.Name) +
              '":['', ''and the reply has them'');');
          A('  Change(''{}'');');
          A('  AssertEqual(Attached, IntToStr(T1.Id) + '','' + IntToStr(T2.Id),');
          A('    ''a body without ' + Mn.Rel.InputKey + ' leaves them as they are'');');
          A('  Change(''{"' + Mn.Rel.InputKey + '":['' + IntToStr(T2.Id) + '']}'');');
          A('  AssertEqual(Attached, IntToStr(T2.Id), ''the one left out is detached'');');
          A('  Res := Change(''{"' + Mn.Rel.InputKey + '":[999999999]}'');');
          if Api then
          begin
            A('  AssertStatus(Res, 422, ''an id to nothing is refused'');');
            A('  AssertContains(Res.Body.ToString, ''"' + Mn.Rel.InputKey + '":'', ''on the field'');');
          end
          else
            { 303: the edit is a PUT, and a redirect after one has to be
              303 or the browser repeats the PUT. }
            A('  AssertStatus(Res, 303, ''an id to nothing is sent back to the form'');');
          A('  AssertEqual(Attached, IntToStr(T2.Id), ''and nothing changed'');');
          A('  Change(''{"' + Mn.Rel.InputKey + '":[]}'');');
          A('  AssertEqual(Attached, '''', ''and an empty list is none'');');
          A('  Change(''{"' + Mn.Rel.InputKey + '":['' + IntToStr(T1.Id) + '']}'');');
          A('  AssertContains(' + RD + '.Get(''' + Url + '/'' + IntToStr(Id)).Body.ToString,');
          A('    ''"' + SnakeCase(Mn.Rel.Name) + '":[{'', ''its page carries them'');');
          A('end;');
          A('');
        end;

      A('procedure TestRemove;');
      A('var');
      A('  Id: Int64;');
      A('begin');
      A('  Ready;');
      A('  Id := Made;');
      if Api then
      begin
        A('  AssertStatus(Writer.Delete(''' + Url + '/'' + IntToStr(Id)), 204,');
        A('    ''a delete answers 204, with nothing in it'');');
        A('  AssertStatus(Reader.Get(''' + Url + '/'' + IntToStr(Id)), 404,');
        A('    ''and the row is not there to read'');');
      end
      else
      begin
        A('  AssertStatus(' + WR + '.Delete(''' + Url + '/'' + IntToStr(Id)), 303,');
        A('    ''a delete answers 303'');');
      end;
      A('  AssertNil(TQuery<T' + N.Model + '>.New.Find(Id), ''and the row is gone'');');
      A('end;');
      A('');
    end;

    A('procedure ' + TestsProc + ';');
    A('begin');
    if Api then
      A('  Group(''' + Capital(N.HumanPlural) + ', as JSON'');')
    else
      A('  Group(''' + Capital(N.HumanPlural) + ''');');
    A('  Test(''the list answers, whatever it is asked to sort by'', @TestList);');
    A('  Test(''a row that is not there is a 404'', @TestMissing);');
    if Api then
      A('  Test(''no token is a 401, and a token without the scope a 403'', @TestTokens);');
    if CanWrite then
    begin
      A('  Test(''a new one is saved and can be read back'', @TestStore);');
      if RequiredCol <> '' then
        A('  Test(''what the rules refuse is not saved'', @TestRefused);');
      A('  Test(''an edit is saved, and only the fields the form has'', @TestUpdate);');
      for I := 0 to High(Manys) do
        if ManyMakeable(Manys[I]) then
          A('  Test(''' + LowerCase(LabelOf(Manys[I].Rel.Table)) +
            ': ticked is attached, left out is detached'', @Test' + Manys[I].Rel.Name + ');');
      A('  Test(''a delete removes it'', @TestRemove);');
    end
    else
    begin
      A('  { Nothing that writes is tested: ' + Why + '.');
      A('    Once that is not so, add them here. }');
    end;
    A('end;');
    A('');
    A('finalization');
    A('  Client.Free;');
    A('  Router.Free;');
    A('  Conn.Free;');
    A('  Arena.Free;');
    A('');
    A('end.');
    Result := B.Text;
  finally
    B.Free;
  end;
end;

const
  TestsMarkerUses = '  Askr.Testing,';
  TestsMarkerRun = '  RunTestsAndHalt;';

function TestProgramText(const TestUnit, TestsProc: string): string;
begin
  Result :=
    '{ The tests `askr test` runs. `askr make resource` adds its tests at' + #10 +
    '  the two lines it recognises below: the uses after Askr.Testing, the' + #10 +
    '  call before RunTestsAndHalt. }' + #10 +
    'program app_tests;' + #10 + #10 +
    '{$mode Delphi}{$H+}' + #10 + #10 +
    'uses' + #10 +
    '{$IFDEF UNIX}' + #10 +
    '  cthreads,' + #10 +
    '{$ENDIF}' + #10 +
    TestsMarkerUses + #10 +
    '  ' + TestUnit + ';' + #10 + #10 +
    'begin' + #10 +
    '  ' + TestsProc + ';' + #10 +
    TestsMarkerRun + #10 +
    'end.' + #10;
end;

{ ------------------------------------------------------------ files -- }

procedure AddFile(var F: TGenFiles; const Path, Content: string);
begin
  SetLength(F, Length(F) + 1);
  F[High(F)].Path := Path;
  F[High(F)].Content := Content;
end;

function ResourceFiles(const P: TResourcePlan; const Parents: TParentInfos;
  const Children: TChildInfos; const Manys: TManyInfos;
  WithModel, Web, Api: Boolean): TGenFiles;
var
  N: TResourceNames;
  Pages, Why: string;
begin
  Result := nil;
  N := ResourceNamesOf(P);
  Pages := 'frontend/src/pages/' + N.PagesDir + '/';
  if WithModel then
    AddFile(Result, 'app/Models/' + N.ModelUnit + '.pas', ModelText(P, Manys));
  if Web then
  begin
    AddFile(Result, 'app/Http/' + N.CtlUnit + '.pas', ControllerText(P, Parents, Children, Manys));
    AddFile(Result, Pages + 'Index.svelte', IndexText(P));
    AddFile(Result, Pages + 'Show.svelte', ShowText(P, Parents, Children, Manys));
    AddFile(Result, Pages + 'Add.svelte', FormPageText(P, Parents, Manys, False));
    AddFile(Result, Pages + 'Edit.svelte', FormPageText(P, Parents, Manys, True));
    AddFile(Result, Pages + 'Fields.svelte', FieldsText(P, Parents, Manys));
    AddFile(Result, 'tests/' + N.TestUnit + '.pas', TestUnitText(P, Parents, Manys, False, Why));
  end;
  if Api then
  begin
    AddFile(Result, 'app/Http/' + N.ApiCtlUnit + '.pas', ApiControllerText(P, Manys));
    AddFile(Result, 'tests/' + N.ApiTestUnit + '.pas', TestUnitText(P, Parents, Manys, True, Why));
  end;
end;

{ ----------------------------------------------------- the command -- }

function HasLine(L: TStringList; const S: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to L.Count - 1 do
    if Trim(L[I]) = Trim(S) then
      Exit(True);
  Result := False;
end;

{ app.lpr at the lines `askr new` wrote -- the same markers make auth
  uses: the uses line of the home controller, and the /demo route. Each
  line goes in only when it is not there, so a second resource does not
  add UseOpenApi twice. False when the markers are gone. }
function InstallInApp(const Root: string; const UsesLines,
  RouteLines: array of string): Boolean;
const
  MarkerUses = '  App.Http.HomeController;';
  MarkerRoutes = '  R.Get(''/demo'', Home.Demo);';
var
  L: TStringList;
  Path_: string;
  I, IdxUses, IdxRoutes: Integer;
  Changed: Boolean;
begin
  Result := False;
  Path_ := IncludeTrailingPathDelimiter(Root) + 'app.lpr';
  if not FileExists(Path_) then
    Exit;
  L := TStringList.Create;
  try
    L.LoadFromFile(Path_);
    IdxUses := -1;
    IdxRoutes := -1;
    for I := 0 to L.Count - 1 do
    begin
      if L[I] = MarkerUses then
        IdxUses := I;
      if L[I] = MarkerRoutes then
        IdxRoutes := I;
    end;
    if (IdxUses < 0) or (IdxRoutes < 0) then
      Exit(False);
    Changed := False;
    { From the back, so the first insertion does not move the second. }
    for I := High(RouteLines) downto 0 do
      if not HasLine(L, RouteLines[I]) then
      begin
        L.Insert(IdxRoutes + 1, RouteLines[I]);
        Changed := True;
      end;
    for I := 0 to High(UsesLines) do
      if not HasLine(L, UsesLines[I]) then
      begin
        L.Insert(IdxUses, UsesLines[I]);
        Inc(IdxUses);
        Changed := True;
      end;
    if Changed then
    begin
      L.SaveToFile(Path_);
      WriteLn('  edited app.lpr');
    end;
    Result := True;
  finally
    L.Free;
  end;
end;

{ A file this command owns the markers of: written when it is not there,
  edited at its markers when it is, and left alone -- False -- when they
  are gone. Each line goes in after its marker, once. }
function InstallAtMarkers(const Path_, FreshText: string;
  const Markers, Lines: array of string): Boolean;
var
  L: TStringList;
  I, J, Idx: Integer;
  Changed: Boolean;
begin
  if not FileExists(Path_) then
  begin
    Emit(Path_, FreshText);
    Exit(True);
  end;
  Result := False;
  L := TStringList.Create;
  try
    L.LoadFromFile(Path_);
    Changed := False;
    for I := 0 to High(Markers) do
    begin
      Idx := -1;
      for J := 0 to L.Count - 1 do
        if L[J] = Markers[I] then
          Idx := J;
      if Idx < 0 then
        Exit(False);
      if not HasLine(L, Lines[I]) then
      begin
        L.Insert(Idx + 1, Lines[I]);
        Changed := True;
      end;
    end;
    if Changed then
    begin
      L.SaveToFile(Path_);
      WriteLn('  edited ', ExtractFileName(Path_));
    end;
    Result := True;
  finally
    L.Free;
  end;
end;

{ tests/app_tests.lpr. The uses goes after Askr.Testing, the call before
  RunTestsAndHalt -- the one marker a line goes in front of. }
function InstallTests(const Root, TestUnit, TestsProc: string): Boolean;
var
  L: TStringList;
  Path_: string;
  I, IdxUses, IdxRun: Integer;
begin
  Path_ := IncludeTrailingPathDelimiter(Root) + 'tests/app_tests.lpr';
  if not FileExists(Path_) then
  begin
    Emit(Path_, TestProgramText(TestUnit, TestsProc));
    Exit(True);
  end;
  Result := False;
  L := TStringList.Create;
  try
    L.LoadFromFile(Path_);
    if HasLine(L, TestsProc + ';') then
      Exit(True);
    IdxUses := -1;
    IdxRun := -1;
    for I := 0 to L.Count - 1 do
    begin
      if L[I] = TestsMarkerUses then
        IdxUses := I;
      if L[I] = TestsMarkerRun then
        IdxRun := I;
    end;
    if (IdxUses < 0) or (IdxRun < 0) then
      Exit(False);
    L.Insert(IdxRun, '  ' + TestsProc + ';');
    L.Insert(IdxUses + 1, '  ' + TestUnit + ',');
    L.SaveToFile(Path_);
    WriteLn('  edited tests/app_tests.lpr');
    Result := True;
  finally
    L.Free;
  end;
end;

procedure SayTestLines(const TestUnit, TestsProc: string);
begin
  WriteLn('');
  WriteLn('tests/app_tests.lpr is there without the lines this recognises.');
  WriteLn('Add these yourself:');
  WriteLn('  uses   ' + TestUnit + ';');
  WriteLn('  and, before RunTestsAndHalt:  ' + TestsProc + ';');
end;

function ParentsOf(Schema: TDbSchema; const P: TResourcePlan;
  const Root: string): TParentInfos;
var
  I, K: Integer;
  Base: string;
begin
  Base := IncludeTrailingPathDelimiter(Root);
  Result := nil;
  for I := 0 to High(P.Relations) do
    if P.Relations[I].Kind = prBelongsTo then
    begin
      SetLength(Result, Length(Result) + 1);
      with Result[High(Result)] do
      begin
        Rel := P.Relations[I];
        Plan := PlanResource(Schema, Rel.Model, Rel.Table);
        Available := (Length(Plan.Problems) = 0) and
          FileExists(Base + 'app/Models/App.Models.' + Rel.Model + '.pas');
        LabelColumn := Plan.DefaultSort;
        LabelMember := '';
        K := PlanColumnIndex(Plan, LabelColumn);
        if K >= 0 then
          LabelMember := Plan.Columns[K].Member;
        if LabelMember = '' then
          Available := False;
        SchemaVar := TableConstName(Rel.Table);
        SchemaUnit := 'App.Schema.' + PascalCase(Rel.Table);
      end;
    end;
end;

function ChildrenOf(Schema: TDbSchema; const P: TResourcePlan;
  const Root: string): TChildInfos;
var
  I, K: Integer;
  Base: string;
  Plan: TResourcePlan;
begin
  Base := IncludeTrailingPathDelimiter(Root);
  Result := nil;
  for I := 0 to High(P.Relations) do
    if P.Relations[I].Kind = prHasMany then
    begin
      SetLength(Result, Length(Result) + 1);
      with Result[High(Result)] do
      begin
        Rel := P.Relations[I];
        Plan := PlanResource(Schema, Rel.Model, Rel.Table);
        Available := (Length(Plan.Problems) = 0) and
          FileExists(Base + 'app/Models/App.Models.' + Rel.Model + '.pas');
        LabelColumn := Plan.DefaultSort;
        LabelMember := '';
        FkMember := '';
        K := PlanColumnIndex(Plan, LabelColumn);
        if K >= 0 then
          LabelMember := Plan.Columns[K].Member;
        K := PlanColumnIndex(Plan, Rel.ForeignKey);
        if K >= 0 then
          FkMember := Plan.Columns[K].Member;
        if (LabelMember = '') or (FkMember = '') then
          Available := False;
        SchemaVar := TableConstName(Rel.Table);
        SchemaUnit := 'App.Schema.' + PascalCase(Rel.Table);
        Linked := FileExists(Base + 'app/Http/App.Http.' + PascalCase(Rel.Table) +
          'Controller.pas');
        Url := '/' + StringReplace(Rel.Table, '_', '-', [rfReplaceAll]);
      end;
    end;
end;

function MakeResource(const Root: string; Schema: TDbSchema;
  const ModelName, Table, Title: string; Force, Web, Api: Boolean): Boolean;
var
  P: TResourcePlan;
  N: TResourceNames;
  Parents: TParentInfos;
  Manys: TManyInfos;
  Files: TGenFiles;
  Paths: array of string;
  I: Integer;
  ModelPath, Base: string;
  WithModel: Boolean;
  Opts: TCodegenOptions;
  Gen: TGeneratedFiles;
  Changed, Removed: TStringArray;
  Why: string;
begin
  Result := False;
  Base := IncludeTrailingPathDelimiter(Root);
  P := PlanResource(Schema, ModelName, Table);
  if Length(P.Problems) > 0 then
  begin
    for I := 0 to High(P.Problems) do
      WriteLn(P.Problems[I]);
    Exit;
  end;
  N := ResourceNamesOf(P);

  Parents := ParentsOf(Schema, P, Root);

  ModelPath := Base + 'app/Models/' + N.ModelUnit + '.pas';
  WithModel := not FileExists(ModelPath);
  Manys := ManysOf(Schema, P, Root, WithModel);
  Files := ResourceFiles(P, Parents, ChildrenOf(Schema, P, Root), Manys,
    WithModel, Web, Api);

  Paths := nil;
  for I := 0 to High(Files) do
  begin
    SetLength(Paths, Length(Paths) + 1);
    Paths[High(Paths)] := Base + Files[I].Path;
  end;
  if RefuseExisting(Paths, Force) then
    Exit;

  WriteLn(PlanText(P));

  { The typed columns first: the controller does not compile without
    them, and they are exactly what askr schema writes. }
  Opts := DefaultCodegenOptions;
  Opts.OutputDir := Base + 'app/Schema';
  RegenerateSchema(Schema, Opts, Gen, Changed, Removed);
  for I := 0 to High(Changed) do
    WriteLn('  schema  app/Schema/' + ExtractFileName(Changed[I]));
  for I := 0 to High(Removed) do
    WriteLn('  schema  app/Schema/' + Removed[I] + '  (removed: no such table)');

  if not WithModel then
    WriteLn('  using  app/Models/' + N.ModelUnit + '.pas, which is there');
  for I := 0 to High(Files) do
    Emit(Base + Files[I].Path, Files[I].Content);

  if Web then
  begin
    if not InstallInApp(Root, ['  ' + N.CtlUnit + ','], ['  ' + N.RoutesProc + '(R);']) then
    begin
      WriteLn('');
      WriteLn('Could not find the markers in app.lpr. Add these yourself:');
      WriteLn('  uses   ' + N.CtlUnit + ';');
      WriteLn('  and, with the other routes:  ' + N.RoutesProc + '(R);');
    end;
    if not InstallTests(Root, N.TestUnit, N.TestsProc) then
      SayTestLines(N.TestUnit, N.TestsProc);
  end;

  if Api then
  begin
    if not InstallInApp(Root,
         ['  Askr.OpenApi, App.Http.ApiDoc,', '  ' + N.ApiCtlUnit + ','],
         ['  ' + N.ApiRoutesProc + '(R);',
          '  { GET /openapi.json, and askr openapi --check. See App.Http.ApiDoc. }',
          '  UseOpenApi(R, @AppApiDoc);']) then
    begin
      WriteLn('');
      WriteLn('Could not find the markers in app.lpr. Add these yourself:');
      WriteLn('  uses   Askr.OpenApi, App.Http.ApiDoc, ' + N.ApiCtlUnit + ';');
      WriteLn('  and, with the other routes:  ' + N.ApiRoutesProc + '(R);');
      WriteLn('                               UseOpenApi(R, @AppApiDoc);');
    end;
    if not InstallAtMarkers(Base + 'app/Http/App.Http.ApiDoc.pas',
         ApiDocUnitText(N, Title),
         [ApiDocUsesMarker, ApiDocCallMarker],
         ['  ' + N.ApiCtlUnit + ',', '  ' + N.ApiDocProc + '(D);']) then
    begin
      WriteLn('');
      WriteLn('app/Http/App.Http.ApiDoc.pas is there without the lines this');
      WriteLn('recognises. Add these yourself:');
      WriteLn('  uses   ' + N.ApiCtlUnit + ';');
      WriteLn('  and, in AppApiDoc:  ' + N.ApiDocProc + '(D);');
    end;
    if not InstallTests(Root, N.ApiTestUnit, N.ApiTestsProc) then
      SayTestLines(N.ApiTestUnit, N.ApiTestsProc);
  end;

  TestUnitText(P, Parents, Manys, Api, Why);
  WriteLn('');
  for I := 0 to High(Manys) do
    if not Manys[I].Available then
      WriteLn(Manys[I].Why);
  if Why <> '' then
    WriteLn('The test does not create, edit or delete: ' + Why + '.');
  WriteLn('Next: askr build, then askr test.');
  if Web then
    WriteLn('The pages are under frontend/src/pages/' + N.PagesDir + ', and ' +
      N.Url + ' lists them.');
  if Api then
  begin
    WriteLn(N.ApiUrl + ' needs a token:  askr token:issue <user-id> <name> --scopes=' +
      N.ScopeRead + ',' + N.ScopeWrite);
    WriteLn('askr openapi --check says whether the document still describes the routes.');
  end;
  Result := True;
end;

end.
