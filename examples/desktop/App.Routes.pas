{ App.Routes — appen. Verken web- eller desktop-skallet rører denne fila.

  Dette er PRD-ens påstand gjort etterprøvbar: modeller, kontroller og
  rutingstabell ligger her, og de to skallene er tynne. webmain.lpr starter
  en HTTP-server; desktopmain.lpr starter den samme tabellen mot en lokal
  port og peker systemets webview dit.

  Databasen er SQLite, som er det desktop faktisk vil bruke. Den samme koden
  kjører mot Postgres ved å bytte DSN — driverabstraksjonen ligger under. }
unit App.Routes;

{$mode Delphi}{$H+}

interface

uses
  SysUtils,
  Askr.Core.Arena, Askr.Core.Text,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response,
  Askr.Http.Router, Askr.Http.Static,
  Askr.Urd.Driver, Askr.Urd.Model, Askr.Urd.Query, Askr.Urd.Bind,
  Askr.Inertia;

type
  TNote = class(TModel)
  private
    FId: Int64;
    FTittel: string;
    FTekst: string;
    FViktig: Boolean;
  published
    property Id: Int64 read FId write FId;
    property Tittel: string read FTittel write FTittel;
    property Tekst: string read FTekst write FTekst;
    property Viktig: Boolean read FViktig write FViktig;
  public
    class procedure Describe(S: TSchema); override;
    procedure Rules(V: TValidator); override;
  end;

  TNoteList = TModelList<TNote>;

  TNotesController = class
  public
    function Index(Req: TRequest): TResponse;
    function Store(Req: TRequest): TResponse;
    function Toggle(Req: TRequest): TResponse;
    function Destroy_(Req: TRequest): TResponse;
  end;

{ Kalles av begge skallene, og av ingen andre. }
procedure RegisterAppRoutes(R: TRouter);
{ Oppretter tabellen hvis den ikke finnes. Desktop har ingen egen
  migreringskommando å kjøre først. }
procedure EnsureSchema(C: TDbConnection);
procedure SetPublicDir(const ADir: string);

var
  Notes: record
    Id: TColInt64;
    Tittel: TColStr;
    Viktig: TColBool;
  end;

implementation

uses
  Askr.Norn.Schema;

class procedure TNote.Describe(S: TSchema);
begin
  S.Table('notes');
end;

procedure TNote.Rules(V: TValidator);
begin
  V.Field('Tittel').Required.MaxLen(120);
  V.Field('Tekst').MaxLen(2000);
end;

procedure EnsureSchema(C: TDbConnection);
var
  S: TSchemaBuilder;
  Stmts: TStringArray;
  A: TArena;
  I: Integer;
begin
  A := TArena.Create(8192);
  S := TSchemaBuilder.Create(C.Dialect);
  try
    with S.Create('notes') do
    begin
      IfNotExists := True;
      Id;
      Text('tittel', 120);
      Text('tekst');
      Bool('viktig').Default(False);
      Timestamps;
    end;
    Stmts := S.ToSql;
    for I := 0 to High(Stmts) do
      C.Exec(A, Stmts[I]);
  finally
    S.Free;
    A.Free;
  end;
end;

function AlleNotater(A: TArena): TNoteList;
begin
  Result := TQuery<TNote>.New.OrderBy(Notes.Id, Desc).Get;
end;

function TNotesController.Index(Req: TRequest): TResponse;
var
  Liste: TNoteList;
begin
  Liste := AlleNotater(Req.Arena);
  Result := Inertia('Notes/Index',
    ['notes', Liste,
     'total', Int64(Liste.Count),
     'skall', GetEnvironmentVariable('ASKR_SHELL')]);
end;

function TNotesController.Store(Req: TRequest): TResponse;
var
  N: TNote;
  Liste: TNoteList;
begin
  N := Req.Arena.New<TNote>;
  Req.FillInto(N);

  if not N.Validate then
  begin
    Liste := AlleNotater(Req.Arena);
    Exit(Inertia('Notes/Index',
      ['notes', Liste, 'total', Int64(Liste.Count),
       'errors', N.Errors, 'sendt', N,
       'skall', GetEnvironmentVariable('ASKR_SHELL')]));
  end;

  N.Save;
  InertiaFlash('suksess', 'Lagret «' + N.Tittel + '»');
  Result := Index(Req);
end;

function TNotesController.Toggle(Req: TRequest): TResponse;
var
  N: TNote;
begin
  N := TQuery<TNote>.New.Find(Req.IntParam('id'));
  if N <> nil then
  begin
    N.Viktig := not N.Viktig;
    N.Save;
  end;
  Result := Index(Req);
end;

function TNotesController.Destroy_(Req: TRequest): TResponse;
var
  N: TNote;
begin
  N := TQuery<TNote>.New.Find(Req.IntParam('id'));
  if N <> nil then
  begin
    N.Delete;
    InertiaFlash('suksess', 'Slettet');
  end;
  Result := Index(Req);
end;

var
  GCtrl: TNotesController;
  GStatisk: TStaticFiles;
  GPublicDir: string = 'public';

procedure SetPublicDir(const ADir: string);
begin
  GPublicDir := ADir;
end;

procedure RegisterAppRoutes(R: TRouter);
begin
  Notes.Id := ColInt64('notes', 'id');
  Notes.Tittel := ColStr('notes', 'tittel');
  Notes.Viktig := ColBool('notes', 'viktig');

  GCtrl := TNotesController.Create;
  GStatisk := TStaticFiles.Create(GPublicDir);
  GStatisk.MaxAge := 31536000;

  R.Use(GStatisk.Serve);
  R.Get('/', GCtrl.Index);                      R.AsName('notes.index');
  R.Post('/notes', GCtrl.Store);                R.AsName('notes.store');
  R.Post('/notes/:id/toggle', GCtrl.Toggle);    R.AsName('notes.toggle');
  R.Post('/notes/:id/delete', GCtrl.Destroy_);  R.AsName('notes.destroy');
end;

finalization
  GCtrl.Free;
  GStatisk.Free;

end.
