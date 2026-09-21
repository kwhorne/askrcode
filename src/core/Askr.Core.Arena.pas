{ Askr.Core.Arena — a bump allocator whose lifetime is one request.

  The model is described in the PRD: a request has an obvious beginning
  and end, so everything allocated along the way is freed in a single
  operation. A worker owns one arena and calls Reset before each request.
  The blocks are kept between requests, so after a few hundred requests
  the arena stops asking the OS for more memory. That is what gives low
  and predictable RSS.

  The rules a user has to understand:

    * Values that must outlive the request must not live in the request
      arena. Such APIs take their own allocator.
    * Background jobs never borrow the request's arena; they get their
      own.
    * A Pascal string is refcounted by the compiler and lives on the heap.
      It is safe, but it is not freed by Reset. Use TStr from
      Askr.Core.Text for strings that are to live in the arena.
    * Destructors are never called on arena objects. Anything owning an
      external resource (a file handle, a socket) has to be handled
      explicitly.
  }
unit Askr.Core.Arena;

{$mode Delphi}{$H+}

interface

uses
  SysUtils;

const
  { The default block size. The first block costs one GetMem; after that
    the same block is reused request after request. }
  ArenaDefaultBlockSize = 64 * 1024;

  { Every allocation is rounded up to this. 16 is enough for SSE-aligned
    load/store and for everything Free Pascal itself requires on both
    x86-64 and aarch64. }
  ArenaAlignment = 16;

