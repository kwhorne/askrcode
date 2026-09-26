{ Askr.Inertia — the Inertia protocol, the way it is already defined.

  Askr invents nothing of its own here. The contract is the same JSON
  structure Inertia uses — component, props, url and version — so the
  official adapters and the rest of the toolchain work unchanged.

      function TCustomerController.Index(Req: TRequest): TResponse;
      begin
        Result := Inertia('Customers/Index',
          ['customers', TQuery<TCustomer>.New.Paginate(Req.Page, 25)]);
      end;

  This is Inertia 3. The most important difference from 2 is where the
  payload sits in the HTML shell: it has moved from a data-page attribute
  on the root div to a script element of its own, of type
  application/json. The client in 3 looks only for the script element, so
  the attribute form does not boot.

  The protocol has four parts that have to line up, or the frontend
  behaves oddly in ways that are painful to debug:

    * Without X-Inertia in the request the answer is the whole HTML shell,
      with the payload in a <script data-page type="application/json">
      element.
    * With X-Inertia the answer is plain JSON, and X-Inertia: true back.
      Vary: X-Inertia has to be there, or intermediaries cache the wrong
      reply.
    * If X-Inertia-Version differs from the server's, the answer is a 409
      with X-Inertia-Location. The client then loads the page again,
      rather than switching to a version of the frontend that no longer
      exists.
    * On a partial reload only the props the client asked for are sent.

  One detail that is easy to miss: a redirect after PUT, PATCH or DELETE
  has to be a 303, not a 302. Otherwise the browser repeats the method
  against the new address.

  Not implemented yet, and deliberately left out of phase 1: merging props
  for infinite scrolling (mergeProps, deepMergeProps, matchPropsOn,
  X-Inertia-Reset). They belong to a pattern the app has to ask for, not
  to the base protocol. }
unit Askr.Inertia;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Askr.Core.Arena, Askr.Core.Text, Askr.Core.Json,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response,
  Askr.Urd.Model, Askr.Urd.Json, Askr.Urd.Bind, Askr.Session, Askr.Core.Url,
  Askr.Csrf, Askr.Core.Lang;

