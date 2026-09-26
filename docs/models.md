# Models

A model is a class with a `published` section. The mapping comes from RTTI —
no code generation, no annotations.

```pascal
uses Askr.Urd.Model;

type
  TCustomer = class(TModel)
  private
    FId: Int64;
    FName: string;
    FEmail: string;
    FBalance: Currency;
    FActive: Boolean;
  published
    property Id: Int64 read FId write FId;
    property Name: string read FName write FName;
    property Email: string read FEmail write FEmail;
    property Balance: Currency read FBalance write FBalance;
    property Active: Boolean read FActive write FActive;
  public
    class procedure Describe(S: TSchema); override;
    procedure Rules(V: TValidator); override;
  end;
```

Conventions, all overridable in `Describe`: the table is the pluralised
snake_case of the class name without `T` (`TCustomer` → `customers`), the
primary key is `id` and auto-increments, and a column is the snake_case of
the property name.

> `TModel` is declared with `{$M+}`. Without it the models would not be
> allowed a `published` section, and the whole mapping would have needed
> code generation.

## Describe

```pascal
class procedure TCustomer.Describe(S: TSchema);
begin
  S.Table('customers');
  S.PrimaryKey('id');                { AAutoIncrement=False for a UUID you set }
  S.Column('Sum_', 'sum');           { property name -> column name }
  S.Ignore('Computed');              { not a column at all }

  S.Timestamps;                      { created_at, updated_at }
  S.SoftDeletes;                     { deleted_at }
  S.EmptyIsNull('Notes');            { '' is written as NULL }

  S.HasMany('Orders', TOrder, 'customer_id');
  S.BelongsTo('Customer', TCustomer, 'customer_id');
  S.HasOne('Profile', TProfile, 'customer_id');
end;
```

The metadata is built once per class and cached.

### EmptyIsNull

Pascal has no null string. A nullable text column set from a model was
therefore never NULL: an empty field went in as `''`, and `WhereNull` found
nothing. For a `json` or `uuid` column it is worse than wrong — `''` is not
a value there at all, and Postgres and MySQL refuse the save.

`S.EmptyIsNull('Notes')` writes an empty string as NULL. It has to be asked
for rather than done for every string, because in a NOT NULL column `''` is
a real value and NULL would make the save fail. `askr make model` asks for
it on every column its spec marked with `?`. Naming a property that is not
there, or one that is not a string, raises — a setting that silently did
nothing would look like it worked.

