{ Sessions in the database, where two requests race -- shared by the
  SQLite, Postgres and MySQL suites.

  Two requests from the same browser, each with the same new session,
  both find nothing to update and both insert. The second insert loses on
  the unique index, and the store has to update instead: an error there
  would be a 500 for a visitor who did nothing wrong, and silence would
  lose their data. The window cannot be hit by timing, so the store's
  BeforeInsert hook puts the other request's insert into it, every time.

  The branch rests on each driver saying "unique violation" the same way,
  which is why it is run on all three. Each suite defines SessionStart and
  SessionOk before including it. }

var
  RaceTable: string;

procedure InsertFirst(C: TDbConnection; const IdHash: string);
var
  A: TArena;
begin
  A := TArena.Create(4 * 1024);
  try
    C.Exec(A, 'INSERT INTO ' + RaceTable + ' (id_hash, payload, expires_at) VALUES (''' +
      IdHash + ''', ''{"data":{"who":"the other request"},"flash":{}}'', 9999999999999)');
  finally
    A.Free;
  end;
end;

procedure SessionRacePart(const RaceDsn: string);
const
  Id = '0123456789abcdef0123456789abcdef';
var
  B: TDbSessions;
  Data, Flash, Mine: TSessionPairs;
  C: TDbConnection;
  A: TArena;
  R: TDbResult;
  Raised: string;
begin
  SessionStart('sessions in the database, when two requests race');
  RaceTable := 'askr_sessions_race';
  C := OpenDbConnection(RaceDsn);
  A := TArena.Create(8 * 1024);
  B := TDbSessions.Create(RaceDsn, 1);
  try
    C.Exec(A, 'DROP TABLE IF EXISTS ' + RaceTable);
    B.Table := RaceTable;
    SetLength(Mine, 1);
    Mine[0].Key := 'who';
    Mine[0].Value := 'this request';
    B.Count(0);   { makes the table }
    B.BeforeInsert := InsertFirst;
    Raised := '';
    try
      B.Save(Id, Mine, nil, 9999999999998);
    except
      on E: Exception do
        Raised := E.ClassName + ': ' + E.Message;
    end;
    B.BeforeInsert := nil;
    SessionOk('a save that loses the insert to another request does not fail' +
      BoolToStr(Raised <> '', ' -- ' + Raised, ''), Raised = '');
    R := C.Exec(A, 'SELECT count(*) FROM ' + RaceTable);
    SessionOk('there is one row for the session, not two', R.AsInt64(0, 0) = 1);
    SessionOk('and it holds what this request saved, written over the other''s',
      B.Load(Id, 0, Data, Flash) and (Length(Data) = 1) and (Data[0].Value = 'this request'));
  finally
    B.Free;
    try
      C.Exec(A, 'DROP TABLE IF EXISTS ' + RaceTable);
    except
      on Exception do ;
    end;
    A.Free;
    C.Free;
  end;
end;
