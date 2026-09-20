# Rún

Rún is an optional query language that reads your database **at compile
time**. It is part of the toolchain — `askr build` runs it over every
`*.run` file in your project — but it is **not the default data layer**.
[Urd and Norn](queries.md) still are, and the reason is measured below.

## What it gives that Pascal cannot

**Generics that monomorphise.** One declaration becomes concrete, typed
functions:

```
query<M> ById(id: int) -> M for Customer, Order
```

gives `CustomerById` and `OrderById`, each with its own row type. In Pascal
this would need two nearly identical functions — a generic method is
rejected by the compiler, and that is the finding phase 3 rests on.

**`with` for eager loading.** `with` is a reserved word in Pascal and cannot
be a name there. Here it can, and **the relation is not declared** — it is
read from the foreign key in the schema:

```
db "postgresql://user:pass@host/shop"

model Customer from customers
model Order from orders

query ActiveCustomers(minBalance: money) -> [Customer]:
  from Customer
  where balance >= minBalance and active == true
  with orders
  order by balance desc, name
  limit 10
```

`TCustomerRow` gains a field `Orders: TOrderRowArray` because
`orders.customer_id` points at `customers.id`. The orders are fetched with
**one** extra query, not one per row.

The rest of v0.1: `is null` / `is not null`, `like`, `offset`, several sort
keys, and `-> M` for a single row with `out Found`.

## Using it

Put `*.run` files under `app/`. `askr build` transpiles them to
`.build/run/App.<Name>.pas` before calling `fpc`. There is no command to
remember.

A compile-time error stops the build with the file, the line and what the
schema actually says:

```
app/Queries.run:10: table "customers" has no column "balanse".
Did you mean "balance"?
```

```
app/Queries.run:6: "balance" is money in table customers, but is compared
with text. The schema was read from postgresql://...
```

## What comptime gives that codegen does not

**The types come from the schema.** `NUMERIC(12,2)` becomes `Currency`,
`TINYINT(1)` becomes `Boolean`, `customer_id` becomes `CustomerId: Int64`.
The Rún source mentions none of them, and the generated code has no model
class, no `published` section and no RTTI.

**Errors are caught before `fpc` sees the code**, with the schema in the
message.

**The dialect is a compile-time decision.** The DSN in the source decides
placeholder form and quoting; the queries mention neither.

## And the cost

Comptime reads the database on **every build**, which is inside the
developer loop:

| Schema | Comptime introspection |
|---|---|
| SQLite, 2 tables | 1 ms |
| SQLite, 32 tables | 2 ms |
| SQLite, 62 tables | 4 ms |
| Postgres, 1 table | 11 ms |
| Postgres, 21 tables | 21 ms |
| Postgres, 61 tables | **70 ms** |

The developer loop is measured at 247 ms against a requirement of 300. That
is **53 ms of headroom**. Against SQLite comptime is free. Against Postgres
with 61 tables it costs **more than the entire margin, by itself**, over a
container network with no latency.

The variant that fits caches the schema between builds and re-reads only
when it changed; parsing and emitting without introspection is 1–2 ms. But
caching a schema and emitting typed code from it, with a check for whether
it has changed, **is Norn codegen**. What is left of the difference is where
the file lives and whether it is committed.

So: **Rún is an offer, not the default.** It is worth having inside the
framework because type checking against a live schema gives error messages
Norn does not give today — and because being in the test gate means it does
not rot. Against SQLite, and against Postgres with smaller schemas, it is
free to use.

## Running the chain

```sh
./askr run:demo
```

`.run` source → introspection of a real database → type check against the
schema → Pascal → `fpc` → a binary that queries the same database.

`tests/askr_run_tests.lpr` covers the transpiler against a real SQLite
database, including that each of the six comptime errors still says what it
should.

## The API

```pascal
uses Askr.Run;

S := Transpile('app/Queries.run', '.build/run/App.Queries.pas', 'App.Queries');
S.Models;  S.Queries;  S.Dialect;
S.ParseMs; S.SchemaMs; S.EmitMs; S.TotalMs;
```

`UnitNameFor` gives the unit name a `.run` file should produce.

## Implementation notes

The transpiler uses `Askr.Norn.Introspect` — the same code Norn uses. That
is deliberate: what is being measured is not *how* the schema is read but
*when*.

Row types are emitted in **dependency order**. A record cannot
forward-reference another record in Pascal, so `TOrderRow` must come before
`TCustomerRow` when the latter has an `Orders` field. `SorterModeller` does
a depth-first sort and reports a cycle rather than hiding it.

As a unit rather than a one-shot program, global state has to be reset:
`Transpile` is called once per file in the same process, and `Nullstill`
runs first. Without it the second file inherits the first file's models.