type
  EInertiaError = class(Exception);

  { Called when the payload is built, and can add props that are to be on
    every page — the signed-in user, flash messages, validation
    errors. }
  TInertiaShare = procedure(var W: TJsonWriter);

  TInertia = class
  public
    { The frontend version. Change it and a full reload is forced the next
      time the client navigates. Set it to the hash of the build. }
    class procedure SetVersion(const AVersion: string); static;
    class function Version: string; static;

    { The id of the element the client mounts into, and which the script
      element points at with data-page. The default is 'app'. }
    class procedure SetRootId(const AId: string); static;
    class function RootId: string; static;

    { Put in the payload as clearHistory and encryptHistory. }
    class procedure SetHistory(AEncrypt, AClear: Boolean); static;

    (* The HTML shell. It has to contain the placeholder {{page}} where the
       payload goes. This comment uses the star form because the braces
       would otherwise close an ordinary Pascal comment too early. *)
    class procedure SetRootTemplate(const AHtml: string); static;
    class function RootTemplate: string; static;

    class procedure SetShare(AHandler: TInertiaShare); static;

    { The title in the HTML shell, where the template has the title
      placeholder. The client usually sets its own per page; this is the
      one that stands there until it does, and the one that stands there
      if it never does. }
    class procedure SetTitle(const ATitle: string); static;
    class function Title: string; static;

    (* The tags that go in where the template has the placeholder {{head}} —
       typically the script and link tags from Vite. Without this the
       placeholder is left standing in the HTML, and the frontend never
       loads. *)
    class procedure SetHead(const AHtml: string); static;
    class function Head: string; static;

    (* ---- this page, rather than this site ----

       SetTitle above is the site's default, set once at startup: it is a
       plain global, which is right for a value that never changes and
       wrong for one that does. These are per thread, like the flash, and
       for the same reason — a global here would let one worker put its
       description on another's page.

       They apply to **the response being built now**, and are cleared
       when it is. A handler that sets them and then returns something
       other than an Inertia response leaves them for the next Inertia
       render on that worker; set them next to the render, not far from
       it. *)

    { This page's <title>, overriding the site default. }
    class procedure PageTitle(const AValue: string); static;
    { <meta name="description">. Search engines use it for the snippet;
      it is not a ranking signal and a missing one is better than a
      duplicated one. }
    class procedure PageDescription(const AValue: string); static;
    { <link rel="canonical">. A path is made absolute against app.url; a
      value that is already absolute is taken as it is. Never built from
      the request — see Askr.Core.Url. }
    class procedure PageCanonical(const APathOrUrl: string); static;
    { An Open Graph property. The name is given without the prefix:
      PageOg('title', ...) becomes <meta property="og:title">. }
    class procedure PageOg(const AProperty, AValue: string); static;
    { JSON-LD, as a complete JSON object. It goes inside a script
      element, so JSON escaping applies and not HTML escaping — the
      distinction that made `/` in an Inertia payload a bug once. }
    class procedure PageJsonLd(const AJson: string); static;
    { What this page looks like before the JavaScript has run: markup
      placed inside the mount element, which the client empties when it
      mounts.

      **This is the answer to a measured problem.** A crawler that does
      not execute JavaScript receives an Inertia page as a payload in a
      script element and an empty div -- zero characters of text. Googlebot
      renders scripts and copes; the fetchers behind most language models
      do not, and neither do several others.

      **It is markup, and it is not escaped.** Everything in it is yours to
      get right, exactly as with SetHead. Interpolating anything a user
      wrote without escaping it first is stored XSS, and this is a place
      where it would be served to every crawler as well.

      Askr does not render your components on the server: that needs a
      Node process beside the binary, and one binary with no sidecars is
      the point of the thing. What goes here is whatever the page *is*
      without its interactivity -- for a document, the document. }
    class procedure PageFallback(const AHtml: string); static;
    { Forgets everything set for this page. Called for you when an
      Inertia response is built. }
    class procedure ClearPageHead; static;
  end;

{ Builds the response. Props are pairs of name and value:

    Inertia('Customers/Index', ['customers', List, 'total', 42])

  The value can be a TModel, a TModelListBase, a string, an integer, a
  floating-point number, a Currency or a Boolean. nil becomes null. }
function Inertia(const Component: string;
  const Props: array of const): TResponse; overload;

{ As above, but the props in Deferred are not sent in the first reply.
  They are listed under deferredProps, and the client fetches them in a
  round of its own. Use it for something that is expensive to work out and
  is not needed for the first paint. }
function Inertia(const Component: string; const Props: array of const;
  const Deferred: array of string): TResponse; overload;

{ A redirect within the app. Uses 303 after PUT, PATCH and DELETE. }
function InertiaRedirect(const Url: string): TResponse;

{ Back where the client came from, following Referer. Without a Referer:
  to Fallback. }
function Back(const Fallback: string = '/'): TResponse;

{ The form the PRD writes: Exit(Back.WithErrors(C.Errors)).

  The errors are put in the session's flash and are props.errors in the
  next request. Without a surrounding session it raises, because the
  alternative — losing the errors in silence — is worse than a clear error
  message.

  **A client that asked for JSON gets 422 instead**, as a problem
  document with the same errors object. A redirect with a flash is a
  browser mechanism: it needs somewhere to store the errors between two
  requests and a client that follows the redirect and then reads the page
  it lands on. An API client does neither, so the old behaviour handed it
  a 302 to a page it never asked for and then lost the errors in the flash
  it never read. It is the same call either way — a handler should not
  have to branch on who is asking. }
function BackWithErrors(E: TErrors;
  const Fallback: string = '/'): TResponse;

{ A flash message on the reply being built right now. Inertia 3 has flash
  as a field of its own on the page object, not as a prop, and the client
  fires a flash event.

  The message does **not** survive a redirect. That would require storing
  it somewhere between the two requests, that is, sessions, and those
  belong to phase 2. More importantly: the two requests are often served
  by different workers, so even a thread-local value would be wrong.

  The pattern that works in phase 1 is to render the page directly after a
  successful save, instead of redirecting to it. }
procedure InertiaFlash(const AKey, AValue: string);

{ Out of the app — to an external address or an entirely new document.
  Inertia requires a 409 with X-Inertia-Location for the client to
  understand it. }
function InertiaLocation(const Url: string): TResponse;

{ True when the request came from the Inertia client. }
function IsInertiaRequest(Req: TRequest): Boolean;

implementation

const
  (* Inertia 3-formen: payloaden i et script-element, og en tom
     monteringsdiv. Plassholderen {{root}} byttes ut med rot-id-en. *)
  { lang is `en`, not `no`. Askr is an international framework, and a
    hard-coded Norwegian language makes a screen reader pronounce English
    text with Norwegian phonemes. The app sets its own language with
    SetRootTemplate.

    <title> has to be here. Without it every single Inertia page is
    missing a title until the client has had time to set one — and if it
    never does, the page has none. axe calls it document-title and counts
    it as serious; it was found by running axe against a site built with
    Askr. }
  DefaultRootTemplate =
    '<!DOCTYPE html>' + #10 +
    '<html lang="en">' + #10 +
    '<head>' + #10 +
    '  <meta charset="utf-8">' + #10 +
    '  <meta name="viewport" content="width=device-width, initial-scale=1">' + #10 +
    '  <title>{{title}}</title>' + #10 +
    '  {{head}}' + #10 +
    '</head>' + #10 +
    '<body>' + #10 +
    '  <script data-page="{{root}}" type="application/json">{{page}}</script>' + #10 +
    '  <div id="{{root}}">{{fallback}}</div>' + #10 +
    '</body>' + #10 +
    '</html>' + #10;

{ Flash is per thread, not shared. The workers each serve their own
  request, and a global would let one thread send the other's message. }
threadvar
  GFlashKeys: array of string;
  GFlashValues: array of string;
  { The head of the page being built right now. Per thread for the same
    reason the flash is: the workers each serve their own request, and a
    global would let one put its description on another's page. }
  GPageTitle: string;
  GPageDescription: string;
  GPageCanonical: string;
  GPageOgKeys: array of string;
  GPageOgValues: array of string;
  GPageJsonLd: string;
  GPageFallback: string;

var
  GVersion: string = '1';
  GRootTemplate: string = '';
  GRootId: string = 'app';
  { The default is the framework's name, not empty: an empty <title> is
    the same violation as no <title>. `askr new` sets the app's own. }
  GTitle: string = 'Askr';
  GHead: string = '';
  GEncryptHistory: Boolean = False;
  GClearHistory: Boolean = False;
  GShare: TInertiaShare = nil;

class procedure TInertia.SetVersion(const AVersion: string);
begin
  GVersion := AVersion;
end;

class function TInertia.Version: string;
begin
  Result := GVersion;
end;

class procedure TInertia.SetRootTemplate(const AHtml: string);
begin
  { Empty means the built-in one, which is what the getter has always
    meant by it. The setter refusing what the getter accepts left no way
    back to the default once a template had been set. }
  if AHtml = '' then
  begin
    GRootTemplate := '';
    Exit;
  end;
  if Pos('{{page}}', AHtml) = 0 then
    raise EInertiaError.Create(
      'The HTML shell must contain {{page}} where the payload goes');
  GRootTemplate := AHtml;
end;

class function TInertia.RootTemplate: string;
begin
  if GRootTemplate = '' then
    Result := DefaultRootTemplate
  else
    Result := GRootTemplate;
end;

class procedure TInertia.SetShare(AHandler: TInertiaShare);
begin
  GShare := AHandler;
end;

class procedure TInertia.SetHead(const AHtml: string);
begin
  GHead := AHtml;
end;

class procedure TInertia.PageTitle(const AValue: string);
begin
  GPageTitle := AValue;
end;

class procedure TInertia.PageDescription(const AValue: string);
begin
  GPageDescription := AValue;
end;

class procedure TInertia.PageCanonical(const APathOrUrl: string);
begin
  GPageCanonical := APathOrUrl;
end;

class procedure TInertia.PageOg(const AProperty, AValue: string);
var
  N: Integer;
begin
  N := Length(GPageOgKeys);
  SetLength(GPageOgKeys, N + 1);
  SetLength(GPageOgValues, N + 1);
  GPageOgKeys[N] := AProperty;
  GPageOgValues[N] := AValue;
end;

class procedure TInertia.PageJsonLd(const AJson: string);
begin
  GPageJsonLd := AJson;
end;

class procedure TInertia.PageFallback(const AHtml: string);
begin
  GPageFallback := AHtml;
end;

class procedure TInertia.ClearPageHead;
begin
  GPageFallback := '';
  GPageTitle := '';
  GPageDescription := '';
  GPageCanonical := '';
  SetLength(GPageOgKeys, 0);
  SetLength(GPageOgValues, 0);
  GPageJsonLd := '';
end;

class function TInertia.Head: string;
begin
  Result := GHead;
end;

class procedure TInertia.SetRootId(const AId: string);
begin
  GRootId := AId;
end;

class function TInertia.RootId: string;
begin
  Result := GRootId;
end;

class procedure TInertia.SetHistory(AEncrypt, AClear: Boolean);
begin
  GEncryptHistory := AEncrypt;
  GClearHistory := AClear;
end;

function IsInertiaRequest(Req: TRequest): Boolean;
begin
  Result := (Req <> nil) and Req.Header('x-inertia').SameTextStr('true');
end;

{ On a partial reload the client sends X-Inertia-Partial-Component along
  with the names it wants. It applies only when the component is the same —
  otherwise it is an ordinary navigation and everything goes along. }
function InList(const Header: TStr; const Name_: string): Boolean;
var
  Rest, Item: TStr;
begin
  Rest := Header;
  while Rest.Len > 0 do
  begin
    Rest.SplitAt(Ord(','), Item, Rest);
    if Item.TrimSpace.EqualsStr(Name_) then
      Exit(True);
  end;
  Result := False;
end;

function WantsProp(Req: TRequest; const Component, PropName: string): Boolean;
var
  Only: TStr;
begin
  if Req = nil then
    Exit(True);

  { Props the client already holds as "once" must not be sent again. That
    applies whether or not it is a partial reload. }
  if InList(Req.Header('x-inertia-except-once-props'), PropName) then
    Exit(False);

  if not Req.Header('x-inertia-partial-component').EqualsStr(Component) then
    Exit(True);

  if InList(Req.Header('x-inertia-partial-except'), PropName) then
    Exit(False);

  Only := Req.Header('x-inertia-partial-data');
  if Only.Len = 0 then
    Exit(True);
  Result := InList(Only, PropName);
end;

{ A deferred prop is not sent in the first reply, but is fetched when the
  client asks for it explicitly in a partial reload. }
function IsDeferredNow(Req: TRequest; const Component, PropName: string;
  const Deferred: array of string): Boolean;
var
  I: Integer;
  Asked: Boolean;
begin
  Result := False;
  for I := 0 to High(Deferred) do
    if Deferred[I] = PropName then
    begin
      Result := True;
      Break;
    end;
  if not Result then
    Exit;
  if Req = nil then
    Exit;
  Asked := Req.Header('x-inertia-partial-component').EqualsStr(Component) and
           InList(Req.Header('x-inertia-partial-data'), PropName);
  if Asked then
    Result := False;
end;

procedure WriteConstValue(var W: TJsonWriter; const V: TVarRec);
var
  O: TObject;
begin
  case V.VType of
    vtInteger:    W.Int(V.VInteger);
    vtInt64:      W.Int(V.VInt64^);
    vtQWord:      W.Int(Int64(V.VQWord^));
    vtBoolean:    W.Bool(V.VBoolean);
    vtCurrency:   W.Money(V.VCurrency^);
    vtExtended:   W.Num(V.VExtended^);
    vtChar:       W.Str(string(V.VChar));
    vtString:     W.Str(string(V.VString^));
    vtAnsiString: W.Str(AnsiString(V.VAnsiString));
    vtPChar:      W.Str(string(V.VPChar));
    vtPointer:
      if V.VPointer = nil then
        W.Null
      else
        raise EInertiaError.Create('A pointer cannot be serialised as a prop');
    vtObject:
      begin
        O := V.VObject;
        if O = nil then
          W.Null
        else if O is TErrors then
          { Inertia 3 reads props.errors from any reply at all, not only from
            a session-carried redirect. So a validation that fails can
            render the page again with the errors as a prop. }
          TErrors(O).WriteJson(W)
        else if O is TJsonWritable then
          { The app's own object. The hook lives in Askr.Core.Json, so that
            Inertia does not have to know every type that can be a prop —
            TGrid was the first, and the list must not grow here. }
          TJsonWritable(O).WriteJson(W)
        else if O is TModelListBase then
          WriteModelList(W, TModelListBase(O))
        else if O is TModel then
          WriteModel(W, TModel(O))
        else
          raise EInertiaError.CreateFmt(
            '%s cannot be serialised as a prop. Pass a TModel, a ' +
            'TModelListBase, a TJsonWritable or a simple value.',
            [O.ClassName]);
      end;
  else
    raise EInertiaError.Create('Unknown prop type in an Inertia call');
  end;
end;

function PropName(const V: TVarRec): string;
begin
  case V.VType of
    vtAnsiString: Result := AnsiString(V.VAnsiString);
    vtString:     Result := string(V.VString^);
    vtChar:       Result := string(V.VChar);
    vtPChar:      Result := string(V.VPChar);
  else
    raise EInertiaError.Create(
      'A prop name must be a string. Props come in pairs: name, value, name, value.');
  end;
end;

function BuildPayload(A: TArena; Req: TRequest; const Component: string;
  const Props: array of const; const Deferred: array of string): TStr;
var
  W: TJsonWriter;
  I: Integer;
  Name_: string;
  Url: TStr;
  AnyDeferred: Boolean;
  Sess: TSession;
  Lauf: TStringArray;
begin
  if Odd(Length(Props)) then
    raise EInertiaError.Create(
      'Props must come in pairs: name, value, name, value.');

  W.Init(A, 2048);
  W.BeginObject;
  W.Field('component', Component);

  W.Key('props');
  W.BeginObject;

  { Validation errors from the previous request. Inertia reads
    props.errors, so this is all it takes for Back.WithErrors to work. }
  Sess := CurrentSession;
  if (Sess <> nil) and Sess.HasErrors then
    W.FieldRaw('errors', Askr.Core.Text.Str(Sess.ErrorsJson));

  if Assigned(GShare) then
    GShare(W);
  { Lauf's own words in the request's language, when it says something
    other than English: the [lauf] section of the lang files, for
    provideStrings in the app's layout. Left out otherwise, so a page in
    English carries none of it. }
  Lauf := ChangedTextsUnder('lauf');
  if Length(Lauf) > 0 then
  begin
    W.Key('lauf');
    W.BeginObject;
    for I := 0 to High(Lauf) do
      W.Field(Copy(Lauf[I], 1, Pos('=', Lauf[I]) - 1),
        Copy(Lauf[I], Pos('=', Lauf[I]) + 1, MaxInt));
    W.EndObject;
  end;
  I := 0;
  while I < Length(Props) do
  begin
    Name_ := PropName(Props[I]);
    if WantsProp(Req, Component, Name_) and
       not IsDeferredNow(Req, Component, Name_, Deferred) then
    begin
      W.Key(Name_);
      WriteConstValue(W, Props[I + 1]);
    end;
    Inc(I, 2);
  end;
  W.EndObject;

  { deferredProps grupperes; alt havner i «default» til appen trenger annet. }
  AnyDeferred := False;
  I := 0;
  while I < Length(Props) do
  begin
    if IsDeferredNow(Req, Component, PropName(Props[I]), Deferred) then
    begin
      AnyDeferred := True;
      Break;
    end;
    Inc(I, 2);
  end;
  if AnyDeferred then
  begin
    W.Key('deferredProps');
    W.BeginObject;
    W.Key('default');
    W.BeginArray;
    I := 0;
    while I < Length(Props) do
    begin
      Name_ := PropName(Props[I]);
      if IsDeferredNow(Req, Component, Name_, Deferred) then
        W.Str(Name_);
      Inc(I, 2);
    end;
    W.EndArray;
    W.EndObject;
  end;

  if Req <> nil then
  begin
    if Req.QueryString.Len > 0 then
      Url := StrCat(A, StrCat(A, Req.RawPath, Askr.Core.Text.Str('?')),
        Req.QueryString)
    else
      Url := Req.RawPath;
  end
  else
    Url := Askr.Core.Text.Str('/');
  W.Field('url', Url);
  W.Field('version', TInertia.Version);
  W.Field('clearHistory', GClearHistory);
  W.Field('encryptHistory', GEncryptHistory);

  { Two sources of flash: what was set on this reply, and what came from
    the previous request through the session. Both are written into the
    same object.

    The guard has to ask about the same thing WriteFlashInto writes. It
    used to ask about one hard-coded key, and then any other flash — for
    instance Session.Flash('error', ...) from the auth scaffolding — was
    silently discarded. }
  if (Length(GFlashKeys) > 0) or
     ((Sess <> nil) and (Sess.HasAnyFlash or Sess.HasErrors)) then
  begin
    W.Key('flash');
    W.BeginObject;
    if Sess <> nil then
      Sess.WriteFlashInto(W);
    for I := 0 to High(GFlashKeys) do
      W.Field(GFlashKeys[I], GFlashValues[I]);
    W.EndObject;
    SetLength(GFlashKeys, 0);
    SetLength(GFlashValues, 0);
  end;

  W.EndObject;
  Result := W.ToStr;
end;

class procedure TInertia.SetTitle(const ATitle: string);
begin
  GTitle := ATitle;
end;

class function TInertia.Title: string;
begin
  Result := GTitle;
end;

{ The head tags for this page: description, canonical, Open Graph,
  JSON-LD.

  Two escapings, and which one applies depends on where the value lands.
  An attribute value takes HTML escaping. The JSON-LD lands inside a
  script element, where HTML escaping is the wrong tool entirely -- the
  browser does not decode entities there, so `&quot;` would arrive as six
  characters inside the JSON and break it, while a `</script>` in a string
  would close the element. That is the same distinction that made the
  Inertia payload's `/` a bug once. }
function PageHeadHtml(A: TArena): string;
var
  I: Integer;
  Canon: string;

  function Attr(const S: string): string;
  begin
    Result := HtmlAttrEscape(A, Askr.Core.Text.Str(S)).ToString;
  end;

begin
  Result := '';

  if GPageDescription <> '' then
    Result := Result + '  <meta name="description" content="' +
      Attr(GPageDescription) + '">' + #10;

  if GPageCanonical <> '' then
  begin
    { A path is made absolute; something already absolute is taken as it
      is. Either way it does not come from the request. }
    if (Pos('http://', GPageCanonical) = 1) or
       (Pos('https://', GPageCanonical) = 1) then
      Canon := GPageCanonical
    else
      Canon := AbsoluteUrl(GPageCanonical);
    { Empty when app.url is not set. A canonical pointing at the wrong
      place is worse than none, so it is left out rather than guessed. }
    if Canon <> '' then
      Result := Result + '  <link rel="canonical" href="' + Attr(Canon) +
        '">' + #10;
  end;

  for I := 0 to High(GPageOgKeys) do
    Result := Result + '  <meta property="og:' + Attr(GPageOgKeys[I]) +
      '" content="' + Attr(GPageOgValues[I]) + '">' + #10;

  if GPageJsonLd <> '' then
    Result := Result + '  <script type="application/ld+json">' +
      JsonScriptEscape(A, Askr.Core.Text.Str(GPageJsonLd)).ToString +
      '</script>' + #10;
end;

function RenderShell(A: TArena; const Payload: TStr): TStr;
var
  Tpl: string;
  Title_: string;
  Escaped: TStr;
  B: TStrBuilder;
  P: Integer;
begin
  Tpl := StringReplace(TInertia.RootTemplate, '{{root}}', TInertia.RootId,
    [rfReplaceAll]);
  Tpl := StringReplace(Tpl, '{{head}}',
    TInertia.Head + #10 + PageHeadHtml(A), [rfReplaceAll]);
  { The title is user-controlled and lands in an HTML element. This page's
    own when it set one, the site default otherwise -- a page with no
    title is the same accessibility failure as an empty one. }
  if GPageTitle <> '' then
    Title_ := GPageTitle
  else
    Title_ := TInertia.Title;
  Tpl := StringReplace(Tpl, '{{title}}',
    HtmlAttrEscape(A, Askr.Core.Text.Str(Title_)).ToString,
    [rfReplaceAll]);

  { Not escaped: it is markup by intent, like the head tags SetHead takes.
    A template that has no place for it while a page supplies one is a
    mistake worth stopping on -- dropping it silently would leave the page
    empty for exactly the readers it was written for, and nothing would
    say so. }
  if (GPageFallback <> '') and (Pos('{{fallback}}', Tpl) = 0) then
    raise EInertiaError.Create('A page set a fallback, but the root ' +
      'template has no {{fallback}} placeholder. Add it inside the mount ' +
      'element: <div id="{{root}}">{{fallback}}</div>');
  Tpl := StringReplace(Tpl, '{{fallback}}', GPageFallback, [rfReplaceAll]);
  { Inside a script element it is JSON escaping that applies, not HTML
    escaping. See JsonScriptEscape. }
  Escaped := JsonScriptEscape(A, Payload);
  P := Pos('{{page}}', Tpl);
  B.Init(A, Length(Tpl) + Escaped.Len + 64);
  B.Append(Copy(Tpl, 1, P - 1));
  B.Append(Escaped);
  B.Append(Copy(Tpl, P + Length('{{page}}'), MaxInt));
  Result := B.ToStr;
end;

function Inertia(const Component: string;
  const Props: array of const): TResponse;
begin
  Result := Inertia(Component, Props, []);
end;

function Inertia(const Component: string; const Props: array of const;
  const Deferred: array of string): TResponse;
var
  Req: TRequest;
  A: TArena;
  Payload: TStr;
begin
  Req := CurrentRequest;
  A := CurrentArena;
  if A = nil then
    raise EInertiaError.Create('Inertia requires an ambient arena');

  { The version check before anything is built. The client is to reload,
    not to get a payload it cannot use. }
  { Whatever happens, this page's head does not become the next page's.
    The values are per thread and a worker serves one request after
    another, so anything left behind is inherited by whoever comes next on
    this thread -- the same shape as the session threadvar that had to be
    cleared first rather than last in Commit. }
  try
    if (Req <> nil) and IsInertiaRequest(Req) and (Req.Method = hmGet) and
       Req.HasHeader('x-inertia-version') and
       not Req.Header('x-inertia-version').EqualsStr(TInertia.Version) then
      Exit(InertiaLocation(Req.Target.ToString));

    { **A page makes the CSRF token.** The Inertia client sends only what
      the XSRF-TOKEN cookie holds, and UseCsrf sets that cookie only once
      the token exists -- so that a static file or a health check does
      not cost a session. Nothing else on an Inertia page asked for it,
      and every POST from a visitor who had not been to a server-rendered
      form answered 419, which the client meets by reloading and trying
      again. A page is where a form is; this is the price of the form
      working, and it is a session per visitor who sees a page. }
    if CsrfInUse and (CurrentSession <> nil) then
      CsrfToken;

    Payload := BuildPayload(A, Req, Component, Props, Deferred);

    if IsInertiaRequest(Req) then
    begin
      Result := Respond(200)
        .WithContentType('application/json')
        .WithHeader('X-Inertia', 'true')
        .WithHeader('Vary', 'X-Inertia')
        .WithBody(Payload);
      Exit;
    end;

    Result := Respond(200)
      .WithContentType('text/html; charset=utf-8')
      .WithHeader('Vary', 'X-Inertia')
      .WithBody(RenderShell(A, Payload));
  finally
    TInertia.ClearPageHead;
  end;
end;

function InertiaRedirect(const Url: string): TResponse;
var
  Req: TRequest;
  Code: Integer;
begin
  Req := CurrentRequest;
  Code := 302;
  { 303 forces the browser over to GET. Without this a PUT or DELETE is
    repeated against the new address. }
  if (Req <> nil) and
     ((Req.Method = hmPut) or (Req.Method = hmPatch) or (Req.Method = hmDelete)) then
    Code := 303;
  Result := Redirect(Url, Code);
end;

procedure InertiaFlash(const AKey, AValue: string);
var
  N: Integer;
begin
  N := Length(GFlashKeys);
  SetLength(GFlashKeys, N + 1);
  SetLength(GFlashValues, N + 1);
  GFlashKeys[N] := AKey;
  GFlashValues[N] := AValue;
end;

function Back(const Fallback: string): TResponse;
var
  Req: TRequest;
  Ref: TStr;
begin
  Req := CurrentRequest;
  if Req <> nil then
  begin
    Ref := Req.Header('referer');
    if Ref.Len > 0 then
      Exit(InertiaRedirect(Ref.ToString));
  end;
  Result := InertiaRedirect(Fallback);
end;

function BackWithErrors(E: TErrors; const Fallback: string): TResponse;
var
  S: TSession;
  W: TJsonWriter;
  A: TArena;
  Req: TRequest;
begin
  { Before the session check, not after: an API client has no session and
    needs none, and raising at it would be the framework insisting on a
    browser mechanism. }
  Req := CurrentRequest;
  if (Req <> nil) and Req.AcceptsJson then
    Exit(ValidationProblem(E));

  S := CurrentSession;
  if S = nil then
    raise EInertiaError.Create(
      'Back.WithErrors requires an ambient session. Set one up with ' +
      'SetSessions and UseSession, or re-render the page with ' +
      'errors as a prop instead.');
  A := CurrentArena;
  W.Init(A, 512);
  E.WriteJson(W);
  S.FlashErrorsJson(W.ToStr);
  Result := Back(Fallback);
end;

function InertiaLocation(const Url: string): TResponse;
begin
  Result := Respond(409)
    .WithHeader('X-Inertia-Location', Url)
    .WithHeader('Vary', 'X-Inertia');
end;

end.
