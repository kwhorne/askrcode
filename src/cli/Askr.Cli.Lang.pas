{ Askr.Cli.Lang — `askr lang:check`: whether the lang files agree.

  The base is app.fallback_locale, English by default: the framework's
  compiled-in English with lang/<base>.toml laid over it. Every other
  locale is held against it, both ways:

    * a key the base has and the locale lacks -- which a reader of that
      language would see in English;
    * a key the locale has and the base does not -- almost always a typo,
      which is never looked up and never says so;
    * a :placeholder in a translation that nothing passes, which would be
      shown to the reader as it is written.

  A plural -- a key whose forms are CLDR categories, app.items.one and
  app.items.other -- is held against the language's own rules instead of
  the base's keys: Polish needs few and many, which English does not have,
  and Norwegian never picks few, so a few in nb.toml is dead text. The
  base is held against its own rules the same way: an English one that is
  missing makes "1 items".

  One direction alone lets the other half rot: a check for missing keys
  passes a file full of misspelled ones. }
unit Askr.Cli.Lang;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, Askr.Core.Lang, Askr.Core.Format;

{ The report, line by line, and False when there is anything to fix.
  Reads the configuration that is loaded -- app.fallback_locale -- and
  the files under Root/lang. }
function LangCheck(const Root: string; out Report: TStringArray): Boolean;

implementation

procedure Say(var A: TStringArray; const S: string);
begin
  SetLength(A, Length(A) + 1);
  A[High(A)] := S;
end;

