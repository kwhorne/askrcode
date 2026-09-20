{ Askr.Inertia — Inertia-protokollen, slik den allerede er definert.

  Askr finner ikke opp noe eget her. Kontrakten er den samme JSON-strukturen
  Inertia bruker — component, props, url og version — så de offisielle
  adapterne og resten av verktøykjeden virker uendret.

      function TCustomerController.Index(Req: TRequest): TResponse;
      begin
        Result := Inertia('Customers/Index',
          ['customers', TQuery<TCustomer>.New.Paginate(Req.Page, 25)]);
      end;

  Dette er Inertia 3. Den viktigste forskjellen fra 2 er hvor payloaden
  ligger i HTML-skallet: den er flyttet fra et data-page-attributt på
  rot-diven til et eget script-element av typen application/json. Klienten i
  3 leter bare etter script-elementet, så attributtformen boot-er ikke.

  Protokollen har fire deler som må stemme, ellers oppfører frontend seg rart
  på måter som er vonde å feilsøke:

    * Uten X-Inertia i requesten svares det med hele HTML-skallet, med
      payloaden i et <script data-page type="application/json">-element.
    * Med X-Inertia svares det med ren JSON, og X-Inertia: true tilbake.
      Vary: X-Inertia må med, ellers cacher mellomledd feil svar.
    * Er X-Inertia-Version ulik serverens, svares 409 med X-Inertia-Location.
      Klienten laster da siden på nytt, i stedet for å bytte til en versjon
      av frontend som ikke finnes lenger.
    * Ved delvis oppdatering sendes bare de propsene klienten ba om.

  En detalj som er lett å overse: en omdirigering etter PUT, PATCH eller
  DELETE må være 303, ikke 302. Ellers gjentar nettleseren metoden mot den
  nye adressen.

  Ikke implementert ennå, og bevisst utelatt fra fase 1: sammenslåing av
  props for uendelig rulling (mergeProps, deepMergeProps, matchPropsOn,
  X-Inertia-Reset). De hører til et mønster appen må be om, ikke til
  grunnprotokollen. }
unit Askr.Inertia;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Askr.Core.Arena, Askr.Core.Text, Askr.Core.Json,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response,
  Askr.Urd.Model, Askr.Urd.Json, Askr.Session;

type
  EInertiaError = class(Exception);

  { Kalles når payloaden bygges, og kan legge til props som skal være med på
    hver side — innlogget bruker, flash-meldinger, valideringsfeil. }
  TInertiaShare = procedure(var W: TJsonWriter);

  TInertia = class
  public
    { Frontend-versjonen. Endres denne, tvinges en full omlasting neste gang
      klienten navigerer. Sett den til hashen av bygget. }
    class procedure SetVersion(const AVersion: string); static;
    class function Version: string; static;

    { Id-en på elementet klienten monterer i, og som script-elementet peker
      på med data-page. Standard er 'app'. }
    class procedure SetRootId(const AId: string); static;
    class function RootId: string; static;

    { Legges i payloaden som clearHistory og encryptHistory. }
    class procedure SetHistory(AEncrypt, AClear: Boolean); static;

    (* HTML-skallet. Må inneholde plassholderen {{page}} der payloaden skal
       inn. Denne kommentaren bruker stjerneform fordi klammeparentesene
       ellers ville lukket en vanlig Pascal-kommentar for tidlig. *)
    class procedure SetRootTemplate(const AHtml: string); static;
    class function RootTemplate: string; static;

    class procedure SetShare(AHandler: TInertiaShare); static;

    (* Taggene som settes inn der malen har plassholderen {{head}} — typisk
       script- og link-taggene fra Vite. Uten dette blir plassholderen
       stående i HTML-en, og frontend laster aldri. *)
    class procedure SetHead(const AHtml: string); static;
    class function Head: string; static;
  end;

{ Bygger responsen. Props er par av navn og verdi:

    Inertia('Customers/Index', ['customers', Liste, 'total', 42])

  Verdien kan være en TModel, en TModelListBase, en streng, et heltall, et
  desimaltall, en Currency eller en Boolean. nil blir null. }
function Inertia(const Component: string;
  const Props: array of const): TResponse; overload;

{ Som over, men propsene i Deferred sendes ikke med i første svar. De
  oppføres under deferredProps, og klienten henter dem i en egen runde. Bruk
  det til noe som er dyrt å regne ut og ikke trengs for første maling. }
function Inertia(const Component: string; const Props: array of const;
  const Deferred: array of string): TResponse; overload;

{ Omdirigering innenfor appen. Bruker 303 etter PUT, PATCH og DELETE. }
function InertiaRedirect(const Url: string): TResponse;

{ Tilbake dit klienten kom fra, etter Referer. Uten Referer: til Fallback. }
function Back(const Fallback: string = '/'): TResponse;

{ Formen PRD-en skriver: Exit(Back.WithErrors(C.Errors)).

  Feilene legges i sesjonens flash og er props.errors i neste request. Uten
  en omgivende sesjon kastes det, fordi alternativet — å miste feilene i
  stillhet — er verre enn en tydelig feilmelding. }
function BackWithErrors(E: TErrors;
  const Fallback: string = '/'): TResponse;

