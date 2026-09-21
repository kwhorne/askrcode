{ Askr.Cli.Pkg — versjoner, cache og lock.

  Et prosjekt pinner en rammeverksversjon i askr.toml og den nøyaktige
  commit-en i askr.lock. Kilden hentes til ~/.askr/pkg/askrcode@<versjon>
  og deles mellom alle prosjekter på maskinen. En hel versjon er 2,2 MB
  kilde som kompilerer på halvannet sekund, så det distribueres ingen
  binærer: .ppu-filer er dessuten bundet til nøyaktig FPC-versjon og skal
  ikke deles mellom prosjekter i det hele tatt.

  En utgivelse spenner over TO økosystemer — Pascal-kilden og
  @askrcode/lauf på npm — og det er den virkelige grunnen til at dette
  trenger en lock. Går de ut av takt, får du en DataGrid.svelte som ikke
  passer Askr.Urd.Grid på serveren, og ingenting sier fra før en kolonne
  slutter å sortere. Derfor eier lockfila begge, og `askr install`
  skriver npm-versjonen inn i frontend/package.json.

  `path` i askr.toml overstyrer alt. Det er for den som utvikler selve
  rammeverket, og er samme rolle som `replace` i go.mod. }
unit Askr.Cli.Pkg;

{$mode Delphi}{$H+}

interface

uses
{$IFDEF UNIX}
  BaseUnix,
{$ENDIF}
  SysUtils, Classes, Process,
  Askr.Core.Config, Askr.Core.Version, Askr.Cli.Project;

const
  DefaultSource = 'https://github.com/kwhorne/askrcode.git';

type
  TLock = record
    Version: string;
    Commit: string;
    Lauf: string;
    Found: Boolean;
  end;

  { Hvor rammeverket kom fra. Brukes i utskrift, slik at «askr version»
    kan si om du kjører en pinnet versjon eller en lokal utsjekking —
    forskjellen forklarer nesten alle «men det virket i går». }
  TPkgOrigin = (poNone, poPath, poCache);

{ ~/.askr/pkg, eller ASKR_CACHE når den er satt — CI vil ha den et sted
  den kan mellomlagre.

  IKKE ASKR_HOME. Den betyr allerede rammeverkets utsjekking, og
  byggskriptet ber folk sette den dit. Leste cachen den samme variabelen,
  ville alle som fulgte instruksjonen fått pakkene skrevet inn i sin egen
  utsjekking. }
function CacheRoot: string;
function CacheDirFor(const Version: string): string;

function LockPath(const Root: string): string;
function ReadLock(const Root: string): TLock;
procedure WriteLock(const Root: string; const L: TLock);

{ Versjonen et tre faktisk er, lest ut av kilden — ikke ut av navnet på
  katalogen. En cache-katalog kan være halvferdig etter en avbrutt
  nedlasting, og da skal den ikke telle som installert. }
function TreeVersion(const Dir: string): string;
function TreeLaufVersion(const Dir: string): string;
function TreeIsComplete(const Dir: string): Boolean;

{ Stien rammeverket skal bygges fra. Tom streng når den ikke kan løses;
  Feil sier da hva som mangler og hva man skal gjøre. }
function ResolveFramework(P: TProject; out Origin: TPkgOrigin;
  out Feil: string): string;

function InstalledVersions: TStringArray;
function RemoteVersions(const Source: string): TStringArray;

function Fetch(const Source, Version: string; out Commit, Feil: string): Boolean;

function CmdInstall(P: TProject): Integer;
function CmdUpdate(P: TProject; const Target: string): Integer;
function CmdOutdated(P: TProject): Integer;
{ Kjører kommandoen med CLI-en som hører til den pinnede versjonen, når
  den ikke er denne. Returnerer False når ingenting ble delegert.

  Dette er ikke pynt. Lista over unit-kataloger (AskrUnits) er kompilert
  inn i verktøyet, så et 0.6.0-verktøy som bygger mot 0.7.0 ikke ville
  lagt en ny katalog på søkestien — og feilen hadde vært «unit not
  found», som peker et helt annet sted enn årsaken. Samme rolle som
  bundle exec og ./gradlew. }
function DelegateIfNeeded(P: TProject; out ExitKode: Integer): Boolean;

function CmdVersionInfo(P: TProject): Integer;

implementation

{ ----------------------------------------------------------- utskrift -- }

procedure Si(const S: string);
begin
  WriteLn(S);
  Flush(Output);
end;

{ ------------------------------------------------------------ prosess -- }

{ Kjører og fanger stdout. Git skriver framdrift til stderr, som får gå
  til terminalen — en nedlasting som ser ut som ingenting er verre enn
  støy. }
function RunCapture(const Exe: string; const Args: array of string;
  const WorkDir: string; out Ut: string): Integer;
var
  Proc: TProcess;
  I: Integer;
  Buf: array[0..4095] of Byte;
  N: LongInt;
  S: TStringStream;
