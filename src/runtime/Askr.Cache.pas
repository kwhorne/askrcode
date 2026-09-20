{ Askr.Cache — delt cache i samme prosess.

  PRD-ens første regel sier at verdier som skal overleve requesten ikke må
  ligge i request-arenaen, og at slike API-er tar sin egen allokator:

      Cache.Put(Key, Value.CloneTo(App.Heap))

  Denne implementasjonen går lenger: kopieringen er ikke noe kalleren gjør,
  den er noe API-et gjør. Put kopierer inn i cachens eget minne, og Get
  kopierer ut i kallerens arena.

  Det er ikke pynt. To ting følger av det, og begge er nødvendige:

    * Cachen kan kaste ut en post når som helst uten at noen sitter med en
      peker inn i minnet som forsvant.
    * Verdien kalleren får, dør med requesten. Den kan ikke ved et uhell bli
      liggende og peke inn i cachen etter at låsen er sluppet.

  Med en arena som bare er en konvensjon ville begge deler vært opp til den
  som skriver kontrolleren. Her er de umulige å gjøre feil.

  Låsene er delt i shards. Én lås for hele cachen ville serialisert alle
  workerne mot hverandre, og da er en cache verre enn ingen cache. }
unit Askr.Cache;

{$mode Delphi}{$H+}
{$POINTERMATH ON}

interface

uses
  SysUtils, SyncObjs, Askr.Core.Arena, Askr.Core.Text, Askr.Core.Clock;

type
  ECacheError = class(Exception);

  PCacheEntry = ^TCacheEntry;
  TCacheEntry = record
    Key: string;
    Hash: Cardinal;
    Data: PByte;
    Len: SizeInt;
    ExpiresAt: Int64;   { unix-sekunder; 0 = aldri }
    { LRU-kjede innenfor sharden. }
    Prev, Next: PCacheEntry;
    { Kjede for hash-bøtta. }
    HashNext: PCacheEntry;
  end;

  TCacheShard = record
    Lock: TCriticalSection;
    Buckets: array of PCacheEntry;
    Head, Tail: PCacheEntry;    { Head = sist brukt }
    Count: Integer;
    MaxCount: Integer;
  end;

  { Regner ut verdien når den ikke finnes. Skriver til B. }
  TCacheCompute = procedure(var B: TStrBuilder);

  TCache = class
  private
    FShards: array of TCacheShard;
    FShardMask: Cardinal;
    FHits, FMisses, FEvictions, FExpired: QWord;
    function ShardFor(Hash: Cardinal): Integer;
    procedure Touch(var S: TCacheShard; E: PCacheEntry);
    procedure Unlink(var S: TCacheShard; E: PCacheEntry);
    procedure LinkFront(var S: TCacheShard; E: PCacheEntry);
    procedure RemoveEntry(var S: TCacheShard; E: PCacheEntry);
    function Find(var S: TCacheShard; const Key: string;
      Hash: Cardinal): PCacheEntry;
    procedure EvictIfNeeded(var S: TCacheShard);
  public
    { MaxEntries er totalt, fordelt likt på shards. }
    constructor Create(AMaxEntries: Integer = 8192; AShards: Integer = 16);
    destructor Destroy; override;

    { Verdien kopieres inn i cachens minne. TtlSeconds 0 = uten utløp. }
    procedure Put(const Key: string; const Value: TStr;
      TtlSeconds: Integer = 0); overload;
    procedure Put(const Key, Value: string;
      TtlSeconds: Integer = 0); overload;

    { Verdien kopieres ut i A. False når den ikke finnes eller er utløpt. }
    function Get(A: TArena; const Key: string; out Value: TStr): Boolean; overload;
    function Get(const Key: string; out Value: string): Boolean; overload;

    function Has(const Key: string): Boolean;
    procedure Forget(const Key: string);
    procedure Flush;

    { Henter, eller regner ut og lagrer. Resultatet ligger i A. }
    function Remember(A: TArena; const Key: string; TtlSeconds: Integer;
      Compute: TCacheCompute): TStr;

    function Count: Integer;
    property Hits: QWord read FHits;
    property Misses: QWord read FMisses;
    property Evictions: QWord read FEvictions;
    property Expired: QWord read FExpired;
  end;

{ Prosessens cache. Verten lager den ved oppstart. }
function Cache: TCache;
procedure SetCache(ACache: TCache);

implementation

{ FNV-1a er tuftet på at multiplikasjonen flyter over og brytes modulo
  ordstørrelsen — det er ikke et uhell, det er algoritmen. Bygger noen med
  -Cr eller -Co, som er helt rimelig i en debug-bygging, blir den tilsiktede
  wraparounden til en ERangeError. Avhengigheten står derfor her i stedet for
  å være stilltiende. }
{$push}{$R-}{$Q-}
{ FNV-1a er tuftet på at multiplikasjonen flyter over og brytes modulo
  ordstørrelsen — det er ikke et uhell, det er algoritmen. Bygger noen med
  -Cr eller -Co, som er helt rimelig i en debug-bygging, blir den tilsiktede
  wraparounden til en ERangeError. Avhengigheten står derfor her i stedet for
  å være stilltiende. }
{$push}{$R-}{$Q-}
function HashKey(const S: string): Cardinal;
var
  I: Integer;
  H: Cardinal;
