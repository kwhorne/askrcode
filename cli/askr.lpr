{ askr — én binær, samme navn som prosjektet.

  Konvensjonen cargo, go, deno og bun har etablert: verktøyet heter det
  språket eller rammeverket heter, og man slipper å huske et eget navn.

  Kommandoene er de PRD-en lister. De som ikke er implementert ennå sier det
  rett ut i stedet for å feile uforklarlig. }
program Askr;

{$mode Delphi}{$H+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  SysUtils, Classes, Process, TermIO,
  Askr.Core.Crypto, Askr.Core.Config,
  Askr.Run, Askr.Cli.Project, Askr.Cli.Serve, Askr.Cli.Scaffold,
  Askr.Cli.Auth;

const
  AskrVersion = '0.6.0';

{ Free Pascal leter etter fpc.cfg i ~/.fpc.cfg og /etc/fpc.cfg på Unix, ikke
  ved siden av binæren. En fpcupdeluxe-installasjon legger den ved binæren,
  og da finner kompilatoren ikke engang system-uniten. Verktøyet peker den ut
  selv i stedet for å la brukeren oppdage det gjennom en kryptisk feil. }
{ Manuell PATH-gjennomgang. ExeSearch og FileSearch er begge finurlige om
  skilletegn på tvers av plattformer. }
function FinnPaaPath(const Navn: string): string;
var
  Deler: TStringList;
  I: Integer;
  Kandidat: string;
begin
  Result := '';
  Deler := TStringList.Create;
  try
    Deler.Delimiter := ':';
    Deler.StrictDelimiter := True;
    Deler.DelimitedText := GetEnvironmentVariable('PATH');
    for I := 0 to Deler.Count - 1 do
    begin
      if Deler[I] = '' then
        Continue;
      Kandidat := IncludeTrailingPathDelimiter(Deler[I]) + Navn;
      if FileExists(Kandidat) then
        Exit(Kandidat);
    end;
  finally
    Deler.Free;
  end;
end;

{ Free Pascal leter etter fpc.cfg i ~/.fpc.cfg og /etc/fpc.cfg på Unix, ikke
  ved siden av binæren. En fpcupdeluxe-installasjon legger den ved binæren,
  og da finner kompilatoren ikke engang system-uniten.

  PPC_CONFIG_PATH ville løst det, men miljøvariabelen når ikke fram til
  barneprosessen: FPCs RTL holder sin egen kopi av miljøet fra oppstart, og
  setenv oppdaterer bare libc sin. Kompilatorflagget virker uansett — det er
  også slik fpcupdeluxe sin egen wrapper gjør det. }
function KompilatorConfigFlagg(const Kompilator: string): string;
var
  Full, Dir, Cfg: string;
begin
  Result := '';
  if GetEnvironmentVariable('PPC_CONFIG_PATH') <> '' then
    Exit;
  Full := Kompilator;
  if ExtractFilePath(Full) = '' then
    Full := FinnPaaPath(Kompilator);
  if Full = '' then
    Exit;
  Dir := ExtractFileDir(ExpandFileName(Full));
  Cfg := IncludeTrailingPathDelimiter(Dir) + 'fpc.cfg';
  if FileExists(Cfg) then
    Result := '-n @' + Cfg;
end;

procedure Si(const S: string);
begin
  WriteLn(S);
end;

procedure Bruk;
begin
  Si('askr ' + AskrVersion);
  Si('');
  Si('  askr new <name> [--auth] new project');
  Si('  askr serve [port]        dev server with hot reload');
  Si('  askr build [--target web|desktop]');
  Si('  askr routes              show the routing table');
  Si('  askr about               what this app is configured with');
  Si('  askr make model <Name>   new model');
  Si('  askr make controller <Name>');
  Si('  askr make migration <Name>');
  Si('  askr make seeder|job|middleware <Name>');
  Si('  askr make auth           /login, /register, /reset-password');
  Si('  askr migrate             run pending migrations');
  Si('  askr migrate:status|:rollback|:reset|:fresh|:refresh');
  Si('  askr db:seed|db:show|db:table|db:wipe');
  Si('  askr schema              typed columns from the database');
  Si('  askr queue:work|queue:status');
  Si('  askr schedule:list|schedule:run');
  Si('  askr cache:clear   askr down   askr up');
  Si('  askr key:generate        print a new APP_KEY');
  Si('  askr config [--values]   show the effective configuration');
  Si('  askr test                build and run the app test suite');
  Si('  askr version');
  Si('');
  Si('Commands read askr.toml in the project root.');
  Si('The app answers many of them itself; see: askr list');
end;

function FinnProsjekt: TProject;
begin
  Result := TProject.Find(GetCurrentDir);
  if Result = nil then
  begin
    Si('No askr.toml here or in any directory above.');
    Si('Create a project with: askr new <name>');
    Halt(1);
  end;
end;

{ Kjører appbinæren med et flagg, og lar den svare selv. Ruter og migrasjoner
  er appens kunnskap, ikke verktøyets. }
function KjorApp(P: TProject; const Flagg: string): Integer;
var
  Proc: TProcess;
  Bin: string;
  I: Integer;
begin
  Bin := IncludeTrailingPathDelimiter(P.Root) + '.build' + PathDelim +
    'bin' + PathDelim + ChangeFileExt(ExtractFileName(P.MainFile), '');
  if not FileExists(Bin) then
  begin
    Si('The app is not built. Run: askr build');
    Exit(1);
  end;
  Proc := TProcess.Create(nil);
  try
    Proc.Executable := Bin;
    Proc.Parameters.Add(Flagg);
    { Alt etter kommandoen sendes med: «askr db:table posts» og
      «askr migrate:rollback --step=2» skal virke. Uten dette kom flagget
      alene fram, og argumentet forsvant på veien. }
    for I := 2 to ParamCount do
      Proc.Parameters.Add(ParamStr(I));
    Proc.CurrentDirectory := P.Root;
    Proc.Options := [poWaitOnExit];
    Proc.Execute;
    Result := Proc.ExitStatus;
  finally
    Proc.Free;
  end;
end;

{ Kommandoene appbinæren svarer på. Lista står i Askr.Console; her er den
  bare speilet, fordi verktøyet må vite hva det skal videresende før det
  har spurt binæren om noe. }
function ErAppKommando(const K: string): Boolean;
const
  Appens: array[0..21] of string = (
    'about', 'routes', 'migrate', 'migrate:status', 'migrate:rollback',
    'migrate:reset', 'migrate:fresh', 'migrate:refresh', 'db:seed',
    'db:show', 'db:table', 'db:wipe', 'schema', 'queue:work',
    'queue:status', 'schedule:list', 'schedule:run', 'cache:clear',
    'down', 'up', 'env', 'list');
var
  I: Integer;
begin
  for I := Low(Appens) to High(Appens) do
    if Appens[I] = K then
      Exit(True);
  Result := False;
end;

function ByggFlagg(P: TProject): string;
const
  { Rammeverkets units. Rekkefølgen spiller ingen rolle for fpc. }
  { `cli` er med fordi Askr.Console ligger der: kommandoene appen svarer
    på selv er en del av rammeverket, ikke av verktøyet. }
  AskrUnits: array[0..8] of string =
    ('core', 'http', 'urd', 'norn', 'inertia', 'desktop', 'runtime', 'run',
     'cli');
var
  Stier: TStringArray;
  I: Integer;
  Ramme, Cfg: string;
begin
  Result := P.CompilerFlags;

  Cfg := KompilatorConfigFlagg(P.Compiler);
  if Cfg <> '' then
    Result := Cfg + ' ' + Result;

  Ramme := P.AskrPath;
  if (Ramme = '') or not DirectoryExists(IncludeTrailingPathDelimiter(Ramme) +
     'src' + PathDelim + 'core') then
  begin
    Si('askr.toml does not point at the framework.');
    Si('Set  askr = "/path/to/askrcode"  in askr.toml.');
    Halt(1);
  end;
  if Ramme <> '' then
    for I := Low(AskrUnits) to High(AskrUnits) do
      Result := Result + ' -Fu' + IncludeTrailingPathDelimiter(Ramme) +
        'src' + PathDelim + AskrUnits[I];

  Stier := P.UnitPaths;
  for I := 0 to High(Stier) do
    if DirectoryExists(IncludeTrailingPathDelimiter(P.Root) + Stier[I]) then
      { Mappa selv og ett nivå under. -Fu<dir>/* er FPCs egen form for det,
        og sparer brukeren for å liste opp app/Http, app/Models og resten. }
      Result := Result + ' -Fu' + Stier[I] + ' -Fu' + Stier[I] + PathDelim + '*';
end;

{ --target web (standard) eller --target desktop. Samme kodebase, to skall;
  det er hele poenget med at forskjellen er én unit. }
function HovedFil(P: TProject): string;
var
  I: Integer;
  Target: string;
begin
  Target := 'web';
  for I := 1 to ParamCount - 1 do
    if (ParamStr(I) = '--target') or (ParamStr(I) = '-t') then
      Target := LowerCase(ParamStr(I + 1));

  if Target = 'desktop' then
  begin
    Result := P.DesktopMainFile;
    if Result = '' then
    begin
      Si('This project has no desktop target.');
      Si('Set  main_desktop = "desktopmain.lpr"  in askr.toml.');
      Halt(1);
    end;
    Exit;
  end;
  if Target <> 'web' then
  begin
    Si('Ukjent target: ' + Target + '. Bruk web eller desktop.');
    Halt(1);
  end;
  Result := P.MainFile;
end;

{ Oversetter hver .run-fil i prosjektet til en Pascal-unit under
  .build/run, som legges på søkestien. Kjøres før kompilatoren, slik at
  `askr build` og `askr serve` bare virker — språket skal ikke kreve et
  eget steg man må huske. }
function KjorRun(P: TProject; Stille: Boolean): Boolean;
var
  Filer: TStringList;
  Rec: TSearchRec;
  Dir, UtDir, Ut, UnitName: string;
  Stier: TStringArray;
  I, J: Integer;
  Stats: TRunStats;
begin
  Result := True;
  UtDir := IncludeTrailingPathDelimiter(P.Root) + '.build' + PathDelim + 'run';
  Filer := TStringList.Create;
  try
    Stier := P.UnitPaths;
    for I := 0 to High(Stier) do
    begin
      Dir := IncludeTrailingPathDelimiter(P.Root) + Stier[I];
      if not DirectoryExists(Dir) then
        Continue;
      if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*.run',
                   faAnyFile, Rec) = 0 then
      begin
        repeat
          Filer.Add(IncludeTrailingPathDelimiter(Dir) + Rec.Name);
        until FindNext(Rec) <> 0;
        FindClose(Rec);
      end;
    end;
    if Filer.Count = 0 then
      Exit;

    ForceDirectories(UtDir);
    for J := 0 to Filer.Count - 1 do
    begin
      UnitName := UnitNameFor(Filer[J], 'App');
      Ut := IncludeTrailingPathDelimiter(UtDir) + UnitName + '.pas';
      try
        Stats := Transpile(Filer[J], Ut, UnitName);
        if not Stille then
          Si(Format('  run       %s -> %s  (%d models, %d queries, %d ms)',
            [ExtractFileName(Filer[J]), UnitName,
             Stats.Models, Stats.Queries, Stats.TotalMs]));
      except
        on E: ERunError do
        begin
          Si(E.Message);
          Exit(False);
        end;
      end;
    end;
  finally
    Filer.Free;
  end;
end;

procedure CmdBuild(P: TProject);
var
  Proc: TProcess;
  Lines: TStringList;
  Flagg: TStringArray;
  I: Integer;
  Params: TStringList;
  Hoved: string;
begin
  Hoved := HovedFil(P);
  if not KjorRun(P, False) then
    Halt(1);
  ForceDirectories(IncludeTrailingPathDelimiter(P.Root) + '.build/units');
  ForceDirectories(IncludeTrailingPathDelimiter(P.Root) + '.build/bin');

  Proc := TProcess.Create(nil);
  Lines := TStringList.Create;
  Params := TStringList.Create;
  try
    Params.Delimiter := ' ';
    Params.StrictDelimiter := True;
    Params.DelimitedText := ByggFlagg(P);
    Proc.Executable := P.Compiler;
    for I := 0 to Params.Count - 1 do
      if Params[I] <> '' then
        Proc.Parameters.Add(Params[I]);
    Proc.Parameters.Add('-Fu.build' + PathDelim + 'run');
    Proc.Parameters.Add('-FU.build/units');
    Proc.Parameters.Add('-FE.build/bin');
    Proc.Parameters.Add(Hoved);
    Proc.CurrentDirectory := P.Root;
    Proc.Options := [poWaitOnExit, poUsePipes, poStderrToOutPut];
    Proc.Execute;
    Lines.LoadFromStream(Proc.Output);
    if Proc.ExitStatus <> 0 then
    begin
      Write(Lines.Text);
      Halt(1);
    end;
    Si('Bygget .build/bin/' + ChangeFileExt(ExtractFileName(Hoved), ''));
  finally
    Params.Free;
    Lines.Free;
    Proc.Free;
  end;
end;

{ Bygger og kjører prosjektets testprogram. Rammeverket er Askr.Testing;
  verktøyet gjør bare bygg og kjør. }
procedure CmdTest(P: TProject);
var
  Proc: TProcess;
  Lines, Params: TStringList;
  I: Integer;
  Fil, Bin: string;
begin
  Fil := P.TestFile;
  if not FileExists(IncludeTrailingPathDelimiter(P.Root) + Fil) then
  begin
    Si('No tests found: ' + Fil);
    Si('Write one, or set  tests = "path/to/tests.lpr"  in askr.toml.');
    Halt(1);
  end;

  ForceDirectories(IncludeTrailingPathDelimiter(P.Root) + '.build/units');
  ForceDirectories(IncludeTrailingPathDelimiter(P.Root) + '.build/bin');

  Proc := TProcess.Create(nil);
  Lines := TStringList.Create;
  Params := TStringList.Create;
  try
    Params.Delimiter := ' ';
    Params.StrictDelimiter := True;
    Params.DelimitedText := ByggFlagg(P);
    Proc.Executable := P.Compiler;
    for I := 0 to Params.Count - 1 do
      if Params[I] <> '' then
        Proc.Parameters.Add(Params[I]);
    Proc.Parameters.Add('-FU.build/units');
    Proc.Parameters.Add('-FE.build/bin');
    Proc.Parameters.Add(Fil);
    Proc.CurrentDirectory := P.Root;
    Proc.Options := [poWaitOnExit, poUsePipes, poStderrToOutPut];
    Proc.Execute;
    Lines.LoadFromStream(Proc.Output);
    if Proc.ExitStatus <> 0 then
    begin
      Write(Lines.Text);
      Halt(1);
    end;
  finally
    Params.Free;
    Lines.Free;
    Proc.Free;
  end;

  Bin := IncludeTrailingPathDelimiter(P.Root) + '.build' + PathDelim +
    'bin' + PathDelim + ChangeFileExt(ExtractFileName(Fil), '');
  Proc := TProcess.Create(nil);
  try
    Proc.Executable := Bin;
    Proc.CurrentDirectory := P.Root;
    Proc.Options := [poWaitOnExit];
    Proc.Execute;
    Halt(Proc.ExitStatus);
  finally
    Proc.Free;
  end;
end;

procedure CmdServe(P: TProject);
var
  Opts: TServeOptions;
  Srv: TDevServer;
  Dirs: TStringArray;
  I: Integer;
begin
  Opts := DefaultServeOptions;
  Opts.Root := P.Root;
  Opts.MainFile := P.MainFile;
  Opts.BinaryName := ChangeFileExt(ExtractFileName(P.MainFile), '');
  Opts.Compiler := P.Compiler;
  Opts.CompilerFlags := ByggFlagg(P);
  Opts.PublicPort := P.Port;
  Opts.BackendPort := P.BackendPort;
  Opts.FrontendDir := P.FrontendDir;

  if ParamCount >= 2 then
    Opts.PublicPort := Word(StrToIntDef(ParamStr(2), Opts.PublicPort));

  Dirs := P.WatchDirs;
  SetLength(Opts.WatchDirs, 0);
  for I := 0 to High(Dirs) do
  begin
    SetLength(Opts.WatchDirs, Length(Opts.WatchDirs) + 1);
    { En absolutt sti skal ikke få prosjektrota limt foran seg. }
    if (Dirs[I] <> '') and (Dirs[I][1] = PathDelim) then
      Opts.WatchDirs[High(Opts.WatchDirs)] := Dirs[I]
    else
      Opts.WatchDirs[High(Opts.WatchDirs)] :=
        IncludeTrailingPathDelimiter(P.Root) + Dirs[I];
  end;

  Si('askr serve — ' + P.Name);
  Srv := TDevServer.Create(Opts);
  try
    Srv.Run;
  finally
    Srv.Free;
  end;
end;

{ FindCmdLineSwitch tolker --migration som svitsjen «-migration», og
  treffer ikke. Enklere å se etter argumentet selv. }
function HarFlagg(const Flagg: string): Boolean;
var
  I: Integer;
begin
  for I := 1 to ParamCount do
    if (ParamStr(I) = '--' + Flagg) or (ParamStr(I) = '-' + Flagg) then
      Exit(True);
  Result := False;
end;

{ Skal prosjektet ha innlogging?

  --auth og --no-auth svarer for den som kjører fra et skript. Uten et av
  dem spørres det, men bare når det faktisk står et menneske der: en
  kommando som venter på svar fra en pipe henger for alltid. }
function VilHaAuth: Boolean;
var
  Svar: string;
begin
  if HarFlagg('auth') then
    Exit(True);
  if HarFlagg('no-auth') then
    Exit(False);
  if IsATTY(Input) = 0 then
    Exit(False);

  Write('Does this project need sign-in? [y/N] ');
  Flush(Output);
  ReadLn(Svar);
  Svar := LowerCase(Trim(Svar));
  Result := (Svar = 'y') or (Svar = 'yes');
end;

procedure CmdMake(P: TProject);
var
  Slag, Navn: string;
begin
  Slag := LowerCase(ParamStr(2));
  Navn := ParamStr(3);
  { auth tar ikke noe navn — det er ett sett filer, ikke en type. }
  if Slag = 'auth' then
    Navn := 'auth';
  if (Slag = '') or (Navn = '') then
  begin
    Si('Usage: askr make model|controller|migration|seeder|job|' +
      'middleware <Name>');
    Si('       askr make auth [--force]');
    Halt(1);
  end;
  if Slag = 'model' then
    LagModell(P.Root, Navn, HarFlagg('migration'))
  else if Slag = 'controller' then
    LagKontroller(P.Root, Navn)
  else if Slag = 'migration' then
    LagMigrasjon(P.Root, Navn)
  else if Slag = 'seeder' then
    LagSeeder(P.Root, Navn)
  else if Slag = 'job' then
    LagJobb(P.Root, Navn)
  else if Slag = 'middleware' then
    LagMiddleware(P.Root, Navn)
  else if Slag = 'auth' then
    LagAuth(P.Root, HarFlagg('force'))
  else
  begin
    Si('Ukjent: ' + Slag);
    Halt(1);
  end;
end;

var
  Kommando: string;
  P: TProject;
begin
  Kommando := LowerCase(ParamStr(1));

  if (Kommando = '') or (Kommando = 'help') or (Kommando = '-h') or
     (Kommando = '--help') then
  begin
    Bruk;
    Exit;
  end;

  if (Kommando = 'version') or (Kommando = '-v') or (Kommando = '--version') then
  begin
    Si('askr ' + AskrVersion);
    Exit;
  end;

  { key:generate trenger ikke et prosjekt. Den skriver bare nøkkelen ut, og
    setter den ikke inn i .env selv: en kommando som skriver i .env kan
    ikke vite om den overskriver noe som allerede er i bruk, og en nøkkel
    som blir byttet ut i stillhet logger ut alle. }
  if Kommando = 'key:generate' then
  begin
    WriteLn('APP_KEY=' + GenerateAppKey);
    Exit;
  end;

  if Kommando = 'new' then
  begin
    if ParamStr(2) = '' then
    begin
      Si('Bruk: askr new <navn>');
      Halt(1);
    end;
    NyttProsjekt(GetCurrentDir, ParamStr(2), VilHaAuth);
    Exit;
  end;

  P := FinnProsjekt;
  try
    if Kommando = 'build' then
      CmdBuild(P)
    else if Kommando = 'serve' then
      CmdServe(P)
    else if Kommando = 'routes' then
      Halt(KjorApp(P, '--routes'))
    else if ErAppKommando(Kommando) then
      { Kommandoen hører til appen, ikke til verktøyet: migrasjonene,
        rutene, jobbene og planen er kompilert inn i binæren. Argumentene
        sendes med, slik at --step og --seed virker. }
      Halt(KjorApp(P, '--' + Kommando))
    else if Kommando = 'make' then
      CmdMake(P)
    else if Kommando = 'test' then
      CmdTest(P)
    else if Kommando = 'config' then
    begin
      { Kjøres fra prosjektrota, slik at .env og askr.toml finnes der de
        skal. Verdiene vises bare når noen ber om det: uten --values er
        utskriften trygg å lime inn i en feilrapport. }
      SetCurrentDir(P.Root);
      LoadConfig(P.Root);
      Write(ConfigReport(HarFlagg('values')));
    end
    else if Kommando = 'run' then
    begin
      { Oversetter .run-filene uten å kompilere. Nyttig når man vil se på
        Pascal-koden som kommer ut. }
      if not KjorRun(P, False) then
        Halt(1);
    end
    else if Kommando = 'repl' then
    begin
      Si('repl is not implemented. It needs an interpreter for Pascal');
      Si('expressions, and is not worth it before the phase 3 language call.');
      Halt(1);
    end
    else
    begin
      Si('Ukjent kommando: ' + Kommando);
      Si('');
      Bruk;
      Halt(1);
    end;
  finally
    P.Free;
  end;
end.
