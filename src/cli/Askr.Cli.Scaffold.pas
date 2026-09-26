{ Askr.Cli.Scaffold — askr new and askr make.

  The templates are small on purpose. Scaffolding that generates fifteen
  files you do not understand is worse than no scaffolding: the goal in the
  PRD is a CRUD app written from scratch in under an hour by somebody who
  has not written Askr before, and then what is generated has to be
  readable in its entirety. }
unit Askr.Cli.Scaffold;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, Askr.Core.Crypto, Askr.Core.Version, Askr.Cli.Fields;

procedure NewProject(const ParentDir, Name: string;
  WithAuth: Boolean = False);
procedure MakeModel(const Root, Name: string; WithMigration: Boolean);
{ A model and its migration from one field spec, so they cannot disagree.
  Refuses to write anything when a file it would write is already there,
  unless Force -- and then says which. Returns False when it refused. }
function MakeModelFromFields(const Root, Name: string;
  const Fields: TFieldSpecs; Timestamps, Force: Boolean): Boolean;
procedure MakeController(const Root, Name: string);

{ The unit a model is, from what it maps. make model and make resource
  both write their models here, so a model reads the same whichever of
  them wrote it. Fields leaves out the key and the timestamps; Describe
  and Rules are the bodies of the two methods, line by line; Hidden are
  typed-column members of SchemaVar, which lives in SchemaUnit. }
function ModelUnitText(const N: string; const Intro: TStringArray;
  const Fields: TFieldSpecs; Timestamps, SoftDeletes: Boolean;
  const Describe, Rules, Hidden: TStringArray;
  const SchemaUnit, SchemaVar: string; const ExtraUses: string = '';
  const ExtraTypes: TStringArray = nil;
  const ExtraFields: TStringArray = nil): string;

{ The lines a model needs for a BelongsToMany it does not have, as a
  person reads them: the uses, the list type, the field and the line in
  Describe. make pivot and make resource both print them, from here, so
  the two cannot tell someone different things. }
function ManyToManyModelLines(const Model, Target, Relation,
  DescribeLine: string): TStringArray;

{ customer, order_item -> Customer, OrderItem. }
function PascalName(const S: string): string;

{ True, having said which, when any of Paths is there already and Force is
  not set. Every path is checked before any is written: half a set is
  worse than none. }
function RefuseExisting(const Paths: array of string; Force: Boolean): Boolean;
procedure MakeMigration(const Root, Name: string);
{ The pivot between two models, for a BelongsToMany:

    askr make pivot Post Tag

  writes a migration for post_tag -- the two singular names in
  alphabetical order, as BelongsToMany expects without being told -- with
  post_id and tag_id as foreign keys that cascade, the pair unique, and
  tag_id indexed for loading from the other side. It does not touch the
  models: it prints the three lines that go in one of them.

  A model related to itself is refused: the two keys would have the same
  name, and which one means which is a decision, not a convention. }
function MakePivot(const Root, First, Second: string; Force: Boolean): Boolean;
procedure MakeSeeder(const Root, Name: string);
procedure MakeJob(const Root, Name: string);
procedure MakeMiddleware(const Root, Name: string);

{ Exposed because Askr.Cli.Auth writes files the same way, and because two
  different ways of writing a generated file would have given two different
  outputs. }
procedure Emit(const Path_, Content_: string);
function Stamp: string;
{ The version for a new migration: now, or one past the highest version
  already in database/, whichever is later. See the implementation. }
function NextVersion(const Root: string): string;
procedure UpdateIndex(const Root, Folder, IndexUnit, Prefix: string);

implementation

uses
  { In implementation, not in interface: Askr.Cli.Auth uses Emit and
    UpdateIndex from here, and Pascal allows the circle only when at least
    one of them is here. }
  Askr.Cli.Auth, Askr.Urd.Model;

const
  Q = '''';

{ ----------------------------------------------------------- hjelpere -- }

procedure Emit(const Path_, Content_: string);
var
  L: TStringList;
begin
  ForceDirectories(ExtractFilePath(Path_));
  L := TStringList.Create;
  try
    L.Text := Content_;
    { TStringList adds a line break at the end. The content is written with
      #10 throughout, and SaveToFile is not to translate them. }
    L.TrailingLineBreak := False;
    L.SaveToFile(Path_);
  finally
    L.Free;
  end;
  WriteLn('  new  ', Path_);
end;

function PascalName(const S: string): string;
var
  I: Integer;
  Big: Boolean;
begin
  Result := '';
  Big := True;
  for I := 1 to Length(S) do
  begin
    if (S[I] = '_') or (S[I] = '-') or (S[I] = ' ') then
    begin
      Big := True;
      Continue;
    end;
    if Big then
      Result := Result + UpCase(S[I])
    else
      Result := Result + S[I];
    Big := False;
  end;
end;

function SnakeName(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    if (S[I] >= 'A') and (S[I] <= 'Z') then
    begin
      if (I > 1) and (Result <> '') and (Result[Length(Result)] <> '_') then
        Result := Result + '_';
      Result := Result + Chr(Ord(S[I]) + 32);
    end
    else if (S[I] = '-') or (S[I] = ' ') then
      Result := Result + '_'
    else
      Result := Result + S[I];
  end;
end;

{ English plurals, to the extent a table needs them, and deliberately
  simple: a model with an irregular name sets the table name itself in
  Describe.

  It used to be a copy of Askr.Urd.Model's rule, with a comment saying it
  was the same. A copy with a note on it is still a copy, and the table
  `make model` creates has to be the one `customer:references` points at
  and the one the model maps to. One rule, called from all three. }
function Plural(const S: string): string;
begin
  Result := Pluralize(S);
end;

function Stamp: string;
var
  Y, M, D, H, Mi, Se, Ms: Word;
begin
  DecodeDate(Now, Y, M, D);
  DecodeTime(Now, H, Mi, Se, Ms);
  Result := Format('%.4d%.2d%.2d%.2d%.2d%.2d', [Y, M, D, H, Mi, Se]);
end;

{ The time alone is not enough. It has a resolution of one second, and two
  `askr make model` in a row -- a script, or two lines pasted at once --
  land in the same second and get the same version. The migrator then ran
  the second one's DDL and failed to record it, and on MySQL left a table
  behind with nothing to say it had been made. Found by make:check, which
  does exactly that.

  So: the versions already in the project are read, the same way
  UpdateIndex reads the directory rather than a list, and the new one is
  put after the highest of them. The number stays an ordering key and
  stops being a promise about the clock, which is all it was ever used
  for. }
function NextVersion(const Root: string): string;
var
  R: TSearchRec;
  L: TStringList;
  Dir, Line, Digits: string;
  I, P, Q: Integer;
  Highest, Now_, V: Int64;
begin
  Now_ := StrToInt64(Stamp);
  Highest := 0;
  Dir := IncludeTrailingPathDelimiter(IncludeTrailingPathDelimiter(Root) +
    'database');
  if FindFirst(Dir + 'App.Migrations.*.pas', faAnyFile, R) = 0 then
  begin
    L := TStringList.Create;
    try
      repeat
        L.LoadFromFile(Dir + R.Name);
        for I := 0 to L.Count - 1 do
        begin
          Line := L[I];
          P := Pos('Result := ''', Line);
          if P = 0 then
            Continue;
          P := P + Length('Result := ''');
          Q := P;
          while (Q <= Length(Line)) and (Line[Q] in ['0'..'9']) do
            Inc(Q);
          Digits := Copy(Line, P, Q - P);
          if (Length(Digits) = 14) and TryStrToInt64(Digits, V) and
             (V > Highest) then
            Highest := V;
        end;
      until FindNext(R) <> 0;
    finally
      L.Free;
      FindClose(R);
    end;
  end;
  if Highest >= Now_ then
    Now_ := Highest + 1;
  Result := IntToStr(Now_);
end;

{ The framework's root. ASKR_HOME first, then upwards from this directory
  — an app made inside the repository is to find it without anybody setting
  anything. }
function AskrRoot: string;
var
  Dir, Prev: string;
begin
  Result := GetEnvironmentVariable('ASKR_HOME');
  if (Result <> '') and
     FileExists(IncludeTrailingPathDelimiter(Result) +
       'src/core/Askr.Core.Arena.pas') then
    Exit(ExcludeTrailingPathDelimiter(ExpandFileName(Result)));

  Dir := ExcludeTrailingPathDelimiter(ExpandFileName(GetCurrentDir));
  repeat
    if FileExists(IncludeTrailingPathDelimiter(Dir) +
      'src/core/Askr.Core.Arena.pas') then
      Exit(Dir);
    Prev := Dir;
    Dir := ExtractFileDir(Dir);
  until (Dir = Prev) or (Dir = '');
  Result := '';
end;

{ Gathers all the App.Migrations.* units into one that merely "uses" them.

  Each migration registers itself in its own initialization section, the way
  the drivers do. But a unit nobody references is never linked in by fpc,
  and then initialization does not run. The index exists only to reference
  them.

  It is read from the directory and not from a list we keep in our heads: a
  file added by hand, or one that has been deleted, must not be able to
  become invisible. That is the same rule as Norn codegen reading the
  database and not the migrations. }
