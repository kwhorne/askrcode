# Desktop

The same app in a native window. The HTTP server runs on localhost and a
webview points at it — one codebase, two shells.

```pascal
uses Askr.Desktop;

DesktopApp.UseDatabase('sqlite:shop.db');
DesktopApp.RegisterRoutes(@Routes);
DesktopApp.Window('Shop', 1100, 780);
DesktopApp.Run;
```

```sh
askr build --target desktop
```

> The object is called **`DesktopApp`, not `App`**. `App.` is the namespace
> your code lives in, and the compiler reads `App.UseDatabase` as a unit
> qualification.

| | |
|---|---|
| macOS | WKWebView |
| Linux | WebKitGTK (4.0 or 4.1) |
| Windows | **written, never run — see below** |

```pascal
WebviewAvailable;      { False if the libraries are missing }
WebviewBackend;        { which one }
WebviewError;          { why not, with the packages to install }
```

Everything is loaded with `dlopen`. The unit compiles on a machine without
GTK, and a plain web service does not inherit the dependency.

## Windows is parked

The WebView2 shell is **written and type-checked but has never been started
on a Windows machine.** It is not considered finished until someone has, and
it is the only place in Askr where that is true. Do not build further on it
meanwhile — the next step there is a run, not more code.

`tools/probes/webview2_vtable.lpr` runs in `./askr test` precisely so the
parked code keeps compiling. Parked code that is not built rots.

An attempt to build a win64 cross-compiler from Debian's FPC sources
stranded: `crossall` is not a target, and `fpcmake` does not generate
`rtl/Makefile` there.

## Things that bite

**`SetExceptionMask` must be set before the first Cocoa *and* GTK call.**
Free Pascal enables floating-point exceptions; Cocoa, CoreGraphics, Cairo,
GLib and WebKit all compute with NaN routinely and trigger them. Without the
mask the process dies with `EInvalidOp` as the first window is created, and
the stack trace points at libraries you did not write — it looks like a bug
in the web engine rather than a choice in our own runtime. Not optional, on
any platform.

**Use `gtk_init_check`, never `gtk_init`.** `gtk_init` calls `exit()` when
there is no display, and the process vanishes without a word in the middle
of `DesktopApp.Run`. `gtk_init_check` returns FALSE, and then we can say
what is wrong.

**`g_signal_connect` is a macro in C.** From Pascal, bind
`g_signal_connect_data` directly. Without the `destroy` signal connected to
`gtk_main_quit`, the process hangs after the window is closed.

**`objc_msgSend` is variadic in C.** From Pascal it is declared several
times with different signatures against the same symbol — that is how the
ABI works, and it is the only thing that is safe on arm64.

**`NSRect` is four doubles and goes in SIMD registers** under AAPCS64. A
record of four `Double` hits correctly; do not change it.

**Diagnostics before `[NSApp run]` need `Flush(Output)`.** The loop below
never flushes the buffer.

**WebView2 vtables are not counted by hand.** The methods are declared as
Pascal interfaces in `WebView2.h` order, including ones we never call, and
the compiler lays out the vtable. Calling method 24 instead of 25 gives a
pointer that looks valid — the one mistake that does not announce itself.

## Testing

`AutoCloseMs` exists only for the tests, and only on Linux
(`g_timeout_add`). On macOS it would need an NSTimer with an Objective-C
class built at runtime — a lot of machinery for something no real app
should use. So `askr_desktop_tests` skips itself on macOS rather than
hanging on a window waiting for a click.

The GTK image (`tools/Dockerfile.gtk`) is separate: WebKitGTK pulls in a few
hundred megabytes, and `./askr test` should not pay for it. The suite skips
itself where the library is missing, and `./askr desktop:linux` runs the
real thing under Xvfb.
