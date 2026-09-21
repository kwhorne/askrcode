{ Askr.Cli.Diag — compiler diagnostics as structure.

  fpc writes one diagnostic per line, in one of two shapes:

    errors.pas(18,8) Error: Identifier not found "NoSuchIdentifier"
    errors.pas(24) Fatal: There were 3 errors compiling module, stopping
    Fatal: Compilation aborted

  That is: a file and a position, then a severity, then the message — with
  the column absent on some lines and the whole position absent on others.
  Everything else fpc prints is noise for this purpose: the banner, the
  target, `Compiling …`, `Assembling …`, `25 lines compiled` and the
  `N warning(s) issued` tallies.

  **The format is what this parses, never the message text.** The wording
  varies between compilers — 3.2.2 says `function header doesn't match` and
  trunk says `Function header doesn't match`, with different name mangling
  behind it — while the shape does not. Anything that matches on message
  text will break on a compiler nobody has tried yet.

  Two traps are already in the captured vectors:

    * `Target OS: Darwin for AArch64` has a word before a colon and is not a
      diagnostic. The severity is matched against a known set, never taken
      as "whatever stands before the colon".
    * `Hint: Start of reading config file /etc/fpc.cfg` is a real
      unpositioned Hint, and it is noise. It is parsed rather than dropped,
      because dropping by message text is the thing this unit must not do;
      the caller filters on severity and position instead.

  The file name is kept exactly as the compiler printed it. Whether that is
  relative, absolute, or a path inside a container depends on how the
  compiler was invoked, and resolving it is the caller's problem — this unit
  does not guess. }
unit Askr.Cli.Diag;

{$mode Delphi}{$H+}

interface

uses
  SysUtils;

type
  { Ordered by how much it matters, so that a caller can ask
    `Severity >= dsError` rather than listing the two. }
  TDiagSeverity = (dsHint, dsNote, dsWarning, dsError, dsFatal);

  TDiag = record
    { As the compiler printed it. Empty when the line carried no position. }
    FileName_: string;
    { 0 when the compiler gave no line. }
    Line: Integer;
    { 0 when the compiler gave a line but no column — `There were N errors`
      is the common case. }
    Col: Integer;
    Severity: TDiagSeverity;
    Message_: string;
  end;

  TDiagArray = array of TDiag;

{ Parses every diagnostic out of a compiler run. Lines that are not
  diagnostics are skipped without comment. }
function ParseDiagnostics(const Output_: string): TDiagArray;

{ 'Hint', 'Note', 'Warning', 'Error', 'Fatal' — the same spelling fpc uses,
  so that a caller can print it back without a second table. }
function DiagSeverityName(S: TDiagSeverity): string;

{ True when anything would have stopped the build. Warnings, notes and hints
  do not: a build that emits them still produced a binary, and reporting it
  as a failure would be wrong in the most common case there is. }
function HasErrors(const Diags: TDiagArray): Boolean;

implementation

const
  SeverityNames: array[TDiagSeverity] of string =
    ('Hint', 'Note', 'Warning', 'Error', 'Fatal');

function DiagSeverityName(S: TDiagSeverity): string;
begin
  Result := SeverityNames[S];
end;

function HasErrors(const Diags: TDiagArray): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(Diags) do
    if Diags[I].Severity >= dsError then
      Exit(True);
end;

{ Reads a severity and its colon at Pos_ in S. Advances Pos_ past ': ' on a
  match. }
function TakeSeverity(const S: string; var Pos_: Integer;
  out Sev: TDiagSeverity): Boolean;
var
  T: TDiagSeverity;
  N: Integer;
begin
  for T := Low(TDiagSeverity) to High(TDiagSeverity) do
  begin
    N := Length(SeverityNames[T]);
    if (Pos_ + N + 1 <= Length(S)) and
       (Copy(S, Pos_, N) = SeverityNames[T]) and
       (S[Pos_ + N] = ':') and (S[Pos_ + N + 1] = ' ') then
    begin
      Sev := T;
      Inc(Pos_, N + 2);
      Exit(True);
    end;
  end;
  Result := False;
