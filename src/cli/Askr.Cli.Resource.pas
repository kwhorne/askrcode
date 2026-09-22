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
  end;

function ResourceNamesOf(const P: TResourcePlan): TResourceNames;

{ Every file a resource is, from its plan. Writes nothing, so a test can
  hold the text; WithModel adds the model unit. }
function ResourceFiles(const P: TResourcePlan; const Parents: TParentInfos;
  WithModel: Boolean): TGenFiles;

{ The tables P points at, as its form needs them: a select for each
  whose model is in Root, a number for the rest. }
function ParentsOf(Schema: TDbSchema; const P: TResourcePlan;
  const Root: string): TParentInfos;

{ A database default as a JavaScript value a form can start with, or ''
  when it is not a plain literal. Exposed for the test: the three
  databases report the same default three ways. }
function DefaultLiteral(const PC: TPlanColumn): string;

{ The whole command: plan the table, refuse what cannot be one, write the
  schema units and the files, and put the routes and the tests in place.
  Prints what it did. Returns False when it refused, having said why. }
function MakeResource(const Root: string; Schema: TDbSchema;
  const ModelName, Table: string; Force: Boolean): Boolean;

implementation

uses
  Askr.Urd.Model, Askr.Cli.Scaffold;

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

{ ------------------------------------------------------- controller -- }

function ControllerText(const P: TResourcePlan;
  const Parents: TParentInfos): string;
var
  B: TStringList;
  N: TResourceNames;
  I: Integer;
  PC: TPlanColumn;
  Ed: TPlanColumns;
  Uses_, Only, Opt: string;
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
  end;

begin
  N := ResourceNamesOf(P);
  Ed := EditableOf(P);
  B := TStringList.Create;
  try
    Uses_ := '  ' + N.ModelUnit + ', ' + N.SchemaUnit;
    for I := 0 to High(Parents) do
      if Parents[I].Available then
        Uses_ := Uses_ + ',' + #10 + '  App.Models.' + Parents[I].Rel.Model +
          ', ' + Parents[I].SchemaUnit;

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

    { The columns a request may set. Everything else a client adds to the
      body is ignored: the one-argument FillInto fills whatever the model
      maps, created_at and hidden columns included. }
    Only := '';
    for I := 0 to High(Ed) do
    begin
      if Only <> '' then
        Only := Only + ',' + #10 + '    ';
      Only := Only + N.SchemaVar + '.' + Ed[I].Member + '.Name';
    end;
    A('{ The columns the form has, and the only ones a request may set. The');
    A('  one-argument FillInto fills anything the model maps, so a client that');
    A('  added created_at to the body would have set it. }');
    A('procedure Fill(Req: TRequest; M: T' + N.Model + ');');
    A('begin');
    if Only = '' then
      A('  { The table has no column a form can set. }')
    else
      A('  Req.FillInto(M, [' + Only + ']);');
    A('end;');
    A('');

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
    A('  G := TGrid<T' + N.Model + '>.New;');
    A('  G.Read(Req);');
    for I := 0 to High(P.Columns) do
    begin
      PC := P.Columns[I];
      if PC.Sortable and PC.Listed then
        A('  G.Sortable(''' + PC.Field.Column + ''', ' + N.SchemaVar + '.' +
          PC.Member + ');');
    end;
    Opt := '';
    for I := 0 to High(P.Columns) do
      if P.Columns[I].Searchable then
      begin
        if Opt <> '' then
          Opt := Opt + ', ';
        Opt := Opt + N.SchemaVar + '.' + P.Columns[I].Member;
      end;
    if Opt <> '' then
      A('  G.Searchable([' + Opt + ']);');
    A('  G.DefaultSort(''' + P.DefaultSort + ''');');
    A('  G.PerPage(25, 200);');
    A('  Result := Inertia(''' + N.PagesDir + '/Index'',');
    A('    [''rows'', G.Rows(TQuery<T' + N.Model + '>.New), ''grid'', G]);');
    A('end;');
    A('');

    { ---- Show ---- }
    A('function ' + N.CtlClass + '.Show(Req: TRequest): TResponse;');
    A('var');
    A('  M: T' + N.Model + ';');
    A('begin');
    A('  M := Find(Req);');
    A('  if M = nil then');
    A('    Exit(NotFound);');
    Opt := '';
    for I := 0 to High(Parents) do
      if Parents[I].Available then
        Opt := Opt + ',' + #10 + '     ' + PasStr(SnakeCase(Parents[I].Rel.Name)) +
          ', TQuery<T' + Parents[I].Rel.Model + '>.New.Find(M.' +
          P.Columns[PlanColumnIndex(P, Parents[I].Rel.ForeignKey)].Field.Prop + ')';
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
    A('begin');
    A('  M := T' + N.Model + '.Create;');
    A('  Fill(Req, M);');
    A('  if not M.Validate then');
    A('    Exit(BackWithErrors(M.Errors, ''' + N.Url + '/new''));');
    A('  M.Save;');
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
      OptionProps + ']);');
    A('end;');
    A('');

    { ---- Update ---- }
    A('function ' + N.CtlClass + '.Update(Req: TRequest): TResponse;');
    A('var');
    A('  M: T' + N.Model + ';');
    A('begin');
    A('  M := Find(Req);');
    A('  if M = nil then');
    A('    Exit(NotFound);');
    A('  Fill(Req, M);');
    A('  if not M.Validate then');
    A('    Exit(BackWithErrors(M.Errors, ''' + N.Url + '/'' + IntToStr(M.Id) + ''/edit''));');
    A('  M.Save;');
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

