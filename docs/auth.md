# Authentication and authorisation

## Scaffolding it

```sh
askr new shop --auth        # or answer the question it asks
askr make auth              # into a project that already exists
askr build && askr migrate
```

That writes a `User` model, two migrations, and an `AuthController` — and
wires it into `app.lpr`. You get eight routes:

| | |
|---|---|
| `/login`, `/register`, `/logout` | Signing in and out |
| `/forgot-password`, `/reset-password/:token` | Resetting a forgotten one |
| `/dashboard` | Where signing in lands you |
| `/settings/profile` | Name and email |
| `/settings/security` | Change password, manage passkeys |
| `/settings/passkeys`, `/login/passkey` | The WebAuthn ceremonies |

`askr new` asks when it is run from a terminal. `--auth` and `--no-auth`
answer for a script; without a terminal and without a flag the answer is no,
because a command that waits for input from a pipe hangs forever.

`askr make auth` refuses to overwrite an existing install without `--force`.
If it cannot find its markers in `app.lpr` — because you have edited it, as
you should be able to — it writes the files and prints the lines to add
yourself. Guessing at where to insert code in a file someone wrote is worse
than asking.

## After signing in

Signing in lands on `/dashboard`, not on `/`. It is a real page with a
sidebar, a profile form and a security page — not a placeholder, and not a
redirect into your app's own routes, because a new project does not have
any yet.

**It is yours to replace.** The point is that `askr new shop --auth`
produces something you can sign into and look around in, rather than a
login form that dumps you on the welcome page. When you build the real
thing in Inertia, point `/dashboard` at your own handler and delete these
three.

`/settings/security` lists your **passkeys**, with a button to add one
and a link to remove each. `/login` gains *Sign in with a passkey*. It
works out of the box on `localhost`; for production, set the RP ID and
origin — see [Passkeys](webauthn.md).

### What you get, and why it looks like that

**The pages are plain HTML, not Inertia.** A new project has Inertia set up
but not installed, and `npm install` is something you do afterwards.
Requiring it before you can sign in would make sign-in useless in exactly
the window where you need it. The pages use system fonts and inline CSS and
need neither npm nor a network, like the welcome page. The generated file
says how to turn them into Inertia pages.

**All of it is yours.** That is the point of a scaffold: you must be able to
change the login page. So the templates generate into your project rather
than living in the framework.

Choices in the generated code that are not arbitrary:

- **One message for "no such account" and "wrong password".** Saying which
  turns the form into a directory of who is registered. The same applies to
  the password-reset form: the answer is identical whether or not the
  address exists.
- **A throttle on the login form**, five attempts per email in fifteen
  minutes, via the cache. Without it the form is a target for guessing at
  scale. The counter is on the email, not the IP: an attacker has many IPs
  and usually one account to get into. If no cache is configured it is
  skipped rather than taking sign-in down.
- **The reset table stores the hash of the token, not the token.** A leaked
  table must not let anyone reset passwords — the same reasoning as for the
  passwords themselves.
- **Reset tokens are single use and expire in an hour**, and *all* tokens
  for the address are deleted on use: if someone asked for two links, the
  other one must not still work.
- **A password reset replaces the session.** If someone else was signed in
  as that user, they should not stay signed in.
- **Rehash on sign-in.** The plaintext is in hand right then, so a hash made
  with weaker parameters is upgraded without asking the user anything.
- **Twelve characters minimum, and no other rule.** Requirements about
  capitals and digits produce weaker passwords in practice, because people
  write `Password1!`.

In development, mail goes through `TLogTransport` and writes to
`storage/mail.log`, so the reset link can actually be followed without an
SMTP server. In production the generated code uses `TSmtpTransport` and
requires `SMTP_HOST`.

## The parts

Two things that get conflated:

- **Authentication** is knowing who someone is. It lives in the session.
- **Authorisation** is deciding whether they may. It lives in gates.

```pascal
uses Askr.Auth;

UseAuth(R);      { after UseSessions }
```

## Askr does not own your user model

The framework stores **one thing** — the user's id, as text — and lets your
app look up the rest through a loader it registers.

That is deliberate. A `TUser` from the framework would force a particular
schema, a particular table and a particular set of columns, and the first
thing any real app does is need one more column.

```pascal
function FindUser(const Id: string): TObject;
begin
  Result := TQuery<TUser>.New.Find(StrToInt64Def(Id, 0));
end;

SetUserLoader(@FindUser);
```

