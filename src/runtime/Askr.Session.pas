{ Askr.Session — sesjoner i samme prosess.

  Dette lukker avviket fra steg 5. PRD-en skriver

      Exit(Back.WithErrors(C.Errors));
      Redirect('/customers').With('flash', 'Kunde opprettet');

  og begge forutsetter at noe overlever en omdirigering. Without sesjoner gjorde
  det ikke det, og valideringen måtte rendre siden på nytt i stedet.

  Lageret ligger i prosessen, som køen og cachen. Det er en bevisst
  begrensning og ikke en forglemmelse: én binær, ingen sidevogn. Skaleres
  appen til flere noder, må lageret byttes — grensesnittet er skilt ut slik
  at det er én klasse, ikke et gjennomgripende inngrep.

  Flash har den klassiske semantikken: det som skrives i én request kan leses
  i den neste, og er borte etter det. Det er derfor det er to kart og ikke
  ett — det som kan leses nå, og det som skrives for neste gang.

  Sesjonsobjektet er et arena-objekt. Verdiene kopieres inn i lageret ved
  Commit og ut i arenaen ved Start, samme grense som i cachen og av samme
  grunn. }
unit Askr.Session;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Clock, Askr.Core.Json,
  Askr.Core.Crypto,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response, Askr.Http.Router;

type
  ESessionError = class(Exception);

  TSessionPair = record
    Key: string;
    Value: string;
  end;

  { Sesjonen slik en request ser den. Lever i request-arenaen. }
  TSession = class(TArenaObject)
  private
    FId: string;
    FData: array of TSessionPair;
    FFlashIn: array of TSessionPair;    { lesbart nå }
    FFlashOut: array of TSessionPair;   { skrives for neste request }
    FDirty: Boolean;
    FNew: Boolean;
    function IndexIn(const Arr: array of TSessionPair;
      const Key: string): Integer;
  public
    function Get(const Key: string; const Default: string = ''): string;
    function Has(const Key: string): Boolean;
    procedure Put(const Key, Value: string);
    procedure Forget(const Key: string);
    procedure Clear;

    { Lesbart i neste request, så borte. }
    procedure Flash(const Key, Value: string);
    function GetFlash(const Key: string; const Default: string = ''): string;
    function HasFlash(const Key: string): Boolean;
    { Om det finnes noe lesbart flash i det hele tatt. Valideringsfeilene
      teller ikke med — de er en egen prop i Inertia-payloaden, ikke en
      melding, og HasErrors svarer for dem. }
    function HasAnyFlash: Boolean;
    { Beholder det som kom inn, slik at det også er der neste gang. }
    procedure Reflash;

    { Valideringsfeil som JSON, lagret som flash. Det er dette som gjør
      Back.WithErrors mulig. }
    procedure FlashErrorsJson(const Json: TStr);
    function ErrorsJson: string;
    function HasErrors: Boolean;

    { Skriver flash-parene inn i et objekt som allerede er åpnet. }
    procedure WriteFlashInto(var W: TJsonWriter);

    property Id: string read FId;
    property IsNew: Boolean read FNew;
    property Dirty: Boolean read FDirty;
  end;

  TSessionStore = class
  private
    FLock: TCriticalSection;
    FKeys: TStringList;          { id -> indeks i FSlots }
    FSlots: array of record
      Id: string;
      Data: array of TSessionPair;
      Flash: array of TSessionPair;
      ExpiresAt: Int64;
      InUse: Boolean;
    end;
    FFree: array of Integer;
    FLifetime: Integer;
    FCookieName: string;
    FSecure: Boolean;
    FCreated, FResumed, FExpired: QWord;
    procedure Sweep;
    function SlotFor(const Id: string): Integer;
  public
    constructor Create(ALifetimeSeconds: Integer = 7200);
    destructor Destroy; override;

    { Leser sesjonskaka, henter tilstanden inn i arenaen. Storage en ny
      sesjon hvis kaka mangler eller er utløpt. }
    function Start(Req: TRequest): TSession;
    { Skriver tilstanden tilbake og setter kaka på responsen. Roterer
      flash: det som ble lest er borte, det som ble skrevet blir lesbart. }
    procedure Commit(S: TSession; Res: TResponse);

    { Gir sesjonen en ny id og kaster den gamle. Dataene blir med.

      Dette må skje ved innlogging. Ellers: en angriper setter kaka di til
      en id han selv kjenner *før* du logger inn, du logger inn i akkurat
      den sesjonen, og han er innlogget som deg. Det heter session fixation,
      og det eneste som stopper det er at id-en byttes i det privilegiene
      endrer seg. }
    procedure Regenerate(S: TSession);

    procedure Destroy_(const Id: string);
    function Count: Integer;

    property CookieName: string read FCookieName write FCookieName;
    { Sett denne når appen kjører bak HTTPS. }
    property Secure: Boolean read FSecure write FSecure;
    property Lifetime: Integer read FLifetime write FLifetime;
    property Created: QWord read FCreated;
    property Resumed: QWord read FResumed;
    property Expired: QWord read FExpired;
  end;

