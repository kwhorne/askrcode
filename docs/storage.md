# File storage

Where an app keeps the files people give it: a directory on this machine
in development, and S3 — or anything that speaks it — in production, where
the files have to outlive the server and be shared by every process. The
code that stores them does not change between the two.

```pascal
uses Askr.Storage;

{ app.lpr, at startup }
SetStorage(StorageFromConfig);

{ a handler }
Path := Storage.PutUpload('avatars', Req.Upload('avatar'));  // avatars/3f9c…e1.png
U.AvatarPath := Path;
U.Save;

{ later }
if Storage.Get(U.AvatarPath, Bytes) then ...
Link := Storage.TemporaryUrl(U.AvatarPath, 15 * 60);  // good for fifteen minutes
```

## The disk

Every disk is a `TStorageDisk`, and has the same seven things:

| | |
|---|---|
| `Put(Path, Data, ContentType)` | Stores the bytes, replacing what was there. The type follows the extension when it is left out. |
| `Get(Path, out Data)` | `False` when there is no such file. |
| `Exists(Path)` | |
| `Delete(Path)` | A file that is not there is not an error: it is gone either way. |
| `Url(Path)` | The address of a public file. |
| `TemporaryUrl(Path, Seconds)` | An address that works for that long, for a private file. |
| `PutUpload(Dir, File)` | An upload under `Dir`, with a random name; the path comes back. |

`PutUpload` never uses the name the client sent — that is text an attacker
writes. The name is random, the extension is the upload's sanitised one,
and the content type is what that extension says. The same rule as
[`StoreIn`](uploads.md), which writes to a directory; `PutUpload` writes to
whichever disk the app has.

Store the **path** in your table, not the URL. The URL depends on the disk
and, for a temporary one, on the time.

## Configuration

```toml
[storage]
disk = "local"          # or "s3"
root = "storage/app"    # local: the directory
url = "/storage"        # local: where Url() points
```

```sh
# .env, for S3
STORAGE_DISK=s3
S3_BUCKET=shop-uploads
S3_REGION=eu-north-1
S3_KEY=AKIA…
S3_SECRET=…
S3_ENDPOINT=            # empty for AWS; https://… for R2, Spaces, MinIO
```

The secret goes in the environment, like every other secret — never in
`askr.toml`, which is in git. `StorageFromConfig` raises on a disk name it
does not know: a typo in production would otherwise put the files on a
disk that is gone at the next deploy. `Describe` says which disk is in
use, and never the secret.

You can build a disk yourself instead — `TLocalDisk.Create(Root, Url)` or
`TS3Disk.Create(Bucket, Region, Key, Secret, Endpoint)` — and hand it to
`SetStorage`, or keep several.

## Paths are checked, never trusted

A path is segments separated by `/`, with no leading `/`, and no segment
empty, `.` or `..`, or holding a backslash or a NUL. Anything else raises
`EStorageError` before a disk is touched. A path that came from a request
cannot climb out of the disk on either kind: `../../etc/passwd` is refused
by the local disk *and* by S3, where it would otherwise have been a key
with dots in it.

On the local disk, a file is written beside its final name and renamed
over it, so a reader never sees half a file.

## Private files

**On S3,** `TemporaryUrl` is a presigned URL: the browser fetches it from
S3 directly, with no key, until it expires. S3 takes a lifetime from a
second to a week. `Url` is the object's plain address, which only works
for a bucket or object that is public — S3's policy decides, not Askr.

**On the local disk,** it is a link signed with `APP_KEY` — the same
[signed links](auth.md#signed-links) email verification uses — to a route that has to be
there:

```pascal
UseStoredFiles(R, Storage as TLocalDisk, '/files');
```

`UseStoredFiles` checks the signature and the expiry before it reads a
byte: a forged link is `403`, an expired one `410`, and a file that is
gone `404`. The answer carries `Cache-Control: private, no-store`, because
the link is the permission and a shared cache must not keep it.

Put it after the static files and before sessions, like them: the link
needs nothing else.

## S3, without an SDK

`TS3Disk` signs its requests with **Signature V4**, in Pascal, over
Askr's own [HTTP client](http-client.md) and crypto. A bucket is in the
host name for AWS (`shop-uploads.s3.eu-north-1.amazonaws.com`) and in the
path for an endpoint (`https://…/shop-uploads/key`), which is what
S3-compatible servers take.

How much of that is known to work:

- **The signatures are botocore's.** `tests/vectors/sigv4.txt` is made by
  `tools/vectors/sigv4.py` with botocore — AWS's own signer — for headers
  and presigned URLs, keys with spaces, `+`, `=`, `&` and letters outside
  ASCII in them. The suite holds Askr's signer to every one.
- **An S3 server takes them.** `./askr storage:check` runs
  [versitygw](https://github.com/versity/versitygw), an S3 gateway that
  checks every signature it is sent, and stores, reads, looks for and
  deletes against it — the same awkward keys, every byte value, and a
  presigned URL that opens the file with no key while one with its expiry
  changed does not. A wrong secret is refused, and the error does not
  carry it.
- **No request has gone to AWS itself from here.** The signer agrees with
  AWS's own, and a server that checks signatures accepts it. That is not
  the same as AWS having done so, and it is said until it has.

An error from S3 becomes an `EStorageError` with the status and S3's error
code — `S3 would not store avatars/x.png: 403 SignatureDoesNotMatch` — and
nothing from the request's credentials.

## Testing

A test uses a `TLocalDisk` on a temporary directory:

```pascal
SetStorage(TLocalDisk.Create(TempDir + '/storage'));
```

It is the same interface, and it runs without a network.

## What is not here

**Listing.** There is no `Files(Dir)`. An app that needs to know what it
stored keeps the paths in a table, which it needs anyway to know whose
they are.

**Large files.** A file is read and written whole, in memory. That is
fine for what fits in a request — [`MaxBodyBytes`](uploads.md) is 8 MB
unless raised — and wrong for video. S3's multipart upload, and streaming
to and from a disk, are not here.

**Retries.** A request S3 refuses raises. Put the work in the
[queue](queue.md) if it should be tried again.

**Other stores.** Google Cloud Storage and Azure Blob have their own
APIs. Most S3-compatible stores — R2, Spaces, MinIO, Backblaze B2 — take
the S3 disk with an endpoint; only versitygw has been run from here.
