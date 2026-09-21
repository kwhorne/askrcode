{ Askr.Auth — hvem er dette, og får de lov?

  To ting som ofte blandes sammen:

    * **Autentisering** er å vite hvem noen er. Den lever i sesjonen.
    * **Autorisasjon** er å avgjøre om de får lov. Den lever i gates.

  Askr eier ikke brukermodellen din. Rammeverket lagrer én ting — brukerens
  id, som tekst — og lar appen slå opp resten selv gjennom en loader den
  registrerer. Det er med vilje: en `TUser` fra rammeverket ville tvunget
  fram et bestemt skjema, en bestemt tabell og et bestemt sett kolonner, og
  det første enhver ekte app gjør er å trenge en kolonne til.

  Passordene ligger i `Askr.Core.Crypto`. Denne uniten ser aldri et passord;
  appen verifiserer selv og kaller `Login` med en id.

      if VerifyPassword(Req.Form('password').ToString, Bruker.PasswordHash) then
        Login(IntToStr(Bruker.Id));

  Det høres ut som en omvei, men det er den ene rekkefølgen som ikke kan gå
  galt: rammeverket kan ikke vite hvilken kolonne hashen står i, og et API
  som gjettet på det ville måttet gjette på hvordan brukeren slås opp også. }
unit Askr.Auth;

{$mode Delphi}{$H+}

interface

uses
  SysUtils,
  Askr.Core.Text, Askr.Core.Clock, Askr.Core.Crypto,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response, Askr.Http.Router,
  Askr.Session;

type
  EAuthError = class(Exception);
  { Kastes av `Authorize`. Verten oversetter den til 403. }
  EForbidden = class(EAuthError);

  { Appens oppslag fra id til brukerobjekt. Kalles høyst én gang per
    request; resultatet caches for den requesten. Returner nil når id-en
    ikke finnes lenger — en slettet bruker med en gyldig sesjonskake skal
    bli utlogget, ikke gi en feil. }
  TUserLoader = function(const Id: string): TObject;

  { En gate: får denne brukeren lov til dette, på denne tingen?
    `Resource` er nil for gates som ikke gjelder et bestemt objekt
    («admin», «view-dashboard»). }
  TGateFunc = function(const UserId: string; Resource: TObject): Boolean;

const
  { Nøkkelen brukerens id ligger under i sesjonen. }
  AuthSessionKey = '_user';
  { «Husk meg»-kaka. Egen kake, ikke sesjonskaka: den skal overleve at
    sesjonen utløper, og det er hele poenget med den. }
  RememberCookieName = 'askr_remember';
  { 30 dager. Lenger enn det er en kake folk har glemt at de har. }
  RememberLifetime = 30 * 24 * 60 * 60;

{ --------------------------------------------------------- innlogging -- }

{ Logger inn. Id-en er appens egen — en primærnøkkel som tekst, en uuid,
  hva som helst, så lenge loaderen forstår den.

  Sesjons-id-en byttes ut her. Without det ville en angriper som fikk satt
  kaka di på forhånd vært innlogget som deg etterpå. }
procedure Login(const UserId: string; Remember: Boolean = False);
{ Logger ut: tømmer sesjonen helt og sletter «husk meg»-kaka. Hele sesjonen,
  ikke bare brukernøkkelen — det som lå der hørte til den innloggede. }
procedure Logout;

function Check: Boolean;
{ Id-en, eller tom streng. }
function Id: string;
{ Brukerobjektet fra loaderen, eller nil. Slår opp høyst én gang per
  request. }
function User: TObject;

{ Appens oppslag. Settes én gang ved oppstart. Without den virker Login, Check
  og Id fortsatt — bare ikke User. }
procedure SetUserLoader(L: TUserLoader);

{ ------------------------------------------------------- autorisasjon -- }

{ Definerer en gate. Samme navn to ganger erstatter den forrige, slik at en
  app kan overstyre en gate fra et bibliotek. }
procedure DefineGate(const Name: string; F: TGateFunc);
{ Får den innloggede brukeren lov? False når ingen er logget inn, og False
  for en gate som ikke finnes — en stavefeil i et gate-navn skal stenge
  døra, ikke åpne den. }
function Allows(const Name: string; Resource: TObject = nil): Boolean;
function Denies(const Name: string; Resource: TObject = nil): Boolean;
{ Samme, men kaster EForbidden. To_ kode som ikke skal fortsette. }
procedure Authorize(const Name: string; Resource: TObject = nil);
function GateExists(const Name: string): Boolean;

{ ---------------------------------------------------------- middleware -- }

