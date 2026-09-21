{ Desktop tests for the webview.

  This is not a compile check. The window is opened for real, WebKitGTK
  fetches the page from the embedded server, and JavaScript on the page
  makes another call back. If both calls are registered, the whole chain
  worked: window, web engine, local HTTP server and router.

    ./askr desktop:linux

  Without GTK, or without a screen, the suite skips itself and says why.

  macOS and Windows skip: both open a window that has to be closed by hand
  (macOS has no AutoCloseMs), and the Windows shell has no machine to run
  on from here. See tools/probes/webview2_vtable.lpr for what actually is
  verified of the WebView2 binding. }
program askr_desktop_tests;

{$mode Delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, SyncObjs,
  Askr.Core.Text, Askr.Http.Types, Askr.Http.Request, Askr.Http.Response,
  Askr.Http.Router, Askr.Desktop;

var
  Passed: Integer = 0;
  Failed: Integer = 0;
  Lock_: TCriticalSection;
  MatchPage: Integer = 0;
  HitPing: Integer = 0;

procedure Ok(const What: string; Value_: Boolean);
begin
  if Value_ then
  begin
    Inc(Passed);
    WriteLn('  ok    ', What);
  end
  else
  begin
    Inc(Failed);
    WriteLn('  FEIL  ', What);
  end;
end;

function Side(Req: TRequest): TResponse;
begin
  Lock_.Acquire;
  try
    Inc(MatchPage);
  finally
    Lock_.Release;
  end;
  { The script proves the web engine is running, not merely that
    something fetched HTML. }
  Result := RespondHtml(
    '<!doctype html><html><head><meta charset="utf-8">' +
    '<title>Askr desktop</title></head><body>' +
    '<h1>Askr</h1>' +
    '<script>fetch("/ping?from=webview");</script>' +
    '</body></html>');
end;

function Ping(Req: TRequest): TResponse;
begin
  Lock_.Acquire;
  try
    Inc(HitPing);
  finally
    Lock_.Release;
  end;
  Result := RespondText('pong', 200);
end;

procedure Routes(R: TRouter);
begin
  R.Get('/', Side);
  R.Get('/ping', Ping);
end;

var
  Err: string;
  HasDisplay: Boolean;
begin
  Lock_ := TCriticalSection.Create;
  WriteLn('askr — desktop');

{$IFDEF WINDOWS}
  WriteLn;
  WriteLn('SKIPPED: nobody has run the Windows shell yet.');
  WriteLn('  The binding is written, but never started on a Windows machine.');
  Halt(0);
{$ENDIF}
{$IFDEF DARWIN}
  { On macOS Run opens an NSWindow that blocks until somebody closes it,
    and AutoCloseMs does not exist there. A suite that waits for a click is
    no suite. The macOS shell is verified by hand with
    examples/desktop. }
  WriteLn;
  WriteLn('SKIPPED: this suite tests the Linux webview.');
  WriteLn('  The macOS shell opens a window that has to be closed by hand —');
  WriteLn('  run examples/desktop to see it.');
  Halt(0);
{$ENDIF}

  if not WebviewAvailable then
  begin
    WriteLn;
    WriteLn('SKIPPED: WebKitGTK is not here.');
    WriteLn('  ', WebviewError);
    Halt(0);
  end;
  WriteLn('backend: ', WebviewBackend);
  Ok('the backend name mentions WebKitGTK',
    Pos('WebKitGTK', WebviewBackend) > 0);
  Ok('nothing to report when the library is there', WebviewError = '');

  HasDisplay := (GetEnvironmentVariable('DISPLAY') <> '') or
               (GetEnvironmentVariable('WAYLAND_DISPLAY') <> '');

  DesktopApp.RegisterRoutes(Routes);
  DesktopApp.Window('Askr desktop', 900, 600);

  if not HasDisplay then
  begin
    { Without a screen GTK is to give an explanation, not kill the
      process. gtk_init would have called exit() here; gtk_init_check does
      not. }
    WriteLn;
    WriteLn('— without a screen');
    Err := '';
    try
      DesktopApp.Run;
    except
      on E: EDesktopError do Err := E.Message;
    end;
    { That we are here at all is the point: gtk_init would have called
      exit(). But it is the next two that can actually fail — an assertion
      that cannot fail is no assertion. }
    Ok('the error mentions DISPLAY', Pos('DISPLAY', Err) > 0);
    { The framework's message is English now. This assertion was still
      looking for 'webtjeneste' and would have failed the moment anyone
      ran the suite without a display — which nobody had, because it skips
      on macOS and wherever GTK is missing. }
    Ok('and says the app is still serving over HTTP',
      Pos('serving over HTTP', Err) > 0);
  end
  else
  begin
    WriteLn;
    WriteLn('— with a screen');
    { The window closes itself. A suite cannot wait for a click. }
    DesktopApp.AutoCloseMs := 6000;
    DesktopApp.Run;

    Ok('the server got a port', DesktopApp.Port > 0);
    WriteLn('        hits: / = ', MatchPage, ', /ping = ', HitPing);
    Ok('the webview fetched the page', MatchPage > 0);
    Ok('and JavaScript on the page called back', HitPing > 0);
  end;

  WriteLn;
  WriteLn('— ', Passed, ' passed, ', Failed, ' failed');
  Lock_.Free;
  if Failed > 0 then
    Halt(1);
end.
