{ Askr.Cli.Scaffold — askr new og askr make.

  Malene er små med vilje. Et stillas som genererer femten filer man ikke
  forstår er verre enn ingen stillas: målet i PRD-en er en CRUD-app skrevet
  fra bunnen på under en time av noen som ikke har skrevet Askr før, og da
  må det som genereres være lesbart i sin helhet. }
unit Askr.Cli.Scaffold;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, Askr.Core.Crypto, Askr.Core.Version;

procedure NyttProsjekt(const ForeldreMappe, Name: string;
  MedAuth: Boolean = False);
procedure LagModell(const Rot, Name: string; MedMigrasjon: Boolean);
procedure LagKontroller(const Rot, Name: string);
procedure LagMigrasjon(const Rot, Name: string);
procedure LagSeeder(const Rot, Name: string);
procedure LagJobb(const Rot, Name: string);
procedure LagMiddleware(const Rot, Name: string);

{ Eksponert fordi Askr.Cli.Auth skriver filer på samme måte, og fordi to
  ulike måter å skrive en generert fil på ville gitt to ulike utskrifter. }
procedure Skriv(const Sti, Innhold: string);
function Tidsstempel: string;
procedure OppdaterIndeks(const Rot, Mappe, IndeksUnit, Prefiks: string);

implementation

uses
  { I implementation, ikke i interface: Askr.Cli.Auth bruker Skriv og
    OppdaterIndeks herfra, og Pascal tillater sirkelen bare når minst én
    av dem står her. }
  Askr.Cli.Auth;

