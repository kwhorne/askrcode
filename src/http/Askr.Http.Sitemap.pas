{ Askr.Http.Sitemap — the list of pages, told to a crawler.

  WHAT THE FRAMEWORK KNOWS AND WHAT IT DOES NOT

  Askr knows the routes. It does not know which of them are public, and it
  cannot expand `/docs/:slug` into the pages that exist — that answer is in
  a database, or a directory, or a decision. Generating a sitemap from the
  route table would produce a list of patterns, which is not a list of
  pages, and would publish every admin route in it.

  So the application declares and the framework generates: correct XML,
  absolute URLs, the timestamp format the specification asks for, and the
  limits it imposes.

  THE LIMITS ARE NOT ADVICE

  A sitemap holds at most 50 000 URLs and 50 MB uncompressed. Over either,
  it is not a large sitemap — it is a rejected one, and a crawler that
  rejects it reads none of it. So the parts are split and an index is
  served in front of them, which is what the specification says to do.

  ESCAPING IS NOT OPTIONAL EITHER

  A `&` in a URL is the ordinary case — one query parameter is enough —
  and an unescaped one makes the whole document malformed, not just that
  entry. The test parses the output with a real XML parser rather than
  matching it against a pattern, for the same reason the markdown renderer
  is measured through the browser's own parser: a regular expression is
  what I imagine XML to be. }
unit Askr.Http.Sitemap;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes,
  Askr.Http.Request, Askr.Http.Response, Askr.Http.Router;

const
  { From the sitemap protocol. Both are hard limits, not guidance. }
  MaxSitemapUrls = 50000;
  MaxSitemapBytes = 50 * 1024 * 1024;

type
  ESitemapError = class(Exception);

  TSitemap = class
  private
    FLocs: TStringList;          { paths as given }
    FMods: array of TDateTime;   { 0 means no lastmod }
    FCount: Integer;
    function EntryXml(Index: Integer): string;
  public
    constructor Create;
    destructor Destroy; override;

    { A path on this site, as `/docs/queries`. Made absolute against
      app.url when the document is written, not here, so that a sitemap
      built at startup is still right if the origin is read later. }
    function Add(const Path_: string): TSitemap; overload;
    { With the time the page last changed. A lastmod that is really "now"
      on every build tells a crawler nothing except that you do not know,
      and it learns to ignore the field. Leave it out instead. }
    function Add(const Path_: string; LastMod: TDateTime): TSitemap; overload;

    { How many documents this becomes. One for anything that fits. }
    function PartCount: Integer;
    { Part N, 1-based. }
    function PartXml(N: Integer): string;
    { The index in front of the parts. Only meaningful when PartCount > 1. }
    function IndexXml: string;
    { What /sitemap.xml should answer with: the index when there is more
      than one part, the single part otherwise. }
    function RootXml: string;

    property Count: Integer read FCount;
  end;

  { Fills a sitemap. Called per request, so an application with pages in a
    database can answer with what is there now. }
  TSitemapSource = procedure(S: TSitemap);

{ Escapes text for XML content. Exposed because a caller building its own
  document should not have to write this again, and because getting it
  wrong makes the whole document malformed rather than one entry. }
function XmlEscape(const S: string): string;

{ W3C datetime in UTC, which is the format the sitemap protocol asks for:
  2026-09-22T10:30:00+00:00. }
function SitemapDate(D: TDateTime): string;

{ Serves /sitemap.xml, and /sitemap/N when there is more than one part.
  Register after the static files, so that a sitemap of your own wins. }
procedure UseSitemap(R: TRouter; Source: TSitemapSource);

implementation

uses
  DateUtils,
  Askr.Core.Url;