type
  EArenaError = class(Exception);

  PArenaBlock = ^TArenaBlock;
  TArenaBlock = record
    Next: PArenaBlock;
    Base: PByte;       { start of usable memory }
    Capacity: PtrUInt;
    Used: PtrUInt;
  end;

  { Cleanup for something the arena does not own itself. See TArena.Defer. }
  TArenaCleanup = procedure(Data: Pointer);

  PDeferNode = ^TDeferNode;
  TDeferNode = record
    Proc: TArenaCleanup;
    Data: Pointer;
    Prev: PDeferNode;
  end;

  { A point in the arena you can rewind to. Used by code that needs
    scratch memory inside a request without waiting for the next Reset. }
  TArenaMark = record
    Block: PArenaBlock;
    Used: PtrUInt;
    Live: PtrUInt;
    Defers: PDeferNode;
  end;

  { Declared here because TArena.New<T> is bound to it. }
  TArenaObject = class;

  TArena = class
  private
    FFirst: PArenaBlock;     { the whole chain, owned until the arena dies }
    FCurrent: PArenaBlock;   { the block we are handing out from now }
    FBlockSize: PtrUInt;
    FLive: PtrUInt;          { utdelt siden siste Reset }
    FReserved: PtrUInt;      { totalt bedt om fra OS }
    FHighWater: PtrUInt;     { the largest FLive seen }
    FResetCount: QWord;
    FDeferTop: PDeferNode;
    procedure RunDeferred(StopAt: PDeferNode);
    function ReserveBlock(MinCapacity: PtrUInt): PArenaBlock;
    function BlockFor(Need: PtrUInt): PArenaBlock;
  public
    constructor Create(ABlockSize: PtrUInt = ArenaDefaultBlockSize);
    destructor Destroy; override;

    { Parts_ ut Size bytes. Innholdet er udefinert. }
    function Alloc(Size: PtrUInt): Pointer;
    { As Alloc, but zeroed. }
    function AllocZero(Size: PtrUInt): Pointer;
    { Kopierer Size bytes fra Src inn i arenaen. }
    function AllocCopy(Src: Pointer; Size: PtrUInt): Pointer;

    { Registers cleanup to run at the next Reset, in the reverse order of
      registration.

      This is the answer to what the PRD points at: destructors never run
      on arena objects, so anything owning an external resource — a file
      handle, a socket, a borrowed connection, a PGresult — has to be
      cleaned up explicitly. Defer makes that explicit without forcing
      try/finally back into the controllers.

      The cleanup function must not raise. If it does anyway it is
      swallowed, because a half-finished Reset is worse than a lost error
      message. }
    procedure Defer(Proc: TArenaCleanup; Data: Pointer);

    { Allocates a class instance in the arena. The constructor does not run,
      and the destructor never will. Prefer New<T> or an ordinary
      TArenaObject.Create — then the constructor runs as normal. }
    function NewObject(AClass: TClass): TObject;

    { Req.Arena.New<TCustomer> — the form the PRD writes.

      The constructor runs, the VMT is in place, and the object lives in
      this arena even if another one is ambient. The type parameter is
      bound to TArenaObject deliberately: an arbitrary TObject would end
      up on the heap without the call site noticing, and that is exactly
      the mistake that makes an arena unsafe. }
    function New<T: TArenaObject>: T;

    { True when P points into memory this arena has reserved. It exists so
      tests and debugging can establish where an object actually is,
      rather than trusting that it is there. }
    function Owns(P: Pointer): Boolean;

    { Spol tilbake til start. Blokkene beholdes for neste request. }
    procedure Reset;
    { Release everything but the first block. Rarely called — for instance
      when a single request has blown the arena up and the worker should
      not hold on to the memory. }
    procedure Trim;

    function Mark: TArenaMark;
    procedure Rewind(const AMark: TArenaMark);

    property BlockSize: PtrUInt read FBlockSize;
    { Bytes handed out since the last Reset. Does not count tails skipped
      when an allocation did not fit in the current block. }
    property BytesLive: PtrUInt read FLive;
    { Bytes the arena holds from the OS. This is the number that should
      flatten out. }
    property BytesReserved: PtrUInt read FReserved;
    property HighWaterMark: PtrUInt read FHighWater;
    property ResetCount: QWord read FResetCount;
    function BlockCount: Integer;
  end;
  { Base class for everything that is to live in the request arena.

    NewInstance takes memory from the ambient arena rather than the heap,
    so a perfectly ordinary TCustomer.Create allocates in the arena and
    runs the constructor as normal. FreeInstance does nothing: the memory
    goes away at Reset.

    If the class has fields the compiler manages — string, dynamic array,
    interface — a finalisation is registered to run at Reset. That is
    necessary because the destructor never runs: without it every string
    property on a model would leak heap memory per request. Classes
    without such fields, like TRequest and TResponse, pay nothing for
    this, because their RTTI table is empty.

    With no ambient arena — in a test, say, or in startup code — the class
    falls back to the heap and behaves like an ordinary TObject. Then the
    usual rules apply and Free has to be called. }
  TArenaObject = class(TObject)
  private
    { Non-nil when the instance lives in an arena. Free is then a no-op. }
    FArena: TArena;
  public
    class function NewInstance: TObject; override;
    procedure FreeInstance; override;
    property Arena: TArena read FArena;
    function IsArenaAllocated: Boolean;
  end;



  { The ambient arena for the current thread.

    The host sets this before calling into user code and clears it
    afterwards. That is what makes TArenaObject.Create land in the right
    arena without every single constructor having to take an allocator as
    a parameter. }
  function CurrentArena: TArena;
  function UseArena(A: TArena): TArena;   { returnerer forrige, for gjenoppretting }

  { True when the class has fields that need finalising — string, dynamic
    array, interface. ShortString and plain numbers do not count. }
  function ClassNeedsFinalization(AClass: TClass): Boolean;

implementation

threadvar
  GCurrentArena: TArena;

function CurrentArena: TArena;
begin
  Result := GCurrentArena;
end;

function UseArena(A: TArena): TArena;
begin
  Result := GCurrentArena;
  GCurrentArena := A;
end;

function ClassNeedsFinalization(AClass: TClass): Boolean;
begin
  { Free Pascal emits one init table per class, and it covers only that
    class's own fields. CleanupInstance therefore walks the whole
    inheritance chain, and so must this: a subclass that inherits a string
    field without declaring anything itself has an empty table of its own,
    but still has to be finalised. }
  while AClass <> nil do
  begin
    if PPointer(PByte(AClass) + vmtInitTable)^ <> nil then
      Exit(True);
    AClass := AClass.ClassParent;
  end;
  Result := False;
end;

procedure FinalizeArenaInstance(Data: Pointer);
begin
  TObject(Data).CleanupInstance;
end;

