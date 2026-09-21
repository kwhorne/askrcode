{ Askr.Core.Env — .env, read once at startup.

  The point is that secrets do not belong in the source. An API key, a
  database password or a certificate path belongs to the deployment, and
  `.env` is where you put them in development.

  Three rules, and they are not negotiable:

    * **Real environment variables win.** If `DATABASE_URL` is set in the
      environment it is used, whatever `.env` says. That is how production
      sets values without the file existing, and how everyone else does
      it.
    * **Values are never logged.** An error message names the key that was
      missing, never what it held. `EnvOrFail` is written to be safe to
      leave in a stack trace.
    * **`.env` is not committed.** `askr new` puts it in .gitignore and
      writes a `.env.example` beside it.

  The file is read into the process's own store rather than set with
  `setenv`. That is deliberate: FPC's RTL keeps its own copy of the
  environment from startup, so `setenv` never reaches child processes
  anyway — and a store we own is easier to reason about than one shared
  with libc. }
unit Askr.Core.Env;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes;

type
  EEnvError = class(Exception);

{ Reads the file if it exists. Does nothing if it does not — an app in
  production often has only real environment variables. Called once,
  early. }
procedure LoadEnv(const Path: string = '.env');
{ Reads the first .env found in this directory or one above it. The same
  way `askr` finds askr.toml. }
procedure LoadEnvUpwards(const StartDir: string = '');

{ The environment first, then .env, then the empty string. }
function Env(const Key: string): string; overload;
function Env(const Key, Default_: string): string; overload;
function EnvInt(const Key: string; Default_: Int64 = 0): Int64;
function EnvBool(const Key: string; Default_: Boolean = False): Boolean;
{ Raises if the key is missing or empty. The message names the key and
  where it looked — never the value. }
function EnvOrFail(const Key: string): string;
{ Whether the key exists at all, empty or not. }
function EnvHas(const Key: string): Boolean;

{ -------------------------------------------------- the environment -- }

{ `APP_ENV`, lower-cased, or 'local' when it is not set.

  One key decides what the app thinks it is. The default is `local` rather
  than `production`, because an app that *thinks* it is in production
  without being so turns on things nobody asked for — while the other way
  round is noticed immediately. }
function AppEnv: string;
function IsProduction: Boolean;
function IsLocal: Boolean;
function IsTesting: Boolean;

{ Checks that every key exists and is non-empty, and raises once with
  **all** of the missing ones.

  The point is the timing: without it a missing DATABASE_URL is discovered
  on the first request that touches the database, perhaps in production,
  perhaps as a 500 in front of a user. With this the app stops at startup
  and says which keys are involved. Never which values. }
procedure RequireEnv(const Keys: array of string);

{ For diagnostics. EnvKeys gives the names that were read, not the
  values. }
function EnvFile: string;
function EnvKeys: TStringArray;
procedure ClearEnv;

implementation

uses
  SyncObjs;

var
  GStore: TStringList = nil;
  GFile: string = '';
  GLock: TCriticalSection;

{ The value after = on a .env line.

  Three forms, as in every other .env reader:
    KEY=raw value          — trimmed, and # after a space is a comment
    KEY="with escapes"     — \n, \t, \" and \\ are interpreted
    KEY='entirely literal' — nothing is interpreted }
function ParseValue(const Raw: string): string;
var
  S: string;
  I, N: Integer;
  Q: Char;
