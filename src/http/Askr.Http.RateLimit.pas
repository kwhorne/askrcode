{ Askr.Http.RateLimit — how often one caller may ask.

  A token bucket, not a fixed window. A window of a minute lets somebody
  spend the whole allowance in the last second of one window and the
  whole of the next in the first second of the next -- twice the limit
  across two seconds, which is exactly the burst the limit was for. A
  bucket refills continuously and has no seam to sit on.

      RateLimit.PerMinute(600);

  600 a minute is a bucket of 600 that refills at 10 a second. A caller
  may spend the lot at once and then goes at ten a second; `Burst` sets
  the two apart when that is not what you want.

  WHAT IT IS KEYED ON, AND WHAT IT MUST NOT BE

  The key comes from `KeyBy`. The default is the address the connection
  came from, which is what you have before anybody has authenticated.
  `Askr.Auth.Token.TokenRateKey` keys on the token when there is one and
  falls back to the address, which is what an API wants: a limit per
  credential rather than per office.

  **`X-Forwarded-For` is not read, and that is deliberate.** It is a
  header the client writes. Trusting it without knowing exactly how many
  proxies sit in front of you means anybody can put a new value in it on
  every request and have an unlimited quota -- a rate limiter that an
  attacker can opt out of is worse than none, because it is believed.
  Behind a proxy, have the proxy set the address it saw, or key on
  something the caller cannot choose, such as a token.

  MEMORY DOES NOT GROW WITH TRAFFIC

  The table is a fixed number of slots. A new key lands in one of a few
  slots decided by its hash; when they are all taken, one of them is
  taken over. So a flood of distinct addresses cannot grow the process --
  a table that grew instead would be a way to spend a server's memory by
  sending requests, which is part of what this is supposed to answer.

  **Taking a slot over never hands out a fresh allowance.** The new key
  inherits whatever was in the bucket, and how long ago it was touched.
  The first version reset it to full, and that is a way round the whole
  limiter: the hash is a pure function of the key, so anybody can work
  out eight keys that collide with their own, spend them, and have their
  own bucket dropped and refilled. Inheriting instead means the worst a
  collision can do is limit somebody early -- which is the safe
  direction, and rare with four thousand slots and an eight-way probe.

  A slot nobody has touched for a while has a full bucket anyway, so the
  ordinary case of an idle key being displaced costs nothing. }
unit Askr.Http.RateLimit;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Math, SyncObjs,
  Askr.Core.Text, Askr.Core.Clock,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response, Askr.Http.Router;

type
  { Decides which bucket a request belongs to. An empty string means the
    request is not limited at all. }
  TRateKeyFunc = function(Req: TRequest): string;

const
  { Slots in the table, and how many are probed for one key. Fixed, so
    the memory is fixed. }
  RateSlots = 4096;
  RateProbe = 8;

type
  TRateSlot = record
    Key: string;
    Tokens: Double;
    Last: Int64;      { MonotonicMs }
    Used: Boolean;
  end;

  TRateLimit = class
  private
    FCapacity: Double;
    FPerSecond: Double;
    FKeyBy: TRateKeyFunc;
    FLock: TCriticalSection;
    FSlots: array[0..RateSlots - 1] of TRateSlot;
    function SlotFor(const Key: string; Now_: Int64): Integer;
  public
    constructor Create;
    destructor Destroy; override;

    { The steady rate, and the burst that comes with it. PerMinute(600)
      is a bucket of 600 refilling at ten a second. }
    function PerMinute(N: Integer): TRateLimit;
    { A different burst from the bucket the rate implies. }
    function Burst(N: Integer): TRateLimit;
    function KeyBy(F: TRateKeyFunc): TRateLimit;

    { Takes one token for Key. False when there is none; RetryAfter is
      then the whole seconds until there is, and never less than 1 -- a
      Retry-After of 0 is an invitation to a loop. }
    { The slot a key hashes to. Exposed because it is a pure function of
      the key and therefore something anybody can work out: a test that
      constructs a collision on purpose is doing what an attacker would,
      and that is the case worth holding down. }
    function Take(const Key: string; out RetryAfter, Remaining: Integer): Boolean;
    { Which key this request falls under. }
    function KeyFor(Req: TRequest): string;
    { Forgets every bucket. For tests, and for a process that wants to
      start over. }
    procedure Clear;
    { Turns it off again, and forgets everything. For a test, and for an
      application that configures it conditionally. }
    procedure Off;
    { How many slots are in use. The point of it is that this number has
      a ceiling. }
    function SlotsUsed: Integer;

    function Enabled: Boolean;
    property Capacity: Double read FCapacity;
  end;

