{ Spike: libpq over C-ABI, med resultatet i arenaen.

  PRD-en kaller C-ABI-interop den største enkeltrisikoen i prosjektet. Dette
  programmet er der for å avlive den, og for å svare på det som faktisk var
  uavklart: hvem eier radene når destructorer aldri kjører.

  Kjøres med `./askr spike`. DSN kan overstyres med ASKR_PG_DSN. }
program PgSpike;

{$mode Delphi}{$H+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  SysUtils,
  Askr.Core.Arena, Askr.Core.Text, Askr.Urd.Driver, Askr.Urd.Pg;

var
  Feil: Integer = 0;

procedure Si(const Etikett, Verdi: string);
var
  Pad: string;
begin
  Pad := Etikett;
  while Length(Pad) < 34 do
    Pad := Pad + ' ';
  WriteLn('  ', Pad, Verdi);
end;

procedure Krev(Betingelse: Boolean; const Hva: string);
begin
  if Betingelse then
    WriteLn('  ok   ', Hva)
  else
  begin
    Inc(Feil);
    WriteLn('  FEIL ', Hva);
  end;
end;

{ Brukes til å vise at Defer faktisk kjører ved Reset. }
var
  RyddetAntall: Integer = 0;

procedure TellOpprydning(Data: Pointer);
begin
  Inc(RyddetAntall);
end;

function VisNull(R: TDbResult; Row: Integer; const Felt: string): string;
begin
  if R.IsNull(Row, R.IndexOfField(Felt)) then
    Result := '<null>'
  else
    Result := R.Value(Row, Felt).ToString;
end;

function Dsn: string;
begin
  Result := GetEnvironmentVariable('ASKR_PG_DSN');
  if Result = '' then
    Result := 'postgresql://askr:askr@127.0.0.1:5433/askr_dev';
end;

var
  A: TArena;
  C: TPgConnection;
  R: TDbResult;
  I: Integer;
  EtterOppsett: PtrUInt;
begin
  WriteLn('Askr — spike: libpq, C-ABI og arena');
  WriteLn;

  { 1. Lastes biblioteket i det hele tatt? }
  WriteLn('Biblioteket');
  Krev(PgAvailable, 'libpq lastet med dlopen');
  if not PgAvailable then
  begin
    WriteLn;
    WriteLn('  Uten libpq stopper spiken her. Feilmeldingen fra laster:');
    try
      C := TPgConnection.Create(Dsn);
      C.Free;
    except
      on E: Exception do
        WriteLn('  ', E.Message);
    end;
    Halt(1);
  end;
  Si('lastet fra', PgLibraryName);
  WriteLn;

  A := TArena.Create(64 * 1024);
  try
    { 2. Forbindelse. Den er ikke et arena-objekt — den lever på heapen. }
    WriteLn('Forbindelse');
    C := TPgConnection.Create(Dsn);
    try
      Krev(C.IsAlive, 'koblet til');
      Si('serverversjon', IntToStr(C.ServerVersion));
      WriteLn;

      { 3. Det enkleste som kan kalles en spørring. }
      WriteLn('SELECT 1');
      R := C.Exec(A, 'SELECT 1 AS ett');
      Krev(R.RowCount = 1, 'én rad');
      Krev(R.FieldCount = 1, 'én kolonne');
      Krev(R.FieldName(0).EqualsStr('ett'), 'kolonnenavnet kom med');
      Krev(R.Value(0, 0).EqualsStr('1'), 'verdien er 1');
      Si('verdien som TStr', R.Value(0, 0).ToString);
      WriteLn;

      { 4. Ekte data: DDL, parametre, UTF-8, NULL og typer. }
      WriteLn('Rundtur med parametre');
      C.Exec(A, 'DROP TABLE IF EXISTS spike_customers');
      C.Exec(A,
        'CREATE TABLE spike_customers (' +
        '  id BIGSERIAL PRIMARY KEY,' +
        '  name TEXT NOT NULL,' +
        '  email TEXT UNIQUE,' +
        '  balance NUMERIC(12,2) NOT NULL DEFAULT 0' +
        ')');

      R := C.ExecParams(A,
        'INSERT INTO spike_customers (name, email, balance) ' +
        'VALUES ($1, $2, $3) RETURNING id',
        [DbParam(A, 'Knut W. Hørne'), DbParam(A, 'kh@gets.no'),
         DbParam(A, '1234.50')]);
      Krev(R.RowCount = 1, 'RETURNING ga id tilbake');
      Si('ny id', R.Value(0, 'id').ToString);

      C.ExecParams(A,
        'INSERT INTO spike_customers (name, email) VALUES ($1, $2)',
        [DbParam(A, 'Uten email'), DbNull]);

      R := C.Exec(A,
        'SELECT id, name, email, balance FROM spike_customers ORDER BY id');
      Krev(R.RowCount = 2, 'to rader');
      Krev(R.Value(0, 'name').EqualsStr('Knut W. Hørne'),
        'UTF-8 overlevde rundturen');
      Krev(R.Value(0, 'balance').EqualsStr('1234.50'),
        'NUMERIC kom tilbake uten avrunding');
      Krev(R.IsNull(1, R.IndexOfField('email')), 'NULL skilles fra tom streng');
      Krev(not R.IsNull(0, R.IndexOfField('email')), 'ikke-NULL er ikke NULL');

      WriteLn;
      WriteLn('  rader:');
      for I := 0 to R.RowCount - 1 do
        WriteLn(Format('    id=%s name=%s email=%s balance=%s',
          [R.Value(I, 'id').ToString,
           R.Value(I, 'name').ToString,
           VisNull(R, I, 'email'),
           R.Value(I, 'balance').ToString]));
      WriteLn;

      { 5. Feil skal komme tilbake som EDbError med SQLSTATE, ikke som 500. }
      WriteLn('Feilhåndtering');
      try
        C.ExecParams(A,
          'INSERT INTO spike_customers (name, email) VALUES ($1, $2)',
          [DbParam(A, 'Duplikat'), DbParam(A, 'kh@gets.no')]);
        Krev(False, 'unik-brudd skulle kastet');
      except
        on E: EDbError do
        begin
          Krev(E.SqlState = '23505', 'unik-brudd gir SQLSTATE 23505');
          Si('sqlstate', E.SqlState);
        end;
      end;

      try
        C.Exec(A, 'SELECT * FROM finnes_ikke');
        Krev(False, 'ukjent tabell skulle kastet');
      except
        on E: EDbError do
          Krev(E.SqlState = '42P01', 'ukjent tabell gir SQLSTATE 42P01');
      end;

      Krev(C.IsAlive, 'forbindelsen lever etter to feil');
      WriteLn;

      { 6. Transaksjon. }
      WriteLn('Transaksjon');
      C.StartTransaction;
      C.ExecParams(A, 'INSERT INTO spike_customers (name) VALUES ($1)',
        [DbParam(A, 'Rulles tilbake')]);
      R := C.Exec(A, 'SELECT count(*) FROM spike_customers');
      Krev(R.Value(0, 0).EqualsStr('3'), 'raden er synlig inne i transaksjonen');
      C.Rollback;
      R := C.Exec(A, 'SELECT count(*) FROM spike_customers');
      Krev(R.Value(0, 0).EqualsStr('2'), 'ROLLBACK fjernet den igjen');
      WriteLn;

      { 7. Arenaen: alt over ligger der, og forsvinner i én operasjon. }
      WriteLn('Arena');
      EtterOppsett := A.BytesLive;
      Si('bytes i bruk etter alt over', IntToStr(EtterOppsett));
      Si('bytes reservert fra OS', IntToStr(A.BytesReserved));
      Si('blokker', IntToStr(A.BlockCount));

      A.Defer(TellOpprydning, nil);
      A.Defer(TellOpprydning, nil);
      A.Reset;
      Krev(A.BytesLive = 0, 'Reset frigjorde hele resultatsettet');
      Krev(RyddetAntall = 2, 'Defer kjørte opprydningen ved Reset');

      { 8. Tusen spørringer skal ikke få arenaen til å vokse. }
      WriteLn;
      WriteLn('Tusen spørringer');
      for I := 1 to 50 do
      begin
        A.Reset;
        C.ExecParams(A, 'SELECT id, name, email, balance FROM spike_customers WHERE id >= $1',
          [DbParam(A, Int64(0))]);
      end;
      EtterOppsett := A.BytesReserved;
      for I := 1 to 1000 do
      begin
        A.Reset;
        C.ExecParams(A, 'SELECT id, name, email, balance FROM spike_customers WHERE id >= $1',
          [DbParam(A, Int64(0))]);
      end;
      Krev(A.BytesReserved = EtterOppsett,
        'arenaen vokste ikke over 1000 spørringer');
      Si('reservert etter 1050 spørringer', IntToStr(A.BytesReserved));
      Si('topp per spørring', IntToStr(A.HighWaterMark));

      C.Exec(A, 'DROP TABLE IF EXISTS spike_customers');
    finally
      C.Free;
    end;
  finally
    A.Free;
  end;

  WriteLn;
  if Feil = 0 then
    WriteLn('Spiken holder. C-ABI-risikoen er avlivet.')
  else
  begin
    WriteLn(Feil, ' feil.');
    Halt(1);
  end;
end.