procedure UpdateIndex(const Root, Folder, IndexUnit, Prefix: string);
var
  R: TSearchRec;
  Name_: TStringList;
  Source_, Path_: string;
  I: Integer;
begin
  Path_ := IncludeTrailingPathDelimiter(Root) + Folder;
  Name_ := TStringList.Create;
  try
    Name_.Sorted := True;
    if FindFirst(IncludeTrailingPathDelimiter(Path_) + Prefix + '*.pas',
      faAnyFile, R) = 0 then
    begin
      repeat
        if R.Name <> IndexUnit + '.pas' then
          Name_.Add(ChangeFileExt(R.Name, ''));
      until FindNext(R) <> 0;
      FindClose(R);
    end;

    Source_ := 'unit ' + IndexUnit + ';' + #10 + #10 +
      '{ GENERATED by askr make. Do not edit; it is rewritten.' + #10 + #10 +
      '  Each unit below registers itself in its own initialization.' + #10 +
      '  This unit exists only so fpc links them in: a unit nothing' + #10 +
      '  references never runs its initialization. }' + #10 + #10 +
      '{$mode Delphi}{$H+}' + #10 + #10 +
      'interface' + #10 + #10 +
      'implementation' + #10 + #10;
    if Name_.Count = 0 then
      Source_ := Source_ + 'end.' + #10
    else
    begin
      Source_ := Source_ + 'uses' + #10;
      for I := 0 to Name_.Count - 1 do
        if I < Name_.Count - 1 then
          Source_ := Source_ + '  ' + Name_[I] + ',' + #10
        else
          Source_ := Source_ + '  ' + Name_[I] + ';' + #10;
      Source_ := Source_ + #10 + 'end.' + #10;
    end;
    Emit(IncludeTrailingPathDelimiter(Path_) + IndexUnit + '.pas', Source_);
  finally
    Name_.Free;
  end;
end;

{ --------------------------------------------------------- askr new -- }

{ AGENTS.md, for the coding agents that read it.

  **It says as little as it can get away with**, and that is the design.
  Everything about the framework itself is behind `docs_search` and
  `docs_read`, which serve the documentation of the exact version this
  project pins. Restating any of it here would put a second copy in a file
  the user owns, frozen at the moment the project was scaffolded, and the
  two would disagree the first time the project is upgraded — with nothing
  to say which one was right.

  So what is here is only what an agent needs before it knows to ask: that
  there is somewhere to ask, and the handful of facts where being wrong is
  silent rather than loud. }
procedure WriteAgentsFile(const Root, Name: string);
var
  L: TStringList;

  procedure A(const S: string);
  begin
    L.Add(S);
  end;

begin
  L := TStringList.Create;
  try
    A('# ' + Name);
    A('');
    A('An [Askr](https://askrcode.com) application: Free Pascal, one');
    A('binary, no sidecars.');
    A('');
    A('## Ask the framework, do not guess at it');
    A('');
    A('Askr ships an MCP server. Start it with `askr mcp`, or wire it in');
    A('with `askr mcp:install`.');
    A('');
    A('| Tool | Use it to |');
    A('|---|---|');
    A('| `build` | Compile. Diagnostics come back as `file:line:column`. |');
    A('| `test` | Run the suite. It stops one that hangs. |');
    A('| `routes` | The routing table, in the order requests match. |');
    A('| `openapi` | The API document, or `check` for drift against the routes. |');
    A('| `schema` | What the database actually contains. |');
    A('| `config` | Every key and the layer it came from. |');
    A('| `docs_search` | Find an API name. The search is exact, never fuzzy. |');
    A('| `docs_read` | Read a page, or one section of it. |');
    A('');
    A('`docs_search` and `docs_read` serve the documentation of the exact');
    A('Askr version this project pins, so they are right about the');
    A('framework in front of you. **This file deliberately does not repeat');
    A('them.** A copy here would be frozen at the day the project was');
    A('created, and would start lying the first time Askr is upgraded.');
    A('');
    A('No match from `docs_search` means the name does not exist. It will');
    A('not offer you the nearest thing that does.');
    A('');
    A('## What is different here from most stacks');
    A('');
    A('These are the ones where being wrong is quiet. Everything else,');
    A('ask the docs.');
    A('');
    A('**A wrong column name is a compile error, not a runtime surprise.**');
    A('`askr schema` generates typed constants from the real database, and');
    A('`Where(Customers.Email, Eq, 42)` will not compile. So run `build`');
    A('after editing rather than reasoning about whether it is right — it');
    A('is the cheapest check in this stack, and it is exhaustive.');
    A('');
    A('**Memory is an arena per request.** Anything created while serving');
    A('a request is freed in one operation when the request ends. Do not');
    A('call `Free` on it: that is a no-op, and writing it says you believe');
    A('a model of the memory that is not the one in use.');
    A('');
    A('**A migration file must be named after the unit inside it**, and');
    A('must sit under a directory listed in `units` in `askr.toml`. fpc');
    A('finds no unit whose file is named something else, and a unit that');
    A('nothing references is never linked in — so a migration in the wrong');
    A('place does not fail, it simply never runs.');
    A('');
    A('**`.env` is not committed, and its values are not output.** The');
    A('`config` tool shows which keys exist and where each resolved from,');
    A('and never what any of them contains. Do not work around that by');
    A('reading the file and quoting it back.');
    A('');
    A('## Commands');
    A('');
    A('```sh');
    A('askr serve                 # dev server, rebuilds on change');
    A('askr build                 # compile');
    A('askr test                  # build and run the suite');
    A('askr migrate               # run pending migrations');
    A('askr schema                # typed columns from the database');
    A('askr routes                # the routing table');
    A('askr about                 # what this app is configured with');
    A('askr list                  # everything this binary answers to');
    A('```');
    A('');
    A('`askr` reads `askr.toml` in the project root. The framework version');
    A('is pinned there; `askr install` fetches it and `askr.lock` records');
    A('the exact commit.');
    Emit(Root + '/AGENTS.md', L.Text);
  finally
    L.Free;
  end;
end;

procedure NewProject(const ParentDir, Name: string;
  WithAuth: Boolean);
var
  Root, Framework, LaufDep, Pin: string;