{ The limiter. One per process, configured at startup. Off until
  PerMinute is called. }
{ FNV-1a over the key, which decides the slot. See TRateLimit for why
  this is not a secret. }
function RateHash(const S: string): Cardinal;

function RateLimit: TRateLimit;

{ The address the connection came from, or '-' when there is none.

  One shared bucket for everything unidentifiable rather than no limit
  at all: a request nobody can tell apart from another is still a
  request, and letting it through unlimited is the wrong way to be
  unsure. }
function RemoteAddrKey(Req: TRequest): string;

{ Refuses with 429 and Retry-After once a caller is over.

  Register it after UseCors -- a preflight is the browser's, not the
  caller's, and should not spend anybody's allowance -- and after
  whatever establishes who the caller is, so the key can name them. }
procedure UseRateLimit(R: TRouter);

implementation

var
  GLimit: TRateLimit = nil;

threadvar
  { What the middleware measured for this request, for the after-filter
    to put on the reply. Set on every request the middleware sees, so
    there is nothing to carry over. }
  GHasInfo: Boolean;
  GRemaining: Integer;

function RateLimit: TRateLimit;
begin
  if GLimit = nil then
    GLimit := TRateLimit.Create;
  Result := GLimit;
end;

function RemoteAddrKey(Req: TRequest): string;
begin
  Result := '';
  if Req <> nil then
    Result := Req.RemoteAddr.ToString;
  if Result = '' then
    Result := '-';
end;

constructor TRateLimit.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FKeyBy := RemoteAddrKey;
  FCapacity := 0;
  FPerSecond := 0;
end;

destructor TRateLimit.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

function TRateLimit.PerMinute(N: Integer): TRateLimit;
begin
  Result := Self;
  if N <= 0 then
    raise Exception.Create(
      'A rate limit of zero would refuse everything. Leave the limiter ' +
      'unconfigured instead; it is off until PerMinute is called.');
  FPerSecond := N / 60.0;
  if FCapacity <= 0 then
    FCapacity := N;
end;

function TRateLimit.Burst(N: Integer): TRateLimit;
begin
  Result := Self;
  if N > 0 then
    FCapacity := N;
end;

function TRateLimit.KeyBy(F: TRateKeyFunc): TRateLimit;
begin
  Result := Self;
  if Assigned(F) then
    FKeyBy := F;
end;

function TRateLimit.Enabled: Boolean;
begin
  Result := (FPerSecond > 0) and (FCapacity > 0);
end;

function TRateLimit.KeyFor(Req: TRequest): string;
begin
  Result := '';
  if Assigned(FKeyBy) then
    Result := FKeyBy(Req);
end;

{ FNV-1a. Marked like the other four in Askr: the algorithm is built on
  the multiplication overflowing, and without the marking it raises under
  -Cr -Co -Ci and quietly carries on without. }
{$push}{$R-}{$Q-}
function RateHash(const S: string): Cardinal;
var
  I: Integer;
begin
  Result := 2166136261;
  for I := 1 to Length(S) do
  begin
    Result := Result xor Cardinal(Ord(S[I]));
    Result := Result * 16777619;
  end;
end;
{$pop}

{ The slot for Key: the one that already holds it, else a free one among
  the few probed, else one of them taken over. Never grows. }
function TRateLimit.SlotFor(const Key: string; Now_: Int64): Integer;
var
  H, I, Idx, Victim: Integer;
begin
  H := Integer(RateHash(Key) mod RateSlots);
  Victim := -1;
  for I := 0 to RateProbe - 1 do
  begin
    Idx := (H + I) mod RateSlots;
    if not FSlots[Idx].Used then
    begin
      FSlots[Idx].Used := True;
      FSlots[Idx].Key := Key;
      FSlots[Idx].Tokens := FCapacity;
      FSlots[Idx].Last := Now_;
      Exit(Idx);
    end;
    if FSlots[Idx].Key = Key then
      Exit(Idx);
    { The least constrained of them is the one to displace: whoever has
      the most left is the one least in need of the slot. }
    if (Victim < 0) or (FSlots[Idx].Tokens > FSlots[Victim].Tokens) then
      Victim := Idx;
  end;

  { All taken. Only the name changes: the bucket and the time it was last
    touched are inherited, so taking a slot over can never hand out a
    fresh allowance. An idle slot is full anyway, and a slot somebody has
    just emptied stays empty -- which is what stops eight keys chosen to
    collide from being a way round the limit. }
  FSlots[Victim].Key := Key;
  Result := Victim;
