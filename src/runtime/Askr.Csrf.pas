{ Askr.Csrf — beskyttelse mot cross-site request forgery.

  Angrepet: en side på et annet domene får nettleseren din til å sende en
  POST til denne appen. Nettleseren legger ved sesjonskaka helt av seg selv,
  fordi det er det kaker gjør, og serveren ser en fullt legitim forespørsel
  fra en innlogget bruker. Without et mottiltak er hvert eneste skjema i appen
  et endepunkt hvem som helst kan kalle på brukerens vegne.

  Mottiltaket er en hemmelighet som ligger i **sesjonen** og må sendes med i
  **requesten**. Et annet domene kan få nettleseren til å sende kaka, men
  det kan ikke lese sesjonen din og kan derfor ikke gjette tokenet.

  Tokenet tas imot tre steder, i denne rekkefølgen:

    1. skjemafeltet `_token`        — vanlige HTML-skjemaer
    2. headeren `X-CSRF-Token`     — fetch/XHR som selv legger det på
    3. headeren `X-XSRF-Token`     — axios og Inertia, som leser kaka
                                      `XSRF-TOKEN` og speiler den hit

  Den tredje er grunnen til at `UseCsrf` også setter en `XSRF-TOKEN`-kake
  som JavaScript får lese. Det er trygt: den kaka er ikke det som
  autentiserer noen — sesjonskaka er fortsatt HttpOnly — og verdien i den
  sammenlignes med den i sesjonen, som et annet domene ikke når.

  GET, HEAD og OPTIONS sjekkes ikke. De skal per definisjon ikke endre noe,
  og en app som endrer tilstand i en GET har et større problem enn CSRF. }
unit Askr.Csrf;

{$mode Delphi}{$H+}

interface

uses
  SysUtils,
  Askr.Core.Text, Askr.Core.Crypto,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response, Askr.Http.Router,
  Askr.Session;

const
  { Nøkkelen tokenet ligger under i sesjonen. Understreken markerer at det
    er rammeverkets, ikke appens. }
  CsrfSessionKey = '_csrf';
  { Feltet et skjema sender det i. Samme navn som Laravel bruker, fordi det
    er det folk allerede har i fingrene. }
  CsrfFieldName = '_token';
  CsrfHeaderName = 'X-CSRF-Token';
  CsrfCookieName = 'XSRF-TOKEN';

  { 419 Page Expired er ikke i noen RFC — den er Laravels, og Inertia-
    klienten kjenner den igjen og laster siden på nytt i stedet for å vise
    en feil. Det er den riktige oppførselen: et utløpt token betyr som
    regel at brukeren har hatt fanen åpen for lenge, ikke at noen angriper
    dem. En ren 403 ville gitt en blindvei. }
  CsrfFailStatus = 419;

{ Tokenet for denne requestens sesjon. Lages første gang det spørres etter
  og blir liggende i sesjonen. Kaster hvis det ikke finnes en sesjon — et
  CSRF-token uten sesjon å binde det til beskytter ingenting, og å returnere
  tom streng ville gjort den feilen usynlig. }
function CsrfToken: string;

{ Hidden felt til et HTML-skjema. Skrives rett inn i markupen:

      <form method="post">
        <%= CsrfField %>
        ... }
function CsrfField: string;

{ Sjekker en request uten å svare på den. To_ kode som vil ta avgjørelsen
  selv. `UseCsrf` bruker den. }
function CsrfValid(Req: TRequest): Boolean;

{ True for metodene som skal sjekkes. GET, HEAD og OPTIONS er unntatt. }
function CsrfMethodNeedsCheck(M: THttpMethod): Boolean;

{ Unnta en sti fra sjekken. To_ webhooks, som kommer fra en tredjepart som
  umulig kan ha tokenet, og som må autentiseres på en annen måte — en
  signatur i en header. Mønsteret matcher enten eksakt eller med `*` til
  slutt: `/webhooks/*`.

  Dette er et hull man lager med vilje, og derfor må det skrives ned. }
procedure CsrfExempt(const PathPattern: string);
function CsrfIsExempt(const Path: TStr): Boolean;

{ Kobler beskyttelsen på ruteren: en middleware som avviser en request uten
  gyldig token, og et etterfilter som setter XSRF-TOKEN-kaka.

  Krever at sesjonene er koblet på først — CSRF uten sesjon er meningsløst,
  og `UseCsrf` sier fra om det med en gang i stedet for å slippe gjennom
  hver request. }
procedure UseCsrf(R: TRouter);

implementation

var
  GExempt: array of string;

function CsrfMethodNeedsCheck(M: THttpMethod): Boolean;
begin
  Result := M in [hmPost, hmPut, hmPatch, hmDelete];
end;

procedure CsrfExempt(const PathPattern: string);
begin
  SetLength(GExempt, Length(GExempt) + 1);
  GExempt[High(GExempt)] := PathPattern;
end;

function CsrfIsExempt(const Path: TStr): Boolean;
var
  I: Integer;
  P, M: string;