function XmlEscape(const S: string): string;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    case C of
      '&': Result := Result + '&amp;';
      '<': Result := Result + '&lt;';
      '>': Result := Result + '&gt;';
      '"': Result := Result + '&quot;';
      '''': Result := Result + '&apos;';
    else
      Result := Result + C;
    end;
  end;
end;

function SitemapDate(D: TDateTime): string;
begin
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', D) + '+00:00';
end;

constructor TSitemap.Create;
begin
  inherited Create;
  FLocs := TStringList.Create;
  FCount := 0;
end;

destructor TSitemap.Destroy;
begin
  FLocs.Free;
  inherited Destroy;
end;

function TSitemap.Add(const Path_: string): TSitemap;
begin
  Result := Add(Path_, 0);
end;

function TSitemap.Add(const Path_: string; LastMod: TDateTime): TSitemap;
begin
  Result := Self;
  if Trim(Path_) = '' then
    Exit;
  FLocs.Add(Path_);
  if Length(FMods) <= FCount then
    SetLength(FMods, (FCount + 1) * 2);
  FMods[FCount] := LastMod;
  Inc(FCount);
end;

function TSitemap.EntryXml(Index: Integer): string;
var
  Loc: string;
begin
  { Absolute, and from app.url. A sitemap of relative URLs is refused, and
    the only other source of an origin is the request -- which is the one
    place it must never come from. }
  Loc := AbsoluteUrlOrFail(FLocs[Index]);
  Result := '  <url>'#10 +
            '    <loc>' + XmlEscape(Loc) + '</loc>'#10;
  if FMods[Index] <> 0 then
    Result := Result +
            '    <lastmod>' + SitemapDate(FMods[Index]) + '</lastmod>'#10;
  Result := Result + '  </url>'#10;
end;

{ Split by count and by bytes both: 50 000 entries of ordinary length come
  to around 5 MB, so the byte limit only bites on URLs long enough that
  somebody has a different problem -- but a limit checked only when it
  seems likely to matter is not a limit. }
function TSitemap.PartCount: Integer;
var
  I, InPart: Integer;
  Bytes_: Int64;
  E: string;
begin
  Result := 1;
  InPart := 0;
  Bytes_ := 0;
  for I := 0 to FCount - 1 do
  begin
    E := EntryXml(I);
    if (InPart >= MaxSitemapUrls) or
       ((Bytes_ + Int64(Length(E)) > MaxSitemapBytes) and (InPart > 0)) then
    begin
      Inc(Result);
      InPart := 0;
      Bytes_ := 0;
    end;
    Inc(InPart);
    Inc(Bytes_, Length(E));
  end;
end;

function TSitemap.PartXml(N: Integer): string;
var
  I, InPart, Part: Integer;
  Bytes_: Int64;
  E: string;
  B: TStringList;
begin
  if N < 1 then
    raise ESitemapError.CreateFmt('There is no sitemap part %d.', [N]);

  B := TStringList.Create;
  try
    B.Add('<?xml version="1.0" encoding="UTF-8"?>');
    B.Add('<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">');

    Part := 1;
    InPart := 0;
    Bytes_ := 0;
    for I := 0 to FCount - 1 do
    begin
      E := EntryXml(I);
      if (InPart >= MaxSitemapUrls) or
         ((Bytes_ + Int64(Length(E)) > MaxSitemapBytes) and (InPart > 0)) then
      begin
        Inc(Part);
        InPart := 0;
        Bytes_ := 0;
      end;
      if Part = N then
        B.Add(TrimRight(E));
      Inc(InPart);
      Inc(Bytes_, Length(E));
    end;

    B.Add('</urlset>');
    Result := B.Text;
  finally
    B.Free;
  end;
end;

function TSitemap.IndexXml: string;
var
  I: Integer;
  B: TStringList;
begin
  B := TStringList.Create;
  try
    B.Add('<?xml version="1.0" encoding="UTF-8"?>');
    B.Add('<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">');
    for I := 1 to PartCount do
    begin
      B.Add('  <sitemap>');
      B.Add('    <loc>' +
        XmlEscape(AbsoluteUrlOrFail(Format('/sitemap/%d', [I]))) +
        '</loc>');
      B.Add('  </sitemap>');
    end;
    B.Add('</sitemapindex>');
    Result := B.Text;
  finally
    B.Free;
  end;
end;

function TSitemap.RootXml: string;
begin
  if PartCount > 1 then
    Result := IndexXml
  else
    Result := PartXml(1);
end;

{ ------------------------------------------------------------- routes -- }

var
  GSource: TSitemapSource = nil;

function BuildFor(const Path_: string): string;
var
  S: TSitemap;
  N: Integer;
  Rest: string;
begin
  if not Assigned(GSource) then
    raise ESitemapError.Create('UseSitemap was called without a source.');

  S := TSitemap.Create;
  try
    GSource(S);
    if Path_ = '/sitemap.xml' then
      Exit(S.RootXml);

    { /sitemap/3 -- the number comes from the path, so it is text a client
      wrote. Anything that is not a part that exists is a 404 rather than
      an empty document, which would look like a site with no pages. }
    Rest := Copy(Path_, Length('/sitemap/') + 1, MaxInt);
    N := StrToIntDef(Rest, 0);
    if (N < 1) or (N > S.PartCount) then
      Exit('');
    Result := S.PartXml(N);
  finally
    S.Free;
  end;
end;

function Serve(Req: TRequest): TResponse;
var
  Xml: string;
begin
  Xml := BuildFor(Req.Path.ToString);
  if Xml = '' then
    Exit(RespondText('Not Found', 404));
  Result := Respond(200)
    .WithContentType('application/xml; charset=utf-8')
    .WithBody(Xml);
end;

procedure UseSitemap(R: TRouter; Source: TSitemapSource);
begin
  GSource := Source;
  R.Get('/sitemap.xml', @Serve);
  { The parts are a pattern rather than one route each: how many there are
    depends on what the source returns, which is not known when the routes
    are registered.

    `/sitemap/1` and not `/sitemap-1.xml`, because a segment in this
    router is a parameter only when it starts with ':' -- and the shape
    does not reach a crawler anyway, which follows the absolute URLs the
    index gives it. }
  R.Get('/sitemap/:part', @Serve);
end;

end.
