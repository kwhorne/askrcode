{ Askr.Cli.Docs — reading the shipped documentation.

  WHICH DOCS

  The caller passes the directory. That is not indirection for its own sake:
  the docs an agent reads have to be the docs for the version the project
  builds against, which is whatever `ResolveFramework` resolved — a local
  checkout during framework development, or `~/.askr/pkg/<version>` for a
  pinned release. Docs compiled into the tool, or fetched from a website,
  would drift from the binary being built the moment a project pins an older
  release, and an agent would then be confidently wrong about the framework
  in front of it.

  THE SEARCH IS AN EXACT SUBSTRING, AND THAT IS THE WHOLE POINT

  It is deliberately not fuzzy, not stemmed and not edit-distance. An agent
  asking about `Back.WithErrors` is asking about something that does not
  exist — the name is `BackWithErrors`, and that exact mistake is in this
  repository's history, in the first draft of docs/. A search that strips
  punctuation would match it against the real name and hand back a page that
  looks like confirmation. The agent would then write the wrong call, and
  the only thing that ever said otherwise was the compiler.

  So: no match means no match, and the tool says so. The same rule as
  elsewhere here — a gate that does not exist answers no. Near-miss
  suggestions were considered and left out; a suggestion is the fuzzy match
  with a disclaimer on it, and disclaimers are the part that gets skipped.

  PAGE NAMES ARE NEVER USED TO BUILD A PATH

  The page an agent asks for is text an agent wrote. It is matched against
  the listing of what is actually in the directory, and only a name that
  came back from that listing is ever opened. Composing a path from the
  input and then checking it for `..` is the version of this that has a bug
  in it. }
unit Askr.Cli.Docs;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes;

type
  TDocPages = array of string;

  TDocHit = record
    { The page as the docs refer to each other: `validation.md`. }
    Page: string;
    Line: Integer;               { 1-based }
    { The nearest `## ` above the hit, empty above the first one. It is what
      `DocRead` takes as its Section, so a hit is directly followable. }
    Heading: string;
    Text_: string;               { the line, trimmed }
  end;

  TDocHits = array of TDocHit;

{ Every `*.md` in Dir, sorted, file names as they are. Empty when the
  directory is not there. }
function DocPages(const Dir: string): TDocPages;

{ Case-insensitive substring search across every page. Stops at Limit hits;
  TotalHits says how many there were, so the caller can say that it
  truncated rather than quietly showing part of the answer. }
function DocSearch(const Dir, Query: string; Limit: Integer;
  out TotalHits: Integer): TDocHits;

{ A whole page, or one `## ` section of it.

  Page may be given with or without the `.md`, and case does not matter —
  an agent that read `see [Sessions](sessions.md)` and one that read
  `## Sessions` should both land. Section is matched against the heading
  text without the `## `.

  False when the page or the section is not there; Err then says which of
  the two and lists what there is. }
function DocRead(const Dir, Page, Section: string;
  out Text_, Err: string): Boolean;

{ The `## ` headings of a page, in order. Empty when the page is not
  there. }
function DocSections(const Dir, Page: string): TDocPages;

type
  { One tree of docs: the framework's, with no prefix, or a plugin's, whose
    pages are named with its name in front -- stripe/billing.md. }
  TDocSource = record
    Prefix: string;
    Dir: string;
  end;
  TDocSources = array of TDocSource;

{ Every page of every source, with its prefix. }
function SourcePages(const Sources: TDocSources): TDocPages;
{ DocSearch across the sources, pages named with their prefix. Limit and
  TotalHits count across all of them. }
function SourceSearch(const Sources: TDocSources; const Query: string;
  Limit: Integer; out TotalHits: Integer): TDocHits;
{ DocRead, with the page resolved to its source by prefix. The prefix is
  matched against the sources' own, and the rest against that source's
  listing: a page name still never builds a path. }
function SourceRead(const Sources: TDocSources; const Page, Section: string;
  out Text_, Err: string): Boolean;

implementation

function DocPages(const Dir: string): TDocPages;
var
  R: TSearchRec;
  L: TStringList;
  I: Integer;
  Out_: TDocPages;
