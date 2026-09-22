{ Askr.Core.Url — the address the application answers on, from the outside.

  WHY THIS IS NOT TAKEN FROM THE REQUEST

  Every absolute URL an application emits — a canonical link, a sitemap
  entry, `og:url`, a password-reset link in an email — has to name one
  origin, and the request cannot be asked what that origin is. `Host` is a
  header, which means it is text the client writes.

  A request carrying `Host: evil.example` and a canonical built from it
  tells a search engine that the real page lives on the attacker's domain;
  the same header in a reset link sends the token there. These are not
  theoretical: host-header injection is the ordinary version of both. The
  same rule as the uploaded file's name and the page name an agent asks
  for — what the client sends is an input, never an authority.

  So the origin is configuration, and the functions here **have no way to
  see a request at all.** That is the point of the shape: the property is
  not that we remember to ignore `Host`, it is that there is nothing here
  to ignore it with.

  WHAT IT IS NOT

  `app.url` is an **origin** — scheme, host, optional port — and a path in
  it is refused rather than dropped or kept. An application served under a
  sub-path (`https://example.com/app`) is a real arrangement, and it is not
  this: it needs the router and every generated link to agree about the
  prefix, which is a bigger change than a string. Refusing says so; either
  silently dropping the `/app` or silently keeping it would produce wrong
  links somewhere, with nothing to say which. }
unit Askr.Core.Url;

{$mode Delphi}{$H+}

interface

uses
  SysUtils;

type
  EUrlError = class(Exception);

{ The configured origin, normalised: lowercase scheme and host, no trailing
  slash, no path. Empty when `app.url` is not set.

  Empty rather than guessed: a caller that can do without an absolute URL
  should leave it out. A canonical link that points at the wrong place is
  worse than no canonical link at all, and the second-best guess available
  here is the request, which is exactly what must not be used. }
function AppUrl: string;

{ The same, refusing instead of returning empty. For the places where an
  absolute URL is the whole point and a missing one is a bug worth stopping
  for: a sitemap, a link in an email. Says which key and which environment
  variable, as CfgOrFail does. }
function AppUrlOrFail: string;

{ Joins a path onto the origin. The path may be empty, or may start with a
  slash or not; the result never has a double slash and never a trailing
  one, except for the origin itself.

  Returns empty when the origin is not configured, so that a caller writing
  `if U <> '' then` is doing the right thing. }
function AbsoluteUrl(const Path_: string): string;

{ AbsoluteUrl, refusing instead of returning empty.

  For a link that is the whole point of the thing carrying it: the reset
  link in an email, an entry in a sitemap. An empty string there is a
  broken email nobody notices until a user cannot sign in, and a relative
  one is worse -- it looks like a link. }
function AbsoluteUrlOrFail(const Path_: string): string;

{ Checks a value the way AppUrl would, and says what is wrong with it.
  Returns an empty string when it is acceptable. Exposed so that a command
  can report a bad configuration without having to trigger it. }
function UrlProblem(const Value: string): string;

implementation

uses
  Askr.Core.Config;

const
  UrlKey = 'app.url';

function UrlProblem(const Value: string): string;
var
  V, Rest: string;
  P: Integer;
begin
  Result := '';
  V := Trim(Value);
  if V = '' then
    Exit;

  if (Copy(LowerCase(V), 1, 7) <> 'http://') and
     (Copy(LowerCase(V), 1, 8) <> 'https://') then
    Exit('it has to start with http:// or https://');

  P := Pos('://', V);
  Rest := Copy(V, P + 3, MaxInt);

  { A trailing slash is the one piece of path that is not a mistake — it is
    what a browser shows — so it is normalised away rather than refused. }
  while (Rest <> '') and (Rest[Length(Rest)] = '/') do
    SetLength(Rest, Length(Rest) - 1);

  if Rest = '' then
    Exit('it has no host');
  if Pos('/', Rest) > 0 then
    Exit('it has a path in it, and app.url is an origin. Serving under a ' +
         'sub-path needs the router to agree about the prefix too, which ' +
         'Askr does not do yet');
  if (Pos('?', Rest) > 0) or (Pos('#', Rest) > 0) then
    Exit('it has a query or a fragment in it, and app.url is an origin');
  if Pos(' ', Rest) > 0 then
    Exit('it has a space in it');
end;

{ Normalises a value that has already been found acceptable. }
function Normalise(const Value: string): string;
var
  V, Scheme, Host: string;
  P: Integer;
begin
  V := Trim(Value);
  P := Pos('://', V);
  Scheme := LowerCase(Copy(V, 1, P - 1));
  Host := Copy(V, P + 3, MaxInt);
  while (Host <> '') and (Host[Length(Host)] = '/') do
    SetLength(Host, Length(Host) - 1);
  { The host is case-insensitive, and a canonical URL that differs only in
    case is a second URL as far as a crawler is concerned. The port keeps
    its digits. }
  Result := Scheme + '://' + LowerCase(Host);
end;

function AppUrl: string;
var
  Raw, Problem: string;
begin
  Raw := Trim(Cfg(UrlKey, ''));
  if Raw = '' then
    Exit('');

  Problem := UrlProblem(Raw);
  if Problem <> '' then
    { Not ignored and not repaired. A value somebody typed and got slightly
      wrong should say so once, loudly, rather than produce links that are
      wrong in a way nobody looks at. }
    raise EUrlError.CreateFmt(
      'The configured %s is not usable: %s. It is "%s". ' +
      'An origin looks like https://example.com.',
      [UrlKey, Problem, Raw]);

  Result := Normalise(Raw);
end;

function AppUrlOrFail: string;
begin
  Result := AppUrl;
  if Result = '' then
    raise EUrlError.CreateFmt(
      'Missing configuration "%s". Set %s, or add url to [app] in ' +
      'askr.toml. It is the address this application answers on from the ' +
      'outside, and it cannot be taken from the request: Host is a header, ' +
      'which the client writes.',
      [UrlKey, EnvNameFor(UrlKey)]);
end;

function AbsoluteUrlOrFail(const Path_: string): string;
begin
  AppUrlOrFail;                 { raises with the useful message }
  Result := AbsoluteUrl(Path_);
end;

function AbsoluteUrl(const Path_: string): string;
var
  Base, P: string;
begin
  Base := AppUrl;
  if Base = '' then
    Exit('');

  P := Trim(Path_);
  while (P <> '') and (P[1] = '/') do
    System.Delete(P, 1, 1);
  while (P <> '') and (P[Length(P)] = '/') do
    SetLength(P, Length(P) - 1);

  if P = '' then
    Result := Base
  else
    Result := Base + '/' + P;
end;

end.