begin
  P := Path.ToString;
  for I := 0 to High(GExempt) do
  begin
    M := GExempt[I];
    if (M <> '') and (M[Length(M)] = '*') then
    begin
      if Copy(P, 1, Length(M) - 1) = Copy(M, 1, Length(M) - 1) then
        Exit(True);
    end
    else if P = M then
      Exit(True);
  end;
  Result := False;
end;

function CsrfToken: string;
var
  S: TSession;
begin
  S := CurrentSession;
  if S = nil then
    raise ESessionError.Create(
      'CSRF needs a session. Call UseSessions before UseCsrf, or ' +
      'SetSessions and UseSession if you wire the request yourself.');
  Result := S.Get(CsrfSessionKey);
  if Result = '' then
  begin
    { 32 byte fra kjernens CSPRNG, base64url. Et token som kan gjettes er
      ikke et token. }
    Result := RandomToken(32);
    S.Put(CsrfSessionKey, Result);
  end;
end;

{ Tokenet er base64url og inneholder per konstruksjon ingenting som må
  escapes. Det escapes likevel: den dagen noen bytter kodingen skal ikke
  et skjemafelt bli et hull. }
function AttrEscape(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    case S[I] of
      '&': Result := Result + '&amp;';
      '<': Result := Result + '&lt;';
      '>': Result := Result + '&gt;';
      '"': Result := Result + '&quot;';
      '''': Result := Result + '&#39;';
    else
      Result := Result + S[I];
    end;
end;

function CsrfField: string;
begin
  Result := '<input type="hidden" name="' + CsrfFieldName + '" value="' +
    AttrEscape(CsrfToken) + '">';
end;

{ Leter etter tokenet der klienten kan ha lagt det. Ingen av stedene er
  autoritative hver for seg — det er sammenligningen med sesjonen som
  avgjør. }
function TokenFromRequest(Req: TRequest): string;
var
  V: TStr;
begin
  V := Req.Form(CsrfFieldName);
  if not V.IsEmpty then
    Exit(V.ToString);
  V := Req.Header(CsrfHeaderName);
  if not V.IsEmpty then
    Exit(V.ToString);
  { axios og Inertia leser XSRF-TOKEN-kaka og sender den tilbake her. }
  V := Req.Header('X-XSRF-Token');
  if not V.IsEmpty then
    Exit(V.ToString);
  Result := '';
end;

function CsrfValid(Req: TRequest): Boolean;
var
  S: TSession;
  Forventet, Fikk: string;
begin
  if not CsrfMethodNeedsCheck(Req.Method) then
    Exit(True);
  if CsrfIsExempt(Req.Path) then
    Exit(True);

  S := CurrentSession;
  if S = nil then
    Exit(False);

  Forventet := S.Get(CsrfSessionKey);
  { Ingen token i sesjonen betyr at brukeren aldri har fått et skjema fra
    oss. Da er det ingenting å sammenligne med, og svaret er nei. }
  if Forventet = '' then
    Exit(False);

  Fikk := TokenFromRequest(Req);
  if Fikk = '' then
    Exit(False);

  { Konstant tid. En vanlig `=` stopper ved første ulike tegn, og tiden det
    tar lekker hvor langt en gjetning kom. }
  Result := ConstantTimeEquals(Forventet, Fikk);
end;

type
  { Middleware og filter er funksjonspekere. Pascal har ingen lukninger, så
    tilstanden — her ingen — ville måttet ligge globalt uansett; en klasse
    med klassemetoder er den formen resten av Askr bruker. }
  TCsrfGuard = class
    class function Check(Req: TRequest): TResponse;
    class function SetCookie(Req: TRequest; Res: TResponse): TResponse;
  end;

class function TCsrfGuard.Check(Req: TRequest): TResponse;
begin
  if CsrfValid(Req) then
    Exit(nil);
  { Meldingen sier hva som er galt uten å røpe hva som var forventet.
    «Token mismatch» med det riktige tokenet i teksten har vært en ekte
    sårbarhet i andre rammeverk. }
  Result := RespondText('CSRF token missing or invalid.', CsrfFailStatus);
end;

class function TCsrfGuard.SetCookie(Req: TRequest; Res: TResponse): TResponse;
var
  S: TSession;
  Token: string;
begin
  Result := Res;
  S := CurrentSession;
  if S = nil then
    Exit;
  Token := S.Get(CsrfSessionKey);
  { Kaka settes bare når tokenet finnes fra før. Å lage et her ville gitt
    hver eneste request — også statiske filer og helsesjekker — en skriving
    til sesjonen, og dermed en sesjon per anonym besøkende. }
  if Token = '' then
    Exit;
  { ReadableByJs: dette er den ene kaka frontend skal lese. Den er ikke det
    som autentiserer noen. }
  Res.WithCookie(CsrfCookieName, Token, Sessions.Lifetime,
    Sessions.Secure, True);
end;

procedure UseCsrf(R: TRouter);
begin
  { Sessions kaster selv hvis ingen lager er satt, og meldingen der sier
    det som skal sies. Kallet står her for at feilen skal komme ved
    oppstart og ikke ved første POST. }
  Sessions;
  R.Use(TCsrfGuard.Check);
  R.After(TCsrfGuard.SetCookie);
end;

end.