end;

{ Reads `(123)` or `(123,45)` at Pos_. Advances Pos_ past the ')' on a
  match. }
function TakePosition(const S: string; var Pos_: Integer;
  out Line, Col: Integer): Boolean;
var
  P: Integer;
  Digits: string;
  Comma: Integer;
begin
  Result := False;
  Line := 0;
  Col := 0;
  if (Pos_ > Length(S)) or (S[Pos_] <> '(') then
    Exit;
  P := Pos_ + 1;
  Comma := 0;
  Digits := '';
  while (P <= Length(S)) and (S[P] <> ')') do
  begin
    if S[P] = ',' then
    begin
      if Comma <> 0 then
        Exit;                  { two commas is not a position }
      Comma := Length(Digits) + 1;
    end
    else if not (S[P] in ['0'..'9']) then
      Exit;
    Digits := Digits + S[P];
    Inc(P);
  end;
  if (P > Length(S)) or (Digits = '') then
    Exit;
  if Comma = 0 then
    Line := StrToIntDef(Digits, 0)
  else
  begin
    Line := StrToIntDef(Copy(Digits, 1, Comma - 1), 0);
    Col := StrToIntDef(Copy(Digits, Comma + 1, MaxInt), 0);
  end;
  if Line = 0 then
    Exit;
  Pos_ := P + 1;
  Result := True;
end;

{ One line. False when it is not a diagnostic at all. }
function ParseLine(const Line_: string; out D: TDiag): Boolean;
var
  P, ParenAt: Integer;
  L, C: Integer;
begin
  Result := False;
  D.FileName_ := '';
  D.Line := 0;
  D.Col := 0;
  D.Message_ := '';

  { The unpositioned form is anchored at the start, which is what keeps
    `Target OS: …` out: it is not a severity. }
  P := 1;
  if TakeSeverity(Line_, P, D.Severity) then
  begin
    D.Message_ := Copy(Line_, P, MaxInt);
    Exit(True);
  end;

  { The positioned form. The file name is everything before the first '(',
    so a path with a parenthesis in it would confuse this — no Pascal
    project has one, and guessing further would cost more than it saves. }
  ParenAt := Pos('(', Line_);
  if ParenAt < 2 then
    Exit;
  P := ParenAt;
  if not TakePosition(Line_, P, L, C) then
    Exit;
  if (P > Length(Line_)) or (Line_[P] <> ' ') then
    Exit;
  Inc(P);
  if not TakeSeverity(Line_, P, D.Severity) then
    Exit;
  D.FileName_ := Copy(Line_, 1, ParenAt - 1);
  D.Line := L;
  D.Col := C;
  D.Message_ := Copy(Line_, P, MaxInt);
  Result := True;
end;

function ParseDiagnostics(const Output_: string): TDiagArray;
var
  Start_, I, N: Integer;
  Line_: string;
  D: TDiag;
  Out_: TDiagArray;
begin
  Out_ := nil;
  N := 0;
  Start_ := 1;
  I := 1;
  while I <= Length(Output_) + 1 do
  begin
    if (I > Length(Output_)) or (Output_[I] = #10) then
    begin
      Line_ := Copy(Output_, Start_, I - Start_);
      { Captured output may carry CRLF depending on where it came from. }
      if (Line_ <> '') and (Line_[Length(Line_)] = #13) then
        SetLength(Line_, Length(Line_) - 1);
      if ParseLine(Line_, D) then
      begin
        if N = Length(Out_) then
          SetLength(Out_, (N + 1) * 2);
        Out_[N] := D;
        Inc(N);
      end;
      Start_ := I + 1;
    end;
    Inc(I);
  end;
  SetLength(Out_, N);
  Result := Out_;
end;

end.
