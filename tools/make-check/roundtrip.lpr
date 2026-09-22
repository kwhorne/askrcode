{ The round trip `./askr make:check` puts into a scaffolded project.

  Every type `askr make model` accepts, saved through the model it
  generated and read back through the same model, against whichever
  database DATABASE_URL names. The gate runs it against all three.

  A migration that runs proves the DDL is valid. It does not prove that
  what goes in comes out -- that a bool survives MySQL's tinyint, that
  money keeps its decimals, that a date is still the same date. That is
  what this is for, and why it goes through the generated model rather
  than through SQL: the model is the thing a user will actually use. }
program app_tests;

{$mode Delphi}{$H+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  SysUtils, DateUtils,
  Askr.Core.Arena, Askr.Core.Env, Askr.Core.Config,
  Askr.Urd.Driver, Askr.Urd.Sqlite, Askr.Urd.Pg, Askr.Urd.MySql,
  Askr.Urd.Model, Askr.Urd.Query,
  App.Models.Maker, App.Models.Gadget;

var
  Fails: Integer = 0;

procedure Check(Cond: Boolean; const What: string; const Got: string = '');
begin
  if Cond then
    WriteLn('  ok    ', What)
  else
  begin
    WriteLn('  FAIL  ', What);
    if Got <> '' then
      WriteLn('        got: ', Got);
    Inc(Fails);
  end;
end;

(* JSON compared without its whitespace. MySQL hands a JSON column back
   normalised -- {"k": 1} for {"k":1} -- which is the same document. A
   byte comparison would call that a lost value. In the star form because
   a brace inside a brace comment opens another one. *)
function Squeeze(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    if not (S[I] in [' ', #9, #10, #13]) then
      Result := Result + S[I];
end;

function NullCount(C: TDbConnection; A: TArena; const Column: string): Int64;
var
  R: TDbResult;
begin
  R := C.Exec(A, 'SELECT count(*) FROM gadgets WHERE ' + Column + ' IS NULL');
  Result := R.AsInt64(0, 0);
end;

var
  A: TArena;
  C: TDbConnection;
  M: TMaker;
  G, Back, Bare, BareBack: TGadget;
  Seen, Born: TDateTime;
  Dsn: string;
begin
  LoadEnvUpwards;
  LoadConfig(GetCurrentDir);
  Dsn := Cfg('database.url', '');
  WriteLn('- ', Copy(Dsn, 1, Pos(':', Dsn) - 1));

  A := TArena.Create(64 * 1024);
  UseArena(A);
  C := OpenDbConnection(Dsn);
  UseDb(C);
  try
    M := A.New<TMaker>;
    M.Name := 'Acme';
    M.Save;
    Check(M.Id > 0, 'a parent row is made');

    Seen := EncodeDateTime(2026, 9, 22, 13, 5, 7, 0);
    Born := EncodeDate(1990, 1, 2);

    G := A.New<TGadget>;
    { utf8mb4 and a four-byte character, on purpose. MySQL's "utf8" is not
      UTF-8, and this is the row that would find out. }
    G.Name := 'Blåbærsyltetøy 🫐';
    G.Notes := 'A longer text, which is a TEXT and has no length.';
    G.Qty := 42;
    G.Big := 9000000001;
    G.Active := True;
    G.Price := 1234.5;
    G.Ratio := 0.25;
    G.SeenAt := Seen;
    G.Born := Born;
    G.Meta := '{"k":1,"list":[1,2]}';
    G.Tag := '6f1c2a0e-8b7d-4c3e-9a51-2d4f6e8a0b1c';
    G.MakerId := M.Id;
    Check(G.Validate, 'a full row validates');
    G.Save;
    Check(G.Id > 0, 'and is saved');

    Back := TQuery<TGadget>.New.Find(G.Id);
    Check(Back <> nil, 'and is found again');
    if Back = nil then
      Halt(1);

    Check(Back.Name = G.Name, 'string, with a four-byte character in it', Back.Name);
    Check(Back.Notes = G.Notes, 'text', Back.Notes);
    Check(Back.Qty = 42, 'int', IntToStr(Back.Qty));
    Check(Back.Big = 9000000001, 'bigint, past 32 bits', IntToStr(Back.Big));
    Check(Back.Active, 'bool');
    Check(Back.Price = 1234.5, 'money, with its decimals', CurrToStr(Back.Price));
    Check(Back.Ratio = 0.25, 'float', FloatToStr(Back.Ratio));
    Check(SecondsBetween(Back.SeenAt, Seen) = 0, 'datetime, to the second',
      DateTimeToStr(Back.SeenAt));
    Check(Trunc(Back.Born) = Trunc(Born), 'date', DateToStr(Back.Born));
    Check(Squeeze(Back.Meta) = Squeeze(G.Meta), 'json', Back.Meta);
    Check(LowerCase(Back.Tag) = G.Tag, 'uuid', Back.Tag);
    Check(Back.MakerId = M.Id, 'a reference', IntToStr(Back.MakerId));
    Check(Back.CreatedAt > 0, 'and the timestamps were set by the model');

    { The nullable ones left alone. They go in as NULL and come back as
      nothing, not as a date in 1899 or a zero that means something. }
    Bare := A.New<TGadget>;
    Bare.Name := 'Bare';
    Bare.Born := Born;
    Bare.MakerId := M.Id;
    Bare.Save;
    BareBack := TQuery<TGadget>.New.Find(Bare.Id);
    Check((BareBack <> nil) and (BareBack.Notes = ''), 'a nullable text left out');
    Check((BareBack <> nil) and (BareBack.SeenAt = 0),
      'a nullable datetime left out is nothing, not 1899');
    Check((BareBack <> nil) and (BareBack.Tag = ''), 'a nullable uuid left out');

    { **And they are NULL in the database, not ''.** The three checks above
      pass either way -- NULL and '' both read back as '' -- so they do not
      show what a `?` in the spec is for. This asks the database. }
    Check(NullCount(C, A, 'notes') = 1, 'a nullable text left out is NULL');
    Check(NullCount(C, A, 'meta') = 1, 'so is a nullable json');
    Check(NullCount(C, A, 'tag') = 1, 'and a nullable uuid');
    Check(NullCount(C, A, 'seen_at') = 1, 'and a nullable datetime');

    { The rules the spec stated, and only those. }
    Bare := A.New<TGadget>;
    Check(not Bare.Validate, 'an empty row does not validate');
    Check(Bare.Errors.Has('name'), 'name is required, because it is NOT NULL text');
    Check(Bare.Errors.Has('born'),
      'born is required -- a zero date would be NULL, and NOT NULL refuses it');
    Check(not Bare.Errors.Has('qty'), 'qty is not: zero is a number');
    Check(not Bare.Errors.Has('active'), 'nor active: false is a value');
    Check(Bare.Errors.Has('maker_id'), 'and a reference to nothing is refused');

    Bare.Name := StringOfChar('x', 61);
    Bare.Validate;
    Check(Bare.Errors.Has('name'), 'string(60) means sixty and no more');
  finally
    UseDb(nil);
    C.Free;
  end;

  if Fails > 0 then
  begin
    WriteLn(Fails, ' failed.');
    Halt(1);
  end;
end.