begin
  Out_ := nil;
  if DirectoryExists(Dir) then
  begin
    L := TStringList.Create;
    try
      if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*.md',
                   faAnyFile, R) = 0 then
      begin
        repeat
          if (R.Attr and faDirectory) = 0 then
            L.Add(R.Name);
        until FindNext(R) <> 0;
        FindClose(R);
      end;
      L.Sort;
      SetLength(Out_, L.Count);
      for I := 0 to L.Count - 1 do
        Out_[I] := L[I];
    finally
      L.Free;
    end;
  end;
  Result := Out_;
end;

{ The one place a page name turns into a file. Returns '' when the name is
  not one of the pages that are actually there, which is also what keeps a
  name like `../../etc/passwd` from ever reaching the filesystem: it will
  not equal any entry in the listing. }
function ResolvePage(const Dir, Page: string): string;
var
  Pages: TDocPages;
  I: Integer;
  Want: string;
begin
  Result := '';
  Want := LowerCase(Trim(Page));
  if Want = '' then
    Exit;
  if ExtractFileExt(Want) <> '.md' then
    Want := Want + '.md';
  Pages := DocPages(Dir);
  for I := 0 to High(Pages) do
    if LowerCase(Pages[I]) = Want then
      Exit(Pages[I]);
end;

function LoadPage(const Dir, FileName_: string): TStringList;
begin
  Result := TStringList.Create;
  try
    Result.LoadFromFile(IncludeTrailingPathDelimiter(Dir) + FileName_);
  except
    Result.Free;
    raise;
  end;
end;

{ '## Across a redirect' -> 'Across a redirect'. Only level two: the title
  is level one and there is exactly one of it, and level three is detail
  inside a section rather than a place to jump to. }
function HeadingOf(const Line_: string): string;
begin
  Result := '';
  if (Length(Line_) > 3) and (Copy(Line_, 1, 3) = '## ') then
    Result := Trim(Copy(Line_, 4, MaxInt));
end;

function DocSections(const Dir, Page: string): TDocPages;
var
  FileName_, H: string;
  L: TStringList;
  I, N: Integer;
  Out_: TDocPages;
begin
  Out_ := nil;
  N := 0;
  FileName_ := ResolvePage(Dir, Page);
  if FileName_ <> '' then
  begin
    L := LoadPage(Dir, FileName_);
    try
      for I := 0 to L.Count - 1 do
      begin
        H := HeadingOf(L[I]);
        if H <> '' then
        begin
          if N = Length(Out_) then
            SetLength(Out_, (N + 1) * 2);
          Out_[N] := H;
          Inc(N);
        end;
      end;
    finally
      L.Free;
    end;
  end;
  SetLength(Out_, N);
  Result := Out_;
end;

function DocSearch(const Dir, Query: string; Limit: Integer;
  out TotalHits: Integer): TDocHits;
var
  Pages: TDocPages;
  L: TStringList;
  I, J, N: Integer;
  Needle, Heading, H: string;
  Out_: TDocHits;
begin
  Out_ := nil;
  N := 0;
  TotalHits := 0;
  Needle := LowerCase(Query);
  if Needle = '' then
  begin
    Result := Out_;
    Exit;
  end;

  Pages := DocPages(Dir);
  for I := 0 to High(Pages) do
  begin
    L := LoadPage(Dir, Pages[I]);
    try
      Heading := '';
      for J := 0 to L.Count - 1 do
      begin
        H := HeadingOf(L[J]);
        if H <> '' then
          Heading := H;
        if Pos(Needle, LowerCase(L[J])) = 0 then
          Continue;
        Inc(TotalHits);
        { Counting past the limit rather than stopping: a caller that says
          "3 of 47" is telling the truth, and one that says "3" while
          quietly holding 44 more is not. }
        if (Limit > 0) and (N >= Limit) then
          Continue;
        if N = Length(Out_) then
          SetLength(Out_, (N + 1) * 2);
        Out_[N].Page := Pages[I];
        Out_[N].Line := J + 1;
        Out_[N].Heading := Heading;
        Out_[N].Text_ := Trim(L[J]);
        Inc(N);
      end;
    finally
      L.Free;
    end;
  end;

  SetLength(Out_, N);
  Result := Out_;
