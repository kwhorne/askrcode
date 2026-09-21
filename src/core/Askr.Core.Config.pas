{ Askr.Core.Config — one lookup for all configuration.

  Before this the CLI read `askr.toml` and the app read `.env`, and the
  two knew nothing about each other. An app that wanted to know which port
  it was running on had to guess or be told on the command line.

  Four layers, in this order:

  1. real environment variables
  2. `.env`
  3. `askr.toml`
  4. the default the caller supplies

  Keys are written with dots — `app.port` — and translated to `APP_PORT`
  when the environment is consulted. That is the whole rule, and it is the
  only one worth remembering: **the environment always beats the file.** A
  deployment has to be able to set something without a file in the repo
  changing.

  The format in `askr.toml` is the smallest thing that looks like TOML:
  key = value, one per line, sections in brackets. The parser here is the
  one the CLI uses — `askr.toml` must not be able to mean two things.

  **Values are not logged.** `ConfigReport` shows keys and where they came
  from, not what they hold, unless somebody asks explicitly. The reason is
  in Askr.Core.Env: a `.env` is where the secrets live. }
unit Askr.Core.Config;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes;

type
  EConfigError = class(Exception);

  { Where a value came from. For ConfigReport — "why is the port 9000" is a
    question asked often enough that the answer should be there. }
  TConfigSource = (csNone, csEnvironment, csDotEnv, csToml, csDefault);

{ Reads askr.toml and .env, both found by searching upwards from StartDir
  (empty means the current directory). Called once, first in app.lpr. If
  one of them is missing that is not an error — an app in production often
  has only real environment variables. }
procedure LoadConfig(const StartDir: string = '');

{ Oppslag gjennom alle fire lagene. }
function Cfg(const Key: string): string; overload;
function Cfg(const Key, Default_: string): string; overload;
function CfgInt(const Key: string; Default_: Int64 = 0): Int64;
function CfgBool(const Key: string; Default_: Boolean = False): Boolean;
{ Does the key exist in any layer, empty value or not? }
function CfgHas(const Key: string): Boolean;
{ Raises if it is missing or empty. The message names the key, where it
  looked and which environment variable would set it — never a value. }
function CfgOrFail(const Key: string): string;
{ Hvilket lag verdien kom fra. }
function CfgSource(const Key: string): TConfigSource;
function SourceName(S: TConfigSource): string;

{ The environment variable name a key translates to: app.port becomes
  APP_PORT. }
function EnvNameFor(const Key: string): string;

function ConfigFile: string;
function ConfigKeys: TStringArray;

{ For `askr config`. Without ShowValues only the key and its source are
  shown — that is safe to paste into a bug report. With ShowValues the
  values appear, but keys that look like secrets are still hidden. }
function ConfigReport(ShowValues: Boolean = False): string;
{ Does the key look like it holds a secret? Used by ConfigReport. }
function LooksSecret(const Key: string): Boolean;

{ Reads an askr.toml-like file into a TStringList as "section.key" =
  value. Exposed because the CLI uses the same one — two parsers for the
  same file would sooner or later disagree about what it means. }
function ParseTomlInto(const Path: string; Into: TStringList): Boolean;

procedure ClearConfig;

implementation

uses
  SyncObjs, Askr.Core.Env;

var
  GToml: TStringList = nil;
  GTomlFile: string = '';
  GLock: TCriticalSection;

{ ------------------------------------------------------------- parsing -- }

function ParseTomlInto(const Path: string; Into: TStringList): Boolean;
var
  Lines: TStringList;
  I, Eq: Integer;
  Line, Key, Val, Section: string;
begin
  Result := False;
  if not FileExists(Path) then
    Exit;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(Path);
    except
      on EStreamError do
        Exit;
    end;
    Section := '';
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      if (Line = '') or (Line[1] = '#') then
        Continue;
      if (Line[1] = '[') and (Line[Length(Line)] = ']') then
      begin
        Section := Copy(Line, 2, Length(Line) - 2) + '.';
        Continue;
      end;
      Eq := Pos('=', Line);
      if Eq = 0 then
        Continue;
      Key := Trim(Copy(Line, 1, Eq - 1));
      Val := Trim(Copy(Line, Eq + 1, MaxInt));
      if (Length(Val) >= 2) and (Val[1] = '"') and (Val[Length(Val)] = '"') then
        Val := Copy(Val, 2, Length(Val) - 2);
      { Add with "key=value", not Values[...] := . On 3.3.1
        `Values[K] := ''` deletes the entry rather than setting it empty,
        and a key with an empty value in askr.toml would vanish on one
        compiler and survive on the other. The same trap as in
        Askr.Core.Env. }
      Eq := Into.IndexOfName(Section + Key);
      if Eq >= 0 then
        Into.Delete(Eq);
      Into.Add(Section + Key + '=' + Val);
    end;
    Result := True;
  finally
    Lines.Free;
  end;
