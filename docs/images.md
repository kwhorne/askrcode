# Images

Two units, and the split between them is the important part.

`Askr.Image` tells you what a file **is** without decoding a pixel. No
dependency, always available, and it is mostly a security unit.

`Askr.Image.Vips` does the work that needs pixels — resizing, cropping,
format conversion — by loading libvips with `dlopen`, the same way TLS
loads OpenSSL. The binary starts without it, and an app that never
resizes an image pays nothing.

## What a file claims, and what it is

```pascal
uses Askr.Image;

var
  F: PUploadedFile;
begin
  F := Req.Files.FileAt(0);

  if SniffFormat(F^.Content) = ifUnknown then
    Exit(BadRequest('That is not an image.'));

  if not ExtensionMatches(F^.SafeName, F^.Content) then
    Exit(BadRequest('The file does not match its extension.'));
end;
```

**This is the check that matters.** The filename comes from an attacker
and means nothing. So does `Content-Type`: a browser sends whatever the
form said, and a `.exe` can announce itself as `image/png`.

A file named `avatar.jpg` that is actually HTML is a stored XSS: serve it
back with the wrong `Content-Type` and it runs in the reader's browser,
under your domain, with your cookies. `SniffFormat` reads the magic bytes
instead.

## Dimensions without decoding

```pascal
Inf := ReadImageInfo(F^.Content);
if Inf.Ok and ((Inf.Width > 6000) or (Inf.Height > 6000)) then
  Exit(BadRequest('That image is too large.'));
if Inf.Animated then
  Exit(BadRequest('Animated images are not allowed here.'));
```

`ReadImageInfo` parses the header only — JPEG's SOF marker, PNG's IHDR,
GIF's screen descriptor, WebP's RIFF chunks. It never allocates a
bitmap, so a 40-megapixel upload costs the same as a thumbnail.

That matters: **decoding an image is how you get a decompression bomb.**
A 100 kB PNG can expand to gigabytes. Checking the dimensions first is
how you refuse it before that happens.

`Animated` is set for animated GIF and WebP, and for APNG. Worth knowing
because an "avatar" that moves is rarely what anyone wanted.

## EXIF is a privacy leak

```pascal
Orient := JpegOrientation(Data);       { read it BEFORE stripping }
if StripJpegMetadata(Data, Clean) then
  Store(Clean);
```

A photo taken on a phone usually carries GPS coordinates. Someone
uploading a profile picture is uploading their home address unless
something removes it.

`StripJpegMetadata` rewrites the JPEG's segments and drops APP1 through
APP15 and COM — where EXIF, XMP and IPTC live. It does not touch the
pixels, so it is fast and lossless. The ICC colour profile in APP2 is
kept: without it, colours can shift visibly, and that is not metadata in
the same sense.

**Read the orientation first.** Phones often store the photo sideways and
set an EXIF flag saying which way up it goes. Strip the metadata without
rotating and the picture is sideways forever.

`ResizeImage` strips metadata too, through libvips, so you do not need
both.

## Resizing

```pascal
uses Askr.Image, Askr.Image.Vips;

Thumb := ResizeImage(Data, 320, 0, ifJpeg, 80);          { width, ratio kept }
Avatar := ResizeImage(Data, 200, 200, ifJpeg, 85, fmCover);
Webp := ConvertImage(Data, ifWebp, 75);
```

A zero for width or height means "work it out from the other one".
`fmInside` fits the image in the box; `fmCover` fills the box and crops
what sticks out — which is what you want for avatars and cards, where
every tile has to be the same size.

**It never scales up.** An image already smaller than the box comes back
at its own size. Enlarging a thumbnail gives you a blurry picture in a
bigger file, and it is never what anyone asked for.

### When libvips is not there

```pascal
if not VipsAvailable then
  LogInfo('image resizing unavailable', ['why', VipsError]);
```

`VipsError` names the package to install for Debian, macOS and Alpine
rather than listing the paths it looked in. Calling `ResizeImage`
without it raises `EVipsError` with that same message.

```sh
apt-get install libvips42     # Debian, Ubuntu
brew install vips             # macOS
apk add vips                  # Alpine
```

## Why this is not pure Pascal, when the crypto is

The crypto in Askr is pure Pascal because **every app with users needs
password hashing**. A framework that puts that on libcrypto cannot call
the dependency optional.

Image processing is not universal. So it follows the same rule as TLS,
Postgres, MySQL and SQLite: loaded with `dlopen` at first use, absent
until you need it, and the binary starts either way.

Writing a JPEG and WebP decoder in Pascal would be several thousand
lines and still slower and less correct than libvips.

## What is not here

**No video.** Transcoding does not belong in a web process: it is
minutes of CPU on a request that has to answer in milliseconds. The
right shape is a job on the [durable queue](queue.md) that shells out to
`ffmpeg` — the same reason the scheduler pushes to the queue rather than
running anything itself. Askr gives you the queue; the `ffmpeg` line is
yours, because the flags depend on what you are making.

**No drawing, no filters, no watermarks.** libvips can do all of it, and
none of it is bound. Resize, crop and convert are what a web framework
actually needs; the rest is an image editor.

**SVG is recognised but never safe to serve from your own origin.** It
is XML, it can carry `<script>`, and a browser will run it. `SniffFormat`
returns `ifSvg` so you can refuse it deliberately. If you must accept
SVG, serve it from a separate domain, or as `Content-Disposition:
attachment`.

**No automatic rotation.** `JpegOrientation` gives you the flag; acting
on it is yours, because it is the one place where doing the obvious
thing silently is worse than asking.

**No image cache.** Resize once, store the result, serve it as a static
file. Doing it per request is a way to turn a CDN miss into a CPU
outage.
