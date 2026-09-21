{ Askr.Cli.Watch — ser etter endringer i kildefiler.

  Pollet, ikke hendelsesdrevet. FSEvents på macOS og inotify på Linux er
  raskere å våkne på, men de er to ulike API-er med hver sine særheter, og
  en full skanning av noen hundre filer koster under en millisekund. Ved 25 ms
  intervall er deteksjonen dyrere enn den trenger å være med rundt tolv
  millisekunder i snitt — men det er en tolvtedel av budsjettet, og det er
  billig nok til at kompleksiteten ikke er verdt det.

  Blir prosjektene store nok til at skanningen merkes, er det da man bytter.
  Ikke før. }
unit Askr.Cli.Watch;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, BaseUnix;

type
  TWatchKind = (wkNone, wkBackend, wkFrontend);

  TWatcher = class
  private
    FRoots: TStringList;
    FExtensions: TStringList;
    FFrontendExts: TStringList;
    FSeen: TStringList;      { sti -> mtime som streng }
    FIgnore: TStringList;
    function ShouldIgnore(const Dir: string): Boolean;
    function KindFor(const Path: string): TWatchKind;
    procedure Scan(const Dir: string; Found: TStringList);
  public
    constructor Create;
    destructor Destroy; override;
    procedure AddRoot(const Dir: string);
    { Filendelser som utløser en rebuild av backend. }
    procedure AddBackendExt(const Ext: string);
    { Endelser som Vite håndterer selv; de skal ikke utløse rebuild. }
    procedure AddFrontendExt(const Ext: string);
    procedure IgnoreDir(const Name: string);

    { Leser inn nåtilstanden uten å rapportere endringer. }
    procedure Prime;
    { What som har endret seg siden forrige kall. ChangedPath settes til den
      første fila som utløste det. }
    function Poll(out ChangedPath: string): TWatchKind;
    function FileCount: Integer;
  end;

{ Filas mtime i millisekunder siden epoch. Brukes til å måle hele
  utviklerløkka fra lagringsøyeblikket, ikke fra da pollingen oppdaget den. }
function FileMtimeMs(const Path: string): Int64;

implementation

function FileMtimeMs(const Path: string): Int64;
var
  St: TStat;
begin
  if fpStat(Path, St) <> 0 then
    Exit(0);
{$IFDEF DARWIN}
  Result := Int64(St.st_mtime) * 1000 + St.st_mtimensec div 1000000;
{$ELSE}
  Result := Int64(St.st_mtime) * 1000 + St.st_mtime_nsec div 1000000;
{$ENDIF}
end;

constructor TWatcher.Create;
begin
  inherited Create;
  FRoots := TStringList.Create;
  FExtensions := TStringList.Create;
  FFrontendExts := TStringList.Create;
  FIgnore := TStringList.Create;
  FSeen := TStringList.Create;
  { Sortert for oppslag i O(log n): en full skanning hvert 25. millisekund
    tåler ikke lineære søk per fil. Stempelet lagres som en hash i Objects,
    fordi Values og ValueFromIndex ikke er lov på en sortert liste. }
  FSeen.Sorted := True;
  FSeen.Duplicates := dupIgnore;
end;

destructor TWatcher.Destroy;
begin
  FRoots.Free;
  FExtensions.Free;
  FFrontendExts.Free;
  FIgnore.Free;
  FSeen.Free;
  inherited Destroy;
end;

procedure TWatcher.AddRoot(const Dir: string);
begin
  if DirectoryExists(Dir) then
    FRoots.Add(ExcludeTrailingPathDelimiter(ExpandFileName(Dir)));
end;

procedure TWatcher.AddBackendExt(const Ext: string);
begin
  FExtensions.Add(LowerCase(Ext));
end;

procedure TWatcher.AddFrontendExt(const Ext: string);
begin
  FFrontendExts.Add(LowerCase(Ext));
end;

procedure TWatcher.IgnoreDir(const Name: string);
begin
  FIgnore.Add(LowerCase(Name));
end;

function TWatcher.ShouldIgnore(const Dir: string): Boolean;
var
  Name_: string;
  I: Integer;
begin
  Name_ := LowerCase(ExtractFileName(ExcludeTrailingPathDelimiter(Dir)));
  if (Name_ = '') or (Name_[1] = '.') then
    Exit(True);
  for I := 0 to FIgnore.Count - 1 do
    if FIgnore[I] = Name_ then
      Exit(True);
  Result := False;
end;

function TWatcher.KindFor(const Path: string): TWatchKind;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(Path));
  if FExtensions.IndexOf(Ext) >= 0 then
    Exit(wkBackend);
  if FFrontendExts.IndexOf(Ext) >= 0 then
    Exit(wkFrontend);
  Result := wkNone;
