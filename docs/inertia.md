# Inertia and Svelte

Inertia lets you build server-driven pages with a component frontend and no
API in between. The server returns props; the client renders the component.

**Askr targets Inertia 3.**

```pascal
uses Askr.Inertia;

function TCustomers.Index(Req: TRequest): TResponse;
begin
  Result := Inertia('Customers/Index',
    ['customers', TQuery<TCustomer>.New.Get,
     'page', Req.Page]);
end;
```

```svelte
<script>
  let { customers, page } = $props()
</script>
```

## Props

```pascal
Inertia(Component);
Inertia(Component, ['key', Value, 'key', Value]);
```

Values may be strings, numbers, booleans, models and model lists. Models
serialise through RTTI, the same way `Askr.Urd.Json` does.

**A relation that was not loaded is omitted, not set to null.** The frontend
must be able to tell "no orders" from "did not ask".

## Redirects

```pascal
Result := InertiaRedirect('/customers');
Result := Back;                          { to the referrer, or a fallback }
Result := BackWithErrors(C.Errors);
Result := InertiaLocation('https://elsewhere.example.com');
```

> **A redirect after PUT, PATCH or DELETE must be 303.** With 302 the
> browser repeats the method against the new address. `InertiaRedirect`
> picks the right one.

`InertiaLocation` is for leaving the Inertia app entirely — it produces a
409 with `X-Inertia-Location`, which is how the protocol says "do a real
browser navigation".

## Flash

```pascal
InertiaFlash('notice', 'Saved.');
```

> Inertia's flash is **thread-local and applies to the response being built
> now**. It does **not** survive a redirect: the two requests can land on
> different workers, and without sessions there is no shared storage.
> **Render the page directly instead of redirecting to it** — or use
> [session flash](sessions.md), which is what `BackWithErrors` does.

Both sources end up in the same `flash` prop, and **any key you set is
carried**, not a fixed list of them:

```pascal
Session.Flash('error', 'That link is no longer valid.');
```

```js
$page.props.flash.error
```

Validation errors are the one exception. They are stored as session flash
internally, but they arrive as their own `errors` prop rather than inside
`flash` — see [Validation](validation.md).

## Shared props

```pascal
TInertia.SetShare(@ShareAuth);
```

```pascal
procedure ShareAuth(var W: TJsonWriter);
begin
  W.Key('auth');
  W.BeginObject;
  W.Field('id', Askr.Auth.Id);
  W.EndObject;
end;
```

Written into every response's props.

## The head of this page

```pascal
TInertia.PageTitle('Queries');
TInertia.PageDescription('The typed query builder, eager loading, paging');
TInertia.PageCanonical('/docs/queries');
TInertia.PageOg('title', 'Queries');
TInertia.PageJsonLd(LdJson);
Result := Inertia('Docs/Show', ['page', P]);
```

`TInertia.SetTitle` is the **site's** default, set once at startup — a
plain global, which is right for a value that never changes. The `Page*`
calls are **this page's**, and they are per thread for the same reason the
flash is: a global would let one worker put its description on another's
page.

They apply to the response being built now and are cleared when it is
built. A handler that sets them and then returns something other than an
Inertia response leaves them for the next Inertia render on that worker,
so set them next to the render rather than far from it.

`PageCanonical` takes a path and makes it absolute against `app.url`;
something already absolute is used as it is. It is never built from the
request — see [`app.url`](configuration.md#appurl-and-why-it-is-not-the-request).
Without `app.url` the link is left out rather than guessed: a canonical
pointing at the wrong place is worse than none.

### What a reader without JavaScript gets

```pascal
TInertia.PageFallback('<h1>Queries</h1><p>The typed query builder.</p>');
Result := Inertia('Docs/Show', ['page', P]);
```

**This answers a measured problem.** An Inertia page without a fallback
sends a crawler a payload in a script element and an empty div — strip the
scripts and there are **zero characters** of text in the body. Googlebot
runs scripts and copes; the fetchers behind most language models do not.

The markup goes inside the mount element, and the client empties that
element before it mounts — Svelte 5 mounts by *appending*, so without that
line the reader would see the page twice. That is one line in the
generated `main.js`:

```js
setup({ el, App, props }) {
  el.innerHTML = ''
  mount(App, { target: el, props })
}
```

**An application from before this needs that line added.** `askr new`
writes it, and a custom root template needs `{{fallback}}` inside the mount
element:

```html
<div id="{{root}}">{{fallback}}</div>
```

A page that sets a fallback against a template with nowhere to put it
raises rather than dropping it — quietly losing it would leave the page
empty for exactly the readers it was written for.

**It is markup, and it is not escaped.** Everything in it is yours to get
right, as with `SetHead`. Interpolating anything a user wrote without
escaping it first is stored XSS, served to every crawler as well.

### This is not server-side rendering

Askr does not run your components on the server. Inertia's SSR needs a Node
process beside the binary, and one binary with no sidecars is the point of
the thing. What goes in a fallback is whatever the page *is* without its
interactivity — for a document, the document.

`./askr seo:check` measures both halves: the characters in the body
without JavaScript, and, in a real Chrome, that the app replaces the
fallback rather than standing beside it. The second cannot be read off the
source and jsdom cannot answer it either.

### Two escapings, and where each applies

An attribute value takes HTML escaping. A `"` in a description that is not
escaped ends the attribute, and the rest of it becomes markup.

The JSON-LD lands **inside a script element**, where HTML escaping is the
wrong tool entirely: the browser decodes no entities there, so `&quot;`
would arrive as six characters inside the JSON and break it — while an
unescaped `</script>` would close the element and hand the rest of the
page to whoever wrote the description. Askr applies JSON escaping there,
the same distinction that made `/` in the Inertia payload a bug once.

## The root template

```pascal
TInertia.SetHead(
  '<script type="module" src="http://localhost:5173/build/@vite/client"></script>' +
  '<script type="module" src="http://localhost:5173/build/src/main.js"></script>');

TInertia.SetRootTemplate(Html);    { the full shell, if you want your own }
TInertia.SetRootId('app');
TInertia.SetVersion(AssetHash);    { asset versioning }
```

In development Vite serves the modules itself. For a production build, read
`public/build/.vite/manifest.json` and set the tags from there — see
`examples/inertia` in the framework.

## Protocol details that matter

**The payload lives in a `<script>` element, not a `data-page` attribute.**
The Inertia 3 client only looks for the script element.

**Inside that element, JSON escaping applies**: `<` becomes `<` and `/`
becomes `\/`. `HtmlAttrEscape` is the wrong tool there and would let a
`</script>` inside a prop value through.

**`Vary: X-Inertia` is set on both HTML and JSON responses**, or
intermediaries cache the wrong response for the wrong client.

## Detecting an Inertia request

```pascal
if IsInertiaRequest(Req) then ...
```

Also what `RequireAuth` uses to answer 401 instead of redirecting — a 302 to
an HTML page is useless to a client expecting JSON.

## The frontend

`askr new` sets up Vite, Svelte 5 and `@inertiajs/svelte`, but does not
install them:

```sh
cd frontend && npm install
```

`askr serve` runs Vite alongside the app and proxies to it. The generated
`vite.config.js` builds into `public/build` with a manifest.

You can ignore all of it. Askr serves HTML, JSON and static files without a
frontend build step, and the welcome page in a new project deliberately
needs neither npm nor a network.
