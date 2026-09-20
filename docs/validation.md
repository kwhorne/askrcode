# Validation

Rules live on the model.

```pascal
procedure TCustomer.Rules(V: TValidator);
begin
  V.Field('Name').Required.MaxLen(120);
  V.Field('Email').Required.Email.UniqueIn('customers');
  V.Field('Balance').Min(0);
  V.Field('Age').Between(18, 120);
  V.Field('Status').OneOf(['draft', 'live', 'archived']);
  V.Field('PasswordConfirmation').SameAs('Password');
end;
```

```pascal
Req.FillInto(C);
if not C.Validate then
  Exit(BackWithErrors(C.Errors));
C.Save;
```

`Validate` returns False and leaves the errors in `C.Errors`.

## Rules

| | |
|---|---|
| `Required` | Present and not blank |
| `MinLen(n)`, `MaxLen(n)` | String length |
| `Min(v)`, `Max(v)`, `Between(lo, hi)` | Numeric, as `Currency` |
| `Email` | Shape, not deliverability |
| `OneOf([...])` | One of a set |
| `SameAs(prop)` | Equal to another field — password and confirmation |
| `UniqueIn(table[, column])` | No other row has this value |
| `Says(message)` | Overrides the message of the rule immediately before it |

Each returns the chain, so they compose:

```pascal
V.Field('Email').Required.Says('We need an email address.').Email;
```

They stop at the first failure per field: one error per field, not five.

`UniqueIn` uses the ambient connection and **skips the row itself** when the
model is already persisted — otherwise updating a record would always report
its own email as taken. The column defaults to the one the property maps to.

## Fields and columns

> **Errors are keyed on the column name; rules are written with the property
> name.**

```pascal
V.Field('CustomerId')          { the property }
C.Errors.Has('customer_id')    { the column }
```

That is deliberate. The frontend receives errors keyed the way the form
fields are named, which follows the column, while the rules read like the
Pascal they are written in.

## The errors

```pascal
C.Errors.Count;
C.Errors.IsEmpty;
C.Errors.Has('email');
C.Errors.First('email');        { first message, or empty }
C.Errors.Field(I);              { iterate }
C.Errors.Message(I);
C.Errors.WriteJson(W);          { field -> message, the shape Inertia wants }
```

Fields without errors are not listed at all. `TErrors` lives in the arena
and dies with the request.

Messages are English, because everything a user of the framework sees is:
`' is required'`, `'%s must be at least %d characters'`, and so on.

## Across a redirect

Validation errors must survive the redirect that follows a failed POST.
They travel as **session flash**:

```pascal
Result := BackWithErrors(C.Errors);
```

The session's flash is **two maps**: what can be read now, and what is being
written for the next request. One map would give either a flash that never
disappears or one that cannot be read. See [Sessions](sessions.md).

> Inertia's own flash is thread-local and applies to **the response being
> built now**. It does not survive a redirect — the two requests can land on
> different workers, and without sessions there is no shared storage. Render
> the page directly instead of redirecting to it.

## Why it lives in the model unit

`TValidator` is declared in `Askr.Urd.Model`, not in a unit of its own.
`TModel.Rules` needs `TValidator`, and `TValidator` needs `TModel`: circular
between units, and Pascal does not allow it. The merge is the price.
