# Upgrading Askr

`askr update` prints the sections between the version you are on and the
one you are moving to, **before** it changes anything in your project.
That is the point of this file: an upgrade you have not read is an
upgrade you debug afterwards.

One heading per release, newest first. Only things that can break your
code belong here — everything else is in the commit log.

## 0.6.0

First release with a version number, so there is nothing to upgrade
*from* yet. What changed is how a project says which framework it wants.

**`askr.toml` gained an `[askr]` section.**

```toml
[askr]
version = "0.6.0"
# path = "/path/to/askrcode"
```

`version` pins a release, which `askr install` fetches into
`~/.askr/pkg`. `path` overrides it with a local checkout, which is what
you want when you are working on the framework itself.

The old top-level form still works:

```toml
askr = "/path/to/askrcode"
```

It is read exactly as `[askr] path` would be, so **projects created
before versioning existed keep building with no changes**. There is no
deprecation warning and no removal date; when the two forms disagree,
`[askr] path` wins.

**`askr.lock` is new, and belongs in git.**

It records the exact commit behind the version, and the
`@askrcode/lauf` version that goes with it. A release spans two
ecosystems — the Pascal source and the npm package — and they are not
allowed to drift apart. `askr install` writes the matching Lauf version
into `frontend/package.json` for you.

If `askr install` refuses because the lock and the cache disagree, the
tag has been moved under you. Delete the cached copy and let it refetch;
the message tells you the path.

**The tool may rebuild itself once.**

`askr` is built *from* the framework, so the list of unit directories is
compiled into it. When your project pins a version that is not the tool
you invoked, `askr` builds that version's tool once into the cache and
re-runs your command with it — the same idea as `bundle exec`. You see
one line about it, and only the first time.

A local `path` is exempt: if you are working on the framework, you are
meant to run the tool you just built.
