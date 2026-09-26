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
  Askr.Core.Crypto, Askr.Core.Config, Askr.Core.Version,
  Askr.Run, Askr.Cli.Project, Askr.Cli.Serve, Askr.Cli.Scaffold,
  Askr.Cli.Auth, Askr.Cli.Pkg, Askr.Cli.Plugins, Askr.Cli.Mcp, Askr.Cli.Diag, Askr.Cli.Docs,
  Askr.Console.Commands, Askr.Cli.Fields, Askr.Cli.Resource, Askr.Cli.Lang,
  Askr.Urd.Driver, Askr.Norn.Introspect,
  Askr.Core.Arena, Askr.Core.Json, Askr.Core.Text;

{ Free Pascal leter etter fpc.cfg i ~/.fpc.cfg og /etc/fpc.cfg på Unix, ikke
  ved siden av binæren. En fpcupdeluxe-installasjon legger den ved binæren,
  og da finner kompilatoren ikke engang system-uniten. Verktøyet peker den ut
  selv i stedet for å la brukeren oppdage det gjennom en kryptisk feil. }
{ Manuell PATH-gjennomgang. ExeSearch og FileSearch er begge finurlige om
  skilletegn på tvers av plattformer. }
function FindOnPath(const Name_: string): string;
var
  Parts_: TStringList;
  I: Integer;
  Candidate: string;
begin
  Result := '';
  Parts_ := TStringList.Create;
  try
    Parts_.Delimiter := ':';
    Parts_.StrictDelimiter := True;
    Parts_.DelimitedText := GetEnvironmentVariable('PATH');
    for I := 0 to Parts_.Count - 1 do
    begin
      if Parts_[I] = '' then
        Continue;
      Candidate := IncludeTrailingPathDelimiter(Parts_[I]) + Name_;
      if FileExists(Candidate) then
        Exit(Candidate);
    end;
  finally
    Parts_.Free;
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
    Full := FindOnPath(Kompilator);
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

type
  { A condition that stops the command, carried to whoever asked instead of
    ending the process where it happened.

    The four failures below — ASKR_FPC pointing at nothing, a `compiler` in
    askr.toml that is not there, no fpc on PATH, an `[askr] path` that is
    not a checkout — have two audiences now. A terminal prints them and
    exits, which is what `Halt` did. An MCP tool call has to answer with the
    same text and leave the server standing: `Halt` there ended the process
    halfway through a reply, and the client saw the pipe close with nothing
    to say why. That is the exact case this layer exists to survive. }
  ECliFatal = class(Exception);

{ The messages say what was looked for, where, and what to do about it, and
  that does not fit on one line. Raising them as one string keeps them
  identical for both audiences. }
procedure Fatal(const Lines: array of string);
var
  I: Integer;
  S: string;
begin
  S := '';
  for I := Low(Lines) to High(Lines) do
  begin
    if I > Low(Lines) then
      S := S + #10;
    S := S + Lines[I];
  end;
  raise ECliFatal.Create(S);
end;

{ Finner Pascal-kompilatoren, eller sier hvorfor den ikke ble funnet.

  Den gamle oppførselen var at TProcess kastet EProcess og prosessen døde
  med et stakkspor i heksadesimale adresser. «Executable not found: "fpc"»
  sto der riktignok, men omgitt av seks linjer som ser ut som en krasj i
  verktøyet — og uten et ord om hva man skal gjøre.

  Rekkefølgen: en `compiler` satt i askr.toml vinner, fordi det er
  prosjektet som sier hvilken kompilator det skal bygges med. ASKR_FPC er
  maskinens svar når prosjektet ikke har noe, og den finnes for at en
  utvikler skal kunne peke på sin egen fpc uten å endre prosjektfila —
  samme variabel som rammeverkets eget byggskript bruker. To_ slutt PATH. }
function FindCompiler(P: TProject): string;
var
  Chosen, FromEnv, Full, EnvLine: string;
begin
  Chosen := P.Compiler;
  FromEnv := GetEnvironmentVariable('ASKR_FPC');

  { ASKR_FPC gjelder bare når prosjektet ikke har pekt ut noe selv. }
  if (FromEnv <> '') and (Chosen = 'fpc') then
  begin
    if FileExists(FromEnv) then
      Exit(FromEnv);
    Fatal(['askr: ASKR_FPC points at a compiler that is not there.',
           '',
           '  ASKR_FPC   ' + FromEnv,
           '',
           'Fix the path, or unset it to use fpc from PATH.']);
  end;

  { En sti med katalog i skal finnes som den er; et bart navn slås opp. }
  if ExtractFilePath(Chosen) <> '' then
  begin
    if FileExists(Chosen) then
      Exit(Chosen);
    Fatal(['askr: the compiler in askr.toml is not there.',
           '',
           '  compiler   ' + Chosen,
           '',
           'Fix the path in askr.toml, or remove the line to use fpc from ' +
           'PATH.']);
  end;

  Full := FindOnPath(Chosen);
  if Full <> '' then
    Exit(Full);

  if FromEnv = '' then
    EnvLine := '  ASKR_FPC     not set'
  else
    EnvLine := '  ASKR_FPC     ' + FromEnv +
      '   (ignored: askr.toml sets compiler)';
  Fatal(['askr: cannot find the Pascal compiler.',
         '',
         '  looked for   ' + Chosen + '   on PATH',
         EnvLine,
         '',
         'Askr builds your app with Free Pascal. Install it, then either ' +
         'put it',
         'on PATH or point at it:',
         '',
         '  export ASKR_FPC=/path/to/fpc',
         '',
         'or set it for this project only, in askr.toml:',
         '',
         '  compiler = "/path/to/fpc"']);
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
  Si('  askr make resource <Name>  pages over a table: list, show, add, edit');
  Si('  askr make controller <Name>');
  Si('  askr make migration <Name>');
  Si('  askr make pivot <Model> <Model>  the table for a many-to-many');
  Si('  askr make seeder|job|middleware <Name>');
  Si('  askr make auth           /login, /register, /reset-password');
  Si('  askr migrate             run pending migrations');
  Si('  askr migrate:status|:rollback|:reset|:fresh|:refresh');
  Si('  askr db:seed|db:show|db:table|db:wipe');
  Si('  askr schema              typed columns from the database');
  Si('  askr schema:check        do they still describe it');
  Si('  askr queue:work|queue:status');
  Si('  askr schedule:list|schedule:run');
  Si('  askr cache:clear   askr down   askr up');
  Si('  askr token:issue|token:list|token:revoke');
  Si('  askr openapi [--check]   the API document, or its drift');
  Si('  askr install             fetch the pinned framework version');
  Si('  askr update [version]    move to a newer release');
  Si('  askr outdated            what is published, what you have');
  Si('  askr plugin add <git url> fetch a plugin and pin it');
  Si('  askr plugin remove|list|update');
  Si('  askr key:generate        print a new APP_KEY');
  Si('  askr lang:check          what each lang file lacks, and has that it should not');
  Si('  askr config [--values]   show the effective configuration');
  Si('  askr test                build and run the app test suite');
  Si('  askr mcp                 MCP server for AI agents, over stdio');
  Si('  askr mcp:install [client]  wire it into claude|cursor|vscode');
  Si('  askr version');
  Si('');
  Si('Commands read askr.toml in the project root.');
  Si('The app answers many of them itself; see: askr list');
end;

