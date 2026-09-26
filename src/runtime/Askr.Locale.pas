{ Askr.Locale — which language a request is answered in.

      UseSessions(R);
      UseLocales(R);     { after the sessions: a choice is kept in one }

  The locale is, in this order: the one the visitor chose, kept in the
  session under 'locale'; the best of Accept-Language that there is a
  lang file for; and app.locale. A locale nobody wrote a file for is only
  chosen when it is app.locale -- English needs no file, because the
  framework's English is compiled in.

  The answer says which it used, in Content-Language, and says Vary:
  Accept-Language when the header decided it, so a cache in between does
  not hand a Norwegian page to the next English visitor. }
unit Askr.Locale;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes,
  Askr.Core.Text, Askr.Core.Lang,
  Askr.Http.Request, Askr.Http.Response, Askr.Http.Router;

{ Sets the locale for every request, and clears it after. }
procedure UseLocales(R: TRouter);

{ The visitor's choice, for a "change language" handler: kept in the
  session and used for the rest of this request. False, and nothing
  kept, for a locale there is no file for -- a choice nothing can answer
  in is not a choice. Needs UseSessions. }
function SetLocale(const Locale: string): Boolean;

{ The best of an Accept-Language header among the locales there are,
  or '' when none of them was asked for. Exposed for the test. }
function NegotiateLocale(const AcceptLanguage: string): string;

implementation

uses
  Askr.Session;

const
  SessionKey = 'locale';

{ A locale answers when there is a file for it, or it is the default. }
function Answerable(const Locale: string): Boolean;
begin
  Result := (Locale <> '') and (HasLocale(Locale) or (Locale = DefaultLocale));
end;

{ The locale as it is spelled here, for a tag as a browser sends it:
  nb-NO finds nb-NO, nb_NO or, failing both, nb. '' when none. }
function Match(const Tag: string): string;
var
  L: TStringArray;
  I: Integer;
  T, Primary, Dash: string;
begin
  Result := '';
  T := LowerCase(Tag);
  Dash := StringReplace(T, '_', '-', [rfReplaceAll]);
  L := Locales;
  SetLength(L, Length(L) + 1);
  L[High(L)] := DefaultLocale;
  for I := 0 to High(L) do
    if LowerCase(StringReplace(L[I], '_', '-', [rfReplaceAll])) = Dash then
      Exit(L[I]);
  Primary := Dash;
  if Pos('-', Primary) > 0 then
    Primary := Copy(Primary, 1, Pos('-', Primary) - 1);
  for I := 0 to High(L) do
    if LowerCase(L[I]) = Primary then
      Exit(L[I]);
end;

function NegotiateLocale(const AcceptLanguage: string): string;
var
  Items: TStringList;
  Part, Tag, QText: string;
  I, J, Semi, BestIndex: Integer;
  Q, BestQ: Double;
  Found: string;
  Fmt: TFormatSettings;
begin
  Result := '';
  Fmt := DefaultFormatSettings;
  Fmt.DecimalSeparator := '.';
  Items := TStringList.Create;
  try
    Items.StrictDelimiter := True;
    Items.Delimiter := ',';
    Items.DelimitedText := AcceptLanguage;
    BestQ := 0;
    BestIndex := MaxInt;
    for I := 0 to Items.Count - 1 do
    begin
      Part := Trim(Items[I]);
      if Part = '' then
        Continue;
      Q := 1;
      Semi := Pos(';', Part);
      Tag := Part;
      if Semi > 0 then
      begin
        Tag := Trim(Copy(Part, 1, Semi - 1));
        QText := Trim(Copy(Part, Semi + 1, MaxInt));
        J := Pos('q=', LowerCase(QText));
        if J > 0 then
          Q := StrToFloatDef(Trim(Copy(QText, J + 2, MaxInt)), 0, Fmt);
      end;
      { q=0 means "not this one". }
      if (Q <= 0) or (Tag = '*') then
        Continue;
      Found := Match(Tag);
      if (Found = '') or not Answerable(Found) then
        Continue;
      { The highest q wins; between equals, the one written first. }
      if (Q > BestQ) or ((Q = BestQ) and (I < BestIndex)) then
      begin
        BestQ := Q;
        BestIndex := I;
        Result := Found;
      end;
    end;
  finally
    Items.Free;
  end;
end;

threadvar
  GNegotiated: Boolean;

type
  { Middleware are function pointers, and Pascal has no closures. }
  TLocaleHook = class
    class function Start(Req: TRequest): TResponse;
    class function Finish(Req: TRequest; Res: TResponse): TResponse;
  end;

class function TLocaleHook.Start(Req: TRequest): TResponse;
var
  Chosen: string;
  S: TSession;
begin
  Result := nil;
  GNegotiated := False;
  Chosen := '';
  S := CurrentSession;
  if (S <> nil) and Answerable(S.Get(SessionKey)) then
    Chosen := S.Get(SessionKey);
  if Chosen = '' then
  begin
    Chosen := NegotiateLocale(Req.Header('accept-language').ToString);
    GNegotiated := True;
  end;
  if Chosen = '' then
    Chosen := DefaultLocale;
  UseLocale(Chosen);
end;

class function TLocaleHook.Finish(Req: TRequest; Res: TResponse): TResponse;
begin
  Result := Res;
  if Res <> nil then
  begin
    Res.WithHeader('Content-Language', CurrentLocale);
    { Added, not set: Inertia's Vary: X-Inertia is already there, and
      WithHeader would have replaced it. }
    if GNegotiated then
      Res.AddHeader('Vary', 'Accept-Language');
  end;
  { Cleared, like the session's threadvar: the next request on this
    worker starts from the default, not from this visitor's choice. }
  UseLocale('');
  GNegotiated := False;
end;

procedure UseLocales(R: TRouter);
begin
  R.Use(TLocaleHook.Start);
  R.After(TLocaleHook.Finish);
end;

function SetLocale(const Locale: string): Boolean;
var
  S: TSession;
begin
  Result := Answerable(Locale);
  if not Result then
    Exit;
  S := CurrentSession;
  if S <> nil then
    S.Put(SessionKey, Locale);
  UseLocale(Locale);
end;

end.
