# Lauf — the frontend layer

Lauf is Askr's component library: Svelte 5, Tailwind v4, and the pieces that
know about Inertia and Urd. `askr new` sets it up, and a new project's demo
page is already written in it.

It is not a separate product you may or may not adopt. It is the frontend
half of the framework, the way Urd is the data half.

**What it does not change:** the binary still starts and answers with no npm,
no network and no files beside it. The welcome page and the sign-in scaffold
stay plain HTML on purpose — they must work in the window before
`npm install` has been run. Lauf is for the pages your app builds.

## What you get

```sh
askr new shop
cd shop
(cd frontend && npm install)
askr serve
```

- `frontend/src/app.css` — Tailwind, Lauf's theme tokens, and the `@source`
  line that lets Tailwind see the library's classes
- `frontend/src/Layout.svelte` — the shell, with `<Flash />` in it
- `frontend/src/pages/Home.svelte` — written with `Heading`, `Text`, `Card`
  and `Button`
- `vite.config.js` — the Tailwind plugin, and the `dedupe` a linked package
  needs

## It is not on npm, and that is deliberate

Lauf ships inside the framework release. `askr install` points your
`frontend/package.json` at it through a gitignored symlink:

```json
"@askrcode/lauf": "file:./.askr/lauf"
```

The path is identical on every machine, so the file does not produce a
diff that follows whoever last ran `install`.

Publishing to npm would put the version in a second place — one that can
lag behind the tag, or be built from a different commit. A release is
supposed to be one number across both halves, and there is a test that
fails if the framework and `frontend/lauf/package.json` disagree. Adding
a registry adds a third copy that test cannot see.

What you give up: `npm install @askrcode/lauf` in a project that is not
an Askr project. That is a real cost, and a narrow one.

## Three layers

**Tokens.** `--color-surface`, `--color-fg`, `--color-accent` and the rest,
semantic rather than literal. Override them in your `app.css` and the whole
library follows.

Dark mode lives in one place. No component writes a `dark:` class — if each
one carried `bg-white dark:bg-zinc-900`, your palette would mean editing
every file in the library. It handles three states, not two: an explicit
choice stamps `data-theme` on the root, and the default "follow the system"
stamps nothing, so only `prefers-color-scheme` separates those two.

