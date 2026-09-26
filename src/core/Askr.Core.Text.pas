{ Askr.Core.Text — strings that live in the arena.

  The PRD marks this as an open point: a Pascal string is refcounted by the
  compiler and lives on the heap, so it is safe, but it is not freed by
  Arena.Reset. A request that builds large payloads out of ordinary string
  values does not leak, but it goes to the heap manager constantly and makes
  RSS uneven.

  TStr is the answer: a slice (pointer + length) with no ownership and no
  refcount. The bytes live either in the arena, in the request buffer, or in
  an ordinary string the caller keeps alive. TStr never copies of its own
  accord — only StrDup and TStrBuilder do, and they take the arena as an
  argument.

  Everything here is byte-oriented and UTF-8 transparent. Case-insensitive
  comparison covers ASCII only, which is what HTTP header names and methods
  actually consist of. Real Unicode folding belongs in the application
  layer, not in the parser.
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
    { Copies out into an ordinary heap string. Use only at the edges. }
    function ToString: string;
    function Equals(const Other: TStr): Boolean;
    function EqualsStr(const S: string): Boolean;
    { ASCII case-insensitive — for header names and methods. }
    function SameText(const Other: TStr): Boolean;
    function SameTextStr(const S: string): Boolean;
    function StartsWithStr(const S: string): Boolean;
    function IndexOfByte(B: Byte; StartAt: SizeInt = 0): SizeInt;
    { The first occurrence of a whole sequence, or -1. An empty needle gives
      -1, not 0: "found everywhere" is never the answer anyone is after, and a
      loop that thinks it found something at position 0 makes no progress. }
    function IndexOfStr(const Needle: TStr; StartAt: SizeInt = 0): SizeInt; overload;
    function IndexOfStr(const Needle: string; StartAt: SizeInt = 0): SizeInt; overload;
    function Slice(Start: SizeInt; Count: SizeInt = -1): TStr;
    function TrimSpace: TStr;
    { Splits at the first occurrence of B. Left/Right point into the same
      buffer. With no match Left becomes the whole string, Right becomes empty
      and False is returned. Safe when Left or Right is the same variable as
      Self. }
    function SplitAt(B: Byte; out Left, Right: TStr): Boolean;
    function ToInt64(out V: Int64): Boolean;
    function ToIntDef(Default: Int64): Int64;
  end;

  { A growing buffer that allocates in an arena. Used to build responses and
    to collect incoming bytes.

    Growth abandons the previous block (it is freed at Reset), so the initial
    capacity should be in the right order of magnitude. In return, append is
    free while the capacity holds. }
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
    { Makes room for at least Extra more bytes, without changing Len. }
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

{ Points into S without copying. Valid as long as S lives. }
function Str(const S: string): TStr;
function StrRef(P: PByte; L: SizeInt): TStr; inline;
function StrEmpty: TStr; inline;
{ Copies the bytes into the arena. }
function StrDup(A: TArena; const S: TStr): TStr; overload;
function StrDup(A: TArena; const S: string): TStr; overload;
function StrCat(A: TArena; const L, R: TStr): TStr;
{ Text safe to put between HTML tags or in a quoted attribute: & < > " '
  escaped, nothing else touched. }
function HtmlEscape(const S: string): string;

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

function HtmlEscape(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    case S[I] of
      '&': Result := Result + '&amp;';
      '<': Result := Result + '&lt;';
      '>': Result := Result + '&gt;';
      '"': Result := Result + '&quot;';
      '''': Result := Result + '&#39;';
    else
      Result := Result + S[I];
    end;
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
  FirstByte: Byte;
begin
  if (Needle.Len <= 0) or (Needle.Len > Len) then
    Exit(-1);
  if StartAt < 0 then
    StartAt := 0;
  FirstByte := Needle.Data^;
  I := StartAt;
  while I <= Len - Needle.Len do
  begin
    { Look for the first byte first. Multipart parsing scans the whole body
      for a boundary of 40-70 bytes; a naive double loop is noticeable on an
      upload of a few megabytes. }
    I := IndexOfByte(FirstByte, I);
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
  { Both halves are worked out before anything is written. The common call
    pattern is Rest.SplitAt(B, Item, Rest), where the out parameter is Self;
    writing straight out would compute the second half from a Self that had
    already been overwritten. }
  P := IndexOfByte(B);
  if P < 0 then
  begin
    { Not found: the whole string is the left side, and that is intended. }
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
    { Stops before overflow rather than wrapping around. }
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
    { Taken as a QWord so that Low(Int64) does not overflow while being
      negated. }
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
