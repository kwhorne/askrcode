{ Askr.Cli.Watch — watches for changes in source files.

  Polled, not event driven. FSEvents on macOS and inotify on Linux are
  faster to wake on, but they are two different APIs each with their own
  quirks, and a full scan of a few hundred files costs under a millisecond.
  At a 25 ms interval the detection is more expensive than it needs to be,
  at around twelve milliseconds on average — but that is a twelfth of the
  budget, and it is cheap enough that the complexity is not worth it.

  If the projects grow big enough for the scan to be noticeable, that is
  when you switch. Not before. }
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
    { File extensions that trigger a rebuild of the backend. }
    procedure AddBackendExt(const Ext: string);
    { Extensions Vite handles itself; they must not trigger a rebuild. }
    procedure AddFrontendExt(const Ext: string);
    procedure IgnoreDir(const Name: string);

    { Reads in the current state without reporting changes. }
    procedure Prime;
    { What has changed since the previous call. ChangedPath is set to the
      first file that triggered it. }
    function Poll(out ChangedPath: string): TWatchKind;
    function FileCount: Integer;
  end;

{ The file's mtime in milliseconds since the epoch. Used to measure the
  whole developer loop from the moment of saving, not from when the polling
  noticed it. }
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
  { Sorted for O(log n) lookups: a full scan every 25 milliseconds cannot
    take a linear search per file. The stamp is stored as a hash in Objects,
    because Values and ValueFromIndex are not allowed on a sorted list. }
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

{ Nanoseconds, not seconds. TSearchRec.TimeStamp and FileAge both have
  only second resolution, and two saves within the same second are entirely
  normal when you work fast. fpStat gives nanoseconds on both macOS and
  Linux — only under different field names. }
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

{ FNV-1a over the stamp. A collision would have meant a lost change, but a
  64-bit result makes it unlikely enough that the alternative — a separate
  string list to keep in sync — is not worth it. }
{ FNV-1a is built on the multiplication overflowing and being cut modulo
  the word size — that is not an accident, that is the algorithm. If
  somebody builds with -Cr or -Co, which is entirely reasonable in a debug
  build, the intended wraparound becomes an ERangeError. The dependency is
  therefore written here rather than being tacit. }
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
        { A new file is a change, but not during Prime — then FSeen is empty
          and everything is new. The caller uses Prime precisely to swallow
          that. }
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
        { Objects can be set on a sorted list; it is only the strings that
          cannot be touched. }
        FSeen.Objects[Idx] := TObject(Hash);
        Changed := KindFor(Path);
        { The backend wins: a round that touches both Pascal and Svelte is to
          rebuild, not merely let Vite update. }
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
