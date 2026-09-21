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
  SysUtils, Classes, Askr.Core.Crypto, Askr.Core.Version;

procedure NewProject(const ParentDir, Name: string;
  WithAuth: Boolean = False);
procedure MakeModel(const Root, Name: string; WithMigration: Boolean);
procedure MakeController(const Root, Name: string);
procedure MakeMigration(const Root, Name: string);
procedure MakeSeeder(const Root, Name: string);
procedure MakeJob(const Root, Name: string);
procedure MakeMiddleware(const Root, Name: string);

{ Exposed because Askr.Cli.Auth writes files the same way, and because two
  different ways of writing a generated file would have given two different
  outputs. }
procedure Emit(const Path_, Content_: string);
function Stamp: string;
procedure UpdateIndex(const Root, Folder, IndexUnit, Prefix: string);

implementation

uses
  { In implementation, not in interface: Askr.Cli.Auth uses Emit and
    UpdateIndex from here, and Pascal allows the circle only when at least
    one of them is here. }
  Askr.Cli.Auth;

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

{ English plurals, to the extent a table needs them. The same rules
  Askr.Urd.Model uses, and they are deliberately simple: a model with an
  irregular name sets the table name itself in Describe. }
function Plural(const S: string): string;
var
  Sis: Char;
begin
  if S = '' then
    Exit(S);
  Sis := S[Length(S)];
  if (Sis = 'y') and (Length(S) > 1) and
     (Pos(S[Length(S) - 1], 'aeiou') = 0) then
    Exit(Copy(S, 1, Length(S) - 1) + 'ies');
  if (Sis = 's') or (Sis = 'x') or (Sis = 'z') then
    Exit(S + 'es');
  if (Length(S) >= 2) and
     ((Copy(S, Length(S) - 1, 2) = 'ch') or
      (Copy(S, Length(S) - 1, 2) = 'sh')) then
    Exit(S + 'es');
  Result := S + 's';
end;

function Stamp: string;
var
  Y, M, D, H, Mi, Se, Ms: Word;
begin
  DecodeDate(Now, Y, M, D);
  DecodeTime(Now, H, Mi, Se, Ms);
  Result := Format('%.4d%.2d%.2d%.2d%.2d%.2d', [Y, M, D, H, Mi, Se]);
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
    '  Askr.Session, Askr.Csrf, Askr.Auth,' + #10 +
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
    '  { Static files first: they need neither session nor CSRF, and they' + #10 +
    '    short-circuit the request before any of it runs. }' + #10 +
    '  R.Use(StaticFiles.Serve);' + #10 +
    '  { askr down / askr up. It comes after the static files, so that a' + #10 +
    '    maintenance page with css can still be served. }' + #10 +
    '  UseMaintenance(R);' + #10 + #10 +
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
    '    nor a cookie. }' + #10 +
    '  SetSessions(TSessionStore.Create);' + #10 +
    '  UseSessions(R);' + #10 +
    '  UseCsrf(R);' + #10 +
    '  UseAuth(R);' + #10 + #10 +
    '  R.Get(' + Q + '/' + Q + ', Home.Index);' + #10 +
    '  R.Get(' + Q + '/demo' + Q + ', Home.Demo);' + #10 + #10 +
    '  { The commands the app answers to itself: migrate, db:seed, schema,' + #10 +
    '    routes, about and the rest. Migrations and routes are compiled in' + #10 +
    '    here, so the tool cannot run them — it asks the binary to. See' + #10 +
    '    the whole list with: askr list }' + #10 +
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
    '# Used in links the app sends by mail, such as password resets.' + #10 +
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
    #10 +
    '# log | resend | smtp | null' + #10 +
    'MAIL_TRANSPORT=log' + #10 +
    'MAIL_FROM=' + #10 +
    'RESEND_API_KEY=' + #10 +
    'ANTHROPIC_API_KEY=' + #10);

  { storage/ exists from the start, so that a log transport or a file
    upload does not fail on a missing directory. }
  Emit(Root + '/storage/.gitkeep', '');

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
  VersionStr := Stamp;
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
