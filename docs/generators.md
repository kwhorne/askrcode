# Generators

```sh
askr make model Gadget name:string(60) born:date maker:references
askr migrate
askr make resource Gadget            # pages
askr make resource Gadget --api      # and JSON
```

Two commands, in that order, and the order is the design. **`make model`
turns a spec into a table. `make resource` turns a table into an
application.** The second one reads the database — the table that exists,
not the spec that made it — so it works just as well on a table you wrote a
migration for by hand, or one that was there before Askr was.

Everything they write is yours the moment it exists. Nothing regenerates
it, and **`make` never writes over a file that is there**: if any file a
command would write already exists, nothing is written and the file is
named. `--force` replaces it.

## A model from a spec

```sh
askr make model Gadget name:string(60) notes:text? qty:int price:money \
                       born:date maker:references
```

The model and its migration come from the same spec, so they start out
agreeing — which a model and a migration written by hand stop doing one
column at a time.

| Type | Column | Property |
|---|---|---|
| `string`, `string(n)` | `VARCHAR(n)`, 255 when no length is given | `string` |
| `text` | `TEXT` | `string` |
| `int`, `bigint` | `INTEGER`, `BIGINT` | `Int64` |
| `bool` | the dialect's boolean | `Boolean` |
| `money` | `NUMERIC(12,2)` | `Currency` |
| `float` | the dialect's double | `Double` |
| `datetime`, `date` | the dialect's timestamp and date | `TDateTime` |
| `json`, `uuid` | the dialect's JSON and UUID where it has them | `string` |
| `thing:references` | `thing_id BIGINT`, a foreign key to `things` | `Int64` |

A trailing `?` makes a column nullable, and `:unique` after the type — and
after its `?` — makes a unique index: `email:string(120):unique`. Not on
`text`, `json` or `bool`: MySQL will not index the first two without a
length, and a boolean has two values. Timestamps are on by default, in
both files together — `--no-timestamps` leaves them out of both.

`Rules` gets what the spec **states**: `Required` for a NOT NULL text,
date or reference, `MaxLen(n)` for a `string(n)`, `Unique` for a
`:unique` column, and `Exists('makers')` for a reference — so a duplicate
and a key to nothing are messages on the form rather than a 500 from the
database. Not for a NOT NULL
number or boolean — zero and false are values, and Required would refuse
the one nobody thinks of as missing. **Nothing is inferred from a name**:
a column called `email` is not therefore an email.

**Refused, with a message saying why:**

- A type that is not on the list. `name:strng` would otherwise become a
  column of some kind, and a typo should not decide which.
- A name the model would not map back to. A model finds a property's
  column with `SnakeCase` at run time, so the property written for a
  column has to snake_case back to exactly that column. `abc_2x` would
  become `Abc2x`, which maps to `abc2x`.
- A Pascal keyword — `label`, `type`, `end`. The usual escape, a trailing
  underscore, is what breaks the mapping: the model would read `label_`
  while the migration made `label`. That happened in Askr once, by hand.
- `id`, `created_at` or `updated_at`, which are there already; a column
  given twice; and `thing_id:references`, which is written `thing:references`.

It does not migrate. A `make` command that changes the database is a
surprise, and in production it is the wrong one. It prints the next step:

```
Next:
  askr migrate     makes the gadgets table
  askr schema      types its columns from the database
```

## A resource from a table

```sh
askr make resource Gadget [--table=gadgets] [--force]
```

The table is read from the database the project is configured with — the
one that **exists**, not a spec — and becomes the seven actions over it:

| File | What is in it |
|---|---|
| `app/Http/App.Http.GadgetsController.pas` | `Index`, `Show`, `Add`, `Store`, `Edit`, `Update`, `Remove`, and `GadgetsRoutes(R)` |
| `frontend/src/pages/Gadgets/` | `Index`, `Show`, `Add` and `Edit`, in Lauf, and `Fields` shared by the two forms |
| `tests/App.Tests.Gadgets.pas` | Every action, through the router |
| `app/Models/App.Models.Gadget.pas` | Only when there is none; one that is there is used as it is |
| `app/Schema/` | The typed columns, exactly as `askr schema` writes them |

and puts `GadgetsRoutes(R);` in `app.lpr` and the test in
`tests/app_tests.lpr`, at the lines `askr new` left — or, when those lines
are gone, prints what to add. It refuses a table that is not there, has no
primary key, a key of two columns, or a key that is not a whole number, and
says which.