function FindProject: TProject;
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
function AppBinaryOf(P: TProject): string;
begin
  Result := IncludeTrailingPathDelimiter(P.Root) + '.build' + PathDelim +
    'bin' + PathDelim + ChangeFileExt(ExtractFileName(P.MainFile), '');
end;

function RunApp(P: TProject; const Flagg: string): Integer;
var
  Proc: TProcess;
  Bin: string;
  I: Integer;
begin
  Bin := AppBinaryOf(P);
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
      «askr migrate:rollback --step=2» skal virke. Without dette kom flagget
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

{ The words the application binary answers to. The list is in
  Askr.Console.Commands and that is the only copy: this used to be a
  mirror of the table in Askr.Console, with a comment on it saying so,
  and the first command added afterwards went into one of them. }
function ErAppKommando(const K: string): Boolean;
begin
  Result := IsConsoleCommand(K);
end;

function BuildFlags(P: TProject): string;
const
  { Rammeverkets units. Rekkefølgen spiller ingen rolle for fpc. }
  { `cli` er med fordi Askr.Console ligger der: kommandoene appen svarer
    på selv er en del av rammeverket, ikke av verktøyet. }
  AskrUnits: array[0..8] of string =
    ('core', 'http', 'urd', 'norn', 'inertia', 'desktop', 'runtime', 'run',
     'cli');
var
  Paths_: TStringArray;
  I: Integer;
  Frame, Cfg, Err, PluginFlags: string;
  Origin: TPkgOrigin;
