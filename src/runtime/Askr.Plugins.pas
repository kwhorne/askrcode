{ Askr.Plugins — what a plugin gives an app, and when.

      type
        TStripePlugin = class(TPlugin)
        public
          function Name: string; override;
          procedure Configure; override;
          procedure Routes(R: TRouter); override;
        end;
      ...
      initialization
        RegisterPlugin(TStripePlugin);

  A plugin's initialization only registers its class. It runs before the
  app's first line -- before LoadConfig -- so nothing it reads there would
  be the configuration the app runs with. The app calls UsePlugins(R) once
  its own middleware is on the router, and each plugin is made then:
  Configure, when the configuration is loaded, and Routes, with the router
  that has sessions and sign-in on it already.

  Commands and migrations need no hook: RegisterCommand and
  RegisterMigration in the initialization are enough, since RunConsole and
  the migrator read their lists when they run.

  **A plugin that fails to start stops the app, and says which.** One half
  started is a payment page with no webhook behind it. }
unit Askr.Plugins;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Askr.Http.Router;

type
  EPluginError = class(Exception);

  TPlugin = class
  public
    { Virtual, so UsePlugins can make it from its class alone. }
    constructor Create; virtual;
    { The name in askr-plugin.toml. }
    function Name: string; virtual; abstract;
    { When the app's configuration is loaded: read it, check it, set up
      what the plugin needs. Raise when something it cannot do without is
      missing -- the app stops and says so. }
    procedure Configure; virtual;
    { Its routes and middleware. The router already has the app's
      sessions, CSRF and sign-in on it. }
    procedure Routes(R: TRouter); virtual;
  end;

  TPluginClass = class of TPlugin;

{ From a plugin's initialization. }
procedure RegisterPlugin(AClass: TPluginClass);

{ Makes each registered plugin, in the order they registered, and calls
  Configure and then Routes on it. Once: a second call raises. }
procedure UsePlugins(R: TRouter);

{ The plugins UsePlugins started, by name. For `askr about` and tests. }
function StartedPlugins: TStringArray;

{ Forgets every plugin. For tests. }
procedure ResetPlugins;

implementation

var
  GClasses: array of TPluginClass;
  GStarted: array of TPlugin;
  GUsed: Boolean = False;

constructor TPlugin.Create;
begin
  inherited Create;
end;

procedure TPlugin.Configure;
begin
end;

procedure TPlugin.Routes(R: TRouter);
begin
end;

procedure RegisterPlugin(AClass: TPluginClass);
var
  I: Integer;
begin
  for I := 0 to High(GClasses) do
    if GClasses[I] = AClass then
      Exit;
  I := Length(GClasses);
  SetLength(GClasses, I + 1);
  GClasses[I] := AClass;
end;

procedure UsePlugins(R: TRouter);
var
  I, J: Integer;
  P: TPlugin;
  Stage: string;
begin
  if GUsed then
    raise EPluginError.Create('UsePlugins was called twice; the plugins are ' +
      'already started');
  GUsed := True;
  for I := 0 to High(GClasses) do
  begin
    P := GClasses[I].Create;
    for J := 0 to High(GStarted) do
      if SameText(GStarted[J].Name, P.Name) then
      begin
        P.Free;
        raise EPluginError.CreateFmt('Two plugins call themselves %s', [GStarted[J].Name]);
      end;
    Stage := 'configure';
    try
      P.Configure;
      Stage := 'add its routes';
      R.Owner := 'the plugin ' + P.Name;
      try
        P.Routes(R);
      finally
        R.Owner := '';
      end;
    except
      on E: Exception do
      begin
        Stage := Format('The plugin %s could not %s: %s', [P.Name, Stage, E.Message]);
        P.Free;
        raise EPluginError.Create(Stage);
      end;
    end;
    J := Length(GStarted);
    SetLength(GStarted, J + 1);
    GStarted[J] := P;
  end;
end;

function StartedPlugins: TStringArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(GStarted));
  for I := 0 to High(GStarted) do
    Result[I] := GStarted[I].Name;
end;

procedure ResetPlugins;
var
  I: Integer;
begin
  for I := 0 to High(GStarted) do
    GStarted[I].Free;
  GStarted := nil;
  GClasses := nil;
  GUsed := False;
end;

finalization
  ResetPlugins;

end.
