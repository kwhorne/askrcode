{ Sjekker det som kan sjekkes av WebView2-bindingen uten Windows.

  Dette er ikke en kjøring, og det later ikke som det. Windows-API-et er
  stubbet ut. Det som faktisk prøves er Pascal-siden:

    * at COM-interfacene lar seg deklarere med den metoderekkefølgen
      WebView2.h har,
    * at TInterfacedObject-klassene **faktisk oppfyller** callback-
      interfacene — kompilatoren sammenligner signaturene, og en feil der
      er en av de få tingene som ellers først ville vist seg som et krasj
      hos en bruker,
    * at «as»-castene og flyten går opp.

  Signaturene mot Windows-API-et er verifisert hver for seg, ved å lese
  FPCs egne deklarasjoner i rtl/win. Det er to ulike sjekker, og ingen av
  dem erstatter å kjøre koden på Windows.

  Deklarasjonene her er en kopi av dem i Askr.Desktop. Endres den ene, må
  den andre følge etter — de kan ikke deles, fordi originalen ligger bak
  en betinget kompilering for Windows. }
program webview2_vtable;

{$mode Delphi}{$H+}

uses
  SysUtils;

type
  { Stubber. Only formen betyr noe her. }
  HWND = PtrUInt;
  TRect = record Left, Top, Right, Bottom: LongInt; end;

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

  TControllerHandler = class(TInterfacedObject,
    ICoreWebView2CreateCoreWebView2ControllerCompletedHandler)
    function Invoke(errorCode: HResult;
      createdController: ICoreWebView2Controller): HResult; stdcall;
  end;

  TEnvHandler = class(TInterfacedObject,
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler)
    function Invoke(errorCode: HResult;
      createdEnvironment: ICoreWebView2Environment): HResult; stdcall;
  end;

var
  GHwnd: HWND = 0;
  GController: ICoreWebView2Controller = nil;
  GCtrlHandler: IUnknown = nil;
  GEnvHandler: IUnknown = nil;
  GUrl: WideString = 'http://127.0.0.1:1/';

function TControllerHandler.Invoke(errorCode: HResult;
  createdController: ICoreWebView2Controller): HResult; stdcall;
var
  R: TRect;
  View: ICoreWebView2;
begin
  Result := 0;
  if (errorCode <> 0) or (createdController = nil) then
    Exit;
  GController := createdController;
  FillChar(R, SizeOf(R), 0);
  GController.put_Bounds(R);
  if GController.get_CoreWebView2(View) <> 0 then
    Exit;
  View.Navigate(PWideChar(GUrl));
end;

function TEnvHandler.Invoke(errorCode: HResult;
  createdEnvironment: ICoreWebView2Environment): HResult; stdcall;
begin
  Result := 0;
  if (errorCode <> 0) or (createdEnvironment = nil) then
    Exit;
  GCtrlHandler := TControllerHandler.Create;
  createdEnvironment.CreateCoreWebView2Controller(GHwnd,
    GCtrlHandler as ICoreWebView2CreateCoreWebView2ControllerCompletedHandler);
end;

var
  Env: ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler;
  Ctrl: ICoreWebView2CreateCoreWebView2ControllerCompletedHandler;
begin
  { Oppfyller klassene interfacene? Kompilatoren svarer på det over; her
    sjekkes at castene også går opp i praksis. }
  GEnvHandler := TEnvHandler.Create;
  Env := GEnvHandler as ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler;
  if Env = nil then
  begin
    WriteLn('FEIL: TEnvHandler oppfyller ikke miljø-callbacken');
    Halt(1);
  end;

  GCtrlHandler := TControllerHandler.Create;
  Ctrl := GCtrlHandler as ICoreWebView2CreateCoreWebView2ControllerCompletedHandler;
  if Ctrl = nil then
  begin
    WriteLn('FEIL: TControllerHandler oppfyller ikke kontroller-callbacken');
    Halt(1);
  end;

  { Et kall med feilkode skal komme uskadd tilbake uten å røre noe COM. }
  if Env.Invoke(HResult($80004005), nil) <> 0 then
  begin
    WriteLn('FEIL: Invoke med feilkode returnerte ikke S_OK');
    Halt(1);
  end;
  if Ctrl.Invoke(HResult($80004005), nil) <> 0 then
  begin
    WriteLn('FEIL: kontroller-Invoke med feilkode returnerte ikke S_OK');
    Halt(1);
  end;

  WriteLn('ok  COM-interfacene lar seg deklarere i WebView2.h-rekkefølge');
  WriteLn('ok  begge callback-klassene oppfyller interfacene sine');
  WriteLn('ok  feilkode-stien returnerer S_OK uten å røre COM');
  WriteLn;
  WriteLn('Merk: Windows-API-kallene er IKKE testet her. De er verifisert');
  WriteLn('mot FPCs egne deklarasjoner i rtl/win, som er noe annet enn å');
  WriteLn('kjøre dem.');
  Env := nil;
  Ctrl := nil;
  GEnvHandler := nil;
  GCtrlHandler := nil;
end.
