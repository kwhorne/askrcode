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

procedure Ok(const What: string; Value_: Boolean);
begin
  if Value_ then
  begin
    Inc(Bestatt);
    WriteLn('  ok    ', What);
  end
  else
  begin
    Inc(Feilet);
    WriteLn('  FEIL  ', What);
  end;
end;

procedure Like(const What, Forventet, Fikk: string);
begin
  if Forventet = Fikk then
  begin
    Inc(Bestatt);
    WriteLn('  ok    ', What);
  end
  else
  begin
    Inc(Feilet);
    WriteLn('  FEIL  ', What);
    WriteLn('        forventet: ', Forventet);
    WriteLn('        fikk:      ', Fikk);
  end;
end;

{ ---- en enkel TCP-klient ---- }

function ConnectTo(Port: Word): TSocket;
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
function HttpsGet(Port: Word; const Path_: string; Verify: Boolean;
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
  Sock := ConnectTo(Port);
  if Sock < 0 then
    raise Exception.Create('fikk ikke koblet til');
  Ctx := TTlsContext.Create(trClient);
  C := nil;
  try
    Ctx.SetVerifyPeer(Verify);
    C := TTlsConn.Create(Ctx, Sock, ServerName);
    Req := 'GET ' + Path_ + ' HTTP/1.1'#13#10 +
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
    FOffersStartTls: Boolean;
    FMottatt: string;
    FKrypterteData: Boolean;
    FErr: string;
    procedure Si(const S: string);
    { False betyr lukket forbindelse. En tom linje er ikke det samme — i
      DATA er den skillet mellom hode og kropp. }
    function Les(out Line_: string): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AOffersStartTls: Boolean);
    destructor Destroy; override;
    property Port: Word read FPort;
    property Mottatt: string read FMottatt;
    { True hvis DATA-innholdet kom inn over TLS og ikke i klartekst. }
    property KrypterteData: Boolean read FKrypterteData;
    property Err: string read FErr;
  end;

constructor TFakeSmtp.Create(AOffersStartTls: Boolean);
var
  Addr: TInetSockAddr;
  Len: TSockLen;
  Ja: Integer;
begin
  FOffersStartTls := AOffersStartTls;
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

function TFakeSmtp.Les(out Line_: string): Boolean;
var
  C: Char;
  N: Integer;
begin
  Line_ := '';
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
      Line_ := Line_ + C;
  until False;
  Result := True;
end;

procedure TFakeSmtp.Execute;
var
  Addr: TInetSockAddr;
  Len: TSockLen;
  Line_: string;
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
      if not Les(Line_) then
        Break;
      if IData then
      begin
        if Line_ = '.' then
        begin
          IData := False;
          Si('250 OK');
        end
        else
          FMottatt := FMottatt + Line_ + #10;
        Continue;
      end;
      if Copy(Line_, 1, 4) = 'EHLO' then
      begin
        Si('250-fake');
        if FOffersStartTls and (FTls = nil) then
          Si('250-STARTTLS');
        Si('250 SIZE 10240000');
      end
      else if Line_ = 'STARTTLS' then
      begin
        Si('220 klar');
        FCtx := TTlsContext.Create(trServer);
        FCtx.UseCertificate(CertDir + 'cert.pem', CertDir + 'key.pem');
        FTls := TTlsConn.Create(FCtx, FSock);
      end
      else if Copy(Line_, 1, 4) = 'MAIL' then
        Si('250 OK')
      else if Copy(Line_, 1, 4) = 'RCPT' then
        Si('250 OK')
      else if Line_ = 'DATA' then
      begin
        Si('354 kom igjen');
        IData := True;
        FKrypterteData := FTls <> nil;
      end
      else if Line_ = 'QUIT' then
      begin
        Si('221 farvel');
        Break;
      end
      else
        Si('250 OK');
    until Terminated;
   except
     on E: Exception do FErr := E.ClassName + ': ' + E.Message;
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
  Message_: string;
begin
  Start('sertifikatfeil');

  Ctx := TTlsContext.Create(trServer);
  try
    Message_ := '';
    try
      Ctx.UseCertificate(CertDir + 'finnesikke.pem', CertDir + 'key.pem');
    except
      on E: Exception do Message_ := E.Message;
    end;
    Ok('manglende fil nevner stien', Pos('finnesikke.pem', Message_) > 0);
  finally
    Ctx.Free;
  end;

  Ctx := TTlsContext.Create(trServer);
  try
    Message_ := '';
    try
      { Sertifikat og nøkkel fra hvert sitt par. OpenSSL oppdager det,
        men bare hvis noen spør — derfor check_private_key i UseCertificate. }
      Ctx.UseCertificate(CertDir + 'cert.pem', CertDir + 'other-key.pem');
    except
      on E: Exception do Message_ := E.Message;
    end;
    Ok('nøkkel som ikke passer avvises ved oppstart', Message_ <> '');
  finally
    Ctx.Free;
  end;
end;

