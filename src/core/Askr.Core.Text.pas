{ Askr.Core.Text — strenger som lever i arenaen.

  PRD-en peker på dette som et åpent punkt: Pascals string er refcountet av
  kompilatoren og ligger på heapen, så den er trygg, men den frigjøres ikke av
  Arena.Reset. En request som bygger store payloads av vanlige string-verdier
  lekker ikke, men den går til heap-manageren hele tiden og gjør RSS ujevn.

  TStr er svaret: et utsnitt (peker + lengde) uten eierskap og uten refcount.
  Bytene ligger enten i arenaen, i request-bufferet, eller i en vanlig string
  som kalleren holder i live. TStr kopierer aldri av seg selv — det gjør bare
  StrDup og TStrBuilder, og de tar arenaen som argument.

  Alt her er byte-orientert og UTF-8-gjennomsiktig. Sammenlikning uten
  hensyn til store og små bokstaver gjelder kun ASCII, som er det HTTP-header-
  navn og metoder faktisk består av. Ekte Unicode-folding hører hjemme i
  applikasjonslaget, ikke i parseren.
}
unit Askr.Core.Text;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Askr.Core.Arena;

type
  PStr = ^TStr;

  TStr = record
  public
    Data: PByte;
    Len: SizeInt;

    function IsEmpty: Boolean; inline;
    { Kopierer ut til en vanlig heap-string. Bruk bare i ytterkanten. }
    function ToString: string;
    function Equals(const Other: TStr): Boolean;
    function EqualsStr(const S: string): Boolean;
    { ASCII case-insensitiv — for headernavn og metoder. }
    function SameText(const Other: TStr): Boolean;
    function SameTextStr(const S: string): Boolean;
    function StartsWithStr(const S: string): Boolean;
    function IndexOfByte(B: Byte; StartAt: SizeInt = 0): SizeInt;
    { Første forekomst av en hel sekvens, eller -1. En tom nål gir -1, ikke
      0: «finnes overalt» er aldri svaret noen er ute etter, og en løkke
      som tror den fant noe på plass 0 går ikke videre. }
    function IndexOfStr(const Needle: TStr; StartAt: SizeInt = 0): SizeInt; overload;
    function IndexOfStr(const Needle: string; StartAt: SizeInt = 0): SizeInt; overload;
    function Slice(Start: SizeInt; Count: SizeInt = -1): TStr;
    function TrimSpace: TStr;
    { Parts_ på første forekomst av B. Left/Right peker inn i samme buffer.
      Without treff blir Left hele strengen og Right tom, og False returneres.
      Trygt når Left eller Right er den samme variabelen som Self. }
    function SplitAt(B: Byte; out Left, Right: TStr): Boolean;
    function ToInt64(out V: Int64): Boolean;
    function ToIntDef(Default: Int64): Int64;
  end;

  { Voksende buffer som allokerer i en arena. Brukes til å bygge responser og
    til å samle innkommende bytes.

    Vekst kaster den forrige blokken (den frigjøres først ved Reset), så
    startkapasiteten bør være i riktig størrelsesorden. To_ gjengjeld er
    append gratis når kapasiteten holder. }
  TStrBuilder = record
  private
    FArena: TArena;
    FData: PByte;
    FLen: SizeInt;
    FCap: SizeInt;
    procedure Grow(MinCap: SizeInt);
  public
    procedure Init(AArena: TArena; InitialCap: SizeInt = 512);
    procedure Clear; inline;
    { Sikrer plass til minst Extra bytes til, uten å endre Len. }
    procedure Reserve(Extra: SizeInt);
    procedure AppendBytes(P: PByte; L: SizeInt);
    procedure Append(const S: string); overload;
    procedure Append(const S: TStr); overload;
    procedure AppendByte(B: Byte); inline;
    procedure AppendInt(V: Int64);
    procedure AppendCRLF; inline;
    function ToStr: TStr;
    function ToString: string;
    property Len: SizeInt read FLen;
    property Capacity: SizeInt read FCap;
    property Data: PByte read FData;
    property Arena: TArena read FArena;
  end;

{ Peker inn i S uten å kopiere. Gyldig så lenge S lever. }
function Str(const S: string): TStr;
function StrRef(P: PByte; L: SizeInt): TStr; inline;
function StrEmpty: TStr; inline;
{ Kopierer bytene inn i arenaen. }
function StrDup(A: TArena; const S: TStr): TStr; overload;
function StrDup(A: TArena; const S: string): TStr; overload;
function StrCat(A: TArena; const L, R: TStr): TStr;

implementation

const
  UpperDelta = Ord('a') - Ord('A');

function LowerByte(B: Byte): Byte; inline;
begin
  if (B >= Ord('A')) and (B <= Ord('Z')) then
    Result := B + UpperDelta
  else
    Result := B;
