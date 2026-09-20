# Lauf

UI components for [Askr](../../README.md) apps, built on Svelte 5.

**This is block 0 of the plan in [`LAUF.md`](../../LAUF.md): infrastructure
only.** Tokens, `cn()` and `Icon` are here. The components you would actually
put on a page — `Button`, `Input`, `Field` — are block 1 and do not exist
yet.

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