{ Flash-melding på det svaret som bygges nå. Inertia 3 har flash som et eget
  felt på page-objektet, ikke som en prop, og klienten fyrer et flash-event.

  Meldingen overlever **ikke** en omdirigering. Det krever at den lagres et
  sted mellom de to requestene, altså sesjoner, og de hører til fase 2. Enda
  viktigere: de to requestene betjenes gjerne av hver sin worker, så selv en
  trådlokal verdi ville vært feil.

  Mønsteret som virker i fase 1 er å rendre siden direkte etter en vellykket
  lagring, i stedet for å omdirigere til den. }
procedure InertiaFlash(const AKey, AValue: string);

{ Ut av appen — til en ekstern adresse eller et helt nytt dokument.
  Inertia krever 409 med X-Inertia-Location for at klienten skal forstå det. }
function InertiaLocation(const Url: string): TResponse;

{ True når requesten kom fra Inertia-klienten. }
function IsInertiaRequest(Req: TRequest): Boolean;

implementation

const
  (* Inertia 3-formen: payloaden i et script-element, og en tom
     monteringsdiv. Plassholderen {{root}} byttes ut med rot-id-en. *)
  DefaultRootTemplate =
    '<!DOCTYPE html>' + #10 +
    '<html lang="no">' + #10 +
    '<head>' + #10 +
    '  <meta charset="utf-8">' + #10 +
    '  <meta name="viewport" content="width=device-width, initial-scale=1">' + #10 +
    '  {{head}}' + #10 +
    '</head>' + #10 +
    '<body>' + #10 +
    '  <script data-page="{{root}}" type="application/json">{{page}}</script>' + #10 +
    '  <div id="{{root}}"></div>' + #10 +
    '</body>' + #10 +
    '</html>' + #10;

{ Flash er per tråd, ikke delt. Workerne betjener hver sin request, og en
  global ville latt den ene tråden sende den andres melding. }
threadvar
  GFlashKeys: array of string;
  GFlashValues: array of string;

var
  GVersion: string = '1';
  GRootTemplate: string = '';
  GRootId: string = 'app';
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

{ Ved delvis oppdatering sender klienten X-Inertia-Partial-Component sammen
  med navnene den vil ha. Gjelder bare når komponenten er den samme — ellers
  er det en vanlig navigering og alt skal med. }
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

  { Props klienten allerede har som «once» skal ikke sendes på nytt. Dette
    gjelder uavhengig av om det er en delvis oppdatering. }
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

{ En utsatt prop sendes ikke med i første svar, men hentes når klienten ber
  eksplisitt om den i en delvis oppdatering. }
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
          { Inertia 3 leser props.errors fra hvilket som helst svar, ikke bare
            fra en sesjonsbåret omdirigering. Derfor kan en validering som
            feiler rendre siden på nytt med feilene som prop. }
          TErrors(O).WriteJson(W)
        else if O is TModelListBase then
          WriteModelList(W, TModelListBase(O))
        else if O is TModel then
          WriteModel(W, TModel(O))
        else
          raise EInertiaError.CreateFmt(
            '%s cannot be serialised as a prop. Pass a TModel, a ' +
            'TModelListBase or a simple value.', [O.ClassName]);
      end;
  else
    raise EInertiaError.Create('Ukjent proptype i Inertia-kall');
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
begin
  if Odd(Length(Props)) then
    raise EInertiaError.Create(
      'Props must come in pairs: name, value, name, value.');

  W.Init(A, 2048);
  W.BeginObject;
  W.Field('component', Component);

  W.Key('props');
  W.BeginObject;

  { Valideringsfeil fra forrige request. Inertia leser props.errors, så
    dette er alt som skal til for at Back.WithErrors virker. }
  Sess := CurrentSession;
  if (Sess <> nil) and Sess.HasErrors then
    W.FieldRaw('errors', Askr.Core.Text.Str(Sess.ErrorsJson));

  if Assigned(GShare) then
    GShare(W);
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

  { To kilder til flash: det som ble satt på dette svaret, og det som kom
    fra forrige request gjennom sesjonen. Begge skrives i samme objekt.

    Vakten må spørre om det samme som WriteFlashInto skriver. Den spurte før
    etter én hardkodet nøkkel, og da ble enhver annen flash — for eksempel
    Session.Flash('error', ...) fra auth-stillaset — stille forkastet. }
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

function RenderShell(A: TArena; const Payload: TStr): TStr;
var
  Tpl: string;
  Escaped: TStr;
  B: TStrBuilder;
  P: Integer;
begin
  Tpl := StringReplace(TInertia.RootTemplate, '{{root}}', TInertia.RootId,
    [rfReplaceAll]);
  Tpl := StringReplace(Tpl, '{{head}}', TInertia.Head, [rfReplaceAll]);
  { Inne i et script-element er det JSON-escaping som gjelder, ikke
    HTML-escaping. Se JsonScriptEscape. }
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

  { Versjonssjekk før noe bygges. Klienten skal laste på nytt, ikke få en
    payload den ikke kan bruke. }
  if (Req <> nil) and IsInertiaRequest(Req) and (Req.Method = hmGet) and
     Req.HasHeader('x-inertia-version') and
     not Req.Header('x-inertia-version').EqualsStr(TInertia.Version) then
    Exit(InertiaLocation(Req.Target.ToString));

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
end;

function InertiaRedirect(const Url: string): TResponse;
var
  Req: TRequest;
  Code: Integer;
begin
  Req := CurrentRequest;
  Code := 302;
  { 303 tvinger nettleseren over på GET. Uten dette gjentas PUT eller DELETE
    mot den nye adressen. }
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
begin
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