end;

{ ------------------------------------------------------------ oppsett -- }

function FindUpwards(const StartDir, Name_: string): string;
var
  Dir, Prev: string;
begin
  if StartDir = '' then
    Dir := GetCurrentDir
  else
    Dir := StartDir;
  Dir := ExcludeTrailingPathDelimiter(ExpandFileName(Dir));
  repeat
    if FileExists(IncludeTrailingPathDelimiter(Dir) + Name_) then
      Exit(IncludeTrailingPathDelimiter(Dir) + Name_);
    Prev := Dir;
    Dir := ExtractFileDir(Dir);
  until (Dir = Prev) or (Dir = '');
  Result := '';
end;

procedure LoadConfig(const StartDir: string);
var
  Path_: string;
begin
  { .env first, so that Env() works through the rest of startup. }
  LoadEnvUpwards(StartDir);

  GLock.Acquire;
  try
    if GToml = nil then
      GToml := TStringList.Create
    else
      GToml.Clear;
    GTomlFile := '';
    Path_ := FindUpwards(StartDir, 'askr.toml');
    if (Path_ <> '') and ParseTomlInto(Path_, GToml) then
      GTomlFile := Path_;
  finally
    GLock.Release;
  end;
end;

procedure ClearConfig;
begin
  GLock.Acquire;
  try
    if GToml <> nil then
      GToml.Clear;
    GTomlFile := '';
  finally
    GLock.Release;
  end;
  ClearEnv;
end;

function ConfigFile: string;
begin
  Result := GTomlFile;
end;

{ ------------------------------------------------------------- oppslag -- }

function EnvNameFor(const Key: string): string;
var
  I: Integer;
begin
  Result := UpperCase(Key);
  for I := 1 to Length(Result) do
    if (Result[I] = '.') or (Result[I] = '-') then
      Result[I] := '_';
end;

function TomlValue(const Key: string; out V: string): Boolean;
var
  I: Integer;
begin
  V := '';
  GLock.Acquire;
  try
    if GToml = nil then
      Exit(False);
    I := GToml.IndexOfName(Key);
    if I < 0 then
      Exit(False);
    V := GToml.ValueFromIndex[I];
    Result := True;
  finally
    GLock.Release;
  end;
end;

function CfgSource(const Key: string): TConfigSource;
var
  EnvName, V: string;
begin
  EnvName := EnvNameFor(Key);
  if GetEnvironmentVariable(EnvName) <> '' then
    Exit(csEnvironment);
  if EnvHas(EnvName) then
    Exit(csDotEnv);
  if TomlValue(Key, V) then
    Exit(csToml);
  Result := csNone;
end;

function SourceName(S: TConfigSource): string;
begin
  case S of
    csEnvironment: Result := 'environment';
    csDotEnv: Result := '.env';
    csToml: Result := 'askr.toml';
    csDefault: Result := 'default';
  else
    Result := 'unset';
  end;
end;

function Cfg(const Key, Default_: string): string;
var
  EnvName, V: string;
begin
  EnvName := EnvNameFor(Key);
  { Env covers both real environment variables and .env, in that order. }
  V := Env(EnvName);
  if V <> '' then
    Exit(V);
  if TomlValue(Key, V) and (V <> '') then
    Exit(V);
  Result := Default_;
end;

function Cfg(const Key: string): string;
begin
  Result := Cfg(Key, '');
end;

function CfgHas(const Key: string): Boolean;
begin
  Result := CfgSource(Key) <> csNone;
end;

function CfgInt(const Key: string; Default_: Int64): Int64;
var
  V: string;
  N: Int64;
begin
  V := Trim(Cfg(Key));
  if (V = '') or not TryStrToInt64(V, N) then
    Exit(Default_);
  Result := N;