end;

function TRateLimit.Take(const Key: string;
  out RetryAfter, Remaining: Integer): Boolean;
var
  Idx: Integer;
  Now_: Int64;
  Elapsed: Double;
begin
  RetryAfter := 0;
  Remaining := 0;
  if not Enabled then
    Exit(True);

  Now_ := MonotonicMs;
  FLock.Acquire;
  try
    Idx := SlotFor(Key, Now_);

    { Monotonic, so it does not jump when the clock is set or when
      summer time starts. }
    Elapsed := (Now_ - FSlots[Idx].Last) / 1000.0;
    if Elapsed > 0 then
    begin
      FSlots[Idx].Tokens := Min(FCapacity,
        FSlots[Idx].Tokens + Elapsed * FPerSecond);
      FSlots[Idx].Last := Now_;
    end;

    if FSlots[Idx].Tokens >= 1 then
    begin
      FSlots[Idx].Tokens := FSlots[Idx].Tokens - 1;
      Remaining := Trunc(FSlots[Idx].Tokens);
      Exit(True);
    end;

    { Never zero: a Retry-After of 0 says "now", and a client that obeys
      it spins. }
    RetryAfter := Max(1, Ceil((1 - FSlots[Idx].Tokens) / FPerSecond));
    Result := False;
  finally
    FLock.Release;
  end;
end;

procedure TRateLimit.Clear;
var
  I: Integer;
begin
  FLock.Acquire;
  try
    for I := 0 to RateSlots - 1 do
    begin
      FSlots[I].Used := False;
      FSlots[I].Key := '';
      FSlots[I].Tokens := 0;
      FSlots[I].Last := 0;
    end;
  finally
    FLock.Release;
  end;
end;

procedure TRateLimit.Off;
begin
  FPerSecond := 0;
  FCapacity := 0;
  Clear;
end;

function TRateLimit.SlotsUsed: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to RateSlots - 1 do
    if FSlots[I].Used then
      Inc(Result);
end;

{ ---------------------------------------------------------- middleware -- }

type
  TRateHook = class
    class function Handle(Req: TRequest): TResponse;
    class function Decorate(Req: TRequest; Res: TResponse): TResponse;
  end;

class function TRateHook.Handle(Req: TRequest): TResponse;
var
  L: TRateLimit;
  Key: string;
  RetryAfter, Remaining: Integer;
begin
  Result := nil;
  { First, and unconditionally: whatever this worker measured for the
    last request is not this one's. }
  GHasInfo := False;
  GRemaining := 0;

  L := RateLimit;
  if not L.Enabled then
    Exit;
  Key := L.KeyFor(Req);
  if Key = '' then
    Exit;

  if L.Take(Key, RetryAfter, Remaining) then
  begin
    GHasInfo := True;
    GRemaining := Remaining;
    Exit;
  end;

  { ErrorResponse, so a JSON client gets a problem document and everybody
    else the plain text they have always had. }
  Result := ErrorResponse(429, 'Too many requests.')
    .WithHeader('Retry-After', IntToStr(RetryAfter))
    .WithHeader('X-RateLimit-Limit', IntToStr(Trunc(L.Capacity)))
    .WithHeader('X-RateLimit-Remaining', '0')
    .WithHeader('X-RateLimit-Reset', IntToStr(RetryAfter));
end;

class function TRateHook.Decorate(Req: TRequest; Res: TResponse): TResponse;
begin
  Result := Res;
  if (Res = nil) or not GHasInfo then
    Exit;
  { So a client can slow down before it is refused rather than after.
    Both numbers are counts and the reset is seconds from now, the same
    unit as Retry-After -- a timestamp here would be a second thing to
    get the timezone of wrong. }
  Res.WithHeader('X-RateLimit-Limit', IntToStr(Trunc(RateLimit.Capacity)));
  Res.WithHeader('X-RateLimit-Remaining', IntToStr(GRemaining));
end;

procedure UseRateLimit(R: TRouter);
begin
  R.Use(TRateHook.Handle);
  R.After(TRateHook.Decorate);
end;

end.
