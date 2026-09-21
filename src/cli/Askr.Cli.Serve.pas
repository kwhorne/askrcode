{ Askr.Cli.Serve — dev-serveren.

  Dette er der PRD-ens første suksesskriterium avgjøres: under 300 ms fra
  lagret fil til oppdatert nettleser.

  Formen er en supervisor, ikke hot patching. Appen er en kompilert binær;
  den byttes ut i sin helhet. Det som gjør at det likevel oppleves som hot
  reload, er proxyen: den lytter på porten utvikleren bruker og holder
  tilkoblinger mens byttet skjer.

  Løkka er:

      endring oppdaget  ->  proxy pauses
                        ->  inkrementell rebuild
                        ->  gammel prosess stoppes, ny startes
                        ->  vent til den svarer på porten
                        ->  proxy slippes

  Frontend går ikke gjennom dette i det hele tatt. Vite kjører ved siden av
  og gjør HMR selv; en endring i en .svelte-fil utløser ingen rebuild av
  Pascal-siden.

  Tiden måles fra filas mtime, ikke fra da pollingen oppdaget den. Alt annet
  ville skjult deteksjonsforsinkelsen, og den er en reell del av løkka. }
unit Askr.Cli.Serve;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, Process, BaseUnix, Unix, Sockets,
  Askr.Core.Clock, Askr.Cli.Watch, Askr.Cli.Proxy;

type
  TServeOptions = record
    Root: string;
    { .lpr-fila som bygges. }
    MainFile: string;
    BinaryName: string;
    Compiler: string;
    CompilerFlags: string;
    BuildDir: string;
    PublicPort: Word;
    BackendPort: Word;
    { Tom betyr ingen frontend. }
    FrontendDir: string;
    WatchDirs: TStringArray;
    AppArgs: TStringArray;
    PollMs: Integer;
  end;

  TDevServer = class
  private
    FOpts: TServeOptions;
    FProxy: TDevProxy;
    FApp: TProcess;
    FAppPort: Word;
    FVite: TProcess;
    FWatcher: TWatcher;
    FBuilds: Integer;
    FBestMs, FWorstMs, FSumMs: Int64;
    function Build(out Output: string): Boolean;
    function StartAppOn(APort: Word): TProcess;
    procedure StartApp;
    procedure StopApp;
    procedure StopProcess(var P: TProcess);
    function WaitForBackend(APort: Word; TimeoutMs: Integer): Boolean;
    procedure StartVite;
    procedure StopVite;
    procedure Rebuild(const ChangedPath: string);
    procedure Summary;
  public
    constructor Create(const AOpts: TServeOptions);
    destructor Destroy; override;
    procedure Run;
  end;

function DefaultServeOptions: TServeOptions;

implementation

var
  GStop: Boolean = False;

procedure HandleStop(Sig: cint); cdecl;
begin
  GStop := True;
end;

function DefaultServeOptions: TServeOptions;
begin
  Result.Root := GetCurrentDir;
  Result.MainFile := '';
  Result.BinaryName := '';
  Result.Compiler := 'fpc';
  Result.CompilerFlags := '-Sh -O1 -vw';
  Result.BuildDir := '.build';
  Result.PublicPort := 8080;
  Result.BackendPort := 8081;
  Result.FrontendDir := '';
  Result.PollMs := 25;
  SetLength(Result.WatchDirs, 0);
  SetLength(Result.AppArgs, 0);
end;

constructor TDevServer.Create(const AOpts: TServeOptions);
begin
  inherited Create;
  FOpts := AOpts;
  FBestMs := High(Int64);
end;

destructor TDevServer.Destroy;
begin
  StopApp;
  StopVite;
  FProxy.Free;
  FWatcher.Free;
  inherited Destroy;
end;

function TDevServer.Build(out Output: string): Boolean;
var
  P: TProcess;
  Lines: TStringList;
begin
  Output := '';
  P := TProcess.Create(nil);
  Lines := TStringList.Create;
  try
    P.Executable := FOpts.Compiler;
    P.Parameters.Delimiter := ' ';
    P.Parameters.StrictDelimiter := True;
    P.Parameters.DelimitedText := FOpts.CompilerFlags;
    P.Parameters.Add('-FU' + FOpts.BuildDir + PathDelim + 'units');
    P.Parameters.Add('-FE' + FOpts.BuildDir + PathDelim + 'bin');
    P.Parameters.Add(FOpts.MainFile);
    P.CurrentDirectory := FOpts.Root;
    P.Options := [poWaitOnExit, poUsePipes, poStderrToOutPut];
    P.Execute;
    Lines.LoadFromStream(P.Output);
    Output := Lines.Text;
    Result := P.ExitStatus = 0;
  finally
    Lines.Free;
    P.Free;
  end;
