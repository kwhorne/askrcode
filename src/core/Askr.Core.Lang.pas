{ Askr.Core.Lang — what the framework says, in the language of the person
  reading it.

  The words live in lang/<locale>.toml next to askr.toml:

      # lang/nb.toml
      [validation]
      required = ":attribute må fylles ut"

      [validation.attributes]
      email = "e-postadresse"

  and a key is looked up in the request's locale, then in the fallback
  locale, then in the English the framework is compiled with, and last it
  is shown as itself. So an app with no lang directory says exactly what
  it said before there was one, and a key nobody translated is English
  rather than blank.

  Three decisions worth knowing:

    * **The English is compiled in, not copied into the app.** A copy in
      lang/en.toml would be frozen the day the project was made, and the
      first upgrade that changed a message would leave the two disagreeing
      with nothing to say which is right -- the reason AGENTS.md is short.
      lang/en.toml holds what the app says differently, and nothing else.
    * **A placeholder is :name**, replaced longest name first, so :min
      never takes the front off :minimum. A value that is not given leaves
      the placeholder in the text, where it is seen.
    * **The locale is per thread**, set for the request by UseLocales in
      Askr.Locale, like the arena and the connection. Outside a request it
      is app.locale, or English.

  The tables are read once, at startup, and only read after that. }
unit Askr.Core.Lang;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes;

type
  ELangError = class(Exception);

  { A problem in a lang file: the file, the line and what is wrong. }
  TLangProblem = record
    Path: string;
    Line: Integer;
    Message: string;
  end;
  TLangProblems = array of TLangProblem;

