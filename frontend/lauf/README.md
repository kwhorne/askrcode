# Lauf

UI components for [Askr](../../README.md) apps, built on Svelte 5.

**The plan in [`LAUF.md`](../../LAUF.md) is done through block 3:** the
infrastructure, the sixteen components a CRUD app needs, the overlay layer,
and the expensive ones. One component from that list was deliberately not
built — see *What is missing* below.

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
`Table` (`.Head`, `.Body`, `.Row`, `.Header`, `.Cell`), `Pagination`,
`Modal`, `Dropdown` (`.Item`, `.Group`, `.Separator`), `Popover`, `Tooltip`,
`Tabs` (`.Panel`), `Accordion` (`.Item`), `Avatar`, `Callout`,
`Breadcrumbs`, `Navbar`, `Sidebar` (`.Item`), `Skeleton`, `Toaster`,
`Progress`, `Slider`, `OtpInput`, `Autocomplete`, `Command`
(`.Group`, `.Item`), `DatePicker`, `FileUpload` — and `Form` and `Flash`
from `@askrcode/lauf/inertia`.

### What opens and closes

`Modal`, `Dropdown`, `Popover`, `Tooltip`, `Tabs` and `Accordion` are built
on [Bits UI](https://bits-ui.com) (MIT), which owns the part that is hard
and has nothing to do with Askr: focus trapping and restoring, roving
tabindex, typeahead, dismiss ordering, floating placement with collision
detection, scroll locking, and screen-reader behaviour. Lauf owns how they
look and the parts Bits leaves out.

Bits never appears in Lauf's public API, so it can be replaced underneath
without an app noticing. Do not import from `bits-ui` yourself.

```svelte
<Dropdown>
  {#snippet trigger(props)}
    <Button {...props} icon={EllipsisHorizontal} label="Actions" />
  {/snippet}
  <Dropdown.Group label="Customer">
    <Dropdown.Item icon={PencilSquare} href="/customers/1">Open</Dropdown.Item>
  </Dropdown.Group>
  <Dropdown.Separator />
  <Dropdown.Item icon={Trash} variant="danger" onclick={remove}>Delete</Dropdown.Item>
</Dropdown>
```

The menu heading has to live inside the group it names — a heading connected
to nothing is just text in the middle of a menu, and a screen reader cannot
say which items it covers.

`Modal` requires a `title`. A dialog without a name is announced as
"dialog", and that is everything the person who cannot see it gets. Pass
`hideTitle` if the heading is already visible in the content: it is hidden
visually, not removed.

### Dates are ISO strings

```svelte
<Field name="due" label="Due date"><DatePicker /></Field>
```

`DatePicker` takes and gives back `YYYY-MM-DD`, which is what Askr's
`DateTimeToSql` produces. Bits builds on `@internationalized/date`, and that
type does not leak into Lauf's API — the conversion lives inside the
component, and a malformed or empty value gives an empty picker rather than
a blank page.

### File upload

```svelte
<Field name="attachment" label="Attachment">
  <FileUpload multiple maxSize={8 * 1024 * 1024} />
</Field>
```

Bits has no primitive for this, but Askr's server side does: the multipart
parser copies nothing, and `StoreIn` saves under a random name rather than
the client's. That is why this was cheaper than it looks.

It is built on a real `<input type="file">`, visually hidden but focusable —
`hidden` would make it unreachable by keyboard. Drag and drop is added on
top and is never the only way in. `maxSize` rejects oversized files with a
message naming them, and never silently.

### What each component costs

With tree-shaking verified (see *Tests*), an expensive component is a choice
the app makes, not a tax on everyone. Measured minified, mounted, without
gzip — the floor is the Svelte runtime plus `cn`:

| | |
|---|---|
| `Button` (the floor) | 75 kB |
| `Progress` | 81 kB |
| `FileUpload` | 84 kB |
| `OtpInput` | 100 kB |
| `Slider` | 103 kB |
| `Command` | 115 kB |
| `Modal` | 129 kB |
| `Autocomplete` | 188 kB |
| `DatePicker` | 274 kB |

`DatePicker` is the one to think twice about: about 200 kB over the floor,
because a correct calendar is a large amount of code. It is worth it on a
booking form and not worth it on a sign-up page.

### What is missing

**No colour picker.** Bits has no primitive for one, so it would be written
from scratch: a hue and saturation surface that works with a keyboard,
colour-space conversion, and contrast reporting. That is its own project,
almost no CRUD app needs one, and the apps that do want a real one. Block 3
in `LAUF.md` says to weigh each of these components on its own; this is the
one where the answer was no.

Also still absent, and on purpose: rich-text editor, kanban board, charts,
client-side validation, and a theme builder. The reasons are in `LAUF.md`.

### Toasts

```svelte
<script>
  import { Toaster, toast } from '@askrcode/lauf'
</script>

<Toaster />
<Button onclick={() => toast.success('Saved')}>Save</Button>
```

In an Inertia app use `Flash` instead — it renders the `Toaster` and turns
Askr's flash into toasts, carrying whatever keys your app sets:

```svelte
import { Flash } from '@askrcode/lauf/inertia'
<Flash />   <!-- once, in your layout -->
```

Two live regions, not one: confirmations are `polite` so they do not
interrupt, errors are `assertive` so they do. Both are in the DOM before any
message arrives — add the region and the text at the same time and a screen
reader never notices the change, so nothing is announced. `toast.error`
defaults to staying until dismissed, because a message you must read should
not disappear while you are reading it.

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
in the same barrel file is absent from the output — and that no Bits UI came
along. If it stops holding, the packaging is wrong, not the test.

It has already earned its place twice. Adding the overlay components made a
single `Button` cost 221 kB instead of 74, because `Object.assign` at module
scope — how `Button.Group` and `Table.Cell` are attached — is a call a
bundler cannot prove is safe to drop, so the barrel file kept the whole
library alive. `/*#__PURE__*/` on those exports is the fix, and
`"sideEffects"` in `package.json` is the other half.

**Some things cannot be tested here at all.** jsdom has no layout, so focus
trapping, floating placement, scroll locking, dragging a slider, and
"Escape returns focus to the trigger" are checked by driving a real Chrome
over CDP — against the demo app, and against the playground:

```sh
./askr lauf:play      # builds and serves it on 4173
```

Twelve Tab presses inside an open modal and focus never leaves it;
`aria-activedescendant` on the autocomplete pointing at a real option;
ArrowRight then Enter in the calendar giving `2026-09-21` back as a string.

`tests/setup.js` stubs the browser APIs jsdom lacks — `ResizeObserver`,
`matchMedia`, pointer capture, `scrollIntoView`. A stub lets the code run;
it does not make the measurement real. Anything that depends on actual
sizes is covered in the browser or not at all, and the file says so.

Accessibility is half of what this library delivers, so `axe-core` runs
against every component in every state it supports. A `Field` whose label is
not connected to its input is a failure, not a detail.

**axe cannot check colour contrast here.** jsdom does no layout and computes
no colours, so that rule is turned off in `tests/axe.js` — it is not silently
passing. Contrast has to be checked in a real browser, and that is listed as
its own step in `LAUF.md`.
