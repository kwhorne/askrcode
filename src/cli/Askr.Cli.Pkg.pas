{ Askr.Cli.Pkg — versions, cache and lock.

  A project pins a framework version in askr.toml and the exact commit in
  askr.lock. The source is fetched to ~/.askr/pkg/askrcode@<version> and
  shared between all projects on the machine. A whole version is 2.2 MB of
  source that compiles in a second and a half, so no binaries are
  distributed: .ppu files are moreover tied to an exact FPC version and
  must not be shared between projects at all.

  A release spans TWO ecosystems — the Pascal source and @askrcode/lauf on
  npm — and that is the real reason this needs a lock. If they drift apart
  you get a DataGrid.svelte that does not fit Askr.Urd.Grid on the server,
  and nothing says so until a column stops sorting. So the lock file owns
  both, and `askr install` writes the npm version into
  frontend/package.json.

  `path` in askr.toml overrides everything. That is for whoever is
  developing the framework itself, and is the same role as `replace` in
  go.mod. }
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

  { Where the framework came from. Used in output, so that "askr version"
    can say whether you are running a pinned version or a local checkout —
    the difference explains nearly every "but it worked yesterday". }
  TPkgOrigin = (poNone, poPath, poCache);

{ ~/.askr/pkg, or ASKR_CACHE when it is set — CI wants it somewhere it
  can cache.

  NOT ASKR_HOME. That already means the framework's checkout, and the build
  script tells people to set it there. If the cache read the same variable,
  everybody who followed the instruction would have had the packages
  written into their own checkout. }
function CacheRoot: string;
function CacheDirFor(const Version: string): string;

function LockPath(const Root: string): string;
function ReadLock(const Root: string): TLock;
procedure WriteLock(const Root: string; const L: TLock);

{ The version a tree actually is, read out of the source — not out of the
  name of the directory. A cache directory can be half finished after an
  aborted download, and then it must not count as installed. }
function TreeVersion(const Dir: string): string;
function TreeLaufVersion(const Dir: string): string;
function TreeIsComplete(const Dir: string): Boolean;

{ The path the framework is to be built from. An empty string when it
  cannot be resolved; Err then says what is missing and what to do. }
function ResolveFramework(P: TProject; out Origin: TPkgOrigin;
  out Err: string): string;

function InstalledVersions: TStringArray;
function RemoteVersions(const Source: string): TStringArray;

function Fetch(const Source, Version: string; out Commit, Err: string): Boolean;

function CmdInstall(P: TProject): Integer;
function CmdUpdate(P: TProject; const Target: string): Integer;
function CmdOutdated(P: TProject): Integer;
{ Runs the command with the CLI that belongs to the pinned version, when
  that is not this one. Returns False when nothing was delegated.

  This is not decoration. The list of unit directories (AskrUnits) is
  compiled into the tool, so a 0.6.0 tool building against 0.7.0 would not
  put a new directory on the search path — and the error would have been
  "unit not found", which points somewhere entirely different from the
  cause. The same role as bundle exec and ./gradlew. }
function DelegateIfNeeded(P: TProject; out ExitCode: Integer): Boolean;

function CmdVersionInfo(P: TProject): Integer;

implementation

{ ----------------------------------------------------------- utskrift -- }

procedure Si(const S: string);
begin
  WriteLn(S);
  Flush(Output);
end;

{ ------------------------------------------------------------ prosess -- }

{ Runs and captures stdout. Git writes progress to stderr, which is
  allowed through to the terminal — a download that looks like nothing is
  worse than noise. }
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

{ Runs with the output going straight to the terminal. For git clone and
  npm install, where the user is meant to see what happens. }
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

function HasGit: Boolean;
var
  Ut: string;
begin
  Result := RunCapture('/usr/bin/env', ['git', '--version'], '', Ut) = 0;
end;

{ The commit a tree actually stands on. Without this the lock file was
  meaningless: CmdInstall fell back to L.Commit when the cache was already
  full, and so compared the value with itself. A tampered lock went straight
  through and was printed as though it were genuine. }
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
    { The same TOML parser askr.toml and the app use. Two parsers for the
      same format are two ways of reading the same file wrong. }
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