end;

function TDevServer.StartAppOn(APort: Word): TProcess;
var
  I: Integer;
begin
  Result := TProcess.Create(nil);
  Result.Executable := IncludeTrailingPathDelimiter(FOpts.Root) +
    FOpts.BuildDir + PathDelim + 'bin' + PathDelim + FOpts.BinaryName;
  Result.Parameters.Add(IntToStr(APort));
  Result.Parameters.Add('127.0.0.1');
  for I := 0 to High(FOpts.AppArgs) do
    Result.Parameters.Add(FOpts.AppArgs[I]);
  Result.CurrentDirectory := FOpts.Root;
  { Appen skriver til samme terminal. Logglinjene fra dev-serveren og fra
    appen hører sammen. }
  Result.Options := [];
  Result.Execute;
end;

procedure TDevServer.StartApp;
begin
  FAppPort := FOpts.BackendPort;
  FApp := StartAppOn(FAppPort);
end;

procedure TDevServer.StopProcess(var P: TProcess);
begin
  if P = nil then
    Exit;
  if P.Running then
  begin
    P.Terminate(0);
    while P.Running do
      Sleep(1);
  end;
  FreeAndNil(P);
end;

procedure TDevServer.StopApp;
begin
  StopProcess(FApp);
end;

function TDevServer.WaitForBackend(APort: Word; TimeoutMs: Integer): Boolean;
var
  Start: Int64;
  Sock: TSocket;
  Addr: TInetSockAddr;
begin
  Start := MonotonicMs;
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := HToNS(APort);
  Addr.sin_addr := StrToNetAddr('127.0.0.1');
  repeat
    Sock := fpSocket(AF_INET, SOCK_STREAM, 0);
    if Sock >= 0 then
    begin
      if fpConnect(Sock, @Addr, SizeOf(Addr)) = 0 then
      begin
        CloseSocket(Sock);
        Exit(True);
      end;
      CloseSocket(Sock);
    end;
    if MonotonicMs - Start > TimeoutMs then
      Exit(False);
    { Ett millisekund. Hele poenget er å komme i gang så fort som mulig. }
    Sleep(1);
  until False;
end;

procedure TDevServer.StartVite;
begin
  if FOpts.FrontendDir = '' then
    Exit;
  if not DirectoryExists(FOpts.FrontendDir) then
    Exit;
  FVite := TProcess.Create(nil);
  FVite.Executable := 'npm';
  FVite.Parameters.Add('run');
  FVite.Parameters.Add('dev');
  FVite.CurrentDirectory := FOpts.FrontendDir;
  FVite.Options := [];
  try
    FVite.Execute;
    WriteLn('  vite      running in ', FOpts.FrontendDir);
  except
    on E: Exception do
    begin
      WriteLn('  vite      could not start: ', E.Message);
      FreeAndNil(FVite);
    end;
  end;
end;

procedure TDevServer.StopVite;
begin
  if FVite = nil then
    Exit;
  if FVite.Running then
    FVite.Terminate(0);
  FreeAndNil(FVite);
end;

procedure TDevServer.Rebuild(const ChangedPath: string);
var
  Output: string;
  Saved, T0, TBuilt, TUp: Int64;
  Total: Int64;
  Ok: Boolean;
  NewPort: Word;
  Old: TProcess;
