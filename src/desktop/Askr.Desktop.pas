{ Askr.Desktop — samme app som webtjeneste, i et vindu.

      program CustomerApp;
      uses Askr.Desktop, App.Models.Customer, App.Http.Routes;

      begin
        DesktopApp.UseDatabase('sqlite:local.db');
        DesktopApp.RegisterRoutes(@RegisterAppRoutes);
        DesktopApp.Window('Kunder', 1200, 800);
        DesktopApp.Run;
      end.

  PRD-en skriver App i stedet for DesktopApp. Det går ikke: PRD-en gir også
  brukerkoden navnerommet App.Models.*, App.Http.* og App.Schema.*, og da
  leser kompilatoren App.UseDatabase som en unit-kvalifikasjon i stedet for
  et objekt. Navnerommet er mer bærende enn variabelnavnet — det står i
  generert kode fra Norn — så det er variabelen som viker.

  Forskjellen mellom web og desktop er i praksis denne uniten og valget av
  databaseadapter. Kontrollere, modeller og Svelte-komponenter er bit for bit
  de samme, fordi desktop-varianten starter den samme rutingstabellen mot en
  lokal HTTP-server og peker systemets webview dit.

  Det er ingen egen GUI-verktøykasse her, og det skal det ikke bli. PRD-en
  lister det som et ikke-mål. Hele renderingsmotoren lånes gratis: GPU-
  akselerert UI uten en linje grafikkode, og en liten binær fordi systemets
  webview brukes.

  macOS går gjennom Objective-C-runtimen direkte — objc_getClass,
  sel_registerName og objc_msgSend — i stedet for et mellomliggende
  C-bibliotek som måtte bygges og vedlikeholdes. Linux går samme vei mot
  GTK3 og WebKitGTK, lastet med dlopen. Begge er verifisert ved å kjøre dem.

  **Windows-grenen er parkert.** WebView2-bindingen er skrevet og
  typesjekket, men ingen har startet den på en Windows-maskin. Den regnes
  ikke som ferdig før noen har gjort det, og det neste steget der er en
  kjøring — ikke mer kode.

  Alt lastes med dlopen, også på Linux. Det betyr at uniten kompilerer på en
  maskin uten GTK i det hele tatt, og at en app som bare skal kjøre som
  webtjeneste ikke drar med seg en avhengighet den aldri bruker. }
unit Askr.Desktop;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Askr.Core.Arena, Askr.Http.Request, Askr.Http.Response,
  Askr.Http.Server, Askr.Http.Router, Askr.Urd.Driver, Askr.Urd.Model,
  Askr.Urd.Pool;

type
  EDesktopError = class(Exception);

  TRouteRegistrar = procedure(R: TRouter);

  TDesktopApp = class
  private
    FRouter: TRouter;
    FServer: TAskrServer;
    FPool: TDbPool;
    FDsn: string;
    FTitle: string;
    FWidth, FHeight: Integer;
    FPort: Word;
    FAutoCloseMs: Integer;
    function Handle(Req: TRequest): TResponse;
  public
    constructor Create;
    destructor Destroy; override;

    { Databasen. For desktop er det normalt SQLite i en lokal fil. }
    procedure UseDatabase(const ADsn: string);
    { Den samme funksjonen web-skallet kaller. }
    procedure RegisterRoutes(AProc: TRouteRegistrar);
    procedure Window(const ATitle: string; AWidth, AHeight: Integer);
    { Starter serveren, åpner vinduet, og blokkerer til det lukkes. }
    procedure Run;

    { Lukker vinduet selv etter så mange millisekunder. 0 er av, og er det
      eneste riktige for en ekte app. Finnes for tester og skjermbilder: et
      vindu som blokkerer til noen klikker kan ikke kjøres i en suite. }
    property AutoCloseMs: Integer read FAutoCloseMs write FAutoCloseMs;

    { Lokal port serveren fikk. Nyttig i tester og for feilsøking. }
    property Port: Word read FPort;
    property Router: TRouter read FRouter;
  end;

var
  { Én app per prosess. Heter ikke App; se kommentaren øverst. }
  DesktopApp: TDesktopApp;

{ True når plattformens webview er tilgjengelig. Kaster ikke. }
function WebviewAvailable: Boolean;
function WebviewBackend: string;
{ Hvorfor den ikke er tilgjengelig, med hva som må installeres. Tom streng
  når alt er i orden. En app som ikke får åpnet et vindu skal kunne si hva
  som mangler i stedet for bare at noe mangler. }
function WebviewError: string;

implementation

uses
{$IFDEF WINDOWS}
  Windows, ActiveX,
{$ENDIF}
  Math, DynLibs, Askr.Urd.Sqlite;

{$IFDEF DARWIN}

{ ------------------------------------------------- Objective-C-runtimen -- }