function AlignUp(Value, Alignment: PtrUInt): PtrUInt; inline;
begin
  Result := (Value + (Alignment - 1)) and not (Alignment - 1);
end;

{ TArena }

constructor TArena.Create(ABlockSize: PtrUInt);
begin
  inherited Create;
  if ABlockSize < 4096 then
    ABlockSize := 4096;
  FBlockSize := AlignUp(ABlockSize, ArenaAlignment);
end;

destructor TArena.Destroy;
var
  B, N: PArenaBlock;
begin
  { Has to run before the blocks go away — the nodes live in the arena
    themselves. }
  RunDeferred(nil);
  B := FFirst;
  while B <> nil do
  begin
    N := B^.Next;
    FreeMem(B^.Base);
    System.Dispose(B);
    B := N;
  end;
  FFirst := nil;
  FCurrent := nil;
  inherited Destroy;
end;

function TArena.ReserveBlock(MinCapacity: PtrUInt): PArenaBlock;
var
  Cap: PtrUInt;
begin
  { An allocation larger than the block size gets a block of its own at
    exactly the right size, so one big payload does not permanently double
    the arena. }
  if MinCapacity > FBlockSize then
    Cap := AlignUp(MinCapacity, ArenaAlignment)
  else
    Cap := FBlockSize;

  { System.New, not TArena.New — the method shadows the standard procedure
    inside the class. Free Pascal 3.2.2 let it pass, 3.3.1 does not. }
  System.New(Result);
  Result^.Next := nil;
  Result^.Capacity := Cap;
  Result^.Used := 0;
  Result^.Base := GetMem(Cap);
  if Result^.Base = nil then
  begin
    System.Dispose(Result);
    raise EArenaError.CreateFmt('Arena: could not reserve %d bytes', [Cap]);
  end;
  Inc(FReserved, Cap);
end;

function TArena.BlockFor(Need: PtrUInt): PArenaBlock;
var
  B: PArenaBlock;
begin
  { After a Reset the whole chain is free, so we look forward before asking
    the OS for more. That reuse is what makes RSS flatten out. }
  if FCurrent <> nil then
  begin
    B := FCurrent^.Next;
    while B <> nil do
    begin
      if B^.Capacity - B^.Used >= Need then
        Exit(B);
      B := B^.Next;
    end;
  end;

  Result := ReserveBlock(Need);
  if FCurrent = nil then
  begin
    Result^.Next := FFirst;
    FFirst := Result;
  end
  else
  begin
    Result^.Next := FCurrent^.Next;
    FCurrent^.Next := Result;
  end;
end;

function TArena.Alloc(Size: PtrUInt): Pointer;
var
  Need: PtrUInt;
  B: PArenaBlock;
begin
  if Size = 0 then
    Size := 1;
  Need := AlignUp(Size, ArenaAlignment);

  B := FCurrent;
  if (B = nil) or (B^.Capacity - B^.Used < Need) then
  begin
    B := BlockFor(Need);
    FCurrent := B;
  end;

  Result := B^.Base + B^.Used;
  Inc(B^.Used, Need);
  Inc(FLive, Need);
  if FLive > FHighWater then
    FHighWater := FLive;
end;

function TArena.AllocZero(Size: PtrUInt): Pointer;
begin
  Result := Alloc(Size);
  FillChar(Result^, Size, 0);
end;

function TArena.AllocCopy(Src: Pointer; Size: PtrUInt): Pointer;
begin
  Result := Alloc(Size);
  if Size > 0 then
    Move(Src^, Result^, Size);
end;

function TArena.NewObject(AClass: TClass): TObject;
begin
  { InitInstance zeroes the fields and sets the VMT pointer. The
    constructor does not run — see the comment in the interface
    section. }
  Result := AClass.InitInstance(Alloc(AClass.InstanceSize));
end;

procedure TArena.Defer(Proc: TArenaCleanup; Data: Pointer);
var
  N: PDeferNode;
begin
  if not Assigned(Proc) then
    Exit;
  N := PDeferNode(Alloc(SizeOf(TDeferNode)));
  N^.Proc := Proc;
  N^.Data := Data;
  N^.Prev := FDeferTop;
  FDeferTop := N;
