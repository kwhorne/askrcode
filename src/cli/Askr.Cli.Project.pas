{ Askr.Cli.Project — finds and reads askr.toml.

  One file in the root says what the project is called and where things
  are. The format is the smallest thing that looks like TOML: key = value,
  one per line, sections in brackets. No tables, no arrays beyond
  comma-separated strings, no multi-line values. If more is needed, that is
  a sign the configuration has grown past what it ought to be. }
unit Askr.Cli.Project;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, Askr.Core.Config;

type
  TProject = class
  private
    FRoot: string;
    FValues: TStringList;
    function Get(const Key, Default: string): string;
  public
    constructor Create(const ARoot: string);
    destructor Destroy; override;

    { Looks upwards from Start for askr.toml. nil if there is none. }
    class function Find(const Start: string): TProject;

    function Name: string;
    function MainFile: string;
    { The main file for a desktop build. Empty when the project has no
      desktop shell. }
    function DesktopMainFile: string;
    { Testprogrammet. Standard er tests/app_tests.lpr. }
    function TestFile: string;
    function FrontendDir: string;
    function Port: Word;
    function BackendPort: Word;
    function Compiler: string;
    function CompilerFlags: string;
    { The framework's root, when the project points at a local checkout.
      Empty when the project pins a version instead. }
    function AskrPath: string;
    { The version the project asks for, from [askr] version. It can be an
      npm-shaped specification: 0.6.0, ^0.6.0, ~0.6.0. }
    function AskrWantedVersion: string;
    { Where versions are fetched from. The default is the public
      repository; a fork or a mirror is set with [askr] source. }
    function AskrSource: string;
    function UnitPaths: TStringArray;
    function WatchDirs: TStringArray;
    property Root: string read FRoot;
  end;

function SplitList(const S: string): TStringArray;

implementation

function SplitList(const S: string): TStringArray;
var
  L: TStringList;
  I: Integer;
begin
  Result := nil;
  L := TStringList.Create;
  try
    L.Delimiter := ',';
    L.StrictDelimiter := True;
    L.DelimitedText := S;
    SetLength(Result, 0);
    for I := 0 to L.Count - 1 do
      if Trim(L[I]) <> '' then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Trim(L[I]);
      end;
  finally
    L.Free;
  end;
end;

constructor TProject.Create(const ARoot: string);
begin
  inherited Create;
  FRoot := ExcludeTrailingPathDelimiter(ExpandFileName(ARoot));
  FValues := TStringList.Create;
  FValues.NameValueSeparator := '=';
  { The parser lives in Askr.Core.Config, and the app uses the same one.
    askr.toml must not be able to mean one thing for the CLI and something
    else for the app it builds. }
  ParseTomlInto(IncludeTrailingPathDelimiter(FRoot) + 'askr.toml', FValues);
end;

destructor TProject.Destroy;
begin
  FValues.Free;
  inherited Destroy;
end;

class function TProject.Find(const Start: string): TProject;
var
  Dir, Prev: string;
begin
  Dir := ExcludeTrailingPathDelimiter(ExpandFileName(Start));
  repeat
    if FileExists(IncludeTrailingPathDelimiter(Dir) + 'askr.toml') then
      Exit(TProject.Create(Dir));
    Prev := Dir;
    Dir := ExtractFileDir(Dir);
  until (Dir = Prev) or (Dir = '');
  Result := nil;
end;

function TProject.Get(const Key, Default: string): string;
begin
  Result := FValues.Values[Key];
  if Result = '' then
    Result := Default;
end;

function TProject.Name: string;
begin
  Result := Get('name', ExtractFileName(FRoot));
end;

function TProject.MainFile: string;
begin
  Result := Get('main', 'app.lpr');
end;

function TProject.DesktopMainFile: string;
begin
  Result := Get('main_desktop', '');
end;

function TProject.TestFile: string;
begin
  Result := Get('tests', 'tests/app_tests.lpr');
end;

function TProject.FrontendDir: string;
var
  D: string;
begin
  D := Get('frontend', 'frontend');
  if D = '' then
    Exit('');
  Result := IncludeTrailingPathDelimiter(FRoot) + D;
end;

{ The port is under [app] in new projects, so that the app can read it as
  app.port through Askr.Core.Config. The bare `port` at the top level is
  kept because projects made before the section existed still have it
  there. }
function TProject.Port: Word;
begin
  Result := Word(StrToIntDef(Get('app.port', Get('port', '8080')), 8080));
end;

function TProject.BackendPort: Word;
begin
  Result := Word(StrToIntDef(
    Get('app.backend_port', Get('backend_port', '8081')), 8081));
end;

function TProject.Compiler: string;
begin
  Result := Get('compiler', 'fpc');
end;

function TProject.CompilerFlags: string;
begin
  { -O1 in dev: -O2 costs more than it gives when the loop is measured in
    milliseconds. }
  Result := Get('flags', '-Sh -O1 -vw');
end;

function TProject.AskrPath: string;
begin
  { [askr] path wins. The old form — askr = "..." at the top level — is
    still read, because projects made before versioning existed are to keep
    building. }
  Result := Get('askr.path', '');
  if Result = '' then
    Result := Get('askr', '');
end;

function TProject.AskrWantedVersion: string;
begin
  Result := Get('askr.version', '');
end;

function TProject.AskrSource: string;
begin
  Result := Get('askr.source', 'https://github.com/kwhorne/askrcode.git');
end;

function TProject.UnitPaths: TStringArray;
begin
  Result := SplitList(Get('units', 'app,src'));
end;

function TProject.WatchDirs: TStringArray;
begin
  Result := SplitList(Get('watch', 'app,src,config,resources'));
end;

end.
