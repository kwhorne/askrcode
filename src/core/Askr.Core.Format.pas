{ Askr.Core.Format — numbers and dates in the reader's format.

      LocaleNumber(1234567)          1,234,567      1 234 567 (nb)
      LocaleDecimal(3.14159, 2)      3.14           3,14
      LocaleDate(D)                  Jan 5, 2026    5. jan. 2026
      LocaleDate(D, dsLong)          January 5, 2026
      LocaleTime(D)                  2:07 PM        14:07
      LocaleDateTime(D)              Jan 5, 2026, 2:07 PM

  In the locale of the request -- CurrentLocale -- with the data ICU has
  for it, generated into Askr.Core.LangData by tools/lang/formats.mjs and
  held against ICU's own output by the vectors in tests/vectors. A
  locale's lang file can say otherwise under [format]: decimal, group,
  minus, date_short, date_medium, date_long, datetime_short,
  datetime_medium, datetime_long, time_short, time_medium, months_short,
  months_medium, months_long, am, pm.

  A locale there is no data for uses its language's, and then English's.
  Dates are Gregorian and taken as they are: a TDateTime has no time zone,
  and nothing here gives it one. }
unit Askr.Core.Format;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Askr.Core.Lang, Askr.Core.LangData;

type
  TDateStyle = (dsShort, dsMedium, dsLong);

{ A whole number, grouped as the locale groups it. }
function LocaleNumber(V: Int64): string;
{ A number with exactly Decimals places, rounded. }
function LocaleDecimal(V: Extended; Decimals: Integer): string;
{ Money, exact: Currency is a scaled integer, and going through a float
  would round it twice. Decimals -1 writes as many as it has, and no
  trailing zeros. }
