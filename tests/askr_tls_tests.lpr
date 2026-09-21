{ TLS tests.

  These run only where OpenSSL exists. On macOS that means after
  brew install openssl@3; without it the suite skips and says why, rather
  than reporting green on something it has not tried.

  The certificates live in .build/tls and are made by ./askr tls:certs.
  They are self-signed and last a year — they belong in a test directory
  and nowhere else. }
program askr_tls_tests;

{$mode Delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Sockets, BaseUnix,
  Askr.Core.Arena, Askr.Core.Text,
  Askr.Http.Types, Askr.Http.Request, Askr.Http.Response, Askr.Http.Server,
  Askr.Tls, Askr.Mail, Askr.Http.Client, Askr.Core.Log;

var
  Passed: Integer = 0;
  Failed: Integer = 0;
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
    Inc(Passed);
    WriteLn('  ok    ', What);
  end
  else
  begin
    Inc(Failed);
    WriteLn('  FEIL  ', What);
  end;
end;

procedure Like(const What, Expected, Got: string);
begin
  if Expected = Got then
  begin
    Inc(Passed);
    WriteLn('  ok    ', What);
  end
  else
  begin
    Inc(Failed);
    WriteLn('  FEIL  ', What);
    WriteLn('        forventet: ', Expected);
    WriteLn('        fikk:      ', Got);
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
    raise Exception.Create('could not connect');
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
    Result := RespondText('hello over tls', 200)
  else
    Result := RespondText('nei', 404);
end;

{ ---- a small SMTP server that can do STARTTLS ---- }

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
    { False means a closed connection. An empty line is not the same — in
      DATA it is the separator between the head and the body. }
    function Read_(out Line_: string): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AOffersStartTls: Boolean);
    destructor Destroy; override;
    property Port: Word read FPort;
    property Mottatt: string read FMottatt;
    { True if the DATA content came in over TLS and not in the clear. }
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

