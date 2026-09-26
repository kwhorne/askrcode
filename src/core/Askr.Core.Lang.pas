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
{ The text one argument to Trans is written as. Exported for what fills
  placeholders the same way -- a mail template. }
function ArgText(const V: TVarRec): string;
function Trans(const Key: string): string; overload;
function Trans(const Key: string; const Args: array of const): string; overload;

{ The text for Key in the form the language uses for Count:

      [app.items]
      one = ":count item"
      other = ":count items"

      TransCount('app.items', N)

  The forms are CLDR's categories -- zero, one, two, few, many, other --
  and PluralCategory says which one a language picks for a number. In each
  locale the form is looked up, then its 'other', then Key on its own for
  a language with one form for every count; the fallback locale is asked
  by its own rules, and the framework's English last. :count is filled in
  without being passed. }
function TransCount(const Key: string; Count: Int64): string; overload;
function TransCount(const Key: string; Count: Int64;
  const Args: array of const): string; overload;

{ Which of CLDR's categories Locale's language picks for Count, for whole
  numbers. A language without rules here gets English's: one for 1, other
  for the rest -- HasPluralRules says whether there were rules. }
function PluralCategory(const Locale: string; Count: Int64): string;
{ The categories Locale's language can pick for a whole number, and
  'other', which every language has as the last resort. }
function PluralCategories(const Locale: string): TStringArray;
function HasPluralRules(const Locale: string): Boolean;
{ A few whole numbers Locale's language puts in Category, for a message:
  '2, 3, 4, 22'. }