begin
  S := Trim(Raw);
  if S = '' then
    Exit('');

  if (S[1] = '"') or (S[1] = '''') then
  begin
    Q := S[1];
    Result := '';
    I := 2;
    N := Length(S);
    while I <= N do
    begin
      if S[I] = Q then
        Break;
      if (Q = '"') and (S[I] = '\') and (I < N) then
      begin
        Inc(I);
        case S[I] of
          'n': Result := Result + #10;
          'r': Result := Result + #13;
          't': Result := Result + #9;
          '0': Result := Result + #0;
        else
          Result := Result + S[I];
        end;
      end
      else
        Result := Result + S[I];
      Inc(I);
    end;
    Exit;
  end;

  { Unquoted: a # with a space in front of it starts a comment. Without
    the space it is part of the value, so a password with a # in it is not
    cut in two. }
  I := 2;
  while I <= Length(S) do
  begin
    if (S[I] = '#') and (S[I - 1] in [' ', #9]) then
    begin
      S := Copy(S, 1, I - 1);
      Break;
    end;
    Inc(I);
  end;
  Result := TrimRight(S);
end;

procedure LoadEnv(const Path: string);
var
  Lines: TStringList;
  I, P, Idx: Integer;
  L, Key, Value_: string;
begin
  GLock.Acquire;
  try
    if GStore = nil then
    begin
      GStore := TStringList.Create;
      GStore.CaseSensitive := True;
    end;
    if not FileExists(Path) then
      Exit;

    Lines := TStringList.Create;
    try
      Lines.LoadFromFile(Path);
      for I := 0 to Lines.Count - 1 do
      begin
        L := Trim(Lines[I]);
        if (L = '') or (L[1] = '#') then
          Continue;
        if Copy(L, 1, 7) = 'export ' then
          L := Trim(Copy(L, 8, MaxInt));
        P := Pos('=', L);
        if P <= 1 then
          Continue;
        Key := TrimRight(Copy(L, 1, P - 1));
        if Key = '' then
          Continue;
        { **Not Values[Key] := ...** — that setter deletes the entry when the
          value is empty on FPC 3.3.1, while 3.2.2 keeps it. A line like
          "API_KEY=" would therefore vanish on trunk and survive on 3.2.2.
          We write the pair ourselves. The last occurrence wins, so a file
          can override itself. }
        Value_ := ParseValue(Copy(L, P + 1, MaxInt));
        Idx := GStore.IndexOfName(Key);
        if Idx >= 0 then
          GStore[Idx] := Key + '=' + Value_
        else
          GStore.Add(Key + '=' + Value_);
      end;
      GFile := ExpandFileName(Path);
    finally
      Lines.Free;
    end;
  finally
    GLock.Release;
  end;
end;

procedure LoadEnvUpwards(const StartDir: string);
var
  Dir, Forrige: string;
begin
  if StartDir = '' then
    Dir := GetCurrentDir
  else
    Dir := StartDir;
  Dir := ExpandFileName(Dir);
  repeat
    if FileExists(IncludeTrailingPathDelimiter(Dir) + '.env') then
    begin
      LoadEnv(IncludeTrailingPathDelimiter(Dir) + '.env');
      Exit;
    end;
    Forrige := Dir;
    Dir := ExtractFileDir(ExcludeTrailingPathDelimiter(Dir));
  until (Dir = '') or (Dir = Forrige);
  { No file found is not an error. The store is created anyway, so Env()
    works and simply answers from the environment. }
  LoadEnv('');
end;

function Env(const Key: string): string;
var
  Idx: Integer;
begin
  { The environment first. A value set by systemd, docker or a shell must
    never be overridable by a file left lying in the directory. }
  Result := GetEnvironmentVariable(Key);
  if Result <> '' then
    Exit;

  GLock.Acquire;
  try
    if GStore = nil then
      Exit('');
    Idx := GStore.IndexOfName(Key);
    if Idx >= 0 then
      Result := GStore.ValueFromIndex[Idx]
    else
      Result := '';
  finally
    GLock.Release;
  end;
end;

function Env(const Key, Default_: string): string;
begin
  Result := Env(Key);
  if Result = '' then
    Result := Default_;
end;

function EnvHas(const Key: string): Boolean;
begin
  if GetEnvironmentVariable(Key) <> '' then
    Exit(True);
  GLock.Acquire;
  try
    Result := (GStore <> nil) and (GStore.IndexOfName(Key) >= 0);
  finally
    GLock.Release;
  end;
end;

function EnvInt(const Key: string; Default_: Int64): Int64;
begin
  Result := StrToInt64Def(Trim(Env(Key)), Default_);
end;

function EnvBool(const Key: string; Default_: Boolean): Boolean;
var
  S: string;
begin
  S := LowerCase(Trim(Env(Key)));
  if S = '' then
    Exit(Default_);
  Result := (S = '1') or (S = 'true') or (S = 'yes') or (S = 'on');
end;

function EnvOrFail(const Key: string): string;
var
  Where_: string;
begin
  Result := Env(Key);
  if Result <> '' then
    Exit;
  { The message says where it looked, so whoever gets it can do something
    about it. It never says what any other key holds. }
  if GFile <> '' then
    Where_ := Format(' Checked the environment and %s.', [GFile])
  else
    Where_ := ' Checked the environment; no .env file was loaded.';
  raise EEnvError.CreateFmt('%s is not set.%s', [Key, Where_]);
end;

function EnvFile: string;
begin
  Result := GFile;
end;

function EnvKeys: TStringArray;
var
  I: Integer;
begin
  GLock.Acquire;
  try
    if GStore = nil then
      Exit(nil);
    SetLength(Result, GStore.Count);
    for I := 0 to GStore.Count - 1 do
      Result[I] := GStore.Names[I];
  finally
    GLock.Release;
  end;
end;

procedure ClearEnv;
begin
  GLock.Acquire;
  try
    FreeAndNil(GStore);
    GFile := '';
  finally
    GLock.Release;
  end;
end;


{ -------------------------------------------------- the environment -- }

function AppEnv: string;
begin
  Result := LowerCase(Trim(Env('APP_ENV')));
  if Result = '' then
    Result := 'local';
end;

function IsProduction: Boolean;
var
  E: string;
begin
  E := AppEnv;
  { Both spellings, because both are used in practice and the difference
    between them is never anything anyone means. }
  Result := (E = 'production') or (E = 'prod');
end;

function IsLocal: Boolean;
var
  E: string;
begin
  E := AppEnv;
  Result := (E = 'local') or (E = 'development') or (E = 'dev');
end;

function IsTesting: Boolean;
var
  E: string;
begin
  E := AppEnv;
  Result := (E = 'testing') or (E = 'test');
end;

procedure RequireEnv(const Keys: array of string);
var
  I: Integer;
  Missing: string;
  Count_: Integer;
begin
  Missing := '';
  Count_ := 0;
  for I := 0 to High(Keys) do
    if Trim(Env(Keys[I])) = '' then
    begin
      if Missing <> '' then
        Missing := Missing + ', ';
      Missing := Missing + Keys[I];
      Inc(Count_);
    end;
  if Count_ = 0 then
    Exit;
  { All at once. One error at a time means as many restarts as there are
    missing keys. }
  if GFile <> '' then
    raise EEnvError.CreateFmt(
      'Missing required configuration: %s. Looked in the environment and %s.',
      [Missing, GFile])
  else
    raise EEnvError.CreateFmt(
      'Missing required configuration: %s. Looked in the environment; ' +
      'no .env file was found.', [Missing]);
end;
initialization
  GLock := TCriticalSection.Create;

finalization
  GStore.Free;
  GLock.Free;

end.
