{ Many-to-many through a pivot -- shared by the SQLite, Postgres and MySQL
  suites.

  The same file in all three, because the SQL is where they differ: an
  alias in a join, an IN list of placeholders, a foreign key that refuses
  a row to nothing. Each suite defines PivotStart(Name) and
  PivotOk(What, Cond) before including it.

  Posts to tags through pv_post_pv_tag. The post side names nothing and
  takes the conventions; the tag side names all three, so both paths are
  used against the same table. Tags soft-delete, so the one rule Preload
  adds -- a trashed row is not shown, though it is still attached -- is
  measured. }

type
  TPvTag = class(TModel)
  private
    FId: Int64;
    FName: string;
    FDeletedAt: TDateTime;
  published
    property Id: Int64 read FId write FId;
    property Name: string read FName write FName;
    property DeletedAt: TDateTime read FDeletedAt write FDeletedAt;
  public
    class procedure Describe(S: TSchema); override;
  end;

  TPvTagList = TModelList<TPvTag>;

  TPvPost = class(TModel)
  private
    FId: Int64;
    FTitle: string;
  published
    Tags: TPvTagList;
    property Id: Int64 read FId write FId;
    property Title: string read FTitle write FTitle;
  public
    class procedure Describe(S: TSchema); override;
  end;

  TPvPostList = TModelList<TPvPost>;

  { The other side. Declared after TPvPost, because a model list can only
    be made of a class that is already complete. }
  TPvTagWithPosts = class(TModel)
  private
    FId: Int64;
    FName: string;
    FDeletedAt: TDateTime;
  published
    Posts: TPvPostList;
    property Id: Int64 read FId write FId;
    property Name: string read FName write FName;
    property DeletedAt: TDateTime read FDeletedAt write FDeletedAt;
  public
    class procedure Describe(S: TSchema); override;
  end;

class procedure TPvTag.Describe(S: TSchema);
begin
  S.Table('pv_tags');
  S.SoftDeletes;
end;

class procedure TPvPost.Describe(S: TSchema);
begin
  S.Table('pv_posts');
  S.BelongsToMany('Tags', TPvTag);
end;

class procedure TPvTagWithPosts.Describe(S: TSchema);
begin
  S.Table('pv_tags');
  S.SoftDeletes;
  S.BelongsToMany('Posts', TPvPost, 'pv_post_pv_tag', 'pv_tag_id', 'pv_post_id');
end;

function PvIds(const Ids: TArray<Int64>): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Ids) do
  begin
    if I > 0 then
      Result := Result + ',';
    Result := Result + IntToStr(Ids[I]);
  end;
end;

function PvNames(L: TPvTagList): string;
var
  I: Integer;
begin
  if L = nil then
    Exit('<not loaded>');
  Result := '';
  for I := 0 to L.Count - 1 do
  begin
    if I > 0 then
      Result := Result + ',';
    Result := Result + L[I].Name;
  end;
end;

procedure PivotPart(C: TDbConnection);
var
  A, PrevA: TArena;
  PrevDb: TDbConnection;
  S: TSchemaBuilder;
  T: TTableBuilder;
  Sql: TStringArray;
  I: Integer;
  Post1, Post2, Post3, Fresh: TPvPost;
  Tag: TPvTag;
  Posts: TPvPostList;
  Tags: TModelList<TPvTagWithPosts>;
  W: TJsonWriter;
  Json, Why: string;
  Refused: Boolean;