begin
  Result := P.CompilerFlags;

  Cfg := KompilatorConfigFlagg(FindCompiler(P));
  if Cfg <> '' then
    Result := Cfg + ' ' + Result;

  { Stien løses av pakkelaget: en lokal sti hvis prosjektet har pekt ut
    én, ellers den låste versjonen fra ~/.askr/pkg. Byggingen skal ikke
    vite forskjellen. }
  Frame := ResolveFramework(P, Origin, Err);
  if Frame = '' then
    Fatal(['askr: ' + Err]);
  if Frame <> '' then
    for I := Low(AskrUnits) to High(AskrUnits) do
      Result := Result + ' -Fu' + IncludeTrailingPathDelimiter(Frame) +
        'src' + PathDelim + AskrUnits[I];

  { The plugins' units, and App.Plugins, which uses them. Resolved
    against the framework actually being built -- a plugin says which
    Askr it builds against, and the build is where that is checked. }
  if Frame <> '' then
  begin
    PluginFlags := PluginBuildFlags(P, TreeVersion(Frame), Err);
    if Err <> '' then
      Fatal(['askr: ' + Err]);
    Result := Result + PluginFlags;
  end;

  Paths_ := P.UnitPaths;
  for I := 0 to High(Paths_) do
    if DirectoryExists(IncludeTrailingPathDelimiter(P.Root) + Paths_[I]) then
      { Mappa selv og ett nivå under. -Fu<dir>/* er FPCs egen form for det,
        og sparer brukeren for å liste opp app/Http, app/Models og resten. }
      Result := Result + ' -Fu' + Paths_[I] + ' -Fu' + Paths_[I] + PathDelim + '*';
end;

{ --target web (standard) eller --target desktop. Samme kodebase, to skall;
  det er hele poenget med at forskjellen er én unit. }
function ChooseMainFile(P: TProject): string;
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
    Si('Unknown target: ' + Target + '. Use web or desktop.');
    Halt(1);
  end;
  Result := P.MainFile;
end;

{ Oversetter hver .run-fil i prosjektet til en Pascal-unit under
  .build/run, som legges på søkestien. Kjøres før kompilatoren, slik at
  `askr build` og `askr serve` bare virker — språket skal ikke kreve et
  eget steg man må huske. }
{ ErrMsg rather than Si: under `askr mcp` stdout carries JSON-RPC, and a
  transpiler error printed there is a parse error at the client with nothing
  to say where it came from. The caller decides where it goes. }
function RunRun(P: TProject; Quiet: Boolean; out ErrMsg: string): Boolean;
var
  Filer: TStringList;
  Rec: TSearchRec;
  Dir, UtDir, Ut, UnitName: string;
  Paths_: TStringArray;
  I, J: Integer;
  Stats: TRunStats;
begin
  Result := True;
  ErrMsg := '';
  UtDir := IncludeTrailingPathDelimiter(P.Root) + '.build' + PathDelim + 'run';
  Filer := TStringList.Create;
  try
    Paths_ := P.UnitPaths;
    for I := 0 to High(Paths_) do
    begin
      Dir := IncludeTrailingPathDelimiter(P.Root) + Paths_[I];
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
        if not Quiet then
          Si(Format('  run       %s -> %s  (%d models, %d queries, %d ms)',
            [ExtractFileName(Filer[J]), UnitName,
             Stats.Models, Stats.Queries, Stats.TotalMs]));
      except
        on E: ERunError do
        begin
          ErrMsg := E.Message;
          Exit(False);
        end;
      end;
    end;
  finally
    Filer.Free;
  end;
end;

{ Runs the compiler over the project and hands back everything it said.
  Shared by `askr build` and the MCP `build` tool — two paths to the
  compiler would drift, and then the agent and the developer would be
  looking at different errors. }
function CompileProject(P: TProject; out Output_: string): Integer;
var
  Proc: TProcess;
  Lines: TStringList;
  Params: TStringList;
  I: Integer;
begin
  Output_ := '';
  ForceDirectories(IncludeTrailingPathDelimiter(P.Root) + '.build/units');
  ForceDirectories(IncludeTrailingPathDelimiter(P.Root) + '.build/bin');

  Proc := TProcess.Create(nil);
  Lines := TStringList.Create;
  Params := TStringList.Create;
  try
    Params.Delimiter := ' ';
    Params.StrictDelimiter := True;
    Params.DelimitedText := BuildFlags(P);
    Proc.Executable := FindCompiler(P);
    for I := 0 to Params.Count - 1 do
      if Params[I] <> '' then
        Proc.Parameters.Add(Params[I]);
    Proc.Parameters.Add('-Fu.build' + PathDelim + 'run');
    Proc.Parameters.Add('-FU.build/units');
    Proc.Parameters.Add('-FE.build/bin');
    Proc.Parameters.Add(ChooseMainFile(P));
    Proc.CurrentDirectory := P.Root;
    Proc.Options := [poWaitOnExit, poUsePipes, poStderrToOutPut];
    Proc.Execute;
    Lines.LoadFromStream(Proc.Output);
    Output_ := Lines.Text;
    Result := Proc.ExitStatus;
  finally
    Params.Free;
    Lines.Free;
    Proc.Free;
  end;
end;

procedure CmdBuild(P: TProject);
var
  Main_, Ut, Err: string;
begin
  Main_ := ChooseMainFile(P);
  if not RunRun(P, False, Err) then
  begin
    Si(Err);
    Halt(1);
  end;
  if CompileProject(P, Ut) <> 0 then
  begin
    Write(Ut);
    Halt(1);
  end;
  Si('Built .build/bin/' + ChangeFileExt(ExtractFileName(Main_), ''));
end;

{ Bygger og kjører prosjektets testprogram. Rammeverket er Askr.Testing;
  verktøyet gjør bare bygg og kjør. }
{ What a test run ended up being. The exit code alone cannot say it: a
  suite that did not compile and a suite that failed both exit non-zero,
  and an agent told only "non-zero" fixes the wrong thing. }
type
  TTestOutcome = (toNoTests, toDidNotBuild, toFailed, toPassed, toTimedOut);

{ Builds the test suite and runs it.

  Shared by `askr test` and the MCP test tool, for the same reason
  CompileProject is: two paths to the tests would drift, and then the agent
  and the developer would be looking at different failures.

  The two differ in one thing, and it is not the logic — it is who is
  watching. A person at a terminal sees a suite hang and presses Ctrl-C,
  and wants the output as it appears, so the command captures nothing and
  sets no deadline. An agent can do neither: a tool that never returns
  takes the session with it, and there is nothing to interrupt it. So the
  tool captures and passes a deadline, and TimeoutMs = 0 means none. }
function RunTests(P: TProject; Capture: Boolean; TimeoutMs: Integer;
  out Output_: string): TTestOutcome;
var
  Proc: TProcess;
  Params: TStringList;
  S: TStringStream;
  Buf: array[0..8191] of Byte;
  N, I: Integer;
  Fil, Bin: string;
  Deadline, Reaped: QWord;

  { Drains the pipe while waiting, rather than waiting and then reading. A
    child that fills the pipe buffer blocks on the write, and a parent that
    is only watching Running would then wait for a process that is waiting
    for it. }
  function Pump(Pr: TProcess): Boolean;
  begin
    Result := True;
    while Pr.Running or (Pr.Output.NumBytesAvailable > 0) do
    begin
      if Pr.Output.NumBytesAvailable > 0 then
      begin
        N := Pr.Output.Read(Buf, SizeOf(Buf));
        if N > 0 then
          S.Write(Buf, N);
      end
      else
      begin
        if (TimeoutMs > 0) and (GetTickCount64 > Deadline) then
        begin
          Pr.Terminate(1);
          { Reaped here rather than left to the destructor, which does not
            wait: this server is long-lived, and a zombie per timed-out run
            accumulates. Bounded, because a process that ignores SIGTERM
            must not turn a stopped hang back into a hanging one — a stray
            child is the lesser of the two. }
          Reaped := GetTickCount64 + 2000;
          while Pr.Running and (GetTickCount64 < Reaped) do
            Sleep(10);
          Exit(False);
        end;
        Sleep(10);
      end;
    end;
  end;

begin
  Output_ := '';
  Fil := P.TestFile;
  if not FileExists(IncludeTrailingPathDelimiter(P.Root) + Fil) then
  begin
    Output_ := 'No tests found: ' + Fil + #10 +
      'Write one, or set  tests = "path/to/tests.lpr"  in askr.toml.';
    Exit(toNoTests);
  end;

  ForceDirectories(IncludeTrailingPathDelimiter(P.Root) + '.build/units');
  ForceDirectories(IncludeTrailingPathDelimiter(P.Root) + '.build/bin');

  { Building the suite is always captured: a compiler that says nothing is
    the normal case, and its diagnostics are the answer when it does. }
  Proc := TProcess.Create(nil);
  Params := TStringList.Create;
  S := TStringStream.Create('');
  try
    Params.Delimiter := ' ';
    Params.StrictDelimiter := True;
    Params.DelimitedText := BuildFlags(P);
    Proc.Executable := FindCompiler(P);
    for I := 0 to Params.Count - 1 do
      if Params[I] <> '' then
        Proc.Parameters.Add(Params[I]);
    Proc.Parameters.Add('-FU.build/units');
    Proc.Parameters.Add('-FE.build/bin');
    Proc.Parameters.Add(Fil);
    Proc.CurrentDirectory := P.Root;
    Proc.Options := [poWaitOnExit, poUsePipes, poStderrToOutPut];
    Proc.Execute;
    S.Size := 0;
    while Proc.Output.NumBytesAvailable > 0 do
    begin
      N := Proc.Output.Read(Buf, SizeOf(Buf));
      if N > 0 then
        S.Write(Buf, N);
    end;
    if Proc.ExitStatus <> 0 then
    begin
      Output_ := S.DataString;
      Exit(toDidNotBuild);
    end;
  finally
    S.Free;
    Params.Free;
    Proc.Free;
  end;

  Bin := IncludeTrailingPathDelimiter(P.Root) + '.build' + PathDelim +
    'bin' + PathDelim + ChangeFileExt(ExtractFileName(Fil), '');
  Proc := TProcess.Create(nil);
  S := TStringStream.Create('');
  try
    Proc.Executable := Bin;
    Proc.CurrentDirectory := P.Root;
    if Capture then
      Proc.Options := [poUsePipes, poStderrToOutPut]
    else
      Proc.Options := [poWaitOnExit];
    Deadline := GetTickCount64 + QWord(TimeoutMs);
    Proc.Execute;
    if Capture then
    begin
      if not Pump(Proc) then
      begin
        Output_ := S.DataString + #10 +
          Format('The suite was still running after %d seconds and was ' +
                 'stopped. The output above is what it had produced. A ' +
                 'test that waits on a socket, a queue or a lock is the ' +
                 'usual cause.', [TimeoutMs div 1000]);
        Exit(toTimedOut);
      end;
      Output_ := S.DataString;
    end;
    if Proc.ExitStatus <> 0 then
      Result := toFailed
    else
      Result := toPassed;
  finally
    S.Free;
    Proc.Free;
  end;
end;

procedure CmdTest(P: TProject);
var
  Ut: string;
begin
  { No deadline and no capture: a person at a terminal wants the output as
    it appears, and can stop a suite that hangs. }
  case RunTests(P, False, 0, Ut) of
    toNoTests:
      begin
        Si(Ut);
        Halt(1);
      end;
    toDidNotBuild:
      begin
        Write(Ut);
        Halt(1);
      end;
    toTimedOut:
      { Cannot happen from here — this path passes no deadline. Written out
        rather than left to an `else`, so that a sixth outcome added later
        is a warning about an unhandled case instead of a silent default.
        Trunk found the version that left two out. }
      Halt(1);
    toFailed:
      Halt(1);
    toPassed:
      ;
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
  Opts.Compiler := FindCompiler(P);
  Opts.CompilerFlags := BuildFlags(P);
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
function HasFlag(const Flagg: string): Boolean;
var
  I: Integer;
begin
  for I := 1 to ParamCount do
    if (ParamStr(I) = '--' + Flagg) or (ParamStr(I) = '-' + Flagg) then
      Exit(True);
  Result := False;
end;

{ The value of --name=value, or ''. }
function FlagText(const Name_: string): string;
var
  I: Integer;
begin
  for I := 1 to ParamCount do
    if Copy(ParamStr(I), 1, Length(Name_) + 3) = '--' + Name_ + '=' then
      Exit(Copy(ParamStr(I), Length(Name_) + 4, MaxInt));
  Result := '';
end;

{ `askr make resource`: read from the database the project is configured
  with, in the tool -- which links the drivers and the introspection
  already, for Rún. The app binary is not needed, and not built: this runs
  before the files that would make it build are there. }
function CmdMakeResource(P: TProject; const Name_: string): Boolean;
var
  Dsn: string;
  Web, Api: Boolean;
  C: TDbConnection;
  S: TDbSchema;
begin
  SetCurrentDir(P.Root);
  LoadConfig(P.Root);
  Dsn := Cfg('database.url');
  if Dsn = '' then
  begin
    Si('make resource reads the table from the database, and DATABASE_URL');
    Si('is not set. Put it in .env, then askr migrate, then try again.');
    Exit(False);
  end;
  C := OpenDbConnection(Dsn);
  try
    S := IntrospectSchema(C);
    try
      { --web unless something else was asked for, and both when both
        were. }
      Api := HasFlag('api');
      Web := HasFlag('web') or not Api;
      Result := MakeResource(P.Root, S, PascalName(Name_), FlagText('table'),
        P.Name, HasFlag('force'), Web, Api);
    finally
      S.Free;
    end;
  finally
    C.Free;
  end;
end;

{ Skal prosjektet ha innlogging?

  --auth og --no-auth svarer for den som kjører fra et skript. Without et av
  dem spørres det, men bare når det faktisk står et menneske der: en
  kommando som venter på svar fra en pipe henger for alltid. }
function WantsAuth: Boolean;
var
  Reply: string;
begin
  if HasFlag('auth') then
    Exit(True);
  if HasFlag('no-auth') then
    Exit(False);
  if IsATTY(Input) = 0 then
    Exit(False);

  Write('Does this project need sign-in? [y/N] ');
  Flush(Output);
  ReadLn(Reply);
  Reply := LowerCase(Trim(Reply));
  Result := (Reply = 'y') or (Reply = 'yes');
end;

procedure CmdMake(P: TProject);
var
  Slag, Name_: string;
  Specs: array of string;
  Fields: TFieldSpecs;
  I: Integer;
begin
  Slag := LowerCase(ParamStr(2));
  Name_ := ParamStr(3);
  { auth tar ikke noe navn — det er ett sett filer, ikke en type. }
  if Slag = 'auth' then
    Name_ := 'auth';
  if (Slag = '') or (Name_ = '') then
  begin
    Si('Usage: askr make model|controller|migration|seeder|job|' +
      'middleware <Name>');
    Si('       askr make model <Name> name:type ...   with its migration');
    Si('         types: ' + TypeNames + '; string(n) for a length,');
    Si('         a trailing ? for nullable. --no-timestamps, --force');
    Si('       askr make resource <Name> [--web] [--api] [--table=name] [--force]');
    Si('         from the table: pages (--web, the default), JSON (--api), or both');
    Si('       askr make pivot <Model> <Model> [--force]');
    Si('         the table between two models, for BelongsToMany');
    Si('       askr make auth [--force]');
    Halt(1);
  end;
  if Slag = 'model' then
  begin
    { name:type after the name means a spec, and then the migration comes
      with it -- a spec without its table would be half of one. Without
      one, the stub it has always written. }
    Specs := nil;
    for I := 4 to ParamCount do
      if (Copy(ParamStr(I), 1, 2) <> '--') then
      begin
        SetLength(Specs, Length(Specs) + 1);
        Specs[High(Specs)] := ParamStr(I);
      end;
    if Length(Specs) = 0 then
      MakeModel(P.Root, Name_, HasFlag('migration'))
    else
    begin
      try
        Fields := ParseFields(Specs);
      except
        on E: EFieldSpec do
        begin
          Si(E.Message);
          Halt(1);
        end;
      end;
      if not MakeModelFromFields(P.Root, Name_, Fields,
               not HasFlag('no-timestamps'), HasFlag('force')) then
        Halt(1);
    end;
  end
  else if Slag = 'resource' then
  begin
    if not CmdMakeResource(P, Name_) then
      Halt(1);
  end
  else if Slag = 'controller' then
    MakeController(P.Root, Name_)
  else if Slag = 'migration' then
    MakeMigration(P.Root, Name_)
  else if Slag = 'pivot' then
  begin
    if not MakePivot(P.Root, Name_, ParamStr(4), HasFlag('force')) then
      Halt(1);
  end
  else if Slag = 'seeder' then
    MakeSeeder(P.Root, Name_)
  else if Slag = 'job' then
    MakeJob(P.Root, Name_)
  else if Slag = 'middleware' then
    MakeMiddleware(P.Root, Name_)
  else if Slag = 'auth' then
    MakeAuth(P.Root, HasFlag('force'))
  else
  begin
    Si('Unknown: ' + Slag);
    Halt(1);
  end;
end;

{ ------------------------------------------------- the MCP tools -- }

{ `build` — the one tool no interpreted framework can offer.

  Askr's claim is that a typo in a column name is a compile error. This is
  what turns that into something an agent can use: it can verify rather
  than claim, and it gets a position to go to rather than a wall of text.

  The project is found here and not at start-up. The server answers the
  handshake wherever it was started; a tool that needs a project says so
  through the protocol, which is the only channel a client can read. }
function Plural(N: Integer): string;
begin
  if N = 1 then
    Result := ''
  else
    Result := 's';
end;

{ Compiler diagnostics as `file:line:column  Severity: message` — the
  shape every editor and every agent already follows.

  One function for the build tool and the test tool both. Two formatters
  would drift, and then the same compiler error would reach an agent in two
  different shapes depending on which call produced it. Notes and hints are
  left out: a compile that emitted only those produced a binary, and the
  tally is what says so. }
procedure FormatDiagnostics(const Raw: string; Into: TStringList;
  out Errors, Warnings: Integer);
var
  Diags: TDiagArray;
  I: Integer;
  Line_: string;
begin
  Diags := ParseDiagnostics(Raw);
  { Defects, not error-level lines: fpc follows one wrong type with three
    lines of its own summary, and `4 errors` for one mistake sends an agent
    looking for three more. Every line is still listed below — the
    compiler's own tally among them. }
  Errors := CountDefects(Diags);
  Warnings := 0;
  for I := 0 to High(Diags) do
    if Diags[I].Severity = dsWarning then
      Inc(Warnings);

  for I := 0 to High(Diags) do
  begin
    if Diags[I].Severity < dsWarning then
      Continue;
    if Diags[I].FileName_ = '' then
      Line_ := ''
    else if Diags[I].Col = 0 then
      Line_ := Format('%s:%d  ', [Diags[I].FileName_, Diags[I].Line])
    else
      Line_ := Format('%s:%d:%d  ',
        [Diags[I].FileName_, Diags[I].Line, Diags[I].Col]);
    Into.Add(Line_ + DiagSeverityName(Diags[I].Severity) + ': ' +
      Diags[I].Message_);
  end;
end;

function McpToolBuild(A: TArena; Args: PJsonValue;
  out IsError: Boolean): string;
var
  P: TProject;
  Ut, Err: string;
  Code: Integer;
  Errors, Warnings: Integer;
  B, DL: TStringList;
begin
  IsError := False;
  P := TProject.Find(GetCurrentDir);
  if P = nil then
  begin
    IsError := True;
    Exit('No askr.toml in the working directory or above it. ' +
         'The build tool needs a project; create one with: askr new <name>');
  end;

  B := TStringList.Create;
  try
    if not RunRun(P, True, Err) then
    begin
      { A Rún error comes before the compiler sees anything, and it already
        names the file and the line. Passing it through unchanged is more
        use than wrapping it. }
      IsError := False;
      Exit('FAILED  the Rún transpiler stopped before the compiler ran'#10#10 +
           Err);
    end;

    try
      Code := CompileProject(P, Ut);
    except
      { No compiler, or an `[askr] path` that is not a checkout. The message
        already says what to do; the tool could not run, so this is the
        other kind of failure — not a build that reported bad news. }
      on E: ECliFatal do
      begin
        IsError := True;
        Exit(E.Message);
      end;
    end;
    DL := TStringList.Create;
    try
      FormatDiagnostics(Ut, DL, Errors, Warnings);

      { The exit code decides, not the diagnostic count: a build can fail
        for a reason the compiler did not attach to a line, and a build
        that only emitted notes still produced a binary. }
      if Code = 0 then
        B.Add(Format('OK  built .build/bin/%s  (%d warning%s)',
          [ChangeFileExt(ExtractFileName(ChooseMainFile(P)), ''), Warnings,
           Plural(Warnings)]))
      else
        B.Add(Format('FAILED  %d error%s, %d warning%s',
          [Errors, Plural(Errors), Warnings, Plural(Warnings)]));
      B.AddStrings(DL);
    finally
      DL.Free;
    end;

    if (Code <> 0) and (Errors = 0) then
      { The compiler failed without attaching a diagnostic to a line — a
        missing compiler, a linker error. Hiding its output here would
        leave the agent with a failure and nothing to read. }
      B.Add(Trim(Ut));

    Result := B.Text;
  finally
    B.Free;
    P.Free;
  end;
end;

{ The documentation the project's own framework version ships with.

  Not the tool's: `askr mcp` runs before FindProject and never delegates, so
  the binary answering may be a different release from the one the project
  builds with. An agent reading current docs for a project pinned two
  releases back would be confidently wrong about the framework in front of
  it, and nothing would say so. ResolveFramework is the same call the build path makes, so the
  docs and the compiler always come from one tree. }
function DocsDirFor(out Version: string; out Err: string): string;
var
  P: TProject;
  Frame: string;
  Origin: TPkgOrigin;
begin
  Result := '';
  Version := '';
  Err := '';
  P := TProject.Find(GetCurrentDir);
  if P = nil then
  begin
    Err := 'No askr.toml in the working directory or above it. The docs ' +
           'tools read the documentation of the framework version this ' +
           'project pins, so they need a project to know which that is.';
    Exit;
  end;
  try
    Frame := ResolveFramework(P, Origin, Err);
    if Frame = '' then
      Exit;
    Version := TreeVersion(Frame);
    Result := IncludeTrailingPathDelimiter(Frame) + 'docs';
    if not DirectoryExists(Result) then
    begin
      Err := 'Askr ' + Version + ' is resolved at ' + Frame +
             ' but has no docs/ directory.';
      Result := '';
    end;
  finally
    P.Free;
  end;
end;

{ Runs the app binary and hands back everything it said.

  RunApp above deliberately does not do this: from a terminal the app owns
  the terminal, and piping its output through the tool would only add a
  buffer. Under MCP that same inheritance writes the app's output straight
  onto the protocol channel — the first tool here that starts a child, and
  the reason the Askr.Cli.Mcp header says a tool must capture rather than
  inherit. It needs the text for the reply anyway, so the two point the
  same way. }
function RunAppCapturing(P: TProject; const Flag_, Arg_: string;
  out Output_: string): Integer;
var
  Proc: TProcess;
  Lines: TStringList;
  Bin: string;
begin
  Output_ := '';
  Bin := AppBinaryOf(P);
  if not FileExists(Bin) then
  begin
    Output_ := 'The app is not built, so it cannot answer. Run the build ' +
               'tool first; this reads the compiled binary, because the ' +
               'routes, the schedule and the database connection are ' +
               'compiled into it and are not in any file to read.';
    Exit(-1);
  end;

  Proc := TProcess.Create(nil);
  Lines := TStringList.Create;
  try
    Proc.Executable := Bin;
    Proc.Parameters.Add(Flag_);
    if Arg_ <> '' then
      Proc.Parameters.Add(Arg_);
    Proc.CurrentDirectory := P.Root;
    Proc.Options := [poWaitOnExit, poUsePipes, poStderrToOutPut];
    Proc.Execute;
    Lines.LoadFromStream(Proc.Output);
    Output_ := Lines.Text;
    Result := Proc.ExitStatus;
  finally
    Lines.Free;
    Proc.Free;
  end;
end;

{ The project, or nil with a tool error already written. Shared by every
  tool that needs one, so they say the same thing. }
function McpProject(out IsError: Boolean; out Msg: string): TProject;
begin
  IsError := False;
  Msg := '';
  Result := TProject.Find(GetCurrentDir);
  if Result = nil then
  begin
    IsError := True;
    Msg := 'No askr.toml in the working directory or above it. ' +
           'Create a project with: askr new <name>';
  end;
end;

function McpToolRoutes(A: TArena; Args: PJsonValue;
  out IsError: Boolean): string;
var
  P: TProject;
  Out_, Msg: string;
begin
  P := McpProject(IsError, Msg);
  if P = nil then
    Exit(Msg);
  try
    if RunAppCapturing(P, '--routes', '', Out_) <> 0 then
      IsError := True;
    Result := Out_;
  finally
    P.Free;
  end;
end;

function McpToolOpenApi(A: TArena; Args: PJsonValue;
  out IsError: Boolean): string;
var
  P: TProject;
  Out_, Msg: string;
  Check: Boolean;
begin
  P := McpProject(IsError, Msg);
  if P = nil then
    Exit(Msg);
  try
    Check := JsonAsBool(JsonMember(Args, 'check'), False);
    if Check then
    begin
      { Drift found is a **successful** call: the tool ran and has an
        answer, and the answer is a list of things to fix. Reporting it
        as a tool error would send an agent looking for a broken tool
        instead of a broken description -- the same distinction the
        build and test tools already make. }
      RunAppCapturing(P, '--openapi', '--check', Out_);
      Exit(Out_);
    end;
    if RunAppCapturing(P, '--openapi', '', Out_) <> 0 then
      IsError := True;
    Result := Out_;
  finally
    P.Free;
  end;
end;

function McpToolSchema(A: TArena; Args: PJsonValue;
  out IsError: Boolean): string;
var
  P: TProject;
  Out_, Msg, Table: string;
begin
  P := McpProject(IsError, Msg);
  if P = nil then
    Exit(Msg);
  try
    Table := Trim(JsonAsString(JsonMember(Args, 'table')));
    { Two calls rather than one enormous one, and it is not only about
      size: the tables first is the order anybody reads a schema in. A
      database with sixty tables would otherwise answer a question nobody
      asked with every column it has. }
    if Table = '' then
    begin
      if RunAppCapturing(P, '--db:show', '', Out_) <> 0 then
        IsError := True;
    end
    else
      if RunAppCapturing(P, '--db:table', Table, Out_) <> 0 then
        IsError := True;
    Result := Out_;
  finally
    P.Free;
  end;
end;

{ Configuration, with the keys and where each one came from — and never a
  value.

  `askr config --values` exists for a person at a terminal, who can see
  their own screen and decide. This output goes into an agent's context and
  from there to whatever model is behind it, so the decision is not the
  tool's to make. Nothing is redacted here, because nothing is read: a
  redactor is a denylist of words, `LooksSecret` says in its own comment
  that it cannot be definitive, and `stripe_live_account` is not on
  anybody's list until after it has leaked.

  The layer each key resolved from is what answers almost every question
  anyone actually has — "why is it using sqlite" is answered by `.env`,
  not by the value. }
function McpToolConfig(A: TArena; Args: PJsonValue;
  out IsError: Boolean): string;
var
  P: TProject;
  Msg: string;
begin
  P := McpProject(IsError, Msg);
  if P = nil then
    Exit(Msg);
  try
    { In the tool, not in the app: the layering is computed from .env and
      askr.toml, which are files, so this answers even when the project
      does not compile. }
    SetCurrentDir(P.Root);
    LoadConfig(P.Root);
    Result := ConfigReport(False) + #10 +
      'Values are not shown, and there is no flag here that shows them: ' +
      'this text goes into an agent context. At a terminal, ' +
      '`askr config --values` shows them, with anything that looks like a ' +
      'secret still hidden.';
  finally
    P.Free;
  end;
end;

{ The test tool.

  A failing test is a successful call reporting bad news, exactly as a
  failing build is. IsError is true only when the tool could not run at
  all: no project, no test file. Conflate the two and an agent reacts to a
  red suite by hunting for a broken tool.

  A suite that did not compile is reported as its own thing, because the
  exit code cannot tell it apart from a suite that failed, and the two need
  opposite work. }
function McpToolTest(A: TArena; Args: PJsonValue;
  out IsError: Boolean): string;
const
  DefaultTimeoutSec = 120;
  { A cap, not a suggestion. Without one, an agent that hits the deadline
    can answer it by raising the deadline, which is how a hang comes back
    wearing a number. }
  MaxTimeoutSec = 600;
var
  P: TProject;
  Msg, Out_: string;
  Secs, Errors, Warnings: Integer;
  B: TStringList;
begin
  P := McpProject(IsError, Msg);
  if P = nil then
    Exit(Msg);
  try
    Secs := JsonAsInt(JsonMember(Args, 'timeout_seconds'), DefaultTimeoutSec);
    if Secs <= 0 then
      Secs := DefaultTimeoutSec;
    if Secs > MaxTimeoutSec then
      Secs := MaxTimeoutSec;

    case RunTests(P, True, Secs * 1000, Out_) of
      toNoTests:
        begin
          IsError := True;
          Result := Out_;
        end;
      toDidNotBuild:
        begin
          { The same shape the build tool gives. An agent should not get
            compiler errors in two forms depending on which call found
            them. }
          B := TStringList.Create;
          try
            FormatDiagnostics(Out_, B, Errors, Warnings);
            B.Insert(0, Format('FAILED  the test suite did not compile ' +
              '(%d error%s, %d warning%s)',
              [Errors, Plural(Errors), Warnings, Plural(Warnings)]));
            if Errors = 0 then
              { Nothing the compiler attached to a line — a linker error, a
                missing unit path. Hiding its output would leave the agent
                with a failure and nothing to read. }
              B.Add(Trim(Out_));
            Result := B.Text;
          finally
            B.Free;
          end;
        end;
      toTimedOut:
        Result := Format('TIMED OUT  after %d seconds', [Secs]) + #10#10 +
                  Out_;
      toFailed:
        Result := 'FAILED  the suite ran and reported failures'#10#10 + Out_;
    else
      Result := 'OK  the suite passed'#10#10 + Out_;
    end;
  finally
    P.Free;
  end;
end;

function McpToolDocsSearch(A: TArena; Args: PJsonValue;
  out IsError: Boolean): string;
var
  Dir, Version, Err, Query: string;
  Hits: TDocHits;
  Total, Limit, I: Integer;
  B: TStringList;
  Where_: string;
begin
  IsError := False;
  Query := JsonAsString(JsonMember(Args, 'query'));
  if Trim(Query) = '' then
  begin
    IsError := True;
    Exit('docs_search needs a query.');
  end;

  Dir := DocsDirFor(Version, Err);
  if Dir = '' then
  begin
    IsError := True;
    Exit(Err);
  end;

  Limit := JsonAsInt(JsonMember(Args, 'limit'), 40);
  if Limit <= 0 then
    Limit := 40;

  Hits := DocSearch(Dir, Query, Limit, Total);
  if Total = 0 then
    { Saying why, once, in the answer itself. The rule only protects an
      agent that knows it is in force: told plainly that nothing matched
      and that the search is exact, it looks for a shorter string. Told
      only "0 results", it is as likely to conclude the docs are thin. }
    Exit('No match for "' + Query + '" in the docs for Askr ' + Version +
         '.'#10#10 +
         'The search is an exact substring and is deliberately not fuzzy: ' +
         'a near match would confirm a name that does not exist. Try a ' +
         'shorter query, or docs_read with no page to list them.');

  B := TStringList.Create;
  try
    if Total > Length(Hits) then
      B.Add(Format('%d matches for "%s" in the docs for Askr %s, showing %d',
        [Total, Query, Version, Length(Hits)]))
    else
      B.Add(Format('%d matches for "%s" in the docs for Askr %s',
        [Total, Query, Version]));
    B.Add('');
    for I := 0 to High(Hits) do
    begin
      { page:line is the shape an editor and an agent already follow, and
        the heading is exactly what docs_read takes as its section. }
      Where_ := Format('%s:%d', [Hits[I].Page, Hits[I].Line]);
      if Hits[I].Heading <> '' then
        Where_ := Where_ + '  [' + Hits[I].Heading + ']';
      B.Add(Where_);
      B.Add('    ' + Hits[I].Text_);
    end;
    Result := B.Text;
  finally
    B.Free;
  end;
end;

function McpToolDocsRead(A: TArena; Args: PJsonValue;
  out IsError: Boolean): string;
var
  Dir, Version, Err, Page, Section, Text_: string;
  Pages: TDocPages;
  B: TStringList;
  I: Integer;
begin
  IsError := False;
  Dir := DocsDirFor(Version, Err);
  if Dir = '' then
  begin
    IsError := True;
    Exit(Err);
  end;

  Page := Trim(JsonAsString(JsonMember(Args, 'page')));
  Section := Trim(JsonAsString(JsonMember(Args, 'section')));

  { No page is the index, not an error. It is the question an agent asks
    first, and making it spell a page name to find out what the pages are
    would be backwards. }
  if Page = '' then
  begin
    Pages := DocPages(Dir);
    B := TStringList.Create;
    try
      B.Add('The documentation for Askr ' + Version + ' — ' +
        IntToStr(Length(Pages)) + ' pages. Read one with docs_read, or a ' +
        'single section of one.');
      B.Add('');
      for I := 0 to High(Pages) do
        B.Add('  ' + Pages[I]);
      Result := B.Text;
    finally
      B.Free;
    end;
    Exit;
  end;

  if not DocRead(Dir, Page, Section, Text_, Err) then
  begin
    { A page or a section that is not there is the tool failing to run,
      not a document whose content is bad news. Same line as the build
      tool draws. }
    IsError := True;
    Exit(Err);
  end;
  Result := Text_;
end;

const
  { No arguments. `additionalProperties: false` so that a client which
    invents one is told, rather than having it silently ignored. }
  BuildSchema = '{"type":"object","properties":{},' +
    '"additionalProperties":false}';

  BuildDescription =
    'Compile the Askr project in the working directory and return the ' +
    'compiler diagnostics as file:line:column with a severity. Use this ' +
    'to verify a change rather than assuming it is correct: in Askr a ' +
    'wrong column name, a wrong type in a query, or a misspelled route ' +
    'parameter is a compile error, not a runtime one. Run it after ' +
    'editing Pascal sources and before saying the work is done.';

  DocsSearchSchema =
    '{"type":"object","properties":{' +
    '"query":{"type":"string","description":' +
    '"Exact substring, case-insensitive. Not fuzzy."},' +
    '"limit":{"type":"integer","description":' +
    '"Maximum hits to return. Default 40."}},' +
    '"required":["query"],"additionalProperties":false}';

  DocsSearchDescription =
    'Search the documentation of the exact Askr version this project ' +
    'builds against. Use it before writing framework code: Askr''s API ' +
    'names are easy to guess wrong, and a wrong one is a compile error. ' +
    'The search is an exact substring and never fuzzy, so no match means ' +
    'the name does not exist — not that the docs are thin. Each hit gives ' +
    'page:line and the section, which docs_read takes.';

  DocsReadSchema =
    '{"type":"object","properties":{' +
    '"page":{"type":"string","description":' +
    '"A page such as validation.md. Omit to list every page."},' +
    '"section":{"type":"string","description":' +
    '"A level-two heading on that page, without the ##."}},' +
    '"additionalProperties":false}';

  RoutesSchema = '{"type":"object","properties":{},' +
    '"additionalProperties":false}';

  RoutesDescription =
    'The routing table of the built app, sorted by specificity — which is ' +
    'the order requests actually match, not the order the routes were ' +
    'registered in. It comes from the compiled binary because that is ' +
    'where the routes are; no file in the project lists them in this ' +
    'order. Build first if you have changed a route.';

  OpenApiSchema = '{"type":"object","properties":{' +
    '"check":{"type":"boolean","description":' +
    '"Instead of the document, report what the document and the routes ' +
    'disagree about, in both directions."}},' +
    '"additionalProperties":false}';

  OpenApiDescription =
    'The OpenAPI 3.1 document for this project''s API: paths, parameters, ' +
    'request and response schemas, and which operations need a token. ' +
    'The schemas come from the models'' own metadata, so a column that ' +
    'never leaves the process is not in the document either. With ' +
    'check=true it reports drift instead — a path described that is not ' +
    'a route, or a route under the API that nothing describes — and that ' +
    'is a tool error rather than a document. Build first if you have ' +
    'changed a route.';

  SchemaSchema =
    '{"type":"object","properties":{' +
    '"table":{"type":"string","description":' +
    '"One table, with its columns, types, indexes and foreign keys. ' +
    'Omit to list every table instead."}},' +
    '"additionalProperties":false}';

  SchemaDescription =
    'What the database actually contains, read from the database itself ' +
    'and not from the migrations — a column added by hand, or a migration ' +
    'that failed halfway, is real and shows up here. Call it with no ' +
    'table to list them, then again with one to see its columns. Use it ' +
    'before writing a query: in Askr a wrong column name is a compile ' +
    'error, not a runtime one.';

  ConfigSchema = '{"type":"object","properties":{},' +
    '"additionalProperties":false}';

  ConfigDescription =
    'Every configuration key and which layer it resolved from — a real ' +
    'environment variable, .env, askr.toml, or the built-in default. ' +
    'That layering is computed and cannot be read off any single file, ' +
    'and it answers nearly every question about why a setting is what it ' +
    'is. Values are deliberately never shown, secret-looking or not.';

  TestSchema =
    '{"type":"object","properties":{' +
    '"timeout_seconds":{"type":"integer","description":' +
    '"Give up and stop the suite after this long. Default 120, capped at ' +
    '600."}},' +
    '"additionalProperties":false}';

  TestDescription =
    'Build and run the project''s test suite, and return what it said. ' +
    'A suite that fails is a normal answer, not a tool error — read the ' +
    'output. A suite that did not compile is reported as that, because it ' +
    'needs different work from one that failed. The run is stopped if it ' +
    'takes too long, so a test that waits on a socket or a lock cannot ' +
    'hang this call.';

  DocsReadDescription =
    'Read a documentation page, or one section of it, for the exact Askr ' +
    'version this project builds against. Call it with no page to list ' +
    'every page. Each page also says what the framework does NOT have and ' +
    'why, which is the part that stops an agent from looking for ' +
    'something that was never built.';

{ Wires `askr mcp` into an agent client's configuration.

  THE FILE IS THE USER'S, AND IS NOT REWRITTEN

  When it is not there, it is written. When it is there, it is read and
  left alone: either an askr server is already configured, and there is
  nothing to do, or the lines to add are printed and the user adds them.

  That is not caution for its own sake. The last time this repository
  edited a file a user owns — a `package.json`, by finding a colon — it
  matched the wrong one, replaced the whole dependencies object with a
  string, and said it had succeeded. These files carry comments, ordering
  and formatting that a parse-and-rewrite loses, and half of them are
  JSONC, which our parser does not read at all. Printing four lines is
  worse ergonomics and cannot destroy anything. }
type
  TMcpClient = record
    Key: string;        { what the user types }
    Label_: string;     { what it is called }
    Path_: string;      { relative to the project root }
    Holder: string;     { the object the servers live under }
    Entry: string;      { the server entry itself }
  end;

const
  { VS Code uses `servers` and wants an explicit transport; the others use
    `mcpServers` and infer stdio from `command`. Copied from each client's
    own documentation rather than assumed to be one format. }
  McpClients: array[0..2] of TMcpClient = (
    (Key: 'claude'; Label_: 'Claude Code'; Path_: '.mcp.json';
     Holder: 'mcpServers';
     Entry: '"askr": { "command": "askr", "args": ["mcp"] }'),
    (Key: 'cursor'; Label_: 'Cursor'; Path_: '.cursor/mcp.json';
     Holder: 'mcpServers';
     Entry: '"askr": { "command": "askr", "args": ["mcp"] }'),
    (Key: 'vscode'; Label_: 'VS Code'; Path_: '.vscode/mcp.json';
     Holder: 'servers';
     Entry: '"askr": { "type": "stdio", "command": "askr", "args": ["mcp"] }'));

{ True when the file already configures a server called askr. Read-only:
  the file is parsed and thrown away. }
function AlreadyHasAskr(const Path_, Holder: string): Boolean;
var
  A: TArena;
  L: TStringList;
  Root, Servers: PJsonValue;
  ErrAt: SizeInt;
begin
  Result := False;
  Root := nil;
  A := TArena.Create(64 * 1024);
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(Path_);
    except
      Exit;
    end;
    if not JsonParse(A, StrDup(A, L.Text), Root, ErrAt) then
      { A file we cannot read is a file we must not touch — it may be
        JSONC, which every one of these clients accepts and our parser
        does not. Saying "add this yourself" is right either way. }
      Exit;
    Servers := JsonMember(Root, Holder);
    Result := (Servers <> nil) and (JsonMember(Servers, 'askr') <> nil);
  finally
    L.Free;
    A.Free;
  end;
end;

procedure CmdMcpInstall(P: TProject);
var
  I, Idx: Integer;
  Want, Path_, Dir: string;
  L: TStringList;
begin
  Want := LowerCase(ParamStr(2));
  Idx := 0;                       { Claude Code, unless told otherwise }
  if Want <> '' then
  begin
    Idx := -1;
    for I := Low(McpClients) to High(McpClients) do
      if McpClients[I].Key = Want then
        Idx := I;
    if Idx < 0 then
    begin
      Si('askr: no client called "' + Want + '".');
      Si('');
      for I := Low(McpClients) to High(McpClients) do
        Si(Format('  %-8s  %-12s  %s',
          [McpClients[I].Key, McpClients[I].Label_, McpClients[I].Path_]));
      Halt(1);
    end;
  end;

  Path_ := IncludeTrailingPathDelimiter(P.Root) + McpClients[Idx].Path_;

  if FileExists(Path_) then
  begin
    if AlreadyHasAskr(Path_, McpClients[Idx].Holder) then
    begin
      Si(McpClients[Idx].Label_ + ' already has an askr server: ' +
        McpClients[Idx].Path_);
      Exit;
    end;
    { Not rewritten. See the note on this type. }
    Si(McpClients[Idx].Path_ + ' exists and is yours to edit.');
    Si('Add this under "' + McpClients[Idx].Holder + '":');
    Si('');
    Si('  ' + McpClients[Idx].Entry);
    Si('');
    Exit;
  end;

  Dir := ExtractFileDir(Path_);
  if (Dir <> '') and not DirectoryExists(Dir) then
    ForceDirectories(Dir);

  L := TStringList.Create;
  try
    L.Add('{');
    L.Add('  "' + McpClients[Idx].Holder + '": {');
    L.Add('    ' + McpClients[Idx].Entry);
    L.Add('  }');
    L.Add('}');
    L.SaveToFile(Path_);
  finally
    L.Free;
  end;

  Si('Wrote ' + McpClients[Idx].Path_ + ' for ' + McpClients[Idx].Label_ + '.');
  Si('Restart the client, and it will start `askr mcp` for this project.');
  if Want = '' then
  begin
    Si('');
    Si('Other clients:');
    for I := Low(McpClients) to High(McpClients) do
      if I <> Idx then
        Si(Format('  askr mcp:install %-8s  %s',
          [McpClients[I].Key, McpClients[I].Label_]));
  end;
end;

var
  Kommando: string;
  P: TProject;
  Delegert: Integer;
  RunErr: string;
  LangReport: TStringArray;
  LangOk: Boolean;
  I: Integer;
begin
 try
  Kommando := LowerCase(ParamStr(1));

  if (Kommando = '') or (Kommando = 'help') or (Kommando = '-h') or
     (Kommando = '--help') then
  begin
    Bruk;
    Exit;
  end;

  if (Kommando = 'version') or (Kommando = '-v') or (Kommando = '--version') then
  begin
    { Utenfor et prosjekt er det bare verktøyet som har en versjon. Inne
      i ett er spørsmålet nesten alltid hvilket rammeverk som faktisk
      bygges mot, og det er et annet tall. }
    P := TProject.Find(GetCurrentDir);
    try
      Halt(CmdVersionInfo(P));
    finally
      P.Free;
    end;
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
      Si('Usage: askr new <name>');
      Halt(1);
    end;
    NewProject(GetCurrentDir, ParamStr(2), WantsAuth);
    Exit;
  end;

  { The MCP server runs before FindProject, and that is the point of it.

    FindProject writes to stdout and halts when there is no askr.toml —
    which for a client is not "no project", it is a parse error on the
    protocol channel with nothing to say where it came from. An agent may
    well start the server in the wrong directory, or before the project
    exists.

    Everything from here on is a JSON-RPC message. The server answers the
    handshake wherever it is started; a tool that needs the project says so
    through the protocol, which is the only place a client can read it. }
  if Kommando = 'mcp:install' then
  begin
    P := FindProject;
    try
      CmdMcpInstall(P);
    finally
      P.Free;
    end;
    Exit;
  end;

  if Kommando = 'mcp' then
  begin
    RegisterMcpTool('build', BuildDescription, BuildSchema, @McpToolBuild);
    RegisterMcpTool('docs_search', DocsSearchDescription, DocsSearchSchema,
      @McpToolDocsSearch);
    RegisterMcpTool('docs_read', DocsReadDescription, DocsReadSchema,
      @McpToolDocsRead);
    RegisterMcpTool('routes', RoutesDescription, RoutesSchema,
      @McpToolRoutes);
    RegisterMcpTool('openapi', OpenApiDescription, OpenApiSchema,
      @McpToolOpenApi);
    RegisterMcpTool('schema', SchemaDescription, SchemaSchema,
      @McpToolSchema);
    RegisterMcpTool('config', ConfigDescription, ConfigSchema,
      @McpToolConfig);
    RegisterMcpTool('test', TestDescription, TestSchema, @McpToolTest);
    McpServe;
    Exit;
  end;

  P := FindProject;
  try
    { Kommandoene som styrer selve pinnen må kjøres av verktøyet man
      startet. De andre skal kjøres av versjonen prosjektet peker på. }
    if (Kommando <> 'install') and (Kommando <> 'update') and
       (Kommando <> 'outdated') and (Kommando <> 'new') and
       (Kommando <> 'plugin') then
      if DelegateIfNeeded(P, Delegert) then
        Halt(Delegert);

    if Kommando = 'build' then
      CmdBuild(P)
    else if Kommando = 'serve' then
      CmdServe(P)
    else if Kommando = 'routes' then
      Halt(RunApp(P, '--routes'))
    else if ErAppKommando(Kommando) then
      { Kommandoen hører til appen, ikke til verktøyet: migrasjonene,
        rutene, jobbene og planen er kompilert inn i binæren. Argumentene
        sendes med, slik at --step og --seed virker. }
      Halt(RunApp(P, '--' + Kommando))
    else if Kommando = 'install' then
    begin
      { The framework first: a plugin says which Askr it builds against. }
      Delegert := CmdInstall(P);
      if Delegert = 0 then
        Delegert := InstallPlugins(P);
      Halt(Delegert);
    end
    else if Kommando = 'update' then
      Halt(CmdUpdate(P, ParamStr(2)))
    else if Kommando = 'outdated' then
    begin
      Delegert := CmdOutdated(P);
      OutdatedPlugins(P);
      Halt(Delegert);
    end
    else if Kommando = 'plugin' then
      Halt(CmdPlugin(P))
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
      Write(ConfigReport(HasFlag('values')));
    end
    else if Kommando = 'lang:check' then
    begin
      { The files, not the app: it answers whether or not the app builds. }
      SetCurrentDir(P.Root);
      LoadConfig(P.Root);
      LangOk := LangCheck(P.Root, LangReport);
      for I := 0 to High(LangReport) do
        Si(LangReport[I]);
      if not LangOk then
        Halt(1);
    end
    else if Kommando = 'run' then
    begin
      { Oversetter .run-filene uten å kompilere. Nyttig når man vil se på
        Pascal-koden som kommer ut. }
      if not RunRun(P, False, RunErr) then
      begin
        Si(RunErr);
        Halt(1);
      end;
    end
    else if Kommando = 'repl' then
    begin
      Si('repl is not implemented. It needs an interpreter for Pascal');
      Si('expressions, and is not worth it before the phase 3 language call.');
      Halt(1);
    end
    else if not IsToolCommand(Kommando) then
    begin
      { A word neither the tool nor every app answers to: the app's own,
        if it registered one. Only the app can say -- its commands are
        compiled into it -- so it is asked, and it answers "unknown" with
        exit code 64 when it has none by that name. }
      if FileExists(AppBinaryOf(P)) then
        Halt(RunApp(P, '--' + Kommando));
      Si('Unknown command: ' + Kommando);
      Si('If it is one this app registers, build it first: askr build');
      Si('');
      Bruk;
      Halt(UnknownCommandExit);
    end
    else
    begin
      { Listed as the tool's and handled by nothing above: a tool command
        added to ToolCommands without its branch here. }
      Si(Kommando + ' is listed as a tool command, and nothing in the tool ' +
        'answers it. This is a bug in askr.');
      Halt(1);
    end;
  finally
    P.Free;
  end;
 except
   { A terminal gets the message and a non-zero exit, which is what Halt
     used to do from inside FindCompiler and BuildFlags. }
   on E: ECliFatal do
   begin
     Si(E.Message);
     Halt(1);
   end;
 end;
end.
