{ Askr.Core.Json — JSON in and out, in the arena.

  The writer streams: it builds straight into a TStrBuilder and keeps no
  intermediate tree. That is what makes an Inertia response with a hundred
  rows cost a few kilobytes rather than a tree of objects.

  The reader does build a tree, because a request body is something you
  look things up in rather than stream through. The nodes live in the
  arena and go away with the request.

  Number formatting does not go through FloatToStr or CurrToStr. Both
  follow the system's decimal separator, and a comma in JSON is
  invalid. }
unit Askr.Core.Json;

{$mode Delphi}{$H+}
{$POINTERMATH ON}

interface

uses
  SysUtils, Math, Askr.Core.Arena, Askr.Core.Text;

type
  EJsonError = class(Exception);

  { ---------------------------------------------------------------- skriv -- }

  TJsonWriter = record
  private
    FB: TStrBuilder;
    FNeedComma: Boolean;
    FDepth: Integer;
    { True at this level when we are inside an object, False in an array. }
    FInObject: array[0..63] of Boolean;
    procedure Separator;
    procedure Push(IsObject: Boolean);
    procedure Pop;
  public
    procedure Init(A: TArena; InitialCap: SizeInt = 1024);

    procedure BeginObject;
    procedure EndObject;
    procedure BeginArray;
    procedure EndArray;

    { A key in an object. The next write becomes the value. }
    procedure Key(const AName: string); overload;
    procedure Key(const AName: TStr); overload;

    procedure Str(const V: string); overload;
    procedure Str(const V: TStr); overload;
    procedure Int(V: Int64);
    procedure Num(V: Double);
    procedure Money(V: Currency);
    procedure Bool(V: Boolean);
    procedure Null;
    { Already-encoded JSON, inserted as it stands. }
    procedure Raw(const Json: TStr);

    { Key and value in one, which is what you almost always want. }
    procedure Field(const AName, V: string); overload;
    procedure Field(const AName: string; const V: TStr); overload;
    procedure Field(const AName: string; V: Int64); overload;
    procedure Field(const AName: string; V: Currency); overload;
    procedure Field(const AName: string; V: Boolean); overload;
    procedure FieldNull(const AName: string);
    procedure FieldRaw(const AName: string; const Json: TStr);

    function ToStr: TStr;
    function ToString: string;
    property Depth: Integer read FDepth;
  end;

  { An object that can write itself into a payload.

    The hook exists so an app can send its own objects as Inertia props
    without Inertia having to know them. Before this the list was closed —
    TModel, TModelList, TErrors — and anything else became an error. TGrid
    is the first to use it, but nothing about it is specific to the grid.

    Inherits TArenaObject, because a prop lives for the request and no
    longer. }
  TJsonWritable = class(TArenaObject)
  public
    procedure WriteJson(var W: TJsonWriter); virtual; abstract;
  end;

  { ----------------------------------------------------------------- les --- }

  TJsonKind = (jkNull, jkBool, jkNumber, jkString, jkArray, jkObject);

  PJsonValue = ^TJsonValue;
  TJsonValue = record
    Kind: TJsonKind;
    { For numbers: the text as it stood. For strings: the decoded content. }
    Text: TStr;
    BoolValue: Boolean;
    Key: TStr;
    First: PJsonValue;
    Last: PJsonValue;
    Next: PJsonValue;
    Count: Integer;
  end;

{ Parses all of Src. Returns False on a syntax error, and then sets ErrorAt
  to the position where it went wrong. }
function JsonParse(A: TArena; const Src: TStr; out Root: PJsonValue;
  out ErrorAt: SizeInt): Boolean;

function JsonMember(V: PJsonValue; const AKey: string): PJsonValue;
function JsonAt(V: PJsonValue; Index: Integer): PJsonValue;
function JsonAsStr(V: PJsonValue): TStr;
function JsonAsString(V: PJsonValue): string;
function JsonAsInt(V: PJsonValue; Default: Int64 = 0): Int64;
function JsonAsBool(V: PJsonValue; Default: Boolean = False): Boolean;
function JsonIsNull(V: PJsonValue): Boolean;

{ Writes a parsed value back out as JSON text.

  It exists because part of a response sometimes has to travel on as it is
  — a tool call's arguments, for instance, where only the tool knows which
  fields it has. Numbers are written with the text they came in as, so
  precision is not lost on a detour through Double. }