function TFakeSmtp.Read_(out Line_: string): Boolean;
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
      if not Read_(Line_) then
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
        Si('354 go ahead');
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
  Ok('a server context can be made',
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
      { A certificate and a key from two different pairs. OpenSSL notices,
        but only if somebody asks — hence check_private_key in
        UseCertificate. }
      Ctx.UseCertificate(CertDir + 'cert.pem', CertDir + 'other-key.pem');
    except
      on E: Exception do Message_ := E.Message;
    end;
    Ok('a key that does not match is rejected at start-up', Message_ <> '');
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
    Ok('the server reports that it uses TLS', Srv.UsesTls);

    Reply := HttpsGet(Srv.BoundPort, '/hei', False);
    Ok('the reply is 200', Pos('200 OK', Reply) > 0);
    Ok('the body arrived', Pos('hello over tls', Reply) > 0);

    Reply := HttpsGet(Srv.BoundPort, '/borte', False);
    Ok('404 works too', Pos('404', Reply) > 0);

    { Verification switched on against a self-signed certificate is to
      fail. Without this test SetVerifyPeer could have been an empty
      procedure. }
    Err := '';
    try
      HttpsGet(Srv.BoundPort, '/hei', True);
    except
      on E: Exception do Err := E.Message;
    end;
    Ok('self-signed is rejected when verification is on', Err <> '');

    { Plaintext against a TLS port must not give an HTTP reply. The point
      is that there is no silent downgrade. }
    Sock := ConnectTo(Srv.BoundPort);
    Req := 'GET /hei HTTP/1.1'#13#10'Host: x'#13#10#13#10;
    fpSend(Sock, PChar(Req), Length(Req), 0);
    N := fpRecv(Sock, @Buf[0], SizeOf(Buf), 0);
    Reply := '';
    if N > 0 then
      Reply := Copy(PChar(@Buf[0]), 1, N);
    CloseSocket(Sock);
    Ok('plaintext against a TLS port gives no HTTP', Pos('HTTP/1.1 200', Reply) = 0);

    { And the server is to still be alive afterwards. A client that fails
      is not a reason to take down a worker. }
    Reply := HttpsGet(Srv.BoundPort, '/hei', False);
    Ok('the server still answers after a failed handshake',
      Pos('hello over tls', Reply) > 0);
  finally
    Srv.Stop;
    Srv.Free;
  end;
end;

{ Askr.Http.Client against Askr's own TLS server.

  This is a better trial than calling a real website: it is hermetic, and
  it tests precisely the security property. The server has a self-signed
  certificate for 127.0.0.1 — that is, a certificate that **must** be
  rejected by a client that verifies. If it goes through anyway, the
  verification is an empty procedure. }
procedure TestKlientOverTls;
var
  Srv: TAskrServer;
  Opts: TServerOptions;
  K: THttpClient;
  R: THttpResponse;
  Base, Err: string;
begin
  Start('the http client over tls');

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

    { With verification on, a self-signed certificate is to be
      rejected. }
    Err := '';
    try
      K.Get(Base + '/hei');
    except
      on E: Exception do Err := E.Message;
    end;
    Ok('a self-signed certificate is rejected by default', Err <> '');
    Ok('and the message mentions the handshake',
      Pos('handshake', LowerCase(Err)) > 0);

    { Insecure turns it off — and logs a warning every time. }
    SetLogLevel(llNone);
    K.Insecure := True;
    R := K.Get(Base + '/hei');
    SetLogLevel(llInfo);
    Ok('with Insecure it goes through', R.Status = 200);
    Like('and the body came over TLS', 'hello over tls', Trim(R.Body));

    { The whole client is to work over TLS, not only GET. }
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
    Ok('a certificate without a key is stopped at start-up',
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
    Ok('the message arrived', Pos('hemmelig innhold', Fake.Mottatt) > 0);
    Ok('DATA went over TLS, not in the clear', Fake.KrypterteData);
    Ok('the subject came along', Pos('Subject: kryptert', Fake.Mottatt) > 0);
  finally
    Fake.Free;
  end;

  { A server without STARTTLS is to give an abort, not a silent
    downgrade. }
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
      Ok('a server without STARTTLS raises', Pos('does not offer STARTTLS', Message_) > 0);
      Ok('the error says what to do instead', Pos('smtpPlain', Message_) > 0);
      Ok('nothing was sent in the clear', Pos('y', Fake.Mottatt) = 0);
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
  Start('smtp without tls');
  Fake := TFakeSmtp.Create(True);
  try
    T := TSmtpTransport.Create('127.0.0.1', Fake.Port, smtpPlain);
    try
      M := TMailMessage.Create;
      M.From('a@example.com').AddTo('b@example.com')
       .Subject('klartekst').Text('open');
      T.Send(M);
      M.Free;
    finally
      T.Free;
    end;
    Fake.WaitFor;
    Ok('smtpPlain sends without requiring TLS', Pos('klartekst', Fake.Mottatt) > 0);
    Ok('and it did not encrypt', not Fake.KrypterteData);
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
  { localhost is in /etc/hosts everywhere. It is to reach connect and
    fail there — not at the lookup. }
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
    Ok('localhost resolves, fails first at connect',
      Pos('Could not connect', Message_) > 0);
  finally
    T.Free;
  end;

  T := TSmtpTransport.Create('not.a.host.that.exists.invalid', 25, smtpPlain);
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
    Ok('an unknown host gives an error naming the host',
      Pos('not.a.host.that.exists.invalid', Message_) > 0);
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
    WriteLn('SKIPPED: OpenSSL is not available here.');
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
    WriteLn('SKIPPED: could not find ', CertDir, 'cert.pem');
    WriteLn('  Run ./askr tls:certs first.');
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
  WriteLn('— ', Passed, ' passed, ', Failed, ' failed');
  if Failed > 0 then
    Halt(1);
end.