type
  TObjcId = Pointer;
  TObjcSel = Pointer;
  TObjcClass = Pointer;

  { NSRect er fire doubles. På arm64 går en slik struktur i SIMD-registre
    etter AAPCS64, og Free Pascal legger den samme vei. }
  TNSRect = record
    X, Y, W, H: Double;
  end;

  Tobjc_getClass = function(Name_: PAnsiChar): TObjcClass; cdecl;
  Tsel_registerName = function(Name_: PAnsiChar): TObjcSel; cdecl;

  { objc_msgSend er variadisk i C. From_ Pascal deklareres den flere ganger med
    hver sin signatur, mot det samme symbolet — det er slik ABI-en faktisk
    virker, og det eneste som er trygt på arm64. }
  TMsgSend = function(Obj: TObjcId; Sel: TObjcSel): TObjcId; cdecl;
  TMsgSendId = function(Obj: TObjcId; Sel: TObjcSel; A: TObjcId): TObjcId; cdecl;
  TMsgSendStr = function(Obj: TObjcId; Sel: TObjcSel; A: PAnsiChar): TObjcId; cdecl;
  TMsgSendInt = function(Obj: TObjcId; Sel: TObjcSel; A: PtrInt): TObjcId; cdecl;
  TMsgSendBool = function(Obj: TObjcId; Sel: TObjcSel; A: Byte): TObjcId; cdecl;
  TMsgSendRect4 = function(Obj: TObjcId; Sel: TObjcSel; R: TNSRect;
    Style: PtrUInt; Backing: PtrUInt; Defer: Byte): TObjcId; cdecl;
  TMsgSendRectId = function(Obj: TObjcId; Sel: TObjcSel; R: TNSRect;
    Cfg: TObjcId): TObjcId; cdecl;

var
  objc_getClass: Tobjc_getClass;
  sel_registerName: Tsel_registerName;
  MsgSend: TMsgSend;
  MsgSendId: TMsgSendId;
  MsgSendStr: TMsgSendStr;
  MsgSendInt: TMsgSendInt;
  MsgSendBool: TMsgSendBool;
  MsgSendRect4: TMsgSendRect4;
  MsgSendRectId: TMsgSendRectId;

  GObjc: TLibHandle = NilHandle;
  GAppKit: TLibHandle = NilHandle;
  GWebKit: TLibHandle = NilHandle;
  GLoadError: string = '';

const
  { NSWindowStyleMask }
  MaskTitled = 1;
  MaskClosable = 2;
  MaskMiniaturizable = 4;
  MaskResizable = 8;
  BackingStoreBuffered = 2;
  ActivationPolicyRegular = 0;

function LoadCocoa: Boolean;
begin
  Result := False;
  if GWebKit <> NilHandle then
    Exit(True);
  if GLoadError <> '' then
    Exit(False);

  GObjc := LoadLibrary('/usr/lib/libobjc.A.dylib');
  { Rammeverkene må lastes for at klassene skal være registrert. }
  GAppKit := LoadLibrary('/System/Library/Frameworks/AppKit.framework/AppKit');
  GWebKit := LoadLibrary('/System/Library/Frameworks/WebKit.framework/WebKit');
  if (GObjc = NilHandle) or (GAppKit = NilHandle) or (GWebKit = NilHandle) then
  begin
    GLoadError := 'Could not find libobjc, AppKit or WebKit.';
    Exit(False);
  end;

  objc_getClass := Tobjc_getClass(GetProcedureAddress(GObjc, 'objc_getClass'));
  sel_registerName := Tsel_registerName(
    GetProcedureAddress(GObjc, 'sel_registerName'));
  MsgSend := TMsgSend(GetProcedureAddress(GObjc, 'objc_msgSend'));
  MsgSendId := TMsgSendId(GetProcedureAddress(GObjc, 'objc_msgSend'));
  MsgSendStr := TMsgSendStr(GetProcedureAddress(GObjc, 'objc_msgSend'));
  MsgSendInt := TMsgSendInt(GetProcedureAddress(GObjc, 'objc_msgSend'));
  MsgSendBool := TMsgSendBool(GetProcedureAddress(GObjc, 'objc_msgSend'));
  MsgSendRect4 := TMsgSendRect4(GetProcedureAddress(GObjc, 'objc_msgSend'));
  MsgSendRectId := TMsgSendRectId(GetProcedureAddress(GObjc, 'objc_msgSend'));

  if not Assigned(objc_getClass) or not Assigned(MsgSend) then
  begin
    GLoadError := 'libobjc is missing objc_getClass or objc_msgSend.';
    Exit(False);
  end;
  Result := True;
end;

function Sel(const Name_: string): TObjcSel;
begin
  Result := sel_registerName(PAnsiChar(AnsiString(Name_)));
end;

function Cls(const Name_: string): TObjcClass;
begin
  Result := objc_getClass(PAnsiChar(AnsiString(Name_)));
end;

function NSStr(const S: string): TObjcId;
begin
  Result := MsgSendStr(Cls('NSString'), Sel('stringWithUTF8String:'),
    PAnsiChar(AnsiString(S)));
end;

