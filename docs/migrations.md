# Migrations

Migrations are Pascal units compiled into your binary. `askr migrate` asks
the binary to run them — the tool cannot read them.

```sh
askr make migration AddSlugToPosts
askr build
askr migrate
```

## A migration

```pascal
unit App.Migrations.AddSlugToPosts;

{$mode Delphi}{$H+}

interface

uses
  Askr.Norn.Schema, Askr.Norn.Migration;

type
  TAddSlugToPosts = class(TMigration)
  public
    class function Version: string; override;
    procedure Up(S: TSchemaBuilder); override;
    procedure Down(S: TSchemaBuilder); override;
  end;

implementation

class function TAddSlugToPosts.Version: string;
begin
  Result := '20260921090300';
end;

procedure TAddSlugToPosts.Up(S: TSchemaBuilder);
begin
  S.Alter('posts').Text('slug', 120).Nullable;
end;

procedure TAddSlugToPosts.Down(S: TSchemaBuilder);
begin
  S.Alter('posts').DropColumn('slug');
end;

initialization
  RegisterMigration(TAddSlugToPosts);

end.
```

Three things about that file are not decoration:

**The filename must be the unit name.** FPC finds no unit called anything
other than its file, so the timestamp cannot go in the filename. Ordering
comes from `Version`.

**The `initialization` section registers it** — the same pattern the
database drivers use.

**A unit nothing references is never linked in**, so `askr make` also
regenerates `database/App.Migrations.pas`, an index unit that exists only
to `uses` them. It is read from the directory, not from a list, so a file
added by hand or deleted cannot become invisible. Do not edit it.

`database` must be in `units` in `askr.toml`, or none of it is on the
search path at all.

## The schema builder

Dialect-neutral DDL. The same `Up` runs against Postgres, MySQL and SQLite.

```pascal
with S.Create('customers') do
begin
  Id;                                    { auto primary key }
  Text('name', 120);
  Text('email', 255).Unique;
  Money('balance').Default(0);
  Bool('active').Default(True);
  ForeignKey('org_id', 'organisations');
  Timestamps;                            { created_at, updated_at }
  SoftDeletes;                           { nullable, indexed deleted_at }
  Index(['name']);
  UniqueIndex(['org_id', 'email']);
end;
```

| Column | Postgres | MySQL | SQLite |
|---|---|---|---|
| `Id` | `BIGSERIAL` | `BIGINT AUTO_INCREMENT` | `INTEGER` |
| `Text(n, len)` | `VARCHAR(len)` or `TEXT` | same | same |
| `Int`, `BigInt`, `SmallInt` | | | |
| `Bool` | `BOOLEAN` | `TINYINT(1)` | `TINYINT(1)` |
| `Money` | `NUMERIC(12,2)` | | |
| `Numeric(n, p, s)` | | | |
| `Float` | `DOUBLE PRECISION` | `DOUBLE` | `REAL` |
| `Timestamp` | `TIMESTAMPTZ` | `DATETIME` | `DATETIME` |
| `Date` | `DATE` | | |
| `Json` | `JSONB` | `JSON` | `TEXT` |
| `Uuid` | `UUID` | `CHAR(36)` | `TEXT` |
| `Bytes` | `BYTEA` | `BLOB` | `BLOB` |

Modifiers chain and return the column:

```pascal
Text('email', 255).Unique.Nullable;
Money('balance').Default(0);
Timestamp('at').DefaultRaw('CURRENT_TIMESTAMP');
BigInt('customer_id').References('customers', 'id', 'CASCADE');
```

> `Timestamps` emits `CURRENT_TIMESTAMP`, not `now()`. `now()` exists in
> Postgres and MySQL but not in SQLite.

Altering:

```pascal
S.Alter('posts').Text('slug', 120).Nullable;
S.Alter('posts').DropColumn('slug');
S.Drop('posts');
S.Rename('posts', 'articles');
S.Execute('CREATE EXTENSION IF NOT EXISTS pg_trgm');   { the escape hatch }
```

`S.Create(table)` overloads the constructor. It works because the signatures
differ, and it is the form the PRD writes.

## The migrator

```pascal
M := TMigrator.Create(Conn);
try
  M.OnLog := @Log;
  M.Up;             { all pending; Up(N) for the next N }
  M.Down(1);        { roll back the last }
  M.Status;         { registered and applied, merged and sorted }
  M.PendingCount;
finally
  M.Free;
end;
```

You rarely call this directly — `askr migrate` and its variants do.

Migrations run **in a transaction where the dialect allows it**. MySQL
commits implicitly on DDL, so the migrator says so rather than pretending
otherwise.

**Two migrations with one version are refused before anything runs.** The
version is what a migration is recorded under, and that key is unique. A
second migration with the same one used to have its DDL run and then fail
at the record — the table made, nothing to say so, and on MySQL nothing to
roll back. The migrator now names both and stops while nothing has
happened.

`askr make` does not produce one any more. A version used to be the time
to the second, and two `make` commands in the same second got the same
one. It is now the time or one past the highest version already in
`database/`, whichever is later: an ordering key, which is all it was ever
used as.

## Status

```sh
askr migrate:status
```

```
Version            State      Title
20260920144652     applied    Create posts
20260921090300     pending    Add slug to posts
20260801120000     MISSING    Create legacy
```

**`MISSING`** means a migration ran against this database but its source
file is gone. That is a state you want surfaced rather than hidden.

## Rolling back

```sh
askr migrate:rollback            # the last one
askr migrate:rollback --step=3
askr migrate:reset               # everything
askr migrate:fresh --seed        # drop every table, migrate, seed
askr migrate:refresh --seed      # reset, migrate, seed
```

`Down` is yours to write. A migration without one is not reversible, and
`Reversible` reports that.

## Seeders

```sh
askr make seeder Posts
askr build
askr db:seed
askr db:seed Posts               # just one
```

```pascal
procedure TPosts.Run(Conn: TDbConnection);
var
  A: TArena;
begin
  A := TArena.Create(64 * 1024);
  try
    Conn.Exec(A, 'INSERT INTO posts (title) VALUES (''First'')');
  finally
    A.Free;
  end;
end;
```

To use models inside a seeder, set the ambient arena and connection first
with `UseArena` and `UseDb`.

## Why codegen reads the database, not the migrations

`askr schema` introspects the **live database**. That is deliberate: a
column added by hand, or a migration that failed halfway, must not become
invisible. See [Typed columns](schema.md).

## Dialect notes

**InnoDB silently ignores `REFERENCES` on a column.** The builder emits
table-level `FOREIGN KEY` for MySQL, both in `CREATE TABLE` and as a
separate `ALTER TABLE ... ADD` after `ADD COLUMN`. The table is created
either way, so the mistake only appears when something deletes a row that is
pointed at.

**SQLite declares `DATETIME`, not `TEXT`.** SQLite stores text regardless,
but the declared type is what introspection reads — with `TEXT` it could not
tell a date from any other string.
