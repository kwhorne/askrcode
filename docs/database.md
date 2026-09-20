# Databases

Three dialects, one interface: **Postgres, MySQL and SQLite**. Models, the
query builder, validation and eager loading are bit for bit the same code
against all three.

Every client library is loaded with `dlopen` at first use. The binary starts
on a machine that has none of them.

## Connecting

```pascal
uses Askr.Urd.Driver, Askr.Urd.Pg;     { the driver unit registers itself }

C := OpenDbConnection('postgresql://user:pass@host:5432/db');
```

| Scheme | Library | Example DSN |
|---|---|---|
| `postgresql:` / `postgres:` | `libpq` | `postgresql://askr:askr@127.0.0.1:5432/shop` |
| `mysql:` | `libmariadb3` | `mysql://askr:askr@127.0.0.1:3306/shop` |
| `sqlite:` | `libsqlite3` | `sqlite:shop.db`, `sqlite::memory:` |

Drivers register themselves in their `initialization` section, so putting
the unit in `uses` is all it takes. If the scheme has no driver, the error
says so and names the unit to add:

```
No driver for "sqlite". Registered: postgresql, mysql.
Add the matching Askr.Urd unit to your uses clause.
```

> The MySQL binding targets **MariaDB Connector/C**, not `libmysqlclient`.
> It is ABI-compatible, packaged as `libmariadb3` on Debian and
> `mariadb-connector-c` on Homebrew, and talks to both servers. Verified
> against MySQL 8.4 with `caching_sha2_password`.

## Running statements

```pascal
R := C.Exec(A, 'SELECT id, name FROM customers');
for I := 0 to R.RowCount - 1 do
  WriteLn(R.Value(I, 'name').ToString);
```

```pascal
R := C.ExecParams(A,
  'SELECT * FROM customers WHERE balance > $1 AND active = $2',
  [DbParam(A, Int64(100)), DbParam(A, True)]);
```

Parameters are always bound, never interpolated. The placeholder form
differs by dialect — `$1` in Postgres, `?` in MySQL and SQLite — so use
`AppendPlaceholder` when you build SQL yourself:

```pascal
B.Init(A, 128);
B.Append('SELECT * FROM ');
C.AppendIdentStr(B, 'customers');
B.Append(' WHERE id = ');
C.AppendPlaceholder(B, 1);
```

`AppendIdent` quotes an identifier the way the dialect wants, doubling any
embedded quote.

## Results

`TDbResult` owns nothing from the client library. Everything is copied into
the arena, and `PQclear` (or its equivalent) happens before `Exec` returns.

```pascal
R.RowCount;  R.FieldCount;  R.AffectedRows;
R.Value(Row, Col);      R.Value(Row, 'name');
R.IsNull(Row, Col);     R.AsInt64(Row, Col);
R.FieldName(Col);       R.IndexOfField('name');
R.IsEmpty;
```

`AffectedRows` is -1 where it does not apply.

## Insert and get the id back

```pascal
Id := C.InsertGetId(A, 'INSERT INTO customers (name) VALUES ($1)',
  [DbParam(A, 'Ada')], 'id');
```

One driver operation, not something the query builder assembles, because
`RETURNING` does not exist in MySQL. Pass the INSERT without `RETURNING`;
the driver adds whatever the dialect needs. Returns 0 when the table has no
generated key.

## Transactions

```pascal
C.StartTransaction;
try
  ...
  C.Commit;
except
  C.Rollback;
  raise;
end;
```

> **MySQL commits implicitly on DDL.** A transaction around a migration
> there gives false safety, and the migrator says so rather than pretending
> otherwise.

## Errors

```pascal
except
  on E: EDbError do
    if E.IsUniqueViolation then
      ...
end;
```

`EDbError` carries `SqlState`. The drivers normalise it: MySQL reports
`23000` for both unique and foreign-key violations, and errno is what tells
them apart (1062 against 1451/1452). The driver translates to **`23505`**
and **`23503`** so the rest of the data layer sees the same thing on every
dialect.

`EDbUnavailable` means the server could not be reached, as opposed to
rejecting the statement.

## Connection pooling

A connection is not thread-safe and lives on the heap across requests — it
is never an arena object.

```pascal
Pool := TDbPool.Create(Dsn, 8);

C := Pool.Acquire;          { blocks until one is free, or times out }
try
  ...
finally
  Pool.Release(C);
end;
```

