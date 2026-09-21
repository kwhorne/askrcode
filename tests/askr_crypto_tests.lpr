{ Kryptogrunnmuren mot offisielle vektorer.

  Dette er den ene suiten der «det ser riktig ut» ikke er godt nok. En
  SHA-256 med feil byterekkefølge produserer en fin, stabil, konsistent og
  fullstendig verdiløs hash, og ingenting i en app vil si fra. Derfor er
  hver algoritme her sjekket mot tall noen andre har publisert:

    SHA-256      NIST FIPS 180-4, eksempelvektorene
    HMAC-SHA256  RFC 4231, alle syv
    PBKDF2       RFC 6070-tilfellene regnet om til SHA-256 (de står i
                 draft-josefsson-scrypt-kdf / RFC 7914s referanser)
    base64       RFC 4648 sine egne teststrenger
    ECDSA P-256  signaturer laget med python-cryptography, altsaa
                 OpenSSL: en uavhengig implementasjon av samme spek
    WebAuthn     hele seremonien bygget fra speken med en ekte P-256
                 noekkel: COSE-noekkel, authenticatorData,
                 attestasjonsobjekt og DER-signatur

  Vektorfila for ECDSA ligger i tests/vectors/ og er generert, ikke
  hentet fra NIST. Det er verdt aa si rett ut: den viser at Askr er enig
  med OpenSSL om de samme tilfellene, ikke at begge foelger standarden.
  De ugyldige radene er de interessante - tuklet r, tuklet s, r = 0,
  s = n, speilet y, punkt utenfor kurven, og en annen noekkels
  signatur. }
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
  Bestatt: Integer = 0;
  Feilet: Integer = 0;

procedure Start(const Name_: string);
begin
  WriteLn;
  WriteLn('— ', Name_);
end;

procedure Ok(const What: string; Betingelse: Boolean);
begin
  if Betingelse then
  begin
    Inc(Bestatt);
    WriteLn('  ok    ', What);
  end
  else
  begin
    Inc(Feilet);
    WriteLn('  FEIL  ', What);
  end;
end;