## Logging in

Passwords live in [`Askr.Core.Crypto`](crypto.md). This unit never sees one;
your app verifies and calls `Login` with an id.

```pascal
U := TQuery<TUser>.New.Where(Users.Email, Eq, Email).First;
if (U <> nil) and VerifyPassword(Password, U.PasswordHash) then
  Login(IntToStr(U.Id), Remember)
else
  Exit(BackWithErrors(U.Errors));
```

It sounds like a detour, but it is the one order that cannot go wrong: the
framework cannot know which column the hash is in, and an API that guessed
at that would have to guess at how the user is looked up too.

```pascal
Login(UserId);                 { the session id is replaced — see below }
Login(UserId, True);           { and a "remember me" cookie is set }
Logout;                        { clears the whole session }
```

```pascal
Check;        { is anyone logged in }
Id;           { the id, or '' }
User;         { the object from the loader, or nil — looked up once per request }
```

`Logout` clears the **whole** session, not just the user key. A cart or a
half-finished form belonged to whoever was logged in.

## Session fixation

`Login` replaces the session id. Without that, an attacker who set your
cookie in advance is logged in as you afterwards. It is one line, and there
is a test that fails if it is removed — verified by removing it.

## Remember me

A **signed cookie**, not a token in the database.

```pascal
Login(UserId, True);
```

The value is `<user id>|<expiry>` signed with the [app key](crypto.md). It
is **readable** — the signature proves we made it, it does not hide it. A
user id is not a secret, and the cookie alone grants nothing without a valid
signature.

The expiry is inside the signed payload, not only in the cookie's `Max-Age`.
A client that keeps the cookie longer than we asked must not get in.

> **It cannot be revoked individually.** Doing that requires storing a token
> per user, and the framework cannot know which table it would go in. That
> is a real limitation, stated here rather than discovered.

`UseAuth` restores the login from the cookie when the session is empty, and
gives the restored session a fresh id — it is a login, just without a form.
An already-logged-in session always wins, so an old cookie cannot override a
newer login.

## Gates

```pascal
function CanEdit(const UserId: string; Resource: TObject): Boolean;
begin
  Result := (Resource <> nil) and
            (TPost(Resource).AuthorId = StrToInt64Def(UserId, 0));
end;

DefineGate('edit-post', @CanEdit);
```

```pascal
if Allows('edit-post', Post) then ...
if Denies('edit-post', Post) then Exit(RespondText('Forbidden', 403));
Authorize('edit-post', Post);        { raises EForbidden }
GateExists('edit-post');
```

`Resource` is `nil` for gates that are not about a particular object —
`admin`, `view-dashboard`.

**A gate that does not exist answers no.** A typo in a gate name must close
the door; the opposite looks exactly like everything working.

**Nobody logged in answers no**, for every gate.

Defining the same name twice replaces the earlier one, so an app can
override a gate from a library.

### Gates, not policies

Policy classes are a convention over reflection: names resolved at runtime.
A gate is a function with a name, and the compiler can see it.

## Requiring login

```pascal
RequireAuth(R);                  { redirects to /login }
RequireAuth(R, '/sign-in');
```

Everything registered from there on is behind it.

An ordinary browser request is redirected. **An Inertia or JSON request gets
401**, because a 302 to an HTML page is useless to a client that asked for
JSON — it would follow it and receive the login page as JSON.

## A caller that is not a browser

`Login` writes to a session, and a session is a browser mechanism. A
program presents its credential on the request instead:

```
Authorization: Bearer askr_...
```

`UseTokenAuth` resolves it and signs the request in for that request only,
with no session and no cookie. `Check`, `Id`, `User` and every gate then
answer as they do for a browser, so authorisation is written once. See
[APIs](api.md).

```pascal
procedure LoginForRequest(const UserId: string);
function IsRequestIdentity: Boolean;
```

`LoginForRequest` is the hook underneath it, for plugging in a scheme of
your own. The identity lasts exactly as long as the request: it is
cleared when the arena resets, which is the first thing the next request
on that worker does. It **wins over the session** when both are present —
an `Authorization` header is the caller naming which credential to use.

## Doing it yourself

`Login` needs an ambient session, so it works inside a request handled by a
router with `UseSessions`. If you host requests yourself, set the session
first — see [Sessions](sessions.md).