```pascal
C := Pool.Lease(Arena);     { returned automatically on Arena.Reset }
```

`Lease` is what a request handler wants: the connection goes back when the
arena resets, so there is no `finally` to forget.

| | |
|---|---|
| `IdleCount`, `LiveCount` | Right now |
| `AcquiredTotal`, `CreatedTotal`, `DiscardedTotal` | Counters |
| `Warmup` | Open the connections up front |

A connection that fails a liveness check is discarded rather than handed
out. Sizing: the pool must be at least as large as the number of threads
that can want a connection at once, including queue workers.

## Prepared statements

Every driver caches prepared statements **per connection**. A prepared
statement is the server's state for one session; a shared cache would point
at handles in the wrong session.

Measured effect per statement, warm: SQLite 6–8 ms → 1–2 ms, Postgres
50–52 ms → 24–33 ms, MySQL 142–152 ms → 109–115 ms.

Things worth knowing if you touch that code:

**`PQprepare` is not the SQL statement `PREPARE`.** It sends `Parse` in the
extended protocol, and such statements belong to the session, not the
transaction — they survive a rollback. SQL `PREPARE` does not. The cache
does not need rebuilding to "handle" transactions.

**The cache can still go stale**, for instance if something runs
`DEALLOCATE ALL`. The server answers `26000`, and the driver re-prepares and
retries. That path has its own test which runs `DEALLOCATE ALL` behind the
cache's back.

**Statement names (`askr_N`) are never reused**, so a statement the driver
lost track of cannot collide with a new one.

**SQLite needs both `sqlite3_reset` and `sqlite3_clear_bindings` on reuse.**
Without reset, a fully stepped SELECT holds its read lock; without
clear_bindings, values from the previous run can linger.

**An uncached statement is owned by the call and must be closed.** With
`CacheLimit := 0` the MySQL driver once leaked one statement per query, on
both the client and the server, because only the cached path closed
anything.

The driver's own counters are not proof. `pg_prepared_statements`,
`SHOW GLOBAL STATUS LIKE 'Prepared_stmt_count'` and
`TSqliteConnection.OpenStatements` are the source's own view — and it was
the MySQL one that revealed the leak.

## Dialect differences worth knowing

| | Postgres | MySQL | SQLite |
|---|---|---|---|
| Placeholder | `$1` | `?` | `?` |
| `RETURNING` | yes | no | yes |
| `SKIP LOCKED` | yes | 8.0+ | no (single writer) |
| DDL in a transaction | yes | implicit commit | yes |
| Boolean | `BOOLEAN` | `TINYINT(1)` | `TINYINT(1)` |
| Timestamp | `TIMESTAMPTZ` | `DATETIME` | `DATETIME` |

**SQLite has no date type and stores text either way.** But the *declared*
type is what introspection reads, so Askr declares `DATETIME` rather than
`TEXT` — otherwise `askr schema` would type `created_at` as `string` against
SQLite and `TDateTime` against Postgres, from the same migration.

**MySQL's charset is `utf8mb4`.** MySQL's "utf8" is not UTF-8.

**`CLIENT_FOUND_ROWS` is on.** Without it an update that changes nothing
reports 0 rows, and calling code concludes the row is gone.

**InnoDB silently ignores `REFERENCES` on a column.** The schema builder
emits table-level `FOREIGN KEY` for MySQL, in `CREATE TABLE` and as a
separate `ALTER TABLE ... ADD` after `ADD COLUMN`. The table is created
either way, so the mistake only shows up when something deletes a row that
is pointed at.

**SQLite needs `PRAGMA foreign_keys = ON`** to enforce them at all. WAL and
`busy_timeout` are set on connect; without them a pool with several workers
gets `SQLITE_BUSY` instead of waiting.

## Money

Use `Currency`, not a float.

> **`Currency(I) * <integer literal>` gives different answers on 3.2.2 and
> 3.3.1.** With `I = 7`, `Currency(I) * 100` is **700.00 on 3.2.2 and 0.07
> on trunk**. This is money, and it is silent: no warning, no error. The
> forms that agree on both — and the ones the framework uses — are
> `Currency(I * 100)`, `Currency(I) * 100.0`, and assigning to a `Currency`
> variable first. Addition and division are unaffected. A premise test holds
> this down.