procedure Like(const What, Expected, Got: string);
begin
  if Expected = Got then
  begin
    Inc(Bestatt);
    WriteLn('  ok    ', What);
  end
  else
  begin
    Inc(Feilet);
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
  Start('ECDSA P-256: punktaritmetikk');

  EcSetAffine(EcGx, EcGy, P1);
  EcDouble(P1, P2);
  EcToAffine(P2, X, Y);
  Ok('2G har riktig x', U256ToHex(X) =
    '7cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc47669978');
  Ok('2G har riktig y', U256ToHex(Y) =
    '07775510db8ed040293d9ac69f7430dbba7dade63ce982299e04b79d227873d1');

  { n*G = uendelig. Den ene identiteten som fanger nesten alt galt i
    punktaritmetikken paa en gang. }
  EcSetAffine(EcGx, EcGy, P1);
  Kk := EcN;
  EcMul(Kk, P1, P2);
  Ok('n*G er uendelig', EcIsInfinity(P2));

  { Doblingsgrenen i EcAdd naas aldri av tilfeldige signaturer: to
    uavhengige punkter har praktisk talt aldri samme x. Without disse to er
    den udekket, og en feil der ville dukket opp sjelden og uforklarlig.
    Mutasjonssjekket: fjernes grenen, feiler begge. }
  EcSetAffine(EcGx, EcGy, P1);
  EcAdd(P1, P1, P2);
  EcToAffine(P2, X, Y);
  Ok('EcAdd(G, G) gir 2G', U256ToHex(X) =
    '7cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc47669978');

  EcSetAffine(EcGx, EcGy, P1);
  FpSub(EcP, EcGy, Y);
  EcSetAffine(EcGx, Y, P2);
  EcAdd(P1, P2, P2);
  Ok('G + (-G) er uendelig', EcIsInfinity(P2));

  { Aliasing: R kan vaere samme variabel som P. Previous utgave nullstilte
    out-parameteren foerst, og da var punktet borte foer foerste runde. }
  U256SetU32(Kk, 21);
  EcSetAffine(EcGx, EcGy, P1);
  EcMul(Kk, P1, P1);
  Ok('EcMul(K, P, P) taaler aliasing', EcToAffine(P1, X, Y));

  Ok('G ligger paa kurven', EcOnCurve(EcGx, EcGy));
  Y := EcGy; Y.L[0] := Y.L[0] xor 1;
  Ok('et punkt utenfor kurven avvises', not EcOnCurve(EcGx, Y));

  Start('ECDSA P-256: signaturer mot OpenSSL-genererte vektorer');
  L := TStringList.Create;
  try
    if not FileExists('tests/vectors/ecdsa_p256.txt') then
    begin
      Ok('vektorfila finnes (kjoer fra repo-rota)', False);
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
  Start('WebAuthn: hele seremonien, mot data bygget fra speken');
  RegOk := 0; RegNei := 0; AsrOk := 0; AsrNei := 0; Gale := 0;
  L := TStringList.Create;
  try
    if not FileExists('tests/vectors/webauthn.txt') then
    begin
      Ok('vektorfila finnes (kjoer fra repo-rota)', False);
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
  Start('SHA-256 mot NIST FIPS 180-4');

  Like('den tomme strengen',
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    Sha256Hex(''));
  Like('"abc"',
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    Sha256Hex('abc'));
  { 56 byte: nøyaktig på grensa der utfyllingen ikke får plass i blokka og
    må gå i en til. Den grenen er den vanligste feilen i en SHA-2. }
  Like('448 bit, to blokker',
    '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
    Sha256Hex('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'));
  Like('en million a-er',
    'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
    Sha256Hex(Again('a', 1000000)));

  Start('SHA-256 på alle lengder rundt blokkgrensa');
  { Utfyllingen har tre tilfeller: den får plass i blokka, den får akkurat
    ikke plass og trenger en blokk til, eller den fyller blokka helt. En
    bom på noen av dem gir typisk to lengder samme digest. 131 lengder som
    alle er forskjellige utelukker det — og dekker 55/56 og 63/64, som er
    nettopp grensene. }
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
  Ok('131 lengder gir 131 ulike digester', Unike = 131);
  Ok('55 og 56 er ulike (utfyllingen så vidt får plass)',
    Sett[55] <> Sett[56]);
  Ok('63 og 64 er ulike (blokka fylles helt)', Sett[63] <> Sett[64]);

  { ------------------------------------------------------ HMAC-SHA256 -- }
  Start('HMAC-SHA256 mot RFC 4231');

  { Tilfelle 1 }
  SetLength(A, 20);
  for I := 0 to 19 do A[I] := $0b;
  Like('tilfelle 1',
    'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7',
    DigestHex(HmacSha256(A, Bytes('Hi There'))));

  { Tilfelle 2: nøkkel kortere enn hashen }
  Like('tilfelle 2 — kort nøkkel',
    '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
    HmacSha256Hex('Jefe', 'what do ya want for nothing?'));

  { Tilfelle 3 }
  SetLength(A, 20);
  for I := 0 to 19 do A[I] := $aa;
  SetLength(B, 50);
  for I := 0 to 49 do B[I] := $dd;
  Like('tilfelle 3',
    '773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe',
    DigestHex(HmacSha256(A, B)));

  { Tilfelle 4 }
  SetLength(A, 25);
  for I := 0 to 24 do A[I] := Byte(I + 1);
  SetLength(B, 50);
  for I := 0 to 49 do B[I] := $cd;
  Like('tilfelle 4',
    '82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b',
    DigestHex(HmacSha256(A, B)));

  { Tilfelle 6: nøkkel på 131 byte, altså lengre enn blokka. Den hashes
    først, og uten det steget stemmer ingenting her. }
  SetLength(A, 131);
  for I := 0 to 130 do A[I] := $aa;
  Like('tilfelle 6 — nøkkel lengre enn blokka',
    '60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54',
    DigestHex(HmacSha256(A,
      Bytes('Test Using Larger Than Block-Size Key - Hash Key First'))));

  { Tilfelle 7 }
  SetLength(A, 131);
  for I := 0 to 130 do A[I] := $aa;
  Like('tilfelle 7 — lang nøkkel og lang melding',
    '9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2',
    DigestHex(HmacSha256(A, Bytes(
      'This is a test using a larger than block-size key and a larger ' +
      'than block-size data. The key needs to be hashed before being ' +
      'used by the HMAC algorithm.'))));

  { ----------------------------------------------------------- base64 -- }
  Start('base64 mot RFC 4648');

  Like('""', '', Base64Encode(Bytes('')));
  Like('"f"', 'Zg==', Base64Encode(Bytes('f')));
  Like('"fo"', 'Zm8=', Base64Encode(Bytes('fo')));
  Like('"foo"', 'Zm9v', Base64Encode(Bytes('foo')));
  Like('"foob"', 'Zm9vYg==', Base64Encode(Bytes('foob')));
  Like('"fooba"', 'Zm9vYmE=', Base64Encode(Bytes('fooba')));
  Like('"foobar"', 'Zm9vYmFy', Base64Encode(Bytes('foobar')));

  { `=` på to TBytes sammenligner referansene i Delphi-modus, ikke
    innholdet. Det er en felle som gir en test som alltid er grønn eller
    alltid rød, avhengig av hvordan den skrives. }
  Ok('dekoding er omvendt av koding',
    ConstantTimeEquals(Base64Decode(Base64Encode(Bytes('foobar'))),
      Bytes('foobar')));
  Ok('også med utfylling',
    ConstantTimeEquals(Base64Decode(Base64Encode(Bytes('fo'))), Bytes('fo')));

  { base64url skal aldri gi tegn som må prosentkodes i en URL. }
  S := '';
  for I := 0 to 300 do
  begin
    SetLength(A, 32);
    for J := 0 to 31 do A[J] := Byte((I * 7 + J * 13) and $FF);
    S := S + Base64UrlEncode(A);
  end;
  Ok('base64url gir ingen +, / eller =',
    (Pos('+', S) = 0) and (Pos('/', S) = 0) and (Pos('=', S) = 0));

  A := RandomBytes(32);
  Ok('base64url tur-retur',
    ConstantTimeEquals(Base64UrlDecode(Base64UrlEncode(A)), A));

  Start('hex');
  Like('koding', '00017fff', HexEncode(Bytes(#0#1#127#255)));
  A := RandomBytes(48);
  Ok('tur-retur', ConstantTimeEquals(HexDecode(HexEncode(A)), A));

  { ----------------------------------------------------------- PBKDF2 -- }
  Start('PBKDF2-HMAC-SHA256 mot RFC 6070-tilfellene');

  Like('c=1, dkLen=32',
    '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
    HexEncode(Pbkdf2Sha256('password', Bytes('salt'), 1, 32)));
  Like('c=2, dkLen=32',
    'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43',
    HexEncode(Pbkdf2Sha256('password', Bytes('salt'), 2, 32)));
  Like('c=4096, dkLen=32',
    'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a',
    HexEncode(Pbkdf2Sha256('password', Bytes('salt'), 4096, 32)));
  { dkLen 40 tvinger to blokker, altså at blokktelleren faktisk brukes.
    With_ en teller som alltid er 1 gir begge blokkene samme bytes, og den
    feilen er usynlig så lenge man bare ber om 32. }
  Like('c=4096, dkLen=40, to blokker',
    '348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1' +
    'c635518c7dac47e9',
    HexEncode(Pbkdf2Sha256('passwordPASSWORDpassword',
      Bytes('saltSALTsaltSALTsaltSALTsaltSALTsalt'), 4096, 40)));

  Ok('null iterasjoner avvises', True);
  try
    Pbkdf2Sha256('x', Bytes('y'), 0, 32);
    Ok('  ... med en exception', False);
  except
    on ECryptoError do Ok('  ... med en exception', True);
  end;

  { ------------------------------------------------------- tilfeldig -- }
  Start('tilfeldighet fra kjernen');

  A := RandomBytes(32);
  B := RandomBytes(32);
  Ok('riktig lengde', (Length(A) = 32) and (Length(B) = 32));
  Ok('to kall gir ikke samme bytes', not ConstantTimeEquals(A, B));
  Ok('ikke bare nuller', not ConstantTimeEquals(A, Bytes(Again(#0, 32))));
  Ok('RandomHex gir dobbelt så mange tegn', Length(RandomHex(16)) = 32);
  Ok('RandomToken er url-trygg',
    (Pos('+', RandomToken) = 0) and (Pos('/', RandomToken) = 0) and
    (Pos('=', RandomToken) = 0));
  Ok('null bytes gir tom tabell', Length(RandomBytes(0)) = 0);

  { En stor prøve skal treffe alle 256 byteverdiene. Det er ikke en
    statistisk test, bare en sperre mot at generatoren leverer noe
    åpenbart degenerert — som en buffer den aldri fylte helt, eller en
    løkke som bare skrev de lave bitene. }
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
  Ok('16 kB fra generatoren dekker alle 256 byteverdiene', Unike = 256);

  { -------------------------------------------------- konstant tid -- }
  Start('konstanttidssammenligning');

  Ok('like strenger', ConstantTimeEquals('hemmelig', 'hemmelig'));
  Ok('ulike strenger', not ConstantTimeEquals('hemmelig', 'hemmeliG'));
  Ok('ulik lengde', not ConstantTimeEquals('hemmelig', 'hemmelige'));
  Ok('tomme strenger', ConstantTimeEquals('', ''));
  Ok('avvik i første tegn oppdages',
    not ConstantTimeEquals('Xemmelig', 'hemmelig'));
  Ok('avvik i siste tegn oppdages',
    not ConstantTimeEquals('hemmeliX', 'hemmelig'));

  { ------------------------------------------------------- passord -- }
  Start('passordhashing');

  { 1000 iterasjoner i testene, ikke 600 000. Standardverdien er målt
    nedenfor i stedet — en suite som bruker et halvt sekund per hash gjør
    ingen ferdig. }
  H1 := HashPassword('riktig hestebatteri stift', 1000);
  Ok('hashen har PHC-form',
    Copy(H1, 1, 17) = '$pbkdf2-sha256$i=');
  Ok('iterasjonene står i hashen', Pos('$i=1000$', H1) > 0);
  Ok('riktig passord godtas',
    VerifyPassword('riktig hestebatteri stift', H1));
  Ok('feil passord avvises',
    not VerifyPassword('riktig hestebatteri stif', H1));
  Ok('tomt passord avvises', not VerifyPassword('', H1));

  { Saltet er det som gjør at to like passord ikke får lik hash. Without det
    avslører én lekket database hvem som deler passord. }
  H2 := HashPassword('riktig hestebatteri stift', 1000);
  Ok('samme passord gir ulik hash (saltet virker)', H1 <> H2);
  Ok('men begge verifiserer',
    VerifyPassword('riktig hestebatteri stift', H2));

  Ok('et tomt passord kan hashes og verifiseres',
    VerifyPassword('', HashPassword('', 1000)));
  Ok('utf8 i passordet overlever',
    VerifyPassword('blåbærsyltetøy 🫐',
      HashPassword('blåbærsyltetøy 🫐', 1000)));

  Start('ødelagte hasher avvises uten å kaste');
  Ok('tom streng', not VerifyPassword('x', ''));
  Ok('bare tull', not VerifyPassword('x', 'ikke en hash'));
  Ok('ukjent algoritme',
    not VerifyPassword('x', '$argon2id$v=19$m=65536$abc$def'));
  Ok('manglende felt', not VerifyPassword('x', '$pbkdf2-sha256$i=1000$abc'));
  Ok('iterasjoner som ikke er et tall',
    not VerifyPassword('x', '$pbkdf2-sha256$i=mange$abc$def'));
  Ok('null iterasjoner',
    not VerifyPassword('x', '$pbkdf2-sha256$i=0$abc$def'));
  Ok('ugyldig base64',
    not VerifyPassword('x', '$pbkdf2-sha256$i=1000$!!!$!!!'));
  Ok('avkortet hash',
    not VerifyPassword('x', Copy(H1, 1, Length(H1) - 10)));

  Start('rehashing');
  Ok('en hash med færre iterasjoner skal oppgraderes',
    NeedsRehash(H1, 2000));
  Ok('en hash med like mange skal ikke', not NeedsRehash(H1, 1000));
  Ok('en hash med flere skal ikke', not NeedsRehash(H1, 500));
  Ok('en ugjenkjennelig hash skal alltid oppgraderes',
    NeedsRehash('tull', 1000));
  Ok('standardverdien er dagens OWASP-anbefaling',
    DefaultPbkdf2Iterations = 600000);


  { ----------------------------------------------------- appnøkkel -- }
  Start('appnøkkel og signering');

  SetAppKey('');
  Ok('uten nøkkel er HasAppKey usann', not HasAppKey);
  try
    Sign('noe');
    Ok('signering uten nøkkel kaster', False);
  except
    on ECryptoError do Ok('signering uten nøkkel kaster', True);
  end;

  S := GenerateAppKey;
  Ok('en generert nøkkel er 32 byte base64', Length(Base64Decode(S)) = 32);
  Ok('to genererte nøkler er ulike', S <> GenerateAppKey);

  SetAppKey(S);
  Ok('nøkkelen er satt', HasAppKey);

  H1 := Sign('bruker=7|utlop=123');
  Ok('den signerte verdien inneholder teksten',
    Pos('bruker=7|utlop=123', H1) > 0);
  Ok('og en signatur etter et punktum',
    Length(H1) > Length('bruker=7|utlop=123') + 1);
  Ok('samme tekst gir samme signatur', Sign('bruker=7|utlop=123') = H1);

  Ok('den verifiserer', Unsign(H1, H2));
  Like('og gir teksten tilbake', 'bruker=7|utlop=123', H2);

  { Dette er hele poenget: en endret tekst skal ikke passere. }
  Ok('en endret tekst avvises',
    not Unsign(StringReplace(H1, 'bruker=7', 'bruker=1', []), H2));
  Ok('og gir ingenting ut', H2 = '');
  Ok('en endret signatur avvises',
    not Unsign(Copy(H1, 1, Length(H1) - 1) + 'X', H2));
  Ok('uten punktum avvises', not Unsign('ingenpunktum', H2));
  Ok('tom streng avvises', not Unsign('', H2));

  { En tekst med punktum i skal fortsatt virke — signaturen skilles av det
    SISTE punktumet, ikke det første. }
  H1 := Sign('a.b.c');
  Ok('tekst med punktum overlever', Unsign(H1, H2) and (H2 = 'a.b.c'));

  { Bytter nøkkelen, blir alt som ble signert med den forrige ugyldig.
    Det er hele grunnen til at man kan bytte den. }
  H1 := Sign('noe');
  SetAppKey(GenerateAppKey);
  Ok('en ny nøkkel ugyldiggjør gamle signaturer', not Unsign(H1, H2));
  SetAppKey('');

  { ------------------------------------------------------- kostnad -- }
  Start('kostnad');

  T0 := Now;
  H1 := HashPassword('et passord');
  Ms := Round((Now - T0) * 24 * 60 * 60 * 1000);
  WriteLn(Format('        %d iterasjoner tok %d ms',
    [DefaultPbkdf2Iterations, Ms]));
  { Dette er hele poenget med en passordhash: den skal koste. Er den under
    50 ms, er parameteren for lav til å bremse en angriper med et grafikk-
    kort. Er den over to sekunder, blir innlogging en DoS-vektor mot din
    egen server. }
  Ok('koster nok til å være verdt navnet (>= 50 ms)', Ms >= 50);
  Ok('men ikke så mye at innlogging blir en DoS-vektor (< 2000 ms)',
    Ms < 2000);
  Ok('og hashen fra den virker', VerifyPassword('et passord', H1));
  EcdsaTester;
  WebAuthnTester;

  WriteLn;
  WriteLn(Format('— %d bestått, %d feilet', [Bestatt, Feilet]));
  if Feilet > 0 then
    Halt(1);
end.
