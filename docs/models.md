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

  S.HasMany('Orders', TOrder, 'customer_id');
  S.BelongsTo('Customer', TCustomer, 'customer_id');
  S.HasOne('Profile', TProfile, 'customer_id');
end;
```

The metadata is built once per class and cached.

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

**Factories and seeders-as-model-builders.** Seeders exist
(`askr make seeder`); a factory layer without reflection would be mostly
ceremony.
