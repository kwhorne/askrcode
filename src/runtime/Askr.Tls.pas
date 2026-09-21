{ Askr.Tls — TLS over OpenSSL.

  Én binding, to brukere: HTTPS i web-skallet og STARTTLS i e-posten. De
  hører sammen, og det er grunnen til at ingen av dem fikk en halvveis
  variant før denne fantes.

  Biblioteket lastes med dlopen, som libpq og libsqlite3, av samme grunn:
  binæren skal starte på en maskin uten OpenSSL. En app som bare snakker
  HTTP bak en reverse proxy trenger den aldri.

  **macOS trenger en OpenSSL brukeren installerer.** Systemets libssl er
  LibreSSL, og Apple blokkerer dlopen mot den fra tredjeparts binærer —
  forsøket gir «loading libcrypto in an unsafe way» og prosessen dør. Det er
  ikke noe Askr kan omgå. Feilmeldingen sier hvilke stier som ble forsøkt,
  og Homebrews openssl@3 er blant dem.

  Linux virker rett ut av boksen: libssl.so.3 ligger der allerede.

  API-et er bevisst lite. Alt som ikke trengs for en server-socket og en
  klient-socket er utelatt — en tynn binding man kan lese er tryggere enn en
  fullstendig man ikke kan. }
unit Askr.Tls;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, DynLibs, Sockets, BaseUnix;

type
  ETlsError = class(Exception);
  ETlsUnavailable = class(ETlsError);

  TTlsRole = (trServer, trClient);

  TTlsContext = class
  private
    FCtx: Pointer;
    FRole: TTlsRole;
  public
    constructor Create(ARole: TTlsRole);
    destructor Destroy; override;
    { PEM-filer. Kjedet sertifikat i den første. }
    procedure UseCertificate(const CertFile, KeyFile: string);
    { Verifiser motpartens sertifikat mot systemets rotlager. På av
      standard for klienter; en klient som ikke verifiserer er en klient
      som later som den har TLS. }
    procedure SetVerifyPeer(Verify: Boolean);
    property Handle: Pointer read FCtx;
    property Role: TTlsRole read FRole;
  end;

  TTlsConn = class
  private
    FSsl: Pointer;
    FSock: TSocket;
    FClosed: Boolean;
  public
    { Overtar ikke eierskap til socketen. }
    constructor Create(Ctx: TTlsContext; ASock: TSocket;
      const ServerName: string = '');
    destructor Destroy; override;

    { Returnerer antall bytes, 0 ved ryddig lukking, -1 ved feil. }
    function Read(Buf: Pointer; Len: Integer): Integer;
    function Write(Buf: Pointer; Len: Integer): Integer;
    { Skriver alt eller returnerer False. }
    function WriteAll(Buf: Pointer; Len: Integer): Boolean;
    procedure Shutdown;

    function PeerVerified: Boolean;
    property Socket: TSocket read FSock;
  end;

{ True når OpenSSL lot seg laste. Kaster ikke. }
function TlsAvailable: Boolean;
function TlsLibraryName: string;
function TlsVersion: string;
{ Siste feil fra OpenSSL, tømt fra feilkøen. }
function TlsLastError: string;

implementation

uses
  SyncObjs;

const
  SSL_ERROR_NONE = 0;
  SSL_ERROR_SSL = 1;
  SSL_ERROR_WANT_READ = 2;
  SSL_ERROR_WANT_WRITE = 3;
  SSL_ERROR_ZERO_RETURN = 6;
  SSL_ERROR_SYSCALL = 5;

  SSL_FILETYPE_PEM = 1;
  SSL_VERIFY_NONE = 0;
  SSL_VERIFY_PEER = 1;

  { SSL_CTX_set_min_proto_version er en makro over SSL_CTX_ctrl. }
  SSL_CTRL_SET_MIN_PROTO_VERSION = 123;
  SSL_CTRL_SET_TLSEXT_HOSTNAME = 55;
  TLSEXT_NAMETYPE_host_name = 0;
  TLS1_2_VERSION = $0303;

  X509_V_OK = 0;