It is the same argument as a `TDateTime` of zero being written as NULL
(see [Timestamps](#timestamps)), made for strings.

### ZeroIsNull

```pascal
S.ZeroIsNull('MakerId');
```

The same for an integer that refers to a row. No table has a row 0, so 0
is how Pascal says "none": it is written as NULL and goes out in JSON as
`null`. Without it a nullable reference could never be NULL — an empty
select wrote 0, a foreign key to a row that is not there. `Required`
refuses 0 on its own, as it does any zero number. `askr make model` asks
for it on every `references` column, nullable or not. An integer property
only, or it raises.

### An unset date

A `TDateTime` of zero is an unset date. It is written as NULL, is blank to
`Required`, and goes out in JSON as `null` — it used to go out as
`1899-12-30 00:00:00`, and a form filled from it showed that.

> A `published` field must come **before** properties in the same section,
> and a forward-declared class cannot be used as a type argument to
> `TModelList<M>`. So the child model must be fully declared before the
> parent.

## Saving

```pascal
C := Arena.New<TCustomer>;
C.Name := 'Ada';
C.Email := 'ada@example.com';
C.Save;                    { INSERT; C.Id is filled in }

C.Balance := 500;
C.Save;                    { UPDATE — Persisted is now true }
```

`Save` uses the ambient connection unless you pass one. `Persisted` is set
by `Hydrate` and by `Save`, and decides INSERT against UPDATE.

## Timestamps

```pascal
S.Timestamps;                            { created_at, updated_at }
S.Timestamps('opprettet', 'endret');     { your own names }
```

The model needs matching published `TDateTime` properties. If they are
missing, `Describe` raises immediately rather than letting the timestamps
quietly fail to be set.

`created_at` is set on INSERT, `updated_at` on both. **In UTC** — two
servers in different zones must not write different values for the same
instant.

This is the model's job, not a database `DEFAULT`. A DEFAULT sets
`created_at` on INSERT and never touches `updated_at` again, so a row
updated ten times looks as fresh as the day it was made.

A `created_at` that is **already set is not overwritten**, so an import can
preserve original timestamps.

> **A `TDateTime` of zero is written as NULL, not as 1899-12-30.** Pascal
> has no null, and 0 is a real date nobody means. If the column is NOT NULL
> you now get a constraint error instead of a silently wrong date — which is
> the right way to fail.

## Soft deletes

```pascal
S.SoftDeletes;                  { deleted_at }
```

```pascal
Post.Delete;        { sets deleted_at; the row stays }
Post.IsTrashed;     { true }
Post.Restore;       { clears it }
Post.ForceDelete;   { really deletes }
```

With soft deletes on, **every query excludes the deleted rows**. A forgotten
`WHERE deleted_at IS NULL` is exactly the mistake the mechanism exists to
make impossible. See [Queries](queries.md) for `WithTrashed` and
`OnlyTrashed`.

`Persisted` stays true after a soft delete. The row exists, and a later
`Save` must update it rather than inserting a new one.

The migration side has a matching one-liner:

```pascal
with S.Create('posts') do
begin
  Id;
  Text('title', 120);
  Timestamps;
  SoftDeletes;        { nullable, indexed deleted_at }
end;
```

It is indexed because every query against the table now carries a clause
about that column.

**A relation loads what a query would.** `Preload` leaves a trashed child
out of a `HasMany`, a `HasOne` and a `BelongsToMany`, as a query for the
children does. A `BelongsTo` loads the parent it points at even when that
parent is trashed: the foreign key still points at it, and a relation left
empty would be written as "not loaded", which it was.

## Lifecycle events

Virtual methods, not observers registered at runtime. The compiler sees
them, and there is no reflection to go through.

```pascal
procedure TPost.BeforeSave;
begin
  if FSlug = '' then
    FSlug := Sluggify(FTitle);
end;
```

| Save | Delete |
|---|---|
| `BeforeSave` | `BeforeDelete` |
| `BeforeInsert` / `BeforeUpdate` | *(SQL)* |
| *(SQL)* | `AfterDelete` |
| `AfterInsert` / `AfterUpdate` | |
| `AfterSave` | |

**To cancel: raise.** It is the one way in Pascal that the call site cannot
overlook, and a `Save` that silently declined to save would be worse than an
exception.

## Relations

```pascal
S.HasMany('Orders', TOrder, 'customer_id');
S.BelongsTo('Customer', TCustomer, 'customer_id');
S.HasOne('Profile', TProfile, 'customer_id');
```

The `published` field holds the loaded relation:

```pascal
type
  TCustomer = class(TModel)
  published
    Orders: TModelList<TOrder>;      { a field, before the properties }
    property Id: Int64 read FId write FId;
    ...
```

> Nested specialisation cannot be written as a type argument:
> `A.New<TModelList<TOrder>>` is read as a shift operator. Make an alias:
> `TOrderList = TModelList<TOrder>;`

Loading is explicit — see `Preload` in [Queries](queries.md). A relation
that was not loaded is **omitted** from Inertia and JSON output, not set to
null, so the frontend can tell "no orders" from "did not ask".

### Many to many

Posts have many tags, and tags have many posts. The rows between them live
in a pivot table that holds a pair of keys and nothing else:

```pascal
S.BelongsToMany('Tags', TTag);
```

That is posts to tags through `post_tag`, where `post_id` points at the post
and `tag_id` at the tag — the two singular names in alphabetical order, as
in Laravel. `askr make pivot Post Tag` writes the migration for exactly
that table: both keys cascade on delete, the pair is unique, and the second
key has an index of its own for loading from the other side. It prints the
lines that go in the model rather than editing it.

Name them when yours differ:

```pascal
S.BelongsToMany('Tags', TTag, 'article_labels', 'article_id', 'label_id');
```

It loads with `Preload(['Tags'])` into a published `TModelList<TTag>` field,
in **one query for the whole list** — the tags joined to the pivot — and a
post with no tags gets an empty list, not nil. A tag that is soft-deleted is
left out, as a query for it would; it is still attached.

The rows in the pivot are changed on the model, which has to be saved first
— the pivot row points at its id:

```pascal
Post.Attach('Tags', [3, 7]);    { adds the ones not already there }
Post.Detach('Tags', [7]);       { removes the ones given }
Post.DetachAll('Tags');
Post.Sync('Tags', [3, 5]);      { exactly these, an empty list included }
Ids := Post.RelatedIds('Tags'); { what an edit form ticks }
```

- **Attaching one that is there is not an error.** Attach reads what is
  attached and inserts the rest, so a double submit does not become a
  unique violation.
- **`Detach` with an empty list removes nothing.** Emptying is `DetachAll`,
  said on purpose, never the accident of a list that happened to be empty.
- **`Sync` is all or nothing.** It runs in a transaction, so an id the
  database refuses leaves the rows as they were rather than half-changed.
  Called inside a transaction you opened, your commit decides.
- **An id is not checked against the other table here.** The pivot's
  foreign keys refuse a row to nothing; on a form, check the ids first so
  the refusal lands on the field instead of as a 500.

From a form or an API call:

```pascal
Ok := Post.Validate;
HasTags := Req.InputIds('tag_ids', TagIds, Post.Errors);
if HasTags then
  IdsExist(Post.Errors, 'tag_ids', 'tags', TagIds);
if not Post.Errors.IsEmpty then
  Exit(BackWithErrors(Post.Errors));
Post.Save;
if HasTags then
  Post.Sync('Tags', TagIds);
```

`InputIds` reads a JSON array — of numbers or numeric strings — or form and
query fields named `tag_ids[]` or `tag_ids`, repeated. It returns **whether
the key was sent at all**, which is what lets a `PATCH` that leaves the tags
alone be told from a form with every box unticked. A plain HTML form sends
nothing for no ticked boxes, so it says "none" with a hidden
`<input type="hidden" name="tag_ids[]" value="">`: the empty entry is left
out without complaint, and the key is there. An entry that is not a positive
whole number is a message on the field, not a list that quietly got shorter.

`IdsExist` checks the whole list in one query and names every id that is not
a row:

```
tag_ids contains 99, 100, which does not match a row in tags
```

Both add to `Errors`, so call them after `Validate`, which starts it afresh.

## Lists

```pascal
Liste := TQuery<TCustomer>.New.Get;
for I := 0 to Liste.Count - 1 do
  WriteLn(Liste[I].Name);
```

`TModelList<M>` lives in the arena and indexes with the right static type.
`TModelListBase` exists so serialisation and eager loading can handle a list
without knowing the element type — without it, every consumer would have to
be specialised per model, which is the boilerplate generics were supposed to
remove.

## What never goes in a payload

```pascal
class procedure TUser.HideFromJson(H: TJsonHidden);
begin
  H.Add(Users.PasswordHash);
end;
```

**The serialiser writes every mapped column.** That is right for a query
and wrong for anything that leaves the process: a model with a
`PasswordHash` property puts the hash into any JSON response, any Inertia
prop, any list, and any relation that carries it. `askr new --auth`
generates exactly such a model, so this is not hypothetical — it was
measured before it was fixed.

`HideFromJson` is declared once, on the model, rather than at each place
that serialises. There are four such places and they all end in the same
function, which is where the check lives; putting it at the call sites
instead is how one of them ends up shipping the hash.

The argument is the typed constant `askr schema` generates, so a column
renamed later **stops compiling** rather than quietly starting to leak.
`H.AddColumn('password_hash')` takes the name directly, for a project that
has not run `askr schema` yet.

It is about serialisation only. A hidden column is still selected, still
written, still queryable — it just never leaves in a payload. Ask
`Meta.IsHidden(ColumnName)` when you build a payload yourself.

## Validation

```pascal
procedure TCustomer.Rules(V: TValidator);
begin
  V.Field('Name').Required.MaxLen(120);
  V.Field('Email').Required.Email.UniqueIn('customers');
end;
```

```pascal
if not C.Validate then
  Exit(BackWithErrors(C.Errors));
```

See [Validation](validation.md).

## What is not here

**Dynamic attributes.** Properties conjured at runtime are impossible here
and unwanted. Askr's typed columns catch `Where(Customers.Email, Eq, 42)`
at compile time, which is the stronger guarantee, not the weaker one.

**Casts and accessors.** The types are already static: a `Currency` is a
`Currency` the whole way. Casts exist in dynamically typed stacks because
every value arrives from the database as a string.

**Both sides as typed fields, in two units.** A `TModelList<TTag>` field
needs `TTag` in the interface, and two units cannot use each other. Declare
the relation on the side you load from, or keep the two models in one unit.

**Columns on the pivot.** A pivot is two keys. A link that carries its own
data — a quantity, a role, a date — is a model of its own with two
`BelongsTo`, and then it can be validated, timestamped and queried like one.

**Polymorphic relations.** A column that names a table and another that
names a row in it cannot have a foreign key, so the database cannot keep it
true. Two relations, or a pivot per kind, can.

**Factories and seeders-as-model-builders.** Seeders exist
(`askr make seeder`); a factory layer without reflection would be mostly
ceremony.