const
  Q = '''';

{ ----------------------------------------------------------- hjelpere -- }

procedure Skriv(const Sti, Innhold: string);
var
  L: TStringList;
begin
  ForceDirectories(ExtractFilePath(Sti));
  L := TStringList.Create;
  try
    L.Text := Innhold;
    { TStringList legger på et linjeskift til slutt. Innholdet er skrevet
      med #10 hele veien, og SaveToFile skal ikke oversette dem. }
    L.TrailingLineBreak := False;
    L.SaveToFile(Sti);
  finally
    L.Free;
  end;
  WriteLn('  new  ', Sti);
end;

function PascalNavn(const S: string): string;
var
  I: Integer;
  Stor: Boolean;
begin
  Result := '';
  Stor := True;
  for I := 1 to Length(S) do
  begin
    if (S[I] = '_') or (S[I] = '-') or (S[I] = ' ') then
    begin
      Stor := True;
      Continue;
    end;
    if Stor then
      Result := Result + UpCase(S[I])
    else
      Result := Result + S[I];
    Stor := False;
  end;
end;

function SnakeNavn(const S: string): string;
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

{ Engelsk flertall, i den grad en tabell trenger det. Samme regler som
  Askr.Urd.Model bruker, og de er med vilje enkle: en modell som heter noe
  uregelmessig setter tabellnavnet selv i Describe. }
function Flertall(const S: string): string;
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

function Tidsstempel: string;
var
  Y, M, D, H, Mi, Se, Ms: Word;
begin
  DecodeDate(Now, Y, M, D);
  DecodeTime(Now, H, Mi, Se, Ms);
  Result := Format('%.4d%.2d%.2d%.2d%.2d%.2d', [Y, M, D, H, Mi, Se]);
end;

{ Rammeverkets rot. ASKR_HOME først, så oppover fra denne katalogen — en
  app laget inne i repoet skal finne det uten at noen setter noe. }
function AskrRot: string;
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

{ Samler alle App.Migrations.*-unitene i én som bare «uses» dem.

  Hver migrasjon registrerer seg selv i sin egen initialization-seksjon,
  slik driverne gjør. Men en unit ingen refererer blir aldri linket inn av
  fpc, og da kjører ikke initialization. Indeksen finnes bare for å
  referere dem.

  Den leses av katalogen og ikke av en liste vi holder i hodet: en fil lagt
  til for hånd, eller en som er slettet, skal ikke kunne bli usynlig. Det er
  samme regel som at Norn-codegen leser databasen og ikke migrasjonene. }
procedure OppdaterIndeks(const Rot, Mappe, IndeksUnit, Prefiks: string);
var
  R: TSearchRec;
  Navn: TStringList;
  Kilde, Sti: string;
  I: Integer;
begin
  Sti := IncludeTrailingPathDelimiter(Rot) + Mappe;
  Navn := TStringList.Create;
  try
    Navn.Sorted := True;
    if FindFirst(IncludeTrailingPathDelimiter(Sti) + Prefiks + '*.pas',
      faAnyFile, R) = 0 then
    begin
      repeat
        if R.Name <> IndeksUnit + '.pas' then
          Navn.Add(ChangeFileExt(R.Name, ''));
      until FindNext(R) <> 0;
      FindClose(R);
    end;

    Kilde := 'unit ' + IndeksUnit + ';' + #10 + #10 +
      '{ GENERATED by askr make. Do not edit; it is rewritten.' + #10 + #10 +
      '  Each unit below registers itself in its own initialization.' + #10 +
      '  This unit exists only so fpc links them in: a unit nothing' + #10 +
      '  references never runs its initialization. }' + #10 + #10 +
      '{$mode Delphi}{$H+}' + #10 + #10 +
      'interface' + #10 + #10 +
      'implementation' + #10 + #10;
    if Navn.Count = 0 then
      Kilde := Kilde + 'end.' + #10
    else
    begin
      Kilde := Kilde + 'uses' + #10;
      for I := 0 to Navn.Count - 1 do
        if I < Navn.Count - 1 then
          Kilde := Kilde + '  ' + Navn[I] + ',' + #10
        else
          Kilde := Kilde + '  ' + Navn[I] + ';' + #10;
      Kilde := Kilde + #10 + 'end.' + #10;
    end;
    Skriv(IncludeTrailingPathDelimiter(Sti) + IndeksUnit + '.pas', Kilde);
  finally
    Navn.Free;
  end;
end;

{ --------------------------------------------------------- askr new -- }

procedure NyttProsjekt(const ForeldreMappe, Name: string;
  MedAuth: Boolean);
var
  Rot, Rammeverk, LaufDep, Pin: string;
begin
  Rot := IncludeTrailingPathDelimiter(ForeldreMappe) + Name;
  if DirectoryExists(Rot) then
  begin
    WriteLn('There is already a directory called ', Name, '.');
    Halt(1);
  end;
  Rammeverk := AskrRot;
  { Finnes en utsjekking ved siden av, peker prosjektet på den — det er
    slik rammeverket utvikles. Ellers står bare versjonen, og `askr
    install` henter den. }
  if Rammeverk <> '' then
    Pin := 'path = "' + Rammeverk + '"'
  else
    Pin := '# path = "/path/to/askrcode"';

  WriteLn('Lager ', Name);
  WriteLn;

  { Seksjonen står sist med vilje: i TOML hører alt etter en [seksjon] til
    den, så en [app] i midten ville gjort units og askr til app.units og
    app.askr — og byggingen ville sluttet å finne rammeverket. }
  Skriv(Rot + '/askr.toml',
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

  if Rammeverk = '' then
  begin
    WriteLn;
    WriteLn('  WARNING   could not find the framework. Set the askr path in');
    WriteLn('            askr.toml, or set ASKR_HOME and run `askr new` again.');
  end;

  Skriv(Rot + '/app.lpr',
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
    { Denne linja er markøren `askr make auth` setter inn foran. Endrer
      du den, må uses-linjene legges til for hånd — verktøyet sier fra. }
    '  App.Http.HomeController;' + #10 + #10 +
    'var' + #10 +
    '  Server: TAskrServer;' + #10 +
    '  DbPool: TDbPool;' + #10 + #10 +
    '{ Én forbindelse per request. Uten dette har modellene og query' + #10 +
    '  builderen ingen forbindelse å bruke, og det merkes først når noe' + #10 +
    '  faktisk spør databasen.' + #10 +
    '' + #10 +
    '  Acquire og Release, ikke Lease: en leaset forbindelse leveres' + #10 +
    '  tilbake når arenaen nullstilles, og det skjer først ved NESTE' + #10 +
    '  request på denne workeren. Med flere workere enn forbindelser i' + #10 +
    '  poolen låser det seg. Her leveres den tilbake når svaret er laget. }' + #10 +
    'function LeaseDb(Req: TRequest): TResponse;' + #10 +
    'begin' + #10 +
    '  UseDb(DbPool.Acquire);' + #10 +
    '  Result := nil;' + #10 +
    'end;' + #10 + #10 +
    'function ReleaseDb(Req: TRequest; Res: TResponse): TResponse;' + #10 +
    'var' + #10 +
    '  C: TDbConnection;' + #10 +
    'begin' + #10 +
    '  { Etterfiltre kjører også når middleware kortsluttet requesten, så' + #10 +
    '    en statisk fil som aldri nådde LeaseDb er dekket av nil-sjekken. }' + #10 +
    '  C := CurrentDb;' + #10 +
    '  UseDb(nil);' + #10 +
    '  if C <> nil then' + #10 +
    '    DbPool.Release(C);' + #10 +
    '  Result := Res;' + #10 +
    'end;' + #10 + #10 +
    'procedure Stopp(Sig: cint); cdecl;' + #10 +
    'begin' + #10 +
    '  if Server <> nil then' + #10 +
    '    Server.Stop;' + #10 +
    'end;' + #10 + #10 +
    'var' + #10 +
    '  Opts: TServerOptions;' + #10 +
    '  R: TRouter;' + #10 +
    '  Statisk: TStaticFiles;' + #10 +
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
    '  { Tittelen i HTML-skallet. Klienten setter vanligvis sin egen per' + #10 +
    '    side med <svelte:head>; denne er den som star der til den gjor' + #10 +
    '    det, og den som star der hvis den aldri gjor det. }' + #10 +
    '  TInertia.SetTitle(' + Q + Name + Q + ');' + #10 + #10 +
    '  TInertia.SetHead(' + #10 +
    '    ' + Q + '<script type="module" ' + Q + ' +' + #10 +
    '    ' + Q + 'src="http://localhost:5173/build/@vite/client"></script>' + Q + ' +' + #10 +
    '    ' + Q + '<script type="module" ' + Q + ' +' + #10 +
    '    ' + Q + 'src="http://localhost:5173/build/src/main.js"></script>' + Q + ');' + #10 +
    #10 +
    '  Statisk := TStaticFiles.Create(' + Q + 'public' + Q + ');' + #10 +
    '  Home := THomeController.Create;' + #10 +
    '  R := TRouter.Create;' + #10 +
    '  { Static files first: they need neither session nor CSRF, and they' + #10 +
    '    short-circuit the request before any of it runs. }' + #10 +
    '  R.Use(Statisk.Serve);' + #10 +
    '  { askr down / askr up. Står etter de statiske filene, slik at en' + #10 +
    '    vedlikeholdsside med css fortsatt kan serveres. }' + #10 +
    '  UseMaintenance(R);' + #10 + #10 +
    '  { Databasen, hvis DATABASE_URL er satt. En app uten database skal' + #10 +
    '    ikke nektes å starte. }' + #10 +
    '  if Cfg(' + Q + 'database.url' + Q + ') <> ' + Q + Q + ' then' + #10 +
    '  begin' + #10 +
    '    { Minst én forbindelse per worker, ellers står de og venter på' + #10 +
    '      hverandre. Opts.Workers = 0 betyr én per kjerne. }' + #10 +
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
    '    Statisk.Free;' + #10 +
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
    '    fpSignal(SIGINT, @Stopp);' + #10 +
    '    fpSignal(SIGTERM, @Stopp);' + #10 +
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
    '    Statisk.Free;' + #10 +
    '    Home.Free;' + #10 +
    '  end;' + #10 +
    'end.' + #10);

  Skriv(Rot + '/app/Http/App.Http.HomeController.pas',
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

  { Tomme indekser fra start, slik at app.lpr kompilerer før noen har laget
    en eneste migrasjon. }
  OppdaterIndeks(Rot, 'database', 'App.Migrations', 'App.Migrations.');
  OppdaterIndeks(Rot, 'database', 'App.Seeders', 'App.Seeders.');

  { Lauf er frontendlaget i Askr, ikke en valgfri pakke ved siden av. Til
    den er publisert på npm peker avhengigheten på rammeverkskatalogen —
    samme sti som askr.toml allerede kjenner. Når den er publisert, byttes
    denne linja mot et versjonsnummer og ingenting annet endrer seg. }
  if Rammeverk <> '' then
    LaufDep := '"file:' + IncludeTrailingPathDelimiter(Rammeverk) + 'frontend/lauf"'
  else
    LaufDep := '"^0.1.0"';

  Skriv(Rot + '/frontend/package.json',
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

  Skriv(Rot + '/frontend/vite.config.js',
    'import { defineConfig } from ' + Q + 'vite' + Q + #10 +
    'import { svelte } from ' + Q + '@sveltejs/vite-plugin-svelte' + Q + #10 +
    'import tailwindcss from ' + Q + '@tailwindcss/vite' + Q + #10 +
    #10 +
    '// Lauf ligger som file:-avhengighet til den er publisert, altså en' + #10 +
    '// symlink ut av dette treet, og har sine egne kopier av svelte og' + #10 +
    '// @inertiajs for testing. Uten dedupe løser Vite dem hver for seg, og' + #10 +
    '// createInertiaApp setter opp en annen router enn <Form> importerer.' + #10 +
    '// Feilen blir «Cannot read properties of undefined (reading visit)»,' + #10 +
    '// langt fra årsaken.' + #10 +
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

  { Tailwind ser ikke inn i node_modules av seg selv. Uten @source mangler
    hver klasse Lauf bruker fra stilarket, og komponentene kommer ut uten
    styling uten at noe sier hvorfor. }
  Skriv(Rot + '/frontend/src/app.css',
    '@import ' + Q + 'tailwindcss' + Q + ';' + #10 +
    '@import ' + Q + '@askrcode/lauf/theme.css' + Q + ';' + #10 +
    '@source ' + Q + '../node_modules/@askrcode/lauf/src' + Q + ';' + #10 + #10 +
    '/* Tokenene er semantiske. Overstyr dem her for ditt eget uttrykk;' + #10 +
    '   mørk modus følger med, fordi ingen komponent skriver dark:. */' + #10 +
    'body {' + #10 +
    '  background: var(--color-surface);' + #10 +
    '  color: var(--color-fg);' + #10 +
    '  font-family: ui-sans-serif, system-ui, -apple-system, sans-serif;' + #10 +
    '}' + #10);

  Skriv(Rot + '/frontend/src/Layout.svelte',
    '<script>' + #10 +
    '  import { Flash } from ' + Q + '@askrcode/lauf/inertia' + Q + #10 +
    '  let { children } = $props()' + #10 +
    '</script>' + #10 + #10 +
    '<!-- Flash setter opp live-omradene en gang og gjor flash fra Askr om' + #10 +
    '     til toasts. Den ma sta utenfor sidene, ellers byttes omradet ut' + #10 +
    '     ved hver navigering og meldingen leses ikke opp. -->' + #10 +
    '<Flash />' + #10 + #10 +
    '<main class="mx-auto max-w-3xl px-4 pt-10 pb-16">' + #10 +
    '  {@render children?.()}' + #10 +
    '</main>' + #10);

  Skriv(Rot + '/frontend/src/main.js',
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

  Skriv(Rot + '/frontend/src/pages/Home.svelte',
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

  { .env holder hemmeligheter og sjekkes aldri inn. .env.example gjør det,
    og er lista over hva en ny utvikler må fylle ut. }
  Skriv(Rot + '/.env',
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
    '# ANTHROPIC_API_KEY=' + #10);

  Skriv(Rot + '/.env.example',
    '# Copy to .env and fill in. Never commit .env itself.' + #10 +
    #10 +
    'APP_ENV=local' + #10 +
    'APP_URL=' + #10 +
    '# askr key:generate' + #10 +
    'APP_KEY=' + #10 +
    'LOG_LEVEL=info' + #10 +
    'DATABASE_URL=' + #10 +
    'ANTHROPIC_API_KEY=' + #10);

  { storage/ finnes fra start, slik at en loggtransport eller en
    filopplasting ikke feiler på en manglende katalog. }
  Skriv(Rot + '/storage/.gitkeep', '');

  Skriv(Rot + '/.gitignore',
    '.build/' + #10 +
    '.env' + #10 +
    'node_modules/' + #10 +
    'public/build/' + #10 +
    'storage/*' + #10 +
    '!storage/.gitkeep' + #10 +
    '*.db' + #10 +
    '*.ppu' + #10 +
    '*.o' + #10);

  if MedAuth then
  begin
    WriteLn;
    LagAuth(Rot, True);
  end;

  WriteLn;
  WriteLn('Done. Next:');
  WriteLn;
  WriteLn('  cd ', Name);
  if MedAuth then
    WriteLn('  askr build && askr migrate');
  WriteLn('  (cd frontend && npm install)');
  WriteLn('  askr serve');

  { Laufs ikoner genereres fra heroicons og sjekkes ikke inn. Er de ikke
    laget, feiler byggingen med at @askrcode/lauf/icons/micro ikke finnes —
    en feilmelding som ikke sier noe om hvorfor. }
  if (Rammeverk <> '') and
     not DirectoryExists(IncludeTrailingPathDelimiter(Rammeverk) +
       'frontend/lauf/src/icons') then
  begin
    WriteLn;
    WriteLn('  NOTE      Lauf''s icons are generated and are not in git.');
    WriteLn('            Run this once, in the framework checkout:');
    WriteLn('              (cd ', Rammeverk, '/frontend/lauf && npm install)');
  end;
end;

{ -------------------------------------------------------- askr make -- }

procedure LagModell(const Rot, Name: string; MedMigrasjon: Boolean);
var
  N, Tabell: string;
begin
  N := PascalNavn(Name);
  Tabell := Flertall(SnakeNavn(N));

  Skriv(IncludeTrailingPathDelimiter(Rot) + 'app/Models/App.Models.' +
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
    '  S.Table(' + Q + Tabell + Q + ');' + #10 +
    '  { S.Timestamps;   sets created_at and updated_at }' + #10 +
    '  { S.SoftDeletes;  Delete sets deleted_at instead of removing }' + #10 +
    'end;' + #10 + #10 +
    'procedure T' + N + '.Rules(V: TValidator);' + #10 +
    'begin' + #10 +
    '  V.Field(' + Q + 'Name' + Q + ').Required.MaxLen(120);' + #10 +
    'end;' + #10 + #10 +
    'end.' + #10);

  if MedMigrasjon then
    LagMigrasjon(Rot, 'Create' + PascalNavn(Tabell));
end;

procedure LagKontroller(const Rot, Name: string);
var
  N, Sti: string;
begin
  N := PascalNavn(Name);
  Sti := Flertall(SnakeNavn(N));
  Skriv(IncludeTrailingPathDelimiter(Rot) + 'app/Http/App.Http.' +
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
    '  Result := Inertia(' + Q + PascalNavn(Sti) + '/Index' + Q + ', []);' + #10 +
    'end;' + #10 + #10 +
    'function T' + N + 'Controller.Show(Req: TRequest): TResponse;' + #10 +
    'begin' + #10 +
    '  Result := Inertia(' + Q + PascalNavn(Sti) + '/Show' + Q + ',' + #10 +
    '    [' + Q + 'id' + Q + ', Req.IntParam(' + Q + 'id' + Q + ')]);' + #10 +
    'end;' + #10 + #10 +
    'function T' + N + 'Controller.Store(Req: TRequest): TResponse;' + #10 +
    'begin' + #10 +
    '  Result := InertiaRedirect(' + Q + '/' + Sti + Q + ');' + #10 +
    'end;' + #10 + #10 +
    'end.' + #10);
end;
procedure LagMigrasjon(const Rot, Name: string);
var
  N, Versjon, Tabell: string;
begin
  N := PascalNavn(Name);
  Versjon := Tidsstempel;
  Tabell := SnakeNavn(N);
  if Copy(Tabell, 1, 7) = 'create_' then
    Delete(Tabell, 1, 7);

  { Filnavnet må være unit-navnet. Fpc finner ingen unit som heter noe
    annet enn fila si, og et tidsstempel foran ville gjort nettopp det.
    Rekkefølgen kommer fra Version, ikke fra filnavnet. }
  Skriv(IncludeTrailingPathDelimiter(Rot) + 'database/App.Migrations.' +
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
    '  Result := ' + Q + Versjon + Q + ';' + #10 +
    'end;' + #10 + #10 +
    'procedure T' + N + '.Up(S: TSchemaBuilder);' + #10 +
    'begin' + #10 +
    '  with S.Create(' + Q + Tabell + Q + ') do' + #10 +
    '  begin' + #10 +
    '    Id;' + #10 +
    '    Text(' + Q + 'name' + Q + ', 120);' + #10 +
    '    Timestamps;' + #10 +
    '    { SoftDeletes;  adds a nullable, indexed deleted_at }' + #10 +
    '  end;' + #10 +
    'end;' + #10 + #10 +
    'procedure T' + N + '.Down(S: TSchemaBuilder);' + #10 +
    'begin' + #10 +
    '  S.Drop(' + Q + Tabell + Q + ');' + #10 +
    'end;' + #10 + #10 +
    'initialization' + #10 +
    '  RegisterMigration(T' + N + ');' + #10 + #10 +
    'end.' + #10);

  OppdaterIndeks(Rot, 'database', 'App.Migrations', 'App.Migrations.');
end;

procedure LagSeeder(const Rot, Name: string);
var
  N: string;
begin
  N := PascalNavn(Name);
  Skriv(IncludeTrailingPathDelimiter(Rot) + 'database/App.Seeders.' +
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

  OppdaterIndeks(Rot, 'database', 'App.Seeders', 'App.Seeders.');
end;

procedure LagJobb(const Rot, Name: string);
var
  N, Navn: string;
begin
  N := PascalNavn(Name);
  Navn := SnakeNavn(N);
  Skriv(IncludeTrailingPathDelimiter(Rot) + 'app/Jobs/App.Jobs.' + N + '.pas',
    'unit App.Jobs.' + N + ';' + #10 + #10 +
    '{$mode Delphi}{$H+}' + #10 + #10 +
    'interface' + #10 + #10 +
    'uses' + #10 +
    '  SysUtils, Askr.Core.Text, Askr.Queue;' + #10 + #10 +
    'const' + #10 +
    '  { The name the job is queued under. }' + #10 +
    '  ' + N + 'Job = ' + Q + Navn + Q + ';' + #10 + #10 +
    'procedure ' + N + '(const Ctx: TJobContext);' + #10 + #10 +
    'implementation' + #10 + #10 +
    'procedure ' + N + '(const Ctx: TJobContext);' + #10 +
    'begin' + #10 +
    '  { The payload lives in the worker arena and dies with the job.' + #10 +
    '    Ctx.Attempt says which attempt this is. }' + #10 +
    '  WriteLn(' + Q + Navn + ': ' + Q + ', Ctx.Payload.ToString);' + #10 +
    'end;' + #10 + #10 +
    'end.' + #10);
  WriteLn;
  WriteLn('  Register it:  Queue.Handle(' + N + 'Job, @' + N + ');');
end;

procedure LagMiddleware(const Rot, Name: string);
begin
  Skriv(IncludeTrailingPathDelimiter(Rot) + 'app/Http/App.Http.' +
    PascalNavn(Name) + '.pas',
    'unit App.Http.' + PascalNavn(Name) + ';' + #10 + #10 +
    '{$mode Delphi}{$H+}' + #10 + #10 +
    'interface' + #10 + #10 +
    'uses' + #10 +
    '  SysUtils, Askr.Http.Request, Askr.Http.Response;' + #10 + #10 +
    '{ Return nil to let the request through, or a response to stop it. }' + #10 +
    'function ' + PascalNavn(Name) + '(Req: TRequest): TResponse;' + #10 + #10 +
    'implementation' + #10 + #10 +
    'function ' + PascalNavn(Name) + '(Req: TRequest): TResponse;' + #10 +
    'begin' + #10 +
    '  Result := nil;' + #10 +
    'end;' + #10 + #10 +
    'end.' + #10);
  WriteLn;
  WriteLn('  Register it:  R.Use(@' + PascalNavn(Name) + ');');
end;

end.