type
  Tmethod = function: Pointer; cdecl;
  TCTX_new = function(M: Pointer): Pointer; cdecl;
  TCTX_free = procedure(C: Pointer); cdecl;
  TCTX_use_cert = function(C: Pointer; F: PAnsiChar): Integer; cdecl;
  TCTX_use_key = function(C: Pointer; F: PAnsiChar; T: Integer): Integer; cdecl;
  TCTX_check_key = function(C: Pointer): Integer; cdecl;
  TCTX_ctrl = function(C: Pointer; Cmd: Integer; Larg: LongInt;
    Parg: Pointer): LongInt; cdecl;
  TCTX_set_verify = procedure(C: Pointer; Mode: Integer; Cb: Pointer); cdecl;
  TCTX_verify_paths = function(C: Pointer): Integer; cdecl;
  TSSL_new = function(C: Pointer): Pointer; cdecl;
  TSSL_free = procedure(S: Pointer); cdecl;
  TSSL_set_fd = function(S: Pointer; Fd: Integer): Integer; cdecl;
  TSSL_accept = function(S: Pointer): Integer; cdecl;
  TSSL_connect = function(S: Pointer): Integer; cdecl;
  TSSL_read = function(S: Pointer; Buf: Pointer; Num: Integer): Integer; cdecl;
  TSSL_write = function(S: Pointer; Buf: Pointer; Num: Integer): Integer; cdecl;
  TSSL_shutdown = function(S: Pointer): Integer; cdecl;
  TSSL_get_error = function(S: Pointer; Ret: Integer): Integer; cdecl;
  TSSL_ctrl = function(S: Pointer; Cmd: Integer; Larg: LongInt;
    Parg: Pointer): LongInt; cdecl;
  TSSL_get_verify_result = function(S: Pointer): LongInt; cdecl;
  { SSL_set1_host finnes fra OpenSSL 1.1.0. Without den sjekker
    SSL_VERIFY_PEER bare at kjeden er gyldig — ikke at sertifikatet
    gjelder verten vi snakker med. Et gyldig sertifikat for et hvilket
    som helst domene ville passert. }
  TSSL_set1_host = function(S: Pointer; H: PAnsiChar): LongInt; cdecl;
  TERR_get_error = function: QWord; cdecl;
  TERR_error_string_n = procedure(E: QWord; Buf: PAnsiChar; Len: PtrUInt); cdecl;
  TOpenSSL_version = function(T: Integer): PAnsiChar; cdecl;

var
  TLS_server_method: Tmethod;
  TLS_client_method: Tmethod;
  SSL_CTX_new: TCTX_new;
  SSL_CTX_free: TCTX_free;
  SSL_CTX_use_certificate_chain_file: TCTX_use_cert;
  SSL_CTX_use_PrivateKey_file: TCTX_use_key;
  SSL_CTX_check_private_key: TCTX_check_key;
  SSL_CTX_ctrl: TCTX_ctrl;
  SSL_CTX_set_verify: TCTX_set_verify;
  SSL_CTX_set_default_verify_paths: TCTX_verify_paths;
  SSL_new: TSSL_new;
  SSL_free: TSSL_free;
  SSL_set_fd: TSSL_set_fd;
  SSL_accept: TSSL_accept;
  SSL_connect: TSSL_connect;
  SSL_read: TSSL_read;
  SSL_write: TSSL_write;
  SSL_shutdown: TSSL_shutdown;
  SSL_get_error: TSSL_get_error;
  SSL_ctrl: TSSL_ctrl;
  SSL_get_verify_result: TSSL_get_verify_result;
  SSL_set1_host: TSSL_set1_host;
  ERR_get_error: TERR_get_error;
  ERR_error_string_n: TERR_error_string_n;
  OpenSSL_version: TOpenSSL_version;

  GSsl: TLibHandle = NilHandle;
  GCrypto: TLibHandle = NilHandle;
  GName: string = '';
  GTried: Boolean = False;
  GError: string = '';
  GLock: TCriticalSection;

function SslCandidates: TStringArray;
begin
{$IFDEF DARWIN}
  { Systemets libssl er LibreSSL, og Apple blokkerer dlopen mot den.
    Derfor bare stier brukeren selv kan ha installert. }
  Result := [
    '/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib',
    '/usr/local/opt/openssl@3/lib/libssl.3.dylib',
    '/opt/homebrew/lib/libssl.3.dylib',
    '/usr/local/lib/libssl.3.dylib'
  ];
{$ELSE}
{$IFDEF WINDOWS}
  Result := ['libssl-3-x64.dll', 'libssl-1_1-x64.dll'];
{$ELSE}
  Result := ['libssl.so.3', 'libssl.so.1.1', 'libssl.so'];
{$ENDIF}
{$ENDIF}
end;

