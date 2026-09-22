# Lists and pagination

A list endpoint answers three questions at once: what the rows are, where
in the set they came from, and how to ask for the next lot.

Sorting, searching and paging happen **in the database**. A grid that
fetches a hundred thousand rows to sort them in JavaScript is the wrong
answer when the database is already there, already has the indexes, and is
faster than the network.

`Askr.Urd.Grid` is that half, and it has two ways out: a prop for the
[data grid component](lauf.md), and the envelope below for an API caller.
The reading of the request, the allowlist, the cap and the count are the
same either way.

## Reading the request

```pascal
G.Read(Req)
 .Sortable('name', Customers.Name)
 .Sortable('balance', Customers.Balance)
 .Searchable([Customers.Name, Customers.Email])
 .DefaultSort('name')
 .PerPage(25, 200);
```

`Read` takes `page`, `per`, `sort`, `dir` and `q` off the query string and
nothing else.

**`Sortable` is an allowlist, and not one somebody remembered to write.**
`TQuery.OrderBy` takes a typed column, not a string, so a key that was
never registered has nothing to sort by — `'ORDER BY ' + parameter` cannot
be written here at all. An unknown key falls back to the default in
silence, because an old bookmarked URL should not bring a page down.

`Searchable` becomes one
[`WhereAnyLike`](queries.md#searching-several-columns-at-once) over the
columns you list: `OR` between them, in a parenthesis, so a `Where` you
added yourself still applies. Nothing at all when the box is empty.

`PerPage(N, Max)` sets the default and the cap. Without the cap, `per=1000000`
is a way of asking the database for the whole table.

What the client asked for is kept apart from the default until the page is
fetched, so calling `Read` and `PerPage` in either order means the same
thing. It did not, once, and that is a trap worth not having.

## The envelope

A list endpoint answers with three things: the rows, where in the set
they came from, and how to ask for the next lot.

```pascal
function TCustomerCtl.Index(Req: TRequest): TResponse;
var
  G: TGrid<TCustomer>;
begin
  G := TGrid<TCustomer>.New;
  G.Read(Req)
   .Sortable('name', Customers.Name)
   .Sortable('balance', Customers.Balance)
   .Searchable([Customers.Name, Customers.Email])
   .DefaultSort('name')
   .PerPage(25, 200);

  Result := G.ListResponse(G.Rows(TQuery<TCustomer>.New));
end;
```

```json
{
  "data": [ { "id": 1, "name": "Ada", "balance": 500.0000 } ],
  "meta": {
    "page": 1, "per": 25, "total": 137, "pages": 6,
    "sort": "name", "dir": "asc", "q": ""
  },
  "links": {
    "prev": null,
    "next": "/customers?sort=name&status=open&page=2"
  }
}
```

`GET /customers?sort=balance&dir=desc&per=50&q=ada&page=2` is read by
`Read`. This is the same `TGrid` the [data grid](lauf.md) component uses
— sorting, searching and paging happen in the database either way, and
the only difference is how the result is written out. `WriteJson` gives
the component its prop; `ListResponse` gives an API caller the envelope
above, and `WriteListInto` writes it into a document of your own.

## data is an array

`data` is an array whatever happens: `[]` when nothing matched, never
`null` and never missing. A consumer of a list is going to iterate that
key, and `null` is the one value that turns an empty result into a
crash. "You did not ask for this" is said by leaving a key out, which is
already the rule for [a relation that was never loaded](inertia.md).

## total is counted, not guessed

`Rows` runs `SELECT count(*)` over the filtered set **before** it fetches
the page, with the search applied and the limit and offset ignored. Do it
the other way round and you count the rows on the page.

Building the payload without calling `Rows` raises rather than reporting
`"total": 0` for a list that has rows in it.

`pages` is at least 1, including for an empty result: a set with nothing
in it still has one page, and a client that loops `for p := 1 to pages`
should visit it.

## The links are relative, and keep your parameters

`links.next` is the whole query string this request came in with, with
only `page` replaced. A list usually carries more than sort and search —
`?status=open&assignee=me` is the application's — and a next link that
quietly dropped those would page through a different list than the caller
asked for.

They are relative on purpose. An absolute URL needs an origin, and the
only truthful source of one is `app.url` ([see why](../src/core/Askr.Core.Url.pas));
a list endpoint has no business requiring that to be configured, and the
caller just made the request, so it has the origin already.

`prev` and `next` are `null` at the ends, and both are `null` when the
grid was never given a request — there is no path to build one from, and
guessing at one would be worse than saying so.

## A page is a slice of an order

`Paginate` puts the primary key last in the `ORDER BY`, always. Where the
order does not decide between two rows the database may put them either
way round on each query — so page one shows a row that page two shows
again, and something else is never shown at all. See
[Queries](queries.md#ordering-limits-paging).

## What is not here

**There are no per-field filters.** `q` is free text over the columns you
named with `Searchable`. Per-field filters need an operator per type and a
way to express and/or, and that is a separate question about how much of a
query language a URL should carry. Add a `Where` of your own to the query
you hand `Rows` — a list over "my orders" is still a list.

**There is no cursor pagination.** `page` and `per` over a total order,
which is what `Paginate` guarantees. Cursors are the right answer for a
feed that grows while you read it, and the wrong shape for a `pages`
count, which is what a table with page numbers under it needs.

**Sorting on a boolean column does nothing.** `TQuery` has no `OrderBy`
for one, and inventing a translation for "true before false" is a guess
about what somebody meant.
