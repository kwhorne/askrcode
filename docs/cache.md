# Cache

A sharded LRU in the process. No Redis, no Memcached.

```pascal
uses Askr.Cache;

SetCache(TCache.Create(8192, 16));      { max entries, shards }
```

```pascal
Cache.Put('customer:7', Json, 300);     { seconds }
if Cache.Get(Arena, 'customer:7', V) then
  ...
Cache.Has('customer:7');
Cache.Forget('customer:7');
Cache.Flush;
```

```sh
askr cache:clear
```

## The arena boundary

**`Cache.Put` copies out of the caller's arena.** The value must outlive the
request that stored it.

**`Cache.Get` copies out into the caller's arena.** Do not "optimise" that
into returning a pointer into the cache: an eviction could then leave a
dangling pointer, and the value would outlive the request.

Neither copy can be skipped. If you touch that code, run the arena tests —
they zero the arena and fill it with garbage before reading back.

There is a `string` overload for code outside a request, where there is no
ambient arena.

## Sharding

The cache is sharded to keep lock contention down across workers.

> **High hash bits choose the shard, low bits choose the bucket.** The other
> way round and everything lands in the same bucket within a shard.

## Eviction

Least-recently-used, per shard, when `MaxEntries` is reached. Expiry is
checked on read.

## The FNV hash

> The FNV-1a hashes in `Askr.Cache`, `Askr.Norn.Codegen` and
> `Askr.Cli.Watch` are marked `{$push}{$R-}{$Q-}`. FNV-1a depends on the
> multiplication overflowing — that is the algorithm, not an accident.
> Without the marking the cache dies with `ERangeError` in any build with
> overflow checking, and in an ordinary build it just keeps computing
> without saying anything. If you write a new hash, mark it the same way.

## What is not here

**A shared cache across processes.** One process means one cache. Several
app processes behind a load balancer each have their own — which is fine for
derived data and wrong for anything that must be consistent. That is a real
limit, stated rather than discovered.