begin
  Ut := '';
  Result := -1;
  Proc := TProcess.Create(nil);
  S := TStringStream.Create('');
  try
    Proc.Executable := Exe;
    for I := Low(Args) to High(Args) do
      Proc.Parameters.Add(Args[I]);
    if WorkDir <> '' then
      Proc.CurrentDirectory := WorkDir;
    Proc.Options := [poUsePipes];
    try
      Proc.Execute;
    except
      on E: Exception do
      begin
        Ut := E.Message;
        Exit(-1);
      end;
    end;
    while Proc.Running or (Proc.Output.NumBytesAvailable > 0) do
    begin
      if Proc.Output.NumBytesAvailable > 0 then
      begin
        N := Proc.Output.Read(Buf, SizeOf(Buf));
        if N > 0 then
          S.Write(Buf, N);
      end
      else
        Sleep(5);
    end;
    Ut := S.DataString;
    Result := Proc.ExitStatus;
  finally
    S.Free;
    Proc.Free;
  end;
end;

{ Kjører med utdata rett til terminalen. For git clone og npm install,
  der brukeren skal se hva som skjer. }
function RunThrough(const Exe: string; const Args: array of string;
  const WorkDir: string): Integer;
var
  Proc: TProcess;
  I: Integer;
begin
  Proc := TProcess.Create(nil);
  try
    Proc.Executable := Exe;
    for I := Low(Args) to High(Args) do
      Proc.Parameters.Add(Args[I]);
    if WorkDir <> '' then
      Proc.CurrentDirectory := WorkDir;
    Proc.Options := [poWaitOnExit];
    try
      Proc.Execute;
      Result := Proc.ExitStatus;
    except
      on E: Exception do
        Result := -1;
    end;
  finally
    Proc.Free;
  end;
end;

function HarGit: Boolean;
var
  Ut: string;
begin
  Result := RunCapture('/usr/bin/env', ['git', '--version'], '', Ut) = 0;
end;

{ Commit-en et tre faktisk står på. Uten denne ble lockfila
  meningsløs: CmdInstall falt tilbake til L.Commit når cachen alt var
  full, og sammenlignet dermed verdien med seg selv. En tuklet lock gikk
  rett gjennom og ble skrevet ut som om den var ekte. }
function CommitOf(const Dir: string): string;
var
  Ut: string;
begin
  Result := '';
  if not DirectoryExists(IncludeTrailingPathDelimiter(Dir) + '.git') then
    Exit;
  if RunCapture('/usr/bin/env', ['git', 'rev-parse', 'HEAD'], Dir, Ut) = 0 then
    Result := Trim(Ut);
end;

{ ---------------------------------------------------------- cache-sti -- }

function CacheRoot: string;
var
  H: string;
begin
  H := GetEnvironmentVariable('ASKR_CACHE');
  if H <> '' then
    Exit(ExcludeTrailingPathDelimiter(H));
  Result := IncludeTrailingPathDelimiter(
    IncludeTrailingPathDelimiter(GetEnvironmentVariable('HOME')) + '.askr') + 'pkg';
end;

function CacheDirFor(const Version: string): string;
begin
  Result := IncludeTrailingPathDelimiter(CacheRoot) + 'askrcode@' + Version;
end;

{ --------------------------------------------------------------- lock -- }

function LockPath(const Root: string): string;
begin
  Result := IncludeTrailingPathDelimiter(Root) + 'askr.lock';
end;

function ReadLock(const Root: string): TLock;
var
  L: TStringList;
begin
  Result.Version := '';
  Result.Commit := '';
  Result.Lauf := '';
  Result.Found := False;
  if not FileExists(LockPath(Root)) then
    Exit;
  L := TStringList.Create;
  try
    { Samme TOML-parser som askr.toml og appen bruker. To parsere for
      samme format er to måter å lese den samme fila feil på. }
    if not ParseTomlInto(LockPath(Root), L) then
      Exit;
    Result.Version := L.Values['version'];
    Result.Commit := L.Values['commit'];
    Result.Lauf := L.Values['lauf'];
    Result.Found := Result.Version <> '';
  finally
    L.Free;
  end;
end;

procedure WriteLock(const Root: string; const L: TLock);
var
  F: TStringList;
begin
  F := TStringList.Create;
  try
    F.Add('# Written by askr. Commit this file.');
    F.Add('#');
    F.Add('# version is the framework release this project is built');
    F.Add('# against. lauf is the @askrcode/lauf version that belongs');
    F.Add('# to it — one release spans both, and they are not allowed');
    F.Add('# to drift apart.');
    F.Add('');
    F.Add('version = "' + L.Version + '"');
    F.Add('commit = "' + L.Commit + '"');
    F.Add('lauf = "' + L.Lauf + '"');
    F.SaveToFile(LockPath(Root));
  finally
    F.Free;
  end;
end;

{ ------------------------------------------------------- lese et tre -- }

{ Leser konstanten ut av kilden. Katalognavnet er ikke bevis: en avbrutt
  nedlasting etterlater en katalog som heter riktig og inneholder halve
  rammeverket. }
function TreeVersion(const Dir: string): string;
var
  F: TStringList;
  I, A, B: Integer;
  S: string;
  Sti: string;
