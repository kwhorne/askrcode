# Queries

```pascal
uses Askr.Urd.Query, App.Schema.Customers;

Liste := TQuery<TCustomer>.New
  .Where(Customers.Balance, GT, 150)
  .Where(Customers.Email, Like, '%@example.com')
  .OrderBy(Customers.Balance, Desc)
  .Preload(['Orders'])
  .Limit(10)
  .Get;
```

`Customers.Balance` is a typed column constant generated from your real
database by `askr schema`. That is what makes the builder typed:

```pascal
.Where(Customers.Email, Eq, 42)     { will not compile }
```

See [Typed columns](schema.md). You can also write columns by hand:

```pascal
.Where(ColStr('customers', 'email'), Eq, 'ada@example.com')
```

> The entry point is `TQuery<TCustomer>.New`, not `Query<TCustomer>` as the
> PRD writes it. A generic free-standing function cannot be exported from a
> unit in FPC 3.2.2. Same type safety, four more characters.

## Filtering

```pascal
.Where(Col, Op, Value)
```

Operators: `Eq`, `Ne`, `GT`, `GTE`, `LT`, `LTE`, `Like`, `ILike`.
Overloads exist for `Int64`, `string`, `Currency`, `Double`, `Boolean` and
`TDateTime`, each taking the matching column type.

```pascal
.WhereIn(Customers.Id, [1, 2, 3])
.WhereIn(Customers.Email, ['a@x.no', 'b@x.no'])
.WhereNull(Customers.DeletedAt)
.WhereNotNull(Customers.ConfirmedAt)
```

Terms are combined with `AND`. `OR` groups are not in the builder; use
`Exec` with your own SQL for those.

## Ordering, limits, paging

```pascal
.OrderBy(Customers.Name)              { Asc by default }
.OrderBy(Customers.Balance, Desc)
.Limit(25)
.Offset(50)
```

```pascal
Liste := TQuery<TCustomer>.New.Paginate(Req.Page, 25);
```

`Req.Page` reads `?page=N` and clamps to at least 1.

## Getting results

| | |
|---|---|
| `.Get` | `TModelList<M>` |
| `.First` | One model, or `nil` |
| `.Find(Id)` | By primary key, or `nil` |
| `.Count` | `Int64` |
| `.ToSql` | The SQL it would run — useful in tests and logs |

```pascal
C := TQuery<TCustomer>.New.Find(7);
if C = nil then
  Exit(RespondText('Not Found', 404));
```

## Eager loading

```pascal
.Preload(['Orders'])
```

`Preload` runs **one extra query per relation**, not one per row. That is
the difference between `Preload` and a loop, and the reason it is worth a
name of its own.

> It is called `Preload`, not `With`, because `with` is a reserved word in
> Pascal.

A relation that was not preloaded is **omitted** from serialised output, not
set to null, so a frontend can tell "no orders" from "did not ask".

## Soft deletes

With `S.SoftDeletes` on the model, every query excludes deleted rows by
default.

```pascal
TQuery<TPost>.New.Count;                { visible only }
TQuery<TPost>.New.WithTrashed.Count;    { all }
TQuery<TPost>.New.OnlyTrashed.Count;    { deleted only }
```

The clause is qualified with the table name, so it still holds when the
query gains a join.

## Bulk operations

```pascal
TQuery<TPost>.New.Where(Posts.Draft, Eq, True).DeleteAll;
TQuery<TPost>.New.ForceDeleteAll;
TQuery<TPost>.New.RestoreAll;
```

**With soft deletes on, `DeleteAll` soft-deletes**, exactly as
`Model.Delete` does. One deleting softly and the other hard is the kind of
difference nobody remembers until a table is empty. `ForceDeleteAll` deletes
regardless; `RestoreAll` brings back the trashed ones.

## Scopes

Query scopes need nothing from the framework. A scope is a function that
returns a query — typed, chainable, and the compiler sees it:

```pascal
function RecentPosts(Count: Integer): TQuery<TPost>;
begin
  Result := TQuery<TPost>.New
    .OrderBy(Posts.CreatedAt, Desc)
    .Limit(Count);
end;

Liste := RecentPosts(10).WithTrashed.Get;
```

It cannot be a class method on the model: the return type would
forward-reference the class's own type, which is the same limit that
applies to `TModelList<M>`.

## Choosing the connection

```pascal
TQuery<TCustomer>.New;              { the ambient connection }
TQuery<TCustomer>.Using(C);         { a specific one }
```

The ambient connection is set by the host with `UseDb` at the start of a
request, which is what lets `Model.Save` be written without arguments.

## Cost

Measured against Postgres 17: **5.8 kB of arena** for a request that fetches
five rows with eager loading of fifteen children, and no growth across 1000
such requests.