function CryptoFor(const SslPath: string): string;
begin
  { libcrypto ligger ved siden av libssl og må lastes først, ellers finner
    ikke dynamisk linking symbolene. }
  Result := StringReplace(SslPath, 'libssl', 'libcrypto', [rfReplaceAll]);
end;

function Need(const AName: string): Pointer;
begin
  Result := GetProcedureAddress(GSsl, AName);
  if Result = nil then
    raise ETlsUnavailable.CreateFmt(
      'OpenSSL was loaded from %s but is missing %s. ' +
      'The version is probably too old; 1.1 or newer is required.',
      [GName, AName]);
end;

procedure EnsureLoaded;
var
  Names: TStringArray;
  I: Integer;
  Tried: string;
begin
  if GSsl <> NilHandle then
    Exit;
  GLock.Acquire;
  try
    if GSsl <> NilHandle then
      Exit;
    if GTried then
      raise ETlsUnavailable.Create(GError);
    GTried := True;

    Names := SslCandidates;
    Tried := '';
    for I := 0 to High(Names) do
    begin
      GCrypto := LoadLibrary(CryptoFor(Names[I]));
      GSsl := LoadLibrary(Names[I]);
      if GSsl <> NilHandle then
      begin
        GName := Names[I];
        Break;
      end;
      if Tried <> '' then
        Tried := Tried + ', ';
      Tried := Tried + Names[I];
    end;

    if GSsl = NilHandle then
    begin
      GError := 'Could not find OpenSSL. Tried: ' + Tried + '.';
{$IFDEF DARWIN}
      GError := GError + ' On macOS you have to install OpenSSL yourself — ' +
        'the system libssl is LibreSSL, and Apple blocks dlopen against it. ' +
        'brew install openssl@3 fixes it.';
{$ENDIF}
      raise ETlsUnavailable.Create(GError);
    end;

    try
      TLS_server_method := Tmethod(Need('TLS_server_method'));
      TLS_client_method := Tmethod(Need('TLS_client_method'));
      SSL_CTX_new := TCTX_new(Need('SSL_CTX_new'));
      SSL_CTX_free := TCTX_free(Need('SSL_CTX_free'));
      SSL_CTX_use_certificate_chain_file :=
        TCTX_use_cert(Need('SSL_CTX_use_certificate_chain_file'));
      SSL_CTX_use_PrivateKey_file :=
        TCTX_use_key(Need('SSL_CTX_use_PrivateKey_file'));
      SSL_CTX_check_private_key :=
        TCTX_check_key(Need('SSL_CTX_check_private_key'));
      SSL_CTX_ctrl := TCTX_ctrl(Need('SSL_CTX_ctrl'));
      SSL_CTX_set_verify := TCTX_set_verify(Need('SSL_CTX_set_verify'));
      SSL_CTX_set_default_verify_paths :=
        TCTX_verify_paths(Need('SSL_CTX_set_default_verify_paths'));
      SSL_new := TSSL_new(Need('SSL_new'));
      SSL_free := TSSL_free(Need('SSL_free'));
      SSL_set_fd := TSSL_set_fd(Need('SSL_set_fd'));
      SSL_accept := TSSL_accept(Need('SSL_accept'));
      SSL_connect := TSSL_connect(Need('SSL_connect'));
      SSL_read := TSSL_read(Need('SSL_read'));
      SSL_write := TSSL_write(Need('SSL_write'));
      SSL_shutdown := TSSL_shutdown(Need('SSL_shutdown'));
      SSL_get_error := TSSL_get_error(Need('SSL_get_error'));
      SSL_ctrl := TSSL_ctrl(Need('SSL_ctrl'));
      SSL_get_verify_result :=
        TSSL_get_verify_result(Need('SSL_get_verify_result'));
      SSL_set1_host := TSSL_set1_host(Need('SSL_set1_host'));
      ERR_get_error := TERR_get_error(Need('ERR_get_error'));
      ERR_error_string_n := TERR_error_string_n(Need('ERR_error_string_n'));
      OpenSSL_version := TOpenSSL_version(
        GetProcedureAddress(GSsl, 'OpenSSL_version'));
    except
      on E: Exception do
      begin
        UnloadLibrary(GSsl);
        GSsl := NilHandle;
        GError := E.Message;
        raise;
      end;
    end;
  finally
    GLock.Release;
  end;