{ Reads the constant out of the source. The directory name is not proof:
  an aborted download leaves a directory with the right name containing half
  the framework. }
function TreeVersion(const Dir: string): string;
var
  F: TStringList;
  I, A, B: Integer;
  S: string;
  Path_: string;
begin
  Result := '';
  Path_ := IncludeTrailingPathDelimiter(Dir) + 'src/core/Askr.Core.Version.pas';
  if not FileExists(Path_) then
    Exit;
  F := TStringList.Create;
  try
    F.LoadFromFile(Path_);
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
  S, Path_: string;
begin
  Result := '';
  Path_ := IncludeTrailingPathDelimiter(Dir) + 'frontend/lauf/package.json';
  if not FileExists(Path_) then
    Exit;
  F := TStringList.Create;
  try
    F.LoadFromFile(Path_);
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

{ --------------------------------------------------------- resolving -- }

function ResolveFramework(P: TProject; out Origin: TPkgOrigin;
  out Err: string): string;
var
  L: TLock;
  Dir, Wanted: string;
begin
  Result := '';
  Err := '';
  Origin := poNone;

  { 1. An explicit path always wins. Whoever is developing the framework
    must not have to cut a release to test a change. }
  Dir := P.AskrPath;
  if Dir <> '' then
  begin
    if not TreeIsComplete(Dir) then
    begin
      Err := 'askr.toml points at ' + Dir + ' but that is not an Askr' +
              ' checkout (no src/core/Askr.Core.Version.pas).';
      Exit;
    end;
    Origin := poPath;
    Exit(Dir);
  end;

  { 2. Otherwise the locked version from the cache. }
  L := ReadLock(P.Root);
  Wanted := L.Version;
  if Wanted = '' then
    Wanted := P.AskrWantedVersion;
  if Wanted = '' then
  begin
    Err := 'this project does not say which Askr version it needs.' + LineEnding +
            LineEnding +
            '  add it to askr.toml:' + LineEnding +
            LineEnding +
            '    [askr]' + LineEnding +
            '    version = "' + AskrVersion + '"' + LineEnding +
            LineEnding +
            '  then run: askr install';
    Exit;
  end;

  Dir := CacheDirFor(Wanted);
  if not TreeIsComplete(Dir) then
  begin
    Err := 'Askr ' + Wanted + ' is not installed.' + LineEnding +
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
  Root, V: string;
  N: Integer;
  Items: TStringArray;
