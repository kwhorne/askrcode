{ Askr.Totp — the six-digit codes from an authenticator app.

      Secret := NewTotpSecret;               // base32, 160 bits
      Uri := TotpUri('Shop', U.Email, Secret);
      ...
      if VerifyTotp(Secret, Code, U.TotpLastStep) then ...

  RFC 6238 over RFC 4226: HMAC-SHA1, 30-second steps, six digits. Those are
  the only settings worth offering. The RFC allows SHA-256 and eight
  digits, and the authenticator apps people have -- Google Authenticator
  above all -- read the parameters and compute SHA-1 and six anyway, so a
  secret set up any other way gives codes that never match.

  **A code works once.** VerifyTotp takes the step the user last signed in
  with and refuses a code at or before it: a code read over a shoulder, or
  out of a phishing page, is spent the moment the user types it. The app
  stores that number next to the secret.

  **The secret is sealed, not stored as it is.** Askr.Core.Aead's SealText
  keeps it under APP_KEY, so a table that leaks does not hand out the
  codes along with it.

  Recovery codes are for the phone that is lost. Each works once, and only
  their SHA-256 is kept: they are random, so a hash without salt or
  stretching is enough -- there is no dictionary to try. }
unit Askr.Totp;

{$mode Delphi}{$H+}

interface

uses
  SysUtils;

const
  TotpPeriod = 30;
  TotpDigits = 6;

{ 20 random bytes as base32: the 160 bits RFC 4226 recommends. }
function NewTotpSecret: string;
{ RFC 4226's code for Counter under Key. }
function HotpCode(const Key: TBytes; Counter: Int64; Digits: Integer): string;
{ The code for Secret (base32) at UnixTime. }
function TotpCode(const Secret: string; UnixTime: Int64;
  Digits: Integer = TotpDigits): string;
{ Whether Code is Secret's for the step now, the one before or the one
  after -- a phone's clock is seldom exact -- and later than LastStep. On a
  match LastStep becomes the step that matched, for the app to store. Spaces
  in the code are ignored. Now_ is for a test; 0 is the clock. }
function VerifyTotp(const Secret, Code: string; var LastStep: Int64;
  Now_: Int64 = 0): Boolean;
(* otpauth://totp/Issuer:Account?secret=...&issuer=... -- what a QR code on
   the setup page holds, and what a phone opens straight into its
   authenticator when tapped. *)
function TotpUri(const Issuer, Account, Secret: string): string;

{ Count codes like 7kx2m-9qwpd: ten characters from base32's alphabet, 50
  bits each, with a dash so they can be read out. }
function NewRecoveryCodes(Count: Integer = 8): TStringArray;
{ What is stored for a recovery code: SHA-256 of it without dashes or
  spaces, in lower case, so it matches however it was typed. }
function RecoveryCodeHash(const Code: string): string;

implementation

uses
  Askr.Core.Crypto, Askr.Core.Clock;

function NewTotpSecret: string;
begin
  Result := Base32Encode(RandomBytes(20));
end;

function HotpCode(const Key: TBytes; Counter: Int64; Digits: Integer): string;
var
  Msg: TBytes;
  H: TSha1Digest;
  I, Offset: Integer;
  Bin: Cardinal;
  Modulo: Cardinal;
begin
  Msg := nil;
  SetLength(Msg, 8);
  for I := 0 to 7 do
    Msg[7 - I] := (UInt64(Counter) shr (8 * I)) and $FF;
  H := HmacSha1(Key, Msg);
  { Dynamic truncation: the low four bits of the last byte say where to
    read 31 bits from. }
  Offset := H[19] and $0F;
  Bin := (Cardinal(H[Offset] and $7F) shl 24) or (Cardinal(H[Offset + 1]) shl 16) or
         (Cardinal(H[Offset + 2]) shl 8) or Cardinal(H[Offset + 3]);
  Modulo := 1;
  for I := 1 to Digits do
    Modulo := Modulo * 10;
  Result := IntToStr(Bin mod Modulo);
  while Length(Result) < Digits do
    Result := '0' + Result;
end;

function TotpCode(const Secret: string; UnixTime: Int64; Digits: Integer): string;
begin
  Result := HotpCode(Base32Decode(Secret), UnixTime div TotpPeriod, Digits);
end;

function VerifyTotp(const Secret, Code: string; var LastStep: Int64;
  Now_: Int64): Boolean;
var
  Given: string;
  Key: TBytes;
  Step, Candidate: Int64;
begin
  Result := False;
  { Nothing else is checked: a code that is not six digits can never be
    one, and the comparison says so. }
  Given := StringReplace(Code, ' ', '', [rfReplaceAll]);
  Key := Base32Decode(Secret);
  if Now_ = 0 then
    Now_ := UnixNow;
  Step := Now_ div TotpPeriod;
  for Candidate := Step - 1 to Step + 1 do
    if (Candidate > LastStep) and
       ConstantTimeEquals(HotpCode(Key, Candidate, TotpDigits), Given) then
    begin
      LastStep := Candidate;
      Exit(True);
    end;
end;

{ Percent-encoding for the label and the issuer: a space or a colon in an
  app's name would otherwise change what the URI says. }
function Enc(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    if S[I] in ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~', '@'] then
      Result := Result + S[I]
    else
      Result := Result + '%' + IntToHex(Ord(S[I]), 2);
end;

function TotpUri(const Issuer, Account, Secret: string): string;
begin
  Result := 'otpauth://totp/' + Enc(Issuer) + ':' + Enc(Account) +
    '?secret=' + Secret + '&issuer=' + Enc(Issuer) +
    '&algorithm=SHA1&digits=' + IntToStr(TotpDigits) +
    '&period=' + IntToStr(TotpPeriod);
end;

function NewRecoveryCodes(Count: Integer): TStringArray;
var
  I: Integer;
  S: string;
begin
  Result := nil;
  SetLength(Result, Count);
  for I := 0 to Count - 1 do
  begin
    S := LowerCase(Copy(Base32Encode(RandomBytes(7)), 1, 10));
    Result[I] := Copy(S, 1, 5) + '-' + Copy(S, 6, 5);
  end;
end;

function RecoveryCodeHash(const Code: string): string;
begin
  Result := Sha256Hex(LowerCase(StringReplace(StringReplace(Trim(Code), '-', '',
    [rfReplaceAll]), ' ', '', [rfReplaceAll])));
end;

end.