end;

function TlsAvailable: Boolean;
begin
  try
    EnsureLoaded;
    Result := True;
  except
    Result := False;
  end;
end;

function TlsLibraryName: string;
begin
  Result := GName;
end;

function TlsVersion: string;
begin
  EnsureLoaded;
  if Assigned(OpenSSL_version) then
    Result := string(OpenSSL_version(0))
  else
    Result := '(unknown)';
end;

function TlsLastError: string;
var
  E: QWord;
  Buf: array[0..255] of AnsiChar;
begin
  Result := '';
  if not Assigned(ERR_get_error) then
    Exit;
  repeat
    E := ERR_get_error;
    if E = 0 then
      Break;
    ERR_error_string_n(E, @Buf[0], SizeOf(Buf));
    if Result <> '' then
      Result := Result + '; ';
    Result := Result + string(PAnsiChar(@Buf[0]));
  until False;
end;

{ TTlsContext }

constructor TTlsContext.Create(ARole: TTlsRole);
var
  M: Pointer;
begin
  inherited Create;
  EnsureLoaded;
  FRole := ARole;
  if ARole = trServer then
    M := TLS_server_method()
  else
    M := TLS_client_method();
  FCtx := SSL_CTX_new(M);
  if FCtx = nil then
    raise ETlsError.Create('SSL_CTX_new failed: ' + TlsLastError);

  { TLS 1.0 og 1.1 er avviklet. Å tillate dem er å tilby et nedgraderingsmål
    ingen har bruk for. }
  SSL_CTX_ctrl(FCtx, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, nil);

  if ARole = trClient then
  begin
    SSL_CTX_set_default_verify_paths(FCtx);
    SSL_CTX_set_verify(FCtx, SSL_VERIFY_PEER, nil);
  end;
end;

destructor TTlsContext.Destroy;
begin
  if FCtx <> nil then
  begin
    SSL_CTX_free(FCtx);
    FCtx := nil;
  end;
  inherited Destroy;
end;

procedure TTlsContext.UseCertificate(const CertFile, KeyFile: string);
begin
  if not FileExists(CertFile) then
    raise ETlsError.CreateFmt('Could not find the certificate: %s', [CertFile]);
  if not FileExists(KeyFile) then
    raise ETlsError.CreateFmt('Could not find the key: %s', [KeyFile]);

  if SSL_CTX_use_certificate_chain_file(FCtx,
     PAnsiChar(AnsiString(CertFile))) <> 1 then
    raise ETlsError.CreateFmt('Could not read the certificate %s: %s',
      [CertFile, TlsLastError]);
  if SSL_CTX_use_PrivateKey_file(FCtx, PAnsiChar(AnsiString(KeyFile)),
     SSL_FILETYPE_PEM) <> 1 then
    raise ETlsError.CreateFmt('Could not read the key %s: %s',
      [KeyFile, TlsLastError]);
  { Sjekker at nøkkelen hører til sertifikatet. Without dette feiler første
    håndtrykk i stedet for oppstarten, og feilen blir mye vanskeligere. }
  if SSL_CTX_check_private_key(FCtx) <> 1 then
    raise ETlsError.Create('The key does not match the certificate');
end;

procedure TTlsContext.SetVerifyPeer(Verify: Boolean);
begin
  if Verify then
  begin
    SSL_CTX_set_default_verify_paths(FCtx);
    SSL_CTX_set_verify(FCtx, SSL_VERIFY_PEER, nil);
  end
  else
    SSL_CTX_set_verify(FCtx, SSL_VERIFY_NONE, nil);
end;

{ TTlsConn }

constructor TTlsConn.Create(Ctx: TTlsContext; ASock: TSocket;
  const ServerName: string);
var
  Rc, Err: Integer;
