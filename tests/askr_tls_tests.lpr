{ TLS-tester.

  Disse kjører bare der OpenSSL finnes. På macOS betyr det etter
  brew install openssl@3; uten den hopper suiten over og sier hvorfor,
  i stedet for å melde grønt på noe den ikke har prøvd.

  Sertifikatene ligger i .build/tls og lages av ./askr tls:certs. De er
  selvsignerte og varer et år — de hører hjemme i en testmappe og ingen
  andre steder. }
program askr_tls_tests;

{$mode Delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Sockets, BaseUnix,
  Askr.Core.Arena, Askr.Core.Text,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response, Askr.Http.Server,
  Askr.Tls, Askr.Mail, Askr.Http.Client, Askr.Core.Log;

var
  Bestatt: Integer = 0;
  Feilet: Integer = 0;
  Gruppe: string = '';
  CertDir: string;

procedure Start(const Name: string);
begin
  Gruppe := Name;
  WriteLn;
  WriteLn('— ', Name);
end;

procedure Ok(const Hva: string; Verdi: Boolean);
begin
  if Verdi then
  begin
    Inc(Bestatt);
    WriteLn('  ok    ', Hva);
  end
  else
  begin
    Inc(Feilet);
    WriteLn('  FEIL  ', Hva);
  end;
end;

procedure Like(const Hva, Forventet, Fikk: string);
begin
  if Forventet = Fikk then
  begin
    Inc(Bestatt);
    WriteLn('  ok    ', Hva);
  end
  else
  begin
    Inc(Feilet);
    WriteLn('  FEIL  ', Hva);
    WriteLn('        forventet: ', Forventet);
    WriteLn('        fikk:      ', Fikk);
  end;
end;

{ ---- en enkel TCP-klient ---- }

function KobleTil(Port: Word): TSocket;
var
  Addr: TInetSockAddr;
begin
  Result := fpSocket(AF_INET, SOCK_STREAM, 0);
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := HToNS(Port);
  Addr.sin_addr := StrToNetAddr('127.0.0.1');
  if fpConnect(Result, @Addr, SizeOf(Addr)) <> 0 then
  begin
    CloseSocket(Result);
    Result := -1;
  end;
end;

{ Sender en HTTP-request over TLS og returnerer hele svaret. }
function HttpsGet(Port: Word; const Sti: string; Verify: Boolean;
  const ServerName: string = 'localhost'): string;
var
  Ctx: TTlsContext;
  C: TTlsConn;
  Sock: TSocket;
  Req: string;
  Buf: array[0..4095] of Byte;
  N: Integer;
begin
  Result := '';
  Sock := KobleTil(Port);
  if Sock < 0 then
    raise Exception.Create('fikk ikke koblet til');
  Ctx := TTlsContext.Create(trClient);
  C := nil;
  try
    Ctx.SetVerifyPeer(Verify);
    C := TTlsConn.Create(Ctx, Sock, ServerName);
    Req := 'GET ' + Sti + ' HTTP/1.1'#13#10 +
           'Host: localhost'#13#10'Connection: close'#13#10#13#10;
    C.WriteAll(PChar(Req), Length(Req));
    repeat
      N := C.Read(@Buf[0], SizeOf(Buf));
      if N <= 0 then
        Break;
      Result := Result + Copy(PChar(@Buf[0]), 1, N);
    until False;
  finally
    C.Free;
    Ctx.Free;
    CloseSocket(Sock);
  end;
end;

{ ---- behandler for testserveren ---- }

function Behandler(Req: TRequest): TResponse;
begin
  if Req.Path.Equals(Str('/hei')) then
    Result := RespondText('hallo over tls', 200)
  else
    Result := RespondText('nei', 404);
end;

{ ---- en liten SMTP-server som kan STARTTLS ---- }

type
  TFakeSmtp = class(TThread)
  private
    FListen: TSocket;
    FPort: Word;
    FCtx: TTlsContext;
    FTls: TTlsConn;
    FSock: TSocket;
    FTilbyStartTls: Boolean;
    FMottatt: string;
    FKrypterteData: Boolean;
    FFeil: string;
    procedure Si(const S: string);
    { False betyr lukket forbindelse. En tom linje er ikke det samme — i
      DATA er den skillet mellom hode og kropp. }
    function Les(out Linje: string): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(ATilbyStartTls: Boolean);
    destructor Destroy; override;
    property Port: Word read FPort;
    property Mottatt: string read FMottatt;
    { True hvis DATA-innholdet kom inn over TLS og ikke i klartekst. }
    property KrypterteData: Boolean read FKrypterteData;
    property Feil: string read FFeil;
  end;

constructor TFakeSmtp.Create(ATilbyStartTls: Boolean);
var
  Addr: TInetSockAddr;
  Len: TSockLen;
  Ja: Integer;
begin
  FTilbyStartTls := ATilbyStartTls;
  FSock := -1;
  FListen := fpSocket(AF_INET, SOCK_STREAM, 0);
  Ja := 1;
  fpSetSockOpt(FListen, SOL_SOCKET, SO_REUSEADDR, @Ja, SizeOf(Ja));
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := 0;
  Addr.sin_addr := StrToNetAddr('127.0.0.1');
  fpBind(FListen, @Addr, SizeOf(Addr));
  fpListen(FListen, 4);
  Len := SizeOf(Addr);
  fpGetSockName(FListen, @Addr, @Len);
  FPort := NToHs(Addr.sin_port);
  inherited Create(False);
end;

destructor TFakeSmtp.Destroy;
begin
  if FListen >= 0 then
    CloseSocket(FListen);
  FTls.Free;
  FCtx.Free;
  inherited Destroy;
end;

procedure TFakeSmtp.Si(const S: string);
var
  L: string;
begin
  L := S + #13#10;
  if FTls <> nil then
    FTls.WriteAll(PChar(L), Length(L))
  else
    fpSend(FSock, PChar(L), Length(L), 0);
end;

function TFakeSmtp.Les(out Linje: string): Boolean;
var
  C: Char;
  N: Integer;
begin
  Linje := '';
  repeat
    if FTls <> nil then
      N := FTls.Read(@C, 1)
    else
      N := fpRecv(FSock, @C, 1, 0);
    if N <= 0 then
      Exit(False);
    if C = #10 then
      Break;
    if C <> #13 then
      Linje := Linje + C;
  until False;
  Result := True;
end;

procedure TFakeSmtp.Execute;
var
  Addr: TInetSockAddr;
  Len: TSockLen;
  Linje: string;
  IData: Boolean;
begin
  Len := SizeOf(Addr);
  FSock := fpAccept(FListen, @Addr, @Len);
  if FSock < 0 then
    Exit;
  try
   try
    Si('220 fake ESMTP');
    IData := False;
    repeat
      if not Les(Linje) then
        Break;
      if IData then
      begin
        if Linje = '.' then
        begin
          IData := False;
          Si('250 OK');
        end
        else
          FMottatt := FMottatt + Linje + #10;
        Continue;
      end;
      if Copy(Linje, 1, 4) = 'EHLO' then
      begin
        Si('250-fake');
        if FTilbyStartTls and (FTls = nil) then
          Si('250-STARTTLS');
        Si('250 SIZE 10240000');
      end
      else if Linje = 'STARTTLS' then
      begin
        Si('220 klar');
        FCtx := TTlsContext.Create(trServer);
        FCtx.UseCertificate(CertDir + 'cert.pem', CertDir + 'key.pem');
        FTls := TTlsConn.Create(FCtx, FSock);
      end
      else if Copy(Linje, 1, 4) = 'MAIL' then
        Si('250 OK')
      else if Copy(Linje, 1, 4) = 'RCPT' then
        Si('250 OK')
      else if Linje = 'DATA' then
      begin
        Si('354 kom igjen');
        IData := True;
        FKrypterteData := FTls <> nil;
      end
      else if Linje = 'QUIT' then
      begin
        Si('221 farvel');
        Break;
      end
      else
        Si('250 OK');
    until Terminated;
   except
     on E: Exception do FFeil := E.ClassName + ': ' + E.Message;
   end;
  finally
    CloseSocket(FSock);
    FSock := -1;
  end;
end;

{ ---- testene ---- }

procedure TestBinding;
begin
  Start('binding');
  Ok('OpenSSL lastet', TlsAvailable);
  WriteLn('        ', TlsLibraryName, ' — ', TlsVersion);
  Ok('serverkontekst lar seg lage',
    TTlsContext.Create(trServer).ClassName = 'TTlsContext');
end;

procedure TestSertifikatfeil;
var
  Ctx: TTlsContext;
  Melding: string;
begin
  Start('sertifikatfeil');

  Ctx := TTlsContext.Create(trServer);
  try
    Melding := '';
    try
      Ctx.UseCertificate(CertDir + 'finnesikke.pem', CertDir + 'key.pem');
    except
      on E: Exception do Melding := E.Message;
    end;
    Ok('manglende fil nevner stien', Pos('finnesikke.pem', Melding) > 0);
  finally
    Ctx.Free;
  end;

  Ctx := TTlsContext.Create(trServer);
  try
    Melding := '';
    try
      { Sertifikat og nøkkel fra hvert sitt par. OpenSSL oppdager det,
        men bare hvis noen spør — derfor check_private_key i UseCertificate. }
      Ctx.UseCertificate(CertDir + 'cert.pem', CertDir + 'other-key.pem');
    except
      on E: Exception do Melding := E.Message;
    end;
    Ok('nøkkel som ikke passer avvises ved oppstart', Melding <> '');
  finally
    Ctx.Free;
  end;
end;

procedure TestHttps;
var
  Srv: TAskrServer;
  Opts: TServerOptions;
  Svar: string;
  Feil: string;
  Sock: TSocket;
  Req: string;
  Buf: array[0..255] of Byte;
  N: Integer;
begin
  Start('https');

  Opts := DefaultServerOptions;
  Opts.Host := '127.0.0.1';
  Opts.Port := 0;
  Opts.Workers := 2;
  Opts.TlsCertFile := CertDir + 'cert.pem';
  Opts.TlsKeyFile := CertDir + 'key.pem';

  Srv := TAskrServer.Create(Opts);
  try
    Srv.SetHandler(Behandler);
    Srv.Start;
    Ok('serveren melder at den bruker TLS', Srv.UsesTls);

    Svar := HttpsGet(Srv.BoundPort, '/hei', False);
    Ok('svaret er 200', Pos('200 OK', Svar) > 0);
    Ok('kroppen kom fram', Pos('hallo over tls', Svar) > 0);

    Svar := HttpsGet(Srv.BoundPort, '/borte', False);
    Ok('404 virker også', Pos('404', Svar) > 0);

    { Verifisering påslått mot et selvsignert sertifikat skal feile.
      Uten denne testen kunne SetVerifyPeer vært en tom prosedyre. }
    Feil := '';
    try
      HttpsGet(Srv.BoundPort, '/hei', True);
    except
      on E: Exception do Feil := E.Message;
    end;
    Ok('selvsignert avvises når verifisering er på', Feil <> '');

    { Klartekst mot en TLS-port skal ikke gi et HTTP-svar. Poenget er at
      det ikke finnes en stille nedgradering. }
    Sock := KobleTil(Srv.BoundPort);
    Req := 'GET /hei HTTP/1.1'#13#10'Host: x'#13#10#13#10;
    fpSend(Sock, PChar(Req), Length(Req), 0);
    N := fpRecv(Sock, @Buf[0], SizeOf(Buf), 0);
    Svar := '';
    if N > 0 then
      Svar := Copy(PChar(@Buf[0]), 1, N);
    CloseSocket(Sock);
    Ok('klartekst mot TLS-port gir ikke HTTP', Pos('HTTP/1.1 200', Svar) = 0);

    { Og serveren skal fortsatt leve etterpå. En mislykket klient er ikke
      en grunn til å ta ned en worker. }
    Svar := HttpsGet(Srv.BoundPort, '/hei', False);
    Ok('serveren svarer fortsatt etter et mislykket håndtrykk',
      Pos('hallo over tls', Svar) > 0);
  finally
    Srv.Stop;
    Srv.Free;
  end;
end;

{ Askr.Http.Client mot Askrs egen TLS-server.

  Dette er en bedre prøve enn å ringe et ekte nettsted: den er hermetisk,
  og den tester nettopp sikkerhetsegenskapen. Serveren har et selvsignert
  sertifikat for 127.0.0.1, altså et sertifikat som **skal** avvises av en
  klient som verifiserer. Går den likevel gjennom, er verifiseringen en
  tom prosedyre. }
procedure TestKlientOverTls;
var
  Srv: TAskrServer;
  Opts: TServerOptions;
  K: THttpClient;
  R: THttpResponse;
  Base, Feil: string;
begin
  Start('http-klienten over tls');

  Opts := DefaultServerOptions;
  Opts.Host := '127.0.0.1';
  Opts.Port := 0;
  Opts.Workers := 2;
  Opts.TlsCertFile := CertDir + 'cert.pem';
  Opts.TlsKeyFile := CertDir + 'key.pem';

  Srv := TAskrServer.Create(Opts);
  K := THttpClient.Create;
  try
    Srv.SetHandler(Behandler);
    Srv.Start;
    Base := Format('https://127.0.0.1:%d', [Srv.BoundPort]);

    { Med verifisering på skal et selvsignert sertifikat avvises. }
    Feil := '';
    try
      K.Get(Base + '/hei');
    except
      on E: Exception do Feil := E.Message;
    end;
    Ok('et selvsignert sertifikat avvises som standard', Feil <> '');
    Ok('og meldingen nevner håndtrykket',
      Pos('handshake', LowerCase(Feil)) > 0);

    { Insecure slår det av — og logger en advarsel hver gang. }
    SetLogLevel(llNone);
    K.Insecure := True;
    R := K.Get(Base + '/hei');
    SetLogLevel(llInfo);
    Ok('med Insecure går den gjennom', R.Status = 200);
    Like('og kroppen kom over TLS', 'hallo over tls', Trim(R.Body));

    { Hele klienten skal virke over TLS, ikke bare GET. }
    R := K.Get(Base + '/borte');
    Ok('404 over TLS', R.Status = 404);
  finally
    K.Free;
    Srv.Stop;
    Srv.Free;
  end;
end;

procedure TestServerKrevererBegge;
var
  Srv: TAskrServer;
  Opts: TServerOptions;
  Melding: string;
begin
  Start('halvt oppsett');
  Opts := DefaultServerOptions;
  Opts.Host := '127.0.0.1';
  Opts.Port := 0;
  Opts.TlsCertFile := CertDir + 'cert.pem';
  Opts.TlsKeyFile := '';
  Srv := TAskrServer.Create(Opts);
  try
    Melding := '';
    try
      Srv.Start;
    except
      on E: Exception do Melding := E.Message;
    end;
    Ok('bare sertifikat uten nøkkel stoppes ved oppstart',
      Pos('only one is set', Melding) > 0);
  finally
    Srv.Stop;
    Srv.Free;
  end;
end;

procedure TestSmtpStartTls;
var
  Fake: TFakeSmtp;
  T: TSmtpTransport;
  M: TMailMessage;
  Melding: string;
begin
  Start('smtp starttls');

  Fake := TFakeSmtp.Create(True);
  try
    T := TSmtpTransport.Create('127.0.0.1', Fake.Port, smtpStartTls);
    try
      T.VerifyPeer := False;
      Like('Describe nevner STARTTLS',
        Format('smtp 127.0.0.1:%d (STARTTLS), uverifisert', [Fake.Port]),
        T.Describe);
      M := TMailMessage.Create;
      M.From('avsender@example.com').AddTo('mottaker@example.com')
       .Subject('kryptert').Text('hemmelig innhold');
      Melding := '';
      try
        T.Send(M);
      except
        on E: Exception do Melding := E.ClassName + ': ' + E.Message;
      end;
      M.Free;
      if Melding <> '' then
        WriteLn('        klientfeil: ', Melding);
    finally
      T.Free;
    end;
    Fake.WaitFor;
    if Fake.Feil <> '' then
      WriteLn('        serverfeil: ', Fake.Feil);
    Ok('meldingen kom fram', Pos('hemmelig innhold', Fake.Mottatt) > 0);
    Ok('DATA gikk over TLS, ikke klartekst', Fake.KrypterteData);
    Ok('emnet kom med', Pos('Subject: kryptert', Fake.Mottatt) > 0);
  finally
    Fake.Free;
  end;

  { En server uten STARTTLS skal gi et avbrudd, ikke en stille nedgradering. }
  Fake := TFakeSmtp.Create(False);
  try
    T := TSmtpTransport.Create('127.0.0.1', Fake.Port, smtpStartTls);
    try
      Melding := '';
      M := TMailMessage.Create;
      M.From('a@example.com').AddTo('b@example.com').Subject('x').Text('y');
      try
        T.Send(M);
      except
        on E: Exception do Melding := E.Message;
      end;
      M.Free;
      Ok('server uten STARTTLS gir feil', Pos('does not offer STARTTLS', Melding) > 0);
      Ok('feilen sier hva man gjør i stedet', Pos('smtpPlain', Melding) > 0);
      Ok('ingenting ble sendt i klartekst', Pos('y', Fake.Mottatt) = 0);
    finally
      T.Free;
    end;
  finally
    Fake.Terminate;
    Fake.Free;
  end;
end;

procedure TestSmtpPlain;
var
  Fake: TFakeSmtp;
  T: TSmtpTransport;
  M: TMailMessage;
begin
  Start('smtp uten tls');
  Fake := TFakeSmtp.Create(True);
  try
    T := TSmtpTransport.Create('127.0.0.1', Fake.Port, smtpPlain);
    try
      M := TMailMessage.Create;
      M.From('a@example.com').AddTo('b@example.com')
       .Subject('klartekst').Text('åpent');
      T.Send(M);
      M.Free;
    finally
      T.Free;
    end;
    Fake.WaitFor;
    Ok('smtpPlain sender uten å kreve TLS', Pos('klartekst', Fake.Mottatt) > 0);
    Ok('og den krypterte da ikke', not Fake.KrypterteData);
  finally
    Fake.Free;
  end;
end;

procedure TestNavneoppslag;
var
  T: TSmtpTransport;
  M: TMailMessage;
  Melding: string;
begin
  Start('navneoppslag');
  { localhost står i /etc/hosts overalt. Den skal nå fram til connect og
    feile der — ikke på oppslaget. }
  T := TSmtpTransport.Create('localhost', 1, smtpPlain);
  try
    T.TimeoutMs := 2000;
    Melding := '';
    M := TMailMessage.Create;
    M.From('a@example.com').AddTo('b@example.com').Subject('x').Text('y');
    try
      T.Send(M);
    except
      on E: Exception do Melding := E.Message;
    end;
    M.Free;
    if Pos('Could not connect', Melding) = 0 then
      WriteLn('        fikk: ', Melding);
    Ok('localhost slås opp, feiler først på connect',
      Pos('Could not connect', Melding) > 0);
  finally
    T.Free;
  end;

  T := TSmtpTransport.Create('ikke.en.vert.som.finnes.invalid', 25, smtpPlain);
  try
    T.TimeoutMs := 3000;
    Melding := '';
    M := TMailMessage.Create;
    M.From('a@example.com').AddTo('b@example.com').Subject('x').Text('y');
    try
      T.Send(M);
    except
      on E: Exception do Melding := E.Message;
    end;
    M.Free;
    Ok('ukjent vert gir en feil som nevner verten',
      Pos('ikke.en.vert.som.finnes.invalid', Melding) > 0);
  finally
    T.Free;
  end;
end;

begin
  CertDir := IncludeTrailingPathDelimiter(
    ExpandFileName(ExtractFilePath(ParamStr(0)) + '../tls'));
  if ParamCount >= 1 then
    CertDir := IncludeTrailingPathDelimiter(ParamStr(1));

  WriteLn('askr — TLS');
  WriteLn('sertifikater: ', CertDir);

  if not TlsAvailable then
  begin
    WriteLn;
    WriteLn('HOPPET OVER: OpenSSL er ikke tilgjengelig her.');
    try
      TTlsContext.Create(trServer);
    except
      on E: Exception do WriteLn('  ', E.Message);
    end;
    Halt(0);
  end;

  if not FileExists(CertDir + 'cert.pem') then
  begin
    WriteLn;
    WriteLn('HOPPET OVER: fant ikke ', CertDir, 'cert.pem');
    WriteLn('  Kjør ./askr tls:certs først.');
    Halt(0);
  end;

  TestBinding;
  TestSertifikatfeil;
  TestHttps;
  TestKlientOverTls;
  TestServerKrevererBegge;
  TestSmtpStartTls;
  TestSmtpPlain;
  TestNavneoppslag;

  WriteLn;
  WriteLn('— ', Bestatt, ' bestått, ', Feilet, ' feilet');
  if Feilet > 0 then
    Halt(1);
end.