end;

function JoinPages(const Pages: TDocPages): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Pages) do
  begin
    if I > 0 then
      Result := Result + ', ';
    Result := Result + Pages[I];
  end;
end;

function SourcePages(const Sources: TDocSources): TDocPages;
var
  I, J, N: Integer;
  Pages: TDocPages;
begin
  Result := nil;
  for I := 0 to High(Sources) do
  begin
    Pages := DocPages(Sources[I].Dir);
    N := Length(Result);
    SetLength(Result, N + Length(Pages));
    for J := 0 to High(Pages) do
      Result[N + J] := Sources[I].Prefix + Pages[J];
  end;
end;

function SourceSearch(const Sources: TDocSources; const Query: string;
  Limit: Integer; out TotalHits: Integer): TDocHits;
var
  I, J, N, Total: Integer;
  Hits: TDocHits;
begin
  Result := nil;
  TotalHits := 0;
  for I := 0 to High(Sources) do
  begin
    Hits := DocSearch(Sources[I].Dir, Query, 0, Total);
    Inc(TotalHits, Total);
    for J := 0 to High(Hits) do
    begin
      if (Limit > 0) and (Length(Result) >= Limit) then
        Break;
      N := Length(Result);
      SetLength(Result, N + 1);
      Result[N] := Hits[J];
      Result[N].Page := Sources[I].Prefix + Hits[J].Page;
    end;
  end;
end;

function SourceRead(const Sources: TDocSources; const Page, Section: string;
  out Text_, Err: string): Boolean;
var
  I: Integer;
  Want: string;
begin
  Text_ := '';
  Err := '';
  Want := Trim(Page);
  for I := 0 to High(Sources) do
    if (Sources[I].Prefix <> '') and
       (LowerCase(Copy(Want, 1, Length(Sources[I].Prefix))) = LowerCase(Sources[I].Prefix)) then
      Exit(DocRead(Sources[I].Dir, Copy(Want, Length(Sources[I].Prefix) + 1, MaxInt),
        Section, Text_, Err));
  for I := 0 to High(Sources) do
    if (Sources[I].Prefix = '') and (Pos('/', Want) = 0) then
      Exit(DocRead(Sources[I].Dir, Want, Section, Text_, Err));
  Err := 'No page named "' + Page + '". The pages are: ' + JoinPages(SourcePages(Sources));
  Result := False;
end;

function DocRead(const Dir, Page, Section: string;
  out Text_, Err: string): Boolean;
var
  FileName_, H: string;
  L, Out_: TStringList;
  I: Integer;
  Inside: Boolean;
begin
  Result := False;
  Text_ := '';
  Err := '';

  FileName_ := ResolvePage(Dir, Page);
  if FileName_ = '' then
  begin
    Err := 'No page named "' + Page + '". The pages are: ' +
           JoinPages(DocPages(Dir));
    Exit;
  end;

  L := LoadPage(Dir, FileName_);
  try
    if Trim(Section) = '' then
    begin
      Text_ := L.Text;
      Exit(True);
    end;

    Out_ := TStringList.Create;
    try
      Inside := False;
      for I := 0 to L.Count - 1 do
      begin
        H := HeadingOf(L[I]);
        if H <> '' then
        begin
          { The next heading of the same level ends the section. }
          if Inside then
            Break;
          Inside := SameText(H, Trim(Section));
          if not Inside then
            Continue;
        end;
        if Inside then
          Out_.Add(L[I]);
      end;
      if not Inside then
      begin
        Err := 'No section "' + Section + '" in ' + FileName_ +
               '. Its sections are: ' + JoinPages(DocSections(Dir, Page));
        Exit;
      end;
      Text_ := Out_.Text;
      Result := True;
    finally
      Out_.Free;
    end;
  finally
    L.Free;
  end;
end;

end.
