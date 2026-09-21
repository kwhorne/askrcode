{ Askr.Cli.Auth — generates sign-in, registration and password reset.

  Run by `askr new --auth` and by `askr make auth` in a project that
  already exists.

  **The pages are plain HTML, not Inertia.** A new project has Inertia set
  up, but not installed — `npm install` is something you do afterwards.
  Requiring it before you can sign in would have made sign-in useless
  exactly in the window where it is needed most. The pages use system fonts
  and inline CSS and need neither npm nor a network, like the welcome page.
  The generated code says how they are turned into Inertia pages.

  **Everything generated is yours.** That is the whole point of scaffolding:
  you are supposed to be able to change the sign-in page. That is why the
  templates are here and not in the framework. }
unit Askr.Cli.Auth;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes;

{ Writes the model, the migrations and the controller. Does not touch
  app.lpr — the lines that have to go in there are printed at the end, or
  inserted by InstallerRuter when the markers are there. }
procedure LagAuth(const Rot: string; Force: Boolean);

{ Inserts the uses line and the routes in app.lpr if the markers from
  `askr new` are there. Returns False when they are not, and then the user
  has to do it themselves. }
function InstallerRuter(const Rot: string): Boolean;

implementation

uses
  Askr.Cli.Scaffold;

const
  Q = '''';

{ ------------------------------------------------------------- modellen -- }

procedure WriteUser(const Rot: string);
begin
  Emit(IncludeTrailingPathDelimiter(Rot) + 'app/Models/App.Models.User.pas',
    'unit App.Models.User;' + #10 + #10 +
    '{$mode Delphi}{$H+}' + #10 + #10 +
    'interface' + #10 + #10 +
    'uses' + #10 +
    { TModelList lives in Askr.Urd.Query, not in Askr.Urd.Model. }
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
    '    { The whole PHC string from HashPassword, not just the hash:' + #10 +
    '      it carries the algorithm, the iterations and the salt, and' + #10 +
    '      that is what lets the parameters change without a' + #10 +
    '      migration. }' + #10 +
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
    '  { The password is validated in the controller, not here: the' + #10 +
    '    model never sees the plaintext, only the hash. }' + #10 +
    'end;' + #10 + #10 +
    'end.' + #10);
end;

{ ---------------------------------------------------------- kontrolleren -- }

{ The template is built line by line rather than as one chained string. A
  two-hundred-line controller written as `'...' + #10 +` is not readable for
  whoever has to change it. Quotes are doubled, as in all Pascal. }
procedure WriteControllers(const Rot: string);
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
    A('{ Sign-in, registration and password reset.');
    A('');
    A('  The pages are plain HTML and need neither npm nor a network, so');
    A('  that signing in works from the first build. If you want them as');
    A('  Inertia pages, swap Result := Page(...) for');
    A('  Result := Inertia(''Auth/Login'', [...]) and write the components');
    A('  in frontend/src/pages/Auth/.');
    A('');
    A('  Everything here is yours. The framework does not own your user');
    A('  model — it stores an id as text, and this file looks up the');
    A('  rest. }');
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
    A('  Askr.Core.Json, Askr.WebAuthn,');
    A('  App.Models.Credential,');
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
    A('');
    A('    { After signing in. Plain HTML pages, like the rest of auth: a');
    A('      new project has to be able to sign in AND get somewhere');
    A('      without npm install having been run. If you build the app in');
    A('      Inertia, you swap these three out — they are a starting');
    A('      point, not a frame. }');
    A('    function Dashboard(Req: TRequest): TResponse;');
    A('    function ShowProfile(Req: TRequest): TResponse;');
    A('    function SaveProfile(Req: TRequest): TResponse;');
    A('    function ShowSecurity(Req: TRequest): TResponse;');
    A('    function ChangePassword(Req: TRequest): TResponse;');
    A('');
    A('    { Passkeys. The challenges go through JSON, the rest of auth');
    A('      is forms — the difference is that the browser has to talk to');
    A('      the authenticator between the two steps. }');
    A('    function PasskeyChallenge(Req: TRequest): TResponse;');
    A('    function PasskeyRegister(Req: TRequest): TResponse;');
    A('    function PasskeyDelete(Req: TRequest): TResponse;');
    A('    function LoginChallenge(Req: TRequest): TResponse;');
    A('    function LoginPasskey(Req: TRequest): TResponse;');
    A('  end;');
    A('');
    A('{ Askr stores only the user''s id. This gives back the rest, and');
    A('  is registered with SetUserLoader in app.lpr. }');
    A('function LoadUser(const Id: string): TObject;');
    A('');
    A('implementation');
    A('');
    A('{ -------------------------------------------------------- pages -- }');
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
    A('{ One place for the shell, so that the five pages look the same and');
    A('  can be changed in one place. }');
    A('function Page(const Title, Body: string): string;');
    A('begin');
    A('  Result :=');
    A('    ''<!doctype html><html lang="en"><head><meta charset="utf-8">'' +');
    A('    ''<meta name="viewport" content="width=device-width,initial-scale=1">'' +');
    A('    ''<title>'' + Esc(Title) + ''</title>'' +');
    A('    ''<meta name="csrf-token" content="'' + Esc(CsrfToken) + ''">'' +');
    A('    ''<style>'' +');
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
    A('function Message_(const S, Klasse: string): string;');
    A('begin');
    A('  if S = '''' then');
    A('    Result := ''''');
    A('  else');
    A('    Result := ''<p class="'' + Klasse + ''">'' + Esc(S) + ''</p>'';');
    A('end;');
    A('');
    A('{ The JavaScript for passkeys is further down, but is used by the');
    A('  security page above. }');
    A('function PasskeyJs: string; forward;');
    A('');
    A('{ ---------------------------------------- shell for app pages -- }');
    A('');
    A('{ The name is read from askr.toml at run time, not baked in by the');
    A('  scaffolding: change `name` there and the sidebar follows. }');
    A('function AppNavn: string;');
    A('begin');
    A('  Result := Cfg(''name'', ''Askr'');');
    A('end;');
    A('');
    A('{ Sidebar and content. A shell of its own because the sign-in pages');
    A('  are narrow and centred, while the pages after signing in are an');
    A('  app. The same rule still applies: no npm, no network, no files');
    A('  next to the binary. }');
    A('function Nav(const Href, Etikett, Aktiv: string): string;');
    A('begin');
    A('  Result := ''<a href="'' + Esc(Href) + ''"'';');
    A('  if Href = Aktiv then');
    A('    Result := Result + '' class="on" aria-current="page"'';');
    A('  Result := Result + ''>'' + Esc(Etikett) + ''</a>'';');
    A('end;');
    A('');
    A('function AppShell(const Title, Aktiv, Name_, Body: string): string;');
    A('begin');
    A('  Result :=');
    A('    ''<!doctype html><html lang="en"><head><meta charset="utf-8">'' +');
    A('    ''<meta name="viewport" content="width=device-width,initial-scale=1">'' +');
    A('    ''<title>'' + Esc(Title) + ''</title>'' +');
    A('    ''<meta name="csrf-token" content="'' + Esc(CsrfToken) + ''">'' +');
    A('    ''<style>'' +');
    A('    '':root{--bg:#fff;--panel:#f6f7f8;--fg:#111;--dim:#667;'' +');
    A('    ''--line:#dde;--accent:#2b6;--bad:#c33;--on:#e9ebee}'' +');
    A('    ''@media(prefers-color-scheme:dark){:root{--bg:#0e1113;'' +');
    A('    ''--panel:#15191c;--fg:#e8eef0;--dim:#8a9aa3;--line:#243;'' +');
    A('    ''--accent:#3fe0a8;--bad:#f77;--on:#1e2429}}'' +');
    A('    ''*{box-sizing:border-box}'' +');
    A('    ''body{margin:0;background:var(--bg);color:var(--fg);'' +');
    A('    ''font:15px/1.55 system-ui,-apple-system,"Segoe UI",sans-serif}'' +');
    A('    ''.wrap{display:flex;min-height:100vh}'' +');
    A('    ''aside{width:15rem;flex:0 0 15rem;background:var(--panel);'' +');
    A('    ''border-right:1px solid var(--line);padding:1.25rem 1rem;'' +');
    A('    ''display:flex;flex-direction:column;gap:1.5rem}'' +');
    A('    ''.brand{font-weight:700;letter-spacing:-.01em}'' +');
    A('    ''nav{display:flex;flex-direction:column;gap:.15rem}'' +');
    A('    ''nav a{padding:.45rem .6rem;border-radius:.35rem;'' +');
    A('    ''color:var(--fg);text-decoration:none;font-size:.925rem}'' +');
    A('    ''nav a:hover{background:var(--on)}'' +');
    A('    ''nav a.on{background:var(--on);font-weight:600}'' +');
    A('    ''.who{margin-top:auto;border-top:1px solid var(--line);'' +');
    A('    ''padding-top:1rem;font-size:.9rem}'' +');
    A('    ''.who .n{font-weight:600}'' +');
    A('    ''.who form{margin:.5rem 0 0}'' +');
    A('    ''.who button{background:none;border:0;padding:0;font:inherit;'' +');
    A('    ''color:var(--dim);cursor:pointer;text-decoration:underline}'' +');
    A('    ''main{flex:1;min-width:0;padding:2.5rem 2rem;max-width:56rem}'' +');
    A('    ''h1{font-size:1.65rem;margin:0 0 .35rem}'' +');
    A('    ''h2{font-size:1.05rem;margin:0 0 .35rem}'' +');
    A('    ''.lead{color:var(--dim);margin:0 0 2rem}'' +');
    A('    ''section{display:grid;gap:2rem;grid-template-columns:1fr;'' +');
    A('    ''padding:2rem 0;border-top:1px solid var(--line)}'' +');
    A('    ''@media(min-width:56rem){section{grid-template-columns:16rem 1fr}}'' +');
    A('    ''section>div>p{color:var(--dim);margin:0;font-size:.925rem}'' +');
    A('    ''label{display:block;margin:0 0 1.1rem}'' +');
    A('    ''label>span{display:block;font-weight:600;margin-bottom:.15rem}'' +');
    A('    ''label>em{display:block;font-style:normal;color:var(--dim);'' +');
    A('    ''font-size:.875rem;margin-bottom:.45rem}'' +');
    A('    ''input,textarea{width:100%;padding:.55rem .65rem;font:inherit;'' +');
    A('    ''background:var(--bg);color:var(--fg);'' +');
    A('    ''border:1px solid var(--line);border-radius:.35rem}'' +');
    A('    ''textarea{min-height:7rem;resize:vertical}'' +');
    A('    ''button.go{padding:.55rem 1.1rem;font:inherit;font-weight:600;'' +');
    A('    ''color:#031;background:var(--accent);border:0;'' +');
    A('    ''border-radius:.35rem;cursor:pointer}'' +');
    A('    ''.right{text-align:right}'' +');
    A('    ''.err{color:var(--bad);font-size:.9rem;margin:0 0 1rem}'' +');
    A('    ''.ok{color:var(--accent);font-size:.9rem;margin:0 0 1rem}'' +');
    A('    ''.card{border:1px solid var(--line);border-radius:.5rem;'' +');
    A('    ''padding:1rem 1.1rem;margin:0 0 1rem}'' +');
    A('    ''.card h2{margin:0 0 .25rem;font-size:.975rem}'' +');
    A('    ''.card p{margin:0;color:var(--dim);font-size:.9rem}'' +');
    A('    ''main a{color:inherit}'' +');
    A('    ''.tag{display:inline-block;margin-left:.5rem;padding:.05rem .4rem;'' +');
    A('    ''border:1px solid var(--line);border-radius:.25rem;'' +');
    A('    ''font-size:.75rem;color:var(--dim);vertical-align:.1rem}'' +');
    A('    ''@media(max-width:44rem){.wrap{display:block}'' +');
    A('    ''aside{width:auto;flex:none;border-right:0;'' +');
    A('    ''border-bottom:1px solid var(--line)}'' +');
    A('    ''.who{margin-top:1rem}main{padding:1.5rem 1rem}}'' +');
    A('    ''</style></head><body><div class="wrap"><aside>'' +');
    A('    ''<div class="brand">'' + Esc(AppNavn) + ''</div>'' +');
    A('    ''<nav>'' +');
    A('      Nav(''/dashboard'', ''Home'', Aktiv) +');
    A('      Nav(''/settings/profile'', ''Profile'', Aktiv) +');
    A('      Nav(''/settings/security'', ''Security'', Aktiv) +');
    A('    ''</nav>'' +');
    A('    ''<div class="who"><div class="n">'' + Esc(Name_) + ''</div>'' +');
    A('    ''<form method="post" action="/logout">'' + CsrfField +');
    A('    ''<button type="submit">Sign out</button></form></div>'' +');
    A('    ''</aside><main>'' + Body + ''</main></div></body></html>'';');
    A('end;');
    A('');
    A('{ ------------------------------------------------ placeholders -- }');
    A('');
    A('{ $1 in Postgres, ? in MySQL and SQLite. The driver knows which;');
    A('  this code should not have to. }');
    A('function Plassholder(N: Integer): string;');
    A('var');
    A('  B: TStrBuilder;');
    A('begin');
    A('  B.Init(CurrentArena, 8);');
    A('  CurrentDb.AppendPlaceholder(B, N);');
    A('  Result := B.ToString;');
    A('end;');
    A('');
    A('function Plassholdere(Count_: Integer): string;');
    A('var');
    A('  I: Integer;');
    A('begin');
    A('  Result := '''';');
    A('  for I := 1 to Count_ do');
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
    A('{ ---------------------------------------------------- throttle -- }');
    A('');
    A('{ Without this the sign-in form is a target for guessing at scale.');
    A('  The cache is used if it exists; if it is not set up, we skip the');
    A('  throttle rather than taking sign-in down. It is then in the log.');
    A('');
    A('  The counter is on the email address, not on the IP: an attacker');
    A('  has many IPs and usually only one account to get into. }');
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
    A('      { No cache set up. See the comment above. }');
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
    A('    Exit(Redirect(''/dashboard''));');
    A('  Result := RespondHtml(Page(''Sign in'',');
    A('    ''<h1>Sign in</h1>'' +');
    A('    Message_(CurrentSession.GetFlash(''error''), ''err'') +');
    A('    Message_(CurrentSession.GetFlash(''notice''), ''ok'') +');
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
    A('    ''<p id="pk-msg"></p>'' +');
    A('    ''<p class="alt" style="margin-top:1rem">'' +');
    A('    ''<a href="#" onclick="signInPasskey();return false">'' +');
    A('    ''Sign in with a passkey</a></p>'' +');
    A('    ''<p class="alt"><a href="/forgot-password">Forgot your '' +');
    A('    ''password?</a><br><a href="/register">Create an account</a></p>'' +');
    A('    PasskeyJs));');
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
    A('    { One message for both cases. Say "no such account" and you');
    A('      have built a directory of who is registered. }');
    A('    TellForsok(Epost);');
    A('    CurrentSession.Flash(''error'', ''Those credentials do not match.'');');
    A('    Exit(Redirect(''/login'', 303));');
    A('  end;');
    A('');
    A('  { The password is in hand right now, so a hash made with weaker');
    A('    parameters can be upgraded without asking the user for');
    A('    anything. }');
    A('  if NeedsRehash(U.PasswordHash) then');
    A('  begin');
    A('    U.PasswordHash := HashPassword(Passord);');
    A('    U.Save;');
    A('  end;');
    A('');
    A('  NullstillForsok(Epost);');
    A('  { Login changes the session id. Without it session fixation is');
    A('    wide open. }');
    A('  Askr.Auth.Login(IntToStr(U.Id), Req.Form(''remember'').Len > 0);');
    A('  LogInfo(''login'', [''user'', U.Id]);');
    A('  Result := Redirect(''/dashboard'', 303);');
    A('end;');
    A('');
    A('function TAuthController.DoLogout(Req: TRequest): TResponse;');
    A('begin');
    A('  Askr.Auth.Logout;');
    A('  Result := Redirect(''/dashboard'', 303);');
    A('end;');
    A('');
    A('{ -------------------------------------------------- registrering -- }');
    A('');
    A('function TAuthController.ShowRegister(Req: TRequest): TResponse;');
    A('begin');
    A('  if Askr.Auth.Check then');
    A('    Exit(Redirect(''/dashboard''));');
    A('  Result := RespondHtml(Page(''Create an account'',');
    A('    ''<h1>Create an account</h1>'' +');
    A('    Message_(CurrentSession.GetFlash(''error''), ''err'') +');
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
    A('{ The minimum is in one place, so that registration and reset cannot');
    A('  disagree. Twelve characters is OWASP''s recommendation for a');
    A('  password with no other requirements; rules about capitals and');
    A('  digits give weaker passwords in practice, because people make');
    A('  Password1! }');
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
    A('  Passord, Err: string;');
    A('begin');
    A('  Passord := Req.Form(''password'').ToString;');
    A('  Err := PassordFeil(Passord,');
    A('    Req.Form(''password_confirmation'').ToString);');
    A('  if Err <> '''' then');
    A('  begin');
    A('    CurrentSession.Flash(''error'', Err);');
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
    A('  { The plaintext goes no further than this. }');
    A('  U.PasswordHash := HashPassword(Passord);');
    A('  U.Save;');
    A('');
    A('  Askr.Auth.Login(IntToStr(U.Id));');
    A('  LogInfo(''registered'', [''user'', U.Id]);');
    A('  Result := Redirect(''/dashboard'', 303);');
    A('end;');
    A('');

    A('{ ------------------------------------------ passordtilbakestilling -- }');
    A('');
    A('function TAuthController.ShowForgot(Req: TRequest): TResponse;');
    A('begin');
    A('  Result := RespondHtml(Page(''Reset your password'',');
    A('    ''<h1>Reset your password</h1>'' +');
    A('    Message_(CurrentSession.GetFlash(''notice''), ''ok'') +');
    A('    ''<form method="post" action="/forgot-password">'' + CsrfField +');
    A('    ''<label><span>Email</span>'' +');
    A('    ''<input type="email" name="email" required autofocus></label>'' +');
    A('    ''<button type="submit">Send reset link</button></form>'' +');
    A('    ''<p class="alt"><a href="/login">Back to sign in</a></p>''));');
    A('end;');
    A('');
    A('const');
    A('  { One hour. Long enough that an email can sit for a while, short');
    A('    enough that an old inbox is not a key. }');
    A('  ResetLevetidMs = 60 * 60 * 1000;');
    A('');
    A('function TAuthController.SendReset(Req: TRequest): TResponse;');
    A('var');
    A('  Epost, Token, Link_: string;');
    A('  U: TUser;');
    A('  A: TArena;');
    A('  M: TMailMessage;');
    A('begin');
    A('  Epost := LowerCase(Trim(Req.Form(''email'').ToString));');
    A('  U := FinnPaaEpost(Epost);');
    A('');
    A('  { The same answer whether or not the address exists. Anything else');
    A('    turns the form into a directory of who is registered. }');
    A('  CurrentSession.Flash(''notice'',');
    A('    ''If that address has an account, a link is on its way.'');');
    A('');
    A('  if U <> nil then');
    A('  begin');
    A('    Token := RandomToken(32);');
    A('    A := CurrentArena;');
    A('    { The hash is stored, not the token. A leaked table must not give');
    A('      anybody the ability to reset passwords. }');
    A('    CurrentDb.ExecParams(A,');
    A('      ''INSERT INTO password_resets (email, token_hash, expires_at, '' +');
    A('      ''created_at) VALUES ('' + Plassholdere(4) + '')'',');
    A('      [DbParam(A, Epost), DbParam(A, Sha256Hex(Token)),');
    A('       DbParam(A, UnixNowMs + ResetLevetidMs), DbParam(A, UnixNowMs)]);');
    A('');
    A('    Link_ := Cfg(''app.url'', ''http://127.0.0.1:8080'') +');
    A('      ''/reset-password/'' + Token;');
    A('');
    A('    { In development TLogTransport writes the email to a file, so');
    A('      that the link can actually be tried without an SMTP server. }');
    A('    M := Mail.Message_;');
    A('    M.AddTo(Epost).Subject(''Reset your password'')');
    A('     .Text(''Open this link to choose a new password:'' + #10 + #10 +');
    A('           Link_ + #10 + #10 + ''It expires in one hour.'');');
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
    A('    Message_(CurrentSession.GetFlash(''error''), ''err'') +');
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
    A('  Token, Passord, Err, Epost: string;');
    A('  A: TArena;');
    A('  R: TDbResult;');
    A('  U: TUser;');
    A('begin');
    A('  Token := Req.Form(''token'').ToString;');
    A('  Passord := Req.Form(''password'').ToString;');
    A('');
    A('  Err := PassordFeil(Passord,');
    A('    Req.Form(''password_confirmation'').ToString);');
    A('  if Err <> '''' then');
    A('  begin');
    A('    CurrentSession.Flash(''error'', Err);');
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
    A('    { Expired, used up, or never valid. The same message for all');
    A('      three: which of them it was is not something the asker gets to');
    A('      know. }');
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
    A('  { Single use. All tokens for the address are deleted, not only');
    A('    the one that was used — if somebody asked for two links, the');
    A('    other one must not still work. }');
    A('  CurrentDb.ExecParams(A,');
    A('    ''DELETE FROM password_resets WHERE email = '' + Plassholder(1),');
    A('    [DbParam(A, Epost)]);');
    A('');
    A('  { The session is swapped. If somebody else was signed in as this');
    A('    user, they must not stay that way after a password change. }');
    A('  NullstillForsok(Epost);');
    A('  Askr.Auth.Login(IntToStr(U.Id));');
    A('  LogInfo(''password reset'', [''user'', U.Id]);');
    A('  Result := Redirect(''/dashboard'', 303);');
    A('end;');
    A('');
    A('{ --------------------------------------------- after sign-in -- }');
    A('');
    A('{ The signed-in user, or nil. The guard is in app.lpr, so this');
    A('  should never give nil in practice — but a handler that assumes it');
    A('  and is wrong crashes with an access violation instead of sending');
    A('  you to the sign-in page. }');
    A('function Meg: TUser;');
    A('begin');
    A('  Result := TUser(Askr.Auth.User);');
    A('end;');
    A('');
    A('function TAuthController.Dashboard(Req: TRequest): TResponse;');
    A('var');
    A('  U: TUser;');
    A('  B: string;');
    A('begin');
    A('  U := Meg;');
    A('  if U = nil then');
    A('    Exit(Redirect(''/login'', 303));');
    A('');
    A('  B :=');
    A('    ''<h1>Welcome back, '' + Esc(U.Name) + ''</h1>'' +');
    A('    ''<p class="lead">This is the page people land on after they'' +');
    A('    '' sign in. It is yours to replace.</p>'' +');
    A('    ''<div class="card"><h2>Where this comes from</h2>'' +');
    A('    ''<p>app/Http/App.Http.AuthController.pas, written by'' +');
    A('    '' <code>askr make auth</code>. It is plain HTML on purpose:'' +');
    A('    '' signing in has to work before <code>npm install</code> has'' +');
    A('    '' been run. Build the real thing in Inertia and point'' +');
    A('    '' <code>/dashboard</code> at it.</p></div>'' +');
    A('    ''<div class="card"><h2>Your account</h2>'' +');
    A('    ''<p>'' + Esc(U.Email) + '' &middot; <a href="/settings/profile">'' +');
    A('    ''Edit profile</a></p></div>'';');
    A('');
    A('  Result := RespondHtml(AppShell(''Home'', ''/dashboard'', U.Name, B));');
    A('end;');
    A('');
    A('{ ------------------------------------------------------ profil -- }');
    A('');
    A('function ProfilSide(U: TUser; const Err, Ok: string): string;');
    A('begin');
    A('  Result :=');
    A('    ''<h1>Settings</h1>'' +');
    A('    ''<p class="lead">Your account, and how it is secured.</p>'' +');
    A('    ''<section><div><h2>Profile</h2>'' +');
    A('    ''<p>This is how others will see you.</p></div><div>'' +');
    A('    Message_(Err, ''err'') + Message_(Ok, ''ok'') +');
    A('    ''<form method="post" action="/settings/profile">'' + CsrfField +');
    A('    ''<label><span>Name</span>'' +');
    A('    ''<em>Your display name. It can be your real name or a'' +');
    A('    '' pseudonym.</em>'' +');
    A('    ''<input name="name" value="'' + Esc(U.Name) + ''"'' +');
    A('    '' maxlength="120" required></label>'' +');
    A('    ''<label><span>Email</span>'' +');
    A('    ''<em>Used to sign in, and to reset your password.</em>'' +');
    A('    ''<input name="email" type="email" value="'' + Esc(U.Email) +');
    A('    ''" maxlength="255" required></label>'' +');
    A('    ''<p class="right"><button class="go" type="submit">'' +');
    A('    ''Save profile</button></p>'' +');
    A('    ''</form></div></section>'';');
    A('end;');
    A('');
    A('function TAuthController.ShowProfile(Req: TRequest): TResponse;');
    A('var');
    A('  U: TUser;');
    A('begin');
    A('  U := Meg;');
    A('  if U = nil then');
    A('    Exit(Redirect(''/login'', 303));');
    A('  Result := RespondHtml(AppShell(''Profile'', ''/settings/profile'', U.Name,');
    A('    ProfilSide(U, '''', CurrentSession.GetFlash(''profile_ok''))));');
    A('end;');
    A('');
    A('function TAuthController.SaveProfile(Req: TRequest): TResponse;');
    A('var');
    A('  U, Annen: TUser;');
    A('  Name_, Epost: string;');
    A('begin');
    A('  U := Meg;');
    A('  if U = nil then');
    A('    Exit(Redirect(''/login'', 303));');
    A('');
    A('  Name_ := Trim(Req.Form(''name'').ToString);');
    A('  Epost := LowerCase(Trim(Req.Form(''email'').ToString));');
    A('');
    A('  if Name_ = '''' then');
    A('    Exit(RespondHtml(AppShell(''Profile'', ''/settings/profile'', U.Name,');
    A('      ProfilSide(U, ''Name is required.'', ''''))));');
    A('  if (Epost = '''') or (Pos(''@'', Epost) < 2) then');
    A('    Exit(RespondHtml(AppShell(''Profile'', ''/settings/profile'', U.Name,');
    A('      ProfilSide(U, ''That does not look like an email address.'', ''''))));');
    A('');
    A('  { A unique email is enforced in the database. Letting the INSERT');
    A('    fail would have given a 500 instead of a form with an error. }');
    A('  if Epost <> LowerCase(U.Email) then');
    A('  begin');
    A('    Annen := FinnPaaEpost(Epost);');
    A('    if (Annen <> nil) and (Annen.Id <> U.Id) then');
    A('      Exit(RespondHtml(AppShell(''Profile'', ''/settings/profile'', U.Name,');
    A('        ProfilSide(U, ''That email is already in use.'', ''''))));');
    A('  end;');
    A('');
    A('  U.Name := Name_;');
    A('  U.Email := Epost;');
    A('  U.Save;');
    A('  LogInfo(''profile updated'', [''user'', U.Id]);');
    A('  CurrentSession.Flash(''profile_ok'', ''Saved.'');');
    A('  Result := Redirect(''/settings/profile'', 303);');
    A('end;');
    A('');
    A('{ ---------------------------------------------------- security -- }');
    A('');
    A('{ The list of registered passkeys. The date is the only thing that');
    A('  tells two keys apart for whoever is looking. }');
    A('function PasskeyListe(U: TUser): string;');
    A('var');
    A('  L: TCredentialList;');
    A('  I: Integer;');
    A('begin');
    A('  L := TQuery<TCredential>.New');
    A('    .Where(ColInt64(' + Q + 'credentials' + Q + ', ' + Q + 'user_id' + Q + '), Eq, U.Id)');
    A('    .OrderBy(ColDateTime(' + Q + 'credentials' + Q + ', ' + Q + 'created_at' + Q + '))');
    A('    .Get;');
    A('  if L.Count = 0 then');
    A('    Exit(''<p class="lead">No passkeys yet. Add one and you can'' +');
    A('      '' sign in without a password.</p>'');');
    A('  Result := '''';');
    A('  for I := 0 to L.Count - 1 do');
    A('    Result := Result +');
    A('      ''<div class="card">'' +');
    A('      ''<form method="post" action="/settings/passkeys/'' +');
    A('      IntToStr(L[I].Id) + ''/delete" style="float:right;margin:0">'' +');
    A('      CsrfField +');
    A('      ''<button type="submit" style="background:none;border:0;'' +');
    A('      ''color:var(--dim);cursor:pointer;font:inherit;'' +');
    A('      ''text-decoration:underline">Remove</button></form>'' +');
    A('      ''<h2>'' + Esc(L[I].Nickname) + ''</h2>'' +');
    A('      ''<p>Added '' + FormatDateTime(''yyyy-mm-dd'', L[I].CreatedAt) +');
    A('      ''</p></div>'';');
    A('end;');
    A('');
    A('function SikkerhetSide(const Err, Ok, Noklene: string): string;');
    A('begin');
    A('  Result :=');
    A('    ''<h1>Security</h1>'' +');
    A('    ''<p class="lead">How you prove it is you.</p>'' +');
    A('    ''<section><div><h2>Password</h2>'' +');
    A('    ''<p>Changing it signs out every other session.</p></div><div>'' +');
    A('    Message_(Err, ''err'') + Message_(Ok, ''ok'') +');
    A('    ''<form method="post" action="/settings/security">'' + CsrfField +');
    A('    ''<label><span>Current password</span>'' +');
    A('    ''<input name="current" type="password" required></label>'' +');
    A('    ''<label><span>New password</span>'' +');
    A('    ''<em>At least 8 characters.</em>'' +');
    A('    ''<input name="password" type="password" required></label>'' +');
    A('    ''<label><span>Repeat new password</span>'' +');
    A('    ''<input name="password_confirmation" type="password" required>'' +');
    A('    ''</label>'' +');
    A('    ''<p class="right"><button class="go" type="submit">'' +');
    A('    ''Change password</button></p></form></div></section>'' +');
    A('');
    A('    { It is here because this is where people look for it. That it');
    A('      does not exist yet is said outright — a button that does');
    A('      nothing is worse than a sentence explaining why. }');
    A('    ''<section><div><h2>Passkeys</h2>'' +');
    A('    ''<p>Sign in with Touch ID, Windows Hello or a security'' +');
    A('    '' key.</p></div><div>'' +');
    A('    Noklene +');
    A('    ''<p id="pk-msg"></p>'' +');
    A('    ''<p><button class="go" type="button" onclick="addPasskey()">'' +');
    A('    ''Add a passkey</button></p>'' +');
    A('    ''</div></section>'' + PasskeyJs;');
    A('end;');
    A('');
    A('function TAuthController.ShowSecurity(Req: TRequest): TResponse;');
    A('var');
    A('  U: TUser;');
    A('begin');
    A('  U := Meg;');
    A('  if U = nil then');
    A('    Exit(Redirect(''/login'', 303));');
    A('  Result := RespondHtml(AppShell(''Security'', ''/settings/security'', U.Name,');
    A('    SikkerhetSide('''', CurrentSession.GetFlash(''security_ok''),');
    A('      PasskeyListe(U))));');
    A('end;');
    A('');
    A('function TAuthController.ChangePassword(Req: TRequest): TResponse;');
    A('var');
    A('  U: TUser;');
    A('  Now_, Nytt, Err: string;');
    A('');
    A('  function Avvis(const M: string): TResponse;');
    A('  begin');
    A('    Result := RespondHtml(AppShell(''Security'', ''/settings/security'', U.Name,');
    A('      SikkerhetSide(M, '''', PasskeyListe(U))));');
    A('  end;');
    A('');
    A('begin');
    A('  U := Meg;');
    A('  if U = nil then');
    A('    Exit(Redirect(''/login'', 303));');
    A('');
    A('  Now_ := Req.Form(''current'').ToString;');
    A('  Nytt := Req.Form(''password'').ToString;');
    A('');
    A('  { The old password is required even though you are already signed');
    A('    in: without it an unattended machine can be taken over for good');
    A('    by whoever walks past. }');
    A('  if not VerifyPassword(Now_, U.PasswordHash) then');
    A('    Exit(Avvis(''That is not your current password.''));');
    A('');
    A('  Err := PassordFeil(Nytt, Req.Form(''password_confirmation'').ToString);');
    A('  if Err <> '''' then');
    A('    Exit(Avvis(Err));');
    A('');
    A('  U.PasswordHash := HashPassword(Nytt);');
    A('  U.Save;');
    A('');
    A('  { The same reason as at reset: if somebody else was signed in as');
    A('    this user, they must not stay that way. Login changes the');
    A('    session id. }');
    A('  Askr.Auth.Login(IntToStr(U.Id));');
    A('  LogInfo(''password changed'', [''user'', U.Id]);');
    A('  CurrentSession.Flash(''security_ok'', ''Password changed.'');');
    A('  Result := Redirect(''/settings/security'', 303);');
    A('end;');
    A('');
    A('{ JavaScript for the two ceremonies.');
    A('');
    A('  Inline for the same reason as everything else here: signing in has');
    A('  to work before npm install. It is around thirty lines, and all');
    A('  they do is translate between base64url and ArrayBuffer and call');
    A('  navigator.credentials. }');
    A('function PasskeyJs: string;');
    A('begin');
    A('  Result :=');
    A('    ''<script>'' +');
    A('    ''const b64d=s=>{s=s.replace(/-/g,"+").replace(/_/g,"/");'' +');
    A('    ''const b=atob(s+"=".repeat((4-s.length%4)%4));'' +');
    A('    ''const u=new Uint8Array(b.length);'' +');
    A('    ''for(let i=0;i<b.length;i++)u[i]=b.charCodeAt(i);return u};'' +');
    A('    ''const b64e=b=>btoa(String.fromCharCode(...new Uint8Array(b)))'' +');
    A('    ''.replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/,"");'' +');
    A('    ''const say=(id,m,bad)=>{const e=document.getElementById(id);'' +');
    A('    ''if(!e)return;e.textContent=m;e.className=bad?"err":"ok"};'' +');
    A('    ''async function addPasskey(){'' +');
    A('    ''  if(!window.PublicKeyCredential)'' +');
    A('    ''    return say("pk-msg","This browser does not support passkeys.",1);'' +');
    A('    ''  try{'' +');
    A('    ''    const o=await (await fetch("/settings/passkeys/challenge")).json();'' +');
    A('    ''    if(o.error)return say("pk-msg",o.error,1);'' +');
    A('    ''    const c=await navigator.credentials.create({publicKey:{'' +');
    A('    ''      challenge:b64d(o.challenge),'' +');
    A('    ''      rp:{id:o.rpId,name:o.rpName},'' +');
    A('    ''      user:{id:b64d(o.userId),name:o.userName,'' +');
    A('    ''            displayName:o.userDisplayName},'' +');
    A('    ''      pubKeyCredParams:[{type:"public-key",alg:-7}],'' +');
    A('    ''      excludeCredentials:(o.exclude||[]).map(id=>'' +');
    A('    ''        ({type:"public-key",id:b64d(id)})),'' +');
    A('    ''      authenticatorSelection:{residentKey:"preferred",'' +');
    A('    ''        userVerification:"preferred"},'' +');
    A('    ''      timeout:60000,attestation:"none"}});'' +');
    A('    ''    const r=await fetch("/settings/passkeys",{method:"POST",'' +');
    A('    ''      headers:{"Content-Type":"application/json",'' +');
    A('    ''               "X-CSRF-Token":document.querySelector'' +');
    A('    ''                 ("meta[name=csrf-token]").content},'' +');
    A('    ''      body:JSON.stringify({'' +');
    A('    ''        clientDataJSON:b64e(c.response.clientDataJSON),'' +');
    A('    ''        attestationObject:b64e(c.response.attestationObject),'' +');
    A('    ''        label:navigator.platform||"Passkey"})});'' +');
    A('    ''    const j=await r.json();'' +');
    A('    ''    if(j.ok)location.reload();else say("pk-msg",j.error||"Failed.",1);'' +');
    A('    ''  }catch(e){say("pk-msg",e.name==="NotAllowedError"?'' +');
    A('    ''    "Cancelled.":"Could not add that passkey.",1)}}'' +');
    A('    ''async function signInPasskey(){'' +');
    A('    ''  if(!window.PublicKeyCredential)'' +');
    A('    ''    return say("pk-msg","This browser does not support passkeys.",1);'' +');
    A('    ''  try{'' +');
    A('    ''    const o=await (await fetch("/login/passkey/challenge")).json();'' +');
    A('    ''    const c=await navigator.credentials.get({publicKey:{'' +');
    A('    ''      challenge:b64d(o.challenge),rpId:o.rpId,'' +');
    A('    ''      userVerification:"preferred",timeout:60000}});'' +');
    A('    ''    const r=await fetch("/login/passkey",{method:"POST",'' +');
    A('    ''      headers:{"Content-Type":"application/json",'' +');
    A('    ''               "X-CSRF-Token":document.querySelector'' +');
    A('    ''                 ("meta[name=csrf-token]").content},'' +');
    A('    ''      body:JSON.stringify({id:b64e(c.rawId),'' +');
    A('    ''        clientDataJSON:b64e(c.response.clientDataJSON),'' +');
    A('    ''        authenticatorData:b64e(c.response.authenticatorData),'' +');
    A('    ''        signature:b64e(c.response.signature)})});'' +');
    A('    ''    const j=await r.json();'' +');
    A('    ''    if(j.ok)location.href="/dashboard";'' +');
    A('    ''    else say("pk-msg",j.error||"Failed.",1);'' +');
    A('    ''  }catch(e){say("pk-msg",e.name==="NotAllowedError"?'' +');
    A('    ''    "Cancelled.":"Could not sign in with a passkey.",1)}}'' +');
    A('    ''</script>'';');
    A('end;');
    A('');
    A('{ Askr.Urd.Bind''s JsonRoot is internal, so the body is parsed here.');
    A('  It is read twice at worst, and that is a few hundred bytes. }');
    A('function Body_(Req: TRequest): PJsonValue;');
    A('var');
    A('  ErrPos: SizeInt;');
    A('begin');
    A('  Result := nil;');
    A('  if (not Req.IsJson) or (Req.Body.Len = 0) then');
    A('    Exit;');
    A('  if not JsonParse(Req.Arena, Req.Body, Result, ErrPos) then');
    A('    Result := nil;');
    A('end;');
    A('');
    A('function StrBytes(const S: string): TBytes;');
    A('var');
    A('  I: Integer;');
    A('  B: TBytes;');
    A('begin');
    A('  B := nil;');
    A('  SetLength(B, Length(S));');
    A('  for I := 1 to Length(S) do');
    A('    B[I - 1] := Byte(S[I]);');
    A('  Result := B;');
    A('end;');
    A('');
    A('{ ------------------------------------------------------ passkeys -- }');
    A('');
    A('{ RP ID og origin.');
    A('');
    A('  The defaults are derived from the request, so that `askr serve`');
    A('  works without any setup — WebAuthn counts localhost as a secure');
    A('  context, so that is enough in development. In production they');
    A('  should be set in askr.toml:');
    A('');
    A('    [webauthn]');
    A('    rp_id  = "example.com"');
    A('    origin = "https://example.com"');
    A('');
    A('  The reason is that the Host header comes from the client. A wrong');
    A('  value is not a hole in itself — the browser refuses to use a');
    A('  passkey on the wrong domain anyway — but a fixed value is what');
    A('  makes the server say no too, and not only the browser. }');
    A('function WaOpts(Req: TRequest): TWebAuthnOptions;');
    A('var');
    A('  Vert: string;');
    A('  P: Integer;');
    A('begin');
    A('  Result.RequireUserVerification := False;');
    A('  Result.RpId := Cfg(' + Q + 'webauthn.rp_id' + Q + ', ' + Q + Q + ');');
    A('  Result.Origin := Cfg(' + Q + 'webauthn.origin' + Q + ', ' + Q + Q + ');');
    A('  if (Result.RpId <> ' + Q + Q + ') and (Result.Origin <> ' + Q + Q + ') then');
    A('    Exit;');
    A('');
    A('  Vert := Req.Header(' + Q + 'Host' + Q + ').ToString;');
    A('  if Vert = ' + Q + Q + ' then');
    A('    Vert := ' + Q + 'localhost' + Q + ';');
    A('  if Result.Origin = ' + Q + Q + ' then');
    A('  begin');
    A('    { Only localhost gets away without https. That is the browser''''s');
    A('      rule, not ours, and guessing wrong here gives an error message');
    A('      that explains nothing. }');
    A('    if (Pos(' + Q + 'localhost' + Q + ', Vert) = 1) or');
    A('       (Pos(' + Q + '127.0.0.1' + Q + ', Vert) = 1) then');
    A('      Result.Origin := ' + Q + 'http://' + Q + ' + Vert');
    A('    else');
    A('      Result.Origin := ' + Q + 'https://' + Q + ' + Vert;');
    A('  end;');
    A('  if Result.RpId = ' + Q + Q + ' then');
    A('  begin');
    A('    { RP ID er domenet uten port. }');
    A('    P := Pos(' + Q + ':' + Q + ', Vert);');
    A('    if P > 0 then');
    A('      Result.RpId := Copy(Vert, 1, P - 1)');
    A('    else');
    A('      Result.RpId := Vert;');
    A('  end;');
    A('end;');
    A('');
    A('{ WebAuthn does not accept an IP address as an RP ID — it has to be');
    A('  a domain name. localhost is valid; 127.0.0.1 is not, and the');
    A('  browser then answers only "This is an invalid domain", which does');
    A('  not say what to do. So it is said here instead. }');
    A('function ErIpAdresse(const S: string): Boolean;');
    A('var');
    A('  I: Integer;');
    A('begin');
    A('  Result := S <> ' + Q + Q + ';');
    A('  for I := 1 to Length(S) do');
    A('    if not (S[I] in [' + Q + '0' + Q + '..' + Q + '9' + Q + ', ' + Q + '.' + Q + ']) then');
    A('      Exit(False);');
    A('end;');
    A('');
    A('{ The challenge is kept in the session until the answer arrives.');
    A('  Without it an attacker could replay an old answer. }');
    A('function NyUtfordring: string;');
    A('begin');
    A('  Result := Base64UrlEncode(NewChallenge);');
    A('  CurrentSession.Put(' + Q + 'wa_challenge' + Q + ', Result);');
    A('end;');
    A('');
    A('function LagretUtfordring: TBytes;');
    A('var');
    A('  S: string;');
    A('begin');
    A('  S := CurrentSession.Get(' + Q + 'wa_challenge' + Q + ');');
    A('  { It is used once. Left lying about, it can be used again. }');
    A('  CurrentSession.Forget(' + Q + 'wa_challenge' + Q + ');');
    A('  Result := Base64UrlDecode(S);');
    A('end;');
    A('');
    A('function JsonSvar(const S: string): TResponse;');
    A('begin');
    A('  Result := RespondJson(S);');
    A('end;');
    A('');
    A('function JsonFeil(const Message_: string; Status: Integer): TResponse;');
    A('var');
    A('  W: TJsonWriter;');
    A('begin');
    A('  W.Init(CurrentArena, 256);');
    A('  W.BeginObject;');
    A('  W.Field(' + Q + 'error' + Q + ', Message_);');
    A('  W.EndObject;');
    A('  Result := RespondJson(W.ToString, Status);');
    A('end;');
    A('');
    A('{ Kroppen er JSON fra vaar egen JS. Feltene er base64url. }');
    A('function JsonFelt(Req: TRequest; const Name_: string): TBytes;');
    A('var');
    A('  V: PJsonValue;');
    A('begin');
    A('  Result := nil;');
    A('  V := Body_(Req);');
    A('  if V = nil then');
    A('    Exit;');
    A('  V := JsonMember(V, Name_);');
    A('  if V = nil then');
    A('    Exit;');
    A('  Result := Base64UrlDecode(JsonAsString(V));');
    A('end;');
    A('');
    A('function TAuthController.PasskeyChallenge(Req: TRequest): TResponse;');
    A('var');
    A('  U: TUser;');
    A('  W: TJsonWriter;');
    A('  O: TWebAuthnOptions;');
    A('  Liste: TCredentialList;');
    A('  I: Integer;');
    A('begin');
    A('  U := Meg;');
    A('  if U = nil then');
    A('    Exit(JsonFeil(' + Q + 'Not signed in.' + Q + ', 401));');
    A('  O := WaOpts(Req);');
    A('  if ErIpAdresse(O.RpId) then');
    A('    Exit(JsonFeil(' + Q + 'Passkeys need a domain name, not an IP ' + Q + ' +');
    A('      ' + Q + 'address. Use localhost in development, or set ' + Q + ' +');
    A('      ' + Q + '[webauthn] rp_id in askr.toml.' + Q + ', 400));');
    A('');
    A('  W.Init(Req.Arena, 1024);');
    A('  W.BeginObject;');
    A('  W.Field(' + Q + 'challenge' + Q + ', NyUtfordring);');
    A('  W.Field(' + Q + 'rpId' + Q + ', O.RpId);');
    A('  W.Field(' + Q + 'rpName' + Q + ', AppNavn);');
    A('  W.Field(' + Q + 'userId' + Q + ', Base64UrlEncode(StrBytes(IntToStr(U.Id))));');
    A('  W.Field(' + Q + 'userName' + Q + ', U.Email);');
    A('  W.Field(' + Q + 'userDisplayName' + Q + ', U.Name);');
    A('  { Keys the user already has, so that the authenticator does not');
    A('    make a new one for the same account. }');
    A('  W.Key(' + Q + 'exclude' + Q + ');');
    A('  W.BeginArray;');
    A('  Liste := TQuery<TCredential>.New');
    A('    .Where(ColInt64(' + Q + 'credentials' + Q + ', ' + Q + 'user_id' + Q + '), Eq, U.Id).Get;');
    A('  for I := 0 to Liste.Count - 1 do');
    A('    W.Str(Liste[I].CredentialId);');
    A('  W.EndArray;');
    A('  W.EndObject;');
    A('  Result := JsonSvar(W.ToString);');
    A('end;');
    A('');
    A('function TAuthController.PasskeyRegister(Req: TRequest): TResponse;');
    A('var');
    A('  U: TUser;');
    A('  Reg: TRegistration;');
    A('  C: TCredential;');
    A('  Name_: string;');
    A('  V: PJsonValue;');
    A('begin');
    A('  U := Meg;');
    A('  if U = nil then');
    A('    Exit(JsonFeil(' + Q + 'Not signed in.' + Q + ', 401));');
    A('');
    A('  Reg := VerifyRegistration(WaOpts(Req),');
    A('    JsonFelt(Req, ' + Q + 'clientDataJSON' + Q + '),');
    A('    JsonFelt(Req, ' + Q + 'attestationObject' + Q + '),');
    A('    LagretUtfordring);');
    A('  if not Reg.Ok then');
    A('  begin');
    A('    LogInfo(' + Q + 'passkey registration refused' + Q + ',');
    A('      [' + Q + 'user' + Q + ', U.Id, ' + Q + 'reason' + Q + ', Reg.Error]);');
    A('    Exit(JsonFeil(Reg.Error, 400));');
    A('  end;');
    A('');
    A('  Name_ := ' + Q + Q + ';');
    A('  V := Body_(Req);');
    A('  if V <> nil then');
    A('  begin');
    A('    V := JsonMember(V, ' + Q + 'label' + Q + ');');
    A('    if V <> nil then');
    A('      Name_ := Trim(JsonAsString(V));');
    A('  end;');
    A('  if Name_ = ' + Q + Q + ' then');
    A('    Name_ := ' + Q + 'Passkey' + Q + ';');
    A('  if Length(Name_) > 120 then');
    A('    Name_ := Copy(Name_, 1, 120);');
    A('');
    A('  C := Req.Arena.New<TCredential>;');
    A('  C.UserId := U.Id;');
    A('  C.CredentialId := Base64UrlEncode(Reg.CredentialId);');
    A('  C.PublicKeyX := HexEncode(Reg.PublicKeyX);');
    A('  C.PublicKeyY := HexEncode(Reg.PublicKeyY);');
    A('  C.SignCount := Reg.SignCount;');
    A('  C.Nickname := Name_;');
    A('  C.Save;');
    A('  LogInfo(' + Q + 'passkey registered' + Q + ', [' + Q + 'user' + Q + ', U.Id]);');
    A('  Result := JsonSvar(' + Q + '{"ok":true}' + Q + ');');
    A('end;');
    A('');
    A('function TAuthController.PasskeyDelete(Req: TRequest): TResponse;');
    A('var');
    A('  U: TUser;');
    A('  C: TCredential;');
    A('begin');
    A('  U := Meg;');
    A('  if U = nil then');
    A('    Exit(Redirect(' + Q + '/login' + Q + ', 303));');
    A('  { The ownership has to be checked. Without it anybody can delete');
    A('    somebody else''''s keys by guessing an id. }');
    A('  C := TQuery<TCredential>.New');
    A('    .Where(ColInt64(' + Q + 'credentials' + Q + ', ' + Q + 'id' + Q + '), Eq,');
    A('      StrToInt64Def(Req.Param(' + Q + 'id' + Q + ').ToString, 0))');
    A('    .Where(ColInt64(' + Q + 'credentials' + Q + ', ' + Q + 'user_id' + Q + '), Eq, U.Id)');
    A('    .First;');
    A('  if C <> nil then');
    A('  begin');
    A('    C.Delete;');
    A('    LogInfo(' + Q + 'passkey removed' + Q + ', [' + Q + 'user' + Q + ', U.Id]);');
    A('    CurrentSession.Flash(' + Q + 'security_ok' + Q + ', ' + Q + 'Passkey removed.' + Q + ');');
    A('  end;');
    A('  Result := Redirect(' + Q + '/settings/security' + Q + ', 303);');
    A('end;');
    A('');
    A('function TAuthController.LoginChallenge(Req: TRequest): TResponse;');
    A('var');
    A('  W: TJsonWriter;');
    A('begin');
    A('  if ErIpAdresse(WaOpts(Req).RpId) then');
    A('    Exit(JsonFeil(' + Q + 'Passkeys need a domain name, not an IP ' + Q + ' +');
    A('      ' + Q + 'address.' + Q + ', 400));');
    A('  W.Init(Req.Arena, 256);');
    A('  W.BeginObject;');
    A('  W.Field(' + Q + 'challenge' + Q + ', NyUtfordring);');
    A('  W.Field(' + Q + 'rpId' + Q + ', WaOpts(Req).RpId);');
    A('  W.EndObject;');
    A('  { No list of keys: it would give away who has an account here.');
    A('    The browser finds a passkey for this domain by itself. }');
    A('  Result := JsonSvar(W.ToString);');
    A('end;');
    A('');
    A('function TAuthController.LoginPasskey(Req: TRequest): TResponse;');
    A('var');
    A('  C: TCredential;');
    A('  U: TUser;');
    A('  Asr: TAssertion;');
    A('  V: PJsonValue;');
    A('  CredId: string;');
    A('begin');
    A('  V := Body_(Req);');
    A('  if V = nil then');
    A('    Exit(JsonFeil(' + Q + 'Malformed request.' + Q + ', 400));');
    A('  V := JsonMember(V, ' + Q + 'id' + Q + ');');
    A('  if V = nil then');
    A('    Exit(JsonFeil(' + Q + 'Malformed request.' + Q + ', 400));');
    A('  CredId := JsonAsString(V);');
    A('');
    A('  C := TQuery<TCredential>.New');
    A('    .Where(ColStr(' + Q + 'credentials' + Q + ', ' + Q + 'credential_id' + Q + '), Eq, CredId)');
    A('    .First;');
    A('  { The same answer whether the key does not exist or the signature');
    A('    does not hold. Anything else tells an attacker which keys are');
    A('    registered here. }');
    A('  if C = nil then');
    A('    Exit(JsonFeil(' + Q + 'That passkey did not work.' + Q + ', 401));');
    A('');
    A('  Asr := VerifyAssertion(WaOpts(Req),');
    A('    JsonFelt(Req, ' + Q + 'clientDataJSON' + Q + '),');
    A('    JsonFelt(Req, ' + Q + 'authenticatorData' + Q + '),');
    A('    JsonFelt(Req, ' + Q + 'signature' + Q + '),');
    A('    LagretUtfordring,');
    A('    HexDecode(C.PublicKeyX), HexDecode(C.PublicKeyY),');
    A('    UInt32(C.SignCount));');
    A('  if not Asr.Ok then');
    A('  begin');
    A('    LogInfo(' + Q + 'passkey sign-in refused' + Q + ',');
    A('      [' + Q + 'credential' + Q + ', C.Id, ' + Q + 'reason' + Q + ', Asr.Error]);');
    A('    Exit(JsonFeil(' + Q + 'That passkey did not work.' + Q + ', 401));');
    A('  end;');
    A('');
    A('  if Asr.CloneWarning then');
    A('    { A warning, not a rejection: most platform authenticators do');
    A('      not count at all. See docs/webauthn.md. }');
    A('    LogInfo(' + Q + 'passkey sign counter did not advance' + Q + ',');
    A('      [' + Q + 'credential' + Q + ', C.Id]);');
    A('');
    A('  U := TQuery<TUser>.New.Find(C.UserId);');
    A('  if U = nil then');
    A('    Exit(JsonFeil(' + Q + 'That passkey did not work.' + Q + ', 401));');
    A('');
    A('  C.SignCount := Asr.SignCount;');
    A('  C.Save;');
    A('  Askr.Auth.Login(IntToStr(U.Id));');
    A('  LogInfo(' + Q + 'signed in with a passkey' + Q + ', [' + Q + 'user' + Q + ', U.Id]);');
    A('  Result := JsonSvar(' + Q + '{"ok":true}' + Q + ');');
    A('end;');
    A('');
    A('end.');

    Emit(IncludeTrailingPathDelimiter(Rot) +
      'app/Http/App.Http.AuthController.pas', L.Text);
  finally
    L.Free;
  end;
