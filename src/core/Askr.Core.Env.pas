{ Askr.Core.Env — .env, lest én gang ved oppstart.

  Poenget er at hemmeligheter ikke skal stå i kildekoden. En API-nøkkel, et
  databasepassord eller en sertifikatsti hører til utrullingen, og `.env` er
  der man legger dem i utvikling.

  Tre regler, og de er ikke forhandlingsbare:

    * **Ekte miljøvariabler vinner.** Er `DATABASE_URL` satt i miljøet, blir
      den brukt selv om `.env` sier noe annet. Det er slik produksjon kan
      sette verdier uten at fila finnes, og slik alle andre gjør det.
    * **Verdier logges aldri.** En feilmelding sier hvilken nøkkel som
      manglet, aldri hva den inneholdt. `EnvOrFail` er skrevet for å være
      trygg å la stå i en stacktrace.
    * **`.env` sjekkes ikke inn.** `askr new` legger den i .gitignore og
      lager en `.env.example` ved siden av.

  Fila leses inn i prosessens eget lager, ikke satt med `setenv`. Det er med
  vilje: FPCs RTL holder sin egen kopi av miljøet fra oppstart, så `setenv`
  når uansett ikke fram til barneprosesser — og et lager vi eier selv er
  lettere å resonnere om enn et vi deler med libc. }
unit Askr.Core.Env;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes;

type
  EEnvError = class(Exception);

{ Leser fila hvis den finnes. Gjør ingenting hvis den ikke gjør det — en app
  i produksjon har gjerne bare ekte miljøvariabler. Kalles én gang, tidlig. }
procedure LoadEnv(const Path: string = '.env');
{ Leser fra den første .env som finnes i denne mappa eller en over. Samme
  måte som `askr` finner askr.toml. }
procedure LoadEnvUpwards(const StartDir: string = '');

{ Miljøet først, så .env, så tom streng. }
function Env(const Key: string): string; overload;
function Env(const Key, Default_: string): string; overload;
function EnvInt(const Key: string; Default_: Int64 = 0): Int64;
function EnvBool(const Key: string; Default_: Boolean = False): Boolean;
{ Kaster hvis nøkkelen mangler eller er tom. Meldingen nevner nøkkelen og
  hvor det ble lett — aldri verdien. }
function EnvOrFail(const Key: string): string;
{ Om nøkkelen finnes i det hele tatt, uansett om den er tom. }
function EnvHas(const Key: string): Boolean;

{ ------------------------------------------------------------- miljø -- }

{ `APP_ENV`, i små bokstaver, eller 'local' når den ikke er satt.

  Én nøkkel avgjør hva appen tror den er. Standarden er `local` og ikke
  `production`, fordi en app som *tror* den er i produksjon uten å være det
  skrur på ting ingen ba om — mens motsatt vei merkes med en gang. }
function AppEnv: string;
function IsProduction: Boolean;
function IsLocal: Boolean;
function IsTesting: Boolean;

{ Sjekker at alle nøklene finnes og ikke er tomme, og kaster én gang med
  **alle** som mangler.

  Poenget er tidspunktet: uten den oppdages en manglende DATABASE_URL på
  første request som treffer databasen, kanskje i produksjon, kanskje som
  en 500 hos en bruker. Med den stopper appen ved oppstart og sier hvilke
  nøkler det gjelder. Aldri hvilke verdier. }
procedure RequireEnv(const Keys: array of string);

{ Til diagnostikk. EnvKeys gir navnene som ble lest, ikke verdiene. }
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

{ Verdien etter = i en .env-linje.

  Tre former, som i alle andre .env-lesere:
    KEY=rå verdi          — trimmes, og # etter mellomrom er kommentar
    KEY="med escapes"     — \n, \t, \" og \\ tolkes
    KEY='helt bokstavelig' — ingenting tolkes }
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

  { Ikke sitert: en # med mellomrom foran starter en kommentar. Uten
    mellomrom er den en del av verdien, slik at et passord med # i seg
    ikke blir kuttet i to. }
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
  Linjer: TStringList;
  I, P, Idx: Integer;
  L, Key, Verdi: string;
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

    Linjer := TStringList.Create;
    try
      Linjer.LoadFromFile(Path);
      for I := 0 to Linjer.Count - 1 do
      begin
        L := Trim(Linjer[I]);
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
        { **Ikke Values[Key] := ...** — den setteren sletter oppføringen når
          verdien er tom på FPC 3.3.1, mens 3.2.2 beholder den. En linje som
          «API_KEY=» ville altså forsvunnet på trunk og blitt igjen på 3.2.2.
          Vi skriver paret selv. Siste forekomst vinner, slik at en fil kan
          overstyre seg selv. }
        Verdi := ParseValue(Copy(L, P + 1, MaxInt));
        Idx := GStore.IndexOfName(Key);
        if Idx >= 0 then
          GStore[Idx] := Key + '=' + Verdi
        else
          GStore.Add(Key + '=' + Verdi);
      end;
      GFile := ExpandFileName(Path);
    finally
      Linjer.Free;
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
  { Ingen fil funnet er ikke en feil. Lageret opprettes likevel, slik at
    Env() virker og bare svarer fra miljøet. }
  LoadEnv('');
end;

function Env(const Key: string): string;
var
  Idx: Integer;
begin
  { Miljøet først. En verdi satt av systemd, docker eller et skall skal
    aldri kunne overstyres av en fil som ligger igjen i katalogen. }
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
  Hvor: string;
begin
  Result := Env(Key);
  if Result <> '' then
    Exit;
  { Meldingen sier hvor det ble lett, slik at den som får den kan gjøre noe.
    Den sier aldri hva noen annen nøkkel inneholder. }
  if GFile <> '' then
    Hvor := Format(' Checked the environment and %s.', [GFile])
  else
    Hvor := ' Checked the environment; no .env file was loaded.';
  raise EEnvError.CreateFmt('%s is not set.%s', [Key, Hvor]);
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


{ ------------------------------------------------------------- miljø -- }

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
  { Begge skrivemåtene, fordi begge brukes i praksis og forskjellen
    mellom dem aldri er noe noen mener. }
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
  Mangler: string;
  Antall: Integer;
begin
  Mangler := '';
  Antall := 0;
  for I := 0 to High(Keys) do
    if Trim(Env(Keys[I])) = '' then
    begin
      if Mangler <> '' then
        Mangler := Mangler + ', ';
      Mangler := Mangler + Keys[I];
      Inc(Antall);
    end;
  if Antall = 0 then
    Exit;
  { Alle på én gang. En feil om gangen betyr like mange omstarter som det
    er manglende nøkler. }
  if GFile <> '' then
    raise EEnvError.CreateFmt(
      'Missing required configuration: %s. Looked in the environment and %s.',
      [Mangler, GFile])
  else
    raise EEnvError.CreateFmt(
      'Missing required configuration: %s. Looked in the environment; ' +
      'no .env file was found.', [Mangler]);
end;
initialization
  GLock := TCriticalSection.Create;

finalization
  GStore.Free;
  GLock.Free;

end.