procedure OpenWindowTimed(const Title, Url: string; W, H, CloseMs: Integer);
var
  NSApp, Win, Cfg, View, Req, TheUrl: TObjcId;
  Frame: TNSRect;
begin
  if not LoadCocoa then
    raise EDesktopError.Create(GLoadError);

  { Free Pascal slår på flyttallsunntak; Cocoa og CoreGraphics regner rutinemessig
    med NaN og uendelig og utløser dem. Without denne masken dør prosessen med
    EInvalidOp i det første vinduet opprettes. Dette er ikke valgfritt. }
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide,
    exOverflow, exUnderflow, exPrecision]);

  NSApp := MsgSend(Cls('NSApplication'), Sel('sharedApplication'));
  MsgSendInt(NSApp, Sel('setActivationPolicy:'), ActivationPolicyRegular);

  Frame.X := 0;
  Frame.Y := 0;
  Frame.W := W;
  Frame.H := H;

  Win := MsgSend(Cls('NSWindow'), Sel('alloc'));
  Win := MsgSendRect4(Win, Sel('initWithContentRect:styleMask:backing:defer:'),
    Frame,
    MaskTitled or MaskClosable or MaskMiniaturizable or MaskResizable,
    BackingStoreBuffered, 0);
  MsgSendId(Win, Sel('setTitle:'), NSStr(Title));
  MsgSend(Win, Sel('center'));

  Cfg := MsgSend(MsgSend(Cls('WKWebViewConfiguration'), Sel('alloc')),
    Sel('init'));
  View := MsgSend(Cls('WKWebView'), Sel('alloc'));
  View := MsgSendRectId(View, Sel('initWithFrame:configuration:'), Frame, Cfg);

  TheUrl := MsgSendId(Cls('NSURL'), Sel('URLWithString:'), NSStr(Url));
  Req := MsgSendId(Cls('NSURLRequest'), Sel('requestWithURL:'), TheUrl);
  MsgSendId(View, Sel('loadRequest:'), Req);

  MsgSendId(Win, Sel('setContentView:'), View);
  MsgSendId(Win, Sel('makeKeyAndOrderFront:'), nil);
  MsgSendBool(NSApp, Sel('activateIgnoringOtherApps:'), 1);

  { AutoCloseMs finnes for testene, og der kjøres Linux-varianten. På macOS
    ville det krevd en NSTimer med en Objective-C-klasse laget i runtime —
    mye maskineri for noe ingen ekte app skal bruke. }
  if CloseMs > 0 then
    raise EDesktopError.Create(
      'AutoCloseMs is not implemented on macOS');

  { Blokkerer til vinduet lukkes. }
  MsgSend(NSApp, Sel('run'));
end;

function WebviewAvailable: Boolean;
begin
  Result := LoadCocoa and (Cls('WKWebView') <> nil) and
    (Cls('NSWindow') <> nil);
end;

function WebviewBackend: string;
begin
  Result := 'WKWebView (macOS)';
end;

function WebviewError: string;
begin
  if LoadCocoa then
    Result := ''
  else
    Result := GLoadError;
end;

{$ELSE}
{$IFDEF UNIX}

{ ------------------------------------------------- GTK3 og WebKitGTK -- }

{ webkit2gtk 4.0 og 4.1 skiller seg bare i hvilken libsoup de bruker.
  Symbolene her er de samme i begge, så begge står i kandidatlisten. }

type
  Tgtk_init_check = function(Argc: PLongInt; Argv: PPointer): LongInt; cdecl;
  Tgtk_window_new = function(Kind: LongInt): Pointer; cdecl;
  Tgtk_window_set_title = procedure(W: Pointer; T: PAnsiChar); cdecl;
  Tgtk_window_set_default_size = procedure(W: Pointer; Wd, Ht: LongInt); cdecl;
  Tgtk_window_set_position = procedure(W: Pointer; P: LongInt); cdecl;
  Tgtk_container_add = procedure(C, Child: Pointer); cdecl;
  Tgtk_widget_show_all = procedure(W: Pointer); cdecl;
  Tgtk_main = procedure; cdecl;
  Tgtk_main_quit = procedure; cdecl;
  Twebkit_web_view_new = function: Pointer; cdecl;
  Twebkit_web_view_load_uri = procedure(V: Pointer; U: PAnsiChar); cdecl;
  Tg_signal_connect_data = function(Instance: Pointer; Signal_: PAnsiChar;
    Handler, Data, DestroyData: Pointer; Flags: LongInt): PtrUInt; cdecl;
  Tg_timeout_add = function(Interval: LongWord; Func, Data: Pointer): LongWord; cdecl;

const
  GtkWindowToplevel = 0;
  GtkWinPosCenter = 1;

