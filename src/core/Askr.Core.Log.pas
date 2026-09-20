{ Askr.Core.Log — én logg for hele rammeverket.

  Før dette skrev serveren `WriteLn(StdErr, ...)` tre steder, og en app som
  ville logge noe hadde ingenting å bruke. Det holder helt til noe går galt i
  produksjon: da er en logg som ikke kan filtreres, ikke har nivåer og ikke
  lar seg sende noe sted det samme som ingen logg.

  To formater:

    * **text** — til et terminalvindu under utvikling:
      `2026-09-20T08:11:12.345Z INFO  request  method=GET path=/ status=200`
    * **json** — én linje per hendelse, til produksjon, der noe annet skal
      lese dem. Hver linje er et JSON-objekt med ts, level, msg og feltene.

  (Et eksempel på JSON-linja kan ikke stå her: klammeparenteser inne i en
  Pascal-kommentar åpner en nøstet kommentar.)

  Standardvalget følger `APP_ENV`: tekst lokalt, JSON i produksjon. Det er
  det eneste stedet i Askr der miljøet endrer oppførsel av seg selv, og
  grunnen er at feil standard her merkes med en gang — enten er terminalen
  full av JSON, eller så er logginnsamleren full av tekst den ikke forstår.

  **Verdier fra `.env` logges aldri av rammeverket.** Samme regel som i
  `Askr.Core.Env`: en logglinje havner i et system flere har tilgang til enn
  databasen. Logger appen selv en hemmelighet, er det appens valg — men
  ingenting her gjør det for den.

  Loggen er trådsikker. Alle workerne skriver til den samme, og en linje
  skal ikke kunne bli klippet i to av en annen tråd. }
unit Askr.Core.Log;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs,
  Askr.Core.Clock;

type
  { llNone slår loggen helt av. Den er ikke et nivå man logger på, bare et
    tak ingenting kommer over. }
  TLogLevel = (llDebug, llInfo, llWarn, llError, llNone);
  TLogFormat = (lfText, lfJson);

  { Egen destinasjon: en linje om gangen, ferdig formatert, uten linjeskift.
    Kalles med loggens lås holdt, så den skal ikke logge selv. }
  TLogSink = procedure(const Line: string);

{ ------------------------------------------------------------ oppsett -- }

procedure SetLogLevel(L: TLogLevel);
function LogLevel: TLogLevel;
{ Sant når noe på dette nivået faktisk ville blitt skrevet. Bruk den til å
  hoppe over dyr formatering:

      if LogEnabled(llDebug) then
        LogDebug(BygDyrMelding);

  Selve LogDebug sjekker nivået selv, men argumentene er allerede regnet ut
  når den kalles. }
function LogEnabled(L: TLogLevel): Boolean;

procedure SetLogFormat(F: TLogFormat);
function LogFormat: TLogFormat;

{ Skriver til fil i stedet for stderr. Tom sti gir stderr tilbake. Fila
  åpnes for tillegg og holdes åpen; en logg som åpner og lukker per linje
  koster et systemkall for mye per request. }
procedure SetLogFile(const Path: string);
function LogFile: string;

{ Egen destinasjon. nil gir stderr eller fila tilbake. }
procedure SetLogSink(S: TLogSink);

{ Leser LOG_LEVEL, LOG_FORMAT og LOG_FILE fra miljøet, med APP_ENV som
  standard for formatet. Kalles én gang ved oppstart, etter LoadEnv. }
procedure ConfigureLogFromEnv;

function ParseLogLevel(const S: string; out L: TLogLevel): Boolean;
function LogLevelName(L: TLogLevel): string;

{ ------------------------------------------------------------ logging -- }

{ Feltene er par: nøkkel, verdi, nøkkel, verdi. Nøklene er strenger,
  verdiene hva som helst `array of const` tar imot — heltall, strenger,
  boolske, flyttall.

      LogInfo('order placed', ['id', Ordre.Id, 'total', Ordre.Total]);

  En nøkkel uten verdi til slutt får tom verdi. En logglinje skal aldri
  kunne velte det som logget den. }
procedure LogWrite(L: TLogLevel; const Msg: string); overload;
procedure LogWrite(L: TLogLevel; const Msg: string;
  const Fields: array of const); overload;