{ ------------------------------------------------------------ model -- }

function ModelText(const P: TResourcePlan): string;
var
  N: TResourceNames;
  Fields: TFieldSpecs;
  Intro, Hidden: TStringArray;
  I: Integer;
  PC: TPlanColumn;
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
  Result := ModelUnitText(N.Model, Intro, Fields, P.HasTimestamps,
    P.HasSoftDeletes, DescribeLinesOf(P), RuleLinesOf(P), Hidden,
    N.SchemaUnit, N.SchemaVar);
end;

{ ------------------------------------------------------------ pages -- }

const
  PagesNote =
    '<!-- Written by askr make resource. Not typed against the table: a' + #10 +
    '     column renamed later is a compile error in the controller and a' + #10 +
    '     blank cell here. -->';

function FieldsText(const P: TResourcePlan; const Parents: TParentInfos): string;
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
    Result := B.Text;
  finally
    B.Free;
  end;
end;

function IndexText(const P: TResourcePlan): string;
var
  B: TStringList;
  N: TResourceNames;
  I: Integer;
  PC: TPlanColumn;
  Link, Extra: string;

  procedure A(const S: string);
  begin
    B.Add(S);
  end;

begin
  N := ResourceNamesOf(P);
  Link := FirstStringOf(P);
  if Link = '' then
    Link := P.PrimaryKey;
  B := TStringList.Create;
  try
    A(PagesNote);
    A('<script>');
    A('  import { router, Link } from ''@inertiajs/svelte''');
    A('  import { Heading, Button, DataGrid } from ''@askrcode/lauf''');
    A('  import Layout from ''../../Layout.svelte''');
    A('');
    A('  let { rows = [], grid = null } = $props()');
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

function ShowText(const P: TResourcePlan; const Parents: TParentInfos): string;
var
  B: TStringList;
  N: TResourceNames;
  I: Integer;
  PC: TPlanColumn;
  Col, Props, Rel: string;
  Par: TParentInfo;

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
    A(PagesNote);
    A('<script>');
    A('  import { router } from ''@inertiajs/svelte''');
    A('  import { Heading, Button } from ''@askrcode/lauf''');
    A('  import Layout from ''../../Layout.svelte''');
    A('');
    A('  let { ' + Props + ' } = $props()');
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
        else
          A('      <dd>{shown(' + N.Prop + '.' + Col + ')}</dd>');
      end;
      A('    </div>');
    end;
    A('  </dl>');
    A('  <p class="mt-8"><a href="' + N.Url + '" class="underline-offset-2 hover:underline">All ' +
      N.HumanPlural + '</a></p>');
    A('</Layout>');
    Result := B.Text;
  finally
    B.Free;
  end;
end;

function FormPageText(const P: TResourcePlan; const Parents: TParentInfos;
  Editing: Boolean): string;
var
  B: TStringList;
  N: TResourceNames;
  I: Integer;
  Props, Pass, Title: string;

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

function TestUnitText(const P: TResourcePlan; const Parents: TParentInfos;
  out Why: string): string;
var
  B: TStringList;
  N: TResourceNames;
  Ed: TPlanColumns;
  I, K: Integer;
  PC: TPlanColumn;
  Body, Args, First, Firstmember, RequiredCol, Uses_: string;
  CanWrite: Boolean;
  Par: TParentInfo;
  ParentIdx: array of Integer;

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