function Sessions: TSessionStore;
procedure SetSessions(AStore: TSessionStore);

{ Kobler sesjonene på ruteren: starter sesjonen før middleware og skriver
  den tilbake etter at svaret er laget.

  Før dette måtte hver app kalle Start, UseSession og Commit for hånd rundt
  hver request, og glemte man Commit ble ingenting lagret — uten en feil
  noe sted. Krever at SetSessions er kalt først. }
procedure UseSessions(R: TRouter);

{ Omgivende sesjon for gjeldende tråd, etter samme mønster som UseArena,
  UseDb og UseRequest. Verten setter den etter Start og fjerner den etter
  Commit. }
function CurrentSession: TSession;
function UseSession(S: TSession): TSession;

{ Én navngitt kake ut av Cookie-headeren. Den står her fordi sesjonen
  trenger den først; Askr.Auth bruker den samme til «husk meg»-kaka, og to
  parsere av samme header ville før eller siden vært uenige. }
function CookieValue(Req: TRequest; const Name_: string): string;

{ Nøkkelen valideringsfeil lagres under. }
const
  ErrorsFlashKey = '_errors';

implementation

threadvar
  GCurrent: TSession;

var
  GStore: TSessionStore = nil;

function CurrentSession: TSession;
begin
  Result := GCurrent;
end;

function UseSession(S: TSession): TSession;
begin
  Result := GCurrent;
  GCurrent := S;
end;

function Sessions: TSessionStore;
begin
  if GStore = nil then
    raise ESessionError.Create(
      'No session store is configured. Call SetSessions at startup.');
  Result := GStore;
end;

procedure SetSessions(AStore: TSessionStore);
begin
  GStore := AStore;
end;

{ 128 tilfeldige bit fra kjernen, hex-kodet. En sesjons-id som kan gjettes
  er ingen sesjons-id.

  Tilfeldigheten kommer fra Askr.Core.Crypto, ikke fra en egen urandom-
  lesning her. Det er én ting i rammeverket som snakker med kjernens CSPRNG,
  og den har testene. }
function NewSessionId: string;
begin
  Result := RandomHex(16);
end;

function CookieValue(Req: TRequest; const Name_: string): string;
var
  H, Rest, Item, K, V: TStr;
begin
  Result := '';
  H := Req.Header('cookie');
  Rest := H;
  while Rest.Len > 0 do
  begin
    Rest.SplitAt(Ord(';'), Item, Rest);
    Item := Item.TrimSpace;
    if Item.Len = 0 then
      Continue;
    if not Item.SplitAt(Ord('='), K, V) then
      Continue;
    if K.TrimSpace.EqualsStr(Name_) then
      Exit(V.TrimSpace.ToString);
  end;
end;

{ TSession }

