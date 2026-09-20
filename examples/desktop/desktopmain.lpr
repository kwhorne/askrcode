{ Desktop-skallet. Nøyaktig formen PRD-en skriver.

  Samme App.Routes som webmain.lpr. Forskjellen er denne fila og valget av
  databaseadapter — ingenting annet. }
program DesktopMain;

{$mode Delphi}{$H+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  SysUtils,
  Askr.Urd.Driver, Askr.Urd.Pool, Askr.Urd.Sqlite,
  Askr.Inertia, Askr.Desktop,
  App.Routes;

var
  Rot, Dsn: string;
  C: TDbConnection;
  Pool: TDbPool;
begin
  Rot := GetCurrentDir;
  Dsn := 'sqlite:' + IncludeTrailingPathDelimiter(Rot) + 'notes.db';

  { Tabellen må finnes før første request. En skrivebordsapp har ingen
    migreringskommando brukeren kjører på forhånd. }
  Pool := TDbPool.Create(Dsn, 1);
  try
    C := Pool.Acquire;
    try
      EnsureSchema(C);
    finally
      Pool.Release(C);
    end;
  finally
    Pool.Free;
  end;

  SetPublicDir(IncludeTrailingPathDelimiter(Rot) + 'public');
  TInertia.SetHead(GetEnvironmentVariable('ASKR_HEAD'));

  { Heter DesktopApp og ikke App, fordi App. er navnerommet brukerkoden
    ligger i — se kommentaren i Askr.Desktop. }
  DesktopApp.UseDatabase(Dsn);
  DesktopApp.RegisterRoutes(@RegisterAppRoutes);
  DesktopApp.Window('Notes', 1100, 780);
  DesktopApp.Run;
end.
