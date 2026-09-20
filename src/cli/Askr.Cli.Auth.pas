{ Askr.Cli.Auth — genererer innlogging, registrering og passordtilbakestilling.

  Kjøres av `askr new --auth` og av `askr make auth` i et prosjekt som
  allerede finnes.

  **Sidene er vanlig HTML, ikke Inertia.** Et nytt prosjekt har Inertia satt
  opp, men ikke installert — `npm install` er noe man gjør etterpå. Å kreve
  det før man kan logge inn ville gjort innloggingen ubrukelig akkurat i det
  vinduet der man trenger den mest. Sidene bruker systemfonter og inline CSS
  og trenger verken npm eller nett, som velkomstsiden. Det står i den
  genererte koden hvordan de gjøres om til Inertia-sider.

  **Alt som genereres er ditt.** Det er hele poenget med et stillas: du skal
  kunne endre innloggingssiden. Derfor ligger malene her og ikke i
  rammeverket. }
unit Askr.Cli.Auth;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes;

{ Skriver modellen, migrasjonene og kontrolleren. Rører ikke app.lpr —
  linjene som må inn der skrives ut til slutt, eller settes inn av
  InstallerRuter når markørene finnes. }
procedure LagAuth(const Rot: string; Force: Boolean);

{ Setter inn uses-linja og rutene i app.lpr hvis markørene fra `askr new`
  er der. Returnerer False når de ikke er det, og da må brukeren gjøre det
  selv. }
function InstallerRuter(const Rot: string): Boolean;

implementation

uses
  Askr.Cli.Scaffold;