begin
  PivotStart('many-to-many through a pivot');
  A := TArena.Create(64 * 1024);
  PrevA := UseArena(A);
  PrevDb := UseDb(C);
  try
    C.Exec(A, 'DROP TABLE IF EXISTS pv_post_pv_tag');
    C.Exec(A, 'DROP TABLE IF EXISTS pv_posts');
    C.Exec(A, 'DROP TABLE IF EXISTS pv_tags');
    S := TSchemaBuilder.Create(C.Dialect);
    try
      T := S.Create('pv_posts');
      T.Id;
      T.Text('title', 80);
      T := S.Create('pv_tags');
      T.Id;
      T.Text('name', 40);
      T.Timestamp('deleted_at').Nullable;
      T := S.Create('pv_post_pv_tag');
      T.ForeignKey('pv_post_id', 'pv_posts');
      T.ForeignKey('pv_tag_id', 'pv_tags');
      T.UniqueIndex(['pv_post_id', 'pv_tag_id']);
      Sql := S.ToSql;
    finally
      S.Free;
    end;
    for I := 0 to High(Sql) do
      C.Exec(A, Sql[I]);

    for I := 1 to 4 do
    begin
      Tag := A.New<TPvTag>;
      Tag.Name := 't' + IntToStr(I);
      Tag.Save;
    end;
    Post1 := A.New<TPvPost>;
    Post1.Title := 'one';
    Post1.Save;
    Post2 := A.New<TPvPost>;
    Post2.Title := 'two';
    Post2.Save;
    Post3 := A.New<TPvPost>;
    Post3.Title := 'three';
    Post3.Save;

    PivotOk('the conventions name the pivot and both keys',
      (TPvPost.Meta.Relations[0].Pivot = 'pv_post_pv_tag') and
      (TPvPost.Meta.Relations[0].ForeignKey = 'pv_post_id') and
      (TPvPost.Meta.Relations[0].PivotRelatedKey = 'pv_tag_id'));

    Post1.Attach('Tags', [1, 2]);
    PivotOk('attach adds the rows', PvIds(Post1.RelatedIds('Tags')) = '1,2');
    Post1.Attach('Tags', [2, 3]);
    PivotOk('attaching one that is there is not a unique violation',
      PvIds(Post1.RelatedIds('Tags')) = '1,2,3');
    Post1.Detach('Tags', [1]);
    PivotOk('detach removes the one given', PvIds(Post1.RelatedIds('Tags')) = '2,3');
    Post1.Detach('Tags', []);
    PivotOk('and an empty list removes nothing', PvIds(Post1.RelatedIds('Tags')) = '2,3');
    Post1.Sync('Tags', [3, 4, 4]);
    PivotOk('sync makes it exactly the ids given, each once',
      PvIds(Post1.RelatedIds('Tags')) = '3,4');
    Post2.Sync('Tags', [1]);
    PivotOk('and only for its own row', PvIds(Post1.RelatedIds('Tags')) = '3,4');

    { All or nothing. 4 goes first and the insert of 999 is refused by
      the foreign key; the rollback has to bring 4 back. }
    Refused := False;
    try
      Post1.Sync('Tags', [3, 999]);
    except
      on E: EDbError do
        Refused := True;
    end;
    PivotOk('an id to nothing is refused by the pivot', Refused);
    PivotOk('and sync leaves the rows as they were',
      PvIds(Post1.RelatedIds('Tags')) = '3,4');

    { A transaction the caller opened is the caller's to end. }
    C.StartTransaction;
    Post1.Sync('Tags', []);
    PivotOk('sync inside a transaction sees its own change',
      PvIds(Post1.RelatedIds('Tags')) = '');
    C.Rollback;
    PivotOk('and does not commit it for the caller',
      PvIds(Post1.RelatedIds('Tags')) = '3,4');

    Fresh := A.New<TPvPost>;
    Why := '';
    try
      Fresh.Attach('Tags', [1]);
    except
      on E: EModelError do
        Why := E.Message;
    end;
    PivotOk('a model that was never saved is refused', Pos('save the', Why) > 0);
    Why := '';
    try
      Post1.Attach('Tags', [0]);
    except
      on E: EModelError do
        Why := E.Message;
    end;
    PivotOk('so is an id of zero', Pos('not the id of a row', Why) > 0);
    Why := '';
    try
      Post1.Sync('Nope', [1]);
    except
      on E: EModelError do
        Why := E.Message;
    end;
    PivotOk('and a relation that is not many-to-many', Pos('no relation', Why) > 0);

    { Preload, one query for the list. }
    Posts := TQuery<TPvPost>.New.Preload(['Tags']).OrderBy(ColInt64('pv_posts', 'id')).Get;
    PivotOk('preload gives each post its tags', PvNames(Posts[0].Tags) = 't3,t4');
    PivotOk('and only its own', PvNames(Posts[1].Tags) = 't1');
    PivotOk('and a post with none an empty list, not nil',
      (Posts[2].Tags <> nil) and (Posts[2].Tags.Count = 0));

    W.Init(A, 512);
    WriteModel(W, Posts[0]);
    Json := W.ToString;
    PivotOk('the tags go out in JSON under the relation''s name',
      (Pos('"tags":[', Json) > 0) and (Pos('"name":"t3"', Json) > 0));
    PivotOk('with no pivot column in them', Pos('askr_pivot_owner', Json) = 0);

    { The other side, with every name given. }
    Tags := TQuery<TPvTagWithPosts>.New.Preload(['Posts']).OrderBy(ColInt64('pv_tags', 'id')).Get;
    PivotOk('the other side loads through the same pivot',
      (Tags[0].Posts.Count = 1) and (Tags[0].Posts[0].Title = 'two') and
      (Tags[2].Posts.Count = 1) and (Tags[2].Posts[0].Title = 'one'));

    { Trashed: not shown, still attached. }
    Tag := TQuery<TPvTag>.New.Find(4);
    Tag.Delete;
    Posts := TQuery<TPvPost>.New.Preload(['Tags']).OrderBy(ColInt64('pv_posts', 'id')).Get;
    PivotOk('a soft-deleted tag is left out of preload', PvNames(Posts[0].Tags) = 't3');
    PivotOk('and is still attached', PvIds(Post1.RelatedIds('Tags')) = '3,4');

    Post1.DetachAll('Tags');
    PivotOk('detach all empties it', PvIds(Post1.RelatedIds('Tags')) = '');
    PivotOk('and nobody else''s', PvIds(Post2.RelatedIds('Tags')) = '1');
  finally
    UseDb(PrevDb);
    UseArena(PrevA);
    A.Free;
  end;
end;
