# Versions

A project says which Askr release it builds against, and `askr` fetches
it. The pin lives in `askr.toml`; the exact commit lives in `askr.lock`,
which belongs in git.

```toml
[askr]
version = "0.6.0"
```

```sh
askr install     # fetch the pinned release
askr outdated    # what is published, and what you have
askr update      # move, after showing you what changes
askr version     # what this project is actually building against
```

## Where the source goes

`~/.askr/pkg/askrcode@0.6.0`, shared by every project on the machine.
Set `ASKR_HOME` to move it — CI usually wants it somewhere cacheable.

Nothing is distributed as a binary. A release is 2.2 MB of source that
compiles in about a second and a half, and `.ppu` files are tied to an
exact FPC version anyway, so sharing them between projects would be a
trap rather than an optimisation.

## One release, two ecosystems

This is the part that has no equivalent in Composer or Bundler.

An Askr release is the Pascal source **and** `@askrcode/lauf` on npm.
If those drift apart you get a `DataGrid.svelte` whose server half is a
different version of `Askr.Urd.Grid`, and nothing says so until a column
stops sorting.

So `askr.lock` pins both, and `askr install` writes the matching Lauf
version into `frontend/package.json`:

```toml
version = "0.6.0"
commit = "15eb4db6e8e4235f229b79d54101c41619934cca"
lauf = "0.6.0"
```

`askr version` warns if a checkout's two halves disagree. That check
exists because they *had* already drifted — the tool said 0.6.0 while
the npm package said 0.1.0 — and nothing had noticed.

## Working on the framework itself

```toml
[askr]
version = "0.6.0"
path = "/Users/you/code/askrcode"
```

`path` wins over `version`, the same way `replace` wins in a `go.mod`.
`askr install` and `askr update` both refuse to do anything while it is
set, and say so rather than quietly working on the cache instead.

The top-level `askr = "/path"` from before versioning is read as
`[askr] path`, so older projects keep building untouched.

## The tool rebuilds itself when it has to

`askr` is compiled *from* the framework, so the list of unit directories
is baked into it. A 0.6.0 tool building a project pinned to 0.7.0 would
not put a newly added directory on the search path, and the error would
be `unit not found` — pointing nowhere near the cause.

So when the pinned version is not the tool you invoked, `askr` builds
that version's tool once into the cache and re-runs your command with
it. One line of output, the first time only. `bundle exec`, essentially.

`install`, `update`, `outdated` and `new` never delegate: they are the
commands that manage the pin, so they have to run as the tool you
started.

## Upgrading

`askr update` prints the relevant sections of the framework's
[`UPGRADE.md`](../UPGRADE.md) **before** touching your project, then
fetches, rewrites the lock, repoints Lauf, and reminds you that a
release can add columns to the tables Askr owns:

```sh
askr migrate
```

An exact pin means `askr update` will not move on its own — which is
correct, and confusing on its own, so it says what it found and what to
type:

```
Already on Askr 0.6.0.

Askr 0.7.0 is published, but askr.toml pins 0.6.0,
which only allows 0.6.0. To move:

  askr update 0.7.0        take that release, and update the pin
  askr update ^0.6.0       or widen the pin in askr.toml by hand
```

Ranges are written the way `package.json` writes them — `^0.6.0`,
`~0.6.0`, `*` — deliberately, so there is not a second version language
to learn for the Pascal half. `^` follows the npm rule for zero-major
projects: `^0.6.0` allows `0.6.3` but not `0.7.0`.

## What is not here

**No registry, and no dependency graph.** `askr` resolves exactly one
thing — the framework — from git tags. There is no place to publish a
third-party Askr package, and nothing resolves transitive dependencies,
because nothing has any. If that changes, this is where it changes.

**No checksums beyond the commit.** The lock records the commit a tag
pointed at, and `install` refuses when the cache disagrees with it. That
catches a moved tag and a edited cache. It is not a supply-chain
guarantee: it does not verify signatures, and a compromised repository
would serve a commit that matches itself perfectly.

**No offline install.** A version you have never fetched needs the
network. Once it is in `~/.askr/pkg` it never needs it again, and
`ASKR_HOME` is how CI keeps it between runs.

**No rollback of your own code.** `askr update 0.6.0` moves the
framework back. It does nothing about migrations you have already run,
or code you wrote against the newer API.