end;

function CfgBool(const Key: string; Default_: Boolean): Boolean;
var
  V: string;
begin
  V := LowerCase(Trim(Cfg(Key)));
  if V = '' then
    Exit(Default_);
  if (V = '1') or (V = 'true') or (V = 'yes') or (V = 'on') then
    Exit(True);
  if (V = '0') or (V = 'false') or (V = 'no') or (V = 'off') then
    Exit(False);
  Result := Default_;
end;

function CfgOrFail(const Key: string): string;
var
  Where_: string;
begin
  Result := Trim(Cfg(Key));
  if Result <> '' then
    Exit;
  { The message says which environment variable would set it. Without that
    the translation from app.port to APP_PORT is something you have to
    look up. }
  Where_ := 'the environment';
  if EnvFile <> '' then
    Where_ := Where_ + ', ' + EnvFile;
  if GTomlFile <> '' then
    Where_ := Where_ + ', ' + GTomlFile;
  raise EConfigError.CreateFmt(
    'Missing configuration "%s". Set %s, or add it to askr.toml. ' +
    'Looked in %s.', [Key, EnvNameFor(Key), Where_]);
end;

{ ------------------------------------------------------------ rapport -- }

function LooksSecret(const Key: string): Boolean;
const
  { Not definitive, and it cannot be. It catches the names people actually
    use, and the default is that no values are shown anyway. }
  Word_: array[0..7] of string = (
    'secret', 'password', 'passwd', 'token', 'key', 'credential',
    'dsn', 'url');
var
  K: string;
  I: Integer;
begin
  K := LowerCase(Key);
  for I := Low(Word_) to High(Word_) do
    if Pos(Word_[I], K) > 0 then
      Exit(True);
  Result := False;
end;

function ConfigKeys: TStringArray;
var
  Acc, From_: TStringArray;
  I, N: Integer;
  K: string;

  { Collected in Acc rather than in Result: inside a nested function
    `Result` is the nested function's own result, not the outer one's. }
  function Has_(const S: string): Boolean;
  var
    J: Integer;
  begin
    Result := False;
    for J := 0 to N - 1 do
      if SameText(Acc[J], S) then
        Exit(True);
  end;

  procedure Put(const S: string);
  begin
    if N >= Length(Acc) then
      SetLength(Acc, Length(Acc) * 2);
    Acc[N] := S;
    Inc(N);
  end;

begin
  Result := nil;
  Acc := nil;
  N := 0;
  SetLength(Acc, 64);

  { The .env keys first, then askr.toml. Keys from both appear once. }
  From_ := EnvKeys;
  for I := 0 to High(From_) do
    if not Has_(From_[I]) then
      Put(From_[I]);

  GLock.Acquire;
  try
    if GToml <> nil then
      for I := 0 to GToml.Count - 1 do
      begin
        K := GToml.Names[I];
        if (K = '') or Has_(K) then
          Continue;
        Put(K);
      end;
  finally
    GLock.Release;
  end;

  SetLength(Acc, N);
  Result := Acc;
end;

function ConfigReport(ShowValues: Boolean): string;
var
  Noekler: TStringArray;
  I: Integer;
  K, V, Source_: string;
  Width_: Integer;
begin
  Noekler := ConfigKeys;
  Width_ := 0;
  for I := 0 to High(Noekler) do
    if Length(Noekler[I]) > Width_ then
      Width_ := Length(Noekler[I]);

  Result := '';
  if GTomlFile <> '' then
    Result := Result + 'askr.toml  ' + GTomlFile + #10;
  if EnvFile <> '' then
    Result := Result + '.env       ' + EnvFile + #10;
  Result := Result + 'APP_ENV    ' + AppEnv + #10#10;

  for I := 0 to High(Noekler) do
  begin
    K := Noekler[I];
    Source_ := SourceName(CfgSource(K));
    if not ShowValues then
      V := ''
    else if LooksSecret(K) then
      { The key is shown, the value is not. Whoever asks then knows it is
        set, without it ending up in a screenshot. }
      V := '  (hidden)'
    else
      V := '  ' + Cfg(K);
    Result := Result + Format('%-*s  %-12s%s', [Width_, K, Source_, V]) + #10;
  end;
end;

initialization
  GLock := TCriticalSection.Create;

finalization
  GToml.Free;
  GLock.Free;

end.