{ Gjenoppretter innlogging fra «husk meg»-kaka når sesjonen er tom. Må stå
  etter UseSessions. Without den virker «husk meg» ikke — kaka blir liggende
  og bli ignorert. }
procedure UseAuth(R: TRouter);

{ Stenger alt bak innlogging fra og med her. En vanlig request sendes til
  `LoginPath`; en Inertia- eller JSON-request får 401, fordi en 302 til en
  HTML-side er ubrukelig for en klient som ventet JSON. }
procedure RequireAuth(R: TRouter; const LoginPath: string = '/login');

implementation

var
  GLoader: TUserLoader;
  GGates: array of record
    Name: string;
    Func: TGateFunc;
  end;
  { Loaderen kalles høyst én gang per request. Cachen ligger trådlokalt,
    som resten av request-tilstanden i Askr. }

threadvar
  GUser: TObject;
  GUserFor: string;

{ --------------------------------------------------------- innlogging -- }

procedure SetUserLoader(L: TUserLoader);
begin
  GLoader := L;
end;

function RequiresSession: TSession;
begin
  Result := CurrentSession;
  if Result = nil then
    raise EAuthError.Create(
      'Authentication needs a session. Call SetSessions and UseSessions ' +
      'before UseAuth.');
end;

{ Innholdet i «husk meg»-kaka: id og utløp, signert med appnøkkelen.
  Verdien er **lesbar** — signaturen beviser bare at vi laget den. Det er
  greit: en bruker-id er ikke en hemmelighet, og kaka alene gir ingen
  tilgang uten at signaturen stemmer.

  Kaka kan ikke trekkes tilbake enkeltvis. Skal den kunne det, må tokenet
  lagres per bruker i databasen, og det krever en kolonne rammeverket ikke
  kan vite om. Det er en reell begrensning, og den står her i stedet for å
  bli oppdaget. }
function RememberValue(const UserId: string): string;
begin
  Result := Sign(UserId + '|' + IntToStr(UnixNow + RememberLifetime));
end;

function ReadRemember(const Cookie_: string; out UserId: string): Boolean;
var
  Payload, UtloepStr: string;
  P: Integer;
  Utloep: Int64;
begin
  UserId := '';
  if Cookie_ = '' then
    Exit(False);
  if not Unsign(Cookie_, Payload) then
    Exit(False);
  P := Pos('|', Payload);
  if P <= 1 then
    Exit(False);
  UtloepStr := Copy(Payload, P + 1, MaxInt);
  if not TryStrToInt64(UtloepStr, Utloep) then
    Exit(False);
  { Utløpet står inne i det signerte, ikke bare i kakas Max-Age. En klient
    som beholder kaka lenger enn vi ba om skal ikke komme inn. }
  if UnixNow > Utloep then
    Exit(False);
  UserId := Copy(Payload, 1, P - 1);
  Result := UserId <> '';
end;

{ Kaka settes og slettes på svaret, og svaret finnes først etter at
  handleren har kjørt. Ønsket parkeres derfor trådlokalt og utføres av
  etterfilteret. }
threadvar
  GSetRemember: string;
  GClearRemember: Boolean;

procedure Login(const UserId: string; Remember: Boolean);
var
  S: TSession;
begin
  if UserId = '' then
    raise EAuthError.Create('Login needs a user id.');
  S := RequiresSession;
  { Ny sesjons-id i det privilegiene endrer seg. Dette er hele forsvaret
    mot session fixation, og det er én linje. }
  Sessions.Regenerate(S);
  S.Put(AuthSessionKey, UserId);
  GUser := nil;
  GUserFor := '';
  if Remember then
    GSetRemember := RememberValue(UserId);
end;

procedure Logout;
var
  S: TSession;
begin
  S := CurrentSession;
  if S <> nil then
  begin
    { Hele sesjonen, ikke bare brukernøkkelen: en handlekurv eller et
      halvferdig skjema hørte til den som var logget inn. }
    S.Clear;
    Sessions.Regenerate(S);
  end;
  GUser := nil;
  GUserFor := '';
  GSetRemember := '';
  GClearRemember := True;
end;

function Id: string;
var
  S: TSession;
begin
  S := CurrentSession;
  if S = nil then
    Exit('');
  Result := S.Get(AuthSessionKey);
end;

function Check: Boolean;
begin
  Result := Id <> '';
end;

function User: TObject;
var
  Uid: string;
begin
  Uid := Id;
  if Uid = '' then
  begin
    GUser := nil;
    GUserFor := '';
    Exit(nil);
  end;
  if (GUserFor = Uid) and (GUser <> nil) then
    Exit(GUser);
  if not Assigned(GLoader) then
    raise EAuthError.Create(
      'No user loader is registered. Call SetUserLoader at startup, or ' +
      'use Id instead of User.');
  GUser := GLoader(Uid);
  GUserFor := Uid;
  Result := GUser;
