# API tokens

A session is a browser mechanism: a cookie, a CSRF token beside it, and
something at the other end that stores cookies and follows redirects. A
program has none of that. It gets a bearer token instead.

```
Authorization: Bearer askr_kZ3n9QwR...
```

```pascal
UseSessions(R);
UseTokenAuth(R);   { before UseCsrf — see below }
UseCsrf(R);
UseAuth(R);
```

That is the whole setup. `askr new` writes it. From there `Check`, `Id`,
`User` and every gate answer for a token caller exactly as they do for a
browser, so an application does not write its authorisation twice.

## Minting one

```sh
askr token:issue 7 "ci deploy" --scopes=orders:read,orders:write
askr token:issue 7 "read only" --scopes=orders:read --days=90
askr token:issue 7 "everything" --scopes='*'
```

```
  askr_kZ3n9QwRt7xLm2pVc4hJdF8sYbN1aG6uE0iO3rT5w

This is the only time the token is shown. Only its SHA-256 is
stored, so there is no way to print it again.
```

`--scopes` is required and has no default. The one command that mints a
credential should make you say what it may do; a default of "everything"
would be the wrong answer most of the time and silent every time.

The `api_tokens` table is created by the first `token:issue`, not at
startup — an application has to start whether or not its database is up.

```sh
askr token:list 7
askr token:revoke 4
askr token:revoke --user=7     # everything that user has
```

## From code

```pascal
function IssueToken(Db: TDbConnection; const UserId, Name_: string;
  const Scopes: array of string; ExpiresInSeconds: Int64 = 0): string;
function FindToken(Db: TDbConnection; const Plain: string;
  out T: TApiToken): Boolean;
procedure RevokeToken(Db: TDbConnection; TokenId: Int64);
function RevokeTokensFor(Db: TDbConnection; const UserId: string): Integer;
function TokensFor(Db: TDbConnection; const UserId: string): TApiTokens;
procedure EnsureTokenSchema(Db: TDbConnection);
```

The user id is the application's own, as text — the same one `Login`
takes. The framework does not own your user model and does not own this
either; it stores an id and nothing else about a person.

## Scopes

```pascal
function TokenAllows(const Scope: string): Boolean;
procedure AuthorizeScope(const Scope: string);   { raises EForbidden → 403 }
```

```pascal
function TOrderCtl.Store(Req: TRequest): TResponse;
begin
  AuthorizeScope('orders:write');
  ...
end;
```

Scopes are exact strings. `*` is the only wildcard and means everything.
`orders:*` is deliberately **not** supported: it reads as an obvious
extension and then raises a question with no obvious answer — whether the
star crosses a colon — at the exact moment somebody is deciding what an
admin token may do. A token can list as many exact scopes as it likes,
which is the same reach without the ambiguity.

Three answers, and the middle one is worth reading twice:

| | |
|---|---|
| Nobody signed in | no |
| Signed in by session | **yes** |
| Signed in by token | the token's scopes decide |

A session is not scoped, so asking a browser session about a scope is
asking a question that has no answer. A handler that must also keep
browsers out needs `RequireAuth` or a gate — that is where that decision
belongs.

A token issued with no scopes allows nothing. Somebody will write
`IssueToken(..., [])` meaning "everything"; this is what they get.

## What is stored

The token itself is never stored. The row holds `sha256(token)` as hex,
and the plaintext is returned once and never again.

**The hash is a bare SHA-256, no salt and no key, and that is a
decision.** A salt defends a low-entropy secret against a precomputed
table. This secret is 32 bytes from the system CSPRNG — there is no table
to precompute and no dictionary to try — so a salt would buy nothing and
would cost the thing that matters: the lookup being one indexed equality
rather than a scan. An HMAC under `APP_KEY` was rejected for a different
reason: rotating `APP_KEY` is something operators are told they may do,
and it already signs everyone out. Making it silently kill every API
token as well widens that blast radius.

**There is no stored prefix column, and nothing keeps a fragment of a
live token.** The usual argument for a prefix is matching a token found
in a log or a public repository back to a row — but hashing the string
you found and looking it up does exactly that, with no part of any secret
kept. Telling two tokens apart in a list is what `name` is for.

`askr_` is on the front of every token so a secret scanner has something
to key on, and so a token in a paste is recognisable for what it is. It
is fixed framework-wide: a per-application prefix would mean no scanner
rule could cover Askr at all.

## Never from the query string

There is no code that reads a token from a URL, and there is a test that
says so. A query string goes into access logs, into `Referer` on every
outbound link, into browser history, and into whatever somebody pastes
into a chat. Each of those is a place a credential is then kept by
somebody who never agreed to keep it.

There is also one header, not several. No `X-Api-Key`, no `?api_key=`.

## Why it comes before UseCsrf

A request that authenticated with a credential it carried itself is not
what CSRF defends against. The whole attack is a browser being made to
send a request it did not mean to, with the cookie it carries everywhere;
an `Authorization` header is not carried everywhere, and no other site can
set one on a request to your server. Requiring a CSRF token as well would
ask an API client for something it has no way to obtain, and every POST
with a valid token would be a 419.

`UseCsrf` exempts a request whose identity came from a header. That is
only visible once the token has been read, which is why `UseTokenAuth`
has to be registered first.

## What a refused token gets

| | |
|---|---|
| No token at all | the request continues as anonymous |
| A token that is unknown, revoked or expired | `401`, and the request stops |

A credential that is offered and does not work is an error in itself.
Treating it as an anonymous request would surface the failure later,
somewhere else, as a 403 or a 404.

The 401 carries `WWW-Authenticate: Bearer error="invalid_token"`, as
RFC 6750 says a bearer scheme should. **The body never says which of the
three it was** — that a token is *revoked* rather than unknown tells the
caller it was real. The server logs the reason, and only for a token that
is actually in the table: a token that is not tells nobody anything, and
logging it would let anyone fill the log by sending words.

## Expiry and last use

`--days=N` sets an expiry; without one a token does not expire.
`last_used_at` is written at most once a minute per token, by one
conditional `UPDATE`, so an authenticated request is not also a write.
Times are unix milliseconds, not `TIMESTAMP`, for the same reason the
durable queue uses them: several processes share the table and an integer
means the same thing whatever time zone each server believes it is in.

Revoking marks the row rather than deleting it. "This token was revoked
on Tuesday" and "this token never existed" are different answers to the
only question anybody asks afterwards, and a deleted row can give only
the second.

## What is not here

**There is no refresh token and no OAuth.** A token is issued by somebody
who is already trusted — at a console, or by a handler you wrote — and
lives until it expires or is revoked. Three-legged OAuth is a product,
not a feature, and half of one is worse than none.

**A token belongs to a user id, not to an application.** There is no
notion of a machine account with no person behind it. Use whatever id
your own user table gives you; the framework stores it as text and does
not look at it.

**Scopes are flat.** `orders:read` and `orders:write` are two strings
with a colon in them, not a hierarchy. `*` is the only wildcard — see
above for why `orders:*` is deliberately absent.
