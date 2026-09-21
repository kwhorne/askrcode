{ Askr.Core.Log — one log for the whole framework.

  Before this the server wrote `WriteLn(StdErr, ...)` in three places, and
  an app that wanted to log something had nothing to use. That holds right
  up until something goes wrong in production: then a log that cannot be
  filtered, has no levels and cannot be sent anywhere is the same as no
  log at all.

  Two formats:

  * **text** — for a terminal window during development:
  `2026-09-20T08:11:12.345Z INFO  request  method=GET path=/ status=200`
  * **json** — one line per event, for production, where something else
  is going to read them. Each line is a JSON object with ts, level,
  msg and the fields.

  (An example of the JSON line cannot go here: braces inside a Pascal
  comment open a nested comment.)

  The default follows `APP_ENV`: text locally, JSON in production. That is
  the only place in Askr where the environment changes behaviour by
  itself, and the reason is that a wrong default here is noticed
  immediately — either the terminal is full of JSON, or the log collector
  is full of text it does not understand.

  **Values from `.env` are never logged by the framework.** The same rule
  as in `Askr.Core.Env`: a log line ends up in a system more people can
  read than the database. If the app logs a secret that is the app's
  choice — but nothing here does it for it.

  The log is thread-safe. Every worker writes to the same one, and a line
  must not be cut in two by another thread. }
unit Askr.Core.Log;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs,
  Askr.Core.Clock;

type
  { llNone turns the log off entirely. It is not a level you log at, only
    a ceiling nothing gets over. }
  TLogLevel = (llDebug, llInfo, llWarn, llError, llNone);
  TLogFormat = (lfText, lfJson);

  { A destination of your own: one line at a time, already formatted,
    without a line break. Called with the log's lock held, so it must not
    log itself. }
  TLogSink = procedure(const Line: string);

{ ------------------------------------------------------------ oppsett -- }

procedure SetLogLevel(L: TLogLevel);
function LogLevel: TLogLevel;
{ True when something at this level would actually be written. Use it to
  skip expensive formatting:

  if LogEnabled(llDebug) then
  LogDebug(BuildExpensiveMessage);

  LogDebug checks the level itself, but its arguments have already been
  worked out by the time it is called. }
function LogEnabled(L: TLogLevel): Boolean;

procedure SetLogFormat(F: TLogFormat);
function LogFormat: TLogFormat;

{ Writes to a file instead of stderr. An empty path gives stderr back.
  The file is opened for append and held open; a log that opens and closes
  per line costs one system call too many per request. }
procedure SetLogFile(const Path: string);
function LogFile: string;

{ Egen destinasjon. nil gir stderr eller fila tilbake. }
procedure SetLogSink(S: TLogSink);

{ Reads LOG_LEVEL, LOG_FORMAT and LOG_FILE from the environment, with
  APP_ENV as the default for the format. Called once at startup, after
  LoadEnv. }
procedure ConfigureLogFromEnv;

function ParseLogLevel(const S: string; out L: TLogLevel): Boolean;
function LogLevelName(L: TLogLevel): string;

{ ------------------------------------------------------------ logging -- }

{ The fields are pairs: key, value, key, value. The keys are strings, the
  values whatever `array of const` accepts — integers, strings, booleans,
  floats.

  LogInfo('order placed', ['id', Order.Id, 'total', Order.Total]);

  A key with no value at the end gets an empty value. A log line must
  never be able to bring down what logged it. }
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

{ An unhandled exception. The class name and message, plus whatever
  fields you give it. The stack trace is left out: it only exists with
  -gl, and half a trace in a log is worse than none. }
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
      { Append, not overwrite: a restart must not delete the previous run's
        log. }
      if FileExists(Path) then
        Append(GFile)
      else
        Rewrite(GFile);
      GFileOpen := True;
    except
      on E: EInOutError do
      begin
        { A log that cannot be opened should say so on stderr and carry on
          there. Raising here would take the app down because it could not
          log. }
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
  F, Path_: string;
begin
  if Env('LOG_LEVEL') <> '' then
  begin
    if ParseLogLevel(Env('LOG_LEVEL'), L) then
      SetLogLevel(L)
    else
      { The key is named, the value is not — the same rule as EnvOrFail. A
        misspelled LOG_LEVEL should say so rather than become silence. }
      WriteLn(StdErr, '[askr] LOG_LEVEL is not a known level; using info');
  end;

  F := LowerCase(Trim(Env('LOG_FORMAT')));
  if F = 'json' then
    SetLogFormat(lfJson)
  else if F = 'text' then
    SetLogFormat(lfText)
  else if IsProduction then
    { In production the log is read by a machine, not by a person in a
      terminal window. }
    SetLogFormat(lfJson)
  else
    SetLogFormat(lfText);

  Path_ := Env('LOG_FILE');
  if Path_ <> '' then
    SetLogFile(Path_);
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