function LocaleCurrency(V: Currency; Decimals: Integer = -1): string;
{ A decimal written with a dot and no grouping -- "-1234.5" -- in the
  locale's separators and minus. What the others go through. }
function LocalizeDecimalText(const Plain: string): string;

function LocaleDate(D: TDateTime; Style: TDateStyle = dsMedium): string;
function LocaleTime(D: TDateTime; WithSeconds: Boolean = False): string;
function LocaleDateTime(D: TDateTime; Style: TDateStyle = dsMedium): string;

{ The data for Locale: its own, its language's, or English's. Exposed for
  the test, which holds each against ICU. }
function FormatDataFor(const Locale: string): TLocaleFormat;
{ The [format] keys a lang file may give. lang:check reads it. }
function IsFormatKey(const Name: string): Boolean;
{ The same keys as a sentence -- "decimal, group, ... am and pm" -- so a
  message listing them cannot drift from the list. }
function FormatKeyNames: string;

implementation

const
  FormatKeys: array[0..15] of string = ('decimal', 'group', 'minus',
    'date_short', 'date_medium', 'date_long', 'datetime_short',
    'datetime_medium', 'datetime_long', 'time_short', 'time_medium',
    'months_short', 'months_medium', 'months_long', 'am', 'pm');

function IsFormatKey(const Name: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FormatKeys) do
    if FormatKeys[I] = Name then
      Exit(True);
  Result := False;
end;

function FormatKeyNames: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(FormatKeys) do
  begin
    if I = High(FormatKeys) then
      Result := Result + ' and '
    else if I > 0 then
      Result := Result + ', ';
    Result := Result + FormatKeys[I];
  end;
end;

function Norm(const Tag: string): string;
begin
  Result := LowerCase(StringReplace(Tag, '_', '-', [rfReplaceAll]));
end;

function IndexOfTag(const Tag: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(LocaleFormats) do
    if Norm(LocaleFormats[I].Tag) = Tag then
      Exit(I);
  Result := -1;
end;

function MonthName(const List: string; Month: Integer): string; forward;

{ A day-period table from the lang file's am and pm, keeping what the file
  leaves out. }
function HalfDays(const Table, Locale: string): string;
var
  Am, Pm, V: string;
  H: Integer;
begin
  Am := MonthName(Table, 1);
  Pm := MonthName(Table, 13);
  if LangFileText(Locale, 'format.am', V) then
    Am := V;
  if LangFileText(Locale, 'format.pm', V) then
    Pm := V;
  Result := '';
  for H := 0 to 23 do
  begin
    if H > 0 then
      Result := Result + '|';
    if H < 12 then
      Result := Result + Am
    else
      Result := Result + Pm;
  end;
end;

function FormatDataFor(const Locale: string): TLocaleFormat;
var
  T, V: string;
  I: Integer;

  procedure Pick(const Key: string; var Field: string);
  begin
    if LangFileText(Locale, 'format.' + Key, V) then
      Field := V;
  end;

begin
  T := Norm(Locale);
  I := IndexOfTag(T);
  if (I < 0) and (Pos('-', T) > 0) then
    I := IndexOfTag(Copy(T, 1, Pos('-', T) - 1));
  if I < 0 then
    I := IndexOfTag('en');
  Result := LocaleFormats[I];
  Pick('decimal', Result.Decimal);
  Pick('group', Result.Group);
  Pick('minus', Result.Minus);
  Pick('date_short', Result.DateShort);
  Pick('date_medium', Result.DateMedium);
  Pick('date_long', Result.DateLong);
  Pick('datetime_short', Result.DateTimeShort);
  Pick('datetime_medium', Result.DateTimeMedium);
  Pick('datetime_long', Result.DateTimeLong);
  Pick('time_short', Result.TimeShort);
  Pick('time_medium', Result.TimeMedium);
  Pick('months_short', Result.MonthsShort);
  Pick('months_medium', Result.MonthsMedium);
  Pick('months_long', Result.MonthsLong);
  { am and pm, for a language whose day has two halves; the table has one
    word per hour, so they fill it. }
  if LangFileText(Locale, 'format.am', V) or LangFileText(Locale, 'format.pm', V) then
    Result.DayPeriods := HalfDays(Result.DayPeriods, Locale);
end;

function LocalizeDecimalText(const Plain: string): string;
var
  F: TLocaleFormat;
  Neg: Boolean;
  S, IntPart, Frac, Grouped: string;
  Dot, I, Count: Integer;
begin
  F := FormatDataFor(CurrentLocale);
  S := Plain;
  Neg := (S <> '') and (S[1] = '-');
  if Neg then
    Delete(S, 1, 1);
  Dot := Pos('.', S);
  if Dot > 0 then
  begin
    IntPart := Copy(S, 1, Dot - 1);
    Frac := Copy(S, Dot + 1, MaxInt);
  end
  else
  begin
    IntPart := S;
    Frac := '';
  end;
  { Grouped from four digits, or from five where the locale waits: Polish
    and Spanish write 1000 but 10 000. }
  Grouped := IntPart;
  if (F.Group <> '') and ((Length(IntPart) >= 5) or
     ((Length(IntPart) = 4) and (F.MinGrouping = 1))) then
  begin
    Grouped := '';
    Count := 0;
    for I := Length(IntPart) downto 1 do
    begin
      if (Count > 0) and (Count mod 3 = 0) then
        Grouped := F.Group + Grouped;
      Grouped := IntPart[I] + Grouped;
      Inc(Count);
    end;
  end;
  Result := Grouped;
  if Frac <> '' then
    Result := Result + F.Decimal + Frac;
  if Neg then
    Result := F.Minus + Result;
end;

function LocaleNumber(V: Int64): string;
begin
  Result := LocalizeDecimalText(IntToStr(V));
end;

function DotSettings: TFormatSettings;
begin
  Result := DefaultFormatSettings;
  Result.DecimalSeparator := '.';
  Result.ThousandSeparator := #0;
end;

function LocaleDecimal(V: Extended; Decimals: Integer): string;
begin
  if Decimals < 0 then
    Decimals := 0;
  { FloatToStrF writes -0.001 to two places as 0.00, not -0.00, on both
    architectures; the test holds it to that rather than a guard here
    that nothing could reach. }
  Result := LocalizeDecimalText(FloatToStrF(V, ffFixed, 18, Decimals, DotSettings));
end;

function LocaleCurrency(V: Currency; Decimals: Integer): string;
var
  S: string;
begin
  if Decimals >= 0 then
    S := CurrToStrF(V, ffFixed, Decimals, DotSettings)
  else
  begin
    S := CurrToStrF(V, ffFixed, 4, DotSettings);
    while (Pos('.', S) > 0) and (S[Length(S)] = '0') do
      Delete(S, Length(S), 1);
    if (S <> '') and (S[Length(S)] = '.') then
      Delete(S, Length(S), 1);
  end;
  Result := LocalizeDecimalText(S);
end;

{ ------------------------------------------------------------- dates -- }

{ The Nth name in a list joined with |: a month, or a day period. }
function MonthName(const List: string; Month: Integer): string;
var
  I, Start, N: Integer;
begin
  Result := '';
  N := 1;
  Start := 1;
  for I := 1 to Length(List) + 1 do
    if (I > Length(List)) or (List[I] = '|') then
    begin
      if N = Month then
        Exit(Copy(List, Start, I - Start));
      Inc(N);
      Start := I + 1;
    end;
end;

function Pad(V: Integer; Width: Integer): string;
begin
  Result := IntToStr(V);
  while Length(Result) < Width do
    Result := '0' + Result;
end;

(* Pattern with each {token} replaced from D -- in the star form, because a
   brace inside a brace comment opens a nested one. *)
function Render(const Pattern, Months: string; D: TDateTime;
  const F: TLocaleFormat): string;
var
  Y, M, Dd, H, Mi, S, Ms: Word;
  I, J: Integer;
  Tok, V: string;
begin
  DecodeDate(D, Y, M, Dd);
  DecodeTime(D, H, Mi, S, Ms);
  Result := '';
  I := 1;
  while I <= Length(Pattern) do
  begin
    if Pattern[I] <> '{' then
    begin
      Result := Result + Pattern[I];
      Inc(I);
      Continue;
    end;
    J := I + 1;
    while (J <= Length(Pattern)) and (Pattern[J] <> '}') do
      Inc(J);
    Tok := Copy(Pattern, I + 1, J - I - 1);
    I := J + 1;
    if Tok = 'yyyy' then V := Pad(Y, 4)
    else if Tok = 'yy' then V := Pad(Y mod 100, 2)
    else if Tok = 'M' then V := IntToStr(M)
    else if Tok = 'MM' then V := Pad(M, 2)
    else if Tok = 'MMMM' then
    begin
      Result := Result + MonthName(Months, M);
      Continue;
    end
    else if Tok = 'd' then V := IntToStr(Dd)
    else if Tok = 'dd' then V := Pad(Dd, 2)
    else if Tok = 'H' then V := IntToStr(H)
    else if Tok = 'HH' then V := Pad(H, 2)
    else if (Tok = 'h') or (Tok = 'hh') then
    begin
      if H mod 12 = 0 then
        V := '12'
      else
        V := IntToStr(H mod 12);
      if Tok = 'hh' then
        V := Pad(StrToInt(V), 2);
    end
    else if Tok = 'K' then V := IntToStr(H mod 12)
    else if Tok = 'KK' then V := Pad(H mod 12, 2)
    else if Tok = 'mm' then V := Pad(Mi, 2)
    else if Tok = 'ss' then V := Pad(S, 2)
    else if Tok = 'a' then
    begin
      Result := Result + MonthName(F.DayPeriods, H + 1);
      Continue;
    end
    else
    begin
      { A token nothing here knows is left as written, where it is seen. }
      Result := Result + '{' + Tok + '}';
      Continue;
    end;
    Result := Result + V;
  end;
end;

function LocaleDate(D: TDateTime; Style: TDateStyle): string;
var
  F: TLocaleFormat;
begin
  F := FormatDataFor(CurrentLocale);
  case Style of
    dsShort: Result := Render(F.DateShort, F.MonthsShort, D, F);
    dsMedium: Result := Render(F.DateMedium, F.MonthsMedium, D, F);
    dsLong: Result := Render(F.DateLong, F.MonthsLong, D, F);
  end;
end;

function LocaleTime(D: TDateTime; WithSeconds: Boolean): string;
var
  F: TLocaleFormat;
begin
  F := FormatDataFor(CurrentLocale);
  if WithSeconds then
    Result := Render(F.TimeMedium, '', D, F)
  else
    Result := Render(F.TimeShort, '', D, F);
end;

function LocaleDateTime(D: TDateTime; Style: TDateStyle): string;
var
  F: TLocaleFormat;
begin
  F := FormatDataFor(CurrentLocale);
  case Style of
    dsShort: Result := Render(F.DateTimeShort, F.MonthsShort, D, F);
    dsMedium: Result := Render(F.DateTimeMedium, F.MonthsMedium, D, F);
    dsLong: Result := Render(F.DateTimeLong, F.MonthsLong, D, F);
  end;
end;

end.
