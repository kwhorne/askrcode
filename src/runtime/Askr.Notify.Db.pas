{ Askr.Notify.Db — notifications kept in a table, for the bell in the
  corner of the page.

      Notes := UseDatabaseNotifications(Pool);
      ...
      Rows := Notes.ListFor(Auth.Id, True);         // unread, newest first
      Notes.MarkRead(Auth.Id, Req.Param('id'));

  **Every read and write names whose.** MarkRead takes the owner's id
  beside the notification's, and a notification that belongs to someone
  else is not found: a controller that passed the id from the URL
  straight on cannot mark another user's.

  **The row's key is the notification's uid**, made when it was sent and
  the same across a queue's retries. A retry after the first attempt got
  the row in finds it there, and is done.

  **The table is made the first time it is needed**, not at startup: the
  app should start with the database down. The same rule as api_tokens
  and the database sessions.

  **The request's own connection is used when there is one**, for the
  reason the database sessions give: a second Acquire from the pool every
  worker already holds one of can wait for ever. A queue worker has none,
  and borrows from the pool. }
unit Askr.Notify.Db;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, SyncObjs,
  Askr.Urd.Driver, Askr.Urd.Pool, Askr.Notify;

const
  DefaultNotificationsTable = 'notifications';

type
  TStoredNotification = record
    { The notification's uid: 32 hex characters. }
    Id: string;
    { The class it was sent as. }
    Kind: string;
    { What ToDatabase gave: a JSON object. }
    Data: string;
    { Unix milliseconds. ReadAt is 0 while it is unread. }
    CreatedAt: Int64;
    ReadAt: Int64;
  end;

  TStoredNotifications = array of TStoredNotification;

  TDbNotifications = class(TNotificationChannel)
  private
    FPool: TDbPool;
    FTable: string;
    FReady: Boolean;
    FLock: TCriticalSection;
    function Borrow(out Borrowed: Boolean): TDbConnection;
    procedure GiveBack(C: TDbConnection; Borrowed: Boolean);
    procedure Prepare(C: TDbConnection);
  public
    { Pool is where a connection comes from when the code runs outside a
      request. Nil works inside requests only. }
    constructor Create(APool: TDbPool);
    destructor Destroy; override;
    procedure Send(const N: TNotifiable; Notice: TNotification;
      const Uid: string); override;
    { Newest first. }
    function ListFor(const NotifiableId: string; UnreadOnly: Boolean = False;
      Limit: Integer = 50): TStoredNotifications;
    function UnreadCount(const NotifiableId: string): Integer;
    { True when this call is what marked it. False when there is no such
      notification of that person's, or it was read already. }
    function MarkRead(const NotifiableId, Id: string): Boolean;
    function MarkAllRead(const NotifiableId: string): Integer;
    function Delete(const NotifiableId, Id: string): Boolean;
    { Change before the first use if the name is taken. }
    property Table: string read FTable write FTable;
  end;

{ Makes the channel, registers it as 'database', and returns it -- the
  object a controller reads the rows through. }
function UseDatabaseNotifications(APool: TDbPool): TDbNotifications;
{ The one UseDatabaseNotifications made. }
function DatabaseNotifications: TDbNotifications;

{ The rows as a JSON array for a page: id, kind, data as the object it is,
  created_at and read_at as ISO 8601 in UTC, read_at null while unread. }
function NotificationsJson(const L: TStoredNotifications): string;

implementation

uses
  DateUtils, Askr.Core.Arena, Askr.Core.Text, Askr.Core.Json,
  Askr.Core.Clock, Askr.Urd.Model, Askr.Norn.Schema, Askr.Norn.Introspect;

var
  GNotifications: TDbNotifications = nil;

function Ph(C: TDbConnection; A: TArena; Index: Integer): string;
var
  B: TStrBuilder;
begin
  B.Init(A, 8);
  C.AppendPlaceholder(B, Index);
  Result := B.ToString;
end;

function Quoted(C: TDbConnection; A: TArena; const Name_: string): string;
var
  B: TStrBuilder;
begin
  B.Init(A, Length(Name_) + 4);
  C.AppendIdentStr(B, Name_);
  Result := B.ToString;
end;

constructor TDbNotifications.Create(APool: TDbPool);
begin
  inherited Create;
  FPool := APool;
  FTable := DefaultNotificationsTable;
  FLock := TCriticalSection.Create;
end;

destructor TDbNotifications.Destroy;
begin
  if GNotifications = Self then
    GNotifications := nil;
  FLock.Free;
  inherited Destroy;
end;

function TDbNotifications.Borrow(out Borrowed: Boolean): TDbConnection;
begin
  Borrowed := False;
  if CurrentDb <> nil then
    Result := CurrentDb
  else if FPool <> nil then
  begin
    Result := FPool.Acquire;
    Borrowed := True;
  end
  else
    raise ENotifyError.Create('Database notifications outside a request need a ' +
      'pool: UseDatabaseNotifications(Pool)');
  try
    Prepare(Result);
  except
    GiveBack(Result, Borrowed);
    raise;
  end;
end;

procedure TDbNotifications.GiveBack(C: TDbConnection; Borrowed: Boolean);
begin
  if Borrowed then
    FPool.Release(C);
end;

procedure TDbNotifications.Prepare(C: TDbConnection);
var
  A: TArena;
  Schema_: TDbSchema;
  Exists_: Boolean;
  S: TSchemaBuilder;
  T: TTableBuilder;
  Statements: TStringArray;
  I: Integer;
begin
  if FReady then
    Exit;
  FLock.Acquire;
  try
    if FReady then
      Exit;
    Schema_ := IntrospectSchema(C);
    try
      Exists_ := Schema_.Table(FTable) <> nil;
    finally
      Schema_.Free;
    end;
    if not Exists_ then
    begin
      S := TSchemaBuilder.Create(C.Dialect);
      try
        T := S.Create(FTable);
        T.IfNotExists := True;
        T.Id;
        T.Text('uid', 32).Unique;
        { Text: the framework does not own the user model. }
        T.Text('notifiable_id', 64);
        T.Text('kind', 191);
        T.Text('data');
        { Unix milliseconds, as api_tokens: several processes share the
          table. }
        T.BigInt('created_at');
        T.BigInt('read_at').Nullable;
        { Every read is one person's, newest first. }
        T.Index(['notifiable_id', 'created_at']);
        Statements := S.ToSql;
      finally
        S.Free;
      end;
      A := TArena.Create(8 * 1024);
      try
        for I := 0 to High(Statements) do
          C.Exec(A, Statements[I]);
      finally
        A.Free;
      end;
    end;
    FReady := True;
  finally
    FLock.Release;
  end;
end;

{ ToDatabase's answer, which has to be a JSON object: the page reads it as
  one, and a string stored now is a page that breaks later. }
procedure CheckObject(const Kind, Data: string);
var
  A: TArena;
  Root: PJsonValue;
  ErrorAt: SizeInt;
begin
  A := TArena.Create(Length(Data) * 2 + 1024);
  try
    if not JsonParse(A, StrDup(A, Data), Root, ErrorAt) or (Root^.Kind <> jkObject) then
      raise ENotifyError.CreateFmt('%s.ToDatabase did not give a JSON object', [Kind]);
  finally
    A.Free;
  end;
end;

procedure TDbNotifications.Send(const N: TNotifiable; Notice: TNotification;
  const Uid: string);
var
  C: TDbConnection;
  Borrowed: Boolean;
  A: TArena;
  Data: string;
begin
  if N.Id = '' then
    raise ENotifyError.CreateFmt('%s goes to the database, and the recipient has no ' +
      'id to keep it under', [Notice.ClassName]);
  Data := Notice.ToDatabase(N);
  CheckObject(Notice.ClassName, Data);
  C := Borrow(Borrowed);
  A := TArena.Create(8 * 1024);
  try
    try
      C.ExecParams(A, 'INSERT INTO ' + Quoted(C, A, FTable) +
        ' (uid, notifiable_id, kind, data, created_at) VALUES (' + Ph(C, A, 1) +
        ', ' + Ph(C, A, 2) + ', ' + Ph(C, A, 3) + ', ' + Ph(C, A, 4) + ', ' +
        Ph(C, A, 5) + ')',
        [DbParam(A, Uid), DbParam(A, N.Id), DbParam(A, Notice.ClassName),
         DbParam(A, Data), DbParam(A, UnixNowMs)]);
    except
      { A retry of a job whose first attempt got the row in. The row is
        there: that is done. }
      on E: EDbError do
        if not E.IsUniqueViolation then
          raise;
    end;
  finally
    A.Free;
    GiveBack(C, Borrowed);
  end;
end;

function TDbNotifications.ListFor(const NotifiableId: string; UnreadOnly: Boolean;
  Limit: Integer): TStoredNotifications;
var
  C: TDbConnection;
  Borrowed: Boolean;
  A: TArena;
  R: TDbResult;
  Sql: string;
  I: Integer;
begin
  Result := nil;
  if Limit < 1 then
    Limit := 1;
  C := Borrow(Borrowed);
  A := TArena.Create(32 * 1024);
  try
    Sql := 'SELECT uid, kind, data, created_at, read_at FROM ' + Quoted(C, A, FTable) +
      ' WHERE notifiable_id = ' + Ph(C, A, 1);
    if UnreadOnly then
      Sql := Sql + ' AND read_at IS NULL';
    { id breaks the tie between two in the same millisecond. }
    Sql := Sql + ' ORDER BY created_at DESC, id DESC LIMIT ' + IntToStr(Limit);
    R := C.ExecParams(A, Sql, [DbParam(A, NotifiableId)]);
    if (R = nil) or R.IsEmpty then
      Exit;
    SetLength(Result, R.RowCount);
    for I := 0 to R.RowCount - 1 do
    begin
      Result[I].Id := R.Value(I, 0).ToString;
      Result[I].Kind := R.Value(I, 1).ToString;
      Result[I].Data := R.Value(I, 2).ToString;
      Result[I].CreatedAt := R.AsInt64(I, 3);
      if R.IsNull(I, 4) then
        Result[I].ReadAt := 0
      else
        Result[I].ReadAt := R.AsInt64(I, 4);
    end;
  finally
    A.Free;
    GiveBack(C, Borrowed);
  end;
end;

function TDbNotifications.UnreadCount(const NotifiableId: string): Integer;
var
  C: TDbConnection;
  Borrowed: Boolean;
  A: TArena;
  R: TDbResult;
begin
  Result := 0;
  C := Borrow(Borrowed);
  A := TArena.Create(8 * 1024);
  try
    R := C.ExecParams(A, 'SELECT count(*) FROM ' + Quoted(C, A, FTable) +
      ' WHERE notifiable_id = ' + Ph(C, A, 1) + ' AND read_at IS NULL',
      [DbParam(A, NotifiableId)]);
    if (R <> nil) and not R.IsEmpty then
      Result := R.AsInt64(0, 0);
  finally
    A.Free;
    GiveBack(C, Borrowed);
  end;
end;

function TDbNotifications.MarkRead(const NotifiableId, Id: string): Boolean;
var
  C: TDbConnection;
  Borrowed: Boolean;
  A: TArena;
  R: TDbResult;
begin
  C := Borrow(Borrowed);
  A := TArena.Create(8 * 1024);
  try
    R := C.ExecParams(A, 'UPDATE ' + Quoted(C, A, FTable) + ' SET read_at = ' +
      Ph(C, A, 1) + ' WHERE uid = ' + Ph(C, A, 2) + ' AND notifiable_id = ' +
      Ph(C, A, 3) + ' AND read_at IS NULL',
      [DbParam(A, UnixNowMs), DbParam(A, Id), DbParam(A, NotifiableId)]);
    Result := (R <> nil) and (R.AffectedRows > 0);
  finally
    A.Free;
    GiveBack(C, Borrowed);
  end;
end;

function TDbNotifications.MarkAllRead(const NotifiableId: string): Integer;
var
  C: TDbConnection;
  Borrowed: Boolean;
  A: TArena;
  R: TDbResult;
begin
  Result := 0;
  C := Borrow(Borrowed);
  A := TArena.Create(8 * 1024);
  try
    R := C.ExecParams(A, 'UPDATE ' + Quoted(C, A, FTable) + ' SET read_at = ' +
      Ph(C, A, 1) + ' WHERE notifiable_id = ' + Ph(C, A, 2) + ' AND read_at IS NULL',
      [DbParam(A, UnixNowMs), DbParam(A, NotifiableId)]);
    if R <> nil then
      Result := R.AffectedRows;
  finally
    A.Free;
    GiveBack(C, Borrowed);
  end;
end;

function TDbNotifications.Delete(const NotifiableId, Id: string): Boolean;
var
  C: TDbConnection;
  Borrowed: Boolean;
  A: TArena;
  R: TDbResult;
begin
  C := Borrow(Borrowed);
  A := TArena.Create(8 * 1024);
  try
    R := C.ExecParams(A, 'DELETE FROM ' + Quoted(C, A, FTable) + ' WHERE uid = ' +
      Ph(C, A, 1) + ' AND notifiable_id = ' + Ph(C, A, 2),
      [DbParam(A, Id), DbParam(A, NotifiableId)]);
    Result := (R <> nil) and (R.AffectedRows > 0);
  finally
    A.Free;
    GiveBack(C, Borrowed);
  end;
end;

function UseDatabaseNotifications(APool: TDbPool): TDbNotifications;
begin
  Result := TDbNotifications.Create(APool);
  { The registry owns it, and frees the one it replaces. }
  RegisterChannel(ChannelDatabase, Result);
  GNotifications := Result;
end;

function DatabaseNotifications: TDbNotifications;
begin
  if GNotifications = nil then
    raise ENotifyError.Create('No database notifications: call ' +
      'UseDatabaseNotifications at startup');
  Result := GNotifications;
end;

function IsoUtc(Ms: Int64): string;
begin
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', UnixToDateTime(Ms div 1000, True));
end;

function NotificationsJson(const L: TStoredNotifications): string;
var
  A: TArena;
  W: TJsonWriter;
  I: Integer;
begin
  A := TArena.Create(16 * 1024);
  try
    W.Init(A, 1024);
    W.BeginArray;
    for I := 0 to High(L) do
    begin
      W.BeginObject;
      W.Field('id', L[I].Id);
      W.Field('kind', L[I].Kind);
      W.FieldRaw('data', StrDup(A, L[I].Data));
      W.Field('created_at', IsoUtc(L[I].CreatedAt));
      if L[I].ReadAt = 0 then
        W.FieldNull('read_at')
      else
        W.Field('read_at', IsoUtc(L[I].ReadAt));
      W.EndObject;
    end;
    W.EndArray;
    Result := W.ToString;
  finally
    A.Free;
  end;
end;

end.