**The controller uses the typed columns** — `Gadgets.Name`, not `'name'` —
so a column dropped later is a compile error in the controller rather than
a 500 on the page. That is the reason to generate Pascal instead of
interpreting a table at run time. **The Svelte pages are not typed against
anything**: a rename breaks the controller and leaves the pages showing an
empty cell. They say so at the top.

`Add` and `Remove`, not `Create` and `Destroy`: those are `TObject`'s
constructor and destructor, and a method with either name hides it.

**A request fills only the fields the form has.**
`Req.FillInto(M, [Gadgets.Name.Name, ...])`, not `Req.FillInto(M)` — the
one-argument form fills every column the model maps and does not set
itself, so a client that added a column the form does not have — a hidden
one, say — would have set it. The generated test sends a forged secret
where the table has one, and checks it did not land.

What the table says, the resource does:

- `NOT NULL` without a default is `Required`, and the field is marked
  required. A column **with** a default is not required, and a new form
  starts from the default when it is a plain value (`'draft'`, `0`,
  `false`); a function such as `now()` is left to the database.
- `VARCHAR(n)` is `MaxLen(n)` and `maxlength="n"`.
- A unique index on the column alone is `Unique`. One on two columns
  together is a note: a rule is on one field, so a duplicate pair is
  still refused by the database, not by the form.
- A foreign key is `Exists` against the table it points at.
- A table that points **here** — `gadgets.maker_id` on the page of a maker
  — is listed on the page: its rows, labelled by their first string
  column, linked to their own pages when those exist, and never more than
  fifty, with a line that says so. A table with no model is not listed;
  there is nothing to query it with.
- A foreign key to a table whose model exists is a select of its rows,
  labelled by its first string column and capped at a thousand — a select
  with more is the wrong control. Without a model for it, it is a number,
  and says what it points at. A key to a table that is not there is not a
  relation.
- A **pivot** — a table of two foreign keys to two other tables and
  nothing of its own but an id and timestamps, such as the one
  `askr make pivot Gadget Tag` writes — is a box to tick per row of the
  other table, in one group named for it (`tag_ids`). The edit form starts
  with the attached ones ticked; the page shows them, linked when the
  other table has pages; the API reads them with the row and answers a
  write with them. Store and Update check the ids in one query, so an id
  to nothing is a message on the field, and save the row and its pivot in
  one transaction. A request that does not send `tag_ids` leaves them as
  they are; one that sends an empty list takes them all off. The pivot
  itself is refused as a resource, and says what it is.

  The boxes need a model for the other table, and a model here that
  declares the relation. When the model here is written by the command,
  it declares it. When it is there already, the command says which lines
  to add rather than editing it. And when the other model already uses
  this one, it says that two units cannot use each other — the relation
  lives on one side, or both models live in one unit.
- A column named like a secret — `password`, `token`, `hash`, `secret`,
  `salt` — is hidden from JSON, and is in neither the form, the list nor
  the page. A guess, made in the direction whose failure is loud.
- A type a form cannot show, such as a blob, stays out of the pages, and
  out of a model this writes.
- `deleted_at` makes it soft: `Remove` sets it.

**The test runs on `TEST_DATABASE_URL`, and on `sqlite::memory:` without
one**, with the migrations run first. A test that wrote into the database
you develop against would leave its rows there. When it cannot make a row —
a `NOT NULL` column the form leaves out, with no default — it tests the
list and the 404 and says why it does not write.

### Why it is Pascal and not a runtime

A framework can serve a table without generating anything: read the
schema at start-up, build the forms from it, answer requests from a
description. That is less code in your repository and more in the
framework, and it moves every mistake to run time — a column that goes
away is a 500 on a page somebody opens next week.

Askr generates code on the typed columns instead, because then **the
compiler is the check**. Drop `gadgets.born` and run `askr schema`, and
`Gadgets.Born` no longer exists: the controller does not build, and the
error names the line. The price is that the files are yours to keep up —
which is also what lets you change them.

## As JSON: `--api`

```sh
askr make resource Gadget --api          # JSON only
askr make resource Gadget --web --api    # both
```

| File | What is in it |
|---|---|
| `app/Http/App.Http.GadgetsApiController.pas` | `GET`, `POST`, `PATCH` and `DELETE` under `/api/gadgets`, `GadgetsApiRoutes(R)`, and `GadgetsApiDoc(D)` |
| `app/Http/App.Http.ApiDoc.pas` | `AppApiDoc`, the first time; each resource after that is two lines in it |
| `tests/App.Tests.GadgetsApi.pas` | Every action, with real tokens |

and `UseOpenApi(R, @AppApiDoc)` in `app.lpr`, once.