var
  gtk_init_check: Tgtk_init_check;
  gtk_window_new: Tgtk_window_new;
  gtk_window_set_title: Tgtk_window_set_title;
  gtk_window_set_default_size: Tgtk_window_set_default_size;
  gtk_window_set_position: Tgtk_window_set_position;
  gtk_container_add: Tgtk_container_add;
  gtk_widget_show_all: Tgtk_widget_show_all;
  gtk_main: Tgtk_main;
  gtk_main_quit: Tgtk_main_quit;
  webkit_web_view_new: Twebkit_web_view_new;
  webkit_web_view_load_uri: Twebkit_web_view_load_uri;
  g_signal_connect_data: Tg_signal_connect_data;
  g_timeout_add: Tg_timeout_add;

  GGtk: TLibHandle = NilHandle;
  GWebkit: TLibHandle = NilHandle;
  GGobject: TLibHandle = NilHandle;
  GGlib: TLibHandle = NilHandle;
  GLoaded: Boolean = False;
  GTried: Boolean = False;
  GLoadError: string = '';
  GBackend: string = '';

function TryLoad(const Names: array of string; out Chosen: string): TLibHandle;
var
  I: Integer;
begin
  Chosen := '';
  for I := 0 to High(Names) do
  begin
    Result := LoadLibrary(Names[I]);
    if Result <> NilHandle then
    begin
      Chosen := Names[I];
      Exit;
    end;
  end;
  Result := NilHandle;
end;

function Need(Lib: TLibHandle; const LibName, Symbol: string): Pointer;
begin
  Result := GetProcedureAddress(Lib, Symbol);
  if Result = nil then
    raise EDesktopError.CreateFmt('%s is missing %s', [LibName, Symbol]);
end;

function LoadGtk: Boolean;
var
  GtkName, WkName, GoName, GlName: string;
begin
  if GLoaded then
    Exit(True);
  if GTried then
    Exit(False);
  GTried := True;

  GGtk := TryLoad(['libgtk-3.so.0', 'libgtk-3.so'], GtkName);
  GWebkit := TryLoad(['libwebkit2gtk-4.1.so.0', 'libwebkit2gtk-4.0.so.37',
    'libwebkit2gtk-4.1.so', 'libwebkit2gtk-4.0.so'], WkName);
  GGobject := TryLoad(['libgobject-2.0.so.0', 'libgobject-2.0.so'], GoName);
  GGlib := TryLoad(['libglib-2.0.so.0', 'libglib-2.0.so'], GlName);

  if (GGtk = NilHandle) or (GWebkit = NilHandle) or (GGobject = NilHandle) or
     (GGlib = NilHandle) then
  begin
    GLoadError := 'Could not find GTK3 and WebKitGTK. ' +
      'On Debian and Ubuntu: apt install libgtk-3-0 libwebkit2gtk-4.1-0. ' +
      'On Fedora: dnf install gtk3 webkit2gtk4.1.';
    Exit(False);
  end;

  try
    gtk_init_check := Need(GGtk, GtkName, 'gtk_init_check');
    gtk_window_new := Need(GGtk, GtkName, 'gtk_window_new');
    gtk_window_set_title := Need(GGtk, GtkName, 'gtk_window_set_title');
    gtk_window_set_default_size :=
      Need(GGtk, GtkName, 'gtk_window_set_default_size');
    gtk_window_set_position := Need(GGtk, GtkName, 'gtk_window_set_position');
    gtk_container_add := Need(GGtk, GtkName, 'gtk_container_add');
    gtk_widget_show_all := Need(GGtk, GtkName, 'gtk_widget_show_all');
    gtk_main := Need(GGtk, GtkName, 'gtk_main');
    gtk_main_quit := Need(GGtk, GtkName, 'gtk_main_quit');
    webkit_web_view_new := Need(GWebkit, WkName, 'webkit_web_view_new');
    webkit_web_view_load_uri :=
      Need(GWebkit, WkName, 'webkit_web_view_load_uri');
    g_signal_connect_data :=
      Need(GGobject, GoName, 'g_signal_connect_data');
    g_timeout_add := Need(GGlib, GlName, 'g_timeout_add');
  except
    on E: Exception do
    begin
      GLoadError := E.Message;
      Exit(False);
    end;
  end;

  GBackend := 'WebKitGTK (' + WkName + ')';
  GLoaded := True;
  Result := True;
end;

{ GTK kaller denne når vinduet lukkes. Without den kjører gtk_main videre etter
  at vinduet er borte, og prosessen henger. }
procedure OnDestroy(Widget, Data: Pointer); cdecl;
begin
  gtk_main_quit();
end;

{ To_ AutoCloseMs. Returnerer FALSE slik at timeren ikke gjentas. }
function OnTimeout(Data: Pointer): LongInt; cdecl;
begin
  gtk_main_quit();
  Result := 0;
end;

procedure OpenWindowTimed(const Title, Url: string; W, H, CloseMs: Integer);
var
  Win, View: Pointer;