end;

function Str(const S: string): TStr;
begin
  Result.Len := Length(S);
  if Result.Len > 0 then
    Result.Data := PByte(Pointer(S))
  else
    Result.Data := nil;
end;

function StrRef(P: PByte; L: SizeInt): TStr;
begin
  Result.Data := P;
  Result.Len := L;
end;

function StrEmpty: TStr;
begin
  Result.Data := nil;
  Result.Len := 0;
end;

function StrDup(A: TArena; const S: TStr): TStr;
begin
  Result.Len := S.Len;
  if S.Len > 0 then
    Result.Data := PByte(A.AllocCopy(S.Data, S.Len))
  else
    Result.Data := nil;
end;

function StrDup(A: TArena; const S: string): TStr;
begin
  Result := StrDup(A, Str(S));
end;

function StrCat(A: TArena; const L, R: TStr): TStr;
begin
  Result.Len := L.Len + R.Len;
  if Result.Len = 0 then
  begin
    Result.Data := nil;
    Exit;
  end;
  Result.Data := PByte(A.Alloc(Result.Len));
  if L.Len > 0 then
    Move(L.Data^, Result.Data^, L.Len);
  if R.Len > 0 then
    Move(R.Data^, (Result.Data + L.Len)^, R.Len);
end;

{ TStr }

function TStr.IsEmpty: Boolean;
begin
  Result := Len <= 0;
end;

function TStr.ToString: string;
begin
  SetLength(Result, Len);
  if Len > 0 then
    Move(Data^, Pointer(Result)^, Len);
end;

function TStr.Equals(const Other: TStr): Boolean;
begin
  Result := (Len = Other.Len) and
            ((Len = 0) or (CompareByte(Data^, Other.Data^, Len) = 0));
end;

function TStr.EqualsStr(const S: string): Boolean;
begin
  Result := Equals(Str(S));
end;

function TStr.SameText(const Other: TStr): Boolean;
var
  I: SizeInt;
begin
  if Len <> Other.Len then
    Exit(False);
  for I := 0 to Len - 1 do
    if LowerByte((Data + I)^) <> LowerByte((Other.Data + I)^) then
      Exit(False);
  Result := True;
end;

function TStr.SameTextStr(const S: string): Boolean;
begin
  Result := SameText(Str(S));
end;

function TStr.StartsWithStr(const S: string): Boolean;
begin
  Result := (Len >= Length(S)) and
            ((Length(S) = 0) or (CompareByte(Data^, Pointer(S)^, Length(S)) = 0));
end;

function TStr.IndexOfByte(B: Byte; StartAt: SizeInt): SizeInt;
var
  I: SizeInt;
begin
  if StartAt < 0 then
    StartAt := 0;
  for I := StartAt to Len - 1 do
    if (Data + I)^ = B then
      Exit(I);
  Result := -1;
end;

function TStr.IndexOfStr(const Needle: TStr; StartAt: SizeInt): SizeInt;
var
  I: SizeInt;
  Foerste: Byte;
begin
  if (Needle.Len <= 0) or (Needle.Len > Len) then
    Exit(-1);
  if StartAt < 0 then
    StartAt := 0;
  Foerste := Needle.Data^;
  I := StartAt;
  while I <= Len - Needle.Len do
  begin
    { Let etter første byte først. Multipart-parsing søker gjennom hele
      kroppen etter en grense på 40–70 byte; en naiv dobbeltløkke gjør det
      merkbart på en opplasting på noen megabyte. }
    I := IndexOfByte(Foerste, I);
    if (I < 0) or (I > Len - Needle.Len) then
      Exit(-1);
    if CompareByte((Data + I)^, Needle.Data^, Needle.Len) = 0 then
      Exit(I);
    Inc(I);
  end;
  Result := -1;
end;

function TStr.IndexOfStr(const Needle: string; StartAt: SizeInt): SizeInt;
var
  N: TStr;
begin
  N.Data := PByte(Pointer(Needle));
  N.Len := Length(Needle);
  Result := IndexOfStr(N, StartAt);
end;

function TStr.Slice(Start: SizeInt; Count: SizeInt): TStr;
begin
  if Start < 0 then
    Start := 0;
  if Start > Len then
    Start := Len;
  if (Count < 0) or (Start + Count > Len) then
    Count := Len - Start;
  Result.Data := Data + Start;
  Result.Len := Count;
end;

function TStr.TrimSpace: TStr;
var
  A, B: SizeInt;
begin
  A := 0;
  B := Len;
  while (A < B) and ((Data + A)^ <= Ord(' ')) do
    Inc(A);
  while (B > A) and ((Data + B - 1)^ <= Ord(' ')) do
    Dec(B);
  Result.Data := Data + A;
  Result.Len := B - A;
