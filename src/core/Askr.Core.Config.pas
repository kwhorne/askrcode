{ Askr.Core.Config — ett oppslag for all konfigurasjon.

  Før dette leste CLI-en `askr.toml` og appen leste `.env`, og de to visste
  ikke om hverandre. En app som ville vite hvilken port den kjørte på måtte
  enten gjette eller få den fortalt på kommandolinjen.

  Fire lag, i denne rekkefølgen:

    1. ekte miljøvariabler
    2. `.env`
    3. `askr.toml`
    4. standardverdien kalleren oppgir

  Nøkkelen skrives med punktum — `app.port` — og oversettes til
  `APP_PORT` når miljøet slås opp. Det er hele regelen, og den er den
  eneste som er verdt å huske: **miljøet vinner alltid over fila.** En
  utrulling skal kunne sette noe uten at en fil i repoet endres.

  Formatet i `askr.toml` er det minste som ser ut som TOML: nøkkel = verdi,
  én per linje, seksjoner i klammer. Parseren her er den samme som CLI-en
  bruker — `askr.toml` skal ikke kunne bety to ting.

  **Verdier logges ikke.** `ConfigReport` viser nøkler og hvor de kom fra,
  ikke hva de inneholder, med mindre noen ber om det eksplisitt. Grunnen
  står i Askr.Core.Env: en `.env` er stedet hemmelighetene ligger. }
unit Askr.Core.Config;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes;

type
  EConfigError = class(Exception);

  { Hvor en verdi kom fra. Til ConfigReport — «hvorfor er porten 9000» er
    et spørsmål man stiller ofte nok til at svaret bør stå der. }
  TConfigSource = (csNone, csEnvironment, csDotEnv, csToml, csDefault);

{ Leser askr.toml og .env, begge funnet ved å lete oppover fra StartDir
  (tom betyr gjeldende katalog). Kalles én gang, først i app.lpr. Mangler
  en av dem, er det ikke en feil — en app i produksjon har gjerne bare
  ekte miljøvariabler. }
procedure LoadConfig(const StartDir: string = '');

{ Oppslag gjennom alle fire lagene. }
function Cfg(const Key: string): string; overload;
function Cfg(const Key, Default_: string): string; overload;
function CfgInt(const Key: string; Default_: Int64 = 0): Int64;
function CfgBool(const Key: string; Default_: Boolean = False): Boolean;
{ Finnes nøkkelen i noe lag, uansett om verdien er tom? }
function CfgHas(const Key: string): Boolean;
{ Kaster hvis den mangler eller er tom. Meldingen nevner nøkkelen, hvor det
  ble lett og hvilken miljøvariabel som ville satt den — aldri en verdi. }
function CfgOrFail(const Key: string): string;
{ Hvilket lag verdien kom fra. }
function CfgSource(const Key: string): TConfigSource;
function SourceName(S: TConfigSource): string;

{ Miljøvariabelnavnet en nøkkel oversettes til: app.port blir APP_PORT. }
function EnvNameFor(const Key: string): string;

function ConfigFile: string;
function ConfigKeys: TStringArray;

{ Til `askr config`. Uten ShowValues står bare nøkkel og kilde — det er
  trygt å lime inn i en feilrapport. Med ShowValues vises verdiene, men
  nøkler som ser ut som hemmeligheter er fortsatt skjult. }
function ConfigReport(ShowValues: Boolean = False): string;
{ Ser nøkkelen ut til å holde en hemmelighet? Brukt av ConfigReport. }
function LooksSecret(const Key: string): Boolean;