Reading needs a token with `gadgets:read`, writing one with
`gadgets:write` — `askr token:issue 7 ci --scopes=gadgets:read,gadgets:write`.
A list is the [envelope](lists.md); a row is the model's JSON; a refusal
is a [problem document](api.md). `POST` answers 201 with a `Location`,
`DELETE` 204 with nothing. A change is a `PATCH`, not a `PUT`: what the
body leaves out is left as it is, which is what `FillInto` does and what
`PATCH` means.

**The description sits next to the routes it describes**, in the same
unit, and `askr openapi --check` fails when the two disagree. `make:check`
runs it straight after generating, and runs the document through a real
OpenAPI validator — a generated API that drifted on its first run would be
the generator being wrong about itself.

The request body in the document is what a request can set: the model's
columns without the key, the timestamps and `deleted_at`, which the model
sets itself and `FillInto` never fills. Going out, those are there and
marked `readOnly`.

## The tests it writes

Both kinds of resource get a test in `tests/`, and `askr make resource`
puts it in `tests/app_tests.lpr` — writing that file if there is none.

| | Web | API |
|---|---|---|
| The list, and a sort key it does not know | 200 | 200, in `data` |
| A row that is not there, or an id that is not a number | 404 | 404, as a problem document |
| No token, and a token without the scope | | 401, then 403 |
| A new row | 302 to its page, then its page and its form | 201 with a `Location`, read back without its secrets |
| What the rules refuse | back to the form, nothing saved | 422 naming the field, nothing saved |
| An edit with a forged `id`, `created_at` and secret | 303, only the form's fields changed | 200, the same |
| A delete | 303, gone | 204 with nothing, then 404 |

**The database is `TEST_DATABASE_URL`, and `sqlite::memory:` without one**,
with the migrations run first and — for the API — two tokens issued
there. A test that wrote into the database you develop against would leave
its rows in it. Point `TEST_DATABASE_URL` at a database that is only for
tests: pending migrations run on it.

When a row cannot be made — a `NOT NULL` column the form leaves out, with
no default, or a reference to a table the test cannot make a row in — the
test checks the list and the 404, and says in a comment why it writes
nothing.

## How it is checked

The framework's own gate, `./askr make:check`, is what stands behind the
claims on this page. It scaffolds a project and then:

- makes models with every type there is, migrates them on **SQLite,
  Postgres and MySQL**, and round-trips every column through the model it
  wrote;
- reads the table with every type back on each database, and requires
  the exact `Describe` and `Rules` lines `make model` wrote — the reader
  `make resource` stands on;
- makes four resources, one of them on a table with no model, a keyword
  for a column, a secret and soft deletes, and one with a pivot to
  another — whose relation is added to its model exactly as
  `make pivot` printed it; builds them, and runs their tests on all three
  databases;
- makes two of them `--api` too, and requires `askr openapi --check` to
  find nothing and a real OpenAPI validator to accept the document;
- drives the API over a socket with tokens from `askr token:issue`,
  including forty refusals in a row and then a request that must still be
  answered;
- drives the pages in Chrome — create, show, edit, a refused form, the
  list, search, sort and delete, and ticking, unticking and clearing the
  boxes of a pivot — and runs axe, contrast included, over
  every page in light and dark at 1280 and 390 px, with the lists empty
  and with rows in them.

It found things. Every POST from an Inertia page answered 419 until a page
made the CSRF token; an empty data grid could not be reached from the
keyboard; and a handler that raised skipped every after-filter, so each
refusal kept a pooled database connection until the pool was empty. None
of those were in the generators. All three were in the framework, and
every app using those parts had them.

## What is not here

**The Svelte pages are not typed against the table.** A column renamed
later is a compile error in the controller and an empty cell on the page.
It is the one place the chain is not closed, and the pages say so at the
top.

**The rows that point here are on the page, not in the API.** A JSON
resource's `GET /api/gadgets/:id` answers with the row alone; asking for
its children is a second request to their own list.

**Two requests at once can both pass `Unique` and `Exists`.** The rules
ask the database before the save, and a second request can take the name
or delete the row in between; the database then refuses one of them, as a
500. The rule is what makes the ordinary case a message on the form; the
constraint is what keeps the data right in the other one.

**A nullable number other than a reference cannot be NULL.** Pascal has no
null `Int64`, and nothing tells 0 from "not set". A reference has
[`ZeroIsNull`](models.md#zeroisnull), because no table has a row 0; a
count does not have that excuse.

**There is no generator for the has-many side, a nested resource, a file
field, or a search on anything but free text.** Each is a question about
what the default should be, and the answer should come from an app that
needed it.