begin
  if not LoadGtk then
    raise EDesktopError.Create(GLoadError);

  { Samme grunn som i Cocoa-grenen, og like lite valgfri: Free Pascal slår på
    flyttallsunntak, og Cairo, GLib og WebKit regner rutinemessig med NaN og
    uendelig. Without masken dør prosessen med EInvalidOp inne i WebKit, og
    stakksporet peker på biblioteker man ikke har skrevet — det ser ut som en
    feil i nettmotoren, ikke som et valg i vår egen runtime. }
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide,
    exOverflow, exUnderflow, exPrecision]);

  { gtk_init kaller exit() når det ikke finnes en skjerm å tegne på.
    gtk_init_check returnerer FALSE i stedet, og da kan vi si hva som er
    galt framfor å forsvinne uten et ord. }
  if gtk_init_check(nil, nil) = 0 then
    raise EDesktopError.Create(
      'GTK could not open a display. Is DISPLAY or WAYLAND_DISPLAY set? ' +
      'The app is still serving over HTTP at ' + Url);

  Win := gtk_window_new(GtkWindowToplevel);
  gtk_window_set_title(Win, PAnsiChar(AnsiString(Title)));
  gtk_window_set_default_size(Win, W, H);
  gtk_window_set_position(Win, GtkWinPosCenter);
  g_signal_connect_data(Win, 'destroy', @OnDestroy, nil, nil, 0);

  View := webkit_web_view_new();
  webkit_web_view_load_uri(View, PAnsiChar(AnsiString(Url)));
  gtk_container_add(Win, View);

  gtk_widget_show_all(Win);
  if CloseMs > 0 then
    g_timeout_add(LongWord(CloseMs), @OnTimeout, nil);

  { Blokkerer til vinduet lukkes. }
  gtk_main();
end;

procedure OpenWindow(const Title, Url: string; W, H: Integer);
begin
  OpenWindowTimed(Title, Url, W, H, 0);
end;

function WebviewAvailable: Boolean;
begin
  Result := LoadGtk;
end;

function WebviewBackend: string;
begin
  if LoadGtk then
    Result := GBackend
  else
    Result := '(WebKitGTK not found)';
end;

function WebviewError: string;
begin
  if LoadGtk then
    Result := ''
  else
    Result := GLoadError;
end;

{$ELSE}
{$IFDEF WINDOWS}

{ --------------------------------------------------- Windows: WebView2 -- }

{ WebView2 er COM, og det er det som gjør denne grenen ulik de to andre.

  Vtable-ene skrives ikke for hånd. Metodene deklareres som Pascal-interface
  i **nøyaktig** den rekkefølgen WebView2.h har dem, og kompilatoren legger
  ut vtablen. Å telle indekser selv er den ene feilen som ikke sier fra:
  kaller man metode 24 i stedet for 25, får man en peker som ser gyldig ut.
  Derfor står også metoder vi aldri bruker med i deklarasjonene — de er der
  for å holde rekkefølgen, ikke for å brukes.

  Callbackene går samme vei: TInterfacedObject gir riktig vtable gratis, og
  COM-tellingen følger av at FPC implementerer IUnknown.

  Oppstarten er asynkron. CreateCoreWebView2EnvironmentWithOptions
  returnerer med én gang, og Invoke kommer først når meldingsløkka kjører.
  Derfor lages vinduet først, så startes løkka, og navigeringen skjer inne i
  den andre callbacken. }

