# Languages

What the framework says — a validation message, a field's name in it — can
be said in the reader's language. The words live in files next to
`askr.toml`:

```toml
# lang/nb.toml
[validation]
required = ":attribute må fylles ut"
min_length = ":attribute må ha minst :min tegn"

[validation.attributes]
email = "e-postadresse"
```

```pascal
LoadConfig;
LoadLang;          { lang/*.toml, next to askr.toml }
...
UseSessions(R);
UseLocales(R);     { after the sessions, which keep a visitor's choice }
```

`askr new` writes both lines, `app.locale = "en"` in `askr.toml`, and a
`lang/en.toml` that starts empty.

## Where a word comes from

A key is looked up in this order:

1. the request's locale — `lang/nb.toml`;
2. the fallback locale — `app.fallback_locale`, English unless set;
3. the English the framework is compiled with;
4. the key itself, so a word nobody wrote is seen rather than blank.

**The framework's English is compiled in, not copied into the app.** An app
with no `lang` directory says exactly what it said before there was one.
`lang/en.toml` holds only what the app says differently, and its own words.
A copy of every message there would be frozen the day the project was made,
and the first upgrade that changed a message would leave the two disagreeing
with nothing to say which is right.

## Which language a request gets

`UseLocales(R)` decides, in this order:

1. the visitor's choice, kept in the session under `locale`;
2. the best of `Accept-Language` there is a file for — `nb-NO` finds
   `nb.toml` when there is no `nb-NO.toml`, and `pt_br` finds `pt-BR.toml`;
3. `app.locale`.

A locale nobody wrote a file for is only chosen when it is `app.locale`:
English needs no file. The answer says what it used in `Content-Language`,
and adds `Vary: Accept-Language` when the header decided it, so a cache in
between does not hand one visitor's language to the next.

A "change language" link calls `SetLocale`:

```pascal
function TLangController.Choose(Req: TRequest): TResponse;
begin
  SetLocale(Req.Param('locale').ToString);
  Result := Redirect('/', 303);
end;
```

It keeps the choice in the session and refuses a locale there is no file for:
a choice nothing can answer in is not a choice.

Outside a request — a queued job, a console command — the locale is
`app.locale`. `UseLocale('nb')` sets it for the thread, and
`UseLocale('')` puts it back.

## Your own words

```toml
# lang/en.toml
[app]
welcome = "Welcome back, :name"
```

```pascal
Trans('app.welcome', ['name', U.Name])
```

The arguments are pairs. A placeholder is `:name`, and they are replaced
longest name first, so `:min` never takes the front off `:minimum`. One that
is not given is left in the text, where it is seen.

## The file

Plain TOML, the part of it a lang file needs: `[sections]`, `key = "value"`
and `# comments` on a line of their own. A value is in double quotes, and
`\"`, `\\`, `\n` and `\t` are its escapes. A line that is none of these is
reported with its number — at start-up in `LangProblems`, and by
`askr lang:check` — rather than skipped in silence.

## askr lang:check

```sh
askr lang:check
```

Every locale held against the base — `app.fallback_locale`, with the
framework's English under it — **both ways**:

- a key the base has and the locale lacks, with the English a reader of that
  language would see instead;
- a key the locale has and the base does not, which is almost always a typo
  and is never looked up;
- a `:placeholder` a translation uses that nothing passes, which would be
  shown as written.

It exits 1 when there is anything to fix, so it can stand in CI. It reads the
files and not the app, and answers whether or not the app builds.

## The framework's keys

| Key | English |
|---|---|
| `validation.required` | `:attribute is required` |
| `validation.min_length` | `:attribute must be at least :min characters` |
| `validation.max_length` | `:attribute can be at most :max characters` |
| `validation.email` | `:attribute is not a valid email address` |
| `validation.min` | `:attribute cannot be less than :min` |
| `validation.max` | `:attribute cannot be greater than :max` |
| `validation.between` | `:attribute must be between :min and :max` |
| `validation.one_of` | `:attribute has a value that is not allowed` |
| `validation.same_as` | `:attribute does not match :other` |
| `validation.unique` | `:attribute is already taken` |
| `validation.exists` | `:attribute does not match a row in :table` |
| `validation.ids_exist` | `:attribute contains :ids, which does not match a row in :table` |
| `validation.ids_list` | `:attribute must be a list of ids, and :value is not one` |

`:attribute` is `validation.attributes.<column>` when the locale has one, and
the column otherwise. The error is still keyed on the column — a form finds
its field by name, whatever the message says.

## Deploying

`lang/` goes with the binary, like `public/`. Without it every message is
English — not broken, but not what you wrote.

## What is not here

**Plurals.** `:count item(s)` is as far as it goes. Plural rules differ by
language in ways a key and a placeholder cannot carry — Polish has three
forms, Arabic six — and doing it properly is a library of its own.

**Translated exceptions.** The messages a developer reads — a missing
connection, a relation that does not exist — stay English. They go to a log
and to the person who can fix them, not to the reader of a form.

**Dates and numbers in the reader's format.** A value in a message is written
as the framework writes it everywhere else.