procedure LogDebug(const Msg: string); overload;
procedure LogDebug(const Msg: string; const Fields: array of const); overload;
procedure LogInfo(const Msg: string); overload;
procedure LogInfo(const Msg: string; const Fields: array of const); overload;
procedure LogWarn(const Msg: string); overload;
procedure LogWarn(const Msg: string; const Fields: array of const); overload;
procedure LogError(const Msg: string); overload;
procedure LogError(const Msg: string; const Fields: array of const); overload;

{ En upåaktet exception. Klassenavn og melding, pluss feltene du gir den.
  Stakksporet tas ikke med: det finnes bare med -gl, og halve spor i en
  logg er verre enn ingen. }
procedure LogException(E: Exception; const Context: string); overload;
procedure LogException(E: Exception; const Context: string;
  const Fields: array of const); overload;

implementation

uses
  Askr.Core.Env;

var
  GLock: TCriticalSection;
  GLevel: TLogLevel = llInfo;
  GFormat: TLogFormat = lfText;
  GPath: string = '';
  GFile: TextFile;
  GFileOpen: Boolean = False;
  GSink: TLogSink = nil;

{ ------------------------------------------------------------ oppsett -- }

function LogLevelName(L: TLogLevel): string;
begin
  case L of
    llDebug: Result := 'debug';
    llInfo: Result := 'info';
    llWarn: Result := 'warn';
    llError: Result := 'error';
  else
    Result := 'none';
  end;
end;

function ParseLogLevel(const S: string; out L: TLogLevel): Boolean;
var
  T: string;
begin
  T := LowerCase(Trim(S));
  Result := True;
  if (T = 'debug') or (T = 'trace') then
    L := llDebug
  else if T = 'info' then
    L := llInfo
  else if (T = 'warn') or (T = 'warning') then
    L := llWarn
  else if (T = 'error') or (T = 'fatal') then
    L := llError
  else if (T = 'none') or (T = 'off') or (T = 'silent') then
    L := llNone
  else
  begin
    L := llInfo;
    Result := False;
  end;
end;

procedure SetLogLevel(L: TLogLevel);
begin
  GLevel := L;
end;

function LogLevel: TLogLevel;
begin
  Result := GLevel;
end;

function LogEnabled(L: TLogLevel): Boolean;
begin
  Result := (L >= GLevel) and (GLevel <> llNone);
end;

procedure SetLogFormat(F: TLogFormat);
begin
  GFormat := F;
end;

function LogFormat: TLogFormat;
begin
  Result := GFormat;
end;

procedure LukkFil;
begin
  if GFileOpen then
  begin
    try
      CloseFile(GFile);
    except
      on EInOutError do ;
    end;
    GFileOpen := False;
  end;
end;

procedure SetLogFile(const Path: string);
begin
  GLock.Acquire;
  try
    LukkFil;
    GPath := Path;
    if Path = '' then
      Exit;
    try
      AssignFile(GFile, Path);
      { Tillegg, ikke overskriving: en omstart skal ikke slette forrige
        kjørings logg. }
      if FileExists(Path) then
        Append(GFile)
      else
        Rewrite(GFile);
      GFileOpen := True;
    except
      on E: EInOutError do
      begin
        { En logg som ikke lar seg åpne skal si fra på stderr og fortsette
          der. Å kaste her ville tatt ned appen fordi den ikke fikk logge. }
        GPath := '';
        GFileOpen := False;
        WriteLn(StdErr, '[askr] could not open log file ', Path, ': ',
          E.Message);
      end;
    end;
  finally
    GLock.Release;
  end;
end;

function LogFile: string;
begin
  Result := GPath;
end;

procedure SetLogSink(S: TLogSink);
begin
  GSink := S;
end;

procedure ConfigureLogFromEnv;
var
  L: TLogLevel;
  F, Sti: string;
begin
  if Env('LOG_LEVEL') <> '' then
  begin
    if ParseLogLevel(Env('LOG_LEVEL'), L) then
      SetLogLevel(L)
    else
      { Nøkkelen nevnes, verdien ikke — samme regel som EnvOrFail. En
        LOG_LEVEL som er feilstavet skal si fra, ikke bli til stillhet. }
      WriteLn(StdErr, '[askr] LOG_LEVEL is not a known level; using info');
  end;

  F := LowerCase(Trim(Env('LOG_FORMAT')));
  if F = 'json' then
    SetLogFormat(lfJson)
  else if F = 'text' then
    SetLogFormat(lfText)
  else if IsProduction then
    { I produksjon leses loggen av en maskin, ikke av et menneske i et
      terminalvindu. }
    SetLogFormat(lfJson)
  else
    SetLogFormat(lfText);

  Sti := Env('LOG_FILE');
  if Sti <> '' then
    SetLogFile(Sti);
