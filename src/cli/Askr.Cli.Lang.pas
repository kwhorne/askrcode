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

  One direction alone lets the other half rot: a check for missing keys
  passes a file full of misspelled ones. }
unit Askr.Cli.Lang;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, Askr.Core.Lang;

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
  for I := 0 to High(Mine) do
    if not Has(Theirs, Mine[I]) then
    begin
      if Result <> '' then
        Result := Result + ', ';
      Result := Result + ':' + Mine[I];
    end;
end;

function LangCheck(const Root: string; out Report: TStringArray): Boolean;
var
  Dir, Base, BasePath, Path_, Locale, Key, Text_, Extra: string;
  Found, Known, T: TStringList;
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

    { The base: the framework's English, and the base file over it. A
      placeholder the base file uses where the framework passes none is
      a problem there too. }
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

    for I := 0 to Found.Count - 1 do
    begin
      if I = BaseIdx then
        Continue;
      Locale := ChangeFileExt(Found[I], '');
      Path_ := 'lang/' + Found[I];
      T := Files[I];
      for J := 0 to Known.Count - 1 do
        if T.IndexOfName(Known.Names[J]) < 0 then
        begin
          Say(Report, Format('%s lacks %s -- in %s: %s',
            [Path_, Known.Names[J], Base, Known.ValueFromIndex[J]]));
          Inc(Bad);
        end;
      for J := 0 to T.Count - 1 do
      begin
        Key := T.Names[J];
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
    Known.Free;
    Found.Free;
  end;
end;

end.