procedure JsonWriteValue(var W: TJsonWriter; V: PJsonValue);
function JsonToString(A: TArena; V: PJsonValue): string;

{ Escaper tekst til bruk i et HTML-attributt. }
function HtmlAttrEscape(A: TArena; const S: TStr): TStr;

{ Makes finished JSON safe inside a <script type="application/json">
  element.

  Without this a string containing </script> can end the element in the
  middle of the payload, and the rest of the document is parsed as HTML.
  The same escaping Inertia itself uses: < becomes \u003c and / becomes
  \/. Both are legal JSON and give exactly the same value after
  parsing. }
function JsonScriptEscape(A: TArena; const S: TStr): TStr;

implementation

const
  HexDigits: array[0..15] of Char = '0123456789abcdef';

{ TJsonWriter }

procedure TJsonWriter.Init(A: TArena; InitialCap: SizeInt);
begin
  FB.Init(A, InitialCap);
  FNeedComma := False;
  FDepth := 0;
end;

procedure TJsonWriter.Separator;
begin
  if FNeedComma then
    FB.AppendByte(Ord(','));
  FNeedComma := True;
end;

procedure TJsonWriter.Push(IsObject: Boolean);
begin
  if FDepth > High(FInObject) then
    raise EJsonError.Create('JSON nested deeper than 64 levels');
  FInObject[FDepth] := IsObject;
  Inc(FDepth);
  FNeedComma := False;
end;

procedure TJsonWriter.Pop;
begin
  if FDepth = 0 then
    raise EJsonError.Create('JSON: closed a level that was never opened');
  Dec(FDepth);
  FNeedComma := True;
end;

procedure TJsonWriter.BeginObject;
begin
  Separator;
  FB.AppendByte(Ord('{'));
  Push(True);
end;

procedure TJsonWriter.EndObject;
begin
  FB.AppendByte(Ord('}'));
  Pop;
end;

procedure TJsonWriter.BeginArray;
begin
  Separator;
  FB.AppendByte(Ord('['));
  Push(False);
end;

procedure TJsonWriter.EndArray;
begin
  FB.AppendByte(Ord(']'));
  Pop;
end;

procedure WriteEscaped(var B: TStrBuilder; const V: TStr);
var
  I: SizeInt;
  C: Byte;