begin
  H := 2166136261;
  for I := 1 to Length(S) do
  begin
    H := H xor Cardinal(Ord(S[I]));
    H := H * 16777619;
  end;
  Result := H;
end;
{$pop}
{$pop}

var
  GCache: TCache = nil;

function Cache: TCache;
begin
  if GCache = nil then
    raise ECacheError.Create(
      'No cache is configured. Call SetCache at startup.');
  Result := GCache;
end;

procedure SetCache(ACache: TCache);
begin
  GCache := ACache;
end;

{ TCache }

constructor TCache.Create(AMaxEntries, AShards: Integer);
var
  I, N, PerShard, Buckets: Integer;
begin
  inherited Create;
  { Antall shards rundes opp til en toerpotens, slik at valget blir en
    maskering og ikke en divisjon. }
  N := 1;
  while N < AShards do
    N := N * 2;
  if N > 256 then
    N := 256;
  FShardMask := Cardinal(N - 1);

  PerShard := AMaxEntries div N;
  if PerShard < 16 then
    PerShard := 16;
  Buckets := 1;
  while Buckets < PerShard * 2 do
    Buckets := Buckets * 2;

  SetLength(FShards, N);
  for I := 0 to N - 1 do
  begin
    FShards[I].Lock := TCriticalSection.Create;
    SetLength(FShards[I].Buckets, Buckets);
    FShards[I].MaxCount := PerShard;
  end;
end;

destructor TCache.Destroy;
var
  I: Integer;
begin
  Flush;
  for I := 0 to High(FShards) do
    FShards[I].Lock.Free;
  inherited Destroy;
end;

function TCache.ShardFor(Hash: Cardinal): Integer;
begin
  { Høye bitene til shard, lave til bøtte — ellers havner alt i samme bøtte
    innenfor sharden. }
  Result := Integer((Hash shr 24) and FShardMask);
end;

procedure TCache.Unlink(var S: TCacheShard; E: PCacheEntry);
begin
  if E^.Prev <> nil then
    E^.Prev^.Next := E^.Next
  else
    S.Head := E^.Next;
  if E^.Next <> nil then
    E^.Next^.Prev := E^.Prev
  else
    S.Tail := E^.Prev;
  E^.Prev := nil;
  E^.Next := nil;
end;

procedure TCache.LinkFront(var S: TCacheShard; E: PCacheEntry);
begin
  E^.Prev := nil;
  E^.Next := S.Head;
  if S.Head <> nil then
    S.Head^.Prev := E;
  S.Head := E;
  if S.Tail = nil then
    S.Tail := E;
end;

procedure TCache.Touch(var S: TCacheShard; E: PCacheEntry);
begin
  if S.Head = E then
    Exit;
  Unlink(S, E);
  LinkFront(S, E);
end;

function TCache.Find(var S: TCacheShard; const Key: string;
  Hash: Cardinal): PCacheEntry;
var
  E: PCacheEntry;
begin
  E := S.Buckets[Hash and Cardinal(High(S.Buckets))];
  while E <> nil do
  begin
    if (E^.Hash = Hash) and (E^.Key = Key) then
      Exit(E);
    E := E^.HashNext;
  end;
  Result := nil;
end;

procedure TCache.RemoveEntry(var S: TCacheShard; E: PCacheEntry);
var
  Idx: Cardinal;
  Cur, Prev: PCacheEntry;
begin
  Idx := E^.Hash and Cardinal(High(S.Buckets));
  Cur := S.Buckets[Idx];
  Prev := nil;
  while Cur <> nil do
  begin
    if Cur = E then
    begin
      if Prev = nil then
        S.Buckets[Idx] := Cur^.HashNext
      else
        Prev^.HashNext := Cur^.HashNext;
      Break;
    end;
    Prev := Cur;
    Cur := Cur^.HashNext;
  end;
  Unlink(S, E);
  Dec(S.Count);
  if E^.Data <> nil then
    FreeMem(E^.Data);
  E^.Key := '';
  Dispose(E);
end;

procedure TCache.EvictIfNeeded(var S: TCacheShard);
begin
  while (S.Count >= S.MaxCount) and (S.Tail <> nil) do
  begin
    { Minst nylig brukt ryker først. }
    RemoveEntry(S, S.Tail);
    Inc(FEvictions);
  end;
end;

procedure TCache.Put(const Key: string; const Value: TStr; TtlSeconds: Integer);
var
  H: Cardinal;
  Idx: Integer;
  E: PCacheEntry;
  Bucket: Cardinal;