function Has(const L: TStringArray; const S: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(L) do
    if L[I] = S then
      Exit(True);
  Result := False;
end;

{ The placeholders in Text_ that Known does not pass. }
function Unknown(const Text_, Known: string): string;
var
  Mine, Theirs: TStringArray;
  I: Integer;
begin
  Result := '';
  Mine := PlaceholdersOf(Text_);
  Theirs := PlaceholdersOf(Known);
  { :count comes with every plural, whether or not the base's text uses it. }
  SetLength(Theirs, Length(Theirs) + 1);
  Theirs[High(Theirs)] := 'count';
  for I := 0 to High(Mine) do
    if not Has(Theirs, Mine[I]) then
    begin
      if Result <> '' then
        Result := Result + ', ';
      Result := Result + ':' + Mine[I];
    end;
end;

{ A [format] key: each locale's own, from ICU, so it is never missing from
  another -- but a misspelled one is text nothing reads. True when Key is
  under format., having said so when the name is not one Askr reads. }
function FormatKey(const Key, Path_: string; var Report: TStringArray;
  var Bad: Integer): Boolean;
begin
  Result := Copy(Key, 1, 7) = 'format.';
  if Result and not IsFormatKey(Copy(Key, 8, MaxInt)) then
  begin
    Say(Report, Format('%s has %s, which is not a format Askr reads -- %s are',
      [Path_, Key, FormatKeyNames]));
    Inc(Bad);
  end;
end;

{ app.items.few -> app.items and few, when the last part is a category. }
function SplitForm(const Key: string; out Group, Form: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  I := LastDelimiter('.', Key);
  if I <= 1 then
    Exit;
  Group := Copy(Key, 1, I - 1);
  Form := Copy(Key, I + 1, MaxInt);
  Result := IsPluralCategory(Form);
end;

{ The plurals in Known: groups with an 'other', every key under which is a
  category. }
function PluralGroups(Known: TStringList): TStringList;
var
  I, J: Integer;
  Group, Form: string;
  AllForms: Boolean;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  Result.Duplicates := dupIgnore;
  for I := 0 to Known.Count - 1 do
    if SplitForm(Known.Names[I], Group, Form) and (Form = 'other') then
    begin
      AllForms := True;
      for J := 0 to Known.Count - 1 do
        if (Copy(Known.Names[J], 1, Length(Group) + 1) = Group + '.') and
           not IsPluralCategory(Copy(Known.Names[J], Length(Group) + 2, MaxInt)) then
          AllForms := False;
      if AllForms then
        Result.Add(Group);
    end;
end;

function InGroup(Groups: TStringList; const Key: string): Boolean;
var
  Group, Form: string;
begin
  Result := (SplitForm(Key, Group, Form) and (Groups.IndexOf(Group) >= 0)) or
    (Groups.IndexOf(Key) >= 0);
end;

function Joined(const L: TStringArray): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(L) do
  begin
    if I > 0 then
      Result := Result + ', ';
    Result := Result + L[I];
  end;
end;

{ Whether T has the plural G at all, as forms or as one text. }
function Mentions(T: TStringList; const G: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to T.Count - 1 do
    if (T.Names[I] = G) or (Copy(T.Names[I], 1, Length(G) + 1) = G + '.') then
      Exit(True);
  Result := False;
end;

{ One file's plurals against its language's rules. OnlyItsOwn for the
  base: the framework's forms are compiled in, and the base file answers
  only for the plurals it writes itself. }
procedure CheckForms(T: TStringList; const Locale, Path_: string;
  Groups, Known: TStringList; OnlyItsOwn: Boolean; var Report: TStringArray;
  var Bad: Integer);
var
  G, C, Flat, BaseOther: string;
  Cats: TStringArray;
  I, J, K: Integer;
  Group, Form: string;
begin
  Cats := PluralCategories(Locale);
  if not HasPluralRules(Locale) then
    for I := 0 to Groups.Count - 1 do
      if T.IndexOfName(Groups[I] + '.other') >= 0 then
      begin
        Say(Report, Format('%s: there are no plural rules here for %s, so its ' +
          'plurals follow English: one for 1, other for the rest', [Path_, Locale]));
        Break;
      end;
  for I := 0 to Groups.Count - 1 do
  begin
    G := Groups[I];
    if OnlyItsOwn and not Mentions(T, G) then
      Continue;
    K := Known.IndexOfName(G + '.other');
    BaseOther := '';
    if K >= 0 then
      BaseOther := Known.ValueFromIndex[K];
    Flat := '';
    J := T.IndexOfName(G);
    if J >= 0 then
      Flat := T.ValueFromIndex[J];
    { A language with one form may give it as the key itself. }
    if (Flat <> '') and (Length(Cats) = 1) then
      Continue;
    if Flat <> '' then
    begin
      Say(Report, Format('%s: %s is one text for every count, and %s picks %s',
        [Path_, G, Locale, Joined(Cats)]));
      Inc(Bad);
      Continue;
    end;
    for J := 0 to High(Cats) do
    begin
      C := Cats[J];
      if T.IndexOfName(G + '.' + C) >= 0 then
        Continue;
      if C = 'other' then
        Say(Report, Format('%s lacks %s.other, the form every language falls back to',
          [Path_, G]))
      else
        Say(Report, Format('%s lacks %s.%s -- %s picks %s for %s',
          [Path_, G, C, Locale, C, PluralExamples(Locale, C)]));
      Inc(Bad);
    end;
    for J := 0 to T.Count - 1 do
      if SplitForm(T.Names[J], Group, Form) and (Group = G) then
      begin
        if not Has(Cats, Form) then
        begin
          Say(Report, Format('%s has %s, which %s never picks for a whole number, ' +
            'so nothing shows it', [Path_, T.Names[J], Locale]));
          Inc(Bad);
        end
        else if (BaseOther <> '') and (Unknown(T.ValueFromIndex[J], BaseOther) <> '') then
        begin
          Say(Report, Format('%s: %s uses %s, which nothing passes, so it would ' +
            'be shown as written', [Path_, T.Names[J], Unknown(T.ValueFromIndex[J], BaseOther)]));
          Inc(Bad);
        end;
      end;
  end;
end;

function LangCheck(const Root: string; out Report: TStringArray): Boolean;
var
  Dir, Base, BasePath, Path_, Key, Text_, Extra: string;
  Found, Known, T, Groups: TStringList;
  Files: array of TStringList;
  Problems: TLangProblems;
  SR: TSearchRec;
  I, J, K, Bad, BaseIdx: Integer;
  BuiltIn: TStringArray;
begin
  Report := nil;
  Problems := nil;
  Bad := 0;
  Dir := IncludeTrailingPathDelimiter(Root) + 'lang' + PathDelim;
  if not DirectoryExists(Dir) then
  begin
    Say(Report, 'There is no lang directory, so every message is the framework''s English.');
    Exit(True);
  end;

  Base := FallbackLocale;
  Found := TStringList.Create;
  Known := TStringList.Create;
  Groups := nil;
  Files := nil;
  try
    Found.Sorted := True;
    if FindFirst(Dir + '*.toml', faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Attr and faDirectory) = 0 then
          Found.Add(SR.Name);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;

    SetLength(Files, Found.Count);
    BaseIdx := -1;
    for I := 0 to Found.Count - 1 do
    begin
      Files[I] := TStringList.Create;
      ReadLangFile(Dir + Found[I], Files[I], Problems);
      if ChangeFileExt(Found[I], '') = Base then
        BaseIdx := I;
    end;
    for I := 0 to High(Problems) do
    begin
      Say(Report, Format('lang/%s:%d %s', [ExtractFileName(Problems[I].Path),
        Problems[I].Line, Problems[I].Message]));
      Inc(Bad);
    end;

    { The base: the framework's English, and the base file over it. }
    BuiltIn := BuiltInTexts;
    for I := 0 to High(BuiltIn) do
      Known.Add(BuiltIn[I]);
    BasePath := 'lang/' + Base + '.toml';
    if BaseIdx >= 0 then
    begin
      T := Files[BaseIdx];
      for J := 0 to T.Count - 1 do
      begin
        Key := T.Names[J];
        Text_ := T.ValueFromIndex[J];
        if FormatKey(Key, BasePath, Report, Bad) then
          Continue;
        K := Known.IndexOfName(Key);
        if K >= 0 then
        begin
          Extra := Unknown(Text_, Known.ValueFromIndex[K]);
          if Extra <> '' then
          begin
            Say(Report, Format('%s: %s uses %s, which the framework does not pass, ' +
              'so it would be shown as written', [BasePath, Key, Extra]));
            Inc(Bad);
          end;
          Known.Delete(K);
        end;
        Known.Add(Key + '=' + Text_);
      end;
    end;
    Groups := PluralGroups(Known);
    if BaseIdx >= 0 then
      CheckForms(Files[BaseIdx], Base, BasePath, Groups, Known, True, Report, Bad);

    for I := 0 to Found.Count - 1 do
    begin
      if I = BaseIdx then
        Continue;
      Path_ := 'lang/' + Found[I];
      T := Files[I];
      for J := 0 to Known.Count - 1 do
        if not InGroup(Groups, Known.Names[J]) and
           (T.IndexOfName(Known.Names[J]) < 0) then
        begin
          Say(Report, Format('%s lacks %s -- in %s: %s',
            [Path_, Known.Names[J], Base, Known.ValueFromIndex[J]]));
          Inc(Bad);
        end;
      for J := 0 to T.Count - 1 do
      begin
        Key := T.Names[J];
        if InGroup(Groups, Key) or FormatKey(Key, Path_, Report, Bad) then
          Continue;
        K := Known.IndexOfName(Key);
        if K < 0 then
        begin
          Say(Report, Format('%s has %s, which neither %s nor the framework has, ' +
            'so nothing looks it up', [Path_, Key, BasePath]));
          Inc(Bad);
          Continue;
        end;
        Extra := Unknown(T.ValueFromIndex[J], Known.ValueFromIndex[K]);
        if Extra <> '' then
        begin
          Say(Report, Format('%s: %s uses %s, which %s does not, so nothing ' +
            'passes it and it would be shown as written', [Path_, Key, Extra, Base]));
          Inc(Bad);
        end;
      end;
      CheckForms(T, ChangeFileExt(Found[I], ''), Path_, Groups, Known, False, Report, Bad);
    end;

    if Bad = 0 then
      Say(Report, Format('lang:check holds: %d locale(s) against %s, %d key(s).',
        [Found.Count, Base, Known.Count]))
    else
      Say(Report, Format('lang:check found %d thing(s) to fix.', [Bad]));
    Result := Bad = 0;
  finally
    for I := 0 to High(Files) do
      Files[I].Free;
    Groups.Free;
    Known.Free;
    Found.Free;
  end;
end;

end.