end;

{ ------------------------------------------------------------ skriving -- }

function JsonEscape(const S: string): string;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    case C of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8: Result := Result + '\b';
      #9: Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
    else
      if C < #32 then
        Result := Result + Format('\u%.4x', [Ord(C)])
      else
        Result := Result + C;
    end;
  end;
end;

function FloatMedPunktum(V: Extended): string;
var
  Fs: TFormatSettings;
begin
  Fs := DefaultFormatSettings;
  Fs.DecimalSeparator := '.';
  Fs.ThousandSeparator := #0;
  Result := FloatToStr(V, Fs);
end;

{ Sant for verdier som skal stå usitert i JSON. En logginnsamler som får
  «"ms":"12"» kan ikke regne på den; «"ms":12» kan den. }
function ErTall(const V: TVarRec): Boolean;
begin
  Result := V.VType in [vtInteger, vtInt64, vtQWord, vtExtended, vtCurrency];
end;

function ErBool(const V: TVarRec): Boolean;
begin
  Result := V.VType = vtBoolean;
end;

{ Én verdi fra `array of const` til tekst. Alt som kan komme inn må ha en
  gren: en logglinje som kaster fordi noen sendte en peker er verre enn
  linja den erstattet. }
function VerdiTekst(const V: TVarRec): string;
begin
  case V.VType of
    vtInteger: Result := IntToStr(V.VInteger);
    vtInt64: Result := IntToStr(V.VInt64^);
    vtQWord: Result := IntToStr(V.VQWord^);
    vtBoolean:
      if V.VBoolean then
        Result := 'true'
      else
        Result := 'false';
    vtChar: Result := V.VChar;
    vtString: Result := V.VString^;
    vtAnsiString: Result := AnsiString(V.VAnsiString);
    vtPChar: Result := StrPas(V.VPChar);
    vtWideChar: Result := string(V.VWideChar);
    vtWideString: Result := string(WideString(V.VWideString));
    vtUnicodeString: Result := string(UnicodeString(V.VUnicodeString));
    { FloatToStr og CurrToStr følger locale, og på en norsk maskin blir
      desimalskilletegnet komma. I en JSON-logg er «1,5» ikke et tall, det
      er en syntaksfeil. Punktum settes derfor eksplisitt. }
    vtExtended: Result := FloatMedPunktum(V.VExtended^);
    vtCurrency: Result := FloatMedPunktum(V.VCurrency^);
    vtPointer:
      if V.VPointer = nil then
        Result := 'nil'
      else
        Result := Format('0x%p', [V.VPointer]);
    vtObject:
      if V.VObject = nil then
        Result := 'nil'
      else
        Result := V.VObject.ClassName;
    vtClass:
      if V.VClass = nil then
        Result := 'nil'
      else
        Result := V.VClass.ClassName;
  else
    Result := '?';
  end;
end;

{ Tekstformatet siterer bare når det trengs. En verdi uten mellomrom eller
  anførselstegn leses lettere uten dem, og det er et menneske som leser
  dette formatet. }
function TekstVerdi(const S: string): string;
var
  I: Integer;
  MaaSiteres: Boolean;
begin
  MaaSiteres := S = '';
  for I := 1 to Length(S) do
    if (S[I] <= ' ') or (S[I] = '"') then
    begin
      MaaSiteres := True;
      Break;
    end;
  if not MaaSiteres then
    Exit(S);
  Result := '"' + JsonEscape(S) + '"';
end;

procedure SkrivLinje(const Line: string);
begin
  GLock.Acquire;
  try
    if Assigned(GSink) then
    begin
      GSink(Line);
      Exit;
    end;
    if GFileOpen then
    begin
      try
        WriteLn(GFile, Line);
        { Uten Flush ligger de siste linjene i bufferet når prosessen dør,
          og det er nettopp de linjene noen leter etter. }
        Flush(GFile);
        Exit;
      except
        on EInOutError do
        begin
          { Disken er full eller fila er borte. Fall tilbake til stderr i
            stedet for å miste loggen helt. }
          LukkFil;
          GPath := '';
        end;
      end;
    end;
    WriteLn(StdErr, Line);
    Flush(StdErr);
  finally
    GLock.Release;
  end;
end;

