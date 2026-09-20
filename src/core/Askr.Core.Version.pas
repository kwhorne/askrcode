{ Askr.Core.Version — rammeverkets versjon, ett sted.

  Den lå før bare i cli/askr.lpr. Det holdt så lenge ingenting annet måtte
  vite hvilken versjon det kjørte, men i det øyeblikket et prosjekt kan
  pinne en versjon, må både verktøyet, rammeverket og npm-pakka si det
  samme. De gjorde ikke det: CLI-en sa 0.6.0 mens frontend/lauf/package.json
  sa 0.1.0, og ingenting sa fra. `askr_version_tests` holder dem i takt nå.

  Formatet er semver uten byggmetadata: MAJOR.MINOR.PATCH, eventuelt med
  en forhåndsutgivelse etter bindestrek. Sammenligningen er her fordi
  `askr outdated` må kunne rangere to versjoner uten å gjette. }
unit Askr.Core.Version;

{$mode Delphi}{$H+}

interface

uses
  SysUtils;

const
  { Endres denne, må frontend/lauf/package.json følge etter. Testen feiler
    ellers, og det er meningen: en utgivelse er ett tall over to
    økosystemer. }
  AskrVersion = '0.6.1';

type
  TSemVer = record
    Major, Minor, Patch: Integer;
    { Tom for en vanlig utgivelse. '0.7.0-rc.1' gir 'rc.1'. }
    Pre: string;
    Valid: Boolean;
  end;

{ Tåler 'v'-prefiks, slik at en git-tag kan sendes rett inn. }
function ParseSemVer(const S: string): TSemVer;

{ -1, 0 eller 1. En forhåndsutgivelse kommer FØR utgivelsen den peker mot:
  0.7.0-rc.1 < 0.7.0. Det er semver-regelen, og den er lett å bomme på. }
function CompareSemVer(const A, B: TSemVer): Integer; overload;
function CompareSemVer(const A, B: string): Integer; overload;

{ True når Have tilfredsstiller Want. Want kan være:
    '0.6.0'    nøyaktig
    '^0.6.0'   samme venstre-mest ikke-null ledd (npm-regelen)
    '~0.6.0'   samme major.minor
    '*'        hva som helst
  Formene er de samme som package.json bruker, med vilje: en bruker skal
  ikke måtte lære et nytt versjonsspråk for Pascal-halvdelen. }
function SatisfiesRange(const Have, Want: string): Boolean;

implementation

{ Math.CompareValue finnes, men å dra inn Math for tre linjer gir
  `IfThen`-tvetydigheten som allerede har kostet tid her. }
function Cmp(A, B: Integer): Integer;
begin
  if A < B then Result := -1
  else if A > B then Result := 1
  else Result := 0;
end;

function ParseSemVer(const S: string): TSemVer;
var
  T, Tall: string;
  I, Ledd: Integer;
  P: Integer;
begin
  Result.Major := 0; Result.Minor := 0; Result.Patch := 0;
  Result.Pre := ''; Result.Valid := False;

  T := Trim(S);
  if (T <> '') and ((T[1] = 'v') or (T[1] = 'V')) then
    System.Delete(T, 1, 1);
  if T = '' then
    Exit;

  { Forhåndsutgivelsen skilles av først, ellers ville '0-rc' gjort
    StrToInt til en exception i stedet for en ugyldig versjon. }
  P := Pos('-', T);
  if P > 0 then
  begin
    Result.Pre := Copy(T, P + 1, Length(T));
    T := Copy(T, 1, P - 1);
  end;

  Ledd := 0;
  Tall := '';
  for I := 1 to Length(T) + 1 do
  begin
    if (I <= Length(T)) and (T[I] in ['0'..'9']) then
      Tall := Tall + T[I]
    else if (I > Length(T)) or (T[I] = '.') then
    begin
      if Tall = '' then
        Exit;
      case Ledd of
        0: Result.Major := StrToIntDef(Tall, -1);
        1: Result.Minor := StrToIntDef(Tall, -1);
        2: Result.Patch := StrToIntDef(Tall, -1);
      else
        Exit;   { fire ledd er ikke semver }
      end;
      Inc(Ledd);
      Tall := '';
    end
    else
      Exit;     { noe annet enn siffer og punktum }
  end;

  if Ledd < 1 then
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

  { Like tall. Den med forhåndsutgivelse er den minste — 0.7.0-rc.1
    kommer før 0.7.0, ikke etter. }
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
    { npm-regelen: ^0.6.0 låser minor så lenge major er 0, fordi et
      nullmajor-prosjekt bryter ting i minor. ^1.2.0 låser bare major. }
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
