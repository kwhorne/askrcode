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
