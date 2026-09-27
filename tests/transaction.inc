{ TDbTransaction, shared by the SQLite, Postgres and MySQL suites.

  The same file in all three, because the three are where it differs:
  SAVEPOINT is spelt alike, but Postgres aborts a whole transaction on an
  error inside it until something is rolled back, and a test that did not
  hold that is a test that passes on the other two. Each suite defines
  TransactionStart(Name) and TransactionOk(What, Cond) before including
  it, and calls TransactionPart with an open connection. }

procedure TxExec(C: TDbConnection; const Sql: string);
var
  A: TArena;
begin
  A := TArena.Create(4096);
  try
    C.Exec(A, Sql);
  finally
    A.Free;
  end;
end;

function TxNames(C: TDbConnection): string;
var
  A: TArena;
  R: TDbResult;
  I: Integer;
begin
  Result := '';
  A := TArena.Create(4096);
  try
    R := C.Exec(A, 'SELECT name FROM tx_items ORDER BY name');
    for I := 0 to R.RowCount - 1 do
      Result := Result + R.Value(I, 0).ToString;
  finally
    A.Free;
  end;
end;

procedure TransactionPart(C: TDbConnection);
var
  T, Inner: TDbTransaction;
  Raised: Boolean;
begin
  TransactionStart('TDbTransaction: a transaction, or a savepoint inside one');
  TxExec(C, 'DROP TABLE IF EXISTS tx_items');
  TxExec(C, 'CREATE TABLE tx_items (id INTEGER PRIMARY KEY, ' +
    'name VARCHAR(40) NOT NULL UNIQUE)');

  T := C.Transaction;
  try
    TransactionOk('outside a transaction it starts one', C.InTransaction and not T.Nested);
    TxExec(C, 'INSERT INTO tx_items VALUES (1, ''a'')');
    T.Commit;
  finally
    T.Finish;
  end;
  TransactionOk('a commit keeps it', TxNames(C) = 'a');
  TransactionOk('and ends the transaction', not C.InTransaction);

  T := C.Transaction;
  try
    TxExec(C, 'INSERT INTO tx_items VALUES (2, ''x'')');
  finally
    T.Finish;
  end;
  TransactionOk('Finish without a commit rolls back', TxNames(C) = 'a');
  TransactionOk('and ends it', not C.InTransaction);

  { Inside: a savepoint, and its rollback takes back only its own. }
  T := C.Transaction;
  try
    TxExec(C, 'INSERT INTO tx_items VALUES (3, ''b'')');
    Inner := C.Transaction;
    try
      TransactionOk('inside a transaction it is a savepoint', Inner.Nested);
      TxExec(C, 'INSERT INTO tx_items VALUES (4, ''c'')');
      Inner.Rollback;
    finally
      Inner.Finish;
    end;
    TransactionOk('a savepoint rolled back leaves the transaction open', C.InTransaction);
    T.Commit;
  finally
    T.Finish;
  end;
  TransactionOk('what came before the savepoint is kept, and what was in it is not',
    TxNames(C) = 'ab');

  { A savepoint committed is the enclosing transaction's: it goes with it. }
  T := C.Transaction;
  try
    Inner := C.Transaction;
    try
      TxExec(C, 'INSERT INTO tx_items VALUES (5, ''d'')');
      Inner.Commit;
    finally
      Inner.Finish;
    end;
  finally
    T.Finish;
  end;
  TransactionOk('a committed savepoint goes with the transaction it is in',
    TxNames(C) = 'ab');

  { An error inside a savepoint: the enclosing transaction goes on. On
    Postgres it is aborted until the savepoint is rolled back -- that is
    the case this holds. }
  T := C.Transaction;
  try
    TxExec(C, 'INSERT INTO tx_items VALUES (6, ''e'')');
    Inner := C.Transaction;
    try
      Raised := False;
      try
        TxExec(C, 'INSERT INTO tx_items VALUES (7, ''a'')');   { a is taken }
      except
        on E: EDbError do
          Raised := E.IsUniqueViolation;
      end;
      TransactionOk('the unique violation inside', Raised);
    finally
      Inner.Finish;
    end;
    TxExec(C, 'INSERT INTO tx_items VALUES (8, ''f'')');
    T.Commit;
  finally
    T.Finish;
  end;
  TransactionOk('does not take the enclosing transaction with it', TxNames(C) = 'abef');

  { Two savepoints one after the other, at the same depth. }
  T := C.Transaction;
  try
    Inner := C.Transaction;
    try
      TxExec(C, 'INSERT INTO tx_items VALUES (9, ''g'')');
      Inner.Commit;
    finally
      Inner.Finish;
    end;
    Inner := C.Transaction;
    try
      TxExec(C, 'INSERT INTO tx_items VALUES (10, ''h'')');
      Inner.Rollback;
    finally
      Inner.Finish;
    end;
    T.Commit;
  finally
    T.Finish;
  end;
  TransactionOk('savepoints one after the other', TxNames(C) = 'abefg');

  { Inside a transaction opened the old way, by hand. }
  C.StartTransaction;
  Inner := C.Transaction;
  try
    TransactionOk('StartTransaction by hand makes it a savepoint', Inner.Nested);
    TxExec(C, 'INSERT INTO tx_items VALUES (11, ''i'')');
    Inner.Commit;
  finally
    Inner.Finish;
  end;
  C.Rollback;
  TransactionOk('and the hand-opened transaction decides', TxNames(C) = 'abefg');

  T := C.Transaction;
  T.Commit;
  Raised := False;
  try
    T.Commit;
  except
    on E: EDbError do
      Raised := True;
  end;
  TransactionOk('a second commit raises', Raised);
  T.Finish;
  TransactionOk('and Finish after a commit does nothing', not C.InTransaction);

  TxExec(C, 'DROP TABLE tx_items');
end;