end;

{ ---------------------------------------------------------- migrasjonene -- }

procedure WriteMigrations(const Rot, Versjon: string);
begin
  Emit(IncludeTrailingPathDelimiter(Rot) +
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
    '    { 255 characters covers the PHC string with room to spare. }' + #10 +
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

  Emit(IncludeTrailingPathDelimiter(Rot) +
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
    '    { The hash of the token, not the token. A leaked table must not' + #10 +
    '      give anybody the ability to reset passwords — the same' + #10 +
    '      reasoning as for the passwords themselves. }' + #10 +
    '    Text(' + Q + 'token_hash' + Q + ', 64).Unique;' + #10 +
    '    { Unix milliseconds. An integer means the same thing whatever' + #10 +
    '      time zone the server thinks it is in. }' + #10 +
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

{ Inserts the uses line and the routes where `askr new` left them.

  If it does not find the markers — because app.lpr has been changed, as it
  is meant to be — it does nothing and says so. Guessing at a place to
  insert code into a file somebody has written themselves is worse than
  asking them to do it. }
function InstallerRuter(const Rot: string): Boolean;
var
  L: TStringList;
  Path_: string;
  I, IdxUses, IdxRuter: Integer;
begin
  Result := False;
  Path_ := IncludeTrailingPathDelimiter(Rot) + 'app.lpr';
  if not FileExists(Path_) then
    Exit;

  L := TStringList.Create;
  try
    L.LoadFromFile(Path_);

    { Already installed? Then there is nothing to do, and it is not an
      error. }
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

    { From the back, so that the first insertion does not move the
      second. }
    { The pages after sign-in. The router sorts on specificity, not order,
      so the placement here only affects how app.lpr reads. }
    L.Insert(IdxRuter + 1, '  R.Post(''/login/passkey'', Auth_.LoginPasskey);');
    L.Insert(IdxRuter + 1, '  R.Get(''/login/passkey/challenge'', Auth_.LoginChallenge);');
    L.Insert(IdxRuter + 1, '  R.Post(''/settings/passkeys/:id/delete'', Auth_.PasskeyDelete);');
    L.Insert(IdxRuter + 1, '  R.Post(''/settings/passkeys'', Auth_.PasskeyRegister);');
    L.Insert(IdxRuter + 1, '  R.Get(''/settings/passkeys/challenge'', Auth_.PasskeyChallenge);');
    L.Insert(IdxRuter + 1, '  R.Post(''/settings/security'', Auth_.ChangePassword);');
    L.Insert(IdxRuter + 1, '  R.Get(''/settings/security'', Auth_.ShowSecurity);');
    L.Insert(IdxRuter + 1, '  R.Post(''/settings/profile'', Auth_.SaveProfile);');
    L.Insert(IdxRuter + 1, '  R.Get(''/settings/profile'', Auth_.ShowProfile);');
    L.Insert(IdxRuter + 1, '  R.Get(''/dashboard'', Auth_.Dashboard);');
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

    { The controller has to be made, the user loader registered, and the
      cache set up for the throttle on sign-in. All three right before the
      routes. }
    for I := 0 to L.Count - 1 do
      if L[I] = '  Home := THomeController.Create;' then
      begin
        L.Insert(I + 1, '  { Askr stores only the user''s id; this gives back the rest. }');
        L.Insert(I + 2, '  SetUserLoader(@LoadUser);');
        L.Insert(I + 3, '  { Used by the throttle on the sign-in form. }');
        L.Insert(I + 4, '  SetCache(TCache.Create);');
        L.Insert(I + 5, '  { Password reset sends email. MAIL_TRANSPORT decides');
        L.Insert(I + 6, '    where it ends up: log writes to a file so the link can');
        L.Insert(I + 7, '    be tried without any server, resend and smtp send for');
        L.Insert(I + 8, '    real. See docs/mail.md. }');
        L.Insert(I + 9, '  SetMail(TMailer.Create(MailFromConfig));');
        L.Insert(I + 10, '  Mail.SetDefaultFrom(Cfg(''mail.from'', ''noreply@localhost''), '''');');
        L.Insert(I + 11, '  Auth_ := TAuthController.Create;');
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
        { Askr.Mail.Resend has to be linked in for MAIL_TRANSPORT=resend to
          exist as a name. It costs no run-time dependency: OpenSSL is not
          loaded until something actually sends. }
        L[I] := '  Askr.Session, Askr.Csrf, Askr.Auth, Askr.Cache,';
        L.Insert(I + 1, '  Askr.Mail, Askr.Mail.Resend,');
        Break;
      end;

    { The controller is freed where the others are. }
    for I := L.Count - 1 downto 0 do
      if L[I] = '    Home.Free;' then
      begin
        L.Insert(I + 1, '    Auth_.Free;');
        Break;
      end;

    L.SaveToFile(Path_);
    WriteLn('  edited app.lpr');
    Result := True;
  finally
    L.Free;
  end;
end;

procedure WriteHelp;
begin
  WriteLn;
  WriteLn('Could not find the markers in app.lpr. Add this yourself:');
  WriteLn;
  WriteLn('  uses  App.Models.User, App.Http.AuthController,');
  WriteLn('        Askr.Cache, Askr.Mail, Askr.Mail.Resend;');
  WriteLn;
  WriteLn('  SetCache(TCache.Create);');
  WriteLn('  SetMail(TMailer.Create(MailFromConfig));');
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
  WriteLn('  R.Get(''/dashboard'', Auth_.Dashboard);');
  WriteLn('  R.Get(''/settings/profile'', Auth_.ShowProfile);');
  WriteLn('  R.Post(''/settings/profile'', Auth_.SaveProfile);');
  WriteLn('  R.Get(''/settings/security'', Auth_.ShowSecurity);');
  WriteLn('  R.Post(''/settings/security'', Auth_.ChangePassword);');
  WriteLn('  R.Get(''/settings/passkeys/challenge'', Auth_.PasskeyChallenge);');
  WriteLn('  R.Post(''/settings/passkeys'', Auth_.PasskeyRegister);');
  WriteLn('  R.Post(''/settings/passkeys/:id/delete'', Auth_.PasskeyDelete);');
  WriteLn('  R.Get(''/login/passkey/challenge'', Auth_.LoginChallenge);');
  WriteLn('  R.Post(''/login/passkey'', Auth_.LoginPasskey);');
end;


{ ------------------------------------------------------------ passkeys -- }

procedure WriteCredential(const Rot: string);
begin
  Emit(IncludeTrailingPathDelimiter(Rot) +
    'app/Models/App.Models.Credential.pas',
    '{ A registered passkey.' + #10 + #10 +
    '  Only the PUBLIC key is here. That is the whole point of passkeys:' + #10 +
    '  a leaked database gives nobody a way in, because what is needed to' + #10 +
    '  sign never leaves the user''s own device. }' + #10 +
    'unit App.Models.Credential;' + #10 + #10 +
    '{$mode Delphi}{$H+}' + #10 + #10 +
    'interface' + #10 + #10 +
    'uses' + #10 +
    '  SysUtils, Askr.Urd.Model, Askr.Urd.Query;' + #10 + #10 +
    'type' + #10 +
    '  TCredential = class(TModel)' + #10 +
    '  private' + #10 +
    '    FId: Int64;' + #10 +
    '    FUserId: Int64;' + #10 +
    '    FCredentialId: string;' + #10 +
    '    FPublicKeyX: string;' + #10 +
    '    FPublicKeyY: string;' + #10 +
    '    FSignCount: Int64;' + #10 +
    '    FNickname: string;' + #10 +
    '    FCreatedAt: TDateTime;' + #10 +
    '    FUpdatedAt: TDateTime;' + #10 +
    '  published' + #10 +
    '    property Id: Int64 read FId write FId;' + #10 +
    '    property UserId: Int64 read FUserId write FUserId;' + #10 +
    '    { base64url, the way the browser reports it. }' + #10 +
    '    property CredentialId: string read FCredentialId write FCredentialId;' + #10 +
    '    { Hex, 64 characters each. }' + #10 +
    '    property PublicKeyX: string read FPublicKeyX write FPublicKeyX;' + #10 +
    '    property PublicKeyY: string read FPublicKeyY write FPublicKeyY;' + #10 +
    '    property SignCount: Int64 read FSignCount write FSignCount;' + #10 +
    '    { Not Label: it is a reserved word in Pascal, and a property' + #10 +
    '      that has to be called Label_ becomes the column label_. Urd' + #10 +
    '      snake_cases the property name, so the name here IS the' + #10 +
    '      column. }' + #10 +
    '    property Nickname: string read FNickname write FNickname;' + #10 +
    '    property CreatedAt: TDateTime read FCreatedAt write FCreatedAt;' + #10 +
    '    property UpdatedAt: TDateTime read FUpdatedAt write FUpdatedAt;' + #10 +
    '  public' + #10 +
    '    class procedure Describe(S: TSchema); override;' + #10 +
    '  end;' + #10 + #10 +
    '  TCredentialList = TModelList<TCredential>;' + #10 + #10 +
    'implementation' + #10 + #10 +
    'class procedure TCredential.Describe(S: TSchema);' + #10 +
    'begin' + #10 +
    '  S.Table(' + Q + 'credentials' + Q + ');' + #10 +
    '  S.Timestamps;' + #10 +
    'end;' + #10 + #10 +
    'end.' + #10);
end;

procedure WritePasskeyMigration(const Rot, Versjon: string);
begin
  Emit(IncludeTrailingPathDelimiter(Rot) +
    'database/App.Migrations.CreateCredentials.pas',
    'unit App.Migrations.CreateCredentials;' + #10 + #10 +
    '{$mode Delphi}{$H+}' + #10 + #10 +
    'interface' + #10 + #10 +
    'uses' + #10 +
    '  Askr.Norn.Schema, Askr.Norn.Migration;' + #10 + #10 +
    'type' + #10 +
    '  TCreateCredentials = class(TMigration)' + #10 +
    '  public' + #10 +
    '    class function Version: string; override;' + #10 +
    '    procedure Up(S: TSchemaBuilder); override;' + #10 +
    '    procedure Down(S: TSchemaBuilder); override;' + #10 +
    '  end;' + #10 + #10 +
    'implementation' + #10 + #10 +
    'class function TCreateCredentials.Version: string;' + #10 +
    'begin' + #10 +
    '  Result := ' + Q + Versjon + Q + ';' + #10 +
    'end;' + #10 + #10 +
    'procedure TCreateCredentials.Up(S: TSchemaBuilder);' + #10 +
    'begin' + #10 +
    '  { Registered passkeys. Public keys only: what is needed to sign' + #10 +
    '    never leaves the user''s own device, and so a leaked database' + #10 +
    '    here gives nobody a way in. }' + #10 +
    '  with S.Create(' + Q + 'credentials' + Q + ') do' + #10 +
    '  begin' + #10 +
    '    Id;' + #10 +
    '    ForeignKey(' + Q + 'user_id' + Q + ', ' + Q + 'users' + Q + ');' + #10 +
    '    { Unique: the same key must not be registrable twice, not even' + #10 +
    '      on two accounts. }' + #10 +
    '    Text(' + Q + 'credential_id' + Q + ', 255).Unique;' + #10 +
    '    Text(' + Q + 'public_key_x' + Q + ', 64);' + #10 +
    '    Text(' + Q + 'public_key_y' + Q + ', 64);' + #10 +
    '    BigInt(' + Q + 'sign_count' + Q + ');' + #10 +
    '    Text(' + Q + 'nickname' + Q + ', 120);' + #10 +
    '    Timestamps;' + #10 +
    '    Index([' + Q + 'user_id' + Q + ']);' + #10 +
    '  end;' + #10 +
    'end;' + #10 + #10 +
    'procedure TCreateCredentials.Down(S: TSchemaBuilder);' + #10 +
    'begin' + #10 +
    '  S.Drop(' + Q + 'credentials' + Q + ');' + #10 +
    'end;' + #10 + #10 +
    'initialization' + #10 +
    '  RegisterMigration(TCreateCredentials);' + #10 + #10 +
    'end.' + #10);
end;

procedure LagAuth(const Rot: string; Force: Boolean);
var
  Path_: string;
begin
  Path_ := IncludeTrailingPathDelimiter(Rot) +
    'app/Http/App.Http.AuthController.pas';
  if FileExists(Path_) and not Force then
  begin
    WriteLn('Auth is already installed. Pass --force to overwrite it.');
    Halt(1);
  end;

  WriteUser(Rot);
  WriteCredential(Rot);
  WriteMigrations(Rot, Tidsstempel);
  { A migration of its own, and TWO timestamps later: credentials points
    at users with a foreign key, so the table has to exist first — and
    WriteMigrations itself uses T and T+1. With +1, credentials got the
    same version as password_resets, and the migrator skipped it as
    already run. The table was then never created, and the security page
    answered 500. }
  WritePasskeyMigration(Rot, IntToStr(StrToInt64(Tidsstempel) + 2));
  WriteControllers(Rot);
  UpdateIndex(Rot, 'database', 'App.Migrations', 'App.Migrations.');

  if not InstallerRuter(Rot) then
    WriteHelp;

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
