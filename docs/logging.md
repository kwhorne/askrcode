# Logging

```pascal
uses Askr.Core.Log;

ConfigureLogFromEnv;      { LOG_LEVEL, LOG_FORMAT, LOG_FILE }
```

```pascal
LogInfo('order placed', ['id', Order.Id, 'total', Order.Total]);
LogWarn('retrying', ['attempt', N]);
LogError('payment declined', ['customer', Id]);
LogDebug('cache miss', ['key', K]);
```

Fields are pairs: key, value, key, value. Values are anything
`array of const` accepts — integers, strings, booleans, floats.

## Two formats

```
2026-09-20T10:52:54.226Z INFO  request method=GET path=/ status=200 ms=0
```

```json
{"ts":"2026-09-20T10:52:55.633Z","level":"info","msg":"request","method":"GET","status":200}
```

Text in a terminal, JSON lines in production. The choice follows `APP_ENV`
when `LOG_FORMAT` is not set — **the only place in Askr where the
environment changes behaviour by itself**, and the reason is that the wrong
default is noticed immediately: either the terminal is full of JSON, or the
log collector is full of text it cannot parse.

**Numbers and booleans are unquoted in JSON.** `"ms":"12"` cannot be
aggregated.

> Beware `FloatToStr`: it follows the locale, and on a Norwegian machine the
> decimal separator is a comma, which makes the line invalid JSON. The log
> unit sets the separator explicitly. Same trap as `FormatFloat` in the
> welcome page.

## Levels

```pascal
SetLogLevel(llDebug);      { llDebug, llInfo, llWarn, llError, llNone }
LogLevel;
LogEnabled(llDebug);
```

`llNone` is not a level you log at — it is a ceiling nothing gets over.

`LogEnabled` is for skipping expensive formatting. `LogWrite` checks the
level itself, but the arguments have already been computed by the time it is
called:

```pascal
if LogEnabled(llDebug) then
  LogDebug(BuildExpensiveMessage);
```

`LOG_LEVEL` accepts `debug`, `info`, `warn`, `error`, `none`. A misspelling
says so on stderr rather than becoming silence.

## Destinations

```pascal
SetLogFile('storage/app.log');     { '' goes back to stderr }
SetLogFile('');
SetLogSink(@MyWriter);             { one formatted line at a time }
```

The file is opened for **append**, so a restart does not erase the previous
run's log. It is held open — opening and closing per line is one syscall too
many per request. Every line is flushed: without that the last lines sit in
the buffer when the process dies, and those are exactly the lines someone is
looking for.

A file that cannot be opened says so on stderr and carries on there. A log
that cannot be written must not take down the app.

## Exceptions

```pascal
except
  on E: Exception do
    LogException(E, 'while saving', ['id', Order.Id]);
end;
```

The class and the message become **their own fields**, not part of the
message text. In JSON that is the difference between being able to group by
error type and having to grep free text.

The stack trace is not included: it only exists with `-gl`, and half a trace
in a log is worse than none.

## The framework's own lines

Request logging and every unhandled exception from a handler go through the
same log.

```pascal
Opts.LogRequests := True;
```

```
2026-09-20T10:52:54.226Z INFO  request method=GET path=/ status=200 ms=0 arena=14640
```

**An unhandled exception is always logged**, regardless of `LogRequests`. It
is not a request line, it is a failure, and a 500 that leaves no trace is a
500 nobody can debug.

If you find `WriteLn(StdErr, ...)` anywhere in `src/`, it is probably in the
wrong place.

## Secrets

**The framework never logs a value from `.env`.** A log line ends up in a
system more people can read than the database. If your app logs a secret,
that is your app's choice — but nothing here does it for you.