begin
  B.AppendByte(Ord('"'));
  for I := 0 to V.Len - 1 do
  begin
    C := (V.Data + I)^;
    case C of
      Ord('"'):  B.Append('\"');
      Ord('\'):  B.Append('\\');
      8:         B.Append('\b');
      9:         B.Append('\t');
      10:        B.Append('\n');
      12:        B.Append('\f');
      13:        B.Append('\r');
    else
      if C < $20 then
      begin
        B.Append('\u00');
        B.AppendByte(Ord(HexDigits[(C shr 4) and $0F]));
        B.AppendByte(Ord(HexDigits[C and $0F]));
      end
      else
        { UTF-8 passes through unchanged. JSON is defined over Unicode, and the
          bytes are already valid UTF-8 from the database and the HTTP layer. }
        B.AppendByte(C);
    end;
  end;
  B.AppendByte(Ord('"'));
end;

procedure TJsonWriter.Key(const AName: TStr);
begin
  Separator;
  WriteEscaped(FB, AName);
  FB.AppendByte(Ord(':'));
  { The value that follows must not have a comma in front of it. }
  FNeedComma := False;
end;

procedure TJsonWriter.Key(const AName: string);
begin
  Key(Askr.Core.Text.Str(AName));
end;

procedure TJsonWriter.Str(const V: TStr);
begin
  Separator;
  WriteEscaped(FB, V);
end;

procedure TJsonWriter.Str(const V: string);
begin
  Str(Askr.Core.Text.Str(V));
end;

procedure TJsonWriter.Int(V: Int64);
begin
  Separator;
  FB.AppendInt(V);
end;

procedure TJsonWriter.Num(V: Double);
var
  FS: TFormatSettings;
begin
  Separator;
  if IsNan(V) or IsInfinite(V) then
  begin
    { JSON has no representation for these. Null is the most honest. }
    FB.Append('null');
    Exit;
  end;
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := #0;
  FB.Append(FloatToStrF(V, ffGeneral, 17, 0, FS));
end;

procedure TJsonWriter.Money(V: Currency);
var
  Scaled, Whole, Frac: Int64;
  Neg: Boolean;
  Digits: string;
begin
  Separator;
  { Currency is an Int64 scaled by 10000. Formatted by hand, so a Norwegian
    decimal comma can never end up in JSON. }
  Scaled := PInt64(@V)^;
  Neg := Scaled < 0;
  if Neg then
    Scaled := -Scaled;
  Whole := Scaled div 10000;
  Frac := Scaled mod 10000;
  if Neg then
    FB.AppendByte(Ord('-'));
  FB.AppendInt(Whole);
  if Frac <> 0 then
  begin
    { Always four decimals, but trailing zeroes are only noise in a payload
      going over the network. 1234.5000 becomes 1234.5. }
    Digits := Copy(IntToStr(10000 + Frac), 2, 4);
    while (Length(Digits) > 1) and (Digits[Length(Digits)] = '0') do
      Delete(Digits, Length(Digits), 1);
    FB.AppendByte(Ord('.'));
    FB.Append(Digits);
  end;
end;

procedure TJsonWriter.Bool(V: Boolean);
begin
  Separator;
  if V then
    FB.Append('true')
  else
    FB.Append('false');
end;

procedure TJsonWriter.Null;
begin
  Separator;
  FB.Append('null');
end;

procedure TJsonWriter.Raw(const Json: TStr);
begin
  Separator;
  FB.Append(Json);
end;

procedure TJsonWriter.Field(const AName, V: string);
begin
  Key(AName);
  Str(V);
end;

procedure TJsonWriter.Field(const AName: string; const V: TStr);
begin
  Key(AName);
  Str(V);
end;

procedure TJsonWriter.Field(const AName: string; V: Int64);
begin
  Key(AName);
  Int(V);
end;

procedure TJsonWriter.Field(const AName: string; V: Currency);
begin
  Key(AName);
  Money(V);
end;

procedure TJsonWriter.Field(const AName: string; V: Boolean);
begin
  Key(AName);
  Bool(V);
end;

procedure TJsonWriter.FieldNull(const AName: string);
begin
  Key(AName);
  Null;
end;

procedure TJsonWriter.FieldRaw(const AName: string; const Json: TStr);
begin
  Key(AName);
  Raw(Json);
end;

function TJsonWriter.ToStr: TStr;
begin
  Result := FB.ToStr;
end;

function TJsonWriter.ToString: string;
begin
  Result := FB.ToString;
end;

{ ------------------------------------------------------------------- les -- }

type
  TParser = record
    A: TArena;
    Src: TStr;
    Pos: SizeInt;
  end;

function NewValue(var P: TParser; Kind: TJsonKind): PJsonValue;
begin
  Result := PJsonValue(P.A.AllocZero(SizeOf(TJsonValue)));
  Result^.Kind := Kind;
end;

procedure SkipSpace(var P: TParser);
var
  C: Byte;
begin
  while P.Pos < P.Src.Len do
  begin
    C := (P.Src.Data + P.Pos)^;
    if (C = 32) or (C = 9) or (C = 10) or (C = 13) then
      Inc(P.Pos)
    else
      Break;
  end;
end;

function Peek(var P: TParser): Byte;
begin
  if P.Pos >= P.Src.Len then
    Exit(0);
  Result := (P.Src.Data + P.Pos)^;
end;

function Literal(var P: TParser; const Word_: string): Boolean;
var
  I: Integer;
begin
  if P.Pos + Length(Word_) > P.Src.Len then
    Exit(False);
  for I := 1 to Length(Word_) do
    if (P.Src.Data + P.Pos + I - 1)^ <> Byte(Ord(Word_[I])) then
      Exit(False);
  Inc(P.Pos, Length(Word_));
  Result := True;
end;

function HexNibble(C: Byte; out V: Byte): Boolean;
begin
  case C of
    Ord('0')..Ord('9'): V := C - Ord('0');
    Ord('a')..Ord('f'): V := C - Ord('a') + 10;
    Ord('A')..Ord('F'): V := C - Ord('A') + 10;
  else
    V := 0;
    Exit(False);
  end;
  Result := True;
end;

{ Writes a code point as UTF-8. }
procedure AppendUtf8(var B: TStrBuilder; Cp: Cardinal);
begin
  if Cp < $80 then
    B.AppendByte(Byte(Cp))
  else if Cp < $800 then
  begin
    B.AppendByte(Byte($C0 or (Cp shr 6)));
    B.AppendByte(Byte($80 or (Cp and $3F)));
  end
  else if Cp < $10000 then
  begin
    B.AppendByte(Byte($E0 or (Cp shr 12)));
    B.AppendByte(Byte($80 or ((Cp shr 6) and $3F)));
    B.AppendByte(Byte($80 or (Cp and $3F)));
  end
  else
  begin
    B.AppendByte(Byte($F0 or (Cp shr 18)));
    B.AppendByte(Byte($80 or ((Cp shr 12) and $3F)));
    B.AppendByte(Byte($80 or ((Cp shr 6) and $3F)));
    B.AppendByte(Byte($80 or (Cp and $3F)));
  end;
end;

function ParseString(var P: TParser; out S: TStr): Boolean;
var
  B: TStrBuilder;
  C: Byte;
  I: Integer;
  N: Byte;
  Cp, Low_: Cardinal;
  Start: SizeInt;
  Simple: Boolean;
begin
  S := StrEmpty;
  if Peek(P) <> Ord('"') then
    Exit(False);
  Inc(P.Pos);

  { The vast majority of strings have no escapes. Then we point straight
    into the source buffer instead of copying. }
  Start := P.Pos;
  Simple := True;
  while P.Pos < P.Src.Len do
  begin
    C := (P.Src.Data + P.Pos)^;
    if C = Ord('"') then
    begin
      if Simple then
      begin
        S := P.Src.Slice(Start, P.Pos - Start);
        Inc(P.Pos);
        Exit(True);
      end;
      Break;
    end;
    if C = Ord('\') then
    begin
      Simple := False;
      Break;
    end;
    if C < $20 then
      Exit(False);
    Inc(P.Pos);
  end;

  if P.Pos >= P.Src.Len then
    Exit(False);

  B.Init(P.A, (P.Pos - Start) * 2 + 32);
  B.AppendBytes(P.Src.Data + Start, P.Pos - Start);

  while P.Pos < P.Src.Len do
  begin
    C := (P.Src.Data + P.Pos)^;
    if C = Ord('"') then
    begin
      Inc(P.Pos);
      S := B.ToStr;
      Exit(True);
    end;
    if C < $20 then
      Exit(False);
    if C <> Ord('\') then
    begin
      B.AppendByte(C);
      Inc(P.Pos);
      Continue;
    end;

    Inc(P.Pos);
    if P.Pos >= P.Src.Len then
      Exit(False);
    C := (P.Src.Data + P.Pos)^;
    Inc(P.Pos);
    case C of
      Ord('"'): B.AppendByte(Ord('"'));
      Ord('\'): B.AppendByte(Ord('\'));
      Ord('/'): B.AppendByte(Ord('/'));
      Ord('b'): B.AppendByte(8);
      Ord('f'): B.AppendByte(12);
      Ord('n'): B.AppendByte(10);
      Ord('r'): B.AppendByte(13);
      Ord('t'): B.AppendByte(9);
      Ord('u'):
        begin
          if P.Pos + 3 >= P.Src.Len then
            Exit(False);
          Cp := 0;
          for I := 0 to 3 do
          begin
            if not HexNibble((P.Src.Data + P.Pos + I)^, N) then
              Exit(False);
            Cp := (Cp shl 4) or N;
          end;
          Inc(P.Pos, 4);
          { Surrogatpar settes sammen igjen. }
          if (Cp >= $D800) and (Cp <= $DBFF) and (P.Pos + 5 < P.Src.Len) and
             ((P.Src.Data + P.Pos)^ = Ord('\')) and
             ((P.Src.Data + P.Pos + 1)^ = Ord('u')) then
          begin
            Low_ := 0;
            for I := 0 to 3 do
            begin
              if not HexNibble((P.Src.Data + P.Pos + 2 + I)^, N) then
                Exit(False);
              Low_ := (Low_ shl 4) or N;
            end;
            if (Low_ >= $DC00) and (Low_ <= $DFFF) then
            begin
              Cp := $10000 + ((Cp - $D800) shl 10) + (Low_ - $DC00);
              Inc(P.Pos, 6);
            end;
          end;
          AppendUtf8(B, Cp);
        end;
    else
      Exit(False);
    end;
  end;
  Result := False;
end;

function ParseValue(var P: TParser; out V: PJsonValue): Boolean; forward;

function ParseNumber(var P: TParser; out V: PJsonValue): Boolean;
var
  Start: SizeInt;
  C: Byte;
begin
  Start := P.Pos;
  if Peek(P) = Ord('-') then
    Inc(P.Pos);
  if P.Pos >= P.Src.Len then
    Exit(False);
  while P.Pos < P.Src.Len do
  begin
    C := (P.Src.Data + P.Pos)^;
    if ((C >= Ord('0')) and (C <= Ord('9'))) or (C = Ord('.')) or
       (C = Ord('e')) or (C = Ord('E')) or (C = Ord('+')) or (C = Ord('-')) then
      Inc(P.Pos)
    else
      Break;
  end;
  if P.Pos = Start then
    Exit(False);
  V := NewValue(P, jkNumber);
  V^.Text := P.Src.Slice(Start, P.Pos - Start);
  Result := True;
end;

procedure Append(Parent, Child: PJsonValue);
begin
  if Parent^.First = nil then
    Parent^.First := Child
  else
    Parent^.Last^.Next := Child;
  Parent^.Last := Child;
  Inc(Parent^.Count);
end;

function ParseValue(var P: TParser; out V: PJsonValue): Boolean;
var
  Child: PJsonValue;
  K: TStr;
begin
  V := nil;
  SkipSpace(P);
  case Peek(P) of
    Ord('{'):
      begin
        Inc(P.Pos);
        V := NewValue(P, jkObject);
        SkipSpace(P);
        if Peek(P) = Ord('}') then
        begin
          Inc(P.Pos);
          Exit(True);
        end;
        repeat
          SkipSpace(P);
          if not ParseString(P, K) then
            Exit(False);
          SkipSpace(P);
          if Peek(P) <> Ord(':') then
            Exit(False);
          Inc(P.Pos);
          if not ParseValue(P, Child) then
            Exit(False);
          Child^.Key := K;
          Append(V, Child);
          SkipSpace(P);
          if Peek(P) = Ord(',') then
          begin
            Inc(P.Pos);
            Continue;
          end;
          Break;
        until False;
        if Peek(P) <> Ord('}') then
          Exit(False);
        Inc(P.Pos);
        Result := True;
      end;
    Ord('['):
      begin
        Inc(P.Pos);
        V := NewValue(P, jkArray);
        SkipSpace(P);
        if Peek(P) = Ord(']') then
        begin
          Inc(P.Pos);
          Exit(True);
        end;
        repeat
          if not ParseValue(P, Child) then
            Exit(False);
          Append(V, Child);
          SkipSpace(P);
          if Peek(P) = Ord(',') then
          begin
            Inc(P.Pos);
            Continue;
          end;
          Break;
        until False;
        if Peek(P) <> Ord(']') then
          Exit(False);
        Inc(P.Pos);
        Result := True;
      end;
    Ord('"'):
      begin
        V := NewValue(P, jkString);
        Result := ParseString(P, V^.Text);
      end;
    Ord('t'):
      begin
        if not Literal(P, 'true') then
          Exit(False);
        V := NewValue(P, jkBool);
        V^.BoolValue := True;
        Result := True;
      end;
    Ord('f'):
      begin
        if not Literal(P, 'false') then
          Exit(False);
        V := NewValue(P, jkBool);
        V^.BoolValue := False;
        Result := True;
      end;
    Ord('n'):
      begin
        if not Literal(P, 'null') then
          Exit(False);
        V := NewValue(P, jkNull);
        Result := True;
      end;
  else
    Result := ParseNumber(P, V);
  end;
end;

function JsonParse(A: TArena; const Src: TStr; out Root: PJsonValue;
  out ErrorAt: SizeInt): Boolean;
var
  P: TParser;
begin
  Root := nil;
  ErrorAt := 0;
  P.A := A;
  P.Src := Src;
  P.Pos := 0;
  Result := ParseValue(P, Root);
  if not Result then
  begin
    ErrorAt := P.Pos;
    Exit;
  end;
  SkipSpace(P);
  if P.Pos <> Src.Len then
  begin
    ErrorAt := P.Pos;
    Result := False;
  end;
end;

function JsonMember(V: PJsonValue; const AKey: string): PJsonValue;
var
  C: PJsonValue;
begin
  if (V = nil) or (V^.Kind <> jkObject) then
    Exit(nil);
  C := V^.First;
  while C <> nil do
  begin
    if C^.Key.EqualsStr(AKey) then
      Exit(C);
    C := C^.Next;
  end;
  Result := nil;
end;

function JsonAt(V: PJsonValue; Index: Integer): PJsonValue;
var
  C: PJsonValue;
  I: Integer;
begin
  if (V = nil) or (Index < 0) then
    Exit(nil);
  C := V^.First;
  I := 0;
  while C <> nil do
  begin
    if I = Index then
      Exit(C);
    Inc(I);
    C := C^.Next;
  end;
  Result := nil;
end;

function JsonAsStr(V: PJsonValue): TStr;
begin
  if V = nil then
    Exit(StrEmpty);
  case V^.Kind of
    jkString, jkNumber: Result := V^.Text;
    jkBool:
      if V^.BoolValue then
        Result := Askr.Core.Text.Str('true')
      else
        Result := Askr.Core.Text.Str('false');
  else
    Result := StrEmpty;
  end;
end;

function JsonAsString(V: PJsonValue): string;
begin
  Result := JsonAsStr(V).ToString;
end;

function JsonAsInt(V: PJsonValue; Default: Int64): Int64;
begin
  if (V = nil) or (V^.Kind <> jkNumber) then
    Exit(Default);
  Result := V^.Text.ToIntDef(Default);
end;

function JsonAsBool(V: PJsonValue; Default: Boolean): Boolean;
begin
  if V = nil then
    Exit(Default);
  case V^.Kind of
    jkBool: Result := V^.BoolValue;
    jkNumber: Result := not V^.Text.EqualsStr('0');
    jkString: Result := V^.Text.SameTextStr('true') or V^.Text.EqualsStr('1');
  else
    Result := Default;
  end;
end;

function JsonIsNull(V: PJsonValue): Boolean;
begin
  Result := (V = nil) or (V^.Kind = jkNull);
end;

function JsonScriptEscape(A: TArena; const S: TStr): TStr;
var
  B: TStrBuilder;
  I: SizeInt;
  C: Byte;
begin
  B.Init(A, S.Len + S.Len div 8 + 32);
  for I := 0 to S.Len - 1 do
  begin
    C := (S.Data + I)^;
    case C of
      Ord('<'): B.Append('\u003c');
      Ord('/'): B.Append('\/');
    else
      B.AppendByte(C);
    end;
  end;
  Result := B.ToStr;
end;

function HtmlAttrEscape(A: TArena; const S: TStr): TStr;
var
  B: TStrBuilder;
  I: SizeInt;
  C: Byte;
begin
  B.Init(A, S.Len + S.Len div 4 + 32);
  for I := 0 to S.Len - 1 do
  begin
    C := (S.Data + I)^;
    case C of
      Ord('&'): B.Append('&amp;');
      Ord('<'): B.Append('&lt;');
      Ord('>'): B.Append('&gt;');
      Ord('"'): B.Append('&quot;');
      Ord(''''): B.Append('&#39;');
    else
      B.AppendByte(C);
    end;
  end;
  Result := B.ToStr;
end;


procedure JsonWriteValue(var W: TJsonWriter; V: PJsonValue);
var
  C: PJsonValue;
begin
  if V = nil then
  begin
    W.Null;
    Exit;
  end;
  case V^.Kind of
    jkNull: W.Null;
    jkBool: W.Bool(V^.BoolValue);
    { The number as it stood. Going through Double and back would turn 1e400
      into something else and 0.1 into 0.1000000000000000055. }
    jkNumber: W.Raw(V^.Text);
    jkString: W.Str(V^.Text);
    jkArray:
      begin
        W.BeginArray;
        C := V^.First;
        while C <> nil do
        begin
          JsonWriteValue(W, C);
          C := C^.Next;
        end;
        W.EndArray;
      end;
    jkObject:
      begin
        W.BeginObject;
        C := V^.First;
        while C <> nil do
        begin
          W.Key(C^.Key);
          JsonWriteValue(W, C);
          C := C^.Next;
        end;
        W.EndObject;
      end;
  end;
end;

function JsonToString(A: TArena; V: PJsonValue): string;
var
  W: TJsonWriter;
  Mark: TArenaMark;
begin
  Mark := A.Mark;
  try
    W.Init(A, 1024);
    JsonWriteValue(W, V);
    Result := W.ToString;
  finally
    A.Rewind(Mark);
  end;
end;
end.