begin
  inherited Create;
  FSock := ASock;
  FSsl := SSL_new(Ctx.Handle);
  if FSsl = nil then
    raise ETlsError.Create('SSL_new failed: ' + TlsLastError);
  if SSL_set_fd(FSsl, FSock) <> 1 then
  begin
    SSL_free(FSsl);
    FSsl := nil;
    raise ETlsError.Create('SSL_set_fd failed: ' + TlsLastError);
  end;

  if (Ctx.Role = trClient) and (ServerName <> '') then
  begin
    { SNI. Without dette får man feil sertifikat fra enhver vert som har flere. }
    SSL_ctrl(FSsl, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name,
      PAnsiChar(AnsiString(ServerName)));
    { Og navnesjekken. SNI sier hvilket sertifikat vi vil ha; denne sier at
      det vi fikk faktisk gjelder verten. SSL_VERIFY_PEER alene sjekker bare
      at kjeden er gyldig — et ekte sertifikat for et annet domene ville
      passert, og det er hele man-in-the-middle-angrepet. }
    if SSL_set1_host(FSsl, PAnsiChar(AnsiString(ServerName))) <> 1 then
    begin
      SSL_free(FSsl);
      FSsl := nil;
      raise ETlsError.CreateFmt(
        'Could not set the expected certificate host name "%s"',
        [ServerName]);
    end;
  end;

  repeat
    if Ctx.Role = trServer then
      Rc := SSL_accept(FSsl)
    else
      Rc := SSL_connect(FSsl);
    if Rc = 1 then
      Break;
    Err := SSL_get_error(FSsl, Rc);
    { Socketen er blokkerende, men WANT_READ kan likevel oppstå ved
      renegotiering. Da er det bare å prøve igjen. }
    if (Err <> SSL_ERROR_WANT_READ) and (Err <> SSL_ERROR_WANT_WRITE) then
    begin
      SSL_free(FSsl);
      FSsl := nil;
      raise ETlsError.CreateFmt('The TLS handshake failed (%d): %s',
        [Err, TlsLastError]);
    end;
  until False;
end;

destructor TTlsConn.Destroy;
begin
  if FSsl <> nil then
  begin
    if not FClosed then
      SSL_shutdown(FSsl);
    SSL_free(FSsl);
    FSsl := nil;
  end;
  inherited Destroy;
end;

function TTlsConn.Read(Buf: Pointer; Len: Integer): Integer;
var
  Err: Integer;
begin
  repeat
    Result := SSL_read(FSsl, Buf, Len);
    if Result > 0 then
      Exit;
    Err := SSL_get_error(FSsl, Result);
    case Err of
      SSL_ERROR_ZERO_RETURN:
        begin
          FClosed := True;
          Exit(0);
        end;
      SSL_ERROR_WANT_READ, SSL_ERROR_WANT_WRITE:
        Continue;
      SSL_ERROR_SYSCALL:
        begin
          if fpGetErrno = ESysEINTR then
            Continue;
          Exit(-1);
        end;
    else
      Exit(-1);
    end;
  until False;
end;

function TTlsConn.Write(Buf: Pointer; Len: Integer): Integer;
var
  Err: Integer;
begin
  repeat
    Result := SSL_write(FSsl, Buf, Len);
    if Result > 0 then
      Exit;
    Err := SSL_get_error(FSsl, Result);
    case Err of
      SSL_ERROR_WANT_READ, SSL_ERROR_WANT_WRITE:
        Continue;
      SSL_ERROR_SYSCALL:
        begin
          if fpGetErrno = ESysEINTR then
            Continue;
          Exit(-1);
        end;
    else
      Exit(-1);
    end;
  until False;
end;

function TTlsConn.WriteAll(Buf: Pointer; Len: Integer): Boolean;
var
  Sent, N: Integer;
begin
  Sent := 0;
  while Sent < Len do
  begin
    N := Write(PByte(Buf) + Sent, Len - Sent);
    if N <= 0 then
      Exit(False);
    Inc(Sent, N);
  end;
  Result := True;
end;

procedure TTlsConn.Shutdown;
begin
  if (FSsl <> nil) and not FClosed then
  begin
    SSL_shutdown(FSsl);
    FClosed := True;
  end;
end;

function TTlsConn.PeerVerified: Boolean;
begin
  Result := SSL_get_verify_result(FSsl) = X509_V_OK;
end;

initialization
  GLock := TCriticalSection.Create;

finalization
  if GSsl <> NilHandle then
    UnloadLibrary(GSsl);
  if GCrypto <> NilHandle then
    UnloadLibrary(GCrypto);
  GLock.Free;

end.
