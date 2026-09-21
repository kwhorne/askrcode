{ Askr.Core.Arena — bump allocator med levetid lik én request.

  Modellen er beskrevet i PRD-en: en request har en åpenbar start og slutt, så
  alt som allokeres underveis frigjøres i én operasjon. En worker eier én arena
  og kaller Reset før hver request. Blokkene beholdes mellom requests, så etter
  noen hundre requests slutter arenaen å be OS om mer minne. Det er dette som
  gir lav og forutsigbar RSS.

  Reglene brukeren må forstå:

    * Verdier som skal overleve requesten må ikke ligge i request-arenaen.
      Slike API-er tar sin egen allokator.
    * Bakgrunnsjobber låner aldri requestens arena, de får en egen.
    * Pascals string er refcountet av kompilatoren og ligger på heapen. Den er
      trygg, men frigjøres ikke av Reset. Bruk TStr fra Askr.Core.Text for
      strenger som skal leve i arenaen.
    * Destructorer kalles aldri på arena-objekter. Alt som eier en ekstern
      ressurs (filhåndtak, socket) må håndteres eksplisitt.
}
unit Askr.Core.Arena;

{$mode Delphi}{$H+}

interface

uses
  SysUtils;

const
  { Standard blokkstørrelse. Første blokk koster én GetMem; deretter gjenbrukes
    den samme blokken request etter request. }
  ArenaDefaultBlockSize = 64 * 1024;

  { All_ allokeringer rundes opp hit. 16 holder for SSE-alignet last/store og
    for alt Free Pascal selv krever på både x86-64 og aarch64. }
  ArenaAlignment = 16;

