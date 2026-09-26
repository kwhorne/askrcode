{ Askr.Cli.Plugins — plugins: fetched from git, pinned, compiled in.

      [plugins.stripe]
      git = "https://github.com/kwhorne/askr-stripe.git"
      version = "^0.1.0"

  A plugin is source, like the framework. Pascal compiles into one binary
  and .ppu files are bound to one compiler version, so nothing is loaded at
  run time: a plugin is fetched to ~/.askr/pkg/plugins/<name>@<version>,
  its commit goes in askr.lock, and its units go on the search path of
  every build.

  **A plugin says what it is in askr-plugin.toml**, at the root of its
  repository: its name, its version, the Askr versions it builds against,
  where its units are, the unit that registers it, and the configuration
  prefix and tables it owns. Two plugins that claim the same prefix or the
  same table stop the build, naming both.

  **App.Plugins is written on every build**, into .build/plugins, and
  "uses" each plugin's entry unit and its migrations. A unit nothing refers
  to is never linked, and its initialization never runs -- the same trap
  the migrations index exists for, with the same answer.

  **Git only.** The version lives in the tag, and the lock holds the
  commit; a registry would be a second place to disagree with the first.

  **There is no sandbox.** A plugin is compiled into the binary and can do
  whatever the app can. The commit in askr.lock is the whole of the trust
  model: install refuses a cached copy that stands on another commit. }
unit Askr.Cli.Plugins;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, Askr.Core.Config, Askr.Core.Version,
  Askr.Cli.Project, Askr.Cli.Pkg;

const
  ManifestFile = 'askr-plugin.toml';

type
  TPluginManifest = record
    Name: string;
    Version: string;
    { The Askr versions it builds against, as a range: ^0.16.0. }
    AskrRange: string;
    { The unit that registers the plugin. }
    Entry: string;
    { Unit directories, relative to Dir. }
    Units: TStringArray;
    { The directory of its migrations, relative to Dir, or ''. }
    Migrations: string;
    Docs: string;
    { The configuration prefix it owns: stripe owns stripe.*. }
    Config: string;
    Tables: TStringArray;
    { Where it is, absolute. }
    Dir: string;
  end;
  TPluginManifests = array of TPluginManifest;

{ A name is lower case letters, digits and dashes, starting with a letter:
  it is a TOML section, a directory and a migration prefix. }
function ValidPluginName(const Name: string): Boolean;

{ Reads Dir/askr-plugin.toml. False, with Err saying what is wrong, when it
  is missing or does not say what it has to. }
function ReadManifest(const Dir: string; out M: TPluginManifest;
  out Err: string): Boolean;

function PluginCacheDir(const Name, Version: string): string;

{ The plugins askr.toml names, found where the lock or a path says, and
  checked: each is there, is the version the lock pins, builds against
  FrameworkVersion, and claims nothing another one claims. }
function ResolvePlugins(P: TProject; const FrameworkVersion: string;
  out Found: TPluginManifests; out Err: string): Boolean;

{ The text of App.Plugins for these plugins. }
function PluginIndexSource(const Found: TPluginManifests): string;

{ The -Fu flags for the plugins' units and the directory App.Plugins is
  written to, which it writes. '' and Err when a plugin cannot be used. }
function PluginBuildFlags(P: TProject; const FrameworkVersion: string;
  out Err: string): string;

{ askr.toml with a [plugins.<name>] section appended, and without one.
  Nothing else in the file is touched: it carries comments and an order a
  parse-and-rewrite would lose. Found is False, and the text unchanged,
  when the section is not there as askr wrote it. }
function AddPluginSection(const Toml, Name, Git, Version: string): string;
function RemovePluginSection(const Toml, Name: string; out Found: Boolean): string;

{ Does app.lpr start the plugins: App.Plugins in its uses, so they are
  linked, and UsePlugins(R), so they run. }
function AppLprStartsPlugins(const Text: string): Boolean;

{ app.lpr with what it lacks of the two added, at the lines askr new
  writes: the uses before App.Migrations, the call after UseAuth(R). Every
  place is found before anything is changed; a file someone reshaped is
  left alone, and Err holds the lines to add by hand. }
function WireAppLpr(const Text: string; out Changed: Boolean; out Err: string): string;

{ askr plugin add|remove|list|update. }
function CmdPlugin(P: TProject): Integer;
function PluginAdd(P: TProject; const Git: string): Integer;
function PluginRemove(P: TProject; const Name: string): Integer;
function PluginUpdate(P: TProject; const Only: string): Integer;

