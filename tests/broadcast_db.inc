{ Broadcasts through the database -- shared by the SQLite, Postgres and
  MySQL suites.

  Two TDbBroadcasts on one database stand in for two processes: what one
  writes, the other's poll delivers, under the same id, and neither hears
  itself. Where two writers can overlap -- Postgres and MySQL -- an insert
  held open in a transaction takes an id that commits after a larger one,
  and the poll has to find it when it does. Each suite defines
  BroadcastStart and BroadcastOk before including it. }

var
  BdHeard: TStringList = nil;

procedure BdSink(Id: Int64; const Channel, Event, Data: string);
begin
  if BdHeard <> nil then
    BdHeard.Add(IntToStr(Id) + ' ' + Channel + ' ' + Event + ' ' + Data);
end;

procedure BroadcastDbPart(const Dsn: string; ConcurrentWriters: Boolean);
const
  Table = 'askr_broadcast_test';
var
  A, B, Late: TDbBroadcasts;
  C: TDbConnection;
  Ar: TArena;
  IdA, Held, After: Int64;
  Raised: Boolean;
begin
  BroadcastStart('broadcasts through the database, one process to another');
  Ar := TArena.Create(8 * 1024);
  C := OpenDbConnection(Dsn);
  BdHeard := TStringList.Create;
  AddBroadcastSink(@BdSink);
  A := TDbBroadcasts.Create(Dsn);
  B := TDbBroadcasts.Create(Dsn);
  Late := nil;
  try
    C.Exec(Ar, 'DROP TABLE IF EXISTS ' + Table);
    A.Table := Table;
    B.Table := Table;
    A.Poll;
    B.Poll;

    IdA := A.Send('orders', 'placed', '{"id":1}');
    BroadcastOk('a broadcast is written, with an id', IdA > 0);
    B.Poll;
    BroadcastOk('the other process delivers it, under the same id',
      BdHeard.Text = IntToStr(IdA) + ' orders placed {"id":1}'#10);
    BdHeard.Clear;
    A.Poll;
    BroadcastOk('the process that wrote it does not hear it twice', BdHeard.Count = 0);
    B.Poll;
    BroadcastOk('and nor does the other', BdHeard.Count = 0);

    Late := TDbBroadcasts.Create(Dsn);
    Late.Table := Table;
    Late.Poll;
    Late.Poll;
    BroadcastOk('a process that starts later hears from then on, not the table''s past',
      BdHeard.Count = 0);

    Raised := False;
    try
      A.Send('orders', 'placed', 'a'#0'b');
    except
      on E: EBroadcastError do Raised := True;
    end;
    BroadcastOk('a NUL in the payload is refused before it is written', Raised);

    { Through Broadcast itself: delivered here at once, under the id the
      database gave, and there on the next poll under the same one. }
    A.Start;
    try
      Broadcast('orders', 'shipped', '{"id":2}');
    finally
      A.Stop;
    end;
    BroadcastOk('Broadcast through the relay is delivered here at once',
      (BdHeard.Count = 1) and (Pos(' orders shipped {"id":2}', BdHeard[0]) > 0));
    After := StrToInt64Def(Copy(BdHeard[0], 1, Pos(' ', BdHeard[0]) - 1), 0);
    BroadcastOk('under an id from the database, after the one before', After > IdA);
    BdHeard.Clear;
    B.Poll;
    BroadcastOk('and on the other process under the same id',
      BdHeard.Text = IntToStr(After) + ' orders shipped {"id":2}'#10);

    if ConcurrentWriters then
    begin
      { An id that commits after a larger one. }
      BdHeard.Clear;
      C.StartTransaction;
      Held := C.InsertGetId(Ar, 'INSERT INTO ' + Table +
        ' (channel, kind, payload, origin, sent_at) VALUES (''orders'', ''held'', ''late'', ''other'', 1)',
        [], 'id');
      After := A.Send('orders', 'placed', 'on time');
      BroadcastOk('with an insert held open, a later one takes a larger id', After > Held);
      B.Poll;
      BroadcastOk('the poll delivers the one that committed',
        BdHeard.Text = IntToStr(After) + ' orders placed on time'#10);
      C.Commit;
      BdHeard.Clear;
      B.Poll;
      BroadcastOk('and the held one when it commits, though its id is smaller',
        BdHeard.Text = IntToStr(Held) + ' orders held late'#10);
      BdHeard.Clear;
      B.Poll;
      BroadcastOk('once', BdHeard.Count = 0);
    end;
  finally
    FreeAndNil(BdHeard);
    Late.Free;
    B.Free;
    A.Free;
    C.Exec(Ar, 'DROP TABLE IF EXISTS ' + Table);
    C.Free;
    Ar.Free;
  end;
end;