const
  Q = '''';

{ ------------------------------------------------------------- modellen -- }

procedure SkrivBruker(const Rot: string);
begin
  Skriv(IncludeTrailingPathDelimiter(Rot) + 'app/Models/App.Models.User.pas',
    'unit App.Models.User;' + #10 + #10 +
    '{$mode Delphi}{$H+}' + #10 + #10 +
    'interface' + #10 + #10 +
    'uses' + #10 +
    { TModelList ligger i Askr.Urd.Query, ikke i Askr.Urd.Model. }
    '  SysUtils, Askr.Urd.Model, Askr.Urd.Query;' + #10 + #10 +
    'type' + #10 +
    '  TUser = class(TModel)' + #10 +
    '  private' + #10 +
    '    FId: Int64;' + #10 +
    '    FName: string;' + #10 +
    '    FEmail: string;' + #10 +
    '    FPasswordHash: string;' + #10 +
    '    FCreatedAt: TDateTime;' + #10 +
    '    FUpdatedAt: TDateTime;' + #10 +
    '  published' + #10 +
    '    property Id: Int64 read FId write FId;' + #10 +
    '    property Name: string read FName write FName;' + #10 +
    '    property Email: string read FEmail write FEmail;' + #10 +
    '    { Hele PHC-strengen fra HashPassword, ikke bare hashen: den' + #10 +
    '      bærer algoritme, iterasjoner og salt, og det er den som gjør' + #10 +
    '      at parametrene kan endres uten en migrasjon. }' + #10 +
    '    property PasswordHash: string read FPasswordHash write FPasswordHash;' + #10 +
    '    property CreatedAt: TDateTime read FCreatedAt write FCreatedAt;' + #10 +
    '    property UpdatedAt: TDateTime read FUpdatedAt write FUpdatedAt;' + #10 +
    '  public' + #10 +
    '    class procedure Describe(S: TSchema); override;' + #10 +
    '    procedure Rules(V: TValidator); override;' + #10 +
    '  end;' + #10 + #10 +
    '  TUserList = TModelList<TUser>;' + #10 + #10 +
    'implementation' + #10 + #10 +
    'class procedure TUser.Describe(S: TSchema);' + #10 +
    'begin' + #10 +
    '  S.Table(' + Q + 'users' + Q + ');' + #10 +
    '  S.Timestamps;' + #10 +
    'end;' + #10 + #10 +
    'procedure TUser.Rules(V: TValidator);' + #10 +
    'begin' + #10 +
    '  V.Field(' + Q + 'Name' + Q + ').Required.MaxLen(120);' + #10 +
    '  V.Field(' + Q + 'Email' + Q + ').Required.Email.UniqueIn(' +
      Q + 'users' + Q + ');' + #10 +
    '  { Passordet valideres i kontrolleren, ikke her: modellen ser aldri' + #10 +
    '    klarteksten, bare hashen. }' + #10 +
    'end;' + #10 + #10 +
    'end.' + #10);
end;

{ ---------------------------------------------------------- kontrolleren -- }

{ Malen bygges linje for linje i stedet for som én kjedet streng. En
  kontroller på to hundre linjer skrevet som `'...' + #10 +` er ikke lesbar
  for den som skal endre den. Anførselstegn dobles, som i all Pascal. }
procedure SkrivKontroller(const Rot: string);
var
  L: TStringList;

  procedure A(const S: string);
  begin
    L.Add(S);
  end;

begin
  L := TStringList.Create;
  try
    A('unit App.Http.AuthController;');
    A('');
    A('{ Innlogging, registrering og passordtilbakestilling.');
    A('');
    A('  Sidene er vanlig HTML og trenger verken npm eller nett, slik at');
    A('  innlogging virker fra første bygg. Vil du ha dem som Inertia-sider,');
    A('  bytt Result := Page(...) mot Result := Inertia(''Auth/Login'', [...])');
    A('  og skriv komponentene i frontend/src/pages/Auth/.');
    A('');
    A('  Alt her er ditt. Rammeverket eier ikke brukermodellen din — det');
    A('  lagrer en id som tekst, og denne fila slår opp resten. }');
    A('');
    A('{$mode Delphi}{$H+}');
    A('');
    A('interface');
    A('');
    A('uses');
    A('  SysUtils, Askr.Core.Arena, Askr.Core.Text, Askr.Core.Clock,');
    A('  Askr.Core.Crypto, Askr.Core.Config, Askr.Core.Log,');
    A('  Askr.Http.Request, Askr.Http.Response,');
    A('  Askr.Urd.Driver, Askr.Urd.Model, Askr.Urd.Query,');
    A('  Askr.Session, Askr.Csrf, Askr.Auth, Askr.Mail, Askr.Cache,');
    A('  App.Models.User;');
    A('');
    A('type');
    A('  TAuthController = class');
    A('  public');
    A('    function ShowLogin(Req: TRequest): TResponse;');
    A('    function DoLogin(Req: TRequest): TResponse;');
    A('    function ShowRegister(Req: TRequest): TResponse;');
    A('    function DoRegister(Req: TRequest): TResponse;');
    A('    function DoLogout(Req: TRequest): TResponse;');
    A('    function ShowForgot(Req: TRequest): TResponse;');
    A('    function SendReset(Req: TRequest): TResponse;');
    A('    function ShowReset(Req: TRequest): TResponse;');
    A('    function DoReset(Req: TRequest): TResponse;');
    A('  end;');
    A('');
    A('{ Askr lagrer bare brukerens id. Denne gir resten tilbake, og');
    A('  registreres med SetUserLoader i app.lpr. }');
    A('function LoadUser(const Id: string): TObject;');
    A('');
    A('implementation');
    A('');
    A('{ ------------------------------------------------------- sidene -- }');
    A('');
    A('function Esc(const S: string): string;');
    A('var');
    A('  I: Integer;');
    A('begin');
    A('  Result := '''';');
    A('  for I := 1 to Length(S) do');
    A('    case S[I] of');
    A('      ''&'': Result := Result + ''&amp;'';');
    A('      ''<'': Result := Result + ''&lt;'';');
    A('      ''>'': Result := Result + ''&gt;'';');
    A('      ''"'': Result := Result + ''&quot;'';');
    A('    else');
    A('      Result := Result + S[I];');
    A('    end;');
    A('end;');
    A('');
    A('{ Ett sted for skallet, slik at de fem sidene ser like ut og kan');
    A('  endres ett sted. }');
    A('function Page(const Title, Body: string): string;');
    A('begin');
    A('  Result :=');
    A('    ''<!doctype html><html lang="en"><head><meta charset="utf-8">'' +');
    A('    ''<meta name="viewport" content="width=device-width,initial-scale=1">'' +');
    A('    ''<title>'' + Esc(Title) + ''</title><style>'' +');
    A('    '':root{--bg:#fff;--fg:#111;--dim:#667;--line:#dde;--accent:#2b6;'' +');
    A('    ''--bad:#c33}'' +');
    A('    ''@media(prefers-color-scheme:dark){:root{--bg:#0e1113;--fg:#e8eef0;'' +');
    A('    ''--dim:#8a9aa3;--line:#243;--accent:#3fe0a8;--bad:#f77}}'' +');
    A('    ''*{box-sizing:border-box}'' +');
    A('    ''body{margin:0;background:var(--bg);color:var(--fg);'' +');
    A('    ''font:16px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}'' +');
    A('    ''main{max-width:24rem;margin:0 auto;padding:4rem 1.5rem}'' +');
    A('    ''h1{font-size:1.5rem;margin:0 0 1.5rem}'' +');
    A('    ''label{display:block;margin:0 0 1rem}'' +');
    A('    ''label span{display:block;font-size:.85rem;color:var(--dim);'' +');
    A('    ''margin-bottom:.25rem}'' +');
    A('    ''input{width:100%;padding:.6rem .7rem;font:inherit;'' +');
    A('    ''background:var(--bg);color:var(--fg);'' +');
    A('    ''border:1px solid var(--line);border-radius:.3rem}'' +');
    A('    ''button{width:100%;padding:.65rem;font:inherit;font-weight:600;'' +');
    A('    ''color:#031;background:var(--accent);border:0;border-radius:.3rem;'' +');
    A('    ''cursor:pointer}'' +');
    A('    ''.err{color:var(--bad);font-size:.9rem;margin:0 0 1rem}'' +');
    A('    ''.ok{color:var(--accent);font-size:.9rem;margin:0 0 1rem}'' +');
    A('    ''.alt{margin-top:1.5rem;font-size:.9rem;color:var(--dim)}'' +');
    A('    ''.alt a{color:inherit}'' +');
    A('    ''.row{display:flex;align-items:center;gap:.5rem;margin:0 0 1rem}'' +');
    A('    ''.row input{width:auto}'' +');
    A('    ''.row span{font-size:.9rem;color:var(--dim)}'' +');
    A('    ''</style></head><body><main>'' + Body + ''</main></body></html>'';');
    A('end;');
    A('');
    A('function Melding(const S, Klasse: string): string;');
    A('begin');
    A('  if S = '''' then');
    A('    Result := ''''');
    A('  else');
    A('    Result := ''<p class="'' + Klasse + ''">'' + Esc(S) + ''</p>'';');
    A('end;');
    A('');
    A('{ ---------------------------------------------- plassholdere -- }');
    A('');
    A('{ $1 i Postgres, ? i MySQL og SQLite. Driveren vet hvilken; denne');
    A('  koden skal slippe å vite det. }');
    A('function Plassholder(N: Integer): string;');
    A('var');
    A('  B: TStrBuilder;');
    A('begin');
    A('  B.Init(CurrentArena, 8);');
    A('  CurrentDb.AppendPlaceholder(B, N);');
    A('  Result := B.ToString;');
    A('end;');
    A('');
    A('function Plassholdere(Antall: Integer): string;');
    A('var');
    A('  I: Integer;');
    A('begin');
    A('  Result := '''';');
    A('  for I := 1 to Antall do');
    A('  begin');
    A('    if I > 1 then');
    A('      Result := Result + '', '';');
    A('    Result := Result + Plassholder(I);');
    A('  end;');
    A('end;');
    A('');
    A('{ ------------------------------------------------ brukeroppslag -- }');
    A('');
    A('function LoadUser(const Id: string): TObject;');
    A('begin');
    A('  Result := TQuery<TUser>.New.Find(StrToInt64Def(Id, 0));');
    A('end;');
    A('');
    A('function FinnPaaEpost(const Epost: string): TUser;');
    A('begin');
    A('  Result := TQuery<TUser>.New');
    A('    .Where(ColStr(''users'', ''email''), Eq, LowerCase(Trim(Epost)))');
    A('    .First;');
    A('end;');
    A('');
    A('{ ------------------------------------------------------ bremsen -- }');
    A('');
    A('{ Uten dette er innloggingsskjemaet et mål for gjetting i stor skala.');
    A('  Cachen brukes hvis den finnes; er den ikke satt opp, hopper vi over');
    A('  bremsen i stedet for å ta ned innloggingen. Da står det i loggen.');
    A('');
    A('  Telleren står på e-posten, ikke på IP-en: en angriper har mange');
    A('  IP-er og som regel bare én konto å komme inn på. }');
    A('const');
    A('  MaxForsok = 5;');
    A('  BremseVinduSek = 900;');
    A('');
    A('function BremseNokkel(const Epost: string): string;');
    A('begin');
    A('  Result := ''login:'' + LowerCase(Trim(Epost));');
    A('end;');
    A('');
    A('function ForMangeForsok(const Epost: string): Boolean;');
    A('var');
    A('  V: string;');
    A('begin');
    A('  Result := False;');
    A('  try');
    A('    if Cache.Get(BremseNokkel(Epost), V) then');
    A('      Result := StrToIntDef(V, 0) >= MaxForsok;');
    A('  except');
    A('    on Exception do');
    A('      { Ingen cache satt opp. Se kommentaren over. }');
    A('      Result := False;');
    A('  end;');
    A('end;');
    A('');
    A('procedure TellForsok(const Epost: string);');
    A('var');
    A('  V: string;');
    A('begin');
    A('  try');
    A('    if not Cache.Get(BremseNokkel(Epost), V) then');
    A('      V := ''0'';');
    A('    Cache.Put(BremseNokkel(Epost), IntToStr(StrToIntDef(V, 0) + 1),');
    A('      BremseVinduSek);');
    A('  except');
    A('    on Exception do ;');
    A('  end;');
    A('end;');
    A('');
    A('procedure NullstillForsok(const Epost: string);');
    A('begin');
    A('  try');
    A('    Cache.Forget(BremseNokkel(Epost));');
    A('  except');
    A('    on Exception do ;');
    A('  end;');
    A('end;');
    A('');
    A('{ ---------------------------------------------------- innlogging -- }');
    A('');
    A('function TAuthController.ShowLogin(Req: TRequest): TResponse;');
    A('begin');
    A('  if Askr.Auth.Check then');
    A('    Exit(Redirect(''/''));');
    A('  Result := RespondHtml(Page(''Sign in'',');
    A('    ''<h1>Sign in</h1>'' +');
    A('    Melding(CurrentSession.GetFlash(''error''), ''err'') +');
    A('    Melding(CurrentSession.GetFlash(''notice''), ''ok'') +');
    A('    ''<form method="post" action="/login">'' + CsrfField +');
    A('    ''<label><span>Email</span>'' +');
    A('    ''<input type="email" name="email" autocomplete="username" '' +');
    A('    ''required autofocus></label>'' +');
    A('    ''<label><span>Password</span>'' +');
    A('    ''<input type="password" name="password" '' +');
    A('    ''autocomplete="current-password" required></label>'' +');
    A('    ''<div class="row"><input type="checkbox" name="remember" '' +');
    A('    ''id="r" value="1"><span>Stay signed in</span></div>'' +');
    A('    ''<button type="submit">Sign in</button></form>'' +');
    A('    ''<p class="alt"><a href="/forgot-password">Forgot your '' +');
    A('    ''password?</a><br><a href="/register">Create an account</a></p>''));');
    A('end;');
    A('');
    A('function TAuthController.DoLogin(Req: TRequest): TResponse;');
    A('var');
    A('  Epost, Passord: string;');
    A('  U: TUser;');
    A('begin');
    A('  Epost := Req.Form(''email'').ToString;');
    A('  Passord := Req.Form(''password'').ToString;');
    A('');
    A('  if ForMangeForsok(Epost) then');
    A('  begin');
    A('    LogWarn(''login throttled'', [''email'', Epost]);');
    A('    CurrentSession.Flash(''error'',');
    A('      ''Too many attempts. Try again in a few minutes.'');');
    A('    Exit(Redirect(''/login'', 303));');
    A('  end;');
    A('');
    A('  U := FinnPaaEpost(Epost);');
    A('  if (U = nil) or not VerifyPassword(Passord, U.PasswordHash) then');
    A('  begin');
    A('    { Én melding for begge tilfellene. Sier man "no such account",');
    A('      har man laget et oppslagsverk over hvem som er registrert. }');
    A('    TellForsok(Epost);');
    A('    CurrentSession.Flash(''error'', ''Those credentials do not match.'');');
    A('    Exit(Redirect(''/login'', 303));');
    A('  end;');
    A('');
    A('  { Passordet er i hånden akkurat nå, så en hash laget med svakere');
    A('    parametre kan oppgraderes uten å spørre brukeren om noe. }');
    A('  if NeedsRehash(U.PasswordHash) then');
    A('  begin');
    A('    U.PasswordHash := HashPassword(Passord);');
    A('    U.Save;');
    A('  end;');
    A('');
    A('  NullstillForsok(Epost);');
    A('  { Login bytter sesjons-id. Uten det er session fixation åpent. }');
    A('  Askr.Auth.Login(IntToStr(U.Id), Req.Form(''remember'').Len > 0);');
    A('  LogInfo(''login'', [''user'', U.Id]);');
    A('  Result := Redirect(''/'', 303);');
    A('end;');
    A('');
    A('function TAuthController.DoLogout(Req: TRequest): TResponse;');
    A('begin');
    A('  Askr.Auth.Logout;');
    A('  Result := Redirect(''/'', 303);');
    A('end;');
    A('');
    A('{ -------------------------------------------------- registrering -- }');
    A('');
    A('function TAuthController.ShowRegister(Req: TRequest): TResponse;');
    A('begin');
    A('  if Askr.Auth.Check then');
    A('    Exit(Redirect(''/''));');
    A('  Result := RespondHtml(Page(''Create an account'',');
    A('    ''<h1>Create an account</h1>'' +');
    A('    Melding(CurrentSession.GetFlash(''error''), ''err'') +');
    A('    ''<form method="post" action="/register">'' + CsrfField +');
    A('    ''<label><span>Name</span>'' +');
    A('    ''<input name="name" required autofocus></label>'' +');
    A('    ''<label><span>Email</span>'' +');
    A('    ''<input type="email" name="email" autocomplete="username" '' +');
    A('    ''required></label>'' +');
    A('    ''<label><span>Password</span>'' +');
    A('    ''<input type="password" name="password" '' +');
    A('    ''autocomplete="new-password" minlength="12" required></label>'' +');
    A('    ''<label><span>Repeat password</span>'' +');
    A('    ''<input type="password" name="password_confirmation" '' +');
    A('    ''autocomplete="new-password" required></label>'' +');
    A('    ''<button type="submit">Create account</button></form>'' +');
    A('    ''<p class="alt"><a href="/login">I already have an account</a></p>''));');
    A('end;');
    A('');
    A('{ Minstekravet står ett sted, slik at registrering og tilbakestilling');
    A('  ikke kan bli uenige. Tolv tegn er OWASPs anbefaling for et passord');
    A('  uten andre krav; regler om store bokstaver og tall gir svakere');
    A('  passord i praksis, fordi folk lager Passord1! }');
    A('function PassordFeil(const P, Bekreft: string): string;');
    A('begin');
    A('  if Length(P) < 12 then');
    A('    Exit(''The password must be at least 12 characters.'');');
    A('  if P <> Bekreft then');
    A('    Exit(''The two passwords do not match.'');');
    A('  Result := '''';');
    A('end;');
    A('');
    A('function TAuthController.DoRegister(Req: TRequest): TResponse;');
    A('var');
    A('  U: TUser;');
    A('  Passord, Feil: string;');
    A('begin');
    A('  Passord := Req.Form(''password'').ToString;');
    A('  Feil := PassordFeil(Passord,');
    A('    Req.Form(''password_confirmation'').ToString);');
    A('  if Feil <> '''' then');
    A('  begin');
    A('    CurrentSession.Flash(''error'', Feil);');
    A('    Exit(Redirect(''/register'', 303));');
    A('  end;');
    A('');
    A('  U := CurrentArena.New<TUser>;');
    A('  U.Name := Req.Form(''name'').ToString;');
    A('  U.Email := LowerCase(Trim(Req.Form(''email'').ToString));');
    A('  if not U.Validate then');
    A('  begin');
    A('    CurrentSession.Flash(''error'', U.Errors.First(''email''));');
    A('    Exit(Redirect(''/register'', 303));');
    A('  end;');
    A('');
    A('  { Klarteksten går ikke lenger enn hit. }');
    A('  U.PasswordHash := HashPassword(Passord);');
    A('  U.Save;');
    A('');
    A('  Askr.Auth.Login(IntToStr(U.Id));');
    A('  LogInfo(''registered'', [''user'', U.Id]);');
    A('  Result := Redirect(''/'', 303);');
    A('end;');
    A('');

    A('{ ------------------------------------------ passordtilbakestilling -- }');
    A('');
    A('function TAuthController.ShowForgot(Req: TRequest): TResponse;');
    A('begin');
    A('  Result := RespondHtml(Page(''Reset your password'',');
    A('    ''<h1>Reset your password</h1>'' +');
    A('    Melding(CurrentSession.GetFlash(''notice''), ''ok'') +');
    A('    ''<form method="post" action="/forgot-password">'' + CsrfField +');
    A('    ''<label><span>Email</span>'' +');
    A('    ''<input type="email" name="email" required autofocus></label>'' +');
    A('    ''<button type="submit">Send reset link</button></form>'' +');
    A('    ''<p class="alt"><a href="/login">Back to sign in</a></p>''));');
    A('end;');
    A('');
    A('const');
    A('  { En time. Lenge nok til at en e-post kan bli liggende litt, kort');
    A('    nok til at en gammel innboks ikke er en nøkkel. }');
    A('  ResetLevetidMs = 60 * 60 * 1000;');
    A('');
    A('function TAuthController.SendReset(Req: TRequest): TResponse;');
    A('var');
    A('  Epost, Token, Lenke: string;');
    A('  U: TUser;');
    A('  A: TArena;');
    A('  M: TMailMessage;');
    A('begin');
    A('  Epost := LowerCase(Trim(Req.Form(''email'').ToString));');
    A('  U := FinnPaaEpost(Epost);');
    A('');
    A('  { Samme svar uansett om adressen finnes. Alt annet gjør skjemaet');
    A('    til et oppslagsverk over hvem som er registrert. }');
    A('  CurrentSession.Flash(''notice'',');
    A('    ''If that address has an account, a link is on its way.'');');
    A('');
    A('  if U <> nil then');
    A('  begin');
    A('    Token := RandomToken(32);');
    A('    A := CurrentArena;');
    A('    { Hashen lagres, ikke tokenet. En lekket tabell skal ikke gi noen');
    A('      muligheten til å tilbakestille passord. }');
    A('    CurrentDb.ExecParams(A,');
    A('      ''INSERT INTO password_resets (email, token_hash, expires_at, '' +');
    A('      ''created_at) VALUES ('' + Plassholdere(4) + '')'',');
    A('      [DbParam(A, Epost), DbParam(A, Sha256Hex(Token)),');
    A('       DbParam(A, UnixNowMs + ResetLevetidMs), DbParam(A, UnixNowMs)]);');
    A('');
    A('    Lenke := Cfg(''app.url'', ''http://127.0.0.1:8080'') +');
    A('      ''/reset-password/'' + Token;');
    A('');
    A('    { I utvikling skriver TLogTransport e-posten til en fil, slik at');
    A('      lenken faktisk kan prøves uten en SMTP-server. }');
    A('    M := Mail.Message_;');
    A('    M.AddTo(Epost).Subject(''Reset your password'')');
    A('     .Text(''Open this link to choose a new password:'' + #10 + #10 +');
    A('           Lenke + #10 + #10 + ''It expires in one hour.'');');
    A('    Mail.Send(M);');
    A('    LogInfo(''password reset requested'', [''user'', U.Id]);');
    A('  end;');
    A('');
    A('  Result := Redirect(''/forgot-password'', 303);');
    A('end;');
    A('');
    A('function TAuthController.ShowReset(Req: TRequest): TResponse;');
    A('begin');
    A('  Result := RespondHtml(Page(''Choose a new password'',');
    A('    ''<h1>Choose a new password</h1>'' +');
    A('    Melding(CurrentSession.GetFlash(''error''), ''err'') +');
    A('    ''<form method="post" action="/reset-password">'' + CsrfField +');
    A('    ''<input type="hidden" name="token" value="'' +');
    A('    Esc(Req.Param(''token'').ToString) + ''">'' +');
    A('    ''<label><span>New password</span>'' +');
    A('    ''<input type="password" name="password" '' +');
    A('    ''autocomplete="new-password" minlength="12" required '' +');
    A('    ''autofocus></label>'' +');
    A('    ''<label><span>Repeat password</span>'' +');
    A('    ''<input type="password" name="password_confirmation" '' +');
    A('    ''autocomplete="new-password" required></label>'' +');
    A('    ''<button type="submit">Save password</button></form>''));');
    A('end;');
    A('');
    A('function TAuthController.DoReset(Req: TRequest): TResponse;');
    A('var');
    A('  Token, Passord, Feil, Epost: string;');
    A('  A: TArena;');
    A('  R: TDbResult;');
    A('  U: TUser;');
    A('begin');
    A('  Token := Req.Form(''token'').ToString;');
    A('  Passord := Req.Form(''password'').ToString;');
    A('');
    A('  Feil := PassordFeil(Passord,');
    A('    Req.Form(''password_confirmation'').ToString);');
    A('  if Feil <> '''' then');
    A('  begin');
    A('    CurrentSession.Flash(''error'', Feil);');
    A('    Exit(Redirect(''/reset-password/'' + Token, 303));');
    A('  end;');
    A('');
    A('  A := CurrentArena;');
    A('  R := CurrentDb.ExecParams(A,');
    A('    ''SELECT email FROM password_resets WHERE token_hash = '' +');
    A('    Plassholder(1) + '' AND expires_at > '' + Plassholder(2),');
    A('    [DbParam(A, Sha256Hex(Token)), DbParam(A, UnixNowMs)]);');
    A('');
    A('  if (R = nil) or R.IsEmpty then');
    A('  begin');
    A('    { Utløpt, brukt opp, eller aldri gyldig. Samme melding for alle');
    A('      tre: hvilken av dem det var er ikke noe den som spør skal få');
    A('      vite. }');
    A('    CurrentSession.Flash(''error'',');
    A('      ''That link is no longer valid. Ask for a new one.'');');
    A('    Exit(Redirect(''/forgot-password'', 303));');
    A('  end;');
    A('');
    A('  Epost := R.Value(0, 0).ToString;');
    A('  U := FinnPaaEpost(Epost);');
    A('  if U = nil then');
    A('    Exit(Redirect(''/forgot-password'', 303));');
    A('');
    A('  U.PasswordHash := HashPassword(Passord);');
    A('  U.Save;');
    A('');
    A('  { Engangsbruk. Alle tokens for adressen slettes, ikke bare det som');
    A('    ble brukt — ba noen om to lenker, skal ikke den andre fortsatt');
    A('    virke. }');
    A('  CurrentDb.ExecParams(A,');
    A('    ''DELETE FROM password_resets WHERE email = '' + Plassholder(1),');
    A('    [DbParam(A, Epost)]);');
    A('');
    A('  { Sesjonen byttes ut. Var noen andre logget inn som denne brukeren,');
    A('    skal de ikke fortsette å være det etter et passordbytte. }');
    A('  NullstillForsok(Epost);');
    A('  Askr.Auth.Login(IntToStr(U.Id));');
    A('  LogInfo(''password reset'', [''user'', U.Id]);');
    A('  Result := Redirect(''/'', 303);');
    A('end;');
    A('');
    A('end.');

    Skriv(IncludeTrailingPathDelimiter(Rot) +
      'app/Http/App.Http.AuthController.pas', L.Text);
  finally
    L.Free;
  end;
