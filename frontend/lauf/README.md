# Lauf

UI components for [Askr](../../README.md) apps, built on Svelte 5.

**Blocks 0 and 1 of the plan in [`LAUF.md`](../../LAUF.md) are done:** the
infrastructure, and the sixteen components a CRUD app needs. Blocks 2 and 3
— modal, dropdown, toast, tabs, and the expensive ones — do not exist yet.

Lauf is not part of the Askr binary and never will be. The server's promise
is one binary with no sidecar; that promise is about the server. Nothing in
`src/` depends on this package, and the welcome page and the auth scaffold
keep working with no npm, no network and no files beside the binary.

## Install

```sh
npm install @askrcode/lauf
```

Not published yet — the npm scope is unclaimed. For now it is used from the
repository.

## Theme

```css
/* your app.css */
@import 'tailwindcss';
@import '@askrcode/lauf/theme.css';

/* Tailwind v4 only generates utilities for classes it can see, and it does
   not look inside node_modules by default. Without this, every class Lauf
   uses is missing from your stylesheet and the components render unstyled. */
@source '../node_modules/@askrcode/lauf/src';
```

The theme is a set of **semantic** tokens — `--color-surface`, not
`--color-zinc-800` — so the role is what stays stable and the value is what
you change. Override any of them after the import.

Dark mode lives in exactly one place: `theme.css`. Components never write
`dark:` classes. If each component carried `bg-white dark:bg-zinc-900`, the
theme would be spread across every file in the library and an app with its
own palette would have to edit all of them.

It handles three states, not two. An explicit choice stamps
`data-theme="dark"` or `data-theme="light"` on the root element; the default
"follow the system" setting stamps nothing, and then only
`prefers-color-scheme` separates the two. The media query is guarded with
`:root:not([data-theme="light"])` so an explicit light choice beats a dark
OS, and `[data-theme="dark"]` is repeated after it so the toggle wins in both
directions.

## `cn`

```js
import { cn } from '@askrcode/lauf'

cn('w-auto', 'w-full') // → 'w-full'
```

Every component runs its classes through this, with the caller's `class`
last. Tailwind classes all have the same specificity, so when two of them
control the same property it is the order in the **stylesheet** that decides,
not the order in the attribute. Without `cn`, an app cannot override anything
a component sets, and it looks like `class` is being ignored.

It costs about 28 kB in your bundle, almost all of it `tailwind-merge`. That
is the price of `class` working the way you expect.

## `Icon`

```svelte
<script>
  import { Icon } from '@askrcode/lauf'
  import { ArrowDownTray } from '@askrcode/lauf/icons/micro'
</script>

<Icon icon={ArrowDownTray} />                      <!-- next to text -->
<Icon icon={ArrowDownTray} label="Download" />     <!-- on its own -->
```

The icon is passed as a **component, not a name**. A name has to be looked up
in a map, and a map keeps all 1288 icons in your bundle however few you use.
An import is the only form a bundler can follow. The whole icon set is 226 kB;
one icon is about 30 kB, and most of that is the Svelte runtime.

Four variants, matching Heroicons: `outline` (24px), `solid` (24px), `mini`
(20px), `micro` (16px). Sizes are `sm`, `base` (default) and `lg`.

**`label` is not optional when the icon stands alone.** Without it the icon
is `aria-hidden`, which is correct beside a text label and wrong when the
icon *is* the label — a close button, a sort arrow. With it, the icon gets
`role="img"` and a name.

Icons are generated from [Heroicons](https://heroicons.com) (MIT) by
`npm run icons`, which `prepare` runs for you. They are not checked into git:
1288 generated files would make every diff unreadable, and they are a
mechanical copy of a dependency that is already in `node_modules`.

## Components

`Button` (`.Group`), `Input`, `Textarea`, `Select`, `Checkbox`, `Radio`,
`Switch`, `Field`, `Heading`, `Text`, `Icon`, `Badge`, `Card`, `Separator`,
`Table` (`.Head`, `.Body`, `.Row`, `.Header`, `.Cell`), `Pagination` — and
`Form` from `@askrcode/lauf/inertia`.

### Forms

```svelte
<script>
  import { Field, Input, Button } from '@askrcode/lauf'
  import { Form } from '@askrcode/lauf/inertia'
  let { errors = {}, sendt = null } = $props()
</script>

<Form action="/customers" data={sendt ?? {}} {errors}>
  <Field name="name" label="Name"><Input /></Field>
  <Field name="email" label="Email"><Input type="email" /></Field>
  <Button type="submit" variant="primary">Create</Button>
</Form>
```

Three things happen without being wired up: `Field` finds its own error
message by name, the control gets a matching `id`, `aria-describedby` and
`aria-invalid`, and the submit button shows a spinner while the request is
out. That is the coupling Flux gets from Livewire and Askr gets from
Inertia.

`Form` is optional. Use Inertia's `useForm` directly and give `Field` an
`error` and the control a `bind:value` — everything else still works. The
demo does it both ways on purpose.

**`Form` lives behind `@askrcode/lauf/inertia`** because it is the only
component that imports Inertia. A JSON service or a desktop shell that never
installs Inertia should still be able to import a button.

### Using it from a checkout rather than npm

An app that depends on Lauf through `file:` or `npm link` gets a symlink out
of its own tree, and Lauf has its own copies of `svelte` and
`@inertiajs/svelte` for testing. Without deduping, Vite resolves them
separately, `createInertiaApp` initialises the app's router while `Form`
imports Lauf's, and you get
`Cannot read properties of undefined (reading 'visit')` nowhere near the
cause. Add this to the app's `vite.config.js`:

```js
resolve: { dedupe: ['svelte', '@inertiajs/svelte', '@inertiajs/core'] }
```

Installing from the registry does not need it — npm hoists one copy. Note
that deduping also cut the demo's bundle from 300 kB to 218 kB, because the
second Svelte runtime went with it.

### What the browser validates first

`<Input type="email">` means the browser refuses to submit a malformed
address before the request is ever made, so your server-side email rule
never sees it. That is standard HTML behaviour and usually what you want,
but it does mean the two validations do not agree about when they run. If
you want the server to be the only judge, use `type="text"` with
`inputmode="email"`.

## Tests

```sh
./askr lauf          # from the repository root
npm test             # from here
```

The suite skips itself when `node` is missing, so `./askr test` does not
require npm to be green.

One of these is a **premise test**, not a unit test: `tree-shaking.test.js`
runs a real Vite build of an app that uses one icon and asserts the neighbour
in the same barrel file is absent from the output. If it stops holding, the
icon model is wrong, not the test.

Accessibility is half of what this library delivers, so `axe-core` runs
against every component in every state it supports. A `Field` whose label is
not connected to its input is a failure, not a detail.

**axe cannot check colour contrast here.** jsdom does no layout and computes
no colours, so that rule is turned off in `tests/axe.js` — it is not silently
passing. Contrast has to be checked in a real browser, and that is listed as
its own step in `LAUF.md`.