type
  EArenaError = class(Exception);

  PArenaBlock = ^TArenaBlock;
  TArenaBlock = record
    Next: PArenaBlock;
    Base: PByte;       { start på brukbart minne }
    Capacity: PtrUInt;
    Used: PtrUInt;
  end;

  { Opprydning for noe arenaen ikke selv eier. Se TArena.Defer. }
  TArenaCleanup = procedure(Data: Pointer);

  PDeferNode = ^TDeferNode;
  TDeferNode = record
    Proc: TArenaCleanup;
    Data: Pointer;
    Prev: PDeferNode;
  end;

  { Et punkt i arenaen man kan spole tilbake til. Brukes av kode som trenger
    midlertidig minne inne i en request uten å vente på neste Reset. }
  TArenaMark = record
    Block: PArenaBlock;
    Used: PtrUInt;
    Live: PtrUInt;
    Defers: PDeferNode;
  end;

  { Deklareres her fordi TArena.New<T> er bundet til den. }
  TArenaObject = class;

  TArena = class
  private
    FFirst: PArenaBlock;     { hele kjeden, eid til arenaen dør }
    FCurrent: PArenaBlock;   { blokken vi deler ut fra nå }
    FBlockSize: PtrUInt;
    FLive: PtrUInt;          { utdelt siden siste Reset }
    FReserved: PtrUInt;      { totalt bedt om fra OS }
    FHighWater: PtrUInt;     { største FLive sett }
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
    { Som Alloc, men nullstilt. }
    function AllocZero(Size: PtrUInt): Pointer;
    { Kopierer Size bytes fra Src inn i arenaen. }
    function AllocCopy(Src: Pointer; Size: PtrUInt): Pointer;

    { Registrerer opprydning som kjører ved neste Reset, i motsatt rekkefølge
      av registreringen.

      Dette er svaret på det PRD-en peker på: destructorer kjører aldri på
      arena-objekter, så alt som eier en ekstern ressurs — filhåndtak, socket,
      en lånt connection, en PGresult — må ryddes eksplisitt. Defer gjør det
      eksplisitt uten å tvinge try/finally tilbake inn i kontrollerene.

      Opprydningsfunksjonen må ikke kaste. Gjør den det likevel, svelges det,
      fordi en halvferdig Reset er verre enn en tapt feilmelding. }
    procedure Defer(Proc: TArenaCleanup; Data: Pointer);

    { Allokerer en klasseinstans i arenaen. Constructoren kjører ikke, og
      destructoren vil aldri kjøre. Foretrekk New<T> eller en vanlig
      TArenaObject.Create — da kjører constructoren som normalt. }
    function NewObject(AClass: TClass): TObject;

    { Req.Arena.New<TCustomer> — formen PRD-en skriver.

      Constructoren kjører, VMT-en er på plass, og objektet ligger i denne
      arenaen selv om en annen er omgivende. Typeparameteren er bundet til
      TArenaObject med vilje: en vilkårlig TObject ville havnet på heapen
      uten at kallstedet merket det, og det er nettopp den feilen som gjør
      en arena utrygg. }
    function New<T: TArenaObject>: T;

    { True når P peker inn i minne denne arenaen har reservert. Finnes for at
      tester og feilsøking skal kunne slå fast hvor et objekt faktisk ligger,
      i stedet for å stole på at det gjør det. }
    function Owns(P: Pointer): Boolean;

    { Spol tilbake til start. Blokkene beholdes for neste request. }
    procedure Reset;
    { Frigi alt unntatt første blokk. Kalles sjelden — f.eks. hvis en enkelt
      request har blåst opp arenaen og workeren ikke skal holde på minnet. }
    procedure Trim;

    function Mark: TArenaMark;
    procedure Rewind(const AMark: TArenaMark);

    property BlockSize: PtrUInt read FBlockSize;
    { Bytes delt ut siden siste Reset. Teller ikke haler som ble hoppet over
      da en allokering ikke fikk plass i gjeldende blokk. }
    property BytesLive: PtrUInt read FLive;
    { Bytes arenaen holder fra OS. Dette er tallet som skal flate ut. }
    property BytesReserved: PtrUInt read FReserved;
    property HighWaterMark: PtrUInt read FHighWater;
    property ResetCount: QWord read FResetCount;
    function BlockCount: Integer;
  end;
  { Basisklasse for alt som skal leve i request-arenaen.

    NewInstance henter minne fra den omgivende arenaen i stedet for heapen, så
    en helt vanlig TCustomer.Create allokerer i arenaen og kjører constructoren
    som normalt. FreeInstance gjør ingenting: minnet forsvinner ved Reset.

    Has_ klassen felter kompilatoren håndterer — string, dynamisk array,
    interface — registreres en finalisering som kjører ved Reset. Det er
    nødvendig fordi destructoren aldri kjøres: uten det ville hver
    string-property på en modell lekket heap-minne per request. Klasser uten
    slike felter, som TRequest og TResponse, betaler ingenting for dette,
    fordi RTTI-tabellen deres er tom.

    Er det ingen omgivende arena — f.eks. i en test eller i oppstartskode —
    faller klassen tilbake til heapen og oppfører seg som en vanlig TObject.
    Da gjelder vanlige regler, og Free må kalles. }
  TArenaObject = class(TObject)
  private
    { Ikke-null når instansen ligger i en arena. Da er Free en no-op. }
    FArena: TArena;
  public
    class function NewInstance: TObject; override;
    procedure FreeInstance; override;
    property Arena: TArena read FArena;
    function IsArenaAllocated: Boolean;
  end;



  { Omgivende arena for gjeldende tråd.

    Verten setter denne før den kaller inn i brukerkode og nullstiller den
    etterpå. Det er dette som gjør at TArenaObject.Create havner i riktig
    arena uten at hver eneste constructor må ta en allokator som parameter. }
  function CurrentArena: TArena;
  function UseArena(A: TArena): TArena;   { returnerer forrige, for gjenoppretting }

  { True når klassen har felter som må finaliseres — string, dynamisk array,
    interface. ShortString og vanlige tall teller ikke. }
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
  { Free Pascal legger én init-tabell per klasse, og den dekker bare klassens
    egne felter. CleanupInstance går derfor opp hele arvekjeden, og det må
    denne gjøre også: en underklasse som arver et string-felt uten å
    deklarere noe selv har tom egen tabell, men må likevel finaliseres. }
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
  { Må kjøres før blokkene forsvinner — nodene ligger i arenaen selv. }
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
  { En allokering større enn blokkstørrelsen får sin egen blokk i nøyaktig
    riktig størrelse, slik at én stor payload ikke dobler arenaen permanent. }
  if MinCapacity > FBlockSize then
    Cap := AlignUp(MinCapacity, ArenaAlignment)
  else
    Cap := FBlockSize;

  { System.New, ikke TArena.New — metoden skygger for standardprosedyren inne
    i klassen. Free Pascal 3.2.2 lot det passere, 3.3.1 gjør det ikke. }
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
  { After_ Reset står hele kjeden ledig, så vi leter framover før vi ber OS om
    mer. Det er denne gjenbruken som gjør at RSS flater ut. }
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
  { InitInstance nullstiller feltene og setter VMT-pekeren. Constructoren
    kjører ikke — se kommentaren i interface-seksjonen. }
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
    { Tas av stabelen først, slik at en funksjon som kaster ikke kan kjøres
      om igjen ved neste Reset. }
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
  { Bytter omgivende arena, slik at TArenaObject.NewInstance treffer denne og
    ikke en annen som tilfeldigvis er satt. }
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
  { Alt som ble registrert etter merket ryddes nå; resten venter på Reset. }
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
  { Ligger instansen i en arena forsvinner den ved Reset, og å gi minnet til
    heap-manageren ville vært korrupsjon. CleanupInstance hoppes over her
    fordi den allerede er registrert som Defer i NewInstance — kaller vi den
    nå, ville den kjørt to ganger. }
  if FArena <> nil then
    Exit;
  inherited FreeInstance;
end;

function TArenaObject.IsArenaAllocated: Boolean;
begin
  Result := FArena <> nil;
end;

end.