end;

{ ------------------------------------------------------- autorisasjon -- }

function GateIndex(const Name: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(GGates) do
    if SameText(GGates[I].Name, Name) then
      Exit(I);
  Result := -1;
end;

procedure DefineGate(const Name: string; F: TGateFunc);
var
  I: Integer;
begin
  if Name = '' then
    raise EAuthError.Create('A gate needs a name.');
  I := GateIndex(Name);
  if I < 0 then
  begin
    SetLength(GGates, Length(GGates) + 1);
    I := High(GGates);
    GGates[I].Name := Name;
  end;
  GGates[I].Func := F;
end;

function GateExists(const Name: string): Boolean;
begin
  Result := GateIndex(Name) >= 0;
end;

function Allows(const Name: string; Resource: TObject): Boolean;
var
  I: Integer;
  Uid: string;
begin
  Uid := Id;
  if Uid = '' then
    Exit(False);
  I := GateIndex(Name);
  { En gate som ikke finnes svarer nei. Det motsatte ville gjort en
    stavefeil i et gate-navn til en åpen dør, og den feilen ser ut som at
    alt virker. }
  if I < 0 then
    Exit(False);
  Result := GGates[I].Func(Uid, Resource);
end;

function Denies(const Name: string; Resource: TObject): Boolean;
begin
  Result := not Allows(Name, Resource);
end;

procedure Authorize(const Name: string; Resource: TObject);
begin
  if not Allows(Name, Resource) then
    { Meldingen nevner gaten, ikke brukeren eller ressursen. Den havner
      i en logg, og en 403 skal ikke fortelle noen hva de nesten fikk. }
    raise EForbidden.CreateFmt('Not authorized: %s', [Name]);
end;

{ ---------------------------------------------------------- middleware -- }

type
  TAuthHook = class
    class function Restore(Req: TRequest): TResponse;
    class function WriteCookies(Req: TRequest; Res: TResponse): TResponse;
    class function Require(Req: TRequest): TResponse;
  end;

var
  GLoginPath: string = '/login';

class function TAuthHook.Restore(Req: TRequest): TResponse;
var
  S: TSession;
  Uid: string;
begin
  Result := nil;
  GSetRemember := '';
  GClearRemember := False;
  GUser := nil;
  GUserFor := '';

  S := CurrentSession;
  if S = nil then
    Exit;
  { Kaka brukes bare når sesjonen er tom. En innlogget sesjon vinner
    alltid — ellers ville en gammel kake kunnet overstyre en nyere
    innlogging. }
  if S.Get(AuthSessionKey) <> '' then
    Exit;

  if not HasAppKey then
    Exit;
  if not ReadRemember(CookieValue(Req, RememberCookieName), Uid) then
    Exit;

  { Ny sesjons-id også her: dette er en innlogging, bare uten skjema. }
  Sessions.Regenerate(S);
  S.Put(AuthSessionKey, Uid);
  { Kaka fornyes, slik at en bruker som er innom ikke plutselig blir kastet
    ut på dag 30. }
  GSetRemember := RememberValue(Uid);
end;

class function TAuthHook.WriteCookies(Req: TRequest; Res: TResponse): TResponse;
begin
  Result := Res;
  if GClearRemember then
    { Max-Age=0 er måten å slette en kake på. Verdien settes tom i tillegg,
      for en klient som beholder den likevel. }
    Res.WithCookie(RememberCookieName, '', 0, Sessions.Secure)
  else if GSetRemember <> '' then
    Res.WithCookie(RememberCookieName, GSetRemember, RememberLifetime,
      Sessions.Secure);
  GSetRemember := '';
  GClearRemember := False;
end;

class function TAuthHook.Require(Req: TRequest): TResponse;
begin
  if Check then
    Exit(nil);
  { En Inertia- eller JSON-klient har ingen nytte av en 302 til en
    HTML-side: den ville fulgt den og fått innloggingssiden som JSON.
    401 er det klienten kan gjøre noe med. }
  if (Req.Header('X-Inertia').Len > 0) or
     (Pos('application/json', Req.Header('Accept').ToString) > 0) then
    Exit(RespondText('Unauthenticated.', 401));
  Result := Redirect(GLoginPath, 302);
end;

procedure UseAuth(R: TRouter);
begin
  Sessions;
  R.Use(TAuthHook.Restore);
  R.After(TAuthHook.WriteCookies);
end;

procedure RequireAuth(R: TRouter; const LoginPath: string);
begin
  GLoginPath := LoginPath;
  R.Use(TAuthHook.Require);
end;

end.
