{ Askr.Core.Version — the framework's version, in one place.

  It used to live only in cli/askr.lpr. That held as long as nothing else
  had to know which version it was running, but the moment a project can
  pin a version, the tool, the framework and the npm package all have to
  say the same thing. They did not: the CLI said 0.6.0 while
  frontend/lauf/package.json said 0.1.0, and nothing said so. The version
  test keeps them in step now.

  The format is semver without build metadata: MAJOR.MINOR.PATCH,
  optionally with a prerelease after a hyphen. The comparison lives here
  because `askr outdated` has to rank two versions without guessing. }
unit Askr.Core.Version;

{$mode Delphi}{$H+}

interface

uses
  SysUtils;

const
  { Change this and frontend/lauf/package.json has to follow. The test
    fails otherwise, and that is the point: one release is one number
    across two ecosystems. }
  AskrVersion = '0.8.1';

type
  TSemVer = record
    Major, Minor, Patch: Integer;
    { Tom for en vanlig utgivelse. '0.7.0-rc.1' gir 'rc.1'. }
    Pre: string;
    Valid: Boolean;
  end;

{ Tolerates a 'v' prefix, so a git tag can be passed straight in. }
function ParseSemVer(const S: string): TSemVer;

{ -1, 0 or 1. A prerelease comes BEFORE the release it points at:
  0.7.0-rc.1 < 0.7.0. That is the semver rule, and it is easy to get
  wrong. }
function CompareSemVer(const A, B: TSemVer): Integer; overload;
function CompareSemVer(const A, B: string): Integer; overload;

{ True when Have satisfies Want. Want may be:
  '0.6.0'    exactly
  '^0.6.0'   same left-most non-zero component (the npm rule)
  '~0.6.0'   same major.minor
  '*'        anything
  The forms are the ones package.json uses, deliberately: nobody should
  have to learn a second version language for the Pascal half. }
function SatisfiesRange(const Have, Want: string): Boolean;

implementation

{ Math.CompareValue exists, but pulling Math in for three lines brings
  the `IfThen` ambiguity that has already cost time here. }
function Cmp(A, B: Integer): Integer;
begin
  if A < B then Result := -1
  else if A > B then Result := 1
  else Result := 0;
end;

function ParseSemVer(const S: string): TSemVer;
var
  T, Number: string;
  I, Clause: Integer;
  P: Integer;
begin
  Result.Major := 0; Result.Minor := 0; Result.Patch := 0;
  Result.Pre := ''; Result.Valid := False;

  T := Trim(S);
  if (T <> '') and ((T[1] = 'v') or (T[1] = 'V')) then
    System.Delete(T, 1, 1);
  if T = '' then
    Exit;

  { The prerelease is split off first, or '0-rc' would turn StrToInt into
    an exception rather than an invalid version. }
  P := Pos('-', T);
  if P > 0 then
  begin
    Result.Pre := Copy(T, P + 1, Length(T));
    T := Copy(T, 1, P - 1);
  end;

  Clause := 0;
  Number := '';
  for I := 1 to Length(T) + 1 do
  begin
    if (I <= Length(T)) and (T[I] in ['0'..'9']) then
      Number := Number + T[I]
    else if (I > Length(T)) or (T[I] = '.') then
    begin
      if Number = '' then
        Exit;
      case Clause of
        0: Result.Major := StrToIntDef(Number, -1);
        1: Result.Minor := StrToIntDef(Number, -1);
        2: Result.Patch := StrToIntDef(Number, -1);
      else
        Exit;   { fire ledd er ikke semver }
      end;
      Inc(Clause);
      Number := '';
    end
    else
      Exit;     { noe annet enn siffer og punktum }
  end;

  if Clause < 1 then
    Exit;
  if (Result.Major < 0) or (Result.Minor < 0) or (Result.Patch < 0) then
    Exit;
  Result.Valid := True;
end;

function CompareSemVer(const A, B: TSemVer): Integer;
begin
  if A.Major <> B.Major then
    Exit(Cmp(A.Major, B.Major));
  if A.Minor <> B.Minor then
    Exit(Cmp(A.Minor, B.Minor));
  if A.Patch <> B.Patch then
    Exit(Cmp(A.Patch, B.Patch));

  { Equal numbers. The one with a prerelease is the smaller — 0.7.0-rc.1
    comes before 0.7.0, not after. }
  if (A.Pre = '') and (B.Pre = '') then
    Exit(0);
  if A.Pre = '' then
    Exit(1);
  if B.Pre = '' then
    Exit(-1);
  Result := CompareStr(A.Pre, B.Pre);
  if Result < 0 then Result := -1
  else if Result > 0 then Result := 1;
end;

function CompareSemVer(const A, B: string): Integer;
begin
  Result := CompareSemVer(ParseSemVer(A), ParseSemVer(B));
end;

function SatisfiesRange(const Have, Want: string): Boolean;
var
  H, W: TSemVer;
  Spec: string;
begin
  Result := False;
  Spec := Trim(Want);
  if (Spec = '') or (Spec = '*') then
    Exit(True);

  H := ParseSemVer(Have);
  if not H.Valid then
    Exit;

  if Spec[1] = '^' then
  begin
    W := ParseSemVer(Copy(Spec, 2, Length(Spec)));
    if not W.Valid then Exit;
    if CompareSemVer(H, W) < 0 then Exit;
    { The npm rule: ^0.6.0 locks the minor while the major is 0, because a
      zero-major project breaks things in a minor. ^1.2.0 locks only the
      major. }
    if W.Major > 0 then
      Result := H.Major = W.Major
    else if W.Minor > 0 then
      Result := (H.Major = 0) and (H.Minor = W.Minor)
    else
      Result := (H.Major = 0) and (H.Minor = 0) and (H.Patch = W.Patch);
  end
  else if Spec[1] = '~' then
  begin
    W := ParseSemVer(Copy(Spec, 2, Length(Spec)));
    if not W.Valid then Exit;
    if CompareSemVer(H, W) < 0 then Exit;
    Result := (H.Major = W.Major) and (H.Minor = W.Minor);
  end
  else
  begin
    W := ParseSemVer(Spec);
    Result := W.Valid and (CompareSemVer(H, W) = 0);
  end;
end;

end.