type
  ICoreWebView2Environment = interface;
  ICoreWebView2Controller = interface;
  ICoreWebView2 = interface;

  ICoreWebView2CreateCoreWebView2ControllerCompletedHandler = interface(IUnknown)
    ['{6c4819f3-c9b7-4260-8127-c9f5bde7f68c}']
    function Invoke(errorCode: HResult;
      createdController: ICoreWebView2Controller): HResult; stdcall;
  end;

  ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler = interface(IUnknown)
    ['{4e8a3389-c9d8-4bd2-b6b5-124fee6cc14d}']
    function Invoke(errorCode: HResult;
      createdEnvironment: ICoreWebView2Environment): HResult; stdcall;
  end;

  ICoreWebView2Environment = interface(IUnknown)
    ['{b96d755e-0319-4e92-a296-23436f46a1fc}']
    function CreateCoreWebView2Controller(ParentWindow: HWND;
      Handler: ICoreWebView2CreateCoreWebView2ControllerCompletedHandler):
      HResult; stdcall;
    { Resten er med for vtable-rekkefølgen, ikke for å brukes. }
    function CreateWebResourceResponse(A, B: Pointer; C: SmallInt;
      D: PWideChar; out E: Pointer): HResult; stdcall;
    function get_BrowserVersionString(out V: PWideChar): HResult; stdcall;
    function add_NewBrowserVersionAvailable(H: Pointer;
      out Token: Int64): HResult; stdcall;
    function remove_NewBrowserVersionAvailable(Token: Int64): HResult; stdcall;
  end;

  ICoreWebView2 = interface(IUnknown)
    ['{76eceacb-0462-4d94-ac83-423a6793775e}']
    function get_Settings(out Settings: Pointer): HResult; stdcall;
    function get_Source(out Uri: PWideChar): HResult; stdcall;
    function Navigate(Uri: PWideChar): HResult; stdcall;
    { Alt etter Navigate er utelatt: ingenting her kaller det, og en
      metode som ikke er deklarert kan ikke kalles med feil indeks. }
  end;

  ICoreWebView2Controller = interface(IUnknown)
    ['{4d00c0d1-9434-4eb6-8078-8697a560334f}']
    function get_IsVisible(out V: LongBool): HResult; stdcall;
    function put_IsVisible(V: LongBool): HResult; stdcall;
    function get_Bounds(out B: TRect): HResult; stdcall;
    function put_Bounds(B: TRect): HResult; stdcall;
    function get_ZoomFactor(out Z: Double): HResult; stdcall;
    function put_ZoomFactor(Z: Double): HResult; stdcall;
    function add_ZoomFactorChanged(H: Pointer; out T: Int64): HResult; stdcall;
    function remove_ZoomFactorChanged(T: Int64): HResult; stdcall;
    function SetBoundsAndZoomFactor(B: TRect; Z: Double): HResult; stdcall;
    function MoveFocus(Reason: LongInt): HResult; stdcall;
    function add_MoveFocusRequested(H: Pointer; out T: Int64): HResult; stdcall;
    function remove_MoveFocusRequested(T: Int64): HResult; stdcall;
    function add_GotFocus(H: Pointer; out T: Int64): HResult; stdcall;
    function remove_GotFocus(T: Int64): HResult; stdcall;
    function add_LostFocus(H: Pointer; out T: Int64): HResult; stdcall;
    function remove_LostFocus(T: Int64): HResult; stdcall;
    function add_AcceleratorKeyPressed(H: Pointer; out T: Int64): HResult; stdcall;
    function remove_AcceleratorKeyPressed(T: Int64): HResult; stdcall;
    function get_ParentWindow(out W: HWND): HResult; stdcall;
    function put_ParentWindow(W: HWND): HResult; stdcall;
    function NotifyParentWindowPositionChanged: HResult; stdcall;
    function Close: HResult; stdcall;
    function get_CoreWebView2(out V: ICoreWebView2): HResult; stdcall;
  end;

  TCreateEnv = function(BrowserFolder, UserDataFolder: PWideChar;
    Options: Pointer;
    Handler: ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler):
    HResult; stdcall;

var
  CreateCoreWebView2EnvironmentWithOptions: TCreateEnv;
  GLoaderLib: TLibHandle = NilHandle;
  GLoaded: Boolean = False;
  GTried: Boolean = False;
  GLoadError: string = '';
  GLoaderName: string = '';

  { Tilstanden meldingsløkka og callbackene deler. Én app per prosess, som
    på de to andre plattformene. }
  GHwnd: HWND = 0;
  GController: ICoreWebView2Controller = nil;
  GUrl: WideString = '';
  GStartError: string = '';
  { Callbackene holdes i live her. WebView2 tar sin egen COM-referanse, så i
    teorien holder det å sende dem som parameter — men da hviler levetiden
    på at en midlertidig Pascal-referanse og en C++-AddRef går opp i opp.
    To globale referanser koster ingenting og fjerner spørsmålet. }
  GEnvHandler: IUnknown = nil;
  GCtrlHandler: IUnknown = nil;

function LoadWebView2: Boolean;
const
  Kandidater: array[0..1] of string = ('WebView2Loader.dll',
    'WebView2Loader.dll.lib');
var
  I: Integer;
begin
  if GLoaded then
    Exit(True);
  if GTried then
    Exit(False);
  GTried := True;

  for I := 0 to High(Kandidater) do
  begin
    GLoaderLib := LoadLibrary(Kandidater[I]);
    if GLoaderLib <> NilHandle then
    begin
      GLoaderName := Kandidater[I];
      Break;
    end;
  end;

  if GLoaderLib = NilHandle then
  begin
    GLoadError := 'Could not find WebView2Loader.dll. It ships with the ' +
      'WebView2 SDK and belongs next to the binary. ' +
      'Install the runtime from ' +
      'https://developer.microsoft.com/microsoft-edge/webview2/ — ' +
      'on Windows 11 it is already there.';
    Exit(False);
  end;

  CreateCoreWebView2EnvironmentWithOptions := TCreateEnv(
    GetProcedureAddress(GLoaderLib,
      'CreateCoreWebView2EnvironmentWithOptions'));
  if not Assigned(CreateCoreWebView2EnvironmentWithOptions) then
  begin
    GLoadError := GLoaderName +
      ' is missing CreateCoreWebView2EnvironmentWithOptions.';
    Exit(False);
  end;

  GLoaded := True;
  Result := True;
end;

type
  { Kalles når kontrolleren er klar: da finnes det noe å navigere med. }
  TControllerHandler = class(TInterfacedObject,
    ICoreWebView2CreateCoreWebView2ControllerCompletedHandler)
    function Invoke(errorCode: HResult;
      createdController: ICoreWebView2Controller): HResult; stdcall;
  end;

  { Kalles når miljøet er klar. Det er her kontrolleren bestilles. }
  TEnvHandler = class(TInterfacedObject,
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler)
    function Invoke(errorCode: HResult;
      createdEnvironment: ICoreWebView2Environment): HResult; stdcall;
  end;