{ Reads every lang/*.toml in Dir, or next to askr.toml when Dir is ''.
  A directory that is not there is no translations, not an error. What
  could not be read is in LangProblems. }
procedure LoadLang(const Dir: string = '');
procedure ClearLang;
function LangProblems: TLangProblems;

{ The locales there are files for, sorted. }
function Locales: TStringArray;
function HasLocale(const Locale: string): Boolean;

{ The locale outside a request: app.locale, or 'en'. And the one a key
  falls back to: app.fallback_locale, or 'en'. }
function DefaultLocale: string;
function FallbackLocale: string;

{ The locale for this thread, following the pattern of UseArena and
  UseDb. '' puts it back to DefaultLocale. Returns the one it replaced. }
function CurrentLocale: string;
function UseLocale(const Locale: string): string;

{ The text for Key, with each :name replaced. Args are pairs:

      Trans('validation.min_length', ['attribute', 'name', 'min', 3])

  Looked up in CurrentLocale, then FallbackLocale, then the framework's
  English, and shown as Key when it is nowhere. }
function Trans(const Key: string): string; overload;
function Trans(const Key: string; const Args: array of const): string; overload;

{ Whether Locale's file has Key -- the file, not the built-in English. }
function HasTrans(const Locale, Key: string): Boolean;

{ What a column is called in a message: validation.attributes.<column>
  in the current locale, and the column itself when nothing says. }
function AttributeName(const Column: string): string;

{ The keys and English text the framework is compiled with, as
  key=value lines. askr lang:check reads them to say what a locale
  lacks. }
function BuiltInTexts: TStringArray;

{ Every key of Locale's file, in the order it was written. }
function KeysOf(const Locale: string): TStringArray;

{ The :names in a text, sorted and each once. }
function PlaceholdersOf(const Text_: string): TStringArray;

{ Reads one lang file into Into as key=value, decoding "\"", "\\", "\n"
  and "\t". A line that is not a key, a section or a comment is a
  problem, not a silence. }
function ReadLangFile(const Path: string; Into: TStringList;
  var Problems: TLangProblems): Boolean;

implementation

uses
  Askr.Core.Config;

const
  { The framework's own words. English, and the text every message had
    before there were keys: an app with no lang directory must not notice
    that there are. }
  BuiltIn: array[0..12] of string = (
    'validation.required=:attribute is required',
    'validation.min_length=:attribute must be at least :min characters',
    'validation.max_length=:attribute can be at most :max characters',
    'validation.email=:attribute is not a valid email address',
    'validation.min=:attribute cannot be less than :min',
    'validation.max=:attribute cannot be greater than :max',
    'validation.between=:attribute must be between :min and :max',
    'validation.one_of=:attribute has a value that is not allowed',
    'validation.same_as=:attribute does not match :other',
    'validation.unique=:attribute is already taken',
    'validation.exists=:attribute does not match a row in :table',
    'validation.ids_exist=:attribute contains :ids, which does not match a row in :table',
    'validation.ids_list=:attribute must be a list of ids, and :value is not one'
  );

type
  TLocaleTable = record
    Locale: string;
    Keys: TStringList;   { key=value, in the order written }
  end;

var
  GTables: array of TLocaleTable;
  GBuiltIn: TStringList;
  GProblems: TLangProblems;

threadvar
  GCurrent: string;

procedure Say(var P: TLangProblems; const Path: string; Line: Integer;
  const Msg: string);
begin
  SetLength(P, Length(P) + 1);
  P[High(P)].Path := Path;
  P[High(P)].Line := Line;
  P[High(P)].Message := Msg;
end;

{ A double-quoted value with its escapes decoded. False when the quotes
  are not closed, or an escape is not one of the four. }
function Unquote(const S: string; out Value: string; out Why: string): Boolean;
var
  I: Integer;
begin
  Value := '';
  Why := '';
  Result := False;
  if (Length(S) >= 2) and (S[1] = '"') and (S[Length(S)] <> '"') and
     (Pos('#', S) > 0) then
  begin
    Why := 'a # comment goes on a line of its own';
    Exit;
  end;
  if (Length(S) < 2) or (S[1] <> '"') or (S[Length(S)] <> '"') then
  begin
    Why := 'a value is written in double quotes';
    Exit;
  end;
  I := 2;
  while I < Length(S) do
  begin
    if S[I] = '\' then
    begin
      if I + 1 >= Length(S) then
      begin
        Why := 'the value ends in a backslash';
        Exit;
      end;
      case S[I + 1] of
        '"': Value := Value + '"';
        '\': Value := Value + '\';
        'n': Value := Value + #10;
        't': Value := Value + #9;
      else
        Why := 'the escape \' + S[I + 1] + ' is not one of \" \\ \n \t';
        Exit;
      end;
      Inc(I, 2);
    end
    else if S[I] = '"' then
    begin
      Why := 'a quote inside the value is written \"';
      Exit;
    end
    else
    begin
      Value := Value + S[I];
      Inc(I);
    end;
  end;
  Result := True;
end;

function ReadLangFile(const Path: string; Into: TStringList;
  var Problems: TLangProblems): Boolean;
var
  Lines: TStringList;
  I, Eq, At: Integer;
  Line, Key, Raw, Value, Section, Why: string;
begin
  Result := False;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(Path);
    except
      on EStreamError do
      begin
        Say(Problems, Path, 0, 'cannot be read');
        Exit;
      end;
    end;
    Section := '';
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      if (Line = '') or (Line[1] = '#') then
        Continue;
      if (Line[1] = '[') and (Line[Length(Line)] = ']') then
      begin
        Section := Trim(Copy(Line, 2, Length(Line) - 2));
        if Section <> '' then
          Section := Section + '.';
        Continue;
      end;
      Eq := Pos('=', Line);
      if Eq = 0 then
      begin
        Say(Problems, Path, I + 1, 'is neither a key = "value", a [section] nor a # comment');
        Continue;
      end;
      Key := Trim(Copy(Line, 1, Eq - 1));
      Raw := Trim(Copy(Line, Eq + 1, MaxInt));
      if Key = '' then
      begin
        Say(Problems, Path, I + 1, 'has no key before the =');
        Continue;
      end;
      if not Unquote(Raw, Value, Why) then
      begin
        Say(Problems, Path, I + 1, Section + Key + ': ' + Why);
        Continue;
      end;
      At := Into.IndexOfName(Section + Key);
      if At >= 0 then
      begin
        Say(Problems, Path, I + 1, Section + Key + ' is there twice; the last one counts');
        Into.Delete(At);
      end;
      { Add, not Values[] :=, which deletes the entry for an empty value
        on 3.3.1 and keeps it on 3.2.2. }
      Into.Add(Section + Key + '=' + Value);
    end;
    Result := True;
  finally
    Lines.Free;
  end;
end;

procedure ClearLang;
var
  I: Integer;
begin
  for I := 0 to High(GTables) do
    GTables[I].Keys.Free;
  GTables := nil;
  GProblems := nil;
end;

procedure LoadLang(const Dir: string);
var
  Root, Path_: string;
  SR: TSearchRec;
  Found: TStringList;
  I, N: Integer;
begin
  ClearLang;
  Root := Dir;
  if Root = '' then
  begin
    if ConfigFile <> '' then
      Root := ExtractFilePath(ConfigFile) + 'lang'
    else
      Root := 'lang';
  end;
  Root := IncludeTrailingPathDelimiter(Root);
  if not DirectoryExists(Root) then
    Exit;
  Found := TStringList.Create;
  try
    Found.Sorted := True;
    if FindFirst(Root + '*.toml', faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Attr and faDirectory) = 0 then
          Found.Add(SR.Name);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
    for I := 0 to Found.Count - 1 do
    begin
      Path_ := Root + Found[I];
      N := Length(GTables);
      SetLength(GTables, N + 1);
      GTables[N].Locale := ChangeFileExt(Found[I], '');
      GTables[N].Keys := TStringList.Create;
      ReadLangFile(Path_, GTables[N].Keys, GProblems);
    end;
  finally
    Found.Free;
  end;
end;

function LangProblems: TLangProblems;
begin
  Result := GProblems;
end;

function TableOf(const Locale: string): TStringList;
var
  I: Integer;
begin
  for I := 0 to High(GTables) do
    if GTables[I].Locale = Locale then
      Exit(GTables[I].Keys);
  Result := nil;
end;

function Locales: TStringArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(GTables));
  for I := 0 to High(GTables) do
    Result[I] := GTables[I].Locale;
end;

function HasLocale(const Locale: string): Boolean;
begin
  Result := TableOf(Locale) <> nil;
end;

function DefaultLocale: string;
begin
  Result := Cfg('app.locale', 'en');
  if Result = '' then
    Result := 'en';
end;

function FallbackLocale: string;
begin
  Result := Cfg('app.fallback_locale', 'en');
  if Result = '' then
    Result := 'en';
end;

function CurrentLocale: string;
begin
  Result := GCurrent;
  if Result = '' then
    Result := DefaultLocale;
end;

function UseLocale(const Locale: string): string;
begin
  Result := GCurrent;
  GCurrent := Locale;
end;

function LookUp(const Locale, Key: string; out Text_: string): Boolean;
var
  T: TStringList;
  I: Integer;
begin
  T := TableOf(Locale);
  Result := False;
  if T = nil then
    Exit;
  I := T.IndexOfName(Key);
  if I < 0 then
    Exit;
  Text_ := T.ValueFromIndex[I];
  Result := True;
end;

function RawText(const Key: string): string;
var
  I: Integer;
begin
  if LookUp(CurrentLocale, Key, Result) then
    Exit;
  if LookUp(FallbackLocale, Key, Result) then
    Exit;
  I := GBuiltIn.IndexOfName(Key);
  if I >= 0 then
    Exit(GBuiltIn.ValueFromIndex[I]);
  Result := Key;
end;

function ArgText(const V: TVarRec): string;
begin
  case V.VType of
    vtInteger: Result := IntToStr(V.VInteger);
    vtInt64: Result := IntToStr(V.VInt64^);
    vtQWord: Result := IntToStr(V.VQWord^);
    vtBoolean: Result := BoolToStr(V.VBoolean, 'true', 'false');
    vtChar: Result := V.VChar;
    vtWideChar: Result := string(V.VWideChar);
    vtString: Result := string(V.VString^);
    vtAnsiString: Result := AnsiString(V.VAnsiString);
    vtUnicodeString: Result := UnicodeString(V.VUnicodeString);
    vtWideString: Result := WideString(V.VWideString);
    vtPChar: Result := string(V.VPChar);
    vtExtended: Result := FloatToStr(V.VExtended^, DefaultFormatSettings);
    vtCurrency: Result := CurrToStr(V.VCurrency^, DefaultFormatSettings);
  else
    Result := '';
  end;
end;

function Trans(const Key: string): string;
begin
  Result := RawText(Key);
end;

function Trans(const Key: string; const Args: array of const): string;
var
  Names, Values: array of string;
  I, J, N, Best: Integer;
  Taken: array of Boolean;
begin
  Result := RawText(Key);
  N := Length(Args) div 2;
  if N = 0 then
    Exit;
  SetLength(Names, N);
  SetLength(Values, N);
  SetLength(Taken, N);
  for I := 0 to N - 1 do
  begin
    Names[I] := ArgText(Args[I * 2]);
    Values[I] := ArgText(Args[I * 2 + 1]);
    Taken[I] := False;
  end;
  { Longest first: :min must not take the front off :minimum. }
  for J := 0 to N - 1 do
  begin
    Best := -1;
    for I := 0 to N - 1 do
      if not Taken[I] and ((Best < 0) or (Length(Names[I]) > Length(Names[Best]))) then
        Best := I;
    Taken[Best] := True;
    if Names[Best] <> '' then
      Result := StringReplace(Result, ':' + Names[Best], Values[Best], [rfReplaceAll]);
  end;
end;

function HasTrans(const Locale, Key: string): Boolean;
var
  Ignored: string;
begin
  Result := LookUp(Locale, Key, Ignored);
end;

function AttributeName(const Column: string): string;
var
  Key: string;
begin
  Key := 'validation.attributes.' + Column;
  if LookUp(CurrentLocale, Key, Result) then
    Exit;
  if LookUp(FallbackLocale, Key, Result) then
    Exit;
  Result := Column;
end;

function BuiltInTexts: TStringArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(BuiltIn));
  for I := 0 to High(BuiltIn) do
    Result[I] := BuiltIn[I];
end;

function KeysOf(const Locale: string): TStringArray;
var
  T: TStringList;
  I: Integer;
begin
  Result := nil;
  T := TableOf(Locale);
  if T = nil then
    Exit;
  SetLength(Result, T.Count);
  for I := 0 to T.Count - 1 do
    Result[I] := T.Names[I];
end;

function PlaceholdersOf(const Text_: string): TStringArray;
var
  L: TStringList;
  I, J: Integer;
begin
  L := TStringList.Create;
  try
    L.Sorted := True;
    L.Duplicates := dupIgnore;
    I := 1;
    while I <= Length(Text_) do
    begin
      if (Text_[I] = ':') and (I < Length(Text_)) and
         (Text_[I + 1] in ['a'..'z', 'A'..'Z', '_']) then
      begin
        J := I + 1;
        while (J <= Length(Text_)) and (Text_[J] in ['a'..'z', 'A'..'Z', '0'..'9', '_']) do
          Inc(J);
        L.Add(Copy(Text_, I + 1, J - I - 1));
        I := J;
      end
      else
        Inc(I);
    end;
    Result := nil;
    SetLength(Result, L.Count);
    for I := 0 to L.Count - 1 do
      Result[I] := L[I];
  finally
    L.Free;
  end;
end;

procedure BuildBuiltIn;
var
  I: Integer;
begin
  GBuiltIn := TStringList.Create;
  for I := 0 to High(BuiltIn) do
    GBuiltIn.Add(BuiltIn[I]);
end;

initialization
  BuildBuiltIn;

finalization
  ClearLang;
  GBuiltIn.Free;

end.