begin
  N := ResourceNamesOf(P);
  Ed := EditableOf(P);
  Why := '';

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
    Uses_ := '  ' + N.CtlUnit + ', ' + N.ModelUnit;
    for I := 0 to High(ParentIdx) do
      Uses_ := Uses_ + ', App.Models.' + Parents[ParentIdx[I]].Rel.Model;

    A('{ Every action of ' + N.CtlUnit + ', through the router.');
    A('');
    A('  Written by askr make resource. The database is TEST_DATABASE_URL, and');
    A('  sqlite::memory: when that is not set, with the migrations run first:');
    A('  a test that wrote into the database you develop against would leave');
    A('  its rows there. Pending migrations are run on TEST_DATABASE_URL too,');
    A('  so point it at a database that is only for this. }');
    A('unit ' + N.TestUnit + ';');
    A('');
    A('{$mode Delphi}{$H+}');
    A('');
    A('interface');
    A('');
    A('procedure ' + N.TestsProc + ';');
    A('');
    A('implementation');
    A('');
    A('uses');
    A('  SysUtils, Askr.Core.Arena, Askr.Core.Env, Askr.Testing,');
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
    A('');
    A('{ Once for all of them: the database, the migrations, and a router with');
    A('  sessions -- BackWithErrors keeps the errors there -- and this');
    A('  resource''s routes, from the same procedure app.lpr calls. }');
    A('procedure Ready;');
    A('var');
    A('  M: TMigrator;');
    A('begin');
    A('  if Client <> nil then');
    A('    Exit;');
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
    A('  SetSessions(TSessionStore.Create);');
    A('  Router := TRouter.Create;');
    A('  UseSessions(Router);');
    A('  ' + N.RoutesProc + '(Router);');
    A('  Client := TTestClient.Create(Router);');
    A('end;');
    A('');
    A('function Count: Int64;');
    A('begin');
    A('  Result := TQuery<T' + N.Model + '>.New.Count;');
    A('end;');
    A('');
    A('{ The id at the end of a Location: /' + P.Table + '/7 -> 7. }');
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
      Body := BodyWith('', '');
      Args := '';
      { One %d per reference, in the order they are in the body. }
      K := 0;
      for I := 0 to High(Ed) do
        if (Ed[I].Field.Kind = ftReferences) and MadeFor(Ed[I].Field.Column) then
        begin
          if Args <> '' then
            Args := Args + ', ';
          Args := Args + 'P' + IntToStr(K) + '.Id';
          Inc(K);
        end;
      if Args = '' then
        A('  Res := Client.AsInertia.Post(''' + N.Url + ''', ' + PasStr(Body) + ');')
      else
        A('  Res := Client.AsInertia.Post(''' + N.Url + ''', Format(' + PasStr(Body) +
          ', [' + Args + ']));');
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
    A('  Res := Client.AsInertia.Get(''' + N.Url + ''');');
    A('  AssertStatus(Res, 200, ''the list answers'');');
    A('  AssertContains(Res.Body.ToString, ''"component":"' + N.PagesDir + '/Index"'',');
    A('    ''with its page'');');
    A('  Res := Client.AsInertia.Get(''' + N.Url + '?sort=nothing&dir=sideways&page=-1'');');
    A('  AssertStatus(Res, 200, ''and a sort key it does not know falls back, not over'');');
    A('end;');
    A('');
    A('procedure TestMissing;');
    A('var');
    A('  Res: TResponse;');
    A('begin');
    A('  Ready;');
    A('  Res := Client.AsInertia.Get(''' + N.Url + '/0'');');
    A('  AssertStatus(Res, 404, ''a row that is not there is a 404'');');
    A('  Res := Client.AsInertia.Get(''' + N.Url + '/abc/edit'');');
    A('  AssertStatus(Res, 404, ''and so is a path that is not a number'');');
    A('end;');
    A('');

    if CanWrite then
    begin
      A('procedure TestStore;');
      A('var');
      A('  Before, Id: Int64;');
      A('  M: T' + N.Model + ';');
      A('begin');
      A('  Ready;');
      A('  Before := Count;');
      A('  Id := Made;');
      A('  AssertTrue(Id > 0, ''to the page of the one it made'');');
      A('  AssertEqual(Count, Before + 1, ''one more row'');');
      A('  M := TQuery<T' + N.Model + '>.New.Find(Id);');
      A('  AssertNotNil(M, ''and it can be found'');');
      if Firstmember <> '' then
        A('  AssertEqual(M.' + Firstmember + ', ' +
          PasStr(Copy('Sample', 1, P.Columns[PlanColumnIndex(P, First)].Field.Length)) +
          ', ''with what was sent'');');
      A('  AssertStatus(Client.AsInertia.Get(''' + N.Url + '/'' + IntToStr(Id)), 200,');
      A('    ''its page answers'');');
      A('  AssertStatus(Client.AsInertia.Get(''' + N.Url + '/'' + IntToStr(Id) + ''/edit''), 200,');
      A('    ''and so does its form'');');
      A('  AssertStatus(Client.AsInertia.Get(''' + N.Url + '/new''), 200,');
      A('    ''and the form for a new one'');');
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
        A('  Res := Client.AsInertia.Post(''' + N.Url + ''', ' + PasStr(Body) + ');');
        A('  AssertStatus(Res, 302, ''an empty ' + RequiredCol + ' is sent back to the form'');');
        A('  AssertEqual(Count, Before, ''and nothing is saved'');');
        A('end;');
        A('');
      end;

      A('procedure TestUpdate;');
      A('var');
      A('  Id: Int64;');
      A('  Res: TResponse;');
      if Firstmember <> '' then
        A('  M: T' + N.Model + ';');
      A('begin');
      A('  Ready;');
      A('  Id := Made;');
      if First <> '' then
        Body := '{"' + First + '":"' +
          Copy('Changed', 1, P.Columns[PlanColumnIndex(P, First)].Field.Length) +
          '","id":999999,"created_at":"2001-01-01 00:00:00"}'
      else
        Body := '{"id":999999}';
      A('  Res := Client.AsInertia.Put(''' + N.Url + '/'' + IntToStr(Id), ' + PasStr(Body) + ');');
      A('  AssertStatus(Res, 303, ''a save answers 303, so the browser does not repeat the PUT'');');
      if Firstmember <> '' then
      begin
        A('  M := TQuery<T' + N.Model + '>.New.Find(Id);');
        A('  AssertNotNil(M, ''the id in the body did not move it'');');
        A('  AssertEqual(M.' + Firstmember + ', ' +
          PasStr(Copy('Changed', 1, P.Columns[PlanColumnIndex(P, First)].Field.Length)) +
          ', ''the change is saved'');');
        if P.HasTimestamps then
          A('  AssertTrue(M.CreatedAt > EncodeDate(2002, 1, 1),' + #10 +
            '    ''and created_at, which the form does not have, is not set from the body'');');
      end;
      A('end;');
      A('');

      A('procedure TestRemove;');
      A('var');
      A('  Id: Int64;');
      A('begin');
      A('  Ready;');
      A('  Id := Made;');
      A('  AssertStatus(Client.AsInertia.Delete(''' + N.Url + '/'' + IntToStr(Id)), 303,');
      A('    ''a delete answers 303'');');
      A('  AssertNil(TQuery<T' + N.Model + '>.New.Find(Id), ''and the row is gone'');');
      A('end;');
      A('');
    end;

    A('procedure ' + N.TestsProc + ';');
    A('begin');
    A('  Group(''' + Capital(N.HumanPlural) + ''');');
    A('  Test(''the list answers, whatever it is asked to sort by'', @TestList);');
    A('  Test(''a row that is not there is a 404'', @TestMissing);');
    if CanWrite then
    begin
      A('  Test(''a new one is saved and can be shown and edited'', @TestStore);');
      if RequiredCol <> '' then
        A('  Test(''what the rules refuse is not saved'', @TestRefused);');
      A('  Test(''an edit is saved, and only the fields the form has'', @TestUpdate);');
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

function TestProgramText(const N: TResourceNames): string;
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
    '  ' + N.TestUnit + ';' + #10 + #10 +
    'begin' + #10 +
    '  ' + N.TestsProc + ';' + #10 +
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
  WithModel: Boolean): TGenFiles;
var
  N: TResourceNames;
  Pages, Why: string;
begin
  Result := nil;
  N := ResourceNamesOf(P);
  Pages := 'frontend/src/pages/' + N.PagesDir + '/';
  if WithModel then
    AddFile(Result, 'app/Models/' + N.ModelUnit + '.pas', ModelText(P));
  AddFile(Result, 'app/Http/' + N.CtlUnit + '.pas', ControllerText(P, Parents));
  AddFile(Result, Pages + 'Index.svelte', IndexText(P));
  AddFile(Result, Pages + 'Show.svelte', ShowText(P, Parents));
  AddFile(Result, Pages + 'Add.svelte', FormPageText(P, Parents, False));
  AddFile(Result, Pages + 'Edit.svelte', FormPageText(P, Parents, True));
  AddFile(Result, Pages + 'Fields.svelte', FieldsText(P, Parents));
  AddFile(Result, 'tests/' + N.TestUnit + '.pas', TestUnitText(P, Parents, Why));
end;

{ ----------------------------------------------------- the command -- }

{ app.lpr at the lines `askr new` wrote. The same markers make auth uses:
  the uses line of the home controller, and the /demo route. }
function InstallRoutes(const Root: string; const N: TResourceNames): Boolean;
const
  MarkerUses = '  App.Http.HomeController;';
  MarkerRoutes = '  R.Get(''/demo'', Home.Demo);';
var
  L: TStringList;
  Path_: string;
  I, IdxUses, IdxRoutes: Integer;
begin
  Result := False;
  Path_ := IncludeTrailingPathDelimiter(Root) + 'app.lpr';
  if not FileExists(Path_) then
    Exit;
  L := TStringList.Create;
  try
    L.LoadFromFile(Path_);
    for I := 0 to L.Count - 1 do
      if Trim(L[I]) = N.RoutesProc + '(R);' then
        Exit(True);
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
    { From the back, so the first insertion does not move the second. }
    L.Insert(IdxRoutes + 1, '  ' + N.RoutesProc + '(R);');
    L.Insert(IdxUses, '  ' + N.CtlUnit + ',');
    L.SaveToFile(Path_);
    WriteLn('  edited app.lpr');
    Result := True;
  finally
    L.Free;
  end;
end;

{ tests/app_tests.lpr: written when there is none, edited at its two
  markers when there is, and left alone -- with the lines to add -- when
  they are not there. }
function InstallTests(const Root: string; const N: TResourceNames): Boolean;
var
  L: TStringList;
  Path_: string;
  I, IdxUses, IdxRun: Integer;
begin
  Path_ := IncludeTrailingPathDelimiter(Root) + 'tests/app_tests.lpr';
  if not FileExists(Path_) then
  begin
    Emit(Path_, TestProgramText(N));
    Exit(True);
  end;
  Result := False;
  L := TStringList.Create;
  try
    L.LoadFromFile(Path_);
    for I := 0 to L.Count - 1 do
      if Trim(L[I]) = N.TestsProc + ';' then
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
    L.Insert(IdxRun, '  ' + N.TestsProc + ';');
    L.Insert(IdxUses + 1, '  ' + N.TestUnit + ',');
    L.SaveToFile(Path_);
    WriteLn('  edited tests/app_tests.lpr');
    Result := True;
  finally
    L.Free;
  end;
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

function MakeResource(const Root: string; Schema: TDbSchema;
  const ModelName, Table: string; Force: Boolean): Boolean;
var
  P: TResourcePlan;
  N: TResourceNames;
  Parents: TParentInfos;
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
  Files := ResourceFiles(P, Parents, WithModel);

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

  if not InstallRoutes(Root, N) then
  begin
    WriteLn('');
    WriteLn('Could not find the markers in app.lpr. Add these yourself:');
    WriteLn('  uses   ' + N.CtlUnit + ';');
    WriteLn('  and, with the other routes:  ' + N.RoutesProc + '(R);');
  end;
  if not InstallTests(Root, N) then
  begin
    WriteLn('');
    WriteLn('tests/app_tests.lpr is there without the lines this recognises.');
    WriteLn('Add these yourself:');
    WriteLn('  uses   ' + N.TestUnit + ';');
    WriteLn('  and, before RunTestsAndHalt:  ' + N.TestsProc + ';');
  end;

  TestUnitText(P, Parents, Why);
  WriteLn('');
  if Why <> '' then
    WriteLn('The test does not create, edit or delete: ' + Why + '.');
  WriteLn('Next: askr build, then askr test. The pages are under');
  WriteLn('frontend/src/pages/' + N.PagesDir + ', and ' + N.Url + ' lists them.');
  Result := True;
end;

end.