function PluralExamples(const Locale, Category: string): string;
{ Whether Name is one of CLDR's six categories. }
function IsPluralCategory(const Name: string): Boolean;

{ The text Locale's own file has for Key, and nothing else: no fallback
  and no built-in English. The [format] overrides are read with it. }
function LangFileText(const Locale, Key: string; out Text_: string): Boolean;

{ Whether Locale's file has Key -- the file, not the built-in English. }
function HasTrans(const Locale, Key: string): Boolean;

{ What a column is called in a message: validation.attributes.<column>
  in the current locale, and the column itself when nothing says. }
function AttributeName(const Column: string): string;

{ The keys and English text the framework is compiled with, as
  key=value lines. askr lang:check reads them to say what a locale
  lacks. }
function BuiltInTexts: TStringArray;

{ The texts under Prefix -- 'lauf' -- in the current locale, as
  key=value without the prefix, where they say something other than the
  framework's English. Empty when nothing does, which is the common case:
  a page in English carries none of it. }
function ChangedTextsUnder(const Prefix: string): TStringArray;

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
  BuiltIn: array[0..65] of string = (
    'validation.required=:attribute is required',
    'validation.min_length.one=:attribute must be at least :min character',
    'validation.min_length.other=:attribute must be at least :min characters',
    'validation.max_length.one=:attribute can be at most :max character',
    'validation.max_length.other=:attribute can be at most :max characters',
    'validation.email=:attribute is not a valid email address',
    'validation.min=:attribute cannot be less than :min',
    'validation.max=:attribute cannot be greater than :max',
    'validation.between=:attribute must be between :min and :max',
    'validation.one_of=:attribute has a value that is not allowed',
    'validation.same_as=:attribute does not match :other',
    'validation.unique=:attribute is already taken',
    'validation.exists=:attribute does not match a row in :table',
    'validation.ids_exist=:attribute contains :ids, which does not match a row in :table',
    'validation.ids_list=:attribute must be a list of ids, and :value is not one',
    { Lauf's own words -- the same keys and English as
      frontend/lauf/src/strings.js, held equal by a test, so a lang file's
      [lauf] section is checked by lang:check like the rest. }
    'lauf.close=Close',
    'lauf.dismiss=Dismiss',
    'lauf.breadcrumb=Breadcrumb',
    'lauf.main_navigation=Main',
    'lauf.sidebar=Sidebar',
    'lauf.pagination=Pagination',
    'lauf.previous_page=Previous page',
    'lauf.next_page=Next page',
    'lauf.no_results=No results',
    'lauf.range_of=:from–:to of :total',
    'lauf.show_suggestions=Show suggestions',
    'lauf.type_a_command=Type a command…',
    'lauf.commands=Commands',
    'lauf.choose_date=Choose date',
    'lauf.previous_month=Previous month',
    'lauf.next_month=Next month',
    'lauf.nothing_here=Nothing here',
    'lauf.search=Search',
    'lauf.search_in=Search :caption',
    'lauf.columns=Columns',
    'lauf.select_all_rows=Select all rows on this page',
    'lauf.select_row=Select row :n',
    'lauf.selected_count=:count selected',
    'lauf.pages_of=:caption pages',
    'lauf.formatting=Formatting',
    'lauf.heading_1=Heading 1',
    'lauf.heading_2=Heading 2',
    'lauf.heading_3=Heading 3',
    'lauf.bold=Bold',
    'lauf.italic=Italic',
    'lauf.strikethrough=Strikethrough',
    'lauf.code=Code',
    'lauf.quote=Quote',
    'lauf.bulleted_list=Bulleted list',
    'lauf.numbered_list=Numbered list',
    'lauf.link=Link',
    'lauf.undo=Undo',
    'lauf.redo=Redo',
    'lauf.show_preview=Show preview',
    'lauf.hide_preview=Hide preview',
    'lauf.preview=Preview',
    'lauf.nothing_to_preview=Nothing to preview yet.',
    'lauf.bold_text=bold text',
    'lauf.italic_text=italic text',
    'lauf.struck_text=struck out',
    'lauf.code_text=code',
    'lauf.choose_file=Choose a file',
    'lauf.choose_files=Choose files',
    'lauf.or_drag=or drag them here',
    'lauf.too_large=Too large, not added: :names',
    'lauf.remove_file=Remove :name'
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

{ Text_ with each :name in Args replaced, longest name first so :min never
  takes the front off :minimum. Extra is a name to fill in too, unless
  Args gives it -- :count, for TransCount. }
function Fill(const Text_: string; const Args: array of const;
  const ExtraName, ExtraValue: string): string;
var
  Names, Values: array of string;
  I, J, N, Best: Integer;
  Taken: array of Boolean;
  Given: Boolean;
begin
  Result := Text_;
  N := Length(Args) div 2;
  SetLength(Names, N);
  SetLength(Values, N);
  Given := False;
  for I := 0 to N - 1 do
  begin
    Names[I] := ArgText(Args[I * 2]);
    Values[I] := ArgText(Args[I * 2 + 1]);
    if Names[I] = ExtraName then
      Given := True;
  end;
  if (ExtraName <> '') and not Given then
  begin
    SetLength(Names, N + 1);
    SetLength(Values, N + 1);
    Names[N] := ExtraName;
    Values[N] := ExtraValue;
    Inc(N);
  end;
  SetLength(Taken, N);
  for I := 0 to N - 1 do
    Taken[I] := False;
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

function Trans(const Key: string; const Args: array of const): string;
begin
  Result := Fill(RawText(Key), Args, '', '');
end;

function LangFileText(const Locale, Key: string; out Text_: string): Boolean;
begin
  Text_ := '';
  Result := LookUp(Locale, Key, Text_);
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

{ ------------------------------------------------------------ plurals -- }

const
  PluralNames: array[0..5] of string = ('zero', 'one', 'two', 'few', 'many', 'other');

function IsPluralCategory(const Name: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(PluralNames) do
    if PluralNames[I] = Name then
      Exit(True);
  Result := False;
end;

{ The language a locale's rules follow: nb-NO is nb. Portugal's
  Portuguese keeps its region: it counts differently from Brazil's. }
function PluralLanguage(const Locale: string): string;
var
  L: string;
  I: Integer;
begin
  L := LowerCase(StringReplace(Locale, '_', '-', [rfReplaceAll]));
  if L = 'pt-pt' then
    Exit(L);
  I := Pos('-', L);
  if I > 0 then
    L := Copy(L, 1, I - 1);
  Result := L;
end;

function InList(const S: string; const L: array of string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(L) do
    if L[I] = S then
      Exit(True);
  Result := False;
end;

const
  { One form for every count. }
  OtherOnly: array[0..11] of string = ('ja', 'zh', 'ko', 'th', 'vi', 'id',
    'ms', 'km', 'lo', 'my', 'jv', 'yo');
  { one for 1, other for the rest: English's rule, and the default. }
  OneOther: array[0..22] of string = ('en', 'nb', 'nn', 'no', 'da', 'sv',
    'de', 'nl', 'fi', 'et', 'el', 'hu', 'tr', 'bg', 'af', 'sq', 'eu', 'gl',
    'ka', 'az', 'kk', 'ur', 'sw');

function HasPluralRules(const Locale: string): Boolean;
var
  L: string;
begin
  L := PluralLanguage(Locale);
  Result := InList(L, OtherOnly) or InList(L, OneOther) or
    InList(L, ['fr', 'pt', 'pt-pt', 'es', 'it', 'ca', 'pl', 'ru', 'uk', 'be',
      'cs', 'sk', 'hr', 'sr', 'bs', 'ro', 'lt', 'lv', 'ar', 'he', 'is']);
end;

function PluralCategory(const Locale: string; Count: Int64): string;
var
  L: string;
  n, n10, n100: Int64;
begin
  L := PluralLanguage(Locale);
  n := Abs(Count);
  n10 := n mod 10;
  n100 := n mod 100;
  if InList(L, OtherOnly) then
    Result := 'other'
  { French and Brazilian Portuguese: one for 0 and 1. The others in the
    group: one for 1. All of them: many for a whole million -- "un million
    de", not "un million". }
  else if InList(L, ['fr', 'pt']) then
  begin
    if n <= 1 then
      Result := 'one'
    else if n mod 1000000 = 0 then
      Result := 'many'
    else
      Result := 'other';
  end
  else if InList(L, ['pt-pt', 'es', 'it', 'ca']) then
  begin
    if n = 1 then
      Result := 'one'
    else if (n <> 0) and (n mod 1000000 = 0) then
      Result := 'many'
    else
      Result := 'other';
  end
  else if L = 'pl' then
  begin
    if n = 1 then
      Result := 'one'
    else if (n10 >= 2) and (n10 <= 4) and not ((n100 >= 12) and (n100 <= 14)) then
      Result := 'few'
    else
      Result := 'many';
  end
  else if InList(L, ['ru', 'uk', 'be']) then
  begin
    if (n10 = 1) and (n100 <> 11) then
      Result := 'one'
    else if (n10 >= 2) and (n10 <= 4) and not ((n100 >= 12) and (n100 <= 14)) then
      Result := 'few'
    else
      Result := 'many';
  end
  else if InList(L, ['cs', 'sk']) then
  begin
    if n = 1 then
      Result := 'one'
    else if (n >= 2) and (n <= 4) then
      Result := 'few'
    else
      Result := 'other';
  end
  else if InList(L, ['hr', 'sr', 'bs']) then
  begin
    if (n10 = 1) and (n100 <> 11) then
      Result := 'one'
    else if (n10 >= 2) and (n10 <= 4) and not ((n100 >= 12) and (n100 <= 14)) then
      Result := 'few'
    else
      Result := 'other';
  end
  else if L = 'ro' then
  begin
    if n = 1 then
      Result := 'one'
    { 101 is few: CLDR says n != 1 and n % 100 = 1..19. }
    else if (n = 0) or ((n100 >= 1) and (n100 <= 19)) then
      Result := 'few'
    else
      Result := 'other';
  end
  else if L = 'lt' then
  begin
    if (n10 = 1) and not ((n100 >= 11) and (n100 <= 19)) then
      Result := 'one'
    else if (n10 >= 2) and not ((n100 >= 11) and (n100 <= 19)) then
      Result := 'few'
    else
      Result := 'other';
  end
  else if L = 'lv' then
  begin
    if (n10 = 0) or ((n100 >= 11) and (n100 <= 19)) then
      Result := 'zero'
    else if (n10 = 1) and (n100 <> 11) then
      Result := 'one'
    else
      Result := 'other';
  end
  else if L = 'ar' then
  begin
    if n = 0 then
      Result := 'zero'
    else if n = 1 then
      Result := 'one'
    else if n = 2 then
      Result := 'two'
    else if (n100 >= 3) and (n100 <= 10) then
      Result := 'few'
    else if (n100 >= 11) and (n100 <= 99) then
      Result := 'many'
    else
      Result := 'other';
  end
  else if L = 'he' then
  begin
    if n = 1 then
      Result := 'one'
    else if n = 2 then
      Result := 'two'
    else
      Result := 'other';
  end
  else if L = 'is' then
  begin
    if (n10 = 1) and (n100 <> 11) then
      Result := 'one'
    else
      Result := 'other';
  end
  else if n = 1 then
    Result := 'one'
  else
    Result := 'other';
end;

{ The categories a language reaches, found by asking it -- the rules above
  are the one place they are written. Whole millions are asked about too,
  for the languages with a form for them. }
function PluralCategories(const Locale: string): TStringArray;
var
  Seen: array[0..5] of Boolean;
  I: Integer;
  N: Int64;
  C: string;
begin
  for I := 0 to High(Seen) do
    Seen[I] := False;
  Seen[5] := True;
  for N := 0 to 1100 do
  begin
    C := PluralCategory(Locale, N);
    for I := 0 to High(PluralNames) do
      if PluralNames[I] = C then
        Seen[I] := True;
  end;
  C := PluralCategory(Locale, 1000000);
  for I := 0 to High(PluralNames) do
    if PluralNames[I] = C then
      Seen[I] := True;
  Result := nil;
  for I := 0 to High(PluralNames) do
    if Seen[I] then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := PluralNames[I];
    end;
end;

function PluralExamples(const Locale, Category: string): string;
var
  N: Int64;
  Count: Integer;
begin
  Result := '';
  Count := 0;
  N := 0;
  while (N <= 1100) and (Count < 4) do
  begin
    if PluralCategory(Locale, N) = Category then
    begin
      if Result <> '' then
        Result := Result + ', ';
      Result := Result + IntToStr(N);
      Inc(Count);
    end;
    Inc(N);
  end;
  if (Count = 0) and (PluralCategory(Locale, 1000000) = Category) then
    Result := '1000000';
end;

{ The form for Count in Locale's file: the category, then 'other', then
  Key on its own. }
function LookUpCount(const Locale, Key: string; Count: Int64;
  out Text_: string): Boolean;
begin
  Result := LookUp(Locale, Key + '.' + PluralCategory(Locale, Count), Text_) or
    LookUp(Locale, Key + '.other', Text_) or LookUp(Locale, Key, Text_);
end;

function TransCount(const Key: string; Count: Int64): string;
begin
  Result := TransCount(Key, Count, []);
end;

function TransCount(const Key: string; Count: Int64;
  const Args: array of const): string;
var
  Text_: string;
  I: Integer;
begin
  if not LookUpCount(CurrentLocale, Key, Count, Text_) and
     not LookUpCount(FallbackLocale, Key, Count, Text_) then
  begin
    I := GBuiltIn.IndexOfName(Key + '.' + PluralCategory('en', Count));
    if I < 0 then
      I := GBuiltIn.IndexOfName(Key + '.other');
    if I < 0 then
      I := GBuiltIn.IndexOfName(Key);
    if I >= 0 then
      Text_ := GBuiltIn.ValueFromIndex[I]
    else
      Text_ := Key;
  end;
  Result := Fill(Text_, Args, 'count', IntToStr(Count));
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

function ChangedTextsUnder(const Prefix: string): TStringArray;
var
  I: Integer;
  Key, Text_, Head: string;
begin
  Result := nil;
  Head := Prefix + '.';
  for I := 0 to GBuiltIn.Count - 1 do
  begin
    Key := GBuiltIn.Names[I];
    if Copy(Key, 1, Length(Head)) <> Head then
      Continue;
    Text_ := RawText(Key);
    if Text_ <> GBuiltIn.ValueFromIndex[I] then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Copy(Key, Length(Head) + 1, MaxInt) + '=' + Text_;
    end;
  end;
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