**Behaviour.** Everything that opens and closes is built on
[Bits UI](https://bits-ui.com): focus trapping and restoring, roving
tabindex, typeahead, dismiss ordering, floating placement with collision
detection, scroll locking. Bits never appears in Lauf's API, so don't import
from it yourself.

**Lauf.** The components you use.

## Components

`Button` (`.Group`), `Input`, `Textarea`, `Select`, `Checkbox`, `Radio`,
`Switch`, `Field`, `Heading`, `Text`, `Icon`, `Badge`, `Card`, `Separator`,
`Table`, `Pagination`, `Modal`, `Dropdown`, `Popover`, `Tooltip`, `Tabs`,
`Accordion`, `Avatar`, `Callout`, `Breadcrumbs`, `Navbar`, `Sidebar`,
`Skeleton`, `Toaster`, `Progress`, `Slider`, `OtpInput`, `Autocomplete`,
`Command`, `DatePicker`, `FileUpload`, `DataGrid`, `Editor` — and `Form` and
`Flash` from `@askrcode/lauf/inertia`.

Either import style works, and they build to the same bytes:

```svelte
import { Button } from '@askrcode/lauf'      <Button>Save</Button>
import * as Lauf from '@askrcode/lauf'       <Lauf.Button>Save</Lauf.Button>
```

The namespace form is there because it reads like the Blade components a
lot of people are coming from. It is free — Rollup follows namespace member
access, so it tree-shakes exactly as well as a named import, and a test
measures that rather than assuming it.

The full reference, with the reasoning behind each choice, is in
[`frontend/lauf/README.md`](../frontend/lauf/README.md).

## Tabs

```svelte
<Lauf.Tabs bind:value={tab} {tabs} variant="segmented">
  <Lauf.Tabs.Panel value="profile">…</Lauf.Tabs.Panel>
</Lauf.Tabs>
```

The tabs are data — `{ value, label, icon?, badge?, disabled? }` — rather
than child components, because in an Askr app they usually come from the
server and Lauf's icons are components already. Three variants
(`underline`, `segmented`, `pills`), two sizes, and `scrollable` for when
they do not fit.

Bits UI owns the keyboard: arrow keys, Home/End, the roving tabindex and
the link between a tab and its panel.

**`findable` is the part Bits does not reach.** An inactive panel carries
`hidden`, so the browser's own Ctrl+F cannot see into it — on a settings
page split across six tabs that makes the search box a lie. With
`findable` the inactive panels are marked `hidden="until-found"`, the
browser searches them anyway, and on a match Lauf selects the owning tab
so the panel is properly open rather than a fragment hanging out of a
closed container.

## The editor writes markdown

```svelte
<Field name="notes" label="Release notes">
  <Lauf.Editor bind:value={notes} preview />
</Field>
```

The value is markdown, in and out. Not HTML — markdown is what belongs in
the database: readable in a SQL console, it diffs, and it cannot carry a
script.

It is a `<textarea>` with a toolbar and a preview pane, not a
`contenteditable`. You see `**bold**` rather than bold, and in exchange you
get everything the browser already does well: selection, paste, IME, mobile
keyboards, and undo. A click on *Bold* lands on the browser's own undo
stack, so `⌘Z` walks back through formatting and typing together — checked
in a real Chrome, because jsdom has no `document.execCommand` to check it
with.

```svelte
<Lauf.Editor toolbar="heading | bold italic | bullet ordered ~ preview" />
```

`|` separates, `~` spaces out, and an unknown name is skipped rather than
thrown — a typo should cost a button, not the page. `⌘B`, `⌘I`, `⌘K` and
`⌘E` are wired, and every button toggles off again.

**Raw HTML never reaches the preview.** That is the whole security answer:
the text comes from whoever is typing, and the preview runs in the reader's
browser on your domain. Everything is escaped, and a link may only be
`http`, `https`, `mailto`, `tel` or relative — `javascript:` and `data:`
become `#`.

`renderMarkdown` is exported for showing stored markdown elsewhere, so a
page does not need a markdown package for what the editor already does.

## Forms know about your validation

```svelte
<Form action="/customers" data={sendt ?? {}} {errors}>
  <Field name="email" label="Email"><Input type="email" /></Field>
  <Button type="submit" variant="primary">Save</Button>
</Form>
```

Three things happen without being wired: `Field` finds its own error message
by name from what [validation](validation.md) put in the payload, the control
gets a matching `id`, `aria-describedby` and `aria-invalid`, and the submit
button shows a spinner while the request is out.

`Form` is optional — use Inertia's `useForm` and give `Field` an `error` and
the control a `bind:value` instead.

## The grid sorts in the database

`DataGrid`'s server half is [`Askr.Urd.Grid`](database.md), not JavaScript.

```pascal
G := TGrid<TCustomer>.New;
G.Read(Req)
 .Sortable('name', Customers.Name)
 .Searchable([Customers.Name, Customers.Email])
 .DefaultSort('name');

Result := Inertia('Customers/Index',
  ['rows', G.Rows(TQuery<TCustomer>.New), 'grid', G]);
```

`Sortable` is an allowlist, and it is not a check somebody remembered to
write: `OrderBy` takes a typed column, not a string, so a key that was never
registered has nothing to sort by. `'ORDER BY ' + param` cannot be written
here.

`Searchable` becomes a single
[`WhereAnyLike`](queries.md#searching-several-columns-at-once) over the
columns you list — one expression with `OR` between them, in a parenthesis,
and nothing at all when the box is empty.

Leave the `grid` prop off and the component sorts and pages the array itself.
That is fine for a few thousand rows and wrong beyond it — at that point you
are pulling a table across the network to do what the database just did.

## Icons

```svelte
import { ArrowDownTray } from '@askrcode/lauf/icons/micro'
<Icon icon={ArrowDownTray} />
```

The icon is a component, not a name. A name has to be looked up in a map,
and a map keeps all 1288 icons in your bundle however few you use.

They are generated from [Heroicons](https://heroicons.com) and are not in
git. If a build complains that `@askrcode/lauf/icons/micro` cannot be
resolved, run `npm install` once inside the framework's `frontend/lauf`.

## Flash becomes toasts

```svelte
<Flash />   <!-- once, in your layout -->
```

Whatever keys your app flashes are carried:

```pascal
InertiaFlash('success', 'Customer ' + C.Name + ' was created.');
```

Two live regions, not one: confirmations are polite so they do not interrupt,
errors are assertive so they do. Both are in the document before any message
arrives — add the region and the text at the same time and a screen reader
never notices the change.

## What is missing

No colour picker, no WYSIWYG editor, no kanban board, no charts, no
client-side validation. `Editor` writes markdown source; true rich text
means ProseMirror, and that is a dependency Lauf does not have. The grid does not reorder or pin columns by drag, and
does not group, edit in place, scroll infinitely or export. Each is its own
project; the reasons are in `LAUF.md` in the repository root.

Client-side validation is the one worth repeating: the server has to validate
anyway, and the same rule written twice drifts apart. What is projected
instead is the column definition — `required` and `maxlength` come from the
schema, which is the same fact used in two places rather than the same logic
written twice.

## Tests

```sh
./askr lauf         # the suite
./askr lauf:play    # the components in a browser, on 4173
./askr lauf:check   # contrast and screenshots, light and dark
```

`./askr test` does not require npm — the Lauf suite skips itself, saying why,
when node is missing.
