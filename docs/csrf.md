# CSRF

On by default in a project from `askr new`. A POST without a valid token
answers **419** before it reaches your handler.

```pascal
uses Askr.Csrf;

UseCsrf(R);      { after UseSessions — the token lives in the session }
```

## The attack

A page on another domain makes your browser send a POST to this app. The
browser attaches the session cookie all by itself, because that is what
cookies do, and the server sees a perfectly legitimate request from a
logged-in user. Without a countermeasure, every form in the app is an
endpoint anyone can call on the user's behalf.

The countermeasure is a secret that lives in the **session** and must be
sent with the **request**. Another domain can make the browser send the
cookie, but it cannot read your session, so it cannot guess the token.

## Sending the token

Three places are accepted, in this order:

1. The form field **`_token`** — ordinary HTML forms
2. The header **`X-CSRF-Token`** — fetch and XHR that attach it themselves
3. The header **`X-XSRF-Token`** — axios and Inertia, which read the
   `XSRF-TOKEN` cookie and mirror it here

```html
<form method="post">
  <%= CsrfField %>
  ...
</form>
```

```pascal
CsrfToken;      { the raw token for this session }
CsrfField;      { <input type="hidden" name="_token" value="..."> }
```

The token is created the first time something asks for it and stays in the
session. It is 32 bytes from the kernel's CSPRNG, base64url.

`UseCsrf` also sets an `XSRF-TOKEN` cookie that JavaScript may read. That is
safe: it is not what authenticates anyone — the session cookie is still
`HttpOnly` — and its value is compared against the session, which another
domain cannot reach.

The cookie is only set when the token already exists. Creating one there
would give every request, including static files and health checks, a write
to the session, and therefore a session per anonymous visitor.

## What is checked

`POST`, `PUT`, `PATCH` and `DELETE`. `GET`, `HEAD` and `OPTIONS` are not —
they should by definition change nothing, and an app that changes state in a
GET has a bigger problem than CSRF.

Comparison is **constant time**. A plain `=` stops at the first differing
character, and how long it took tells an attacker how far a guess got.

## Why 419

`419 Page Expired` is not in any RFC — it is Laravel's, and the Inertia
client recognises it and reloads the page instead of showing an error. That
is the right behaviour: an expired token usually means the user left a tab
open, not that someone is attacking them. A plain 403 would be a dead end.

The message says what is wrong without revealing what was expected.
"Token mismatch" with the correct token in the text has been a real
vulnerability in other frameworks.

## Exemptions

```pascal
CsrfExempt('/webhooks/*');
```

For webhooks, which come from a third party that cannot possibly have the
token and must be authenticated some other way — a signature in a header.

The pattern matches exactly, or with a trailing `*`. **This is a hole you
make on purpose, which is why it has to be written down.**

## Checking it yourself

```pascal
if not CsrfValid(Req) then
  ...
CsrfMethodNeedsCheck(Req.Method);
CsrfIsExempt(Req.Path);
```