begin
  H := HashKey(Key);
  Idx := ShardFor(H);
  FShards[Idx].Lock.Acquire;
  try
    E := Find(FShards[Idx], Key, H);
    if E <> nil then
    begin
      if E^.Data <> nil then
        FreeMem(E^.Data);
      E^.Data := nil;
      E^.Len := 0;
    end
    else
    begin
      EvictIfNeeded(FShards[Idx]);
      New(E);
      FillChar(E^, SizeOf(TCacheEntry), 0);
      E^.Key := Key;
      E^.Hash := H;
      Bucket := H and Cardinal(High(FShards[Idx].Buckets));
      E^.HashNext := FShards[Idx].Buckets[Bucket];
      FShards[Idx].Buckets[Bucket] := E;
      LinkFront(FShards[Idx], E);
      Inc(FShards[Idx].Count);
    end;

    { Her er grensen. Bytene kopieres ut av kallerens arena og inn i minne
      cachen eier, fordi arenaen nullstilles ved neste request. }
    if Value.Len > 0 then
    begin
      E^.Data := GetMem(Value.Len);
      Move(Value.Data^, E^.Data^, Value.Len);
    end;
    E^.Len := Value.Len;

    if TtlSeconds > 0 then
      E^.ExpiresAt := UnixNow + TtlSeconds
    else
      E^.ExpiresAt := 0;

    Touch(FShards[Idx], E);
  finally
    FShards[Idx].Lock.Release;
  end;
end;

procedure TCache.Put(const Key, Value: string; TtlSeconds: Integer);
begin
  Put(Key, Str(Value), TtlSeconds);
end;

function TCache.Get(A: TArena; const Key: string; out Value: TStr): Boolean;
var
  H: Cardinal;
  Idx: Integer;
  E: PCacheEntry;
  Buf: PByte;
  Len: SizeInt;
begin
  Value := StrEmpty;
  H := HashKey(Key);
  Idx := ShardFor(H);
  Buf := nil;
  Len := 0;

  FShards[Idx].Lock.Acquire;
  try
    E := Find(FShards[Idx], Key, H);
    if E = nil then
    begin
      Inc(FMisses);
      Exit(False);
    end;
    if (E^.ExpiresAt <> 0) and (UnixNow >= E^.ExpiresAt) then
    begin
      RemoveEntry(FShards[Idx], E);
      Inc(FExpired);
      Inc(FMisses);
      Exit(False);
    end;
    Touch(FShards[Idx], E);

    { Kopieres ut mens låsen holdes, inn i kallerens arena. Da kan cachen
      kaste ut posten et mikrosekund senere uten at noen merker det. }
    Len := E^.Len;
    if Len > 0 then
    begin
      Buf := PByte(A.Alloc(Len));
      Move(E^.Data^, Buf^, Len);
    end;
    Inc(FHits);
  finally
    FShards[Idx].Lock.Release;
  end;

  Value := StrRef(Buf, Len);
  Result := True;
end;

function TCache.Get(const Key: string; out Value: string): Boolean;
var
  A: TArena;
  S: TStr;
begin
  Value := '';
  { Egen arena: denne formen finnes for oppstartskode og bakgrunnsjobber som
    ikke har en request-arena for hånden. }
  A := TArena.Create(4096);
  try
    Result := Get(A, Key, S);
    if Result then
      Value := S.ToString;
  finally
    A.Free;
  end;
end;

function TCache.Has(const Key: string): Boolean;
var
  H: Cardinal;
  Idx: Integer;
  E: PCacheEntry;
begin
  H := HashKey(Key);
  Idx := ShardFor(H);
  FShards[Idx].Lock.Acquire;
  try
    E := Find(FShards[Idx], Key, H);
    if E = nil then
      Exit(False);
    if (E^.ExpiresAt <> 0) and (UnixNow >= E^.ExpiresAt) then
    begin
      RemoveEntry(FShards[Idx], E);
      Inc(FExpired);
      Exit(False);
    end;
    Result := True;
  finally
    FShards[Idx].Lock.Release;
  end;
end;

procedure TCache.Forget(const Key: string);
var
  H: Cardinal;
  Idx: Integer;
  E: PCacheEntry;
begin
  H := HashKey(Key);
  Idx := ShardFor(H);
  FShards[Idx].Lock.Acquire;
  try
    E := Find(FShards[Idx], Key, H);
    if E <> nil then
      RemoveEntry(FShards[Idx], E);
  finally
    FShards[Idx].Lock.Release;
  end;
end;

procedure TCache.Flush;
var
  I: Integer;
begin
  for I := 0 to High(FShards) do
  begin
    FShards[I].Lock.Acquire;
    try
      while FShards[I].Tail <> nil do
        RemoveEntry(FShards[I], FShards[I].Tail);
    finally
      FShards[I].Lock.Release;
    end;
  end;
end;

function TCache.Remember(A: TArena; const Key: string; TtlSeconds: Integer;
  Compute: TCacheCompute): TStr;
var
  B: TStrBuilder;
begin
  if Get(A, Key, Result) then
    Exit;
  B.Init(A, 512);
  Compute(B);
  Result := B.ToStr;
  Put(Key, Result, TtlSeconds);
end;

function TCache.Count: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FShards) do
  begin
    FShards[I].Lock.Acquire;
    try
      Inc(Result, FShards[I].Count);
    finally
      FShards[I].Lock.Release;
    end;
  end;
end;

end.