function TControllerHandler.Invoke(errorCode: HResult;
  createdController: ICoreWebView2Controller): HResult; stdcall;
var
  R: TRect;
  View: ICoreWebView2;
begin
  Result := S_OK;
  if (errorCode <> S_OK) or (createdController = nil) then
  begin
    GStartError := Format('The WebView2 controller failed (0x%.8x)', [errorCode]);
    PostQuitMessage(0);
    Exit;
  end;

  GController := createdController;
  GetClientRect(GHwnd, R);
  GController.put_Bounds(R);

  if GController.get_CoreWebView2(View) <> S_OK then
  begin
    GStartError := 'Could not obtain ICoreWebView2';
    PostQuitMessage(0);
    Exit;
  end;
  View.Navigate(PWideChar(GUrl));
end;

function TEnvHandler.Invoke(errorCode: HResult;
  createdEnvironment: ICoreWebView2Environment): HResult; stdcall;
begin
  Result := S_OK;
  if (errorCode <> S_OK) or (createdEnvironment = nil) then
  begin
    GStartError := Format('The WebView2 environment failed (0x%.8x). ' +
      'Is the runtime installed?', [errorCode]);
    PostQuitMessage(0);
    Exit;
  end;
  GCtrlHandler := TControllerHandler.Create;
  createdEnvironment.CreateCoreWebView2Controller(GHwnd,
    GCtrlHandler as ICoreWebView2CreateCoreWebView2ControllerCompletedHandler);
end;

function WndProc(Wnd: HWND; Msg: UINT; WP: WPARAM; LP: LPARAM): LRESULT; stdcall;
var
  R: TRect;
begin
  case Msg of
    WM_SIZE:
      begin
        { Without dette blir nettmotoren stående i sin opprinnelige størrelse
          mens vinduet endrer seg. }
        if GController <> nil then
        begin
          GetClientRect(Wnd, R);
          GController.put_Bounds(R);
        end;
        Exit(0);
      end;
    WM_TIMER:
      begin
        { AutoCloseMs. Samme rolle som g_timeout_add på Linux. }
        KillTimer(Wnd, WP);
        PostQuitMessage(0);
        Exit(0);
      end;
    WM_DESTROY:
      begin
        PostQuitMessage(0);
        Exit(0);
      end;
  end;
  Result := DefWindowProcW(Wnd, Msg, WP, LP);
end;

procedure OpenWindowTimed(const Title, Url: string; W, H, CloseMs: Integer);
const
  ClassName_: WideString = 'AskrDesktopWindow';
var
  Wc: TWndClassExW;
  Msg: TMsg;
  WTitle: WideString;
  Hr: HResult;
begin
  if not LoadWebView2 then
    raise EDesktopError.Create(GLoadError + ' The app is still serving over ' +
      'HTTP at ' + Url);

  { Samme grunn som i de to andre grenene: Free Pascal slår på
    flyttallsunntak, og grafikkstakken regner med NaN. }
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide,
    exOverflow, exUnderflow, exPrecision]);

  { WebView2 er COM og må ha en apartment-tråd. }
  Hr := CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  if (Hr <> S_OK) and (Hr <> S_FALSE) then
    raise EDesktopError.CreateFmt('CoInitializeEx failed (0x%.8x)', [Hr]);

  GUrl := WideString(Url);
  GStartError := '';

  FillChar(Wc, SizeOf(Wc), 0);
  Wc.cbSize := SizeOf(Wc);
  Wc.style := CS_HREDRAW or CS_VREDRAW;
  Wc.lpfnWndProc := @WndProc;
  Wc.hInstance := HInstance;
  Wc.hCursor := LoadCursor(0, IDC_ARROW);
  Wc.hbrBackground := HBRUSH(COLOR_WINDOW + 1);
  Wc.lpszClassName := PWideChar(ClassName_);
  if RegisterClassExW(Wc) = 0 then
    raise EDesktopError.Create('RegisterClassExW failed');

  WTitle := WideString(Title);
  GHwnd := CreateWindowExW(0, PWideChar(ClassName_), PWideChar(WTitle),
    WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, W, H,
    0, 0, HInstance, nil);
  if GHwnd = 0 then
    raise EDesktopError.Create('CreateWindowExW failed');

  ShowWindow(GHwnd, SW_SHOWNORMAL);
  UpdateWindow(GHwnd);

  { Asynkron: Invoke kommer først når løkka under kjører. }
  GEnvHandler := TEnvHandler.Create;
  Hr := CreateCoreWebView2EnvironmentWithOptions(nil, nil, nil,
    GEnvHandler as ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler);
  if Hr <> S_OK then
    raise EDesktopError.CreateFmt(
      'CreateCoreWebView2EnvironmentWithOptions failed (0x%.8x). ' +
      'Is the WebView2 runtime installed?', [Hr]);

  if CloseMs > 0 then
    SetTimer(GHwnd, 1, CloseMs, nil);

  { GetMessageW tar meldingen som var-parameter i FPCs Windows-unit, ikke
    som peker. @Msg ville ikke kompilert. }
  while GetMessageW(Msg, 0, 0, 0) do
  begin
    TranslateMessage(Msg);
    DispatchMessageW(Msg);
  end;

  GController := nil;
  GCtrlHandler := nil;
  GEnvHandler := nil;
  CoUninitialize;

  if GStartError <> '' then
    raise EDesktopError.Create(GStartError);
