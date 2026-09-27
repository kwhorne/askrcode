{ askr.query from each driver, shared by the SQLite, Postgres and MySQL
  suites.

  Each driver sends it from its own Exec, ExecParams and InsertGetId, so
  a driver that forgot one would be silent in a suite that only ran
  another. Each suite defines TelemetryStartPart(Name) and
  TelemetryOk(What, Cond) before including it, and calls TelemetryPart
  with an open connection. }

var
  TqSeen: TStringList = nil;

procedure TqRecord(const E: TTelemetryEvent);
begin
  TqSeen.Add(E.Field('sql') + ' | rows=' + E.Field('rows') + ' | error=' +
    E.Field('error'));
end;

{ The line for the statement Sql, or '' when it sent none. }
function TqLine(const Sql: string): string;
var
  I: Integer;
begin
  for I := 0 to TqSeen.Count - 1 do
    if Copy(TqSeen[I], 1, Length(Sql) + 3) = Sql + ' | ' then
      Exit(TqSeen[I]);
  Result := '';
end;

procedure TelemetryPart(C: TDbConnection);
var
  A: TArena;
  Ph1, Ph2, Ins1, Ins2, Failed: string;
  Raised: Boolean;
begin
  TelemetryStartPart('askr.query from the driver');
  A := TArena.Create(8192);
  TqSeen := TStringList.Create;
  try
    C.Exec(A, 'DROP TABLE IF EXISTS tq_items');
    C.Exec(A, 'CREATE TABLE tq_items (id INTEGER PRIMARY KEY, secret VARCHAR(40))');
    if C.Dialect = sdPostgres then
    begin
      Ph1 := '$1';
      Ph2 := '$2';
    end
    else
    begin
      Ph1 := '?';
      Ph2 := '?';
    end;

    Ins1 := 'INSERT INTO tq_items (id, secret) VALUES (' + Ph1 + ', ' + Ph2 + ')';
    Ins2 := 'INSERT INTO tq_items (secret, id) VALUES (' + Ph1 + ', ' + Ph2 + ')';
    AttachTelemetry('askr.query', @TqRecord);
    try
      C.Exec(A, 'SELECT 1');
      C.ExecParams(A, Ins1, [DbParam(A, Int64(1)), DbParam(A, 'hunter2-sentinel')]);
      C.InsertGetId(A, Ins2, [DbParam(A, 'x'), DbParam(A, Int64(2))], '');
      Raised := False;
      try
        C.Exec(A, 'SELECT nothing FROM no_such_table');
      except
        on E: EDbError do Raised := True;
      end;
    finally
      DetachTelemetry(@TqRecord);
    end;

    TelemetryOk('Exec says so, with the rows it gave',
      TqLine('SELECT 1') = 'SELECT 1 | rows=1 | error=');
    TelemetryOk('ExecParams says so, with the statement as written and the row it touched',
      TqLine(Ins1) = Ins1 + ' | rows=1 | error=');
    TelemetryOk('InsertGetId says so', TqLine(Ins2) = Ins2 + ' | rows=0 | error=');
    Failed := TqLine('SELECT nothing FROM no_such_table');
    TelemetryOk('a failed query still raises', Raised);
    TelemetryOk('and says it failed, by its SQLSTATE',
      (Failed <> '') and (Copy(Failed, Length(Failed) - 6, 7) <> ' error='));
    TelemetryOk('and no parameter is ever in it',
      Pos('hunter2-sentinel', TqSeen.Text) = 0);
    C.Exec(A, 'DROP TABLE tq_items');
  finally
    FreeAndNil(TqSeen);
    A.Free;
  end;
end;