procedure LogWrite(L: TLogLevel; const Msg: string;
  const Fields: array of const);
var
  B: string;
  I: Integer;
  Noekkel, Verdi: string;
begin
  if not LogEnabled(L) then
    Exit;

  if GFormat = lfJson then
  begin
    B := '{"ts":"' + IsoTimestampNow + '","level":"' + LogLevelName(L) +
      '","msg":"' + JsonEscape(Msg) + '"';
    I := 0;
    while I <= High(Fields) do
    begin
      Noekkel := VerdiTekst(Fields[I]);
      B := B + ',"' + JsonEscape(Noekkel) + '":';
      if I + 1 > High(Fields) then
        B := B + '""'
      else if ErTall(Fields[I + 1]) or ErBool(Fields[I + 1]) then
        B := B + VerdiTekst(Fields[I + 1])
      else
        B := B + '"' + JsonEscape(VerdiTekst(Fields[I + 1])) + '"';
      Inc(I, 2);
    end;
    B := B + '}';
  end
  else
  begin
    { Nivået fylles ut til fem tegn slik at meldingene står i kolonne. }
    B := IsoTimestampNow + ' ' +
      Format('%-5s', [UpperCase(LogLevelName(L))]) + ' ' + Msg;
    I := 0;
    while I <= High(Fields) do
    begin
      Noekkel := VerdiTekst(Fields[I]);
      if I + 1 <= High(Fields) then
        Verdi := VerdiTekst(Fields[I + 1])
      else
        Verdi := '';
      B := B + ' ' + Noekkel + '=' + TekstVerdi(Verdi);
      Inc(I, 2);
    end;
  end;

  SkrivLinje(B);
end;

procedure LogWrite(L: TLogLevel; const Msg: string);
begin
  LogWrite(L, Msg, []);
end;

procedure LogDebug(const Msg: string);
begin
  LogWrite(llDebug, Msg, []);
end;

procedure LogDebug(const Msg: string; const Fields: array of const);
begin
  LogWrite(llDebug, Msg, Fields);
end;

procedure LogInfo(const Msg: string);
begin
  LogWrite(llInfo, Msg, []);
end;

procedure LogInfo(const Msg: string; const Fields: array of const);
begin
  LogWrite(llInfo, Msg, Fields);
end;

procedure LogWarn(const Msg: string);
begin
  LogWrite(llWarn, Msg, []);
end;

procedure LogWarn(const Msg: string; const Fields: array of const);
begin
  LogWrite(llWarn, Msg, Fields);
end;

procedure LogError(const Msg: string);
begin
  LogWrite(llError, Msg, []);
end;

procedure LogError(const Msg: string; const Fields: array of const);
begin
  LogWrite(llError, Msg, Fields);
end;

procedure LogException(E: Exception; const Context: string);
begin
  LogException(E, Context, []);
end;

procedure LogException(E: Exception; const Context: string;
  const Fields: array of const);
var
  NKlasse, NFeil, VKlasse, VFeil: string;
  Alle: array of TVarRec;
  I: Integer;
begin
  if not LogEnabled(llError) then
    Exit;
  if E = nil then
  begin
    LogWrite(llError, Context, Fields);
    Exit;
  end;

  { Klassen og meldingen blir egne felter, ikke en del av meldingsteksten.
    I JSON-formatet er det forskjellen på å kunne gruppere på feiltype og
    å måtte lete i fritekst.

    En TVarRec holder bare en peker til strengen. De fire lokale variablene
    står her nettopp for å holde dem i live til LogWrite har lest dem —
    uttrykk på stedet ville vært frigjort for tidlig. }
  NKlasse := 'class';
  VKlasse := E.ClassName;
  NFeil := 'error';
  VFeil := E.Message;

  SetLength(Alle, Length(Fields) + 4);
  Alle[0].VType := vtAnsiString; Alle[0].VAnsiString := Pointer(NKlasse);
  Alle[1].VType := vtAnsiString; Alle[1].VAnsiString := Pointer(VKlasse);
  Alle[2].VType := vtAnsiString; Alle[2].VAnsiString := Pointer(NFeil);
  Alle[3].VType := vtAnsiString; Alle[3].VAnsiString := Pointer(VFeil);
  for I := 0 to High(Fields) do
    Alle[I + 4] := Fields[I];

  LogWrite(llError, Context, Alle);
end;

initialization
  GLock := TCriticalSection.Create;

finalization
  LukkFil;
  GLock.Free;

end.
