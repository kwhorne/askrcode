# Typed columns

```sh
askr schema
```

Reads your **live database** and writes Pascal that names every column with
its real type.

```
  app/Schema/App.Schema.Customers.pas
  app/Schema/App.Schema.Manifest.pas

2 file(s), 2 changed.
```

```pascal
uses App.Schema.Customers;

TQuery<TCustomer>.New
  .Where(Customers.Balance, GT, 150)
  .OrderBy(Customers.Email, Desc)
```

`Customers.Balance` is a `TColCurrency` because the column is
`NUMERIC(12,2)`. `Where(Customers.Balance, GT, 'abc')` does not compile, and
neither does a misspelled column name.

## Why it reads the database

Not the migrations. A column added by hand, or a migration that failed
halfway, must not become invisible. The generated code describes what is
actually there — which is also what makes it useful as a drift check.

## What is generated

**One unit per table**, carrying that table's own fingerprint. **One
manifest** carrying the fingerprint of the whole schema.

The split matters: if every file carried the whole schema's fingerprint, a
change in one table would make all the files look changed, and the
operational diff would be useless.

The manifest answers questions about the schema at runtime:

```pascal
ColumnExists('customers', 'email');
IsIndexed('customers', 'created_at');
PascalTypeOf('customers', 'balance');     { 'Currency' }
SchemaAvtrykk;                            { the fingerprint }
```

## Type mapping

| SQL | Pascal | Column type |
|---|---|---|
| `bigint`, `integer`, `smallint`, `serial`, `tinyint(4)` | `Int64` | `TColInt64` |
| `varchar`, `text`, `uuid`, `jsonb`, `bytea` | `string` | `TColStr` |
| `numeric(p,s)` with s ≤ 4, `money` | `Currency` | `TColCurrency` |
| `numeric` with s > 4, `double`, `real`, `float` | `Double` | `TColFloat` |
| `boolean`, `tinyint(1)`, `bit(1)` | `Boolean` | `TColBool` |
| `timestamp*`, `datetime`, `date`, `time*` | `TDateTime` | `TColDateTime` |

Two of those rows are where the bodies are buried:

**`tinyint(1)` is boolean, `tinyint(4)` is an integer.** MySQL and SQLite
have no boolean type; the width is the convention that makes it one. The
introspector reads `column_type`, not `data_type`, precisely because that is
the one that keeps the width.

**`Currency` has four decimals.** More than that would have to go to
floating point, and it is better to say so than to lose precision silently.

## Naming

`snake_case` in SQL, `PascalCase` in Pascal. `customer_id` becomes
`CustomerId`; the SQL name is preserved in the generated constant, so the
query is correct and the Pascal reads like Pascal.

## Writing files

`WriteSources` **does not touch files that are unchanged**, so timestamps
and incremental compilation are not disturbed. `askr schema` reports how
many were actually written:

```
2 file(s), 0 changed.
```

## Drift

`CheckDrift` compares generated source against what is on disk and returns
the names that differ. An empty list means they agree — a deployment check
that the schema the code was compiled against is the schema that is there.

## Generated code must compile without warnings

If you change the generator: write to a local variable and assign `Result`
at the end. FPC otherwise warns about an uninitialised result, both for
records with string fields and for dynamic arrays with `SetLength`.

And `uses` belongs immediately after `implementation`, not at the bottom.
That is easy to get wrong when you are building source code as text.

## The alternative that was measured and rejected

Reading the schema at **compile time**, on every build, was tried. It works
and the error messages are better — but it costs **70 ms against Postgres
with 61 tables**, against 53 ms of headroom in the dev loop. The variant
that fits caches the schema and re-reads only when it changed, and a cached
schema with typed output *is* this. See [Rún](run.md) for the full
accounting.