end;

procedure TArena.RunDeferred(StopAt: PDeferNode);
var
  N: PDeferNode;
begin
  while (FDeferTop <> nil) and (FDeferTop <> StopAt) do
  begin
    N := FDeferTop;
    { Taken off the stack first, so a function that raises cannot be run
      again at the next Reset. }
    FDeferTop := N^.Prev;
    try
      N^.Proc(N^.Data);
    except
      { With_ vilje. Se kommentaren ved Defer. }
    end;
  end;
end;

function TArena.New<T>: T;
var
  Prev: TArena;
begin
  { Swaps the ambient arena, so that TArenaObject.NewInstance lands in this
    one and not in another that happens to be set. }
  Prev := UseArena(Self);
  try
    Result := T.Create;
  finally
    UseArena(Prev);
  end;
end;

function TArena.Owns(P: Pointer): Boolean;
var
  B: PArenaBlock;
begin
  B := FFirst;
  while B <> nil do
  begin
    if (PByte(P) >= B^.Base) and (PByte(P) < B^.Base + B^.Capacity) then
      Exit(True);
    B := B^.Next;
  end;
  Result := False;
end;

procedure TArena.Reset;
var
  B: PArenaBlock;
begin
  RunDeferred(nil);
  B := FFirst;
  while B <> nil do
  begin
    B^.Used := 0;
    B := B^.Next;
  end;
  FCurrent := FFirst;
  FLive := 0;
  Inc(FResetCount);
end;

procedure TArena.Trim;
var
  B, N: PArenaBlock;
begin
  RunDeferred(nil);
  if FFirst = nil then
    Exit;
  B := FFirst^.Next;
  while B <> nil do
  begin
    N := B^.Next;
    Dec(FReserved, B^.Capacity);
    FreeMem(B^.Base);
    System.Dispose(B);
    B := N;
  end;
  FFirst^.Next := nil;
  FFirst^.Used := 0;
  FCurrent := FFirst;
  FLive := 0;
end;

function TArena.Mark: TArenaMark;
begin
  Result.Defers := FDeferTop;
  Result.Block := FCurrent;
  if FCurrent <> nil then
    Result.Used := FCurrent^.Used
  else
    Result.Used := 0;
  Result.Live := FLive;
end;

procedure TArena.Rewind(const AMark: TArenaMark);
var
  B: PArenaBlock;
begin
  { Everything registered after the mark is cleaned up now; the rest waits
    for Reset. }
  RunDeferred(AMark.Defers);
  if AMark.Block = nil then
  begin
    Reset;
    Dec(FResetCount);   { Rewind er ikke en request-grense }
    Exit;
  end;
  AMark.Block^.Used := AMark.Used;
  B := AMark.Block^.Next;
  while B <> nil do
  begin
    B^.Used := 0;
    B := B^.Next;
  end;
  FCurrent := AMark.Block;
  FLive := AMark.Live;
end;

function TArena.BlockCount: Integer;
var
  B: PArenaBlock;
begin
  Result := 0;
  B := FFirst;
  while B <> nil do
  begin
    Inc(Result);
    B := B^.Next;
  end;
end;

{ TArenaObject }

class function TArenaObject.NewInstance: TObject;
var
  A: TArena;
begin
  A := GCurrentArena;
  if A = nil then
  begin
    Result := inherited NewInstance;
    TArenaObject(Result).FArena := nil;
    Exit;
  end;
  Result := InitInstance(A.Alloc(InstanceSize));
  TArenaObject(Result).FArena := A;
  if ClassNeedsFinalization(Self) then
    A.Defer(FinalizeArenaInstance, Result);
end;

procedure TArenaObject.FreeInstance;
begin
  { If the instance lives in an arena it goes away at Reset, and handing
    the memory to the heap manager would be corruption. CleanupInstance is
    skipped here because it is already registered as a Defer in
    NewInstance — calling it now would run it twice. }
  if FArena <> nil then
    Exit;
  inherited FreeInstance;
end;

function TArenaObject.IsArenaAllocated: Boolean;
begin
  Result := FArena <> nil;
end;

end.