begin
  Result := '';
  Sti := IncludeTrailingPathDelimiter(Dir) + 'src/core/Askr.Core.Version.pas';
  if not FileExists(Sti) then
    Exit;
  F := TStringList.Create;
  try
    F.LoadFromFile(Sti);
    for I := 0 to F.Count - 1 do
    begin
      S := Trim(F[I]);
      if Pos('AskrVersion', S) = 1 then
      begin
        A := Pos('''', S);
        if A = 0 then Continue;
        B := Pos('''', S, A + 1);
        if B = 0 then Continue;
        Exit(Copy(S, A + 1, B - A - 1));
      end;
    end;
  finally
    F.Free;
  end;
end;

function TreeLaufVersion(const Dir: string): string;
var
  F: TStringList;
  I, A, B: Integer;
  S, Sti: string;
begin
  Result := '';
  Sti := IncludeTrailingPathDelimiter(Dir) + 'frontend/lauf/package.json';
  if not FileExists(Sti) then
    Exit;
  F := TStringList.Create;
  try
    F.LoadFromFile(Sti);
    for I := 0 to F.Count - 1 do
    begin
      S := Trim(F[I]);
      if Pos('"version"', S) = 1 then
      begin
        A := Pos(':', S);
        if A = 0 then Continue;
        A := Pos('"', S, A);
        if A = 0 then Continue;
        B := Pos('"', S, A + 1);
        if B = 0 then Continue;
        Exit(Copy(S, A + 1, B - A - 1));
      end;
    end;
  finally
    F.Free;
  end;
end;

function TreeIsComplete(const Dir: string): Boolean;
begin
  Result := (TreeVersion(Dir) <> '') and
            DirectoryExists(IncludeTrailingPathDelimiter(Dir) + 'src') and
            DirectoryExists(IncludeTrailingPathDelimiter(Dir) + 'cli');
end;

{ ------------------------------------------------------------- løsing -- }

function ResolveFramework(P: TProject; out Origin: TPkgOrigin;
  out Feil: string): string;
var
  L: TLock;
  Dir, Onsket: string;
begin
  Result := '';
  Feil := '';
  Origin := poNone;

  { 1. En eksplisitt sti vinner alltid. Den som utvikler rammeverket skal
       ikke måtte gi ut en versjon for å teste en endring. }
  Dir := P.AskrPath;
  if Dir <> '' then
  begin
    if not TreeIsComplete(Dir) then
    begin
      Feil := 'askr.toml points at ' + Dir + ' but that is not an Askr' +
              ' checkout (no src/core/Askr.Core.Version.pas).';
      Exit;
    end;
    Origin := poPath;
    Exit(Dir);
  end;

  { 2. Ellers den låste versjonen fra cachen. }
  L := ReadLock(P.Root);
  Onsket := L.Version;
  if Onsket = '' then
    Onsket := P.AskrWantedVersion;
  if Onsket = '' then
  begin
    Feil := 'this project does not say which Askr version it needs.' + LineEnding +
            LineEnding +
            '  add it to askr.toml:' + LineEnding +
            LineEnding +
            '    [askr]' + LineEnding +
            '    version = "' + AskrVersion + '"' + LineEnding +
            LineEnding +
            '  then run: askr install';
    Exit;
  end;

  Dir := CacheDirFor(Onsket);
  if not TreeIsComplete(Dir) then
  begin
    Feil := 'Askr ' + Onsket + ' is not installed.' + LineEnding +
            LineEnding +
            '  looked in  ' + Dir + LineEnding +
            LineEnding +
            '  run: askr install';
    Exit;
  end;

  Origin := poCache;
  Result := Dir;
end;

{ --------------------------------------------------------- versjoner -- }

function InstalledVersions: TStringArray;
var
  R: TSearchRec;
  Rot, V: string;
  N: Integer;
  Liste: TStringArray;
begin
  { Bygges lokalt og tilordnes til slutt. SetLength rett på Result gir
    «function result variable of a managed type does not seem to be
    initialized», og suitene her er advarselsfrie. }
  Liste := nil;
  SetLength(Liste, 0);
  Result := Liste;
  Rot := IncludeTrailingPathDelimiter(CacheRoot);
  if not DirectoryExists(Rot) then
    Exit;
  N := 0;
  if FindFirst(Rot + 'askrcode@*', faDirectory, R) = 0 then
  try
    repeat
      if (R.Name = '.') or (R.Name = '..') then
        Continue;
      V := TreeVersion(Rot + R.Name);
      if V = '' then
        Continue;
      SetLength(Liste, N + 1);
      Liste[N] := V;
      Inc(N);
    until FindNext(R) <> 0;
  finally
    FindClose(R);
  end;
  Result := Liste;
end;

{ Taggene på fjernsiden, nyeste sist. Krever nett; en tom liste betyr
  enten ingen tagger eller ingen forbindelse, og kallstedet skiller dem
  ved hjelp av returverdien fra git. }
function RemoteVersions(const Source: string): TStringArray;
var
  Ut, Linje, Tag: string;
  L: TStringList;
  I, P2, N: Integer;
  Tmp: string;
  J, K: Integer;
  Liste: TStringArray;
begin
  Liste := nil;
  SetLength(Liste, 0);
  Result := Liste;
  if RunCapture('/usr/bin/env', ['git', 'ls-remote', '--tags', '--refs',
                                 Source], '', Ut) <> 0 then
    Exit;
  L := TStringList.Create;
  try
    L.Text := Ut;
    N := 0;
    for I := 0 to L.Count - 1 do
    begin
      Linje := L[I];
      P2 := Pos('refs/tags/', Linje);
      if P2 = 0 then
        Continue;
      Tag := Trim(Copy(Linje, P2 + Length('refs/tags/'), Length(Linje)));
      if not ParseSemVer(Tag).Valid then
        Continue;
      SetLength(Liste, N + 1);
      { 'v' fjernes her, slik at resten av koden aldri må vite om en
        versjon kom fra en tag eller fra askr.toml. }
      if (Tag <> '') and ((Tag[1] = 'v') or (Tag[1] = 'V')) then
        Liste[N] := Copy(Tag, 2, Length(Tag))
      else
        Liste[N] := Tag;
      Inc(N);
    end;
  finally
    L.Free;
  end;

  { Innstikksortering. Lista er kort, og å dra inn en generisk sortering
    for ti tagger er feil bytte. }
  for J := 1 to High(Liste) do
  begin
    Tmp := Liste[J];
    K := J - 1;
    while (K >= 0) and (CompareSemVer(Liste[K], Tmp) > 0) do
    begin
      Liste[K + 1] := Liste[K];
      Dec(K);
    end;
    Liste[K + 1] := Tmp;
  end;
  Result := Liste;
end;

{ ------------------------------------------------------------- henting -- }

function Fetch(const Source, Version: string; out Commit, Feil: string): Boolean;
var
  Maal, Midl, Ut, Fant, Klonelogg: string;
begin
  Result := False;
  Commit := '';
  Feil := '';

  if not HarGit then
  begin
    Feil := 'git was not found on PATH. askr install fetches the' +
            ' framework with git.';
    Exit;
  end;

  Maal := CacheDirFor(Version);
  if TreeIsComplete(Maal) then
  begin
    { Allerede der. Commit-en leses ut av utsjekkingen. }
    RunCapture('/usr/bin/env', ['git', 'rev-parse', 'HEAD'], Maal, Ut);
    Commit := Trim(Ut);
    Exit(True);
  end;

  ForceDirectories(CacheRoot);
  { Hentes til en midlertidig katalog og flyttes på plass til slutt. En
    avbrutt nedlasting skal ikke etterlate noe som ser installert ut. }
  Midl := Maal + '.tmp';
  if DirectoryExists(Midl) then
    RunCapture('/usr/bin/env', ['rm', '-rf', Midl], '', Ut);

  Si('  fetching Askr ' + Version + ' from ' + Source);
  { Fanges i stedet for å slippes ut. En annotert tag får git til å
    skrive «refs/tags/v0.6.0 <sha> is not a commit!» under --depth 1:
    tag-objektet har sin egen sha, og klonen blir riktig likevel —
    commit-en leses ut av utsjekkingen etterpå. Advarselen sier
    ingenting en bruker kan gjøre noe med. Feiler klonen, vises alt,
    for da er det nettopp utdataene man trenger. }
  if RunCapture('/usr/bin/env',
       ['git', '-c', 'advice.detachedHead=false', 'clone', '--depth', '1',
        '--branch', 'v' + Version, '--quiet', Source, Midl], '', Klonelogg) <> 0 then
  begin
    Si(Klonelogg);
    RunCapture('/usr/bin/env', ['rm', '-rf', Midl], '', Ut);
    Feil := 'could not fetch v' + Version + ' from ' + Source + '.' +
            LineEnding + LineEnding +
            '  the tag may not exist. see what is published with:' +
            LineEnding + '    askr outdated';
    Exit;
  end;

  { Treet må si at det ER versjonen vi ba om. En tag som peker på feil
    kode er nettopp den feilen ingen oppdager før den er i produksjon. }
  Fant := TreeVersion(Midl);
  if Fant <> Version then
  begin
    RunCapture('/usr/bin/env', ['rm', '-rf', Midl], '', Ut);
    if Fant = '' then
      Feil := 'the tag v' + Version + ' does not look like an Askr' +
              ' checkout: src/core/Askr.Core.Version.pas is missing.'
    else
      Feil := 'the tag v' + Version + ' contains Askr ' + Fant +
              '. Refusing to install it under the wrong name.';
    Exit;
  end;

  RunCapture('/usr/bin/env', ['git', 'rev-parse', 'HEAD'], Midl, Ut);
  Commit := Trim(Ut);

  if not RenameFile(Midl, Maal) then
  begin
    RunCapture('/usr/bin/env', ['rm', '-rf', Midl], '', Ut);
    Feil := 'could not move the download into ' + Maal;
    Exit;
  end;
  Result := True;
end;

{ Peker frontend/.askr/lauf paa den installerte utgivelsen.

  Uten den maa package.json baere en absolutt sti inn i DIN cache, og da
  gir fila en diff som endrer seg per maskin. Symlinken er gitignorert
  og lages av install, saa den committede stien er `file:./.askr/lauf`
  og lik overalt.

  Returnerer stien som skal staa i package.json. Kan symlinken ikke
  lages -- et filsystem uten dem, eller Windows -- faller den tilbake
  til den absolutte stien, som virker like godt lokalt. }
function LaufSti(P: TProject; const Dir: string): string;
var
  Mappe, Lenke, Maal: string;
begin
  Maal := IncludeTrailingPathDelimiter(Dir) + 'frontend/lauf';
  Result := 'file:' + Maal;
  if P.FrontendDir = '' then
    Exit;

  Mappe := IncludeTrailingPathDelimiter(P.FrontendDir) + '.askr';
  Lenke := IncludeTrailingPathDelimiter(Mappe) + 'lauf';
  if not ForceDirectories(Mappe) then
    Exit;

{$IFDEF UNIX}
  { En gammel lenke kan peke paa forrige versjon. fpUnlink bryr seg ikke
    om at den ikke finnes. }
  fpUnlink(PChar(Lenke));
  if fpSymlink(PChar(Maal), PChar(Lenke)) = 0 then
    Result := 'file:./.askr/lauf';
{$ENDIF}
end;

{ -------------------------------------------------- Lauf i takt med -- }

{ Skriver @askrcode/lauf-versjonen inn i frontend/package.json.

  Bare selve verdien byttes. Første utgave tok Pos(':', Linje) — den
  FØRSTE kolonen på linja — og på en kompakt package.json tilhører den
  "dependencies", ikke "@askrcode/lauf". Resultatet var at hele
  dependencies-objektet ble erstattet av én streng: @inertiajs/svelte
  forsvant, og JSON-en ble ugyldig. Den skrev altså over en fil brukeren
  eier, uten å si fra.

  Nå finnes kolonen etter nøkkelen, og bare den siterte verdien etter
  den byttes ut. Ser linja ikke ut som forventet, gjettes det ikke:
  funksjonen sier hva som skal stå. Samme regel som InstallerRuter i
  stillaset. }
function SettLaufAvhengighet(P: TProject; const LaufSpec: string;
  out Endret: Boolean): Boolean;
const
  Nokkel = '"@askrcode/lauf"';
var
  Sti, S, Ny: string;
  F: TStringList;
  I, PN, A, V1, V2: Integer;
begin
  Endret := False;
  { FrontendDir er allerede absolutt. Å legge Root foran ga en sti som
    aldri fantes, og da gjorde denne funksjonen ingenting og meldte
    suksess. }
  if P.FrontendDir = '' then
    Exit(True);   { prosjektet har ingen frontend }
  Sti := IncludeTrailingPathDelimiter(P.FrontendDir) + 'package.json';
  if not FileExists(Sti) then
  begin
    Si('  no package.json in ' + P.FrontendDir + ' -- skipping the Lauf pin.');
    Exit(True);
  end;

  F := TStringList.Create;
  try
    F.LoadFromFile(Sti);
    for I := 0 to F.Count - 1 do
    begin
      S := F[I];
      PN := Pos(Nokkel, S);
      if PN = 0 then
        Continue;

      { Kolonen som hører til NØKKELEN, ikke den første på linja. }
      A := Pos(':', S, PN + Length(Nokkel));
      if A = 0 then
        Break;

      (* Verdien maa vaere en sitert streng, og det maa sjekkes paa det
         FOERSTE tegnet etter kolonen. Lette man bare etter neste
         anfoerselstegn, traff man inn i et objekt: en verdi som selv er
         et objekt med et version-felt ble da skrevet over i stedet for
         avvist. *)
      V1 := A + 1;
      while (V1 <= Length(S)) and (S[V1] in [' ', #9]) do
        Inc(V1);
      if (V1 > Length(S)) or (S[V1] <> '"') then
        Break;
      V2 := Pos('"', S, V1 + 1);
      if V2 = 0 then
        Break;

      { Anførselstegnene beholdes: LaufSpec er verdien uten dem. }
      Ny := Copy(S, 1, V1) + LaufSpec + Copy(S, V2, Length(S));
      if Ny <> S then
      begin
        F[I] := Ny;
        F.SaveToFile(Sti);
        Endret := True;
      end;
      Exit(True);
    end;
  finally
    F.Free;
  end;

  Si('  could not find ' + Nokkel + ' in ' + Sti);
  Si('  add this to its "dependencies" yourself:');
  Si('');
  Si('    ' + Nokkel + ': ' + LaufSpec);
  Si('');
  Result := False;
end;

{ Setter [askr] version i askr.toml. Finner den ikke linja, gjetter den
  ikke -- den sier hva som skal stå. Samme regel som InstallerRuter i
  stillaset. }
function SettPinnetVersjon(P: TProject; const Versjon: string): Boolean;
var
  F: TStringList;
  I, A: Integer;
  S2, Sti: string;
  ISeksjon: Boolean;
begin
  Result := False;
  Sti := IncludeTrailingPathDelimiter(P.Root) + 'askr.toml';
  F := TStringList.Create;
  try
    F.LoadFromFile(Sti);
    ISeksjon := False;
    for I := 0 to F.Count - 1 do
    begin
      S2 := Trim(F[I]);
      if (S2 <> '') and (S2[1] = '[') then
      begin
        ISeksjon := LowerCase(S2) = '[askr]';
        Continue;
      end;
      if not ISeksjon then
        Continue;
      if Pos('version', S2) <> 1 then
        Continue;
      A := Pos('=', F[I]);
      if A = 0 then
        Continue;
      F[I] := Copy(F[I], 1, A) + ' "' + Versjon + '"';
      F.SaveToFile(Sti);
      Exit(True);
    end;
  finally
    F.Free;
  end;

  Si('  could not find `version` under [askr] in askr.toml.');
  Si('  set it yourself, so the pin and the lock agree:');
  Si('');
  Si('    [askr]');
  Si('    version = "' + Versjon + '"');
  Si('');
end;

{ --------------------------------------------- oppgraderingsnotater -- }

{ Henter avsnittene i UPGRADE.md som gjelder strekningen Fra..Til.

  Formatet er en H2 per versjon: `## 0.7.0`. Alt mellom en overskrift og
  den neste hører til den versjonen. }
function UpgradeNotes(const Dir, Fra, Til: string): string;
var
  F: TStringList;
  I: Integer;
  S, V, Ut: string;
  Med: Boolean;
begin
  Result := '';
  if not FileExists(IncludeTrailingPathDelimiter(Dir) + 'UPGRADE.md') then
    Exit;
  F := TStringList.Create;
  try
    F.LoadFromFile(IncludeTrailingPathDelimiter(Dir) + 'UPGRADE.md');
    Med := False;
    Ut := '';
    for I := 0 to F.Count - 1 do
    begin
      S := F[I];
      if Pos('## ', S) = 1 then
      begin
        V := Trim(Copy(S, 4, Length(S)));
        { Med når versjonen er nyere enn den vi står på, og ikke nyere
          enn den vi skal til. }
        Med := ParseSemVer(V).Valid and
               (CompareSemVer(V, Fra) > 0) and
               (CompareSemVer(V, Til) <= 0);
      end;
      if Med then
        Ut := Ut + S + LineEnding;
    end;
    Result := Trim(Ut);
  finally
    F.Free;
  end;
end;

{ ---------------------------------------------------------- kommandoer -- }

function CmdInstall(P: TProject): Integer;
var
  L: TLock;
  Onsket, Dir, Commit, Feil, Lauf: string;
  Endret: Boolean;
begin
  Result := 0;

  if P.AskrPath <> '' then
  begin
    Si('askr.toml pins a local path, so there is nothing to install:');
    Si('  ' + P.AskrPath + '  (Askr ' + TreeVersion(P.AskrPath) + ')');
    Si('');
    Si('Remove `path` from [askr] to use a published version instead.');
    Exit;
  end;

  L := ReadLock(P.Root);
  Onsket := L.Version;
  if Onsket = '' then
    Onsket := P.AskrWantedVersion;
  if Onsket = '' then
  begin
    Si('askr.toml does not say which version to install.');
    Si('');
    Si('  [askr]');
    Si('  version = "' + AskrVersion + '"');
    Exit(1);
  end;

  Dir := CacheDirFor(Onsket);
  if TreeIsComplete(Dir) then
  begin
    Si('Askr ' + Onsket + ' is already installed.');
    { Leses ut av utsjekkingen, ikke ut av lockfila. Det er hele
      poenget med sjekken under. }
    Commit := CommitOf(Dir);
  end
  else if not Fetch(P.AskrSource, Onsket, Commit, Feil) then
  begin
    Si('askr: ' + Feil);
    Exit(1);
  end;

  { Låst commit og det som faktisk ligger i cachen må stemme. Gjør de
    ikke det, er enten taggen flyttet eller cachen rørt — begge deler
    skal sies fra om, ikke overskrives i stillhet. }
  if (L.Found) and (L.Commit <> '') and (Commit <> '') and
     (L.Commit <> Commit) then
  begin
    Si('askr: askr.lock pins commit ' + Copy(L.Commit, 1, 12) + ' for ' +
       Onsket + ',');
    Si('      but the copy in the cache is ' + Copy(Commit, 1, 12) + '.');
    Si('');
    Si('  the tag may have been moved. remove the cached copy to refetch:');
    Si('    rm -rf ' + Dir);
    Exit(1);
  end;

  Lauf := TreeLaufVersion(Dir);
  if Lauf = '' then
    Lauf := Onsket;

  { Lauf er ikke publisert på npm ennå, så avhengigheten peker inn i den
    versjonen vi nettopp installerte. Naar pakka er publisert, blir dette
    versjonsnummeret og ingenting annet endrer seg. }
  if not SettLaufAvhengighet(P, LaufSti(P, Dir), Endret) then
    Result := 1;

  L.Version := Onsket;
  L.Commit := Commit;
  L.Lauf := Lauf;
  WriteLock(P.Root, L);

  Si('');
  Si('Askr ' + Onsket + '  (' + Copy(Commit, 1, 12) + ')');
  Si('  framework  ' + Dir);
  Si('  lauf       ' + Lauf);
  Si('  lock       ' + LockPath(P.Root));
  if Endret then
  begin
    Si('');
    Si('frontend/package.json changed. Run this to pick it up:');
    Si('  (cd ' + P.FrontendDir + ' && npm install)');
  end;
end;

function CmdUpdate(P: TProject; const Target: string): Integer;
var
  L: TLock;
  Tags: TStringArray;
  Naa, Til, Notater, Commit, Feil: string;
  I: Integer;
  Spec: string;
begin
  Result := 0;

  if P.AskrPath <> '' then
  begin
    Si('askr.toml pins a local path. Update it with git instead:');
    Si('  git -C ' + P.AskrPath + ' pull');
    Exit;
  end;

  L := ReadLock(P.Root);
  Naa := L.Version;
  if Naa = '' then
    Naa := P.AskrWantedVersion;

  Tags := nil;
  if Target <> '' then
    Til := Target
  else
  begin
    Si('Looking for newer releases...');
    Tags := RemoteVersions(P.AskrSource);
    if Length(Tags) = 0 then
    begin
      Si('askr: no releases found at ' + P.AskrSource);
      Si('      (no tags, or no network)');
      Exit(1);
    end;
    { askr.toml kan begrense hvor langt update får gå, med samme
      skrivemåte som package.json: ^0.6.0 eller ~0.6.0. }
    Spec := P.AskrWantedVersion;
    Til := '';
    for I := High(Tags) downto 0 do
      if (Spec = '') or SatisfiesRange(Tags[I], Spec) then
      begin
        Til := Tags[I];
        Break;
      end;
    if Til = '' then
    begin
      Si('askr: nothing published matches ' + Spec);
      Exit(1);
    end;
  end;

  if (Naa <> '') and (CompareSemVer(Til, Naa) = 0) then
  begin
    Si('Already on Askr ' + Naa + '.');
    { En nøyaktig pin gjør at update aldri flytter seg. Det er riktig,
      men uten forklaring motsier det `askr outdated`, som nettopp sa at
      noe nyere finnes. Si hvorfor, og hva man gjør. }
    if (Target = '') and (Length(Tags) > 0) and
       (CompareSemVer(Tags[High(Tags)], Naa) > 0) then
    begin
      Si('');
      Si('Askr ' + Tags[High(Tags)] + ' is published, but askr.toml pins ' +
         P.AskrWantedVersion + ',');
      Si('which only allows ' + Naa + '. To move:');
      Si('');
      Si('  askr update ' + Tags[High(Tags)] +
         '        take that release, and update the pin');
      Si('  askr update ^' + Naa +
         '       or widen the pin in askr.toml by hand');
    end;
    Exit;
  end;

  if (Naa <> '') and (CompareSemVer(Til, Naa) < 0) then
    Si('Going back from ' + Naa + ' to ' + Til + '.')
  else if Naa <> '' then
    Si('Askr ' + Naa + ' → ' + Til)
  else
    Si('Installing Askr ' + Til);

  if not Fetch(P.AskrSource, Til, Commit, Feil) then
  begin
    Si('askr: ' + Feil);
    Exit(1);
  end;

  { Notatene skrives ut FØR noe er endret i prosjektet. En oppgradering
    man ikke har lest er en oppgradering man feilsoker etterpå. }
  if Naa <> '' then
  begin
    Notater := UpgradeNotes(CacheDirFor(Til), Naa, Til);
    if Notater <> '' then
    begin
      Si('');
      Si('--- what changes between ' + Naa + ' and ' + Til +
         ' --------------------');
      Si('');
      Si(Notater);
      Si('');
      Si('------------------------------------------------------------');
    end;
  end;

  { Pinnen i askr.toml må følge med, ellers sier fila og lockfila to
    forskjellige ting, og neste `askr install` drar deg tilbake. }
  if (Target <> '') and (P.AskrWantedVersion <> Til) then
    SettPinnetVersjon(P, Til);

  L.Version := Til;
  L.Commit := Commit;
  L.Lauf := TreeLaufVersion(CacheDirFor(Til));
  if L.Lauf = '' then
    L.Lauf := Til;
  WriteLock(P.Root, L);

  Result := CmdInstall(P);
  if Result = 0 then
  begin
    Si('');
    Si('A framework release can add columns to the tables Askr owns.');
    Si('Run this once the build is green:');
    Si('  askr migrate');
  end;
end;

function CmdOutdated(P: TProject): Integer;
var
  L: TLock;
  Tags: TStringArray;
  Naa: string;
  I: Integer;
  Nyeste: string;
begin
  Result := 0;
  L := ReadLock(P.Root);
  Naa := L.Version;
  if Naa = '' then
    Naa := P.AskrWantedVersion;

  if P.AskrPath <> '' then
    Si('local path  ' + P.AskrPath + '  (Askr ' + TreeVersion(P.AskrPath) + ')')
  else if Naa = '' then
    Si('this project does not pin a version')
  else
    Si('installed   ' + Naa);

  Tags := RemoteVersions(P.AskrSource);
  if Length(Tags) = 0 then
  begin
    Si('published   (none found — no tags, or no network)');
    Exit;
  end;

  Nyeste := Tags[High(Tags)];
  Si('latest      ' + Nyeste);
  Si('');
  Si('published releases:');
  for I := High(Tags) downto 0 do
    if Tags[I] = Naa then
      Si('  ' + Tags[I] + '   <- this project')
    else
      Si('  ' + Tags[I]);

  if (Naa <> '') and (CompareSemVer(Nyeste, Naa) > 0) then
  begin
    Si('');
    Si('Askr ' + Nyeste + ' is available. Read what changes, then take it:');
    Si('  askr update');
  end;
end;

function DelegateIfNeeded(P: TProject; out ExitKode: Integer): Boolean;
var
  Dir, Feil, Binaer, Skall, Bygglogg: string;
  O: TPkgOrigin;
  Args: array of string;
  I: Integer;
begin
  Result := False;
  ExitKode := 0;

  { Uten denne ville den delegerte prosessen delegert videre i ring. }
  if GetEnvironmentVariable('ASKR_DELEGATED') = '1' then
    Exit;

  Dir := ResolveFramework(P, O, Feil);
  if (Dir = '') or (TreeVersion(Dir) = AskrVersion) then
    Exit;

  { En lokal sti er rammeverksutvikling. Da er det med vilje at man
    kjører verktøyet man selv har bygget, og delegering ville gjort det
    umulig å teste en endring i CLI-en. }
  if O = poPath then
    Exit;

  Binaer := IncludeTrailingPathDelimiter(Dir) + '.build/bin/askr';
  if not FileExists(Binaer) then
  begin
    Skall := IncludeTrailingPathDelimiter(Dir) + 'askr';
    if not FileExists(Skall) then
      Exit;   { ingen måte å bygge den på — la det gamle verktøyet prøve }
    Si('Building the askr ' + TreeVersion(Dir) + ' tool once...');
    { Fanges i stedet for å slippes ut. Byggskriptet i rammeverket er et
      arbeidsverktøy og skriver norsk; det skal ikke havne foran en som
      bare ville kjøre askr build. Ved feil vises alt, for da er det
      nettopp utdataene man trenger. }
    if (RunCapture('/bin/sh', [Skall, 'cli'], Dir, Bygglogg) <> 0) or
       not FileExists(Binaer) then
    begin
      Si(Bygglogg);
      Si('askr: could not build the tool for Askr ' + TreeVersion(Dir) + '.');
      Si('      continuing with askr ' + AskrVersion + ' — if the build');
      Si('      fails on a unit it cannot find, this is why.');
      Exit;
    end;
  end;

  SetLength(Args, 0);
  for I := 1 to ParamCount do
  begin
    SetLength(Args, Length(Args) + 1);
    Args[High(Args)] := ParamStr(I);
  end;
  { Miljøvariabelen settes i barnet gjennom env, fordi FPCs RTL holder
    sin egen kopi av miljøet fra oppstart og setenv ikke når fram. }
  SetLength(Args, Length(Args) + 2);
  for I := High(Args) downto 2 do
    Args[I] := Args[I - 2];
  Args[0] := 'ASKR_DELEGATED=1';
  Args[1] := Binaer;

  ExitKode := RunThrough('/usr/bin/env', Args, GetCurrentDir);
  Result := True;
end;

function CmdVersionInfo(P: TProject): Integer;
var
  Dir, Feil: string;
  O: TPkgOrigin;
  L: TLock;
begin
  Result := 0;
  Si('askr ' + AskrVersion + '   (the tool)');
  if P = nil then
    Exit;

  Dir := ResolveFramework(P, O, Feil);
  Si('');
  if Dir = '' then
  begin
    Si('framework   not resolved');
    Si('');
    Si(Feil);
    Exit(1);
  end;

  Si('framework   ' + TreeVersion(Dir));
  if O = poPath then
    Si('  from      ' + Dir + '   (local path, from askr.toml)')
  else
    Si('  from      ' + Dir);
  Si('  lauf      ' + TreeLaufVersion(Dir));

  L := ReadLock(P.Root);
  if L.Found then
    Si('  locked    ' + L.Version + ' ' + Copy(L.Commit, 1, 12))
  else
    Si('  locked    (no askr.lock)');

  { Den ene sjekken som fanger driften mellom de to økosystemene. }
  if (TreeLaufVersion(Dir) <> '') and
     (TreeVersion(Dir) <> '') and
     (TreeLaufVersion(Dir) <> TreeVersion(Dir)) then
  begin
    Si('');
    Si('warning: the framework says ' + TreeVersion(Dir) +
       ' but its Lauf package says ' + TreeLaufVersion(Dir) + '.');
    Si('         one release is supposed to be one number.');
  end;
end;

end.
