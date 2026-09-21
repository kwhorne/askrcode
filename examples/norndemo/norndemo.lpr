{ Norn ende-til-ende: migrasjoner, introspeksjon, codegen og driftsjekk.

  Steg 3 i fase 1. Kjøres med `./askr schema` (krever `./askr db:up`).

  Demoen svarer også på spørsmålet Rún-dokumentet stiller: holder codegen, i
  den forstand at generert kode og database ikke kan drive fra hverandre uten
  at noe oppdager det? Den siste delen lager drift med vilje og ser hva som
  skjer. }
program NornDemo;

{$mode Delphi}{$H+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  SysUtils, Classes,
  Askr.Core.Arena,
  Askr.Urd.Driver, Askr.Urd.Pg,
  Askr.Norn.Schema, Askr.Norn.Migration, Askr.Norn.Introspect,
  Askr.Norn.Codegen,
  App.Migrations;

var
  Err: Integer = 0;

procedure Si(const Etikett, Value_: string);
var
  Pad: string;
begin
  Pad := Etikett;
  while Length(Pad) < 30 do
    Pad := Pad + ' ';
  WriteLn('  ', Pad, Value_);
end;

procedure Expect(Betingelse: Boolean; const What: string);
begin
  if Betingelse then
    WriteLn('  ok   ', What)
  else
  begin
    Inc(Err);
    WriteLn('  FEIL ', What);
  end;
end;

procedure Quiet(const Line: string);
begin
  { Migratoren logger hver setning; her holder det med overskriftene. }
  if (Length(Line) > 4) and (Copy(Line, 1, 4) = '    ') then
    Exit;
  WriteLn(Line);
end;

function Dsn: string;
begin
  Result := GetEnvironmentVariable('ASKR_PG_DSN');
  if Result = '' then
    Result := 'postgresql://askr:askr@127.0.0.1:5433/askr_dev';
end;

function OutDir: string;
begin
  Result := GetEnvironmentVariable('ASKR_SCHEMA_OUT');
  if Result = '' then
    Result := '.build/schema';
end;

procedure RensDatabasen(C: TDbConnection);
var
  A: TArena;
begin
  A := TArena.Create(16 * 1024);
  try
    C.Exec(A, 'DROP TABLE IF EXISTS orders');
    C.Exec(A, 'DROP TABLE IF EXISTS customers');
    C.Exec(A, 'DROP TABLE IF EXISTS ' + MigrationsTable);
    C.Exec(A, 'DROP TABLE IF EXISTS spike_customers');
    C.Exec(A, 'DROP TABLE IF EXISTS spike_customers');
  finally
    A.Free;
  end;
end;

procedure WriteOutFile(const Path: string; MaxLines: Integer);
var
  L: TStringList;
  I: Integer;
begin
  if not FileExists(Path) then
  begin
    WriteLn('  (fant ikke ', Path, ')');
    Exit;
  end;
  L := TStringList.Create;
  try
    L.LoadFromFile(Path);
    for I := 0 to L.Count - 1 do
    begin
      if I >= MaxLines then
      begin
        WriteLn('  | ... (', L.Count - MaxLines, ' linjer til)');
        Break;
      end;
      WriteLn('  | ', L[I]);
    end;
  finally
    L.Free;
  end;
end;

var
  C: TDbConnection;
  M: TMigrator;
  St: TMigrationInfoArray;
  Schema: TDbSchema;
  Opts: TCodegenOptions;
  Files: TGeneratedFiles;
  Changed, Drift: TStringArray;
  T: TDbTable;
  A: TArena;
  I, Ran: Integer;
  Avtrykk1, Avtrykk2: string;
begin
  WriteLn('Askr — Norn ende-til-ende');
  WriteLn;

  C := OpenDbConnection(Dsn);
  A := TArena.Create(16 * 1024);
  try
    RensDatabasen(C);

    WriteLn('Migrasjoner');
    M := TMigrator.Create(C);
    try
      M.OnLog := @Quiet;
      Expect(M.PendingCount = 3, 'tre migrasjoner venter');
      Ran := M.Up;
      Expect(Ran = 3, 'alle tre kjørte');
      Expect(M.PendingCount = 0, 'ingenting venter etterpå');

      St := M.Status;
      Expect(Length(St) = 3, 'status viser tre');
      for I := 0 to High(St) do
        Si(St[I].Version, St[I].Title);
      Expect(St[0].Title = 'Create customers',
        'tittel utledes fra klassenavnet');
      WriteLn;

      WriteLn('Introspeksjon');
      Schema := IntrospectSchema(C);
      try
        Expect(Schema.Table('customers') <> nil, 'customers finnes');
        Expect(Schema.Table('orders') <> nil, 'orders finnes');
        T := Schema.Table('customers');
        Si('kolonner i customers', IntToStr(T.ColumnCount));
        Expect(T.ColumnCount = 7,
          'id, name, email, balance, created_at, updated_at, active');
        Expect(T.PrimaryKey = 'id', 'primærnøkkelen ble lest tilbake');
        Expect(T.HasColumn('active'),
          'kolonnen fra ALTER-migrasjonen er med');
        Expect(T.IsIndexed('created_at'),
          'indeksen fra migrasjonen ble funnet');
        Expect(T.IsIndexed('email'), 'UNIQUE gir også en indeks');
        Expect(not T.IsIndexed('balance'), 'balance har ingen indeks');

        T := Schema.Table('orders');
        Expect(T.ForeignKeyCount = 1, 'fremmednøkkelen ble lest tilbake');
        Expect(T.ForeignKey(0).RefTable = 'customers', 'den peker på customers');
        Si('skjemaavtrykk', SchemaFingerprint(Schema));
        Avtrykk1 := SchemaFingerprint(Schema);
        WriteLn;

        WriteLn('Codegen');
        Opts := DefaultCodegenOptions;
        Opts.OutputDir := OutDir;
        Files := GenerateSources(Schema, Opts);
        Expect(Length(Files) = 3,
          'to tabell-units og ett manifest (migrasjonstabellen hoppes over)');
        Changed := WriteSources(Files, Opts);
        Si('filer skrevet', IntToStr(Length(Changed)));

        Drift := CheckDrift(Files, Opts);
        Expect(Length(Drift) = 0, 'ingen drift rett etter generering');

        { Skriver man igjen uten endringer, skal ingenting røres. }
        Changed := WriteSources(Files, Opts);
        Expect(Length(Changed) = 0,
          'uendrede filer skrives ikke på nytt');
        WriteLn;

        WriteLn('Generert kode');
        WriteOutFile(IncludeTrailingPathDelimiter(OutDir) +
          'App.Schema.Customers.pas', 26);
        WriteLn;
      finally
        Schema.Free;
      end;

      { Her er kjernespørsmålet: hva skjer når databasen endres uten at
        migrasjonene vet om det? }
      WriteLn('Drift: kolonne lagt til utenom migrasjonene');
      C.Exec(A, 'ALTER TABLE customers ADD COLUMN rabatt NUMERIC(5,2)');
      Schema := IntrospectSchema(C);
      try
        Avtrykk2 := SchemaFingerprint(Schema);
        Expect(Avtrykk1 <> Avtrykk2, 'skjemaavtrykket endret seg');
        Files := GenerateSources(Schema, Opts);
        Drift := CheckDrift(Files, Opts);
        Expect(Length(Drift) > 0, 'driftsjekken oppdager det');
        for I := 0 to High(Drift) do
          Si('avviker', Drift[I]);
      finally
        Schema.Free;
      end;
      WriteLn;

      WriteLn('Rulle tilbake');
      C.Exec(A, 'ALTER TABLE customers DROP COLUMN rabatt');
      Ran := M.Down(1);
      Expect(Ran = 1, 'én migrasjon rullet tilbake');
      Schema := IntrospectSchema(C);
      try
        Expect(not Schema.Table('customers').HasColumn('active'),
          'kolonnen er borte igjen');
        Expect(SchemaFingerprint(Schema) <> Avtrykk1,
          'avtrykket er et annet enn før');
      finally
        Schema.Free;
      end;
      Expect(M.PendingCount = 1, 'den venter nå igjen');
      Ran := M.Up;
      Expect(Ran = 1, 'og kan kjøres på nytt');
      Schema := IntrospectSchema(C);
      try
        Expect(SchemaFingerprint(Schema) = Avtrykk1,
          'avtrykket er tilbake der det var');
        Files := GenerateSources(Schema, Opts);
        Expect(Length(CheckDrift(Files, Opts)) = 0, 'og driften er borte');
      finally
        Schema.Free;
      end;
    finally
      M.Free;
    end;
  finally
    A.Free;
    C.Free;
  end;

  WriteLn;
  if Err = 0 then
    WriteLn('Norn holder: migrasjoner, introspeksjon, codegen og driftsjekk.')
  else
  begin
    WriteLn(Err, ' feil.');
    Halt(1);
  end;
end.
