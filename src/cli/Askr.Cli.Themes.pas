{ Askr.Cli.Themes -- which Lauf theme an app imports.

      askr theme                  the theme now, and the ones there are
      askr theme stone teal       a gray and an accent
      askr theme askr             back to Lauf's own
      askr new shop --theme=stone/teal

  A theme is two files in Lauf, a gray and an accent, imported after
  Lauf's own tokens. The two lines stand between two markers in
  frontend/src/app.css, which askr new writes, and askr theme changes what
  is between them and nothing else. The rest of the file is the app's.
  Without the markers -- somebody removed them, which they may -- it says
  which lines to put in, and writes nothing: a guess at where to put a line
  in a file somebody else wrote is worse than asking.

  The names are the ones scripts/themes.mjs writes files for. A test
  holds the two lists here to Lauf's themes.json, both ways. }
unit Askr.Cli.Themes;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes;

const
  ThemeGrays: array[0..8] of string = (
    'slate', 'gray', 'zinc', 'neutral', 'stone', 'mauve', 'olive', 'mist', 'taupe');
  ThemeAccents: array[0..17] of string = (
    'base', 'red', 'orange', 'amber', 'yellow', 'lime', 'green', 'emerald', 'teal',
    'cyan', 'sky', 'blue', 'indigo', 'violet', 'purple', 'fuchsia', 'pink', 'rose');
  { Lauf's own palette: no theme files at all. }
  DefaultTheme = 'askr';

  ThemeStart = '/* askr theme: the lines from here to the end marker are askr theme''s. */';
  ThemeEnd = '/* askr theme end */';

{ gray/accent, gray accent, or askr -> the two names. '' for askr. False,
  with the reason, for a name there is no theme for. }
function ParseTheme(const Text: string; out Gray, Accent: string;
  out Why: string): Boolean;

{ The lines between the markers: the two imports, or none for askr. }
function ThemeLines(const Gray, Accent: string): string;

{ The markers with the lines between them, as askr new writes them. }
function ThemeBlock(const Gray, Accent: string): string;

{ Css with what is between its markers replaced. False, with the reason,
  when the markers are not there once each and in order. }
function ApplyTheme(const Css, Gray, Accent: string; out NewCss, Why: string): Boolean;

{ The theme Css imports now: gray/accent, askr, or '' when its markers are
  missing. }
function CurrentTheme(const Css: string): string;

implementation

function InList(const S: string; const L: array of string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(L) do
    if L[I] = S then
      Exit(True);
  Result := False;
end;

function Joined(const L: array of string): string;
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

function ParseTheme(const Text: string; out Gray, Accent: string;
  out Why: string): Boolean;
var
  T: string;
  P: Integer;
begin
  Gray := '';
  Accent := '';
  Why := '';
  T := LowerCase(Trim(Text));
  if T = DefaultTheme then
    Exit(True);
  P := Pos('/', T);
  if P = 0 then
    P := Pos(' ', T);
  if P = 0 then
  begin
    Why := 'A theme is a gray and an accent, as stone/teal, or ' + DefaultTheme +
      ' for Lauf''s own.';
    Exit(False);
  end;
  Gray := Trim(Copy(T, 1, P - 1));
  Accent := Trim(Copy(T, P + 1, MaxInt));
  if not InList(Gray, ThemeGrays) then
  begin
    Why := Format('There is no gray called "%s". The grays are %s.', [Gray, Joined(ThemeGrays)]);
    Exit(False);
  end;
  if not InList(Accent, ThemeAccents) then
  begin
    Why := Format('There is no accent called "%s". The accents are %s.', [Accent, Joined(ThemeAccents)]);
    Exit(False);
  end;
  Result := True;
end;

function ThemeLines(const Gray, Accent: string): string;
begin
  if Gray = '' then
    Exit('');
  Result := '@import ''@askrcode/lauf/themes/' + Gray + '.css'';' + #10 +
    '@import ''@askrcode/lauf/themes/accent/' + Accent + '.css'';' + #10;
end;

function ThemeBlock(const Gray, Accent: string): string;
begin
  Result := ThemeStart + #10 + ThemeLines(Gray, Accent) + ThemeEnd + #10;
end;

{ Where the markers are: the start of the line after the first, and the
  start of the line the second is on. False unless each is there once,
  in order. }
function Span(const Css: string; out Inner, Close: Integer): Boolean;
var
  A, B: Integer;
begin
  Result := False;
  A := Pos(ThemeStart, Css);
  B := Pos(ThemeEnd, Css);
  if (A = 0) or (B = 0) or (B < A) then
    Exit;
  if (Pos(ThemeStart, Copy(Css, A + 1, MaxInt)) > 0) or
     (Pos(ThemeEnd, Copy(Css, B + 1, MaxInt)) > 0) then
    Exit;
  Inner := A + Length(ThemeStart);
  if (Inner <= Length(Css)) and (Css[Inner] = #10) then
    Inc(Inner);
  Close := B;
  Result := True;
end;

function ApplyTheme(const Css, Gray, Accent: string; out NewCss, Why: string): Boolean;
var
  Inner, Close: Integer;
begin
  NewCss := Css;
  Why := '';
  if not Span(Css, Inner, Close) then
  begin
    Why := 'The theme markers are not in app.css, once each and in order.';
    Exit(False);
  end;
  NewCss := Copy(Css, 1, Inner - 1) + ThemeLines(Gray, Accent) + Copy(Css, Close, MaxInt);
  Result := True;
end;

function CurrentTheme(const Css: string): string;
var
  Inner, Close, P: Integer;
  Lines, G, A: string;
begin
  if not Span(Css, Inner, Close) then
    Exit('');
  Lines := Copy(Css, Inner, Close - Inner);
  if Trim(Lines) = '' then
    Exit(DefaultTheme);
  G := '';
  A := '';
  P := Pos('/themes/accent/', Lines);
  if P > 0 then
  begin
    A := Copy(Lines, P + Length('/themes/accent/'), MaxInt);
    A := Copy(A, 1, Pos('.css', A) - 1);
  end;
  P := Pos('/themes/', Lines);
  if P > 0 then
  begin
    G := Copy(Lines, P + Length('/themes/'), MaxInt);
    G := Copy(G, 1, Pos('.css', G) - 1);
  end;
  if (G = '') or (A = '') or (Pos('/', G) > 0) then
    Exit('');
  Result := G + '/' + A;
end;

end.
