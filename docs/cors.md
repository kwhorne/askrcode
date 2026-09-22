# CORS

CORS is not a lock. It is a browser telling a page on one origin what it
may do with a reply from another, and nothing else honours it — curl
ignores it, so does a server, so does anything that is not a browser. A
route that must not be reached by some callers needs a guard, not a
header.

```pascal
Cors.AllowOrigin('https://app.example')
    .AllowMethods(['GET', 'POST', 'PATCH', 'DELETE'])
    .AllowHeaders(['Content-Type', 'Authorization'])
    .AllowCredentials;
UseCors(R);
```

`askr new` writes `UseCors(R)` and nothing else, so a new project allows
nothing until somebody names an origin. That is the same rule as
[robots.txt](routing.md#robotstxt) and as a gate that does not exist: the
state you land in without deciding anything has to be the narrow one,
because the dangerous configuration is the one nobody thought about.

## Origins match exactly

`https://app.example.evil.example` starts with `https://app.example`, so
a prefix test lets it in. `Askr.WebAuthn` was caught by a mutation test on
exactly this shape — every wrong origin in its fixtures started with
something else, so nothing measured the rule. There is no pattern
matching and no wildcard subdomain here: an origin is a string, and it is
either on the list or it is not.

A trailing slash is refused rather than quietly kept, because a browser
never sends one and an origin written that way would never match
anything.

## `*` and credentials cannot both be asked for

A browser refuses `Access-Control-Allow-Origin: *` together with
`Access-Control-Allow-Credentials: true`. A server that sends both has a
configuration that reads as "anyone, with cookies" and behaves as
"nobody" — the worst kind of wrong, because it looks generous and fails.
`AllowCredentials` after `AllowAnyOrigin` raises, and so does the other
order.

With credentials the allowed origin is echoed back rather than `*`, since
that is the only form a browser will take alongside them.

## Vary: Origin, on everything

The same URL answers differently depending on who asked, so every reply
says so — including the ones from an origin that was not allowed and
carry no CORS header at all. Without it a cache in front of the server
hands a page from one origin the headers meant for another, or hands a
browser a reply with no CORS headers and the page silently cannot read
it. The same mistake as `Vary: X-Inertia`, and it shows up the same way:
only behind a cache, and only sometimes.

The headers go on error replies too. A page that cannot read the 401 is a
page whose developer has no idea what went wrong.

## The preflight

`OPTIONS` carrying `Access-Control-Request-Method` is answered with 204
before routing. An `OPTIONS` without that header is an ordinary request
and belongs to the application.

A preflight from an origin that is not allowed is still a 204, with no
CORS headers — the browser stops there, which is the answer. Refusing
with a 403 would say the same thing less clearly and would tell a script
which origins are on the list.

It is registered **first**, before the static files and before anything
that authenticates: a preflight carries no credentials by design, so
anything refusing a request without one would refuse every preflight and
the real request would never be sent. It also does not spend anybody's
rate limit, because it is the browser's request and not the caller's.

## What is not here

**There are no wildcard subdomains.** `https://*.example.com` is not a
thing you can write. An origin is a string on a list, and every pattern
language invented for this has had a bypass in it. List the origins.

**There is no per-route policy.** One policy for the whole router. A route
that should be readable by one origin and not another is an authorisation
question, and CORS is not an authorisation mechanism — it is a browser
convention, and curl ignores it.

**Nothing here is enforcement.** A page on another origin is stopped by
the browser, not by Askr. A route that must not be reached needs a guard.