end;

procedure TWatcher.Scan(const Dir: string; Found: TStringList);
var
  Rec: TSearchRec;
  Full: string;
begin
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, Rec) <> 0 then
    Exit;
  try
    repeat
      if (Rec.Name = '.') or (Rec.Name = '..') then
        Continue;
      Full := IncludeTrailingPathDelimiter(Dir) + Rec.Name;
      if (Rec.Attr and faDirectory) <> 0 then
      begin
        if not ShouldIgnore(Full) then
          Scan(Full, Found);
        Continue;
      end;
      if KindFor(Rec.Name) = wkNone then
        Continue;
      Found.Add(Full);
    until FindNext(Rec) <> 0;
  finally
    FindClose(Rec);
  end;
end;

{ Nanosekunder, ikke sekunder. TSearchRec.TimeStamp og FileAge har begge
  bare sekundoppløsning, og to lagringer innenfor samme sekund er helt
  vanlig når man jobber fort. fpStat gir nanosekunder på både macOS og
  Linux — bare under ulike feltnavn. }
function StampOf(const Path: string): string;
var
  St: TStat;
begin
  if fpStat(Path, St) <> 0 then
    Exit('');
{$IFDEF DARWIN}
  Result := IntToStr(St.st_mtime) + '.' + IntToStr(St.st_mtimensec) +
    ':' + IntToStr(St.st_size);
{$ELSE}
  Result := IntToStr(St.st_mtime) + '.' + IntToStr(St.st_mtime_nsec) +
    ':' + IntToStr(St.st_size);
{$ENDIF}
end;

procedure TWatcher.Prime;
var
  Dummy: string;
begin
  FSeen.Clear;
  Poll(Dummy);
end;

{ FNV-1a over stempelet. Kollisjon ville betydd en tapt endring, men et
  64-bits utfall gjør det usannsynlig nok til at alternativet — en egen
  strengliste å holde i synk — ikke er verdt det. }
{ FNV-1a er tuftet på at multiplikasjonen flyter over og brytes modulo
  ordstørrelsen — det er ikke et uhell, det er algoritmen. Bygger noen med
  -Cr eller -Co, som er helt rimelig i en debug-bygging, blir den tilsiktede
  wraparounden til en ERangeError. Avhengigheten står derfor her i stedet for
  å være stilltiende. }
{$push}{$R-}{$Q-}
function HashStamp(const S: string): PtrInt;
var
  H: QWord;
  I: Integer;
begin
  H := QWord(14695981039346656037);
  for I := 1 to Length(S) do
  begin
    H := H xor QWord(Ord(S[I]));
    H := H * QWord(1099511628211);
  end;
  Result := PtrInt(H and High(PtrInt));
end;
{$pop}

function TWatcher.Poll(out ChangedPath: string): TWatchKind;
var
  Found: TStringList;
  I, Idx: Integer;
  Stamp, Path: string;
  Hash: PtrInt;
  Changed: TWatchKind;
begin
  Result := wkNone;
  ChangedPath := '';
  Found := TStringList.Create;
  try
    for I := 0 to FRoots.Count - 1 do
      Scan(FRoots[I], Found);

    for I := 0 to Found.Count - 1 do
    begin
      Path := Found[I];
      Stamp := StampOf(Path);
      Hash := HashStamp(Stamp);
      Idx := FSeen.IndexOf(Path);
      if Idx < 0 then
      begin
        FSeen.AddObject(Path, TObject(Hash));
        { En ny fil er en endring, men ikke under Prime — da er FSeen tom og
          alt er nytt. Kalleren bruker Prime nettopp for å svelge det. }
        if Result = wkNone then
        begin
          Changed := KindFor(Path);
          if Changed <> wkNone then
          begin
            Result := Changed;
            ChangedPath := Path;
          end;
        end;
      end
      else if PtrInt(FSeen.Objects[Idx]) <> Hash then
      begin
        { Objects kan settes på en sortert liste; det er bare strengene som
          ikke kan røres. }
        FSeen.Objects[Idx] := TObject(Hash);
        Changed := KindFor(Path);
        { Backend vinner: en runde som rører både Pascal og Svelte skal
          bygge på nytt, ikke bare la Vite oppdatere. }
        if (Result = wkNone) or (Changed = wkBackend) then
        begin
          Result := Changed;
          ChangedPath := Path;
        end;
      end;
    end;
  finally
    Found.Free;
  end;
end;

function TWatcher.FileCount: Integer;
begin
  Result := FSeen.Count;
end;

end.