function FloatWithDot(V: Extended): string;
var
  Fs: TFormatSettings;
begin
  Fs := DefaultFormatSettings;
  Fs.DecimalSeparator := '.';
  Fs.ThousandSeparator := #0;
  Result := FloatToStr(V, Fs);
end;

{ True for values that belong unquoted in JSON. A log collector handed
  "ms":"12" cannot do arithmetic on it; "ms":12 it can. }
function IsNumber(const V: TVarRec): Boolean;
begin
  Result := V.VType in [vtInteger, vtInt64, vtQWord, vtExtended, vtCurrency];
end;

function ErBool(const V: TVarRec): Boolean;
begin
  Result := V.VType = vtBoolean;
end;

{ One value from `array of const` to text. Everything that can come in
  needs a branch: a log line that raises because somebody passed a pointer
  is worse than the line it replaced. }
function ValueText(const V: TVarRec): string;
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
    { FloatToStr and CurrToStr follow the locale, and on a Norwegian machine
      the decimal separator becomes a comma. In a JSON log "1,5" is not a
      number, it is a syntax error. The dot is therefore set
      explicitly. }
    vtExtended: Result := FloatWithDot(V.VExtended^);
    vtCurrency: Result := FloatWithDot(V.VCurrency^);
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

{ The text format quotes only when it has to. A value with no spaces or
  quotes reads more easily without them, and it is a person reading this
  format. }
function TextValue(const S: string): string;
var
  I: Integer;
  NeedsQuoting: Boolean;
begin
  NeedsQuoting := S = '';
  for I := 1 to Length(S) do
    if (S[I] <= ' ') or (S[I] = '"') then
    begin
      NeedsQuoting := True;
      Break;
    end;
  if not NeedsQuoting then
    Exit(S);
  Result := '"' + JsonEscape(S) + '"';
end;

procedure WriteLine_(const Line: string);
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
        { Without Flush the last lines sit in the buffer when the process
          dies, and those are exactly the lines somebody is looking for. }
        Flush(GFile);
        Exit;
      except
        on EInOutError do
        begin
          { The disk is full or the file is gone. Fall back to stderr rather
            than losing the log entirely. }
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
  Noekkel, Value_: string;
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
      Noekkel := ValueText(Fields[I]);
      B := B + ',"' + JsonEscape(Noekkel) + '":';
      if I + 1 > High(Fields) then
        B := B + '""'
      else if IsNumber(Fields[I + 1]) or ErBool(Fields[I + 1]) then
        B := B + ValueText(Fields[I + 1])
      else
        B := B + '"' + JsonEscape(ValueText(Fields[I + 1])) + '"';
      Inc(I, 2);
    end;
    B := B + '}';
  end
  else
  begin
    { The level is padded to five characters so the messages line up. }
    B := IsoTimestampNow + ' ' +
      Format('%-5s', [UpperCase(LogLevelName(L))]) + ' ' + Msg;
    I := 0;
    while I <= High(Fields) do
    begin
      Noekkel := ValueText(Fields[I]);
      if I + 1 <= High(Fields) then
        Value_ := ValueText(Fields[I + 1])
      else
        Value_ := '';
      B := B + ' ' + Noekkel + '=' + TextValue(Value_);
      Inc(I, 2);
    end;
  end;

  WriteLine_(B);
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
  NKlasse, NErr, VKlasse, VErr: string;
  All_: array of TVarRec;
  I: Integer;
begin
  if not LogEnabled(llError) then
    Exit;
  if E = nil then
  begin
    LogWrite(llError, Context, Fields);
    Exit;
  end;

  { The class and the message become their own fields rather than part of
    the message text. In the JSON format that is the difference between
    being able to group by error type and having to search free text.

    A TVarRec only holds a pointer to the string. The four local variables
    are here precisely to keep them alive until LogWrite has read them —
    expressions in place would have been freed too early. }
  NKlasse := 'class';
  VKlasse := E.ClassName;
  NErr := 'error';
  VErr := E.Message;

  SetLength(All_, Length(Fields) + 4);
  All_[0].VType := vtAnsiString; All_[0].VAnsiString := Pointer(NKlasse);
  All_[1].VType := vtAnsiString; All_[1].VAnsiString := Pointer(VKlasse);
  All_[2].VType := vtAnsiString; All_[2].VAnsiString := Pointer(NErr);
  All_[3].VType := vtAnsiString; All_[3].VAnsiString := Pointer(VErr);
  for I := 0 to High(Fields) do
    All_[I + 4] := Fields[I];

  LogWrite(llError, Context, All_);
end;

initialization
  GLock := TCriticalSection.Create;

finalization
  LukkFil;
  GLock.Free;

end.
