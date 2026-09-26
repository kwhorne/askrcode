{ Askr.Signed — links that prove they came from here.

      Link := SignedUrl('/verify-email/' + IntToStr(U.Id), 60 * 60);
      ...
      case CheckSignature(Req) of
        scValid:   { the link is ours, and not stale }
        scExpired: { ours, but too old: offer a new one }
        scInvalid: { changed, or never ours }
      end;

  A signed link carries an expiry and an HMAC under APP_KEY over the path,
  the query and the expiry together. Nothing is stored: the link is its
  own proof, which is what lets a verification mail or an unsubscribe
  link work without a table of tokens.

  The host is not signed. Behind a proxy the app may not see the host the
  link was made for, and the path is what says what the link does.

  A signed link can be used as often as it is valid. Where once matters --
  a password reset -- a token in the database is the tool, because only a
  table can forget a token when it has been used. }
unit Askr.Signed;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Askr.Http.Request;

type
  TSignatureCheck = (
    { Ours, unchanged, and not past its expiry. }
    scValid,
    { Ours and unchanged, but past its expiry. Worth telling apart: the
      answer is a new link, not a warning. }
    scExpired,
    { Changed, cut short, or never signed here. }
    scInvalid);

{ Path with expires and signature added to its query. Path may have a
  query of its own; it is signed with the rest. }
function SignedPath(const Path: string; LifetimeSeconds: Int64): string;
{ The same as an absolute link, for a mail: app.url in front. Raises when
  app.url is not set, because a link in a mail that points nowhere is
  worse than a mail that did not go. }
function SignedUrl(const Path: string; LifetimeSeconds: Int64): string;

{ Whether the request's own path and query are a link SignedPath made.
  The signature is the last parameter, and anything added after it is
  read as part of it, so it no longer matches. }
function CheckSignature(Req: TRequest): TSignatureCheck;
function HasValidSignature(Req: TRequest): Boolean;

implementation

uses
  Askr.Core.Crypto, Askr.Core.Clock, Askr.Core.Url;

const
  { Keeps these signatures apart from everything else APP_KEY signs --
    the remember cookie, above all. A signature from one is never a
    signature for the other. }
  Purpose = 'askr.signed-url:';

function SignatureOf(const Text_: string): string;
var
  S: string;
begin
  S := Sign(Purpose + Text_);
  Result := Copy(S, LastDelimiter('.', S) + 1, MaxInt);
end;

function SignedPath(const Path: string; LifetimeSeconds: Int64): string;
var
  Unsigned: string;
begin
  if Pos('?', Path) > 0 then
    Unsigned := Path + '&expires=' + IntToStr(UnixNow + LifetimeSeconds)
  else
    Unsigned := Path + '?expires=' + IntToStr(UnixNow + LifetimeSeconds);
  Result := Unsigned + '&signature=' + SignatureOf(Unsigned);
end;

function SignedUrl(const Path: string; LifetimeSeconds: Int64): string;
begin
  Result := AbsoluteUrlOrFail(SignedPath(Path, LifetimeSeconds));
end;

function CheckSignature(Req: TRequest): TSignatureCheck;
var
  Query, Unsigned, Given: string;
  P: Integer;
  Expires: Int64;
begin
  Result := scInvalid;
  Query := Req.QueryString.ToString;
  P := Pos('&signature=', Query);
  if P = 0 then
    Exit;
  { Everything after it is the signature, so a parameter added after the
    signature makes it one that does not match -- no check of its own
    needed, and a mutation that took one away showed nothing could reach
    it. }
  Given := Copy(Query, P + Length('&signature='), MaxInt);
  Unsigned := Req.RawPath.ToString + '?' + Copy(Query, 1, P - 1);
  if not HasAppKey then
    Exit;
  if not ConstantTimeEquals(SignatureOf(Unsigned), Given) then
    Exit;
  { Signed, so expires is ours -- but only if it is where SignedPath put
    it, the last parameter before the signature. Read from the query as
    a whole, a second expires earlier in the path's own query could be
    the one that counts. }
  P := LastDelimiter('&?', Unsigned);
  if Copy(Unsigned, P + 1, Length('expires=')) <> 'expires=' then
    Exit;
  if not TryStrToInt64(Copy(Unsigned, P + 1 + Length('expires='), MaxInt), Expires) then
    Exit;
  if UnixNow > Expires then
    Exit(scExpired);
  Result := scValid;
end;

function HasValidSignature(Req: TRequest): Boolean;
begin
  Result := CheckSignature(Req) = scValid;
end;

end.