function TSession.IndexIn(const Arr: array of TSessionPair;
  const Key: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(Arr) do
    if Arr[I].Key = Key then
      Exit(I);
  Result := -1;
end;

function TSession.Get(const Key, Default: string): string;
var
  I: Integer;
begin
  I := IndexIn(FData, Key);
  if I < 0 then
    Exit(Default);
  Result := FData[I].Value;
end;

function TSession.Has(const Key: string): Boolean;
begin
  Result := IndexIn(FData, Key) >= 0;
end;

procedure TSession.Put(const Key, Value: string);
var
  I, N: Integer;
begin
  I := IndexIn(FData, Key);
  if I >= 0 then
    FData[I].Value := Value
  else
  begin
    N := Length(FData);
    SetLength(FData, N + 1);
    FData[N].Key := Key;
    FData[N].Value := Value;
  end;
  FDirty := True;
end;

procedure TSession.Forget(const Key: string);
var
  I, J: Integer;
begin
  I := IndexIn(FData, Key);
  if I < 0 then
    Exit;
  for J := I to High(FData) - 1 do
    FData[J] := FData[J + 1];
  SetLength(FData, Length(FData) - 1);
  FDirty := True;
end;

procedure TSession.Clear;
begin
  SetLength(FData, 0);
  SetLength(FFlashOut, 0);
  FDirty := True;
end;

procedure TSession.Flash(const Key, Value: string);
var
  I, N: Integer;
begin
  I := IndexIn(FFlashOut, Key);
  if I >= 0 then
    FFlashOut[I].Value := Value
  else
  begin
    N := Length(FFlashOut);
    SetLength(FFlashOut, N + 1);
    FFlashOut[N].Key := Key;
    FFlashOut[N].Value := Value;
  end;
  FDirty := True;
end;

function TSession.GetFlash(const Key, Default: string): string;
var
  I: Integer;
begin
  I := IndexIn(FFlashIn, Key);
  if I < 0 then
    Exit(Default);
  Result := FFlashIn[I].Value;
end;

function TSession.HasFlash(const Key: string): Boolean;
begin
  Result := IndexIn(FFlashIn, Key) >= 0;
end;

function TSession.HasAnyFlash: Boolean;
var
  I: Integer;
begin
  { Samme utvalg som WriteFlashInto skriver. Skiller de to lag, blir vakten
    stående og si nei til noe som ville blitt skrevet. }
  for I := 0 to High(FFlashIn) do
    if FFlashIn[I].Key <> ErrorsFlashKey then
      Exit(True);
  Result := False;
end;

procedure TSession.Reflash;
var
  I: Integer;
begin
  for I := 0 to High(FFlashIn) do
    Flash(FFlashIn[I].Key, FFlashIn[I].Value);
end;

procedure TSession.FlashErrorsJson(const Json: TStr);
begin
  Flash(ErrorsFlashKey, Json.ToString);
end;

function TSession.ErrorsJson: string;
begin
  Result := GetFlash(ErrorsFlashKey, '');
end;

function TSession.HasErrors: Boolean;
begin
  Result := HasFlash(ErrorsFlashKey) and (ErrorsJson <> '') and
    (ErrorsJson <> '{}');
end;

procedure TSession.WriteFlashInto(var W: TJsonWriter);
var
  I: Integer;
begin
  for I := 0 to High(FFlashIn) do
    { Feilene er en egen prop i Inertia-payloaden, ikke en flash-melding. }
    if FFlashIn[I].Key <> ErrorsFlashKey then
      W.Field(FFlashIn[I].Key, FFlashIn[I].Value);
end;

{ TSessionStore }

constructor TSessionStore.Create(ALifetimeSeconds: Integer);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FKeys := TStringList.Create;
  FKeys.Sorted := True;
  FKeys.Duplicates := dupIgnore;
  FLifetime := ALifetimeSeconds;
  FCookieName := 'askr_session';
end;

destructor TSessionStore.Destroy;
begin
  FKeys.Free;
  FLock.Free;
  inherited Destroy;
end;

function TSessionStore.SlotFor(const Id: string): Integer;
var
  I: Integer;
begin
  I := FKeys.IndexOf(Id);
  if I < 0 then
    Exit(-1);
  Result := PtrInt(FKeys.Objects[I]);
end;

procedure TSessionStore.Sweep;
var
  I, Slot: Integer;
  Now_: Int64;
begin
  Now_ := UnixNow;
  I := 0;
  while I < FKeys.Count do
  begin
    Slot := PtrInt(FKeys.Objects[I]);
    if FSlots[Slot].ExpiresAt <= Now_ then
    begin
      FSlots[Slot].InUse := False;
      SetLength(FSlots[Slot].Data, 0);
      SetLength(FSlots[Slot].Flash, 0);
      FSlots[Slot].Id := '';
      SetLength(FFree, Length(FFree) + 1);
      FFree[High(FFree)] := Slot;
      FKeys.Delete(I);
      Inc(FExpired);
    end
    else
      Inc(I);
  end;
end;

function TSessionStore.Start(Req: TRequest): TSession;
var
  Id: string;
  Slot, I: Integer;
  Prev: TArena;
begin
  Prev := UseArena(Req.Arena);
  try
    Result := TSession.Create;
  finally
    UseArena(Prev);
  end;

  Id := CookieValue(Req, FCookieName);

  FLock.Acquire;
  try
    { Feiing her, ikke i en egen tråd: en sesjonsstore som trenger sin egen
      tråd for å rydde er mer maskineri enn problemet fortjener. }
    if (FKeys.Count > 0) and (Random(64) = 0) then
      Sweep;

    Slot := -1;
    if Length(Id) = 32 then
      Slot := SlotFor(Id);

    if (Slot >= 0) and (FSlots[Slot].ExpiresAt > UnixNow) then
    begin
      Result.FId := Id;
      Result.FNew := False;
      { Kopieres ut i request-arenaen. Lageret beholder sitt eget. }
      SetLength(Result.FData, Length(FSlots[Slot].Data));
      for I := 0 to High(FSlots[Slot].Data) do
        Result.FData[I] := FSlots[Slot].Data[I];
      SetLength(Result.FFlashIn, Length(FSlots[Slot].Flash));
      for I := 0 to High(FSlots[Slot].Flash) do
        Result.FFlashIn[I] := FSlots[Slot].Flash[I];
      Inc(FResumed);
    end
    else
    begin
      Result.FId := NewSessionId;
      Result.FNew := True;
      Inc(FCreated);
    end;
  finally
    FLock.Release;
  end;
end;

procedure TSessionStore.Commit(S: TSession; Res: TResponse);
var
  Slot, I: Integer;
begin
  if S = nil then
    Exit;

  FLock.Acquire;
  try
    Slot := SlotFor(S.Id);
    if Slot < 0 then
    begin
      if Length(FFree) > 0 then
      begin
        Slot := FFree[High(FFree)];
        SetLength(FFree, Length(FFree) - 1);
      end
      else
      begin
        Slot := Length(FSlots);
        SetLength(FSlots, Slot + 1);
      end;
      FSlots[Slot].Id := S.Id;
      FSlots[Slot].InUse := True;
      FKeys.AddObject(S.Id, TObject(PtrInt(Slot)));
    end;

    SetLength(FSlots[Slot].Data, Length(S.FData));
    for I := 0 to High(S.FData) do
      FSlots[Slot].Data[I] := S.FData[I];

    { Flash roteres: det som ble lest denne gangen er borte, det som ble
      skrevet blir lesbart neste gang. }
    SetLength(FSlots[Slot].Flash, Length(S.FFlashOut));
    for I := 0 to High(S.FFlashOut) do
      FSlots[Slot].Flash[I] := S.FFlashOut[I];

    FSlots[Slot].ExpiresAt := UnixNow + FLifetime;
  finally
    FLock.Release;
  end;

  { WithCookie, ikke WithHeader: den siste lar siste verdi vinne per
    headernavn, og da ville CSRF-kaka og sesjonskaka slått hverandre i hjel.
    HttpOnly og SameSite=Lax er standard fordi alternativet er å huske det.
    Secure settes av appen når den vet at den står bak HTTPS. }
  Res.WithCookie(FCookieName, S.Id, FLifetime, FSecure);
end;

procedure TSessionStore.Regenerate(S: TSession);
var
  Old: string;
begin
  if S = nil then
    Exit;
  Old := S.FId;
  S.FId := NewSessionId;
  S.FNew := True;
  S.FDirty := True;
  { Den gamle slotten slettes, ikke bare forlates. En id som fortsatt
    virker etter at den er byttet ut er nøyaktig det angrepet vi stopper. }
  if Old <> '' then
    Destroy_(Old);
end;

procedure TSessionStore.Destroy_(const Id: string);
var
  Slot, I: Integer;
begin
  FLock.Acquire;
  try
    Slot := SlotFor(Id);
    if Slot < 0 then
      Exit;
    FSlots[Slot].InUse := False;
    SetLength(FSlots[Slot].Data, 0);
    SetLength(FSlots[Slot].Flash, 0);
    FSlots[Slot].Id := '';
    SetLength(FFree, Length(FFree) + 1);
    FFree[High(FFree)] := Slot;
    I := FKeys.IndexOf(Id);
    if I >= 0 then
      FKeys.Delete(I);
  finally
    FLock.Release;
  end;
end;

function TSessionStore.Count: Integer;
begin
  FLock.Acquire;
  try
    Result := FKeys.Count;
  finally
    FLock.Release;
  end;
end;

type
  { Middleware er funksjonspekere, og Pascal har ingen lukninger. Lageret
    hentes derfor fra Sessions, ikke fra en fanget variabel. }
  TSessionHook = class
    class function Start(Req: TRequest): TResponse;
    class function Commit(Req: TRequest; Res: TResponse): TResponse;
  end;

class function TSessionHook.Start(Req: TRequest): TResponse;
begin
  UseSession(Sessions.Start(Req));
  { nil betyr «fortsett» — sesjonen er ikke et svar. }
  Result := nil;
end;

class function TSessionHook.Commit(Req: TRequest; Res: TResponse): TResponse;
var
  S: TSession;
begin
  Result := Res;
  S := CurrentSession;

  { Threadvar-en ryddes FØRST, ikke til slutt.

    Sesjonen lever i request-arenaen og forsvinner ved Reset; threadvar-en
    gjør ikke det. Sto oppryddingen nederst, slapp to utganger forbi den —
    og den ene er helt vanlig: en anonym besøkende som starter en sesjon
    uten å skrive til den. Neste request på den workeren fikk da en peker
    inn i minne arenaen hadde gjenbrukt.

    Den feilen viste seg som EAccessViolation når en nettleser hentet en
    css-fil rett etter en side på samme tilkobling — og bare når fila fikk
    plass i blokka som alt var i bruk. En stor fil fikk en ny blokk, det
    gamle minnet lå urørt, og den samme feilen gikk stille forbi. }
  UseSession(nil);

  if S = nil then
    Exit;
  { En ny sesjon ingen skrev til, lagres ikke og får ingen kake. Without dette
    ville hver anonyme besøkende — hver robot, hvert helsesjekk-kall — fått
    en plass i lageret og en kake å sende tilbake. Lageret ligger i
    prosessen, så det er hukommelse som vokser med trafikk og ikke med
    brukere.

    Sessions.Commit kalt direkte gjør fortsatt som den blir bedt om. Det er
    bare den automatiske veien som er tilbakeholden. }
  if S.IsNew and not S.Dirty then
    Exit;
  Sessions.Commit(S, Res);
end;

procedure UseSessions(R: TRouter);
begin
  { Sessions kaster selv hvis ingen lager er satt. Kallet står her for at
    feilen skal komme ved oppstart, ikke ved første request. }
  Sessions;
  R.Use(TSessionHook.Start);
  R.After(TSessionHook.Commit);
end;

initialization
  Randomize;


end.