{ Leser en askr.toml-lignende fil inn i en TStringList som «seksjon.nøkkel»
  = verdi. Eksponert fordi CLI-en bruker den samme — to parsere for samme
  fil ville før eller siden vært uenige om hva den betyr. }
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
      { Add med «nøkkel=verdi», ikke Values[...] := . På 3.3.1 sletter
        `Values[K] := ''` oppføringen i stedet for å sette den tom, og en
        nøkkel med tom verdi i askr.toml ville forsvunnet på den ene
        kompilatoren og blitt stående på den andre. Samme felle som i
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

function FinnOppover(const StartDir, Navn: string): string;
var
  Dir, Prev: string;
begin
  if StartDir = '' then
    Dir := GetCurrentDir
  else
    Dir := StartDir;
  Dir := ExcludeTrailingPathDelimiter(ExpandFileName(Dir));
  repeat
    if FileExists(IncludeTrailingPathDelimiter(Dir) + Navn) then
      Exit(IncludeTrailingPathDelimiter(Dir) + Navn);
    Prev := Dir;
    Dir := ExtractFileDir(Dir);
  until (Dir = Prev) or (Dir = '');
  Result := '';
end;

procedure LoadConfig(const StartDir: string);
var
  Sti: string;
begin
  { .env først, slik at Env() virker under resten av oppstarten. }
  LoadEnvUpwards(StartDir);

  GLock.Acquire;
  try
    if GToml = nil then
      GToml := TStringList.Create
    else
      GToml.Clear;
    GTomlFile := '';
    Sti := FinnOppover(StartDir, 'askr.toml');
    if (Sti <> '') and ParseTomlInto(Sti, GToml) then
      GTomlFile := Sti;
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

function TomlVerdi(const Key: string; out V: string): Boolean;
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
  EnvNavn, V: string;
begin
  EnvNavn := EnvNameFor(Key);
  if GetEnvironmentVariable(EnvNavn) <> '' then
    Exit(csEnvironment);
  if EnvHas(EnvNavn) then
    Exit(csDotEnv);
  if TomlVerdi(Key, V) then
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
  EnvNavn, V: string;
begin
  EnvNavn := EnvNameFor(Key);
  { Env dekker både ekte miljøvariabler og .env, i den rekkefølgen. }
  V := Env(EnvNavn);
  if V <> '' then
    Exit(V);
  if TomlVerdi(Key, V) and (V <> '') then
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
  Hvor: string;
begin
  Result := Trim(Cfg(Key));
  if Result <> '' then
    Exit;
  { Meldingen sier hvilken miljøvariabel som ville satt den. Uten det er
    oversettelsen fra app.port til APP_PORT noe man må slå opp. }
  Hvor := 'the environment';
  if EnvFile <> '' then
    Hvor := Hvor + ', ' + EnvFile;
  if GTomlFile <> '' then
    Hvor := Hvor + ', ' + GTomlFile;
  raise EConfigError.CreateFmt(
    'Missing configuration "%s". Set %s, or add it to askr.toml. ' +
    'Looked in %s.', [Key, EnvNameFor(Key), Hvor]);
end;

{ ------------------------------------------------------------ rapport -- }

function LooksSecret(const Key: string): Boolean;
const
  { Ikke en fasit, og den kan ikke bli det. Den fanger navnene folk faktisk
    bruker, og standarden er uansett at ingen verdier vises. }
  Ord_: array[0..7] of string = (
    'secret', 'password', 'passwd', 'token', 'key', 'credential',
    'dsn', 'url');
var
  K: string;
  I: Integer;
begin
  K := LowerCase(Key);
  for I := Low(Ord_) to High(Ord_) do
    if Pos(Ord_[I], K) > 0 then
      Exit(True);
  Result := False;
end;

function ConfigKeys: TStringArray;
var
  Acc, Fra: TStringArray;
  I, N: Integer;
  K: string;

  { Samles i Acc, ikke i Result: inne i en nøstet funksjon er `Result` den
    nøstede funksjonens eget resultat, ikke den ytres. }
  function Har(const S: string): Boolean;
  var
    J: Integer;
  begin
    Result := False;
    for J := 0 to N - 1 do
      if SameText(Acc[J], S) then
        Exit(True);
  end;

  procedure Legg(const S: string);
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

  { Først .env-nøklene, så askr.toml. Nøkler fra begge står én gang. }
  Fra := EnvKeys;
  for I := 0 to High(Fra) do
    if not Har(Fra[I]) then
      Legg(Fra[I]);

  GLock.Acquire;
  try
    if GToml <> nil then
      for I := 0 to GToml.Count - 1 do
      begin
        K := GToml.Names[I];
        if (K = '') or Har(K) then
          Continue;
        Legg(K);
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
  K, V, Kilde: string;
  Bredde: Integer;
begin
  Noekler := ConfigKeys;
  Bredde := 0;
  for I := 0 to High(Noekler) do
    if Length(Noekler[I]) > Bredde then
      Bredde := Length(Noekler[I]);

  Result := '';
  if GTomlFile <> '' then
    Result := Result + 'askr.toml  ' + GTomlFile + #10;
  if EnvFile <> '' then
    Result := Result + '.env       ' + EnvFile + #10;
  Result := Result + 'APP_ENV    ' + AppEnv + #10#10;

  for I := 0 to High(Noekler) do
  begin
    K := Noekler[I];
    Kilde := SourceName(CfgSource(K));
    if not ShowValues then
      V := ''
    else if LooksSecret(K) then
      { Nøkkelen vises, verdien ikke. Den som spør vet da at den er satt,
        uten at den havner i en skjermdump. }
      V := '  (hidden)'
    else
      V := '  ' + Cfg(K);
    Result := Result + Format('%-*s  %-12s%s', [Bredde, K, Kilde, V]) + #10;
  end;
end;

initialization
  GLock := TCriticalSection.Create;

finalization
  GToml.Free;
  GLock.Free;

end.
