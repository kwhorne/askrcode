{ Norn end to end: migrations, introspection, codegen and a drift check.

  Step 3 of phase 1. Run with `./askr schema` (needs `./askr db:up`).

  The demo also answers the question the Rún document asks: does codegen
  hold, in the sense that generated code and the database cannot drift
  apart without something noticing? The last part creates drift on purpose
  and sees what happens. }
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
  { The migrator logs every statement; here the headings are enough. }
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
    WriteLn('  (could not find ', Path, ')');
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
  WriteLn('Askr — Norn end to end');
  WriteLn;

  C := OpenDbConnection(Dsn);
  A := TArena.Create(16 * 1024);
  try
    RensDatabasen(C);

    WriteLn('Migrasjoner');
    M := TMigrator.Create(C);
    try
      M.OnLog := @Quiet;
      Expect(M.PendingCount = 3, 'three migrations are pending');
      Ran := M.Up;
      Expect(Ran = 3, 'all three ran');
      Expect(M.PendingCount = 0, 'nothing is pending afterwards');

      St := M.Status;
      Expect(Length(St) = 3, 'status shows three');
      for I := 0 to High(St) do
        Si(St[I].Version, St[I].Title);
      Expect(St[0].Title = 'Create customers',
        'the title is derived from the class name');
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
        Expect(T.PrimaryKey = 'id', 'the primary key was read back');
        Expect(T.HasColumn('active'),
          'the column from the ALTER migration is there');
        Expect(T.IsIndexed('created_at'),
          'the index from the migration was found');
        Expect(T.IsIndexed('email'), 'UNIQUE gives an index too');
        Expect(not T.IsIndexed('balance'), 'balance has no index');

        T := Schema.Table('orders');
        Expect(T.ForeignKeyCount = 1, 'the foreign key was read back');
        Expect(T.ForeignKey(0).RefTable = 'customers', 'it points at customers');
        Si('schema fingerprint', SchemaFingerprint(Schema));
        Avtrykk1 := SchemaFingerprint(Schema);
        WriteLn;

        WriteLn('Codegen');
        Opts := DefaultCodegenOptions;
        Opts.OutputDir := OutDir;
        Files := GenerateSources(Schema, Opts);
        Expect(Length(Files) = 3,
          'two table units and one manifest (the framework''s own tables are skipped)');
        Changed := WriteSources(Files, Opts);
        Si('files written', IntToStr(Length(Changed)));

        Drift := CheckDrift(Files, Opts);
        Expect(Length(Drift) = 0, 'no drift right after generating');

        { Write again with no changes and nothing is to be touched. }
        Changed := WriteSources(Files, Opts);
        Expect(Length(Changed) = 0,
          'unchanged files are not rewritten');
        WriteLn;

        WriteLn('Generated code');
        WriteOutFile(IncludeTrailingPathDelimiter(OutDir) +
          'App.Schema.Customers.pas', 26);
        WriteLn;
      finally
        Schema.Free;
      end;

      { Here is the core question: what happens when the database changes
        without the migrations knowing about it? }
      WriteLn('Drift: a column added outside the migrations');
      C.Exec(A, 'ALTER TABLE customers ADD COLUMN rabatt NUMERIC(5,2)');
      Schema := IntrospectSchema(C);
      try
        Avtrykk2 := SchemaFingerprint(Schema);
        Expect(Avtrykk1 <> Avtrykk2, 'the schema fingerprint changed');
        Files := GenerateSources(Schema, Opts);
        Drift := CheckDrift(Files, Opts);
        Expect(Length(Drift) > 0, 'the drift check notices');
        for I := 0 to High(Drift) do
          Si('avviker', Drift[I]);
      finally
        Schema.Free;
      end;
      WriteLn;

      WriteLn('Rolling back');
      C.Exec(A, 'ALTER TABLE customers DROP COLUMN rabatt');
      Ran := M.Down(1);
      Expect(Ran = 1, 'one migration rolled back');
      Schema := IntrospectSchema(C);
      try
        Expect(not Schema.Table('customers').HasColumn('active'),
          'the column is gone again');
        Expect(SchemaFingerprint(Schema) <> Avtrykk1,
          'the fingerprint is a different one');
      finally
        Schema.Free;
      end;
      Expect(M.PendingCount = 1, 'it is pending again now');
      Ran := M.Up;
      Expect(Ran = 1, 'and can be run again');
      Schema := IntrospectSchema(C);
      try
        Expect(SchemaFingerprint(Schema) = Avtrykk1,
          'the fingerprint is back where it was');
        Files := GenerateSources(Schema, Opts);
        Expect(Length(CheckDrift(Files, Opts)) = 0, 'and the drift is gone');
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
    WriteLn('Norn holds: migrations, introspection, codegen and the drift check.')
  else
  begin
    WriteLn(Err, ' feil.');
    Halt(1);
  end;
end.
