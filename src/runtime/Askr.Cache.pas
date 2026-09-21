{ Askr.Cache — a shared cache in the same process.

  The PRD's first rule says values that are to outlive the request must
  not live in the request arena, and that such APIs take their own
  allocator:

      Cache.Put(Key, Value.CloneTo(App.Heap))

  This implementation goes further: the copying is not something the
  caller does, it is something the API does. Put copies into the cache's
  own memory, and Get copies out into the caller's arena.

  That is not decoration. Two things follow from it, and both are
  necessary:

    * The cache can evict an entry at any time without anyone holding a
      pointer into memory that went away.
    * The value the caller gets dies with the request. It cannot
      accidentally be left pointing into the cache after the lock is
      released.

  With an arena that is only a convention, both of those would be up to
  whoever writes the controller. Here they are impossible to get wrong.

  The locks are split into shards. One lock for the whole cache would
  serialise every worker against every other, and then a cache is worse
  than no cache. }
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
    { The chain for the hash bucket. }
    HashNext: PCacheEntry;
  end;

  TCacheShard = record
    Lock: TCriticalSection;
    Buckets: array of PCacheEntry;
    Head, Tail: PCacheEntry;    { Head = sist brukt }
    Count: Integer;
    MaxCount: Integer;
  end;

  { Computes the value when it is missing. Writes into B. }
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
    { MaxEntries is the total, divided evenly across the shards. }
    constructor Create(AMaxEntries: Integer = 8192; AShards: Integer = 16);
    destructor Destroy; override;

    { The value is copied into the cache's memory. TtlSeconds 0 = no
      expiry. }
    procedure Put(const Key: string; const Value: TStr;
      TtlSeconds: Integer = 0); overload;
    procedure Put(const Key, Value: string;
      TtlSeconds: Integer = 0); overload;

    { The value is copied out into A. False when it is missing or
      expired. }
    function Get(A: TArena; const Key: string; out Value: TStr): Boolean; overload;
    function Get(const Key: string; out Value: string): Boolean; overload;

    function Has(const Key: string): Boolean;
    procedure Forget(const Key: string);
    procedure Flush;

    { Fetches, or computes and stores. The result lives in A. }
    function Remember(A: TArena; const Key: string; TtlSeconds: Integer;
      Compute: TCacheCompute): TStr;

    function Count: Integer;
    property Hits: QWord read FHits;
    property Misses: QWord read FMisses;
    property Evictions: QWord read FEvictions;
    property Expired: QWord read FExpired;
  end;

{ The process's cache. The host creates it at startup. }
function Cache: TCache;
procedure SetCache(ACache: TCache);

implementation

{ FNV-1a rests on the multiplication overflowing and wrapping modulo the
  word size — that is not an accident, it is the algorithm. If somebody
  builds with -Cr or -Co, which is perfectly reasonable in a debug build,
  the intended wraparound becomes an ERangeError. The dependency is
  therefore written down here rather than being tacit. }
{$push}{$R-}{$Q-}
{ FNV-1a rests on the multiplication overflowing and wrapping modulo the
  word size — that is not an accident, it is the algorithm. If somebody
  builds with -Cr or -Co, which is perfectly reasonable in a debug build,
  the intended wraparound becomes an ERangeError. The dependency is
  therefore written down here rather than being tacit. }
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
  { The shard count is rounded up to a power of two, so the choice is a
    mask and not a division. }
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
  { The high bits pick the shard, the low ones the bucket — otherwise
    everything lands in the same bucket within the shard. }
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
    { Least recently used goes first. }
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

    { This is the boundary. The bytes are copied out of the caller's arena
      and into memory the cache owns, because the arena is reset at the
      next request. }
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

    { Copied out while the lock is held, into the caller's arena. Then the
      cache can evict the entry a microsecond later without anyone
      noticing. }
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
  { Its own arena: this form exists for startup code and background jobs
    that have no request arena to hand. }
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