begin
  Root := IncludeTrailingPathDelimiter(ParentDir) + Name;
  if DirectoryExists(Root) then
  begin
    WriteLn('There is already a directory called ', Name, '.');
    Halt(1);
  end;
  Framework := AskrRoot;
  { If there is a checkout alongside, the project points at it — that is
    how the framework is developed. Otherwise only the version is there, and
    `askr install` fetches it. }
  if Framework <> '' then
    Pin := 'path = "' + Framework + '"'
  else
    Pin := '# path = "/path/to/askrcode"';

  WriteLn('Storage ', Name);
  WriteLn;

  { The section comes last on purpose: in TOML everything after a
    [section] belongs to it, so an [app] in the middle would have turned
    units and askr into app.units and app.askr — and the build would have
    stopped finding the framework. }
  Emit(Root + '/askr.toml',
    'name = "' + Name + '"' + #10 +
    'main = "app.lpr"' + #10 +
    'frontend = "frontend"' + #10 +
    '' + #10 +
    '# Directories added to the unit search path. Migrations and seeders' + #10 +
    '# must be here: a unit that is not compiled into the binary does not' + #10 +
    '# exist as far as askr migrate is concerned.' + #10 +
    'units = "app,database"' + #10 +
    '# Directories the dev server watches.' + #10 +
    'watch = "app,database,frontend/src"' + #10 +
    '' + #10 +

    '# The app reads these as app.port and app.backend_port. A real' + #10 +
    '# environment variable — APP_PORT — wins over what is here, so a' + #10 +
    '# deployment can change it without touching this file.' + #10 +
    '# See what actually applies with: askr config' + #10 +
    '[app]' + #10 +
    'port = 8080' + #10 +
    'backend_port = 8081' + #10 +
    '' + #10 +
    '# Which Askr release this project builds against.' + #10 +
    '#' + #10 +
    '#   askr install    fetch it into ~/.askr/pkg' + #10 +
    '#   askr outdated   see what else is published' + #10 +
    '#   askr update     move, after reading what changes' + #10 +
    '#' + #10 +
    '# askr.lock records the exact commit and the matching' + #10 +
    '# @askrcode/lauf version. Commit that file.' + #10 +
    '[askr]' + #10 +
    'version = "' + AskrVersion + '"' + #10 +
    '# path overrides the version. It is for working on the' + #10 +
    '# framework itself, and is what `askr new` sets when it' + #10 +
    '# finds a checkout beside you.' + #10 +
    Pin + #10);

  if Framework = '' then
  begin
    WriteLn;
    WriteLn('  WARNING   could not find the framework. Set the askr path in');
    WriteLn('            askr.toml, or set ASKR_HOME and run `askr new` again.');
  end;

  Emit(Root + '/app.lpr',
    'program App;' + #10 + #10 +
    '{$mode Delphi}{$H+}' + #10 + #10 +
    'uses' + #10 +
    '{$IFDEF UNIX}' + #10 +
    '  cthreads,' + #10 +
    '{$ENDIF}' + #10 +
    '  SysUtils, BaseUnix, Math,' + #10 +
    '  Askr.Core.Arena, Askr.Core.Env, Askr.Core.Crypto,' + #10 +
    '  Askr.Core.Config, Askr.Core.Log,' + #10 +
    '  Askr.Urd.Driver, Askr.Urd.Pool, Askr.Urd.Model,' + #10 +
    '  Askr.Urd.Sqlite, Askr.Urd.Pg, Askr.Urd.MySql,' + #10 +
    '  Askr.Console,' + #10 +
    '  Askr.Http.Request, Askr.Http.Response,' + #10 +
    '  Askr.Http.Server, Askr.Http.Router, Askr.Http.Static,' + #10 +
    '  Askr.Http.Robots, Askr.Http.Sitemap,' + #10 +
    '  Askr.Session, Askr.Session.Db, Askr.Csrf, Askr.Auth, Askr.Auth.Token,' + #10 +
    '  Askr.Http.Cors, Askr.Http.RateLimit,' + #10 +
    '  Askr.Inertia,' + #10 +
    '  App.Migrations, App.Seeders,' + #10 +
    { This line is the marker `askr make auth` inserts in front of. If you
      change it, the uses lines have to be added by hand — the tool says
      so. }
    '  App.Http.HomeController;' + #10 + #10 +
    'var' + #10 +
    '  Server: TAskrServer;' + #10 +
    '  DbPool: TDbPool;' + #10 + #10 +
    '{ One connection per request. Without this the models and the query' + #10 +
    '  builder have no connection to use, and it is not noticed until' + #10 +
    '  something actually asks the database.' + #10 +
    '' + #10 +
    '  Acquire and Release, not Lease: a leased connection is handed back' + #10 +
    '  when the arena is reset, and that does not happen until the NEXT' + #10 +
    '  request on this worker. With more workers than connections in the' + #10 +
    '  pool it deadlocks. Here it is handed back once the reply is made. }' + #10 +
    'function LeaseDb(Req: TRequest): TResponse;' + #10 +
    'begin' + #10 +
    '  UseDb(DbPool.Acquire);' + #10 +
    '  Result := nil;' + #10 +
    'end;' + #10 + #10 +

    '{ The pages this site offers to a crawler. Add yours here; with' + #10 +
    '  pages in a database, query them — this runs per request, so the' + #10 +
    '  list is what exists now.' + #10 +
    '' + #10 +
    '  Paths only. They are made absolute against app.url when the' + #10 +
    '  document is written, never from the request. }' + #10 +
    'procedure AppSitemap(S: TSitemap);' + #10 +
    'begin' + #10 +
    '  S.Add(' + Q + '/' + Q + ');' + #10 +
    'end;' + #10 + #10 +
    'function ReleaseDb(Req: TRequest; Res: TResponse): TResponse;' + #10 +
    'var' + #10 +
    '  C: TDbConnection;' + #10 +
    'begin' + #10 +
    '  { After filters also run when middleware short-circuited the' + #10 +
    '    request, so a static file that never reached LeaseDb is covered' + #10 +
    '    by the nil check. }' + #10 +
    '  C := CurrentDb;' + #10 +
    '  UseDb(nil);' + #10 +
    '  if C <> nil then' + #10 +
    '    DbPool.Release(C);' + #10 +
    '  Result := Res;' + #10 +
    'end;' + #10 + #10 +
    'procedure Stop_(Sig: cint); cdecl;' + #10 +
    'begin' + #10 +
    '  if Server <> nil then' + #10 +
    '    Server.Stop;' + #10 +
    'end;' + #10 + #10 +
    'var' + #10 +
    '  Opts: TServerOptions;' + #10 +
    '  R: TRouter;' + #10 +
    '  StaticFiles: TStaticFiles;' + #10 +
    '  Home: THomeController;' + #10 +
    'begin' + #10 +
    '  { Reads .env and askr.toml. Real environment variables win over' + #10 +
    '    both. See what actually applies with: askr config }' + #10 +
    '  LoadConfig;' + #10 +
    '  { Level and format from LOG_LEVEL and LOG_FORMAT. Text locally,' + #10 +
    '    JSON when APP_ENV=production. }' + #10 +
    '  ConfigureLogFromEnv;' + #10 +
    '  { Signs the "remember me" cookie and signed URLs. Changing it logs' + #10 +
    '    everyone out. New one: askr key:generate }' + #10 +
    '  SetAppKey(Env(' + Q + 'APP_KEY' + Q + '));' + #10 + #10 +
    '  Opts := DefaultServerOptions;' + #10 +
    '  Opts.Port := Word(CfgInt(' + Q + 'app.port' + Q + ', 8080));' + #10 +
    '  Opts.LogRequests := True;' + #10 + #10 +
    '  { Certificate paths belong to the deployment, not the source. With' + #10 +
    '    neither set the app speaks HTTP, which is the right thing behind a' + #10 +
    '    reverse proxy that terminates TLS itself. }' + #10 +
    '  Opts.TlsCertFile := Cfg(' + Q + 'askr.tls.cert' + Q + ');' + #10 +
    '  Opts.TlsKeyFile := Cfg(' + Q + 'askr.tls.key' + Q + ');' + #10 + #10 +
    '  { In development Vite serves the modules itself. For a production' + #10 +
    '    build, read public/build/.vite/manifest.json instead and set the' + #10 +
    '    tags from there — see examples/inertia in the framework. }' + #10 +
    '  { The title in the HTML shell. The client usually sets its own' + #10 +
    '    per page with <svelte:head>; this is the one that stands there' + #10 +
    '    until it does, and the one that stands there if it never' + #10 +
    '    does. }' + #10 +
    '  TInertia.SetTitle(' + Q + Name + Q + ');' + #10 + #10 +
    '  TInertia.SetHead(' + #10 +
    '    ' + Q + '<script type="module" ' + Q + ' +' + #10 +
    '    ' + Q + 'src="http://localhost:5173/build/@vite/client"></script>' + Q + ' +' + #10 +
    '    ' + Q + '<script type="module" ' + Q + ' +' + #10 +
    '    ' + Q + 'src="http://localhost:5173/build/src/main.js"></script>' + Q + ');' + #10 +
    #10 +
    '  StaticFiles := TStaticFiles.Create(' + Q + 'public' + Q + ');' + #10 +
    '  Home := THomeController.Create;' + #10 +
    '  R := TRouter.Create;' + #10 +
    '  { CORS, before everything: a preflight is the browser asking' + #10 +
    '    whether a page on another origin may call this, and it carries' + #10 +
    '    no credentials by design — so anything that refuses a request' + #10 +
    '    without one would refuse every preflight.' + #10 +
    '' + #10 +
    '    It allows nothing until you say otherwise. Name the origins:' + #10 +
    '    Cors.AllowOrigin(''https://app.example''), and AllowCredentials' + #10 +
    '    if the browser should send cookies with them. }' + #10 +
    '  UseCors(R);' + #10 +
    '  { Static files: they need neither session nor CSRF, and they' + #10 +
    '    short-circuit the request before any of it runs. }' + #10 +
    '  R.Use(StaticFiles.Serve);' + #10 +
    '  { askr down / askr up. It comes after the static files, so that a' + #10 +
    '    maintenance page with css can still be served. }' + #10 +
    '  UseMaintenance(R);' + #10 +
    '  { The sitemap. Askr knows the routes but not which of them are' + #10 +
    '    public, and it cannot turn /docs/:slug into the pages that' + #10 +
    '    exist — so the list is yours. Called per request, so pages in a' + #10 +
    '    database can be listed as they are now. }' + #10 +
    '  UseSitemap(R, @AppSitemap);' + #10 +
    '  { robots.txt. The default follows APP_ENV and only production is' + #10 +
    '    open, because a missing robots.txt means "index everything" —' + #10 +
    '    the dangerous state is a staging site nobody thought about.' + #10 +
    '    Your own public/robots.txt is served above and wins. }' + #10 +
    '  UseRobots(R);' + #10 + #10 +
    '  { The database, if DATABASE_URL is set. An app without a database' + #10 +
    '    must not be refused a start. }' + #10 +
    '  if Cfg(' + Q + 'database.url' + Q + ') <> ' + Q + Q + ' then' + #10 +
    '  begin' + #10 +
    '    { At least one connection per worker, or they stand waiting for' + #10 +
    '      each other. Opts.Workers = 0 means one per core. }' + #10 +
    '    DbPool := TDbPool.Create(Cfg(' + Q + 'database.url' + Q + '),' + #10 +
    '      Max(8, Opts.Workers * 2));' + #10 +
    '    R.Use(@LeaseDb);' + #10 +
    '    R.After(@ReleaseDb);' + #10 +
    '  end;' + #10 + #10 +
    '  { Sessions, CSRF and login. The order is not optional: the CSRF' + #10 +
    '    token lives in the session, and "remember me" writes to it. A' + #10 +
    '    session nobody writes to costs nothing — it gets neither a slot' + #10 +
    '    nor a cookie.' + #10 +
    '' + #10 +
    '    In memory unless SESSION_DRIVER=database, which keeps them in' + #10 +
    '    the database above so a second node and a restart see the' + #10 +
    '    same logins. SESSION_LIFETIME is in seconds. }' + #10 +
    '  SetSessions(SessionsFromConfig(DbPool));' + #10 +
    '  UseSessions(R);' + #10 +
    '  { API tokens, for callers that are not browsers:' + #10 +
    '' + #10 +
    '      Authorization: Bearer askr_...' + #10 +
    '' + #10 +
    '    Mint one with: askr token:issue <user-id> <name> --scopes=a,b' + #10 +
    '' + #10 +
    '    The api_tokens table is made by the first token:issue, not at' + #10 +
    '    startup: this app has to start whether or not the database is' + #10 +
    '    up, and a DDL on boot would make that untrue.' + #10 +
    '' + #10 +
    '    It costs nothing for a browser — with no Authorization header' + #10 +
    '    it does not touch the database. It has to come BEFORE UseCsrf:' + #10 +
    '    a request that authenticated with a header it carried itself is' + #10 +
    '    not what CSRF defends against, and the exemption is only' + #10 +
    '    visible once the token has been read. }' + #10 +
    '  UseTokenAuth(R);' + #10 +
    '  { How often one caller may ask. After UseTokenAuth, so the bucket' + #10 +
    '    can be named after the token rather than the address — one' + #10 +
    '    office behind one address is not one caller.' + #10 +
    '' + #10 +
    '    600 a minute is a number nobody types by hand and a script' + #10 +
    '    reaches in seconds. It is a starting point, not a measurement:' + #10 +
    '    change it to what this app can actually serve. }' + #10 +
    '  RateLimit.PerMinute(600).KeyBy(@TokenRateKey);' + #10 +
    '  UseRateLimit(R);' + #10 +
    '  UseCsrf(R);' + #10 +
    '  UseAuth(R);' + #10 + #10 +
    '  R.Get(' + Q + '/' + Q + ', Home.Index);' + #10 +
    '  R.Get(' + Q + '/demo' + Q + ', Home.Demo);' + #10 + #10 +
    '  { The commands the app answers to itself: migrate, db:seed, schema,' + #10 +
    '    routes, about and the rest. Migrations and routes are compiled in' + #10 +
    '    here, so the tool cannot run them — it asks the binary to. See' + #10 +
    '    the whole list with: askr list' + #10 + #10 +
    '    Commands of your own go before RunConsole:' + #10 + #10 +
    '      RegisterCommand(' + Q + 'invoices:send' + Q + ', ' + Q + 'send what is due' + Q + ', @SendInvoices);' + #10 + #10 +
    '    and askr invoices:send runs SendInvoices. See docs/cli.md. }' + #10 +
    '  SetConsoleDsn(Cfg(' + Q + 'database.url' + Q + '));' + #10 +
    '  SetConsoleRouter(R);' + #10 +
    '  if RunConsole then' + #10 +
    '  begin' + #10 +
    '    R.Free;' + #10 +
    '    StaticFiles.Free;' + #10 +
    '    Home.Free;' + #10 +
    '    Exit;' + #10 +
    '  end;' + #10 + #10 +
    '  { A port on the command line still wins, for two apps side by side. }' + #10 +
    '  if ParamCount >= 1 then' + #10 +
    '    Opts.Port := Word(StrToIntDef(ParamStr(1), Opts.Port));' + #10 +
    '  if ParamCount >= 2 then' + #10 +
    '    Opts.Host := ParamStr(2);' + #10 + #10 +
    '  Server := TAskrServer.Create(Opts);' + #10 +
    '  try' + #10 +
    '    Server.SetHandler(R.Handle);' + #10 +
    '    fpSignal(SIGINT, @Stop_);' + #10 +
    '    fpSignal(SIGTERM, @Stop_);' + #10 +
    '    Server.Start;' + #10 +
    '    if Server.UsesTls then' + #10 +
    '      WriteLn(' + Q + Name + ' on https://' + Q + ', Opts.Host, ' + Q + ':' + Q + ', Server.BoundPort)' + #10 +
    '    else' + #10 +
    '      WriteLn(' + Q + Name + ' on http://' + Q + ', Opts.Host, ' + Q + ':' + Q + ', Server.BoundPort);' + #10 +
    '    Flush(Output);' + #10 +
    '    while Server.Running do' + #10 +
    '      Sleep(50);' + #10 +
    '  finally' + #10 +
    '    Server.Free;' + #10 +
    '    R.Free;' + #10 +
    '    StaticFiles.Free;' + #10 +
    '    Home.Free;' + #10 +
    '  end;' + #10 +
    'end.' + #10);

  Emit(Root + '/app/Http/App.Http.HomeController.pas',
    'unit App.Http.HomeController;' + #10 + #10 +
    '{$mode Delphi}{$H+}' + #10 + #10 +
    'interface' + #10 + #10 +
    'uses' + #10 +
    '  SysUtils, Askr.Http.Request, Askr.Http.Response,' + #10 +
    '  Askr.Http.Welcome, Askr.Inertia;' + #10 + #10 +
    'type' + #10 +
    '  THomeController = class' + #10 +
    '  public' + #10 +
    '    function Index(Req: TRequest): TResponse;' + #10 +
    '    function Demo(Req: TRequest): TResponse;' + #10 +
    '  end;' + #10 + #10 +
    'implementation' + #10 + #10 +
    '{ The welcome page ships with the framework and needs neither npm nor' + #10 +
    '  a network. Replace the line below with your own response. }' + #10 +
    'function THomeController.Index(Req: TRequest): TResponse;' + #10 +
    'begin' + #10 +
    '  Result := WelcomePage(Req, ' + Q + Name + Q + ');' + #10 +
    'end;' + #10 + #10 +
    '{ The Inertia page. Needs the frontend installed and Vite running;' + #10 +
    '  see frontend/ and askr.toml. }' + #10 +
    'function THomeController.Demo(Req: TRequest): TResponse;' + #10 +
    'begin' + #10 +
    '  { What this page is for a reader that does not run JavaScript.' + #10 +
    '    Without it a crawler gets a payload in a script element and an' + #10 +
    '    empty div — zero characters of text. The client empties this' + #10 +
    '    element before it mounts, so nobody sees it twice.' + #10 +
    '' + #10 +
    '    It is markup, and it is not escaped: escape anything a user' + #10 +
    '    wrote before it goes in here. }' + #10 +
    '  TInertia.PageFallback(' + #10 +
    '    ' + Q + '<h1>' + Name + '</h1>' + Q + ' +' + #10 +
    '    ' + Q + '<p>An Askr application.</p>' + Q + ');' + #10 +
    '  Result := Inertia(' + Q + 'Home' + Q + ', [' + Q + 'name' + Q + ', ' + Q + Name + Q + ']);' + #10 +
    'end;' + #10 + #10 +
    'end.' + #10);

  { Empty indexes from the start, so that app.lpr compiles before anybody
    has made a single migration. }
  UpdateIndex(Root, 'database', 'App.Migrations', 'App.Migrations.');
  UpdateIndex(Root, 'database', 'App.Seeders', 'App.Seeders.');

  { Lauf is the frontend layer in Askr, not an optional package on the
    side. Until it is published on npm the dependency points at the
    framework directory — the same path askr.toml already knows. When it is
    published, this line is swapped for a version number and nothing else
    changes. }
  if Framework <> '' then
    LaufDep := '"file:' + IncludeTrailingPathDelimiter(Framework) + 'frontend/lauf"'
  else
    LaufDep := '"^0.1.0"';

  Emit(Root + '/frontend/package.json',
    '{' + #10 +
    '  "name": "' + Name + '-frontend",' + #10 +
    '  "private": true,' + #10 +
    '  "type": "module",' + #10 +
    '  "scripts": {' + #10 +
    '    "dev": "vite",' + #10 +
    '    "build": "vite build"' + #10 +
    '  },' + #10 +
    '  "dependencies": {' + #10 +
    '    "@askrcode/lauf": ' + LaufDep + ',' + #10 +
    '    "@inertiajs/svelte": "^3.0.0"' + #10 +
    '  },' + #10 +
    '  "devDependencies": {' + #10 +
    '    "@sveltejs/vite-plugin-svelte": "^5.0.0",' + #10 +
    '    "@tailwindcss/vite": "^4.0.0",' + #10 +
    '    "svelte": "^5.0.0",' + #10 +
    '    "tailwindcss": "^4.0.0",' + #10 +
    '    "vite": "^6.0.0"' + #10 +
    '  }' + #10 +
    '}' + #10);

  Emit(Root + '/frontend/vite.config.js',
    'import { defineConfig } from ' + Q + 'vite' + Q + #10 +
    'import { svelte } from ' + Q + '@sveltejs/vite-plugin-svelte' + Q + #10 +
    'import tailwindcss from ' + Q + '@tailwindcss/vite' + Q + #10 +
    #10 +
    '// Lauf sits as a file: dependency until it is published, that is, a' + #10 +
    '// symlink out of this tree, and has its own copies of svelte and' + #10 +
    '// @inertiajs for testing. Without dedupe Vite resolves them' + #10 +
    '// separately, and createInertiaApp sets up a different router from' + #10 +
    '// the one <Form> imports. The error is "Cannot read properties of' + #10 +
    '// undefined (reading visit)", a long way from the cause.' + #10 +
    'export default defineConfig({' + #10 +
    '  plugins: [tailwindcss(), svelte()],' + #10 +
    '  resolve: {' + #10 +
    '    dedupe: [' + Q + 'svelte' + Q + ', ' + Q + '@inertiajs/svelte' + Q +
      ', ' + Q + '@inertiajs/core' + Q + '],' + #10 +
    '  },' + #10 +
    '  base: ' + Q + '/build/' + Q + ',' + #10 +
    '  server: { port: 5173, strictPort: true },' + #10 +
    '  build: {' + #10 +
    '    manifest: true,' + #10 +
    '    outDir: ' + Q + '../public/build' + Q + ',' + #10 +
    '    emptyOutDir: true,' + #10 +
    '    rollupOptions: { input: ' + Q + 'src/main.js' + Q + ' },' + #10 +
    '  },' + #10 +
    '})' + #10);

  { Tailwind does not look into node_modules by itself. Without @source
    every class Lauf uses is missing from the stylesheet, and the components
    come out without styling with nothing to say why. }
  Emit(Root + '/frontend/src/app.css',
    '@import ' + Q + 'tailwindcss' + Q + ';' + #10 +
    '@import ' + Q + '@askrcode/lauf/theme.css' + Q + ';' + #10 +
    '@source ' + Q + '../node_modules/@askrcode/lauf/src' + Q + ';' + #10 + #10 +
    '/* The tokens are semantic. Override them here for your own look;' + #10 +
    '   dark mode follows along, because no component writes dark:. */' + #10 +
    'body {' + #10 +
    '  background: var(--color-surface);' + #10 +
    '  color: var(--color-fg);' + #10 +
    '  font-family: ui-sans-serif, system-ui, -apple-system, sans-serif;' + #10 +
    '}' + #10);

  Emit(Root + '/frontend/src/Layout.svelte',
    '<script>' + #10 +
    '  import { Flash } from ' + Q + '@askrcode/lauf/inertia' + Q + #10 +
    '  let { children } = $props()' + #10 +
    '</script>' + #10 + #10 +
    '<!-- Flash sets up the live regions once and turns flash from Askr' + #10 +
    '     into toasts. It has to sit outside the pages, or the region is' + #10 +
    '     swapped out on every navigation and the message is not read' + #10 +
    '     out. -->' + #10 +
    '<Flash />' + #10 + #10 +
    '<main class="mx-auto max-w-3xl px-4 pt-10 pb-16">' + #10 +
    '  {@render children?.()}' + #10 +
    '</main>' + #10);

  Emit(Root + '/frontend/src/main.js',
    'import { createInertiaApp } from ' + Q + '@inertiajs/svelte' + Q + #10 +
    'import { mount } from ' + Q + 'svelte' + Q + #10 +
    'import ' + Q + './app.css' + Q + #10 + #10 +
    'createInertiaApp({' + #10 +
    '  resolve: (name) => {' + #10 +
    '    const pages = import.meta.glob(' + Q + './pages/**/*.svelte' + Q +
      ', { eager: true })' + #10 +
    '    return pages[`./pages/${name}.svelte`]' + #10 +
    '  },' + #10 +
    '  setup({ el, App, props }) {' + #10 +
    '    // Empty it first. Svelte 5 mounts by appending, so anything the' + #10 +
    '    // server put there -- the fallback a page renders for crawlers' + #10 +
    '    // that do not run JavaScript -- would stay behind the app' + #10 +
    '    // instead of being replaced by it.' + #10 +
    '    el.innerHTML = ' + Q + Q + #10 +
    '    mount(App, { target: el, props })' + #10 +
    '  },' + #10 +
    '})' + #10);

  Emit(Root + '/frontend/src/pages/Home.svelte',
    '<script>' + #10 +
    '  import { Heading, Text, Card, Button } from ' + Q + '@askrcode/lauf' + Q + #10 +
    '  import Layout from ' + Q + '../Layout.svelte' + Q + #10 + #10 +
    '  let { name = ' + Q + Q + ' } = $props()' + #10 +
    '</script>' + #10 + #10 +
    '<Layout>' + #10 +
    '  <Heading level={1}>{name}</Heading>' + #10 +
    '  <Text muted class="mb-6">' + #10 +
    '    Served by Askr, rendered by Svelte 5, styled with Lauf.' + #10 +
    '  </Text>' + #10 + #10 +
    '  <Card class="flex flex-col gap-3">' + #10 +
    '    <Text>' + #10 +
    '      Edit <code>frontend/src/pages/Home.svelte</code>, or the' + #10 +
    '      controller in <code>app/Http/App.Http.HomeController.pas</code>.' + #10 +
    '    </Text>' + #10 +
    '    <Button variant="primary" class="self-start"' + #10 +
    '            href="/demo">See the Inertia demo</Button>' + #10 +
    '  </Card>' + #10 +
    '</Layout>' + #10);

  { .env holds secrets and is never checked in. .env.example is, and is the
    list of what a new developer has to fill in. }
  Emit(Root + '/.env',
    '# Local settings. Never commit this file.' + #10 +
    '# Real environment variables always win over what is set here.' + #10 +
    #10 +
    'APP_ENV=local' + #10 +
    '# The address this app answers on from the outside. Every absolute' + #10 +
    '# URL comes from here -- links in mail, and later canonical and' + #10 +
    '# sitemap. Never taken from the request: Host is a header the' + #10 +
    '# client writes.' + #10 +
    'APP_URL=http://127.0.0.1:8080' + #10 +
    '# The port lives in askr.toml as [app] port. Uncomment to override' + #10 +
    '# it here; a real environment variable wins over both.' + #10 +
    '# APP_PORT=8080' + #10 +
    #10 +
    '# Signs the "remember me" cookie and signed URLs. Changing it logs' + #10 +
    '# everyone out. New one: askr key:generate' + #10 +
    'APP_KEY=' + GenerateAppKey + #10 +
    #10 +
    '# debug | info | warn | error. Format: text | json.' + #10 +
    '# Without LOG_FORMAT: text locally, json when APP_ENV=production.' + #10 +
    'LOG_LEVEL=debug' + #10 +
    '# LOG_FORMAT=text' + #10 +
    '# LOG_FILE=storage/app.log' + #10 +
    #10 +
    '# Needed by askr migrate, db:seed, schema and the rest.' + #10 +
    'DATABASE_URL=sqlite:' + Name + '.db' + #10 +
    '# DATABASE_URL=postgresql://user:pass@127.0.0.1:5432/' + Name + #10 +
    #10 +
    '# memory | database. memory is gone on a restart and not shared' + #10 +
    '# between two nodes; database keeps them in DATABASE_URL.' + #10 +
    '# SESSION_DRIVER=memory' + #10 +
    '# SESSION_LIFETIME=7200' + #10 +
    #10 +
    '# log | resend | smtp | null. log writes to a file instead of' + #10 +
    '# sending, which is what you want in development.' + #10 +
    'MAIL_TRANSPORT=log' + #10 +
    'MAIL_FROM=noreply@localhost' + #10 +
    '# MAIL_LOG=storage/mail.log' + #10 +
    #10 +
    '# resend: get a key at resend.com and verify your domain first.' + #10 +
    '# RESEND_API_KEY=' + #10 +
    #10 +
    '# smtp: MAIL_ENCRYPTION is tls (STARTTLS), ssl or none.' + #10 +
    '# MAIL_HOST=' + #10 +
    '# MAIL_PORT=587' + #10 +
    '# MAIL_USERNAME=' + #10 +
    '# MAIL_PASSWORD=' + #10 +
    '# MAIL_ENCRYPTION=tls' + #10 +
    #10 +
    '# ANTHROPIC_API_KEY=' + #10);

  Emit(Root + '/.env.example',
    '# Copy to .env and fill in. Never commit .env itself.' + #10 +
    #10 +
    'APP_ENV=local' + #10 +
    'APP_URL=' + #10 +
    '# askr key:generate' + #10 +
    'APP_KEY=' + #10 +
    'LOG_LEVEL=info' + #10 +
    'DATABASE_URL=' + #10 +
    '# memory | database' + #10 +
    'SESSION_DRIVER=memory' + #10 +
    #10 +
    '# log | resend | smtp | null' + #10 +
    'MAIL_TRANSPORT=log' + #10 +
    'MAIL_FROM=' + #10 +
    'RESEND_API_KEY=' + #10 +
    'ANTHROPIC_API_KEY=' + #10);

  { storage/ exists from the start, so that a log transport or a file
    upload does not fail on a missing directory. }
  Emit(Root + '/storage/.gitkeep', '');

  WriteAgentsFile(Root, Name);

  Emit(Root + '/.gitignore',
    '.build/' + #10 +
    '.env' + #10 +
    'node_modules/' + #10 +
    { The symlink askr install makes into ~/.askr/pkg. It points at a path
      that differs per machine, and so does not belong in git. }
    'frontend/.askr/' + #10 +
    'public/build/' + #10 +
    'storage/*' + #10 +
    '!storage/.gitkeep' + #10 +
    '*.db' + #10 +
    '*.ppu' + #10 +
    '*.o' + #10);

  if WithAuth then
  begin
    WriteLn;
    MakeAuth(Root, True);
  end;

  WriteLn;
  WriteLn('Done. Next:');
  WriteLn;
  WriteLn('  cd ', Name);
  if WithAuth then
    WriteLn('  askr build && askr migrate');
  WriteLn('  (cd frontend && npm install)');
  WriteLn('  askr serve');

  { Lauf's icons are generated from heroicons and are not checked in. If
    they have not been made, the build fails saying @askrcode/lauf/icons/micro
    does not exist — an error message that says nothing about why. }
  if (Framework <> '') and
     not DirectoryExists(IncludeTrailingPathDelimiter(Framework) +
       'frontend/lauf/src/icons') then
  begin
    WriteLn;
    WriteLn('  NOTE      Lauf''s icons are generated and are not in git.');
    WriteLn('            Run this once, in the framework checkout:');
    WriteLn('              (cd ', Framework, '/frontend/lauf && npm install)');
  end;
end;

{ -------------------------------------------------------- askr make -- }

procedure MakeModel(const Root, Name: string; WithMigration: Boolean);
var
  N, Table_: string;
begin
  N := PascalName(Name);
  Table_ := Plural(SnakeName(N));

  Emit(IncludeTrailingPathDelimiter(Root) + 'app/Models/App.Models.' +
    N + '.pas',
    'unit App.Models.' + N + ';' + #10 + #10 +
    '{$mode Delphi}{$H+}' + #10 + #10 +
    'interface' + #10 + #10 +
    'uses' + #10 +
    '  SysUtils, Askr.Urd.Model;' + #10 + #10 +
    'type' + #10 +
    '  T' + N + ' = class(TModel)' + #10 +
    '  private' + #10 +
    '    FId: Int64;' + #10 +
    '    FName: string;' + #10 +
    '  published' + #10 +
    '    property Id: Int64 read FId write FId;' + #10 +
    '    property Name: string read FName write FName;' + #10 +
    '  public' + #10 +
    '    class procedure Describe(S: TSchema); override;' + #10 +
    '    procedure Rules(V: TValidator); override;' + #10 +
    '  end;' + #10 + #10 +
    'implementation' + #10 + #10 +
    'class procedure T' + N + '.Describe(S: TSchema);' + #10 +
    'begin' + #10 +
    '  S.Table(' + Q + Table_ + Q + ');' + #10 +
    '  { S.Timestamps;   sets created_at and updated_at }' + #10 +
    '  { S.SoftDeletes;  Delete sets deleted_at instead of removing }' + #10 +
    'end;' + #10 + #10 +
    'procedure T' + N + '.Rules(V: TValidator);' + #10 +
    'begin' + #10 +
    '  V.Field(' + Q + 'Name' + Q + ').Required.MaxLen(120);' + #10 +
    'end;' + #10 + #10 +
    'end.' + #10);

  if WithMigration then
    MakeMigration(Root, 'Create' + PascalName(Table_));
end;

{ Every path a generator is about to write, checked before any of them is
  written. Half a set -- a model with no migration because the migration
  was refused -- is worse than none, because it looks like it worked. }
procedure Say(var A: TStringArray; const S: string);
begin
  SetLength(A, Length(A) + 1);
  A[High(A)] := S;
end;

function ModelUnitText(const N: string; const Intro: TStringArray;
  const Fields: TFieldSpecs; Timestamps, SoftDeletes: Boolean;
  const Describe, Rules, Hidden: TStringArray;
  const SchemaUnit, SchemaVar: string; const ExtraUses: string;
  const ExtraTypes: TStringArray; const ExtraFields: TStringArray): string;
var
  B: TStringList;
  I: Integer;

  procedure A(const S: string);
  begin
    B.Add(S);
  end;

begin
  B := TStringList.Create;
  try
    A('unit App.Models.' + N + ';');
    A('');
    A('{$mode Delphi}{$H+}');
    A('');
    A('interface');
    A('');
    A('uses');
    A('  SysUtils, Askr.Urd.Model' + ExtraUses + ';');
    A('');
    A('type');
    { A list of another model is a type of its own: nested specialisation
      cannot be written as a field's type. }
    for I := 0 to High(ExtraTypes) do
      A('  ' + ExtraTypes[I]);
    if Length(ExtraTypes) > 0 then
      A('');
    for I := 0 to High(Intro) do
      if I = 0 then
        A('  { ' + Intro[I])
      else if Intro[I] = '' then
        A('')
      else
        A('    ' + Intro[I]);
    A('  }');
    A('  T' + N + ' = class(TModel)');
    A('  private');
    A('    FId: Int64;');
    for I := 0 to High(Fields) do
      A('    F' + Fields[I].Prop + ': ' + PascalTypeOf(Fields[I]) + ';');
    if Timestamps then
    begin
      A('    FCreatedAt: TDateTime;');
      A('    FUpdatedAt: TDateTime;');
    end;
    if SoftDeletes then
      A('    FDeletedAt: TDateTime;');
    A('  published');
    { A relation's field first: a published field has to come before the
      properties in its section. }
    for I := 0 to High(ExtraFields) do
      A('    ' + ExtraFields[I]);
    A('    property Id: Int64 read FId write FId;');
    for I := 0 to High(Fields) do
      A('    property ' + Fields[I].Prop + ': ' + PascalTypeOf(Fields[I]) +
        ' read F' + Fields[I].Prop + ' write F' + Fields[I].Prop + ';');
    if Timestamps then
    begin
      A('    property CreatedAt: TDateTime read FCreatedAt write FCreatedAt;');
      A('    property UpdatedAt: TDateTime read FUpdatedAt write FUpdatedAt;');
    end;
    if SoftDeletes then
      A('    property DeletedAt: TDateTime read FDeletedAt write FDeletedAt;');
    A('  public');
    A('    class procedure Describe(S: TSchema); override;');
    if Length(Hidden) > 0 then
      A('    class procedure HideFromJson(H: TJsonHidden); override;');
    A('    procedure Rules(V: TValidator); override;');
    A('  end;');
    A('');
    A('implementation');
    A('');
    if Length(Hidden) > 0 then
    begin
      { The typed Add is a class helper in Askr.Urd.Query, next to the
        typed columns it takes -- unless the interface uses it already,
        for a relation's list, and a unit named twice does not compile. }
      A('uses');
      if Pos('Askr.Urd.Query', ExtraUses) > 0 then
        A('  ' + SchemaUnit + ';')
      else
        A('  Askr.Urd.Query, ' + SchemaUnit + ';');
      A('');
    end;
    A('class procedure T' + N + '.Describe(S: TSchema);');
    A('begin');
    for I := 0 to High(Describe) do
      A('  ' + Describe[I]);
    A('end;');
    A('');
    if Length(Hidden) > 0 then
    begin
      A('class procedure T' + N + '.HideFromJson(H: TJsonHidden);');
      A('begin');
      for I := 0 to High(Hidden) do
        A('  H.Add(' + SchemaVar + '.' + Hidden[I] + ');');
      A('end;');
      A('');
    end;
    A('procedure T' + N + '.Rules(V: TValidator);');
    A('begin');
    for I := 0 to High(Rules) do
      A('  ' + Rules[I]);
    A('end;');
    A('');
    A('end.');
    Result := B.Text;
  finally
    B.Free;
  end;
end;

function ManyToManyModelLines(const Model, Target, Relation,
  DescribeLine: string): TStringArray;
begin
  Result := nil;
  SetLength(Result, 5);
  Result[0] := 'In app/Models/App.Models.' + Model + '.pas:';
  Result[1] := '  uses       App.Models.' + Target +
    ', and Askr.Urd.Query where TModelList is not in scope yet';
  Result[2] := '  type       T' + Target + 'List = TModelList<T' + Target + '>;';
  Result[3] := '  published  ' + Relation + ': T' + Target + 'List;    { before the properties }';
  Result[4] := '  Describe   ' + DescribeLine;
end;

function RefuseExisting(const Paths: array of string; Force: Boolean): Boolean;
var
  I: Integer;
  Any: Boolean;
begin
  Result := False;
  if Force then
    Exit;
  Any := False;
  for I := 0 to High(Paths) do
    if FileExists(Paths[I]) then
    begin
      if not Any then
        WriteLn('These are already there, and nothing was written:');
      WriteLn('  ' + Paths[I]);
      Any := True;
    end;
  if Any then
  begin
    WriteLn('');
    WriteLn('A generated file is yours the moment it exists, and this would');
    WriteLn('have written over it. Delete it, or pass --force to replace it.');
    Result := True;
  end;
end;

function MakeModelFromFields(const Root, Name: string;
  const Fields: TFieldSpecs; Timestamps, Force: Boolean): Boolean;
var
  N, Table_, MigName, ModelPath, MigPath, VersionStr: string;
  I: Integer;
  B: TStringList;
  Intro, Describe, Rules: TStringArray;

  procedure A(const S: string);
  begin
    B.Add(S);
  end;

begin
  N := PascalName(Name);
  Table_ := Plural(SnakeName(N));
  MigName := 'Create' + PascalName(Table_);
  ModelPath := IncludeTrailingPathDelimiter(Root) + 'app/Models/App.Models.' +
    N + '.pas';
  MigPath := IncludeTrailingPathDelimiter(Root) + 'database/App.Migrations.' +
    MigName + '.pas';

  if RefuseExisting([ModelPath, MigPath], Force) then
    Exit(False);

  { ---- the model ---- }
  Intro := nil;
  Say(Intro, 'Written by askr make model from the spec below, together with its');
  Say(Intro, 'migration -- so the two start out agreeing. After that it is yours.');
  Say(Intro, '');
  for I := 0 to High(Fields) do
    Say(Intro, '  ' + Fields[I].Column + ': ' + PascalTypeOf(Fields[I]) +
      BoolToStr(Fields[I].Nullable, ' (nullable)', ''));
  Describe := nil;
  Say(Describe, 'S.Table(''' + Table_ + ''');');
  for I := 0 to High(Fields) do
    if DescribeLineOf(Fields[I]) <> '' then
      Say(Describe, DescribeLineOf(Fields[I]));
  { Together with the migration's Timestamps, or not at all. A model that
    maps NOT NULL created_at without setting it is the one way the
    TDateTime-as-NULL change turns into a constraint error. }
  if Timestamps then
    Say(Describe, 'S.Timestamps;');
  Say(Describe, '{ S.SoftDeletes;  Delete sets deleted_at instead of removing }');
  Rules := nil;
  Say(Rules, '{ What the spec stated, and nothing inferred from a name. A column');
  Say(Rules, '  called email is not therefore an email: say so here if it is. }');
  for I := 0 to High(Fields) do
    if RuleLineOf(Fields[I]) <> '' then
      Say(Rules, RuleLineOf(Fields[I]));
  Emit(ModelPath, ModelUnitText(N, Intro, Fields, Timestamps, False,
    Describe, Rules, nil, '', ''));

  { ---- the migration ---- }
  VersionStr := NextVersion(Root);
  B := TStringList.Create;
  try
    A('unit App.Migrations.' + MigName + ';');
    A('');
    A('{$mode Delphi}{$H+}');
    A('');
    A('interface');
    A('');
    A('uses');
    A('  Askr.Norn.Schema, Askr.Norn.Migration;');
    A('');
    A('type');
    A('  T' + MigName + ' = class(TMigration)');
    A('  public');
    A('    class function Version: string; override;');
    A('    procedure Up(S: TSchemaBuilder); override;');
    A('    procedure Down(S: TSchemaBuilder); override;');
    A('  end;');
    A('');
    A('implementation');
    A('');
    A('class function T' + MigName + '.Version: string;');
    A('begin');
    A('  Result := ''' + VersionStr + ''';');
    A('end;');
    A('');
    A('procedure T' + MigName + '.Up(S: TSchemaBuilder);');
    A('begin');
    A('  with S.Create(''' + Table_ + ''') do');
    A('  begin');
    A('    Id;');
    for I := 0 to High(Fields) do
      A('    ' + MigrationLineOf(Fields[I]));
    if Timestamps then
      A('    Timestamps;');
    A('  end;');
    A('end;');
    A('');
    A('procedure T' + MigName + '.Down(S: TSchemaBuilder);');
    A('begin');
    A('  S.Drop(''' + Table_ + ''');');
    A('end;');
    A('');
    A('initialization');
    A('  RegisterMigration(T' + MigName + ');');
    A('');
    A('end.');
    Emit(MigPath, B.Text);
  finally
    B.Free;
  end;
  UpdateIndex(Root, 'database', 'App.Migrations', 'App.Migrations.');

  WriteLn('');
  WriteLn('Next:');
  WriteLn('  askr migrate     makes the ' + Table_ + ' table');
  WriteLn('  askr schema      types its columns from the database');
  { The generator does not migrate. A make command that changes the
    database is a surprise, and in production it is the wrong one. }
  Result := True;
end;

procedure MakeController(const Root, Name: string);
var
  N, Path_: string;
begin
  N := PascalName(Name);
  Path_ := Plural(SnakeName(N));
  Emit(IncludeTrailingPathDelimiter(Root) + 'app/Http/App.Http.' +
    N + 'Controller.pas',
    'unit App.Http.' + N + 'Controller;' + #10 + #10 +
    '{$mode Delphi}{$H+}' + #10 + #10 +
    'interface' + #10 + #10 +
    'uses' + #10 +
    '  SysUtils, Askr.Core.Arena, Askr.Http.Request, Askr.Http.Response,' + #10 +
    '  Askr.Urd.Query, Askr.Urd.Bind, Askr.Inertia;' + #10 + #10 +
    'type' + #10 +
    '  T' + N + 'Controller = class' + #10 +
    '  public' + #10 +
    '    function Index(Req: TRequest): TResponse;' + #10 +
    '    function Show(Req: TRequest): TResponse;' + #10 +
    '    function Store(Req: TRequest): TResponse;' + #10 +
    '  end;' + #10 + #10 +
    'implementation' + #10 + #10 +
    'function T' + N + 'Controller.Index(Req: TRequest): TResponse;' + #10 +
    'begin' + #10 +
    '  Result := Inertia(' + Q + PascalName(Path_) + '/Index' + Q + ', []);' + #10 +
    'end;' + #10 + #10 +
    'function T' + N + 'Controller.Show(Req: TRequest): TResponse;' + #10 +
    'begin' + #10 +
    '  Result := Inertia(' + Q + PascalName(Path_) + '/Show' + Q + ',' + #10 +
    '    [' + Q + 'id' + Q + ', Req.IntParam(' + Q + 'id' + Q + ')]);' + #10 +
    'end;' + #10 + #10 +
    'function T' + N + 'Controller.Store(Req: TRequest): TResponse;' + #10 +
    'begin' + #10 +
    '  Result := InertiaRedirect(' + Q + '/' + Path_ + Q + ');' + #10 +
    'end;' + #10 + #10 +
    'end.' + #10);
end;
procedure MakeMigration(const Root, Name: string);
var
  N, VersionStr, Table_: string;
begin
  N := PascalName(Name);
  VersionStr := NextVersion(Root);
  Table_ := SnakeName(N);
  if Copy(Table_, 1, 7) = 'create_' then
    Delete(Table_, 1, 7);

  { The file name has to be the unit name. Fpc finds no unit called
    anything other than its file, and a timestamp in front would have done
    exactly that. The order comes from Version, not from the file name. }
  Emit(IncludeTrailingPathDelimiter(Root) + 'database/App.Migrations.' +
    N + '.pas',
    'unit App.Migrations.' + N + ';' + #10 + #10 +
    '{$mode Delphi}{$H+}' + #10 + #10 +
    'interface' + #10 + #10 +
    'uses' + #10 +
    '  Askr.Norn.Schema, Askr.Norn.Migration;' + #10 + #10 +
    'type' + #10 +
    '  T' + N + ' = class(TMigration)' + #10 +
    '  public' + #10 +
    '    class function Version: string; override;' + #10 +
    '    procedure Up(S: TSchemaBuilder); override;' + #10 +
    '    procedure Down(S: TSchemaBuilder); override;' + #10 +
    '  end;' + #10 + #10 +
    'implementation' + #10 + #10 +
    'class function T' + N + '.Version: string;' + #10 +
    'begin' + #10 +
    '  Result := ' + Q + VersionStr + Q + ';' + #10 +
    'end;' + #10 + #10 +
    'procedure T' + N + '.Up(S: TSchemaBuilder);' + #10 +
    'begin' + #10 +
    '  with S.Create(' + Q + Table_ + Q + ') do' + #10 +
    '  begin' + #10 +
    '    Id;' + #10 +
    '    Text(' + Q + 'name' + Q + ', 120);' + #10 +
    '    Timestamps;' + #10 +
    '    { SoftDeletes;  adds a nullable, indexed deleted_at }' + #10 +
    '  end;' + #10 +
    'end;' + #10 + #10 +
    'procedure T' + N + '.Down(S: TSchemaBuilder);' + #10 +
    'begin' + #10 +
    '  S.Drop(' + Q + Table_ + Q + ');' + #10 +
    'end;' + #10 + #10 +
    'initialization' + #10 +
    '  RegisterMigration(T' + N + ');' + #10 + #10 +
    'end.' + #10);

  UpdateIndex(Root, 'database', 'App.Migrations', 'App.Migrations.');
end;

function MakePivot(const Root, First, Second: string; Force: Boolean): Boolean;
var
  N1, N2, S1, S2, T1, T2, Pivot, K1, K2, MigName, MigPath, VersionStr: string;
  Lo, Hi: string;
  B: TStringList;
  Lines: TStringArray;
  I: Integer;

  procedure A(const S: string);
  begin
    B.Add(S);
  end;

begin
  Result := False;
  N1 := PascalName(First);
  N2 := PascalName(Second);
  if (N1 = '') or (N2 = '') then
  begin
    WriteLn('A pivot is between two models: askr make pivot Post Tag');
    Exit;
  end;
  S1 := SnakeName(N1);
  S2 := SnakeName(N2);
  if S1 = S2 then
  begin
    WriteLn('A model related to itself needs two key names that say which');
    WriteLn('side is which -- follower_id and followed_id, say. That is a');
    WriteLn('decision rather than a convention: write the migration with');
    WriteLn('askr make migration, and name the keys in BelongsToMany.');
    Exit;
  end;
  T1 := Plural(S1);
  T2 := Plural(S2);
  K1 := S1 + '_id';
  K2 := S2 + '_id';
  if S1 < S2 then
    Pivot := S1 + '_' + S2
  else
    Pivot := S2 + '_' + S1;
  MigName := 'Create' + PascalName(Pivot);
  MigPath := IncludeTrailingPathDelimiter(Root) + 'database/App.Migrations.' +
    MigName + '.pas';
  if RefuseExisting([MigPath], Force) then
    Exit;

  { The key that is not first in the unique index gets its own: the index
    on the pair serves a lookup by its first column only, and loading from
    the other side asks by the second. }
  if K1 < K2 then
  begin
    Lo := K1;
    Hi := K2;
  end
  else
  begin
    Lo := K2;
    Hi := K1;
  end;

  VersionStr := NextVersion(Root);
  B := TStringList.Create;
  try
    A('{ The pivot between ' + T1 + ' and ' + T2 + ', written by');
    A('  askr make pivot ' + N1 + ' ' + N2 + '. Two keys and nothing else: a link that');
    A('  carries data of its own is a model with two BelongsTo. }');
    A('unit App.Migrations.' + MigName + ';');
    A('');
    A('{$mode Delphi}{$H+}');
    A('');
    A('interface');
    A('');
    A('uses');
    A('  Askr.Norn.Schema, Askr.Norn.Migration;');
    A('');
    A('type');
    A('  T' + MigName + ' = class(TMigration)');
    A('  public');
    A('    class function Version: string; override;');
    A('    procedure Up(S: TSchemaBuilder); override;');
    A('    procedure Down(S: TSchemaBuilder); override;');
    A('  end;');
    A('');
    A('implementation');
    A('');
    A('class function T' + MigName + '.Version: string;');
    A('begin');
    A('  Result := ''' + VersionStr + ''';');
    A('end;');
    A('');
    A('procedure T' + MigName + '.Up(S: TSchemaBuilder);');
    A('begin');
    A('  with S.Create(''' + Pivot + ''') do');
    A('  begin');
    A('    { ON DELETE CASCADE: a deleted ' + S1 + ' takes its rows here with it,');
    A('      rather than being refused for having any. }');
    A('    ForeignKey(''' + K1 + ''', ''' + T1 + ''');');
    A('    ForeignKey(''' + K2 + ''', ''' + T2 + ''');');
    A('    UniqueIndex([''' + Lo + ''', ''' + Hi + ''']);');
    A('    Index([''' + Hi + ''']);');
    A('  end;');
    A('end;');
    A('');
    A('procedure T' + MigName + '.Down(S: TSchemaBuilder);');
    A('begin');
    A('  S.Drop(''' + Pivot + ''');');
    A('end;');
    A('');
    A('initialization');
    A('  RegisterMigration(T' + MigName + ');');
    A('');
    A('end.');
    Emit(MigPath, B.Text);
  finally
    B.Free;
  end;
  UpdateIndex(Root, 'database', 'App.Migrations', 'App.Migrations.');

  WriteLn('');
  WriteLn('Next:');
  WriteLn('  askr migrate     makes the ' + Pivot + ' table');
  WriteLn('');
  Lines := ManyToManyModelLines(N1, N2, PascalName(T2),
    'S.BelongsToMany(''' + PascalName(T2) + ''', T' + N2 + ');');
  for I := 0 to High(Lines) do
    WriteLn(Lines[I]);
  WriteLn('');
  WriteLn('One side only, unless both models are in one unit: two units cannot');
  WriteLn('use each other. The pivot works from either; the side you load from is');
  WriteLn('the one that needs the field.');
  Result := True;
end;

procedure MakeSeeder(const Root, Name: string);
var
  N: string;
begin
  N := PascalName(Name);
  Emit(IncludeTrailingPathDelimiter(Root) + 'database/App.Seeders.' +
    N + '.pas',
    'unit App.Seeders.' + N + ';' + #10 + #10 +
    '{$mode Delphi}{$H+}' + #10 + #10 +
    'interface' + #10 + #10 +
    'uses' + #10 +
    '  SysUtils, Askr.Core.Arena, Askr.Urd.Driver, Askr.Console;' + #10 + #10 +
    'type' + #10 +
    '  T' + N + ' = class(TSeeder)' + #10 +
    '  public' + #10 +
    '    procedure Run(Conn: TDbConnection); override;' + #10 +
    '  end;' + #10 + #10 +
    'implementation' + #10 + #10 +
    'procedure T' + N + '.Run(Conn: TDbConnection);' + #10 +
    'var' + #10 +
    '  A: TArena;' + #10 +
    'begin' + #10 +
    '  { The connection is passed in. If the seeder uses models, set the' + #10 +
    '    ambient arena and database with UseArena and UseDb first. }' + #10 +
    '  A := TArena.Create(64 * 1024);' + #10 +
    '  try' + #10 +
    '    // Conn.Exec(A, ' + Q + 'INSERT INTO ...' + Q + ');' + #10 +
    '  finally' + #10 +
    '    A.Free;' + #10 +
    '  end;' + #10 +
    'end;' + #10 + #10 +
    'initialization' + #10 +
    '  RegisterSeeder(T' + N + ');' + #10 + #10 +
    'end.' + #10);

  UpdateIndex(Root, 'database', 'App.Seeders', 'App.Seeders.');
end;

procedure MakeJob(const Root, Name: string);
var
  N, Name_: string;
begin
  N := PascalName(Name);
  Name_ := SnakeName(N);
  Emit(IncludeTrailingPathDelimiter(Root) + 'app/Jobs/App.Jobs.' + N + '.pas',
    'unit App.Jobs.' + N + ';' + #10 + #10 +
    '{$mode Delphi}{$H+}' + #10 + #10 +
    'interface' + #10 + #10 +
    'uses' + #10 +
    '  SysUtils, Askr.Core.Text, Askr.Queue;' + #10 + #10 +
    'const' + #10 +
    '  { The name the job is queued under. }' + #10 +
    '  ' + N + 'Job = ' + Q + Name_ + Q + ';' + #10 + #10 +
    'procedure ' + N + '(const Ctx: TJobContext);' + #10 + #10 +
    'implementation' + #10 + #10 +
    'procedure ' + N + '(const Ctx: TJobContext);' + #10 +
    'begin' + #10 +
    '  { The payload lives in the worker arena and dies with the job.' + #10 +
    '    Ctx.Attempt says which attempt this is. }' + #10 +
    '  WriteLn(' + Q + Name_ + ': ' + Q + ', Ctx.Payload.ToString);' + #10 +
    'end;' + #10 + #10 +
    'end.' + #10);
  WriteLn;
  WriteLn('  Register it:  Queue.Handle(' + N + 'Job, @' + N + ');');
end;

procedure MakeMiddleware(const Root, Name: string);
begin
  Emit(IncludeTrailingPathDelimiter(Root) + 'app/Http/App.Http.' +
    PascalName(Name) + '.pas',
    'unit App.Http.' + PascalName(Name) + ';' + #10 + #10 +
    '{$mode Delphi}{$H+}' + #10 + #10 +
    'interface' + #10 + #10 +
    'uses' + #10 +
    '  SysUtils, Askr.Http.Request, Askr.Http.Response;' + #10 + #10 +
    '{ Return nil to let the request through, or a response to stop it. }' + #10 +
    'function ' + PascalName(Name) + '(Req: TRequest): TResponse;' + #10 + #10 +
    'implementation' + #10 + #10 +
    'function ' + PascalName(Name) + '(Req: TRequest): TResponse;' + #10 +
    'begin' + #10 +
    '  Result := nil;' + #10 +
    'end;' + #10 + #10 +
    'end.' + #10);
  WriteLn;
  WriteLn('  Register it:  R.Use(@' + PascalName(Name) + ');');
end;

end.
