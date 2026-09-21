{ The desktop shell. Exactly the shape the PRD writes.

  The same App.Routes as webmain.lpr. The difference is this file and the
  choice of database adapter — nothing else. }
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
  Root, Dsn: string;
  C: TDbConnection;
  Pool: TDbPool;
begin
  Root := GetCurrentDir;
  Dsn := 'sqlite:' + IncludeTrailingPathDelimiter(Root) + 'notes.db';

  { The table has to exist before the first request. A desktop app has no
    migration command the user runs beforehand. }
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

  SetPublicDir(IncludeTrailingPathDelimiter(Root) + 'public');
  TInertia.SetHead(GetEnvironmentVariable('ASKR_HEAD'));

  { It is called DesktopApp and not App, because App. is the namespace
    user code lives in — see the comment in Askr.Desktop. }
  DesktopApp.UseDatabase(Dsn);
  DesktopApp.RegisterRoutes(@RegisterAppRoutes);
  DesktopApp.Window('Notes', 1100, 780);
  DesktopApp.Run;
end.
