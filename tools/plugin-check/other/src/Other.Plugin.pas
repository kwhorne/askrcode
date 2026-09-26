{ Claims a table the hello fixture owns, so the build has something to
  refuse. }
unit Other.Plugin;

{$mode Delphi}{$H+}

interface

implementation

uses
  Askr.Plugins;

type
  TOtherPlugin = class(TPlugin)
  public
    function Name: string; override;
  end;

function TOtherPlugin.Name: string;
begin
  Result := 'other';
end;

initialization
  RegisterPlugin(TOtherPlugin);

end.
