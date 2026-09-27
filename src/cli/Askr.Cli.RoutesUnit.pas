{ Askr.Cli.RoutesUnit -- the routes as functions the compiler checks.

      askr routes:gen      writes app/App.Routes.pas from the routes
      askr routes:check    exits 1 when that file no longer matches them

  Each pattern becomes one function that gives its path:

      Result := InertiaRedirect(GadgetsIdEditPath(M.Id));   // /gadgets/7/edit

  Remove the route and generate again, and every place that used the
  function no longer compiles. That is Phoenix's verified routes, done by
  the compiler: a link to a page that is gone is a build error at the line
  that has it, not a 404 somebody finds.

  **A route's name is the function's name.** R.AsName('docs.show') gives
  DocsShowPath. A route with no name is named after its pattern, its
  static segments and its parameters: /gadgets/:id/edit gives
  GadgetsIdEditPath, and / gives RootPath. When two patterns would share a
  name, the one that sorts later gets a number.

  **One function per pattern, not per route.** GET and PATCH on
  /gadgets/:id are one path. A parameter is a string; where it is called
  id or ends in _id, there is an Int64 overload as well.

  The text depends on the routes and nothing else -- no date, no version
  -- so generating twice gives the same file, and routes:check compares
  text. }
unit Askr.Cli.RoutesUnit;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, Askr.Http.Router;

const
  RoutesUnitPath = 'app/App.Routes.pas';

{ The whole of App.Routes, for the routes R has. }
function RoutesUnitText(R: TRouter): string;

{ The function names in a text RoutesUnitText wrote, in order. For
  routes:check, to say what was added and what went. }
function RoutesUnitFunctions(const Text: string): TStringArray;

implementation

uses
  Askr.Norn.Codegen;

type
  TPathFunc = record
    Name: string;
    Pattern: string;
    Params: TStringArray;
  end;

function Capitalised(const S: string): string;
var
  I: Integer;
  Up: Boolean;
begin
  Result := '';
  Up := True;
  for I := 1 to Length(S) do
    if S[I] in ['A'..'Z', 'a'..'z', '0'..'9'] then
    begin
      if Up then
        Result := Result + UpCase(S[I])
      else
        Result := Result + S[I];
      Up := False;
    end
    else
      Up := True;
end;

{ Letters and digits, and not starting with a digit. }
function Ident(const S: string): string;
begin
  Result := Capitalised(S);
  if (Result <> '') and (Result[1] in ['0'..'9']) then
    Result := 'P' + Result;
end;

function IsIdParam(const Name: string): Boolean;
begin
  Result := (LowerCase(Name) = 'id') or
    ((Length(Name) > 3) and (LowerCase(Copy(Name, Length(Name) - 2, 3)) = '_id'));
end;

function NameFromPattern(Route: TRoute): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to Route.SegmentCount - 1 do
    Result := Result + Ident(Route.SegmentAt(I).Text);
  if Result = '' then
    Result := 'Root';
end;

function Collect(R: TRouter): TArray<TPathFunc>;
var
  I, J, K: Integer;
  Route: TRoute;
  Found: Boolean;
  Base, Name: string;
  Seg: TSegment;
  T: TPathFunc;
  Taken: TStringList;
  FromName: TArray<Boolean>;
  B: Boolean;
begin
  Result := nil;
  FromName := nil;
  for I := 0 to R.Count - 1 do
  begin
    Route := R.RouteAt(I);
    Found := False;
    for J := 0 to High(Result) do
      if Result[J].Pattern = Route.Pattern then
      begin
        { A name on any route of the pattern names it. }
        if (Route.Name <> '') and not FromName[J] then
        begin
          Result[J].Name := Ident(Route.Name);
          FromName[J] := True;
        end;
        Found := True;
        Break;
      end;
    if Found then
      Continue;
    K := Length(Result);
    SetLength(Result, K + 1);
    SetLength(FromName, K + 1);
    Result[K].Pattern := Route.Pattern;
    Result[K].Params := nil;
    for J := 0 to Route.SegmentCount - 1 do
    begin
      Seg := Route.SegmentAt(J);
      if Seg.Kind in [skParam, skWildcard] then
      begin
        SetLength(Result[K].Params, Length(Result[K].Params) + 1);
        Result[K].Params[High(Result[K].Params)] := Seg.Text;
      end;
    end;
    FromName[K] := Route.Name <> '';
    if FromName[K] then
      Result[K].Name := Ident(Route.Name)
    else
      Result[K].Name := NameFromPattern(Route);
  end;

  { By pattern: a route added elsewhere moves nothing else in the file,
    and which of two clashing names gets the number does not depend on
    the order the routes were added in. }
  for I := 1 to High(Result) do
  begin
    J := I;
    while (J > 0) and (CompareStr(Result[J - 1].Pattern, Result[J].Pattern) > 0) do
    begin
      T := Result[J - 1];
      Result[J - 1] := Result[J];
      Result[J] := T;
      B := FromName[J - 1];
      FromName[J - 1] := FromName[J];
      FromName[J] := B;
      Dec(J);
    end;
  end;

  Taken := TStringList.Create;
  try
    { Pascal does not tell the two apart. }
    Taken.CaseSensitive := False;
    for I := 0 to High(Result) do
    begin
      Base := Result[I].Name;
      if Base = '' then
        Base := 'Unnamed';
      Name := Base;
      K := 2;
      while Taken.IndexOf(Name) >= 0 do
      begin
        Name := Base + IntToStr(K);
        Inc(K);
      end;
      Taken.Add(Name);
      Result[I].Name := Name + 'Path';
    end;
  finally
    Taken.Free;
  end;