procedure TestHttps;
var
  Srv: TAskrServer;
  Opts: TServerOptions;
  Reply: string;
  Err: string;
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

    Reply := HttpsGet(Srv.BoundPort, '/hei', False);
    Ok('svaret er 200', Pos('200 OK', Reply) > 0);
    Ok('kroppen kom fram', Pos('hallo over tls', Reply) > 0);

    Reply := HttpsGet(Srv.BoundPort, '/borte', False);
    Ok('404 virker også', Pos('404', Reply) > 0);

    { Verifisering påslått mot et selvsignert sertifikat skal feile.
      Without denne testen kunne SetVerifyPeer vært en tom prosedyre. }
    Err := '';
    try
      HttpsGet(Srv.BoundPort, '/hei', True);
    except
      on E: Exception do Err := E.Message;
    end;
    Ok('selvsignert avvises når verifisering er på', Err <> '');

    { Klartekst mot en TLS-port skal ikke gi et HTTP-svar. Poenget er at
      det ikke finnes en stille nedgradering. }
    Sock := ConnectTo(Srv.BoundPort);
    Req := 'GET /hei HTTP/1.1'#13#10'Host: x'#13#10#13#10;
    fpSend(Sock, PChar(Req), Length(Req), 0);
    N := fpRecv(Sock, @Buf[0], SizeOf(Buf), 0);
    Reply := '';
    if N > 0 then
      Reply := Copy(PChar(@Buf[0]), 1, N);
    CloseSocket(Sock);
    Ok('klartekst mot TLS-port gir ikke HTTP', Pos('HTTP/1.1 200', Reply) = 0);

    { Og serveren skal fortsatt leve etterpå. En mislykket klient er ikke
      en grunn til å ta ned en worker. }
    Reply := HttpsGet(Srv.BoundPort, '/hei', False);
    Ok('serveren svarer fortsatt etter et mislykket håndtrykk',
      Pos('hallo over tls', Reply) > 0);
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
  Base, Err: string;
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

    { With_ verifisering på skal et selvsignert sertifikat avvises. }
    Err := '';
    try
      K.Get(Base + '/hei');
    except
      on E: Exception do Err := E.Message;
    end;
    Ok('et selvsignert sertifikat avvises som standard', Err <> '');
    Ok('og meldingen nevner håndtrykket',
      Pos('handshake', LowerCase(Err)) > 0);

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
  Message_: string;
begin
  Start('halvt oppsett');
  Opts := DefaultServerOptions;
  Opts.Host := '127.0.0.1';
  Opts.Port := 0;
  Opts.TlsCertFile := CertDir + 'cert.pem';
  Opts.TlsKeyFile := '';
  Srv := TAskrServer.Create(Opts);
  try
    Message_ := '';
    try
      Srv.Start;
    except
      on E: Exception do Message_ := E.Message;
    end;
    Ok('bare sertifikat uten nøkkel stoppes ved oppstart',
      Pos('only one is set', Message_) > 0);
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
  Message_: string;
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
      Message_ := '';
      try
        T.Send(M);
      except
        on E: Exception do Message_ := E.ClassName + ': ' + E.Message;
      end;
      M.Free;
      if Message_ <> '' then
        WriteLn('        klientfeil: ', Message_);
    finally
      T.Free;
    end;
    Fake.WaitFor;
    if Fake.Err <> '' then
      WriteLn('        serverfeil: ', Fake.Err);
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
      Message_ := '';
      M := TMailMessage.Create;
      M.From('a@example.com').AddTo('b@example.com').Subject('x').Text('y');
      try
        T.Send(M);
      except
        on E: Exception do Message_ := E.Message;
      end;
      M.Free;
      Ok('server uten STARTTLS gir feil', Pos('does not offer STARTTLS', Message_) > 0);
      Ok('feilen sier hva man gjør i stedet', Pos('smtpPlain', Message_) > 0);
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
  Message_: string;
begin
  Start('navneoppslag');
  { localhost står i /etc/hosts overalt. Den skal nå fram til connect og
    feile der — ikke på oppslaget. }
  T := TSmtpTransport.Create('localhost', 1, smtpPlain);
  try
    T.TimeoutMs := 2000;
    Message_ := '';
    M := TMailMessage.Create;
    M.From('a@example.com').AddTo('b@example.com').Subject('x').Text('y');
    try
      T.Send(M);
    except
      on E: Exception do Message_ := E.Message;
    end;
    M.Free;
    if Pos('Could not connect', Message_) = 0 then
      WriteLn('        fikk: ', Message_);
    Ok('localhost slås opp, feiler først på connect',
      Pos('Could not connect', Message_) > 0);
  finally
    T.Free;
  end;

  T := TSmtpTransport.Create('ikke.en.vert.som.finnes.invalid', 25, smtpPlain);
  try
    T.TimeoutMs := 3000;
    Message_ := '';
    M := TMailMessage.Create;
    M.From('a@example.com').AddTo('b@example.com').Subject('x').Text('y');
    try
      T.Send(M);
    except
      on E: Exception do Message_ := E.Message;
    end;
    M.Free;
    Ok('ukjent vert gir en feil som nevner verten',
      Pos('ikke.en.vert.som.finnes.invalid', Message_) > 0);
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