begin
  Saved := FileMtimeMs(ChangedPath);
  T0 := MonotonicMs;

  FProxy.Pause;
  Ok := Build(Output);
  TBuilt := MonotonicMs;
  if not Ok then
  begin
    WriteLn;
    WriteLn('  FAIL      ', ExtractFileName(ChangedPath));
    Write(Output);
    FProxy.Resume(Output);
    Exit;
  end;

  { Den nye prosessen startes på den andre porten før den gamle drepes.
    Nedstengingen tar 44 ms målt, og den trenger ikke ligge i den kritiske
    stien. Proxyen bytter port i det øyeblikket den nye svarer. }
  if FAppPort = FOpts.BackendPort then
    NewPort := FOpts.BackendPort + 1
  else
    NewPort := FOpts.BackendPort;

  Old := FApp;
  FApp := StartAppOn(NewPort);
  if not WaitForBackend(NewPort, 10000) then
  begin
    StopProcess(FApp);
    FApp := Old;
    FProxy.Resume('The app started but is not answering on port ' +
      IntToStr(NewPort) + '.');
    Exit;
  end;

  FAppPort := NewPort;
  FProxy.BackendPort := NewPort;
  FProxy.Resume('');
  TUp := MonotonicMs;

  { Veggklokka leses her, før den gamle prosessen drepes. Leses den etterpå,
    havner nedstengingen i tallet selv om ingen venter på den. }
  Total := UnixNowMs - Saved;

  { Utenfor målingen, og utenfor det brukeren venter på. }
  StopProcess(Old);

  { Deteksjonen er det som skjedde før T0: tiden fra editoren skrev fila til
    pollingen så den. Den regnes ut som resten, og skjules ikke — den er en
    reell del av løkka. }
  if Total < 0 then
    Total := TUp - T0;

  Inc(FBuilds);
  Inc(FSumMs, Total);
  if Total < FBestMs then
    FBestMs := Total;
  if Total > FWorstMs then
    FWorstMs := Total;

  WriteLn(Format('  %-4dms   %s   (oppdaget %d, bygg %d, oppstart %d)',
    [Total, ExtractFileName(ChangedPath),
     Total - (TUp - T0), TBuilt - T0, TUp - TBuilt]));
end;

procedure TDevServer.Summary;
begin
  if FBuilds = 0 then
    Exit;
  WriteLn;
  WriteLn(Format('%d rebuilds — raskeste %d ms, tregeste %d ms, snitt %d ms',
    [FBuilds, FBestMs, FWorstMs, FSumMs div FBuilds]));
  if FProxy.HeldTotal > 0 then
    WriteLn(Format('%d requests were held while the code swapped, longest %d ms',
      [FProxy.HeldTotal, FProxy.HeldMaxMs]));
end;

procedure TDevServer.Run;
var
  Output, Changed: string;
  Kind: TWatchKind;
  I: Integer;
begin
  fpSignal(SIGINT, @HandleStop);
  fpSignal(SIGTERM, @HandleStop);

  ForceDirectories(IncludeTrailingPathDelimiter(FOpts.Root) +
    FOpts.BuildDir + PathDelim + 'units');
  ForceDirectories(IncludeTrailingPathDelimiter(FOpts.Root) +
    FOpts.BuildDir + PathDelim + 'bin');

  Write('  bygger    ');
  if not Build(Output) then
  begin
    WriteLn('failed');
    Write(Output);
    Halt(1);
  end;
  WriteLn('ok');

  FWatcher := TWatcher.Create;
  FWatcher.AddBackendExt('.pas');
  FWatcher.AddBackendExt('.lpr');
  FWatcher.AddBackendExt('.inc');
  FWatcher.AddFrontendExt('.svelte');
  FWatcher.AddFrontendExt('.js');
  FWatcher.AddFrontendExt('.ts');
  FWatcher.AddFrontendExt('.css');
  FWatcher.IgnoreDir('node_modules');
  FWatcher.IgnoreDir('.build');
  FWatcher.IgnoreDir('public');
  for I := 0 to High(FOpts.WatchDirs) do
    FWatcher.AddRoot(FOpts.WatchDirs[I]);
  FWatcher.Prime;

  StartApp;
  if not WaitForBackend(FAppPort, 10000) then
  begin
    WriteLn('  the app did not come up on port ', FAppPort);
    Halt(1);
  end;

  FProxy := TDevProxy.Create(FOpts.PublicPort, FAppPort);
  FProxy.Start;

  StartVite;

  WriteLn('  watching  ', FWatcher.FileCount, ' filer');
  WriteLn;
  WriteLn('  http://127.0.0.1:', FOpts.PublicPort);
  WriteLn('  Ctrl-C to stop.');
  WriteLn;

  while not GStop do
  begin
    Kind := FWatcher.Poll(Changed);
    case Kind of
      wkBackend: Rebuild(Changed);
      wkFrontend:
        { Vite tar denne selv. Pascal-siden skal ikke bygges. }
        WriteLn('  vite      ', ExtractFileName(Changed));
      wkNone: ;
    end;
    Sleep(FOpts.PollMs);
  end;

  WriteLn;
  WriteLn('Stopper.');
  Summary;
  FProxy.Stop;
  StopApp;
  StopVite;
end;

end.