end;

function PasQuote(const S: string): string;
begin
  Result := '''' + StringReplace(S, '''', '''''', [rfReplaceAll]) + '''';
end;

{ The parameter list, and the values FillRoute takes, for one overload. }
procedure Signature(const F: TPathFunc; Ints: Boolean;
  out Params, Values: string);
var
  I: Integer;
  P: string;
begin
  Params := '';
  Values := '';
  for I := 0 to High(F.Params) do
  begin
    P := Ident(F.Params[I]);
    if P = '' then
      P := 'Value' + IntToStr(I + 1);
    { :type is a keyword, and :result would hide the function's own. }
    if IsPascalKeyword(P) or SameText(P, 'Result') then
      P := P + '_';
    if Params <> '' then
    begin
      Params := Params + '; ';
      Values := Values + ', ';
    end;
    if Ints and IsIdParam(F.Params[I]) then
    begin
      Params := Params + P + ': Int64';
      Values := Values + 'IntToStr(' + P + ')';
    end
    else
    begin
      Params := Params + 'const ' + P + ': string';
      Values := Values + P;
    end;
  end;
end;

function HasIdParam(const F: TPathFunc): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(F.Params) do
    if IsIdParam(F.Params[I]) then
      Exit(True);
  Result := False;
end;

function Header(const F: TPathFunc; Ints: Boolean): string;
var
  Params, Values: string;
begin
  Signature(F, Ints, Params, Values);
  Result := 'function ' + F.Name;
  if Params <> '' then
    Result := Result + '(' + Params + ')';
  Result := Result + ': string;';
  if HasIdParam(F) then
    Result := Result + ' overload;';
end;

function RoutesUnitText(R: TRouter): string;
var
  Fs: TArray<TPathFunc>;
  L: TStringList;
  I: Integer;
  Params, Values: string;

  procedure A(const S: string);
  begin
    L.Add(S);
  end;

  procedure Body(const F: TPathFunc; Ints: Boolean);
  begin
    Signature(F, Ints, Params, Values);
    A(Header(F, Ints));
    A('begin');
    A('  Result := FillRoute(' + PasQuote(F.Pattern) + ', [' + Values + ']);');
    A('end;');
    A('');
  end;

begin
  Fs := Collect(R);
  L := TStringList.Create;
  try
    L.LineBreak := #10;
    A('{ App.Routes -- written by askr routes:gen from the routes the app');
    A('  registers. Do not edit it: change the routes and run askr routes:gen');
    A('  again. askr routes:check exits 1 when it no longer matches them.');
    A('');
    A('  A route that is removed takes its function with it, and whatever');
    A('  used the function stops compiling at the line that used it. }');
    A('unit App.Routes;');
    A('');
    A('{$mode Delphi}{$H+}');
    A('');
    A('interface');
    A('');
    for I := 0 to High(Fs) do
    begin
      A('// ' + Fs[I].Pattern);
      A(Header(Fs[I], False));
      if HasIdParam(Fs[I]) then
        A(Header(Fs[I], True));
    end;
    A('');
    A('implementation');
    A('');
    A('uses');
    if Length(Fs) > 0 then
      A('  SysUtils, Askr.Http.Router;')
    else
      A('  SysUtils;');
    A('');
    for I := 0 to High(Fs) do
    begin
      Body(Fs[I], False);
      if HasIdParam(Fs[I]) then
        Body(Fs[I], True);
    end;
    A('end.');
    Result := L.Text;
  finally
    L.Free;
  end;
end;

function RoutesUnitFunctions(const Text: string): TStringArray;
var
  L: TStringList;
  I, P: Integer;
  S, Name: string;
begin
  Result := nil;
  L := TStringList.Create;
  try
    L.Text := Text;
    for I := 0 to L.Count - 1 do
    begin
      S := L[I];
      { The interface lists each once; the bodies say it again. }
      if S = 'implementation' then
        Break;
      if Copy(S, 1, 9) <> 'function ' then
        Continue;
      Name := Copy(S, 10, MaxInt);
      P := 1;
      while (P <= Length(Name)) and (Name[P] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) do
        Inc(P);
      Name := Copy(Name, 1, P - 1);
      if (Length(Result) = 0) or (Result[High(Result)] <> Name) then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Name;
      end;
    end;
  finally
    L.Free;
  end;
end;

end.