end;

function TStr.SplitAt(B: Byte; out Left, Right: TStr): Boolean;
var
  P: SizeInt;
  L, R: TStr;
begin
  { Begge halvdelene beregnes ferdig før noe skrives ut. Det vanligste
    kallmønsteret er Rest.SplitAt(B, Item, Rest), der ut-parameteret er Self;
    skrev vi rett ut ville andre halvdel blitt beregnet fra et Self som
    allerede var overskrevet. }
  P := IndexOfByte(B);
  if P < 0 then
  begin
    { Ikke funnet: hele strengen er venstre side, og det er meningen. }
    L := Self;
    R := StrEmpty;
    Result := False;
  end
  else
  begin
    L := Slice(0, P);
    R := Slice(P + 1);
    Result := True;
  end;
  Left := L;
  Right := R;
end;

function TStr.ToInt64(out V: Int64): Boolean;
var
  I: SizeInt;
  Neg: Boolean;
  D: Byte;
begin
  V := 0;
  if Len = 0 then
    Exit(False);
  I := 0;
  Neg := False;
  if (Data^ = Ord('-')) or (Data^ = Ord('+')) then
  begin
    Neg := Data^ = Ord('-');
    I := 1;
    if Len = 1 then
      Exit(False);
  end;
  while I < Len do
  begin
    D := (Data + I)^;
    if (D < Ord('0')) or (D > Ord('9')) then
      Exit(False);
    { Stopper før overflow i stedet for å pakke rundt. }
    if V > (High(Int64) - Int64(D - Ord('0'))) div 10 then
      Exit(False);
    V := V * 10 + Int64(D - Ord('0'));
    Inc(I);
  end;
  if Neg then
    V := -V;
  Result := True;
end;

function TStr.ToIntDef(Default: Int64): Int64;
begin
  if not ToInt64(Result) then
    Result := Default;
end;

{ TStrBuilder }

procedure TStrBuilder.Init(AArena: TArena; InitialCap: SizeInt);
begin
  FArena := AArena;
  FLen := 0;
  if InitialCap < 16 then
    InitialCap := 16;
  FCap := InitialCap;
  FData := PByte(FArena.Alloc(FCap));
end;

procedure TStrBuilder.Clear;
begin
  FLen := 0;
end;

procedure TStrBuilder.Grow(MinCap: SizeInt);
var
  NewCap: SizeInt;
  NewData: PByte;
begin
  NewCap := FCap;
  if NewCap < 16 then
    NewCap := 16;
  while NewCap < MinCap do
    NewCap := NewCap * 2;
  NewData := PByte(FArena.Alloc(NewCap));
  if FLen > 0 then
    Move(FData^, NewData^, FLen);
  FData := NewData;
  FCap := NewCap;
end;

procedure TStrBuilder.Reserve(Extra: SizeInt);
begin
  if FLen + Extra > FCap then
    Grow(FLen + Extra);
end;

procedure TStrBuilder.AppendBytes(P: PByte; L: SizeInt);
begin
  if L <= 0 then
    Exit;
  Reserve(L);
  Move(P^, (FData + FLen)^, L);
  Inc(FLen, L);
end;

procedure TStrBuilder.Append(const S: string);
begin
  AppendBytes(PByte(Pointer(S)), Length(S));
end;

procedure TStrBuilder.Append(const S: TStr);
begin
  AppendBytes(S.Data, S.Len);
end;

procedure TStrBuilder.AppendByte(B: Byte);
begin
  Reserve(1);
  (FData + FLen)^ := B;
  Inc(FLen);
end;

procedure TStrBuilder.AppendInt(V: Int64);
var
  Buf: array[0..23] of Byte;
  I: Integer;
  U: QWord;
begin
  if V = 0 then
  begin
    AppendByte(Ord('0'));
    Exit;
  end;
  if V < 0 then
  begin
    AppendByte(Ord('-'));
    { Tas som QWord for at Low(Int64) ikke skal overflowe under negering. }
    U := QWord(-(V + 1)) + 1;
  end
  else
    U := QWord(V);

  I := High(Buf);
  while U > 0 do
  begin
    Buf[I] := Ord('0') + Byte(U mod 10);
    U := U div 10;
    Dec(I);
  end;
  AppendBytes(@Buf[I + 1], High(Buf) - I);
end;

procedure TStrBuilder.AppendCRLF;
begin
  Reserve(2);
  (FData + FLen)^ := 13;
  (FData + FLen + 1)^ := 10;
  Inc(FLen, 2);
end;

function TStrBuilder.ToStr: TStr;
begin
  Result.Data := FData;
  Result.Len := FLen;
end;

function TStrBuilder.ToString: string;
begin
  Result := ToStr.ToString;
end;

end.
