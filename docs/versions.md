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

Plugins are pinned the same way, each under `[plugins.<name>]` in both
files — see [Plugins](plugins.md).

## Where the source goes

`~/.askr/pkg/askrcode@0.6.0`, shared by every project on the machine.
Set `ASKR_CACHE` to move it — CI usually wants it somewhere cacheable.

Not `ASKR_HOME`: that one means *the framework checkout*, and the build
script tells you to point it at yours. If the cache read the same
variable, following that instruction would write packages into your own
checkout.

Nothing is distributed as a binary. A release is 2.2 MB of source that
compiles in about a second and a half, and `.ppu` files are tied to an
exact FPC version anyway, so sharing them between projects would be a
trap rather than an optimisation.

## One release, two ecosystems

This is the part that has no equivalent in Composer or Bundler.

An Askr release is the Pascal source **and** `@askrcode/lauf`. If those
drift apart you get a `DataGrid.svelte` whose server half is a different
version of `Askr.Urd.Grid`, and nothing says so until a column stops
sorting.

Lauf therefore ships **inside the release**, not on npm. `askr install`
points `frontend/package.json` at it through a gitignored symlink:

```json
"@askrcode/lauf": "file:./.askr/lauf"
```

That path is the same on every machine; the symlink under
`frontend/.askr/` is what differs, and it is not in git. Publishing to
npm would add a second place the version lives, which can lag behind the
tag or be built from the wrong commit — the exact failure this design
removes.

`askr.lock` records both halves anyway, so you can see what you have:

```toml
version = "0.6.0"
commit = "15eb4db6e8e4235f229b79d54101c41619934cca"
lauf = "0.6.0"
```

`askr version` warns if a checkout's two halves disagree. That check
exists because they *had* already drifted — the tool said 0.6.0 while
`frontend/lauf/package.json` said 0.1.0 — and nothing had noticed.

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

## Upgrading, step by step

**1. See what is published.**

```sh
askr outdated
```

```
installed   0.6.0
latest      0.7.0

published releases:
  0.7.0
  0.6.0   <- this project
```

**2. Read what changes before you take it.**

```sh
askr update
```

`askr update` prints the relevant sections of the framework's
[`UPGRADE.md`](../UPGRADE.md) **before** it touches anything in your
project, and stops there if you interrupt it. Only breaking changes are
listed — everything else is in the commit log.

If `askr.toml` pins an exact version, `askr update` will not move on its
own. That is correct, and on its own it contradicts what `askr outdated`
just told you, so it says what it found and what to type:

```
Already on Askr 0.6.0.

Askr 0.7.0 is published, but askr.toml pins 0.6.0,
which only allows 0.6.0. To move:

  askr update 0.7.0        take that release, and update the pin
  askr update ^0.6.0       or widen the pin in askr.toml by hand
```

`askr update 0.7.0` moves `askr.lock` **and** the pin in `askr.toml`, so
the two cannot disagree and drag you back on the next `askr install`.

**3. Pick up the frontend half.**

A release is one number across the Pascal source and `@askrcode/lauf`.
`askr update` rewrites the dependency in `frontend/package.json`; npm
still has to act on it:

```sh
(cd frontend && npm install)
```

`askr update` prints this line with your actual frontend path when the
file changed.

**4. Rebuild.**

```sh
askr build
```

The first build after an upgrade may print one extra line about building
the tool for the new version — see *The tool rebuilds itself* above.
That happens once per version.

**5. Migrate.**

```sh
askr migrate
```

A framework release can add columns to the tables Askr owns — the job
and failure tables, for instance. `askr update` reminds you; it does not
run it for you, because a migration against production is your decision
and not a side effect of an upgrade.

**6. Run your tests.**

```sh
askr test
```

This is the step that finds what `UPGRADE.md` warned you about. The
notes tell you the shape of what can break; your suite tells you whether
your code is that shape.

## Going back

```sh
askr update 0.6.0
```

The framework moves back, the lock and the pin follow, and Lauf goes
with it. Two things do **not** move: migrations you have already run,
and code you wrote against the newer API. Roll those back yourself.

## When it refuses

**`askr.lock pins commit … but the copy in the cache is …`**

A tag was moved after you locked it, or the cached copy was edited. The
message prints the path; delete it and run `askr install` again to
refetch.

**`Askr 0.7.0 is not installed`**

The lock names a version that is not in `~/.askr/pkg`. That is what a
fresh clone looks like:

```sh
askr install
```

**`could not fetch v0.7.0`**

The tag does not exist at the source, or there is no network. `askr
outdated` lists what is actually published.

**`the tag v0.7.0 contains Askr 0.6.1`**

The tag and the version constant inside it disagree, so the download is
thrown away rather than installed under the wrong name. That is a
problem at the source, not in your project.

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
`ASKR_CACHE` is how CI keeps it between runs.

**No rollback of your own code.** `askr update 0.6.0` moves the
framework back. It does nothing about migrations you have already run,
or code you wrote against the newer API.
