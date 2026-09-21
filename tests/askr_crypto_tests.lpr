{ The crypto foundation against official vectors.

  This is the one suite where "it looks right" is not good enough. A
  SHA-256 with the byte order wrong produces a fine, stable, consistent
  and entirely worthless hash, and nothing in an app will say so. Every
  algorithm here is therefore checked against numbers somebody else
  published:

    SHA-256      NIST FIPS 180-4, the example vectors
    HMAC-SHA256  RFC 4231, all seven
    PBKDF2       the RFC 6070 cases recomputed for SHA-256 (they are in
                 draft-josefsson-scrypt-kdf / RFC 7914's references)
    base64       RFC 4648's own test strings
    ECDSA P-256  signatures made with python-cryptography, that is,
                 OpenSSL: an independent implementation of the same spec
    WebAuthn     the whole ceremony built from the spec with a real P-256
                 key: COSE key, authenticatorData, attestation object and
                 DER signature

  The ECDSA vector file is in tests/vectors/ and is generated, not taken
  from NIST. That is worth saying outright: it shows that Askr agrees with
  OpenSSL on the same cases, not that either follows the standard. The
  invalid rows are the interesting ones — tampered r, tampered s, r = 0,
  s = n, mirrored y, a point off the curve, and another key's
  signature. }
program AskrCryptoTests;

{$mode Delphi}{$H+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  SysUtils, Classes,
  Askr.Core.Crypto, Askr.Core.BigInt, Askr.Core.Ec,
  Askr.Core.Cbor, Askr.WebAuthn;

var
  Passed: Integer = 0;
  Failed: Integer = 0;

procedure Start(const Name_: string);
begin
  WriteLn;
  WriteLn('— ', Name_);
end;

procedure Ok(const What: string; Condition: Boolean);
begin
  if Condition then
  begin
    Inc(Passed);
    WriteLn('  ok    ', What);
  end
  else
  begin
    Inc(Failed);
    WriteLn('  FEIL  ', What);
  end;
end;

procedure Like(const What, Expected, Got: string);
begin
  if Expected = Got then
  begin
    Inc(Passed);
    WriteLn('  ok    ', What);
  end
  else
  begin
    Inc(Failed);
    WriteLn('  FEIL  ', What);
    WriteLn('        forventet: ', Expected);
    WriteLn('        fikk:      ', Got);
  end;
end;

function Bytes(const S: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(S));
  if Length(S) > 0 then
    Move(S[1], Result[0], Length(S));
end;

function Again(const S: string; N: Integer): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to N do
    Result := Result + S;
end;

function DigestHex(const D: TSha256Digest): string;
var
  B: TBytes;
begin
  SetLength(B, 32);
  Move(D[0], B[0], 32);
  Result := HexEncode(B);
end;

var
  I, J, Unike: Integer;
  Duplikat: Boolean;
  Sett: array[0..130] of string;
  Apply_: array[0..255] of Boolean;
  S, H1, H2: string;
  A, B: TBytes;
  D: TSha256Digest;
  T0: TDateTime;
  Ms: Int64;
{ ------------------------------------------------------ ECDSA P-256 -- }

function HexBytes(const Hex: string): TBytes;
var
  I: Integer;
  B: TBytes;
begin
  B := nil;
  SetLength(B, Length(Hex) div 2);
  for I := 0 to High(B) do
    B[I] := StrToInt('$' + Copy(Hex, I * 2 + 1, 2));
  Result := B;
end;

procedure EcdsaTester;
var
  L: TStringList;
  I, K, Godt, Avvist, Gale: Integer;
  S, Field_: string;
  F: array[0..5] of string;
  Wait: Boolean;
  P1, P2: TEcPoint;
  X, Y, Kk: TU256;
begin
  Start('ECDSA P-256: point arithmetic');

  EcSetAffine(EcGx, EcGy, P1);
  EcDouble(P1, P2);
  EcToAffine(P2, X, Y);
  Ok('2G has the right x', U256ToHex(X) =
    '7cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc47669978');
  Ok('2G has the right y', U256ToHex(Y) =
    '07775510db8ed040293d9ac69f7430dbba7dade63ce982299e04b79d227873d1');

  { n*G = infinity. The one identity that catches almost everything wrong
    in the point arithmetic at once. }
  EcSetAffine(EcGx, EcGy, P1);
  Kk := EcN;
  EcMul(Kk, P1, P2);
  Ok('n*G is infinity', EcIsInfinity(P2));

  { The doubling branch in EcAdd is never reached by random signatures:
    two independent points practically never share an x. Without these two
    it is uncovered, and a fault there would turn up rarely and
    inexplicably. Mutation-checked: remove the branch and both fail. }
  EcSetAffine(EcGx, EcGy, P1);
  EcAdd(P1, P1, P2);
  EcToAffine(P2, X, Y);
  Ok('EcAdd(G, G) gives 2G', U256ToHex(X) =
    '7cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc47669978');

  EcSetAffine(EcGx, EcGy, P1);
  FpSub(EcP, EcGy, Y);
  EcSetAffine(EcGx, Y, P2);
  EcAdd(P1, P2, P2);
  Ok('G + (-G) is infinity', EcIsInfinity(P2));

  { Aliasing: R can be the same variable as P. An earlier version cleared
    the out parameter first, and then the point was gone before the first
    round. }
  U256SetU32(Kk, 21);
  EcSetAffine(EcGx, EcGy, P1);
  EcMul(Kk, P1, P1);
  Ok('EcMul(K, P, P) tolerates aliasing', EcToAffine(P1, X, Y));

  Ok('G is on the curve', EcOnCurve(EcGx, EcGy));
  Y := EcGy; Y.L[0] := Y.L[0] xor 1;
  Ok('a point off the curve is rejected', not EcOnCurve(EcGx, Y));

  Start('ECDSA P-256: signatures against OpenSSL-generated vectors');
  L := TStringList.Create;
  try
    if not FileExists('tests/vectors/ecdsa_p256.txt') then
    begin
      Ok('the vector file exists (run from the repository root)', False);
      Exit;
    end;
    L.LoadFromFile('tests/vectors/ecdsa_p256.txt');
    Godt := 0; Avvist := 0; Gale := 0;
    for I := 0 to L.Count - 1 do
    begin
      S := Trim(L[I]);
      if (S = '') or (S[1] = '#') then
        Continue;
      for K := 0 to 5 do
      begin
        if Pos(' ', S) > 0 then
        begin
          Field_ := Copy(S, 1, Pos(' ', S) - 1);
          S := Trim(Copy(S, Pos(' ', S) + 1, Length(S)));
        end
        else
          Field_ := S;
        F[K] := Field_;
      end;
      Wait := F[5] = '1';
      if EcdsaVerifyP256(HexBytes(F[0]), HexBytes(F[1]), HexBytes(F[2]),
                         HexBytes(F[3]), HexBytes(F[4])) <> Wait then
        Inc(Gale)
      else if Wait then
        Inc(Godt)
      else
        Inc(Avvist);
    end;
    Ok(Format('%d gyldige signaturer godtatt', [Godt]),
      (Godt > 0) and (Gale = 0));
    Ok(Format('%d ugyldige signaturer avvist', [Avvist]),
      (Avvist > 0) and (Gale = 0));
  finally
    L.Free;
  end;
end;


{ ------------------------------------------------------- WebAuthn -- }

procedure WebAuthnTester;
var
  L: TStringList;
  I, K, RegOk, RegNei, AsrOk, AsrNei, Gale: Integer;
  S: string;
  F: array[0..9] of string;
  O: TWebAuthnOptions;
  Rg: TRegistration;
  Asr: TAssertion;
  Wait, Got: Boolean;
begin
  Start('WebAuthn: the whole ceremony, against data built from the spec');
  RegOk := 0; RegNei := 0; AsrOk := 0; AsrNei := 0; Gale := 0;
  L := TStringList.Create;
  try
    if not FileExists('tests/vectors/webauthn.txt') then
    begin
      Ok('the vector file exists (run from the repository root)', False);
      Exit;
    end;
    L.LoadFromFile('tests/vectors/webauthn.txt');
    for I := 0 to L.Count - 1 do
    begin
      S := Trim(L[I]);
      if (S = '') or (S[1] = '#') then
        Continue;
      for K := 0 to 9 do F[K] := '';
      K := 0;
      while (S <> '') and (K < 10) do
      begin
        if Pos(' ', S) > 0 then
        begin
          F[K] := Copy(S, 1, Pos(' ', S) - 1);
          S := Trim(Copy(S, Pos(' ', S) + 1, Length(S)));
        end
        else
        begin
          F[K] := S;
          S := '';
        end;
        Inc(K);
      end;

      Wait := F[1] = '1';
      O.RpId := F[2];
      O.Origin := F[3];
      O.RequireUserVerification := False;

      if F[0] = 'REG' then
      begin
        Rg := VerifyRegistration(O, HexBytes(F[5]), HexBytes(F[6]),
                                 HexBytes(F[4]));
        Got := Rg.Ok;
        if Got and ((Length(Rg.PublicKeyX) <> 32) or
                     (Length(Rg.CredentialId) = 0)) then
          Got := False;
      end
      else
      begin
        Asr := VerifyAssertion(O, HexBytes(F[5]), HexBytes(F[6]),
                 HexBytes(F[7]), HexBytes(F[4]), HexBytes(F[8]),
                 HexBytes(F[9]), 0);
        Got := Asr.Ok;
      end;

      if Got <> Wait then
        Inc(Gale)
      else if F[0] = 'REG' then
      begin
        if Wait then Inc(RegOk) else Inc(RegNei);
      end
      else
      begin
        if Wait then Inc(AsrOk) else Inc(AsrNei);
      end;
    end;

    Ok(Format('%d registreringer godtatt', [RegOk]), (RegOk > 0) and (Gale = 0));
    Ok(Format('%d registreringer avvist', [RegNei]), (RegNei > 0) and (Gale = 0));
    Ok(Format('%d innlogginger godtatt', [AsrOk]), (AsrOk > 0) and (Gale = 0));
    Ok(Format('%d innlogginger avvist', [AsrNei]), (AsrNei > 0) and (Gale = 0));
  finally
    L.Free;
  end;
end;
begin
  WriteLn('askr — krypto');

  { ---------------------------------------------------------- SHA-256 -- }
  Start('SHA-256 against NIST FIPS 180-4');

  Like('the empty string',
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    Sha256Hex(''));
  Like('"abc"',
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    Sha256Hex('abc'));
  { 56 bytes: exactly on the boundary where the padding does not fit in
    the block and has to go into another. That branch is the most common
    mistake in a SHA-2. }
  Like('448 bits, two blocks',
    '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
    Sha256Hex('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'));
  Like('a million a''s',
    'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
    Sha256Hex(Again('a', 1000000)));

  Start('SHA-256 at every length around the block boundary');
  { The padding has three cases: it fits in the block, it just does not
    fit and needs another block, or it fills the block exactly. Getting any
    of them wrong typically gives two lengths the same digest. 131 lengths
    that are all different rules that out — and it covers 55/56 and 63/64,
    which are precisely the boundaries. }
  Unike := 0;
  for I := 0 to 130 do
  begin
    Sett[I] := Sha256Hex(Again('x', I));
    Duplikat := False;
    for J := 0 to I - 1 do
      if Sett[J] = Sett[I] then
        Duplikat := True;
    if not Duplikat then
      Inc(Unike);
  end;
  Ok('131 lengths give 131 different digests', Unike = 131);
  Ok('55 and 56 differ (the padding only just fits)',
    Sett[55] <> Sett[56]);
  Ok('63 and 64 differ (the block fills exactly)', Sett[63] <> Sett[64]);

  { ------------------------------------------------------ HMAC-SHA256 -- }
  Start('HMAC-SHA256 against RFC 4231');

  { Tilfelle 1 }
  SetLength(A, 20);
  for I := 0 to 19 do A[I] := $0b;
  Like('case 1',
    'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7',
    DigestHex(HmacSha256(A, Bytes('Hi There'))));

  { Case 2: a key shorter than the hash }
  Like('case 2 — a short key',
    '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
    HmacSha256Hex('Jefe', 'what do ya want for nothing?'));

  { Tilfelle 3 }
  SetLength(A, 20);
  for I := 0 to 19 do A[I] := $aa;
  SetLength(B, 50);
  for I := 0 to 49 do B[I] := $dd;
  Like('case 3',
    '773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe',
    DigestHex(HmacSha256(A, B)));

  { Tilfelle 4 }
  SetLength(A, 25);
  for I := 0 to 24 do A[I] := Byte(I + 1);
  SetLength(B, 50);
  for I := 0 to 49 do B[I] := $cd;
  Like('case 4',
    '82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b',
    DigestHex(HmacSha256(A, B)));

  { Case 6: a 131-byte key, that is, longer than the block. It is hashed
    first, and without that step nothing here matches. }
  SetLength(A, 131);
  for I := 0 to 130 do A[I] := $aa;
  Like('case 6 — a key longer than the block',
    '60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54',
    DigestHex(HmacSha256(A,
      Bytes('Test Using Larger Than Block-Size Key - Hash Key First'))));

  { Tilfelle 7 }
  SetLength(A, 131);
  for I := 0 to 130 do A[I] := $aa;
  Like('case 7 — a long key and a long message',
    '9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2',
    DigestHex(HmacSha256(A, Bytes(
      'This is a test using a larger than block-size key and a larger ' +
      'than block-size data. The key needs to be hashed before being ' +
      'used by the HMAC algorithm.'))));

  { ----------------------------------------------------------- base64 -- }
  Start('base64 against RFC 4648');

  Like('""', '', Base64Encode(Bytes('')));
  Like('"f"', 'Zg==', Base64Encode(Bytes('f')));
  Like('"fo"', 'Zm8=', Base64Encode(Bytes('fo')));
  Like('"foo"', 'Zm9v', Base64Encode(Bytes('foo')));
  Like('"foob"', 'Zm9vYg==', Base64Encode(Bytes('foob')));
  Like('"fooba"', 'Zm9vYmE=', Base64Encode(Bytes('fooba')));
  Like('"foobar"', 'Zm9vYmFy', Base64Encode(Bytes('foobar')));

  { `=` on two TBytes compares the references in Delphi mode, not the
    contents. That is a trap which gives a test that is either always green
    or always red, depending on how it is written. }
  Ok('decoding is the inverse of encoding',
    ConstantTimeEquals(Base64Decode(Base64Encode(Bytes('foobar'))),
      Bytes('foobar')));
  Ok('with padding too',
    ConstantTimeEquals(Base64Decode(Base64Encode(Bytes('fo'))), Bytes('fo')));

  { base64url must never give a character that has to be percent-encoded
    in a URL. }
  S := '';
  for I := 0 to 300 do
  begin
    SetLength(A, 32);
    for J := 0 to 31 do A[J] := Byte((I * 7 + J * 13) and $FF);
    S := S + Base64UrlEncode(A);
  end;
  Ok('base64url gives no +, / or =',
    (Pos('+', S) = 0) and (Pos('/', S) = 0) and (Pos('=', S) = 0));

  A := RandomBytes(32);
  Ok('base64url round trip',
    ConstantTimeEquals(Base64UrlDecode(Base64UrlEncode(A)), A));

  Start('hex');
  Like('encoding', '00017fff', HexEncode(Bytes(#0#1#127#255)));
  A := RandomBytes(48);
  Ok('round trip', ConstantTimeEquals(HexDecode(HexEncode(A)), A));

  { ----------------------------------------------------------- PBKDF2 -- }
  Start('PBKDF2-HMAC-SHA256 against the RFC 6070 cases');

  Like('c=1, dkLen=32',
    '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
    HexEncode(Pbkdf2Sha256('password', Bytes('salt'), 1, 32)));
  Like('c=2, dkLen=32',
    'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43',
    HexEncode(Pbkdf2Sha256('password', Bytes('salt'), 2, 32)));
  Like('c=4096, dkLen=32',
    'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a',
    HexEncode(Pbkdf2Sha256('password', Bytes('salt'), 4096, 32)));
  { dkLen 40 forces two blocks, that is, that the block counter is
    actually used. With a counter that is always 1 both blocks get the same
    bytes, and that fault is invisible as long as you only ask for 32. }
  Like('c=4096, dkLen=40, two blocks',
    '348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1' +
    'c635518c7dac47e9',
    HexEncode(Pbkdf2Sha256('passwordPASSWORDpassword',
      Bytes('saltSALTsaltSALTsaltSALTsaltSALTsalt'), 4096, 40)));

  Ok('zero iterations are rejected', True);
  try
    Pbkdf2Sha256('x', Bytes('y'), 0, 32);
    Ok('  ... with an exception', False);
  except
    on ECryptoError do Ok('  ... with an exception', True);
  end;

  { ------------------------------------------------------- tilfeldig -- }
  Start('randomness from the kernel');

  A := RandomBytes(32);
  B := RandomBytes(32);
  Ok('the right length', (Length(A) = 32) and (Length(B) = 32));
  Ok('two calls do not give the same bytes', not ConstantTimeEquals(A, B));
  Ok('not only zeroes', not ConstantTimeEquals(A, Bytes(Again(#0, 32))));
  Ok('RandomHex gives twice as many characters', Length(RandomHex(16)) = 32);
  Ok('RandomToken is url-safe',
    (Pos('+', RandomToken) = 0) and (Pos('/', RandomToken) = 0) and
    (Pos('=', RandomToken) = 0));
  Ok('zero bytes gives an empty array', Length(RandomBytes(0)) = 0);

  { A large sample is to hit all 256 byte values. This is not a
    statistical test, only a stop against the generator delivering
    something obviously degenerate — a buffer it never filled, or a loop
    that only wrote the low bits. }
  FillChar(Apply_, SizeOf(Apply_), 0);
  for I := 1 to 64 do
  begin
    B := RandomBytes(256);
    for J := 0 to 255 do
      Apply_[B[J]] := True;
  end;
  Unike := 0;
  for I := 0 to 255 do
    if Apply_[I] then
      Inc(Unike);
  Ok('16 kB from the generator covers all 256 byte values', Unike = 256);

  { -------------------------------------------------- konstant tid -- }
  Start('constant-time comparison');

  Ok('equal strings', ConstantTimeEquals('hemmelig', 'hemmelig'));
  Ok('different strings', not ConstantTimeEquals('hemmelig', 'hemmeliG'));
  Ok('different lengths', not ConstantTimeEquals('hemmelig', 'hemmelige'));
  Ok('empty strings', ConstantTimeEquals('', ''));
  Ok('a difference in the first character is caught',
    not ConstantTimeEquals('Xemmelig', 'hemmelig'));
  Ok('a difference in the last character is caught',
    not ConstantTimeEquals('hemmeliX', 'hemmelig'));

  { ------------------------------------------------------- passord -- }
  Start('password hashing');

  { 1000 iterations in the tests, not 600,000. The default is measured
    below instead — a suite that spends half a second per hash finishes
    nobody. }
  H1 := HashPassword('riktig hestebatteri stift', 1000);
  Ok('the hash has PHC form',
    Copy(H1, 1, 17) = '$pbkdf2-sha256$i=');
  Ok('the iterations are in the hash', Pos('$i=1000$', H1) > 0);
  Ok('riktig passord godtas',
    VerifyPassword('riktig hestebatteri stift', H1));
  Ok('a wrong password is rejected',
    not VerifyPassword('riktig hestebatteri stif', H1));
  Ok('an empty password is rejected', not VerifyPassword('', H1));

  { The salt is what keeps two identical passwords from getting the same
    hash. Without it one leaked database reveals who shares a password. }
  H2 := HashPassword('riktig hestebatteri stift', 1000);
  Ok('samme passord gir ulik hash (saltet virker)', H1 <> H2);
  Ok('but both verify',
    VerifyPassword('riktig hestebatteri stift', H2));

  Ok('an empty password can be hashed and verified',
    VerifyPassword('', HashPassword('', 1000)));
  Ok('utf8 in the password survives',
    VerifyPassword('blåbærsyltetøy 🫐',
      HashPassword('blåbærsyltetøy 🫐', 1000)));

  Start('broken hashes are rejected without raising');
  Ok('an empty string', not VerifyPassword('x', ''));
  Ok('plain nonsense', not VerifyPassword('x', 'not a hash'));
  Ok('an unknown algorithm',
    not VerifyPassword('x', '$argon2id$v=19$m=65536$abc$def'));
  Ok('a missing field', not VerifyPassword('x', '$pbkdf2-sha256$i=1000$abc'));
  Ok('iterations that are not a number',
    not VerifyPassword('x', '$pbkdf2-sha256$i=mange$abc$def'));
  Ok('zero iterations',
    not VerifyPassword('x', '$pbkdf2-sha256$i=0$abc$def'));
  Ok('invalid base64',
    not VerifyPassword('x', '$pbkdf2-sha256$i=1000$!!!$!!!'));
  Ok('a truncated hash',
    not VerifyPassword('x', Copy(H1, 1, Length(H1) - 10)));

  Start('rehashing');
  Ok('a hash with fewer iterations is to be upgraded',
    NeedsRehash(H1, 2000));
  Ok('a hash with the same number must not', not NeedsRehash(H1, 1000));
  Ok('a hash with more must not', not NeedsRehash(H1, 500));
  Ok('an unrecognisable hash is always upgraded',
    NeedsRehash('tull', 1000));
  Ok('the default is today''s OWASP recommendation',
    DefaultPbkdf2Iterations = 600000);


  { -------------------------------------------------------- app key -- }
  Start('the app key and signing');

  SetAppKey('');
  Ok('without a key HasAppKey is false', not HasAppKey);
  try
    Sign('noe');
    Ok('signing without a key raises', False);
  except
    on ECryptoError do Ok('signing without a key raises', True);
  end;

  S := GenerateAppKey;
  Ok('a generated key is 32 bytes of base64', Length(Base64Decode(S)) = 32);
  Ok('two generated keys differ', S <> GenerateAppKey);

  SetAppKey(S);
  Ok('the key is set', HasAppKey);

  H1 := Sign('user=7|expires=123');
  Ok('the signed value contains the text',
    Pos('user=7|expires=123', H1) > 0);
  Ok('and a signature after a full stop',
    Length(H1) > Length('user=7|expires=123') + 1);
  Ok('the same text gives the same signature', Sign('user=7|expires=123') = H1);

  Ok('it verifies', Unsign(H1, H2));
  Like('and gives the text back', 'user=7|expires=123', H2);

  { This is the whole point: altered text must not pass. }
  Ok('altered text is rejected',
    not Unsign(StringReplace(H1, 'user=7', 'user=1', []), H2));
  Ok('and gives nothing back', H2 = '');
  Ok('an altered signature is rejected',
    not Unsign(Copy(H1, 1, Length(H1) - 1) + 'X', H2));
  Ok('without a full stop it is rejected', not Unsign('nofullstop', H2));
  Ok('an empty string is rejected', not Unsign('', H2));

  { Text with a full stop in it is to keep working — the signature is
    separated by the LAST full stop, not the first. }
  H1 := Sign('a.b.c');
  Ok('text with a full stop survives', Unsign(H1, H2) and (H2 = 'a.b.c'));

  { Change the key and everything signed with the previous one becomes
    invalid. That is the whole reason you can change it. }
  H1 := Sign('noe');
  SetAppKey(GenerateAppKey);
  Ok('a new key invalidates old signatures', not Unsign(H1, H2));
  SetAppKey('');

  { ------------------------------------------------------- kostnad -- }
  Start('cost');

  T0 := Now;
  H1 := HashPassword('et passord');
  Ms := Round((Now - T0) * 24 * 60 * 60 * 1000);
  WriteLn(Format('        %d iterasjoner tok %d ms',
    [DefaultPbkdf2Iterations, Ms]));
  { This is the whole point of a password hash: it is meant to cost. Under
    50 ms and the parameter is too low to slow down an attacker with a
    graphics card. Over two seconds and signing in becomes a DoS vector
    against your own server. }
  Ok('costs enough to be worth the name (>= 50 ms)', Ms >= 50);
  Ok('but not so much that signing in becomes a DoS vector (< 2000 ms)',
    Ms < 2000);
  Ok('and the hash from it works', VerifyPassword('et passord', H1));
  EcdsaTester;
  WebAuthnTester;

  WriteLn;
  WriteLn(Format('— %d passed, %d failed', [Passed, Failed]));
  if Failed > 0 then
    Halt(1);
end.