var
  { False for a test, which wants the result, not the narration. }
  PluginOutput: Boolean = True;
{ The plugins' part of askr install and askr outdated. }
function InstallPlugins(P: TProject): Integer;
function OutdatedPlugins(P: TProject): Integer;

implementation

uses
  Askr.Core.Crypto;

procedure Say(const S: string);
begin
  if not PluginOutput then
    Exit;
  WriteLn(S);
  Flush(Output);
end;

function ValidPluginName(const Name: string): Boolean;
var
  I: Integer;
begin
  Result := (Name <> '') and (Length(Name) <= 40) and (Name[1] in ['a'..'z']);
  if Result then
    for I := 2 to Length(Name) do
      if not (Name[I] in ['a'..'z', '0'..'9', '-']) then
        Exit(False);
end;

function ValidUnitName(const S: string): Boolean;
var
  I: Integer;
begin
  Result := (S <> '') and (S[1] in ['A'..'Z', 'a'..'z', '_']);
  if Result then
    for I := 2 to Length(S) do
      if not (S[I] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '.']) then
        Exit(False);
end;

{ A path inside the plugin: relative, and not climbing out of it. }
function InsidePath(const S: string): Boolean;
begin
  Result := (S <> '') and (S[1] <> '/') and (Pos('..', S) = 0) and (Pos('\', S) = 0);
end;

function ReadManifest(const Dir: string; out M: TPluginManifest;
  out Err: string): Boolean;
var
  L: TStringList;
  Path_: string;
  I: Integer;
begin
  Result := False;
  Err := '';
  M.Name := '';
  M.Version := '';
  M.AskrRange := '';
  M.Entry := '';
  M.Units := nil;
  M.Migrations := '';
  M.Docs := '';
  M.Config := '';
  M.Tables := nil;
  M.Dir := ExcludeTrailingPathDelimiter(ExpandFileName(Dir));
  Path_ := IncludeTrailingPathDelimiter(M.Dir) + ManifestFile;
  if not FileExists(Path_) then
  begin
    Err := M.Dir + ' is not an Askr plugin: it has no ' + ManifestFile;
    Exit;
  end;
  L := TStringList.Create;
  try
    ParseTomlInto(Path_, L);
    M.Name := L.Values['name'];
    M.Version := L.Values['version'];
    M.AskrRange := L.Values['askr'];
    M.Entry := L.Values['entry'];
    M.Units := SplitList(L.Values['units']);
    if Length(M.Units) = 0 then
      M.Units := SplitList('src');
    M.Migrations := L.Values['migrations'];
    M.Docs := L.Values['docs'];
    M.Config := L.Values['config'];
    if M.Config = '' then
      M.Config := M.Name;
    M.Tables := SplitList(L.Values['tables']);
  finally
    L.Free;
  end;
  if not ValidPluginName(M.Name) then
    Err := ManifestFile + ' in ' + M.Dir + ' has no usable name: lower case ' +
      'letters, digits and dashes, starting with a letter'
  else if not ParseSemVer(M.Version).Valid then
    Err := 'the plugin ' + M.Name + ' has no version in ' + ManifestFile
  else if M.AskrRange = '' then
    Err := 'the plugin ' + M.Name + ' does not say which Askr it builds ' +
      'against: askr = "^' + AskrVersion + '" in ' + ManifestFile
  else if not ValidUnitName(M.Entry) then
    Err := 'the plugin ' + M.Name + ' names no entry unit: entry = "..." in ' +
      ManifestFile
  else if not ValidPluginName(M.Config) then
    Err := 'the plugin ' + M.Name + ' has a configuration prefix that is not ' +
      'a name: ' + M.Config
  else if (M.Migrations <> '') and not InsidePath(M.Migrations) then
    Err := 'the plugin ' + M.Name + ' points its migrations outside itself: ' +
      M.Migrations
  else
    for I := 0 to High(M.Units) do
      if not InsidePath(M.Units[I]) then
      begin
        Err := 'the plugin ' + M.Name + ' points a unit directory outside ' +
          'itself: ' + M.Units[I];
        Break;
      end;
  Result := Err = '';
end;

function PluginCacheDir(const Name, Version: string): string;
begin
  Result := IncludeTrailingPathDelimiter(CacheRoot) + 'plugins' + PathDelim +
    Name + '@' + Version;
end;

{ The copy in the cache, when it is whole and is what its name says. }
function CachedManifest(const Name, Version: string; out M: TPluginManifest): Boolean;
var
  Err: string;
begin
  Result := ReadManifest(PluginCacheDir(Name, Version), M, Err) and
    (M.Name = Name) and (M.Version = Version);
end;

function LockedIndex(const L: TLock; const Name: string): Integer;
begin
  for Result := 0 to High(L.Plugins) do
    if L.Plugins[Result].Name = Name then
      Exit;
  Result := -1;
end;

function ResolvePlugins(P: TProject; const FrameworkVersion: string;
  out Found: TPluginManifests; out Err: string): Boolean;
var
  Names: TStringArray;
  L: TLock;
  I, J, K, N, T: Integer;
  M: TPluginManifest;
  Path_, Git, Spec: string;
begin
  Result := False;
  Found := nil;
  Err := '';
  Names := P.PluginNames;
  if Length(Names) = 0 then
    Exit(True);
  L := ReadLock(P.Root);
  for I := 0 to High(Names) do
  begin
    if not ValidPluginName(Names[I]) then
    begin
      Err := 'askr.toml names a plugin "' + Names[I] + '": a name is lower case ' +
        'letters, digits and dashes, starting with a letter';
      Exit;
    end;
    Path_ := P.PluginSetting(Names[I], 'path');
    if (Path_ = '') and (P.PluginSetting(Names[I], 'git') = '') then
    begin
      Err := 'askr.toml names the plugin ' + Names[I] + ' with neither git nor ' +
        'path. A plugin is a section of its own:' + LineEnding + LineEnding +
        '    [plugins.' + Names[I] + ']' + LineEnding +
        '    git = "https://..."' + LineEnding +
        '    version = "^0.1.0"';
      Exit;
    end;
    if Path_ <> '' then
    begin
      { A local checkout, for whoever is writing the plugin. It wins over
        the lock, like [askr] path. }
      if (Path_[1] <> '/') then
        Path_ := IncludeTrailingPathDelimiter(P.Root) + Path_;
      if not ReadManifest(Path_, M, Err) then
        Exit;
      if M.Name <> Names[I] then
      begin
        Err := 'askr.toml calls the plugin at ' + M.Dir + ' "' + Names[I] +
          '", and it calls itself "' + M.Name + '"';
        Exit;
      end;
    end
    else
    begin
      K := LockedIndex(L, Names[I]);
      Git := P.PluginSetting(Names[I], 'git');
      Spec := P.PluginSetting(Names[I], 'version');
      if K < 0 then
      begin
        Err := 'the plugin ' + Names[I] + ' is in askr.toml and not in ' +
          'askr.lock.' + LineEnding + LineEnding + '  run: askr install';
        Exit;
      end;
      if L.Plugins[K].Git <> Git then
      begin
        Err := 'askr.toml fetches the plugin ' + Names[I] + ' from ' + Git +
          ', and askr.lock from ' + L.Plugins[K].Git + '.' + LineEnding +
          LineEnding + '  run: askr install';
        Exit;
      end;
      if (Spec <> '') and not SatisfiesRange(L.Plugins[K].Version, Spec) then
      begin
        Err := 'askr.toml asks for ' + Names[I] + ' ' + Spec + ', and askr.lock ' +
          'has ' + L.Plugins[K].Version + '.' + LineEnding + LineEnding +
          '  run: askr plugin update ' + Names[I];
        Exit;
      end;
      if not CachedManifest(Names[I], L.Plugins[K].Version, M) then
      begin
        Err := 'the plugin ' + Names[I] + ' ' + L.Plugins[K].Version +
          ' is not installed.' + LineEnding + LineEnding +
          '  looked in  ' + PluginCacheDir(Names[I], L.Plugins[K].Version) +
          LineEnding + LineEnding + '  run: askr install';
        Exit;
      end;
    end;
    if not SatisfiesRange(FrameworkVersion, M.AskrRange) then
    begin
      Err := 'the plugin ' + M.Name + ' ' + M.Version + ' builds against Askr ' +
        M.AskrRange + ', and this project builds against ' + FrameworkVersion + '.';
      Exit;
    end;
    N := Length(Found);
    SetLength(Found, N + 1);
    Found[N] := M;
  end;

  { What one plugin owns, no other may. }
  for I := 0 to High(Found) do
    for J := I + 1 to High(Found) do
    begin
      if Found[I].Config = Found[J].Config then
      begin
        Err := 'the plugins ' + Found[I].Name + ' and ' + Found[J].Name +
          ' both claim the configuration prefix ' + Found[I].Config + '.';
        Exit;
      end;
      for K := 0 to High(Found[I].Tables) do
        for T := 0 to High(Found[J].Tables) do
          if SameText(Found[I].Tables[K], Found[J].Tables[T]) then
          begin
            Err := 'the plugins ' + Found[I].Name + ' and ' + Found[J].Name +
              ' both claim the table ' + Found[I].Tables[K] + '.';
            Exit;
          end;
    end;
  Result := True;
end;

{ The unit names in a plugin's migrations directory, sorted. }
function MigrationUnits(const M: TPluginManifest): TStringArray;
var
  R: TSearchRec;
  L: TStringList;
  I: Integer;
  Dir: string;
begin
  Result := nil;
  if M.Migrations = '' then
    Exit;
  Dir := IncludeTrailingPathDelimiter(IncludeTrailingPathDelimiter(M.Dir) +
    M.Migrations);
  L := TStringList.Create;
  try
    L.Sorted := True;
    if FindFirst(Dir + '*.pas', faAnyFile, R) = 0 then
    begin
      repeat
        if ValidUnitName(ChangeFileExt(R.Name, '')) then
          L.Add(ChangeFileExt(R.Name, ''));
      until FindNext(R) <> 0;
      FindClose(R);
    end;
    SetLength(Result, L.Count);
    for I := 0 to L.Count - 1 do
      Result[I] := L[I];
  finally
    L.Free;
  end;
end;

function PluginIndexSource(const Found: TPluginManifests): string;
var
  Units: TStringList;
  I, J: Integer;
  Migs: TStringArray;
begin
  Units := TStringList.Create;
  try
    for I := 0 to High(Found) do
    begin
      Units.Add(Found[I].Entry);
      Migs := MigrationUnits(Found[I]);
      for J := 0 to High(Migs) do
        if Units.IndexOf(Migs[J]) < 0 then
          Units.Add(Migs[J]);
    end;
    Result := '{ Written by askr from askr.toml and askr.lock, on every build.' + LineEnding +
      '  Do not edit it: the next build writes it again. It "uses" each' + LineEnding +
      '  plugin''s units, because a unit nothing refers to is never linked. }' + LineEnding +
      'unit App.Plugins;' + LineEnding + LineEnding +
      '{$mode Delphi}{$H+}' + LineEnding + LineEnding +
      'interface' + LineEnding + LineEnding;
    if Units.Count > 0 then
    begin
      Result := Result + 'uses' + LineEnding;
      for I := 0 to Units.Count - 1 do
      begin
        Result := Result + '  ' + Units[I];
        if I < Units.Count - 1 then
          Result := Result + ',' + LineEnding
        else
          Result := Result + ';' + LineEnding;
      end;
      Result := Result + LineEnding;
    end;
    Result := Result + 'implementation' + LineEnding + LineEnding + 'end.' + LineEnding;
  finally
    Units.Free;
  end;
end;

function ReadText(const Path_: string): string;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    if FileExists(Path_) then
      L.LoadFromFile(Path_);
    Result := L.Text;
  finally
    L.Free;
  end;
end;

procedure WriteText(const Path_, Text: string);
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Text := Text;
    L.SaveToFile(Path_);
  finally
    L.Free;
  end;
end;

const
  UsesLine = '  Askr.Plugins, App.Plugins,';
  CallLine = '  UsePlugins(R);';
  HandLines = '  in the uses of app.lpr:' + LineEnding + LineEnding + UsesLine + LineEnding +
    LineEnding + '  and after the middleware, before the routes:' + LineEnding + LineEnding +
    CallLine;

function AppLprStartsPlugins(const Text: string): Boolean;
begin
  Result := (Pos('App.Plugins', Text) > 0) and (Pos('UsePlugins(', Text) > 0);
end;

function WireAppLpr(const Text: string; out Changed: Boolean; out Err: string): string;
var
  L: TStringList;
  I, UsesAt, CallAt: Integer;
  NeedUses, NeedCall: Boolean;
begin
  Result := Text;
  Changed := False;
  Err := '';
  NeedUses := Pos('App.Plugins', Text) = 0;
  NeedCall := Pos('UsePlugins(', Text) = 0;
  if not (NeedUses or NeedCall) then
    Exit;
  L := TStringList.Create;
  try
    L.Text := Text;
    UsesAt := -1;
    CallAt := -1;
    for I := 0 to L.Count - 1 do
    begin
      if Trim(L[I]) = 'App.Migrations, App.Seeders,' then
        UsesAt := I;
      if Trim(L[I]) = 'UseAuth(R);' then
        CallAt := I;
    end;
    if (NeedUses and (UsesAt < 0)) or (NeedCall and (CallAt < 0)) then
    begin
      Err := 'app.lpr does not look the way askr new writes it, so nothing was ' +
        'added. Add the plugins yourself --' + LineEnding + LineEnding + HandLines;
      Exit;
    end;
    { The call first: it is below the uses, and inserting the uses would
      move it. }
    if NeedCall then
      L.Insert(CallAt + 1, CallLine);
    if NeedUses then
      L.Insert(UsesAt, UsesLine);
    Result := L.Text;
    Changed := True;
  finally
    L.Free;
  end;
end;

{ Written only when it changed, so a build with nothing new compiles
  nothing new. }
procedure WriteIfChanged(const Path_, Text: string);
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    if FileExists(Path_) then
    begin
      L.LoadFromFile(Path_);
      if L.Text = Text then
        Exit;
    end;
    L.Text := Text;
    ForceDirectories(ExtractFilePath(Path_));
    L.SaveToFile(Path_);
  finally
    L.Free;
  end;
end;

function PluginBuildFlags(P: TProject; const FrameworkVersion: string;
  out Err: string): string;
var
  Found: TPluginManifests;
  I, J: Integer;
  IndexDir, D: string;
begin
  Result := '';
  if not ResolvePlugins(P, FrameworkVersion, Found, Err) then
    Exit;
  { A plugin that is not linked, or linked and never started, is a plugin
    that silently does nothing. }
  if (Length(Found) > 0) and
     not AppLprStartsPlugins(ReadText(IncludeTrailingPathDelimiter(P.Root) + P.MainFile)) then
  begin
    Err := 'askr.toml names plugins, and ' + P.MainFile + ' does not start them. ' +
      'Add --' + LineEnding + LineEnding + HandLines;
    Exit;
  end;
  IndexDir := IncludeTrailingPathDelimiter(P.Root) + '.build' + PathDelim + 'plugins';
  WriteIfChanged(IncludeTrailingPathDelimiter(IndexDir) + 'App.Plugins.pas',
    PluginIndexSource(Found));
  Result := ' -Fu' + IndexDir;
  for I := 0 to High(Found) do
  begin
    for J := 0 to High(Found[I].Units) do
    begin
      D := IncludeTrailingPathDelimiter(Found[I].Dir) + Found[I].Units[J];
      Result := Result + ' -Fu' + D + ' -Fu' + D + PathDelim + '*';
    end;
    if Found[I].Migrations <> '' then
      Result := Result + ' -Fu' + IncludeTrailingPathDelimiter(Found[I].Dir) +
        Found[I].Migrations;
  end;
end;

{ ------------------------------------------------------------ askr.toml -- }

function AddPluginSection(const Toml, Name, Git, Version: string): string;
begin
  Result := Toml;
  if (Result <> '') and (Result[Length(Result)] <> #10) then
    Result := Result + LineEnding;
  Result := Result + LineEnding + '[plugins.' + Name + ']' + LineEnding +
    'git = "' + Git + '"' + LineEnding +
    'version = "' + Version + '"' + LineEnding;
end;

function RemovePluginSection(const Toml, Name: string; out Found: Boolean): string;
var
  L: TStringList;
  I, Start, Stop: Integer;
  S: string;
begin
  Found := False;
  Result := Toml;
  L := TStringList.Create;
  try
    L.Text := Toml;
    Start := -1;
    for I := 0 to L.Count - 1 do
      if Trim(L[I]) = '[plugins.' + Name + ']' then
      begin
        Start := I;
        Break;
      end;
    if Start < 0 then
      Exit;
    Stop := L.Count;
    for I := Start + 1 to L.Count - 1 do
    begin
      S := Trim(L[I]);
      if (S <> '') and (S[1] = '[') then
      begin
        Stop := I;
        Break;
      end;
    end;
    { The blank line askr put in front of it goes with it. }
    if (Start > 0) and (Trim(L[Start - 1]) = '') then
      Dec(Start);
    for I := Stop - 1 downto Start do
      L.Delete(I);
    Result := L.Text;
    Found := True;
  finally
    L.Free;
  end;
end;

{ ------------------------------------------------------------- fetching -- }

procedure RemoveTree(const Dir: string);
var
  Out_: string;
begin
  if DirectoryExists(Dir) then
    RunCapture('/usr/bin/env', ['rm', '-rf', Dir], '', Out_);
end;

{ Clones the tag v<Version> of Git into a directory of its own and returns
  it, or '' and Err. }
function CloneTag(const Git, Version, Into: string; out Err: string): Boolean;
var
  Log_: string;
begin
  Err := '';
  RemoveTree(Into);
  ForceDirectories(ExtractFilePath(ExcludeTrailingPathDelimiter(Into)));
  if RunCapture('/usr/bin/env',
       ['git', '-c', 'advice.detachedHead=false', 'clone', '--depth', '1',
        '--branch', 'v' + Version, '--quiet', Git, Into], '', Log_) <> 0 then
  begin
    RemoveTree(Into);
    Err := 'could not fetch v' + Version + ' from ' + Git + '.' + LineEnding +
      Trim(Log_);
    Exit(False);
  end;
  Result := True;
end;

{ Fetches Name at Version into the cache, unless it is there, and gives
  the commit it stands on. The tree has to call itself what it was fetched
  as: a tag that points at another plugin, or another version, is refused. }
function FetchPlugin(const Name, Git, Version: string; out Commit, Err: string): Boolean;
var
  Target, Tmp: string;
  M: TPluginManifest;
begin
  Result := False;
  Commit := '';
  Target := PluginCacheDir(Name, Version);
  if CachedManifest(Name, Version, M) then
  begin
    Commit := CommitOf(Target);
    Exit(True);
  end;
  Say('  fetching ' + Name + ' ' + Version + ' from ' + Git);
  Tmp := Target + '.tmp';
  if not CloneTag(Git, Version, Tmp, Err) then
    Exit;
  if not ReadManifest(Tmp, M, Err) then
  begin
    RemoveTree(Tmp);
    Exit;
  end;
  if (M.Name <> Name) or (M.Version <> Version) then
  begin
    RemoveTree(Tmp);
    Err := 'the tag v' + Version + ' at ' + Git + ' is ' + M.Name + ' ' + M.Version +
      ', not ' + Name + ' ' + Version + '. Refusing to install it under the wrong name.';
    Exit;
  end;
  Commit := CommitOf(Tmp);
  RemoveTree(Target);
  if not RenameFile(Tmp, Target) then
  begin
    RemoveTree(Tmp);
    Err := 'could not move the download into ' + Target;
    Exit;
  end;
  Result := True;
end;

{ The newest published version of Git that Spec allows, or ''. }
function NewestAllowed(const Git, Spec: string): string;
var
  Tags: TStringArray;
  I: Integer;
begin
  Result := '';
  Tags := RemoteVersions(Git);
  for I := High(Tags) downto 0 do
    if (Spec = '') or SatisfiesRange(Tags[I], Spec) then
      Exit(Tags[I]);
end;

procedure SetLocked(var L: TLock; const Name, Git, Version, Commit: string);
var
  K: Integer;
begin
  K := LockedIndex(L, Name);
  if K < 0 then
  begin
    K := Length(L.Plugins);
    SetLength(L.Plugins, K + 1);
    L.Plugins[K].Name := Name;
  end;
  L.Plugins[K].Git := Git;
  L.Plugins[K].Version := Version;
  L.Plugins[K].Commit := Commit;
end;

procedure DropLocked(var L: TLock; const Name: string);
var
  K, I: Integer;
begin
  K := LockedIndex(L, Name);
  if K < 0 then
    Exit;
  for I := K to High(L.Plugins) - 1 do
    L.Plugins[I] := L.Plugins[I + 1];
  SetLength(L.Plugins, Length(L.Plugins) - 1);
end;

{ ------------------------------------------------------------- commands -- }

function InstallPlugins(P: TProject): Integer;
var
  Names: TStringArray;
  L: TLock;
  I, K: Integer;
  Git, Spec, Version, Commit, Err: string;
  Changed: Boolean;
begin
  Result := 0;
  Names := P.PluginNames;
  if Length(Names) = 0 then
    Exit;
  if not HasGit then
  begin
    Say('askr: git was not found on PATH. Plugins are fetched with git.');
    Exit(1);
  end;
  L := ReadLock(P.Root);
  Changed := False;
  Say('');
  for I := 0 to High(Names) do
  begin
    if P.PluginSetting(Names[I], 'path') <> '' then
    begin
      Say('  ' + Names[I] + '  local: ' + P.PluginSetting(Names[I], 'path'));
      Continue;
    end;
    Git := P.PluginSetting(Names[I], 'git');
    Spec := P.PluginSetting(Names[I], 'version');
    if Git = '' then
    begin
      Say('askr: [plugins.' + Names[I] + '] in askr.toml has neither git nor path.');
      Exit(1);
    end;
    K := LockedIndex(L, Names[I]);
    if (K >= 0) and (L.Plugins[K].Git = Git) and
       ((Spec = '') or SatisfiesRange(L.Plugins[K].Version, Spec)) then
      Version := L.Plugins[K].Version
    else
    begin
      Version := NewestAllowed(Git, Spec);
      if Version = '' then
      begin
        Say('askr: nothing published at ' + Git + ' matches ' + Names[I] + ' ' + Spec);
        Exit(1);
      end;
      K := -1;
    end;
    if not FetchPlugin(Names[I], Git, Version, Commit, Err) then
    begin
      Say('askr: ' + Err);
      Exit(1);
    end;
    { The same check as the framework's: the locked commit and the copy in
      the cache have to agree, or the tag moved or the cache was touched. }
    if (K >= 0) and (L.Plugins[K].Commit <> '') and (Commit <> L.Plugins[K].Commit) then
    begin
      Say('askr: askr.lock pins commit ' + Copy(L.Plugins[K].Commit, 1, 12) + ' for ' +
        Names[I] + ' ' + Version + ',');
      Say('      but the copy in the cache is ' + Copy(Commit, 1, 12) + '.');
      Say('');
      Say('  the tag may have been moved. remove the cached copy to refetch:');
      Say('    rm -rf ' + PluginCacheDir(Names[I], Version));
      Exit(1);
    end;
    if K < 0 then
    begin
      SetLocked(L, Names[I], Git, Version, Commit);
      Changed := True;
    end;
    Say('  ' + Names[I] + ' ' + Version + '  (' + Copy(Commit, 1, 12) + ')');
  end;
  { Plugins that left askr.toml leave the lock. }
  for I := High(L.Plugins) downto 0 do
    if P.PluginSetting(L.Plugins[I].Name, 'git') = '' then
    begin
      DropLocked(L, L.Plugins[I].Name);
      Changed := True;
    end;
  if Changed then
    WriteLock(P.Root, L);
end;

function OutdatedPlugins(P: TProject): Integer;
var
  Names: TStringArray;
  L: TLock;
  I, K: Integer;
  Git, Newest, Allowed: string;
begin
  Result := 0;
  Names := P.PluginNames;
  L := ReadLock(P.Root);
  for I := 0 to High(Names) do
  begin
    Git := P.PluginSetting(Names[I], 'git');
    K := LockedIndex(L, Names[I]);
    if (Git = '') or (K < 0) then
      Continue;
    Newest := NewestAllowed(Git, '');
    Allowed := NewestAllowed(Git, P.PluginSetting(Names[I], 'version'));
    if (Newest = '') or (CompareSemVer(Newest, L.Plugins[K].Version) <= 0) then
      Say('  ' + Names[I] + ' ' + L.Plugins[K].Version + '  up to date')
    else if (Allowed <> '') and (CompareSemVer(Allowed, L.Plugins[K].Version) > 0) then
      Say('  ' + Names[I] + ' ' + L.Plugins[K].Version + ' -> ' + Allowed +
        '   askr plugin update ' + Names[I])
    else
      Say('  ' + Names[I] + ' ' + L.Plugins[K].Version + '   ' + Newest +
        ' is published; askr.toml allows ' + P.PluginSetting(Names[I], 'version'));
  end;
end;

function TomlPath(P: TProject): string;
begin
  Result := IncludeTrailingPathDelimiter(P.Root) + 'askr.toml';
end;

{ The framework version the project builds against, or '' when it cannot
  be resolved -- then the build says why, and add need not. }
function FrameworkVersionOf(P: TProject): string;
var
  Origin: TPkgOrigin;
  Err, Dir: string;
begin
  Dir := ResolveFramework(P, Origin, Err);
  if Dir = '' then
    Exit('');
  Result := TreeVersion(Dir);
end;

{ Fetches the newest release once to learn what it calls itself, then
  moves it to where the name puts it. Every way out before that removes
  the download. }
function PluginAdd(P: TProject; const Git: string): Integer;
var
  Version, Tmp, Err, Commit, Have, Name, AppPath, AppText: string;
  Wired: Boolean;
  M, Cached: TPluginManifest;
  L: TLock;
  Names: TStringArray;
  I: Integer;
begin
  Result := 1;
  if not HasGit then
  begin
    Say('askr: git was not found on PATH. Plugins are fetched with git.');
    Exit;
  end;
  Version := NewestAllowed(Git, '');
  if Version = '' then
  begin
    Say('askr: found no release at ' + Git + ' -- a plugin is published as a tag');
    Say('      like v0.1.0, with ' + ManifestFile + ' at its root.');
    Exit;
  end;
  Tmp := IncludeTrailingPathDelimiter(CacheRoot) + 'plugins' + PathDelim +
    '.incoming-' + LowerCase(RandomHex(6));
  if not CloneTag(Git, Version, Tmp, Err) then
  begin
    Say('askr: ' + Err);
    Exit;
  end;
  Err := '';
  if not ReadManifest(Tmp, M, Err) then
    { Err says why. }
  else if M.Version <> Version then
    Err := 'the tag v' + Version + ' at ' + Git + ' says it is ' + M.Name + ' ' +
      M.Version + '. Refusing it.'
  else
  begin
    Names := P.PluginNames;
    for I := 0 to High(Names) do
      if Names[I] = M.Name then
        Err := 'askr.toml already has the plugin ' + M.Name + '. To move it: ' +
          'askr plugin update ' + M.Name;
  end;
  if Err <> '' then
  begin
    RemoveTree(Tmp);
    Say('askr: ' + Err);
    Exit;
  end;

  Have := FrameworkVersionOf(P);
  if (Have <> '') and not SatisfiesRange(Have, M.AskrRange) then
    Say('  note: ' + M.Name + ' ' + M.Version + ' builds against Askr ' + M.AskrRange +
      ', and this project against ' + Have + '. The build will refuse it until ' +
      'they agree.');

  { Its own variable, and its own record for the check: passing M.Name as
    the const name into a call that resets M as its out parameter empties
    the name before it is compared -- a const string is passed by
    reference. The test found that; add wrote [plugins.] into askr.toml. }
  Name := M.Name;
  if CachedManifest(Name, Version, Cached) then
    RemoveTree(Tmp)
  else
  begin
    RemoveTree(PluginCacheDir(Name, Version));
    if not RenameFile(Tmp, PluginCacheDir(Name, Version)) then
    begin
      RemoveTree(Tmp);
      Say('askr: could not move the download into ' + PluginCacheDir(Name, Version));
      Exit;
    end;
  end;
  Commit := CommitOf(PluginCacheDir(Name, Version));

  WriteText(TomlPath(P), AddPluginSection(ReadText(TomlPath(P)), Name, Git,
    '^' + Version));
  L := ReadLock(P.Root);
  SetLocked(L, Name, Git, Version, Commit);
  WriteLock(P.Root, L);
  Say('Added ' + Name + ' ' + Version + '  (' + Copy(Commit, 1, 12) + ')');
  Say('  askr.toml  [plugins.' + Name + ']');
  Say('  askr.lock  the commit');
  { An app made before plugins does not start them yet. }
  AppPath := IncludeTrailingPathDelimiter(P.Root) + P.MainFile;
  if FileExists(AppPath) then
  begin
    AppText := WireAppLpr(ReadText(AppPath), Wired, Err);
    if Wired then
    begin
      WriteText(AppPath, AppText);
      Say('  ' + P.MainFile + '    now starts the plugins');
    end
    else if Err <> '' then
    begin
      Say('');
      Say(Err);
    end;
  end;
  Say('');
  Say('It is compiled in on the next build: askr build');
  Result := 0;
end;

function PluginRemove(P: TProject; const Name: string): Integer;
var
  Text: string;
  Found: Boolean;
  L: TLock;
begin
  Text := RemovePluginSection(ReadText(TomlPath(P)), Name, Found);
  if not Found then
  begin
    Say('askr: askr.toml has no [plugins.' + Name + '] section as askr writes it.');
    Say('      remove the section by hand, then run: askr install');
    Exit(1);
  end;
  WriteText(TomlPath(P), Text);
  L := ReadLock(P.Root);
  DropLocked(L, Name);
  WriteLock(P.Root, L);
  Say('Removed ' + Name + ' from askr.toml and askr.lock.');
  Say('Its tables, if it made any, are still in the database.');
  Result := 0;
end;

function PluginList(P: TProject): Integer;
var
  Names: TStringArray;
  L: TLock;
  I, K: Integer;
begin
  Result := 0;
  Names := P.PluginNames;
  if Length(Names) = 0 then
  begin
    Say('No plugins. Add one with: askr plugin add <git url>');
    Exit;
  end;
  L := ReadLock(P.Root);
  for I := 0 to High(Names) do
  begin
    K := LockedIndex(L, Names[I]);
    if P.PluginSetting(Names[I], 'path') <> '' then
      Say('  ' + Names[I] + '  local ' + P.PluginSetting(Names[I], 'path'))
    else if K >= 0 then
      Say('  ' + Names[I] + ' ' + L.Plugins[K].Version + '  (' +
        Copy(L.Plugins[K].Commit, 1, 12) + ')  ' + L.Plugins[K].Git)
    else
      Say('  ' + Names[I] + '  not installed -- run: askr install');
  end;
end;

function PluginUpdate(P: TProject; const Only: string): Integer;
var
  Names: TStringArray;
  L: TLock;
  I, K: Integer;
  Git, To_, From_, Commit, Err, Notes: string;
begin
  Result := 0;
  Names := P.PluginNames;
  L := ReadLock(P.Root);
  for I := 0 to High(Names) do
  begin
    if (Only <> '') and (Names[I] <> Only) then
      Continue;
    Git := P.PluginSetting(Names[I], 'git');
    if Git = '' then
      Continue;
    To_ := NewestAllowed(Git, P.PluginSetting(Names[I], 'version'));
    K := LockedIndex(L, Names[I]);
    From_ := '';
    if K >= 0 then
      From_ := L.Plugins[K].Version;
    if To_ = '' then
    begin
      Say('askr: nothing published at ' + Git + ' matches ' +
        P.PluginSetting(Names[I], 'version'));
      Exit(1);
    end;
    if (From_ <> '') and (CompareSemVer(To_, From_) <= 0) then
    begin
      Say('  ' + Names[I] + ' ' + From_ + '  up to date');
      Continue;
    end;
    if not FetchPlugin(Names[I], Git, To_, Commit, Err) then
    begin
      Say('askr: ' + Err);
      Exit(1);
    end;
    { A plugin's UPGRADE.md is read the same way as the framework's, and
      before the lock moves. }
    if From_ <> '' then
    begin
      Notes := UpgradeNotes(PluginCacheDir(Names[I], To_), From_, To_);
      if Notes <> '' then
      begin
        Say('');
        Say('--- ' + Names[I] + ': what changes between ' + From_ + ' and ' + To_ + ' ---');
        Say('');
        Say(Notes);
        Say('');
      end;
    end;
    SetLocked(L, Names[I], Git, To_, Commit);
    Say('  ' + Names[I] + ' ' + From_ + ' -> ' + To_ + '  (' + Copy(Commit, 1, 12) + ')');
  end;
  WriteLock(P.Root, L);
end;

function CmdPlugin(P: TProject): Integer;
var
  Sub: string;
begin
  Sub := ParamStr(2);
  if (Sub = 'add') and (ParamStr(3) <> '') then
    Result := PluginAdd(P, ParamStr(3))
  else if (Sub = 'remove') and (ParamStr(3) <> '') then
    Result := PluginRemove(P, ParamStr(3))
  else if (Sub = 'list') or (Sub = '') then
    Result := PluginList(P)
  else if Sub = 'update' then
    Result := PluginUpdate(P, ParamStr(3))
  else
  begin
    Say('Usage:');
    Say('  askr plugin add <git url>     fetch the newest release and pin it');
    Say('  askr plugin remove <name>     take it out of askr.toml and askr.lock');
    Say('  askr plugin list              what this project builds with');
    Say('  askr plugin update [name]     move to the newest release askr.toml allows');
    Result := 64;
  end;
end;

end.
