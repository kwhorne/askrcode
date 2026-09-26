# Plugins

A plugin is a git repository of Pascal source that an app builds with, the
way it builds with the framework: fetched, pinned to a commit, and
compiled into the one binary. Nothing is loaded at run time.

```sh
askr plugin add https://github.com/kwhorne/askr-stripe.git
askr build
```

```toml
# askr.toml, as plugin add writes it
[plugins.stripe]
git = "https://github.com/kwhorne/askr-stripe.git"
version = "^0.1.0"
```

| | |
|---|---|
| `askr plugin add <git url>` | Fetch the newest release, pin it, and wire it into app.lpr |
| `askr plugin update [name]` | Move to the newest release askr.toml allows, after showing its UPGRADE.md |
| `askr plugin remove <name>` | Take it out of askr.toml and askr.lock |
| `askr plugin list` | What this project builds with |
| `askr install` | Fetch the framework and every plugin the lock names |
| `askr outdated` | What is published, for the framework and each plugin |

## Why source, and why git

Pascal compiles into one binary, and a `.ppu` file is bound to one exact
compiler version, so there is nothing a plugin could be but source. It
goes where the framework goes -- `~/.askr/pkg/plugins/<name>@<version>` --
and `askr.lock` records the commit it stands on:

```toml
[plugins.stripe]
git = "https://github.com/kwhorne/askr-stripe.git"
version = "0.1.2"
commit = "9f3c…"
```

There is no registry. The version lives in the tag, the commit in the
lock, and a registry would be a third place that can disagree with both.
A version is a tag like `v0.1.2`, and the range in askr.toml follows
npm's rules, zero major included: `^0.1.0` allows 0.1.x and not 0.2.0.

Working on a plugin, point at the checkout instead, as with `[askr] path`:

```toml
[plugins.stripe]
path = "../askr-stripe"
```

## There is no sandbox

A plugin is compiled into your binary and can do anything your app can:
read its configuration, its database, its keys. **The commit in askr.lock
is the whole of the trust model.** `askr install` refuses a cached copy
that stands on another commit than the lock -- a moved tag, or a touched
cache -- and says how to fetch it again. Read what you add, the way you
would read a dependency that ships as source, because that is what it is.

## What the build checks

Every build resolves the plugins askr.toml names and stops, with the
reason, when:

- a plugin builds against another Askr than this project does;
- two plugins claim the same table, or the same configuration prefix;
- askr.lock disagrees with askr.toml -- another git url, or a pin the
  locked version no longer meets -- until `askr install` or
  `askr plugin update` settles it;
- app.lpr does not start the plugins (below);
- askr.toml says `plugins.stripe = "^0.1.0"`, the form Cargo uses. A plugin
  is a section of its own here, and without this check that line would
  have meant no plugin at all.

It then writes `App.Plugins` into `.build/plugins`: a unit that uses each
plugin's entry unit and every migration it has. A unit nothing refers to
is never linked, and its initialization never runs -- the same reason
`App.Migrations` exists.

## In app.lpr

```pascal
uses
  ...
  Askr.Plugins, App.Plugins,
  App.Migrations, App.Seeders,
  ...

  UseCsrf(R);
  UseAuth(R);
  UsePlugins(R);
```

`askr new` writes both lines. `askr plugin add` adds them to an app.lpr
from before plugins, at the places `askr new` puts them; if the file does
not look that way, it changes nothing and shows the lines to add.

`UsePlugins` comes after the app's middleware, so a plugin's routes have
sessions and sign-in. Each plugin is made there, in the order they
registered: `Configure`, then `Routes`. A plugin that cannot start stops
the app, naming it and why.

## Writing a plugin

A repository with `askr-plugin.toml` at its root:

```toml
name = "stripe"
version = "0.1.0"
askr = "^0.16.0"             # the Askr versions it builds against
entry = "Askr.Plugin.Stripe" # the unit that registers it
units = "src"                # unit directories, relative to the root
migrations = "database"      # optional
docs = "docs"                # optional; the default
config = "stripe"            # its configuration prefix; the name by default
tables = "stripe_customers, stripe_events"
```

The entry unit registers the plugin, and nothing else, in its
initialization:

```pascal
unit Askr.Plugin.Stripe;

interface

uses SysUtils, Askr.Core.Config, Askr.Plugins, Askr.Http.Router;

type
  TStripePlugin = class(TPlugin)
  public
    function Name: string; override;
    procedure Configure; override;
    procedure Routes(R: TRouter); override;
  end;

implementation

function TStripePlugin.Name: string;
begin
  Result := 'stripe';
end;

procedure TStripePlugin.Configure;
begin
  if Cfg('stripe.secret') = '' then
    raise Exception.Create('Set STRIPE_SECRET');
end;

procedure TStripePlugin.Routes(R: TRouter);
begin
  R.Post('/stripe/webhook', Webhooks.Receive);
end;

initialization
  RegisterPlugin(TStripePlugin);

end.
```

**The initialization runs before the app's first line** -- before its
configuration is loaded -- so read nothing there. Commands and
migrations are registered there as the app's are, with `RegisterCommand`
and `RegisterMigration`; they are read when they run.

**A migration's version carries the plugin's name**:
`stripe:20261001120000`. The row in `askr_migrations` then says whose it
is, and it cannot collide with the app's. The migrator orders by the
timestamp, so a plugin's migration takes its place among the app's.

**A route is the app's or one plugin's.** A second route with the same
method and shape -- `/stripe/:id` beside `/stripe/:slug` -- stops the app
where it is added, and names the plugin that has the first. So does a
command registered twice.

**Docs** in the plugin's `docs/` are served to coding agents through
`docs_search` and `docs_read` for the version the project pins, as
`stripe/billing.md` beside the framework's pages.

**UPGRADE.md** at the root is read the way the framework's is: `askr plugin
update` prints the sections between the two versions before it moves the
lock.

Publish a release by pushing a tag, `v0.1.0`, whose `askr-plugin.toml`
says `version = "0.1.0"`. A tag that says it is another version, or
another plugin, is refused.

## What is not here

**A registry.** Git urls only, for now; a catalogue on askrcode.com can
come later as a list of them.

**Plugins that need other plugins.** A plugin depends on Askr and nothing
else. The list is flat.

**Svelte pages in a plugin.** The mechanism leaves room for it, but no
plugin needs it yet: Stripe's checkout and customer portal are Stripe's
own pages.

**A sandbox**, as above. There is no way to give compiled Pascal less than
the process it runs in.
