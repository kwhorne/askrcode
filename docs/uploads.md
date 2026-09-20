# File uploads

```pascal
function TFiles.Receive(Req: TRequest): TResponse;
var
  F: TUploadedFile;
  Path: string;
begin
  if not Req.Multipart.Ok then
    Exit(RespondText(Req.Multipart.ErrorText, 400));

  F := Req.Upload('attachment');
  if F.IsEmpty then
    Exit(RespondText('No file', 422));

  Path := F.StoreIn('storage/uploads');
  Result := RespondText(Format('%d bytes -> %s', [F.Size, Path]));
end;
```

`Req.Form` reads both urlencoded and multipart, so the other fields in the
form — and the CSRF token — work as before. `Req.Uploads(name)` returns all
the files under one name, as from `<input type="file" multiple>`.

## No copies

The parser copies nothing. The body already sits contiguous in the worker's
read buffer, and every part is a `TStr` slice into that same buffer. A
five-megabyte upload costs five megabytes **once**, in the buffer that had
to read them anyway.

The content is valid for the duration of the request and **not longer**. To
keep it, store it or copy it.

## The file

| | |
|---|---|
| `IsEmpty` | No file was chosen |
| `Size` | Bytes |
| `Content` | `TStr` into the read buffer |
| `ClientName` | Exactly what the client sent — **do not use as a filename** |
| `ContentType` | The client's claim, not a measurement |
| `SafeName` | The client name, cleaned |
| `Extension` | From `SafeName`, lowercase, with the dot |
| `SaveAs(Path)` | Writes exactly there |
| `StoreIn(Dir)` | Random name, sanitised extension; returns the path |

`ContentType` is a claim, not a measurement: a `.exe` can be announced as
`image/png`. If the type must be trusted, inspect the content.

## The client's filename is not to be trusted

It is text an attacker writes, and the classic mistake is to join it
straight onto a directory: `../../etc/passwd`, or a file called `.bashrc`.

**`StoreIn` does not use it at all.** Random name, sanitised extension. The
original stays in `ClientName` if you want to store it beside the file.

```pascal
Path := F.StoreIn('storage/uploads');
{ storage/uploads/6a7c38c81173adecf67324f2a31d7609.bin }
```

Verified with a real curl upload of `../../evil name.BIN`: it landed in the
directory asked for, under a random name, with the sanitised extension.

`SaveAs` writes exactly where you say. **That path is your responsibility** —
never assemble one from `ClientName`.

```pascal
SanitizeFileName('../../etc/passwd');       { 'passwd' }
SanitizeFileName('..\..\cmd.exe');          { 'cmd.exe' }
SanitizeFileName('.bashrc');                { 'bashrc' }
SanitizeFileName('');                       { 'upload' }
```

It strips directory components (`/`, `\` and `:`), leading dots, and
anything that is not `[A-Za-z0-9._-]`.

## The ceiling

**`MaxBodyBytes`, 8 MB by default**, set in `TServerOptions`. The whole
upload must fit in memory at once.

That is enough for attachments, profile pictures and CSV imports, and not
enough for video. Accepting something that does not fit in memory means
streaming the body to disk while it is read, and that is a different shape
from "the body is one slice" — it would have to change in `TWorker`, not in
the parser.

There are also limits on the number of parts (512) and the size of a part's
headers, against a body that is small but expensive.

## Errors

```pascal
if not Req.Multipart.Ok then
  Exit(RespondText(Req.Multipart.ErrorText, 400));
```

| | |
|---|---|
| `mpNoBoundary` | The Content-Type has no `boundary=` |
| `mpMalformed` | The boundaries are not where they should be |
| `mpTooManyParts` | |

A truncated body is **rejected**, not accepted in part. Taking what arrived
would give half a file that looks whole.

## For the curious

The CRLF before a boundary belongs to the delimiter, not to the content.
Get that wrong and every file gains two bytes at the end — which shows up
when somebody cannot open a zip.