end;

procedure OpenWindow(const Title, Url: string; W, H: Integer);
begin
  OpenWindowTimed(Title, Url, W, H, 0);
end;

function WebviewAvailable: Boolean;
begin
  Result := LoadWebView2;
end;

function WebviewBackend: string;
begin
  if LoadWebView2 then
    Result := 'WebView2 (' + GLoaderName + ')'
  else
    Result := '(WebView2 not found)';
end;

function WebviewError: string;
begin
  if LoadWebView2 then
    Result := ''
  else
    Result := GLoadError;
end;

{$ELSE}

procedure OpenWindowTimed(const Title, Url: string; W, H, CloseMs: Integer);
begin
  raise EDesktopError.Create(
    'The desktop shell is implemented for macOS (WKWebView), Linux ' +
    '(WebKitGTK) and Windows (WebView2). This platform has none of ' +
    'them. The app is still serving over HTTP at ' + Url);
end;

procedure OpenWindow(const Title, Url: string; W, H: Integer);
begin
  OpenWindowTimed(Title, Url, W, H, 0);
end;

function WebviewAvailable: Boolean;
begin
  Result := False;
end;

function WebviewBackend: string;
begin
  Result := '(not implemented on this platform)';
end;

function WebviewError: string;
begin
  Result := 'The desktop shell covers macOS (WKWebView), Linux (WebKitGTK) ' +
    'and Windows (WebView2, never run yet). This platform is none ' +
    'of them.';
end;

{$ENDIF}
{$ENDIF}
{$ENDIF}

{ ----------------------------------------------------------- TDesktopApp -- }

constructor TDesktopApp.Create;
begin
  inherited Create;
  FRouter := TRouter.Create;
  FTitle := 'Askr';
  FWidth := 1100;
  FHeight := 750;
end;

destructor TDesktopApp.Destroy;
begin
  FServer.Free;
  FPool.Free;
  FRouter.Free;
  inherited Destroy;
end;

procedure TDesktopApp.UseDatabase(const ADsn: string);
begin
  FDsn := ADsn;
  { Én forbindelse holder for en skrivebordsapp, og SQLite har uansett bare
    én skriver. Poolen finnes for at koden skal være den samme som på web. }
  FPool := TDbPool.Create(ADsn, 2);
  FPool.Warmup;
end;

procedure TDesktopApp.RegisterRoutes(AProc: TRouteRegistrar);
begin
  if not Assigned(AProc) then
    raise EDesktopError.Create('RegisterRoutes without a function');
  AProc(FRouter);
end;

procedure TDesktopApp.Window(const ATitle: string; AWidth, AHeight: Integer);
begin
  FTitle := ATitle;
  FWidth := AWidth;
  FHeight := AHeight;
end;

function TDesktopApp.Handle(Req: TRequest): TResponse;
var
  PrevDb: TDbConnection;
begin
  { Samme mønster som web-skallet: forbindelsen lånes for requesten og
    leveres tilbake når arenaen nullstilles. }
  if FPool <> nil then
    PrevDb := UseDb(FPool.Lease(Req.Arena))
  else
    PrevDb := nil;
  try
    Result := FRouter.Handle(Req);
  finally
    if FPool <> nil then
      UseDb(PrevDb);
  end;
end;

procedure TDesktopApp.Run;
var
  Opts: TServerOptions;
begin
  Opts := DefaultServerOptions;
  Opts.Host := '127.0.0.1';
  { Kjernen velger porten. En skrivebordsapp skal ikke krasje fordi noe
    annet tilfeldigvis bruker 8080. }
  Opts.Port := 0;
  { Én bruker, ett vindu. Seksten workere ville vært sløsing. }
  Opts.Workers := 2;
  Opts.LogRequests := False;

  FServer := TAskrServer.Create(Opts);
  FServer.SetHandler(Handle);
  FServer.Start;
  FPort := FServer.BoundPort;
  { Flush er nødvendig: stdout er blokkbufret når det omdirigeres, og
    Cocoa-løkka under kommer aldri til å tømme bufferet. }
  WriteLn(Format('%s — local server on 127.0.0.1:%d, webview: %s',
    [FTitle, FPort, WebviewBackend]));
  Flush(Output);

  try
    OpenWindowTimed(FTitle, Format('http://127.0.0.1:%d/', [FPort]),
      FWidth, FHeight, FAutoCloseMs);
  finally
    FServer.Stop;
  end;
end;

initialization
  DesktopApp := TDesktopApp.Create;

finalization
  DesktopApp.Free;

end.
