# Rate limiting

How often one caller may ask. Off until a number is set, and `askr new`
sets one.

```pascal
RateLimit.PerMinute(600).KeyBy(@TokenRateKey);
UseRateLimit(R);
```

A token bucket, not a fixed window. A window of a minute lets somebody
spend the whole allowance in its last second and the whole of the next in
the first second of the next — twice the limit across two seconds, which
is exactly the burst the limit was for. A bucket refills continuously and
has no seam to sit on.

`PerMinute(600)` is a bucket of 600 refilling at ten a second; `Burst(N)`
sets the two apart when a different shape is wanted. Over the limit is
`429` with `Retry-After`, which is never less than 1 — a `Retry-After` of
0 says "now", and a client that obeys it spins.

Every reply under the limit carries `X-RateLimit-Limit` and
`X-RateLimit-Remaining`, so a client can slow down before it is refused
rather than after.

## What it is keyed on

`TokenRateKey` is the token when the request came in with one, and the
caller's address otherwise — a limit per credential rather than per
office. It is keyed on the token's **id**: the id is a number in a table,
the text is a credential, and a limiter has no business holding the
second in a process-wide table for the life of the process.

It has to be registered after `UseTokenAuth`, or there is no token to see
yet.

Static files that exist short-circuit before the limiter, so a page with
thirty assets does not spend thirty tokens.

## `X-Forwarded-For` is not read

It is a header the client writes. Trusting it without knowing exactly how
many proxies sit in front of you means anybody can put a new value in it
on every request and have an unlimited quota — **a rate limiter you can
opt out of is worse than none, because it is believed.** Behind a proxy,
have the proxy set the address it saw, or key on something the caller
cannot choose, such as a token.

## Memory does not grow with traffic

The table is a fixed number of slots. A new key lands in one of a few
decided by its hash, and when they are all taken one of them is taken
over — the least constrained, since whoever has the most left is least in
need of it.

**Taking a slot over never hands out a fresh allowance.** The new key
inherits whatever was in the bucket. The first version reset it to full,
and that is a way round the whole limiter: the hash is a pure function of
the key, so anybody can work out eight keys that collide with their own,
spend them, and have their own bucket dropped and refilled. Inheriting
instead means the worst a collision can do is limit somebody early, which
is the safe direction.

The counters live in the process. Two Askr processes behind a load
balancer each enforce the limit separately, so the effective limit is the
number times the processes. A shared counter needs somewhere shared to
put it, and that is a different piece with a different failure mode —
what happens to every request when the store is down.

## What is not here

**The counters are not shared between processes.** Two Askr processes
behind a load balancer each enforce the limit separately, so the effective
limit is the number times the processes. A shared counter needs somewhere
shared to put it, and that brings a question this does not have to answer:
what happens to every request when that store is down.

**There is no per-route limit.** One bucket per caller for the whole
router. A route that costs far more than the others wants its own
accounting, and that is a different shape: a cost per operation rather
than a count of requests.

**A 429 is not logged.** It is an ordinary answer to an ordinary request,
and logging every one of them hands whoever is over the limit a way to
fill the disk.
