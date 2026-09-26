{ The plugin gate's fixture: a route, a command, and the configuration it
  reads in Configure, once the app has loaded it. }
unit Hello.Plugin;

{$mode Delphi}{$H+}

interface

implementation

uses
  SysUtils, Askr.Core.Config, Askr.Plugins, Askr.Console,
  Askr.Http.Router, Askr.Http.Request, Askr.Http.Response;

type
  THelloPlugin = class(TPlugin)
  public
    function Name: string; override;
    procedure Configure; override;
    procedure Routes(R: TRouter); override;
    function Greet(Req: TRequest): TResponse;
  end;

var
  GGreeting: string = '';

function THelloPlugin.Name: string;
begin
  Result := 'hello';
end;

procedure THelloPlugin.Configure;
begin
  GGreeting := Cfg('hello.greeting', 'hello from a plugin');
end;

procedure THelloPlugin.Routes(R: TRouter);
begin
  R.Get('/hello', Greet);
end;

function THelloPlugin.Greet(Req: TRequest): TResponse;
begin
  Result := RespondText(GGreeting);
end;

function GreetCommand(const A: TConsoleArgs): Integer;
begin
  WriteLn('hello from a plugin command');
  Result := 0;
end;

initialization
  RegisterPlugin(THelloPlugin);
  RegisterCommand('hello:greet', 'say hello from the plugin', @GreetCommand, False);

end.
