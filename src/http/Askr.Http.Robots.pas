{ Askr.Http.Robots — what crawlers are told, and what the default has to be.

  A missing robots.txt does not mean "do not index". It means "index
  everything", because that is what a crawler assumes when it asks and gets
  a 404. So the dangerous state is not a wrong file — it is no file, on a
  staging site nobody thought about, and the first sign of it is the copy
  of your unreleased pages in somebody's search results.

  **So the default follows APP_ENV, and only production is open.** Anything
  else answers `Disallow: /`. `AppEnv` is `local` when nothing is set, so a
  server with no configuration at all is closed rather than open — the same
  rule as a gate that does not exist answering no.

  WHAT IT DOES NOT DECIDE

  It names no crawler. Whether GPTBot, ClaudeBot or PerplexityBot may read
  a site is a decision about that site, and a framework that shipped an
  opinion in the default would be making it for every application built on
  it, silently, in a file most people never open. An application that has
  decided writes `public/robots.txt`, which is served by the static files
  ahead of this and wins.

  Nothing here is enforcement. robots.txt is a request that well-behaved
  crawlers honour; it keeps nothing private. A page that must not be read
  needs a guard, not a line in a text file. }
unit Askr.Http.Robots;

{$mode Delphi}{$H+}

interface

uses
  SysUtils,
  Askr.Http.Request, Askr.Http.Response, Askr.Http.Router;

{ The body robots.txt would have right now. Exposed separately from the
  route so that a test, or a command, can ask without a server. }
function RobotsText: string;

{ Answers GET /robots.txt.

  Register it after the static files, so that an application's own
  `public/robots.txt` is found first and this never runs. }
procedure UseRobots(R: TRouter);

implementation

uses
  Askr.Core.Env, Askr.Core.Url;

function RobotsText: string;
var
  Sitemap: string;
begin
  if not IsProduction then
    { The environment is named on purpose. The question this file gets
      asked is "why is my site not being indexed", and the answer is
      usually that the environment is not what somebody thought it was. }
    Exit('# APP_ENV is "' + AppEnv + '", not production, so nothing here' +
      ' is offered for indexing.'#10 +
      '# The default in Askr is closed: a missing robots.txt means' +
      ' "index everything".'#10 +
      'User-agent: *'#10 +
      'Disallow: /'#10);

  { An empty Disallow is the long-standing way of saying "all of it".
    `Allow: /` says the same thing to most crawlers and less to the
    oldest ones. }
  Result := 'User-agent: *'#10 +
            'Disallow:'#10;

  { Only with an origin to write. Sitemap takes an absolute URL, and there
    is nowhere truthful to get one from without app.url -- not from the
    request, which is the whole argument in Askr.Core.Url. }
  Sitemap := AbsoluteUrl('/sitemap.xml');
  if Sitemap <> '' then
    Result := Result + #10 + 'Sitemap: ' + Sitemap + #10;
end;

function ServeRobots(Req: TRequest): TResponse;
begin
  Result := Respond(200)
    .WithContentType('text/plain; charset=utf-8')
    .WithBody(RobotsText)
    { Short, and not immutable: the file changes when the environment or
      the origin does, and a crawler that cached it for a year would
      outlive the mistake it was meant to fix. }
    .WithHeader('Cache-Control', 'public, max-age=3600');
end;

procedure UseRobots(R: TRouter);
begin
  R.Get('/robots.txt', @ServeRobots);
end;

end.