begin
  { Built locally and assigned at the end. SetLength straight on Result
    gives "function result variable of a managed type does not seem to be
    initialized", and the suites here are warning free. }
  Items := nil;
  SetLength(Items, 0);
  Result := Items;
  Root := IncludeTrailingPathDelimiter(CacheRoot);
  if not DirectoryExists(Root) then
    Exit;
  N := 0;
  if FindFirst(Root + 'askrcode@*', faDirectory, R) = 0 then
  try
    repeat
      if (R.Name = '.') or (R.Name = '..') then
        Continue;
      V := TreeVersion(Root + R.Name);
      if V = '' then
        Continue;
      SetLength(Items, N + 1);
      Items[N] := V;
      Inc(N);
    until FindNext(R) <> 0;
  finally
    FindClose(R);
  end;
  Result := Items;
end;

{ The tags on the remote, newest last. Requires a network; an empty list
  means either no tags or no connection, and the caller tells them apart
  using the return value from git. }
function RemoteVersions(const Source: string): TStringArray;
var
  Ut, Line_, Tag: string;
  L: TStringList;
  I, P2, N: Integer;
  Tmp: string;
  J, K: Integer;
  Items: TStringArray;
begin
  Items := nil;
  SetLength(Items, 0);
  Result := Items;
  if RunCapture('/usr/bin/env', ['git', 'ls-remote', '--tags', '--refs',
                                 Source], '', Ut) <> 0 then
    Exit;
  L := TStringList.Create;
  try
    L.Text := Ut;
    N := 0;
    for I := 0 to L.Count - 1 do
    begin
      Line_ := L[I];
      P2 := Pos('refs/tags/', Line_);
      if P2 = 0 then
        Continue;
      Tag := Trim(Copy(Line_, P2 + Length('refs/tags/'), Length(Line_)));
      if not ParseSemVer(Tag).Valid then
        Continue;
      SetLength(Items, N + 1);
      { The 'v' is removed here, so that the rest of the code never has to
        know whether a version came from a tag or from askr.toml. }
      if (Tag <> '') and ((Tag[1] = 'v') or (Tag[1] = 'V')) then
        Items[N] := Copy(Tag, 2, Length(Tag))
      else
        Items[N] := Tag;
      Inc(N);
    end;
  finally
    L.Free;
  end;

  { Insertion sort. The list is short, and pulling in a generic sort for
    ten tags is the wrong trade. }
  for J := 1 to High(Items) do
  begin
    Tmp := Items[J];
    K := J - 1;
    while (K >= 0) and (CompareSemVer(Items[K], Tmp) > 0) do
    begin
      Items[K + 1] := Items[K];
      Dec(K);
    end;
    Items[K + 1] := Tmp;
  end;
  Result := Items;
end;

{ ------------------------------------------------------------- henting -- }

function Fetch(const Source, Version: string; out Commit, Err: string): Boolean;
var
  Target, Tmp, Ut, Fant, CloneLog: string;
begin
  Result := False;
  Commit := '';
  Err := '';

  if not HasGit then
  begin
    Err := 'git was not found on PATH. askr install fetches the' +
            ' framework with git.';
    Exit;
  end;

  Target := CacheDirFor(Version);
  if TreeIsComplete(Target) then
  begin
    { Allerede der. Commit-en leses ut av utsjekkingen. }
    RunCapture('/usr/bin/env', ['git', 'rev-parse', 'HEAD'], Target, Ut);
    Commit := Trim(Ut);
    Exit(True);
  end;

  ForceDirectories(CacheRoot);
  { Fetched into a temporary directory and moved into place at the end. An
    aborted download must not leave behind something that looks
    installed. }
  Tmp := Target + '.tmp';
  if DirectoryExists(Tmp) then
    RunCapture('/usr/bin/env', ['rm', '-rf', Tmp], '', Ut);

  Si('  fetching Askr ' + Version + ' from ' + Source);
  { Caught rather than let out. An annotated tag makes git write
    "refs/tags/v0.6.0 <sha> is not a commit!" under --depth 1: the tag
    object has its own sha, and the clone is right anyway — the commit is
    read out of the checkout afterwards. The warning says nothing a user can
    act on. If the clone fails, everything is shown, because then the output
    is precisely what you need. }
  if RunCapture('/usr/bin/env',
       ['git', '-c', 'advice.detachedHead=false', 'clone', '--depth', '1',
        '--branch', 'v' + Version, '--quiet', Source, Tmp], '', CloneLog) <> 0 then
  begin
    Si(CloneLog);
    RunCapture('/usr/bin/env', ['rm', '-rf', Tmp], '', Ut);
    Err := 'could not fetch v' + Version + ' from ' + Source + '.' +
            LineEnding + LineEnding +
            '  the tag may not exist. see what is published with:' +
            LineEnding + '    askr outdated';
    Exit;
  end;

  { The tree has to say that it IS the version we asked for. A tag that
    points at the wrong code is exactly the bug nobody notices until it is
    in production. }
  Fant := TreeVersion(Tmp);
  if Fant <> Version then
  begin
    RunCapture('/usr/bin/env', ['rm', '-rf', Tmp], '', Ut);
    if Fant = '' then
      Err := 'the tag v' + Version + ' does not look like an Askr' +
              ' checkout: src/core/Askr.Core.Version.pas is missing.'
    else
      Err := 'the tag v' + Version + ' contains Askr ' + Fant +
              '. Refusing to install it under the wrong name.';
    Exit;
  end;

  RunCapture('/usr/bin/env', ['git', 'rev-parse', 'HEAD'], Tmp, Ut);
  Commit := Trim(Ut);

  if not RenameFile(Tmp, Target) then
  begin
    RunCapture('/usr/bin/env', ['rm', '-rf', Tmp], '', Ut);
    Err := 'could not move the download into ' + Target;
    Exit;
  end;
  Result := True;
end;

{ Points frontend/.askr/lauf at the installed release.

  Without it package.json has to carry an absolute path into YOUR cache, and
  then the file gives a diff that changes per machine. The symlink is
  gitignored and made by install, so the committed path is
  `file:./.askr/lauf` and the same everywhere.

  Returns the path that is to go in package.json. If the symlink cannot be
  made — a file system without them, or Windows — it falls back to the
  absolute path, which works just as well locally. }
function LaufPath(P: TProject; const Dir: string): string;
var
  Folder, Link_, Target: string;
begin
  Target := IncludeTrailingPathDelimiter(Dir) + 'frontend/lauf';
  Result := 'file:' + Target;
  if P.FrontendDir = '' then
    Exit;

  Folder := IncludeTrailingPathDelimiter(P.FrontendDir) + '.askr';
  Link_ := IncludeTrailingPathDelimiter(Folder) + 'lauf';
  if not ForceDirectories(Folder) then
    Exit;

{$IFDEF UNIX}
  { An old link can point at the previous version. fpUnlink does not mind
    that it does not exist. }
  fpUnlink(PChar(Link_));
  if fpSymlink(PChar(Target), PChar(Link_)) = 0 then
    Result := 'file:./.askr/lauf';
{$ENDIF}
end;

{ -------------------------------------------------- Lauf i takt med -- }

{ Writes the @askrcode/lauf version into frontend/package.json.

  Only the value itself is swapped. The first version took Pos(':', Line_) —
  the FIRST colon on the line — and on a compact package.json that one
  belongs to "dependencies", not to "@askrcode/lauf". The result was that
  the whole dependencies object was replaced by a single string:
  @inertiajs/svelte disappeared, and the JSON became invalid. It therefore
  overwrote a file the user owns, without saying so.

  Now the colon is found after the key, and only the quoted value after it
  is replaced. If the line does not look as expected, nothing is guessed:
  the function says what it should say. The same rule as InstallRoutes in
  the scaffolding. }
function SetLaufDependency(P: TProject; const LaufSpec: string;
  out Changed: Boolean): Boolean;
const
  Key_ = '"@askrcode/lauf"';
var
  Path_, S, Ny: string;
  F: TStringList;
  I, PN, A, V1, V2: Integer;
begin
  Changed := False;
  { FrontendDir is already absolute. Putting Root in front gave a path
    that never existed, and then this function did nothing and reported
    success. }
  if P.FrontendDir = '' then
    Exit(True);   { prosjektet har ingen frontend }
  Path_ := IncludeTrailingPathDelimiter(P.FrontendDir) + 'package.json';
  if not FileExists(Path_) then
  begin
    Si('  no package.json in ' + P.FrontendDir + ' -- skipping the Lauf pin.');
    Exit(True);
  end;

  F := TStringList.Create;
  try
    F.LoadFromFile(Path_);
    for I := 0 to F.Count - 1 do
    begin
      S := F[I];
      PN := Pos(Key_, S);
      if PN = 0 then
        Continue;

      { The colon that belongs to the KEY, not the first one on the line. }
      A := Pos(':', S, PN + Length(Key_));
      if A = 0 then
        Break;

      (* The value has to be a quoted string, and that has to be checked
         on the FIRST character after the colon. Looking only for the next
         quote reached into an object: a value that is itself an object
         with a version field was then overwritten instead of rejected. *)
      V1 := A + 1;
      while (V1 <= Length(S)) and (S[V1] in [' ', #9]) do
        Inc(V1);
      if (V1 > Length(S)) or (S[V1] <> '"') then
        Break;
      V2 := Pos('"', S, V1 + 1);
      if V2 = 0 then
        Break;

      { The quotes are kept: LaufSpec is the value without them. }
      Ny := Copy(S, 1, V1) + LaufSpec + Copy(S, V2, Length(S));
      if Ny <> S then
      begin
        F[I] := Ny;
        F.SaveToFile(Path_);
        Changed := True;
      end;
      Exit(True);
    end;
  finally
    F.Free;
  end;

  Si('  could not find ' + Key_ + ' in ' + Path_);
  Si('  add this to its "dependencies" yourself:');
  Si('');
  Si('    ' + Key_ + ': ' + LaufSpec);
  Si('');
  Result := False;
end;

{ Sets [askr] version in askr.toml. If it does not find the line, it does
  not guess — it says what should be there. The same rule as InstallRoutes
  in the scaffolding. }
function SetPinnedVersion(P: TProject; const VersionStr: string): Boolean;
var
  F: TStringList;
  I, A: Integer;
  S2, Path_: string;
  InSection: Boolean;
begin
  Result := False;
  Path_ := IncludeTrailingPathDelimiter(P.Root) + 'askr.toml';
  F := TStringList.Create;
  try
    F.LoadFromFile(Path_);
    InSection := False;
    for I := 0 to F.Count - 1 do
    begin
      S2 := Trim(F[I]);
      if (S2 <> '') and (S2[1] = '[') then
      begin
        InSection := LowerCase(S2) = '[askr]';
        Continue;
      end;
      if not InSection then
        Continue;
      if Pos('version', S2) <> 1 then
        Continue;
      A := Pos('=', F[I]);
      if A = 0 then
        Continue;
      F[I] := Copy(F[I], 1, A) + ' "' + VersionStr + '"';
      F.SaveToFile(Path_);
      Exit(True);
    end;
  finally
    F.Free;
  end;

  Si('  could not find `version` under [askr] in askr.toml.');
  Si('  set it yourself, so the pin and the lock agree:');
  Si('');
  Si('    [askr]');
  Si('    version = "' + VersionStr + '"');
  Si('');
end;

{ --------------------------------------------- oppgraderingsnotater -- }

{ Fetches the sections in UPGRADE.md that cover the stretch From_..To_.

  The format is one H2 per version: `## 0.7.0`. Everything between a heading
  and the next belongs to that version. }
function UpgradeNotes(const Dir, From_, To_: string): string;
var
  F: TStringList;
  I: Integer;
  S, V, Ut: string;
  With_: Boolean;
begin
  Result := '';
  if not FileExists(IncludeTrailingPathDelimiter(Dir) + 'UPGRADE.md') then
    Exit;
  F := TStringList.Create;
  try
    F.LoadFromFile(IncludeTrailingPathDelimiter(Dir) + 'UPGRADE.md');
    With_ := False;
    Ut := '';
    for I := 0 to F.Count - 1 do
    begin
      S := F[I];
      if Pos('## ', S) = 1 then
      begin
        V := Trim(Copy(S, 4, Length(S)));
        { Included when the version is newer than the one we are on, and not
          newer than the one we are going to. }
        With_ := ParseSemVer(V).Valid and
               (CompareSemVer(V, From_) > 0) and
               (CompareSemVer(V, To_) <= 0);
      end;
      if With_ then
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
  Wanted, Dir, Commit, Err, Lauf: string;
  Changed: Boolean;
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
  Wanted := L.Version;
  if Wanted = '' then
    Wanted := P.AskrWantedVersion;
  if Wanted = '' then
  begin
    Si('askr.toml does not say which version to install.');
    Si('');
    Si('  [askr]');
    Si('  version = "' + AskrVersion + '"');
    Exit(1);
  end;

  Dir := CacheDirFor(Wanted);
  if TreeIsComplete(Dir) then
  begin
    Si('Askr ' + Wanted + ' is already installed.');
    { Read out of the checkout, not out of the lock file. That is the whole
      point of the check below. }
    Commit := CommitOf(Dir);
  end
  else if not Fetch(P.AskrSource, Wanted, Commit, Err) then
  begin
    Si('askr: ' + Err);
    Exit(1);
  end;

  { The locked commit and what is actually in the cache have to match. If
    they do not, either the tag has moved or the cache has been touched —
    both are to be reported, not overwritten in silence. }
  if (L.Found) and (L.Commit <> '') and (Commit <> '') and
     (L.Commit <> Commit) then
  begin
    Si('askr: askr.lock pins commit ' + Copy(L.Commit, 1, 12) + ' for ' +
       Wanted + ',');
    Si('      but the copy in the cache is ' + Copy(Commit, 1, 12) + '.');
    Si('');
    Si('  the tag may have been moved. remove the cached copy to refetch:');
    Si('    rm -rf ' + Dir);
    Exit(1);
  end;

  Lauf := TreeLaufVersion(Dir);
  if Lauf = '' then
    Lauf := Wanted;

  { Lauf is not published on npm yet, so the dependency points into the
    version we just installed. When the package is published, this becomes
    the version number and nothing else changes. }
  if not SetLaufDependency(P, LaufPath(P, Dir), Changed) then
    Result := 1;

  L.Version := Wanted;
  L.Commit := Commit;
  L.Lauf := Lauf;
  WriteLock(P.Root, L);

  Si('');
  Si('Askr ' + Wanted + '  (' + Copy(Commit, 1, 12) + ')');
  Si('  framework  ' + Dir);
  Si('  lauf       ' + Lauf);
  Si('  lock       ' + LockPath(P.Root));
  if Changed then
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
  Now_, To_, Notes, Commit, Err: string;
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
  Now_ := L.Version;
  if Now_ = '' then
    Now_ := P.AskrWantedVersion;

  Tags := nil;
  if Target <> '' then
    To_ := Target
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
    { askr.toml can limit how far update may go, with the same notation as
      package.json: ^0.6.0 or ~0.6.0. }
    Spec := P.AskrWantedVersion;
    To_ := '';
    for I := High(Tags) downto 0 do
      if (Spec = '') or SatisfiesRange(Tags[I], Spec) then
      begin
        To_ := Tags[I];
        Break;
      end;
    if To_ = '' then
    begin
      Si('askr: nothing published matches ' + Spec);
      Exit(1);
    end;
  end;

  if (Now_ <> '') and (CompareSemVer(To_, Now_) = 0) then
  begin
    Si('Already on Askr ' + Now_ + '.');
    { An exact pin means update never moves. That is right, but without an
      explanation it contradicts `askr outdated`, which has just said that
      something newer exists. Say why, and what to do. }
    if (Target = '') and (Length(Tags) > 0) and
       (CompareSemVer(Tags[High(Tags)], Now_) > 0) then
    begin
      Si('');
      Si('Askr ' + Tags[High(Tags)] + ' is published, but askr.toml pins ' +
         P.AskrWantedVersion + ',');
      Si('which only allows ' + Now_ + '. To move:');
      Si('');
      Si('  askr update ' + Tags[High(Tags)] +
         '        take that release, and update the pin');
      Si('  askr update ^' + Now_ +
         '       or widen the pin in askr.toml by hand');
    end;
    Exit;
  end;

  if (Now_ <> '') and (CompareSemVer(To_, Now_) < 0) then
    Si('Going back from ' + Now_ + ' to ' + To_ + '.')
  else if Now_ <> '' then
    Si('Askr ' + Now_ + ' → ' + To_)
  else
    Si('Installing Askr ' + To_);

  if not Fetch(P.AskrSource, To_, Commit, Err) then
  begin
    Si('askr: ' + Err);
    Exit(1);
  end;

  { The notes are printed BEFORE anything in the project is changed. An
    upgrade you have not read is an upgrade you debug afterwards. }
  if Now_ <> '' then
  begin
    Notes := UpgradeNotes(CacheDirFor(To_), Now_, To_);
    if Notes <> '' then
    begin
      Si('');
      Si('--- what changes between ' + Now_ + ' and ' + To_ +
         ' --------------------');
      Si('');
      Si(Notes);
      Si('');
      Si('------------------------------------------------------------');
    end;
  end;

  { The pin in askr.toml has to come along, or the file and the lock file
    say two different things, and the next `askr install` drags you
    back. }
  if (Target <> '') and (P.AskrWantedVersion <> To_) then
    SetPinnedVersion(P, To_);

  L.Version := To_;
  L.Commit := Commit;
  L.Lauf := TreeLaufVersion(CacheDirFor(To_));
  if L.Lauf = '' then
    L.Lauf := To_;
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
  Now_: string;
  I: Integer;
  Newest: string;
begin
  Result := 0;
  L := ReadLock(P.Root);
  Now_ := L.Version;
  if Now_ = '' then
    Now_ := P.AskrWantedVersion;

  if P.AskrPath <> '' then
    Si('local path  ' + P.AskrPath + '  (Askr ' + TreeVersion(P.AskrPath) + ')')
  else if Now_ = '' then
    Si('this project does not pin a version')
  else
    Si('installed   ' + Now_);

  Tags := RemoteVersions(P.AskrSource);
  if Length(Tags) = 0 then
  begin
    Si('published   (none found — no tags, or no network)');
    Exit;
  end;

  Newest := Tags[High(Tags)];
  Si('latest      ' + Newest);
  Si('');
  Si('published releases:');
  for I := High(Tags) downto 0 do
    if Tags[I] = Now_ then
      Si('  ' + Tags[I] + '   <- this project')
    else
      Si('  ' + Tags[I]);

  if (Now_ <> '') and (CompareSemVer(Newest, Now_) > 0) then
  begin
    Si('');
    Si('Askr ' + Newest + ' is available. Read what changes, then take it:');
    Si('  askr update');
  end;
end;

function DelegateIfNeeded(P: TProject; out ExitCode: Integer): Boolean;
var
  Dir, Err, Binary_, ShellScript, BuildLog: string;
  O: TPkgOrigin;
  Args: array of string;
  I: Integer;
begin
  Result := False;
  ExitCode := 0;

  { Without this the delegated process would have delegated onwards in a
    ring. }
  if GetEnvironmentVariable('ASKR_DELEGATED') = '1' then
    Exit;

  Dir := ResolveFramework(P, O, Err);
  if (Dir = '') or (TreeVersion(Dir) = AskrVersion) then
    Exit;

  { A local path is framework development. Then running the tool you have
    built yourself is the point, and delegation would have made it
    impossible to test a change in the CLI. }
  if O = poPath then
    Exit;

  Binary_ := IncludeTrailingPathDelimiter(Dir) + '.build/bin/askr';
  if not FileExists(Binary_) then
  begin
    ShellScript := IncludeTrailingPathDelimiter(Dir) + 'askr';
    if not FileExists(ShellScript) then
      Exit;   { no way to build it — let the old tool have a go }
    Si('Building the askr ' + TreeVersion(Dir) + ' tool once...');
    { Caught rather than let out. The build script in the framework is a
      working tool and writes Norwegian; it must not land in front of
      somebody who only wanted to run askr build. On an error everything is
      shown, because then the output is precisely what you need. }
    if (RunCapture('/bin/sh', [ShellScript, 'cli'], Dir, BuildLog) <> 0) or
       not FileExists(Binary_) then
    begin
      Si(BuildLog);
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
  { The environment variable is set in the child through env, because FPC's
    RTL keeps its own copy of the environment from start-up and setenv does
    not reach it. }
  SetLength(Args, Length(Args) + 2);
  for I := High(Args) downto 2 do
    Args[I] := Args[I - 2];
  Args[0] := 'ASKR_DELEGATED=1';
  Args[1] := Binary_;

  ExitCode := RunThrough('/usr/bin/env', Args, GetCurrentDir);
  Result := True;
end;

function CmdVersionInfo(P: TProject): Integer;
var
  Dir, Err: string;
  O: TPkgOrigin;
  L: TLock;
begin
  Result := 0;
  Si('askr ' + AskrVersion + '   (the tool)');
  if P = nil then
    Exit;

  Dir := ResolveFramework(P, O, Err);
  Si('');
  if Dir = '' then
  begin
    Si('framework   not resolved');
    Si('');
    Si(Err);
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

  { The one check that catches the drift between the two ecosystems. }
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