end;

{ ---------------------------------------------------------- migrasjonene -- }

procedure SkrivMigrasjoner(const Rot, Versjon: string);
begin
  Skriv(IncludeTrailingPathDelimiter(Rot) +
    'database/App.Migrations.CreateUsers.pas',
    'unit App.Migrations.CreateUsers;' + #10 + #10 +
    '{$mode Delphi}{$H+}' + #10 + #10 +
    'interface' + #10 + #10 +
    'uses' + #10 +
    '  Askr.Norn.Schema, Askr.Norn.Migration;' + #10 + #10 +
    'type' + #10 +
    '  TCreateUsers = class(TMigration)' + #10 +
    '  public' + #10 +
    '    class function Version: string; override;' + #10 +
    '    procedure Up(S: TSchemaBuilder); override;' + #10 +
    '    procedure Down(S: TSchemaBuilder); override;' + #10 +
    '  end;' + #10 + #10 +
    'implementation' + #10 + #10 +
    'class function TCreateUsers.Version: string;' + #10 +
    'begin' + #10 +
    '  Result := ' + Q + Versjon + Q + ';' + #10 +
    'end;' + #10 + #10 +
    'procedure TCreateUsers.Up(S: TSchemaBuilder);' + #10 +
    'begin' + #10 +
    '  with S.Create(' + Q + 'users' + Q + ') do' + #10 +
    '  begin' + #10 +
    '    Id;' + #10 +
    '    Text(' + Q + 'name' + Q + ', 120);' + #10 +
    '    Text(' + Q + 'email' + Q + ', 255).Unique;' + #10 +
    '    { 255 tegn holder til PHC-strengen med god margin. }' + #10 +
    '    Text(' + Q + 'password_hash' + Q + ', 255);' + #10 +
    '    Timestamps;' + #10 +
    '  end;' + #10 +
    'end;' + #10 + #10 +
    'procedure TCreateUsers.Down(S: TSchemaBuilder);' + #10 +
    'begin' + #10 +
    '  S.Drop(' + Q + 'users' + Q + ');' + #10 +
    'end;' + #10 + #10 +
    'initialization' + #10 +
    '  RegisterMigration(TCreateUsers);' + #10 + #10 +
    'end.' + #10);

  Skriv(IncludeTrailingPathDelimiter(Rot) +
    'database/App.Migrations.CreatePasswordResets.pas',
    'unit App.Migrations.CreatePasswordResets;' + #10 + #10 +
    '{$mode Delphi}{$H+}' + #10 + #10 +
    'interface' + #10 + #10 +
    'uses' + #10 +
    '  Askr.Norn.Schema, Askr.Norn.Migration;' + #10 + #10 +
    'type' + #10 +
    '  TCreatePasswordResets = class(TMigration)' + #10 +
    '  public' + #10 +
    '    class function Version: string; override;' + #10 +
    '    procedure Up(S: TSchemaBuilder); override;' + #10 +
    '    procedure Down(S: TSchemaBuilder); override;' + #10 +
    '  end;' + #10 + #10 +
    'implementation' + #10 + #10 +
    'class function TCreatePasswordResets.Version: string;' + #10 +
    'begin' + #10 +
    '  Result := ' + Q + IntToStr(StrToInt64(Versjon) + 1) + Q + ';' + #10 +
    'end;' + #10 + #10 +
    'procedure TCreatePasswordResets.Up(S: TSchemaBuilder);' + #10 +
    'begin' + #10 +
    '  with S.Create(' + Q + 'password_resets' + Q + ') do' + #10 +
    '  begin' + #10 +
    '    Id;' + #10 +
    '    Text(' + Q + 'email' + Q + ', 255);' + #10 +
    '    { Hashen av tokenet, ikke tokenet. En lekket tabell skal ikke' + #10 +
    '      gi noen muligheten til å tilbakestille passord — samme' + #10 +
    '      resonnement som for passordene selv. }' + #10 +
    '    Text(' + Q + 'token_hash' + Q + ', 64).Unique;' + #10 +
    '    { Unix-millisekunder. Et heltall betyr det samme uansett hvilken' + #10 +
    '      tidssone serveren tror den står i. }' + #10 +
    '    BigInt(' + Q + 'expires_at' + Q + ');' + #10 +
    '    BigInt(' + Q + 'created_at' + Q + ');' + #10 +
    '    Index([' + Q + 'email' + Q + ']);' + #10 +
    '  end;' + #10 +
    'end;' + #10 + #10 +
    'procedure TCreatePasswordResets.Down(S: TSchemaBuilder);' + #10 +
    'begin' + #10 +
    '  S.Drop(' + Q + 'password_resets' + Q + ');' + #10 +
    'end;' + #10 + #10 +
    'initialization' + #10 +
    '  RegisterMigration(TCreatePasswordResets);' + #10 + #10 +
    'end.' + #10);
end;

{ ------------------------------------------------------------ app.lpr -- }

const
  MarkorUses = '  App.Http.HomeController;';
  MarkorRuter = '  R.Get(''/demo'', Home.Demo);';

{ Setter inn uses-linja og rutene der `askr new` la igjen dem.

  Finner den ikke markørene — fordi app.lpr er endret, som den skal kunne
  være — gjør den ingenting og sier fra. Å gjette seg til et sted å sette
  inn kode i en fil noen har skrevet selv er verre enn å be dem gjøre det. }
function InstallerRuter(const Rot: string): Boolean;
var
  L: TStringList;
  Sti: string;
  I, IdxUses, IdxRuter: Integer;
begin
  Result := False;
  Sti := IncludeTrailingPathDelimiter(Rot) + 'app.lpr';
  if not FileExists(Sti) then
    Exit;

  L := TStringList.Create;
  try
    L.LoadFromFile(Sti);

    { Allerede installert? Da er det ingenting å gjøre, og det er ikke en
      feil. }
    for I := 0 to L.Count - 1 do
      if Pos('App.Http.AuthController', L[I]) > 0 then
        Exit(True);

    IdxUses := -1;
    IdxRuter := -1;
    for I := 0 to L.Count - 1 do
    begin
      if L[I] = MarkorUses then
        IdxUses := I;
      if L[I] = MarkorRuter then
        IdxRuter := I;
    end;
    if (IdxUses < 0) or (IdxRuter < 0) then
      Exit(False);

    { Bakfra, slik at den første innsettingen ikke flytter den andre. }
    L.Insert(IdxRuter + 1, '  R.Post(''/reset-password'', Auth_.DoReset);');
    L.Insert(IdxRuter + 1, '  R.Get(''/reset-password/:token'', Auth_.ShowReset);');
    L.Insert(IdxRuter + 1, '  R.Post(''/forgot-password'', Auth_.SendReset);');
    L.Insert(IdxRuter + 1, '  R.Get(''/forgot-password'', Auth_.ShowForgot);');
    L.Insert(IdxRuter + 1, '  R.Post(''/logout'', Auth_.DoLogout);');
    L.Insert(IdxRuter + 1, '  R.Post(''/register'', Auth_.DoRegister);');
    L.Insert(IdxRuter + 1, '  R.Get(''/register'', Auth_.ShowRegister);');
    L.Insert(IdxRuter + 1, '  R.Post(''/login'', Auth_.DoLogin);');
    L.Insert(IdxRuter + 1, '  R.Get(''/login'', Auth_.ShowLogin);');
    L.Insert(IdxRuter + 1, '');
    L.Insert(IdxRuter + 1, '  { Innlogging, registrering og passordtilbakestilling. }');

    L.Insert(IdxUses, '  App.Http.AuthController,');
    L.Insert(IdxUses, '  App.Models.User,');

    { Kontrolleren må lages, brukeroppslaget registreres, og cachen settes
      opp for bremsen på innloggingen. Alt tre rett før rutene. }
    for I := 0 to L.Count - 1 do
      if L[I] = '  Home := THomeController.Create;' then
      begin
        L.Insert(I + 1, '  { Askr lagrer bare brukerens id; denne gir resten tilbake. }');
        L.Insert(I + 2, '  SetUserLoader(@LoadUser);');
        L.Insert(I + 3, '  { Brukes av bremsen på innloggingsskjemaet. }');
        L.Insert(I + 4, '  SetCache(TCache.Create);');
        L.Insert(I + 5, '  { Passordtilbakestilling sender e-post. TLogTransport');
        L.Insert(I + 6, '    skriver den til en fil, slik at lenken kan prøves');
        L.Insert(I + 7, '    uten en SMTP-server. Bytt til TSmtpTransport i');
        L.Insert(I + 8, '    produksjon — se docs/mail.md. }');
        L.Insert(I + 9, '  if IsProduction then');
        L.Insert(I + 10, '    SetMail(TMailer.Create(TSmtpTransport.Create(');
        L.Insert(I + 11, '      CfgOrFail(''smtp.host''), Word(CfgInt(''smtp.port'', 587)))))');
        L.Insert(I + 12, '  else');
        L.Insert(I + 13, '    SetMail(TMailer.Create(TLogTransport.Create(''storage/mail.log'')));');
        L.Insert(I + 14, '  Mail.SetDefaultFrom(Cfg(''mail.from'', ''noreply@localhost''), '''');');
        L.Insert(I + 15, '  Auth_ := TAuthController.Create;');
        Break;
      end;

    for I := 0 to L.Count - 1 do
      if L[I] = '  Home: THomeController;' then
      begin
        L.Insert(I + 1, '  Auth_: TAuthController;');
        Break;
      end;

    for I := 0 to L.Count - 1 do
      if L[I] = '  Askr.Session, Askr.Csrf, Askr.Auth,' then
      begin
        L[I] := '  Askr.Session, Askr.Csrf, Askr.Auth, Askr.Cache, Askr.Mail,';
        Break;
      end;

    { Kontrolleren frigjøres der de andre gjør det. }
    for I := L.Count - 1 downto 0 do
      if L[I] = '    Home.Free;' then
      begin
        L.Insert(I + 1, '    Auth_.Free;');
        Break;
      end;

    L.SaveToFile(Sti);
    WriteLn('  edited app.lpr');
    Result := True;
  finally
    L.Free;
  end;
end;

procedure SkrivHjelp;
begin
  WriteLn;
  WriteLn('Could not find the markers in app.lpr. Add this yourself:');
  WriteLn;
  WriteLn('  uses  App.Models.User, App.Http.AuthController,');
  WriteLn('        Askr.Cache, Askr.Mail;');
  WriteLn;
  WriteLn('  SetCache(TCache.Create);');
  WriteLn('  SetMail(TMailer.Create(TLogTransport.Create(''storage/mail.log'')));');
  WriteLn;
  WriteLn('  var Auth_: TAuthController;');
  WriteLn;
  WriteLn('  SetUserLoader(@LoadUser);');
  WriteLn('  SetCache(TCache.Create);');
  WriteLn('  Auth_ := TAuthController.Create;');
  WriteLn;
  WriteLn('  R.Get(''/login'', Auth_.ShowLogin);');
  WriteLn('  R.Post(''/login'', Auth_.DoLogin);');
  WriteLn('  R.Get(''/register'', Auth_.ShowRegister);');
  WriteLn('  R.Post(''/register'', Auth_.DoRegister);');
  WriteLn('  R.Post(''/logout'', Auth_.DoLogout);');
  WriteLn('  R.Get(''/forgot-password'', Auth_.ShowForgot);');
  WriteLn('  R.Post(''/forgot-password'', Auth_.SendReset);');
  WriteLn('  R.Get(''/reset-password/:token'', Auth_.ShowReset);');
  WriteLn('  R.Post(''/reset-password'', Auth_.DoReset);');
end;

procedure LagAuth(const Rot: string; Force: Boolean);
var
  Sti: string;
begin
  Sti := IncludeTrailingPathDelimiter(Rot) +
    'app/Http/App.Http.AuthController.pas';
  if FileExists(Sti) and not Force then
  begin
    WriteLn('Auth is already installed. Pass --force to overwrite it.');
    Halt(1);
  end;

  SkrivBruker(Rot);
  SkrivMigrasjoner(Rot, Tidsstempel);
  SkrivKontroller(Rot);
  OppdaterIndeks(Rot, 'database', 'App.Migrations', 'App.Migrations.');

  if not InstallerRuter(Rot) then
    SkrivHjelp;

  WriteLn;
  WriteLn('Next:');
  WriteLn;
  WriteLn('  askr build');
  WriteLn('  askr migrate');
  WriteLn;
  WriteLn('Then /login, /register and /forgot-password are there.');
  WriteLn('Mail goes through whatever transport you configured; in');
  WriteLn('development a TLogTransport writes the reset link to a file.');
end;

end.
