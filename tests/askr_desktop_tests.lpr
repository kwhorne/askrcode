{ Desktop-tester for webviewen.

  Dette er ikke en kompileringssjekk. Vinduet åpnes på ordentlig, WebKitGTK
  henter siden fra den innebygde serveren, og JavaScript på siden gjør et
  nytt kall tilbake. Blir begge kallene registrert, har hele kjeden virket:
  vindu, nettmotor, lokal HTTP-server og ruter.

    ./askr desktop:linux

  Uten GTK eller uten skjerm hopper suiten over seg selv og sier hvorfor.

  macOS og Windows hopper over: begge åpner et vindu som må lukkes for hånd
  (macOS mangler AutoCloseMs), og Windows-skallet har ingen maskin å kjøre
  på herfra. Se tools/probes/webview2_vtable.lpr for det som faktisk er
  verifisert av WebView2-bindingen. }
program askr_desktop_tests;

{$mode Delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, SyncObjs,
  Askr.Core.Text, Askr.Http.Types, Askr.Http.Request, Askr.Http.Response,
  Askr.Http.Router, Askr.Desktop;

var
  Bestatt: Integer = 0;
  Feilet: Integer = 0;
  Laas: TCriticalSection;
  TreffSide: Integer = 0;
  TreffPing: Integer = 0;

procedure Ok(const Hva: string; Verdi: Boolean);
begin
  if Verdi then
  begin
    Inc(Bestatt);
    WriteLn('  ok    ', Hva);
  end
  else
  begin
    Inc(Feilet);
    WriteLn('  FEIL  ', Hva);
  end;
end;

function Side(Req: TRequest): TResponse;
begin
  Laas.Acquire;
  try
    Inc(TreffSide);
  finally
    Laas.Release;
  end;
  { Skriptet beviser at nettmotoren kjører, ikke bare at noe hentet HTML. }
  Result := RespondHtml(
    '<!doctype html><html><head><meta charset="utf-8">' +
    '<title>Askr desktop</title></head><body>' +
    '<h1>Askr</h1>' +
    '<script>fetch("/ping?fra=webview");</script>' +
    '</body></html>');
end;

function Ping(Req: TRequest): TResponse;
begin
  Laas.Acquire;
  try
    Inc(TreffPing);
  finally
    Laas.Release;
  end;
  Result := RespondText('pong', 200);
end;

procedure Ruter(R: TRouter);
begin
  R.Get('/', Side);
  R.Get('/ping', Ping);
end;

var
  Feil: string;
  HarSkjerm: Boolean;
begin
  Laas := TCriticalSection.Create;
  WriteLn('askr — desktop');

{$IFDEF WINDOWS}
  WriteLn;
  WriteLn('HOPPET OVER: Windows-skallet er ikke kjørt av noen ennå.');
  WriteLn('  Bindingen er skrevet, men aldri startet på en Windows-maskin.');
  Halt(0);
{$ENDIF}
{$IFDEF DARWIN}
  { På macOS åpner Run et NSWindow som blokkerer til noen lukker det, og
    AutoCloseMs finnes ikke der. En suite som venter på et klikk er ingen
    suite. macOS-skallet verifiseres for hånd med examples/desktop. }
  WriteLn;
  WriteLn('HOPPET OVER: denne suiten tester Linux-webviewen.');
  WriteLn('  macOS-skallet åpner et vindu som må lukkes for hånd —');
  WriteLn('  kjør examples/desktop for å se det.');
  Halt(0);
{$ENDIF}

  if not WebviewAvailable then
  begin
    WriteLn;
    WriteLn('HOPPET OVER: WebKitGTK finnes ikke her.');
    WriteLn('  ', WebviewError);
    Halt(0);
  end;
  WriteLn('backend: ', WebviewBackend);
  Ok('backend-navnet nevner WebKitGTK',
    Pos('WebKitGTK', WebviewBackend) > 0);
  Ok('ingen feil å melde når biblioteket er der', WebviewError = '');

  HarSkjerm := (GetEnvironmentVariable('DISPLAY') <> '') or
               (GetEnvironmentVariable('WAYLAND_DISPLAY') <> '');

  DesktopApp.RegisterRoutes(Ruter);
  DesktopApp.Window('Askr desktop', 900, 600);

  if not HarSkjerm then
  begin
    { Uten skjerm skal GTK gi en forklaring, ikke drepe prosessen.
      gtk_init ville kalt exit() her; gtk_init_check gjør det ikke. }
    WriteLn;
    WriteLn('— uten skjerm');
    Feil := '';
    try
      DesktopApp.Run;
    except
      on E: EDesktopError do Feil := E.Message;
    end;
    { At vi i det hele tatt er her, er poenget: gtk_init ville kalt exit().
      Men det er de to neste som faktisk kan feile — en påstand som ikke kan
      feile er ingen påstand. }
    Ok('feilen nevner DISPLAY', Pos('DISPLAY', Feil) > 0);
    Ok('og sier at appen kjører som webtjeneste likevel',
      Pos('webtjeneste', Feil) > 0);
  end
  else
  begin
    WriteLn;
    WriteLn('— med skjerm');
    { Vinduet lukker seg selv. En suite kan ikke vente på et klikk. }
    DesktopApp.AutoCloseMs := 6000;
    DesktopApp.Run;

    Ok('serveren fikk en port', DesktopApp.Port > 0);
    WriteLn('        treff: / = ', TreffSide, ', /ping = ', TreffPing);
    Ok('webviewen hentet siden', TreffSide > 0);
    Ok('og JavaScript på siden kalte tilbake', TreffPing > 0);
  end;

  WriteLn;
  WriteLn('— ', Bestatt, ' bestått, ', Feilet, ' feilet');
  Laas.Free;
  if Feilet > 0 then
    Halt(1);
end.
