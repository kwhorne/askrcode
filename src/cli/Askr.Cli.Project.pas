{ Askr.Cli.Project — finner og leser askr.toml.

  Én fil i rota sier hva prosjektet heter og hvor ting ligger. Formatet er
  det minste som ser ut som TOML: nøkkel = verdi, én per linje, seksjoner i
  klammer. Ingen tabeller, ingen arrays utover kommaseparerte strenger, ingen
  flerlinjes verdier. Trengs mer, er det et tegn på at konfigurasjonen har
  vokst forbi det den burde. }
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

    { Leter oppover fra Start etter askr.toml. nil hvis ingen finnes. }
    class function Find(const Start: string): TProject;

    function Name: string;
    function MainFile: string;
    { Hovedfila for et desktop-bygg. Tom når prosjektet ikke har noe
      desktop-skall. }
    function DesktopMainFile: string;
    { Testprogrammet. Standard er tests/app_tests.lpr. }
    function TestFile: string;
    function FrontendDir: string;
    function Port: Word;
    function BackendPort: Word;
    function Compiler: string;
    function CompilerFlags: string;
    { Rammeverkets rot. Unitene under src/ legges på søkestien. }
    function AskrPath: string;
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
  { Parseren ligger i Askr.Core.Config, og appen bruker den samme.
    askr.toml skal ikke kunne bety én ting for CLI-en og noe annet for
    appen den bygger. }
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

{ Porten står under [app] i nye prosjekter, slik at appen kan lese den som
  app.port gjennom Askr.Core.Config. Den bare `port` på toppnivå beholdes
  fordi prosjekter laget før seksjonen kom fortsatt har den der. }
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
  { -O1 i dev: -O2 koster mer enn det gir når løkka er målt i millisekunder. }
  Result := Get('flags', '-Sh -O1 -vw');
end;

function TProject.AskrPath: string;
begin
  Result := Get('askr', '');
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
