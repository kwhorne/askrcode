{ Askr.Mail — e-post, med transporter man kan bytte.

  En melding bygges likt uansett hvor den havner. Transporten avgjør hva som
  faktisk skjer: i utvikling skrives den til en fil eller til terminalen, i
  produksjon går den over SMTP.

  SMTP-transporten krever STARTTLS som standard. Vil man ha klartekst — mot
  en relé på loopback, eller mot Mailpit i utvikling — sier man smtpPlain.
  Det er den veien rundt med vilje: et oppsett som stille faller tilbake til
  klartekst når serveren ikke tilbyr kryptering, er verre enn et som stopper
  og sier fra.

  TLS forutsetter at OpenSSL finnes på maskinen. Se Askr.Tls; på macOS må den
  installeres selv.

  Køen er det naturlige stedet å sende fra: SMTP er tregt, og en request skal
  ikke vente på en fremmed server. }
unit Askr.Mail;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, Sockets, BaseUnix,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Clock, netdb, Askr.Tls;

type
  EMailError = class(Exception);

  TMailAddress = record
    Address: string;
    Name_: string;
  end;

  TMailMessage = class
  private
    FFrom: TMailAddress;
    FTo: array of TMailAddress;
    FCc: array of TMailAddress;
    FBcc: array of TMailAddress;
    FSubject: string;
    FText: string;
    FHtml: string;
    FHeaders: TStringList;
    FMessageId: string;
    function Recipients: TStringArray;
  public
    constructor Create;
    destructor Destroy; override;

    function From(const AAddress: string;
      const AName: string = ''): TMailMessage;
    function AddTo(const AAddress: string;
      const AName: string = ''): TMailMessage;
    function Cc(const AAddress: string;
      const AName: string = ''): TMailMessage;
    function Bcc(const AAddress: string;
      const AName: string = ''): TMailMessage;
    function Subject(const S: string): TMailMessage;
    function Text(const S: string): TMailMessage;
    function Html(const S: string): TMailMessage;
    function Header(const Name_, Value: string): TMailMessage;

    { Hele meldingen som RFC 5322-tekst. Bcc utelates fra hodet, men er med
      i mottakerlista — det er hele poenget med Bcc. }
    function Render: string;
    property AllRecipients: TStringArray read Recipients;
    property Sender: TMailAddress read FFrom;
  end;

  TMailTransport = class
  public
    procedure Send(M: TMailMessage); virtual; abstract;
    function Describe: string; virtual; abstract;
  end;

  { Skriver meldingen til en fil, eller til stdout hvis stien er tom.
    Standardvalget i utvikling: ingenting sendes, alt kan leses. }
  TLogTransport = class(TMailTransport)
  private
    FPath: string;
    FCount: Integer;
  public
    constructor Create(const APath: string = '');
    procedure Send(M: TMailMessage); override;
    function Describe: string; override;
    property Count: Integer read FCount;
  end;

  { Forkaster alt. Finnes for tester som ikke vil ha bivirkninger. }
  TNullTransport = class(TMailTransport)
  private
    FCount: Integer;
    FLast: string;
  public
    procedure Send(M: TMailMessage); override;
    function Describe: string; override;
    property Count: Integer read FCount;
    property LastMessage: string read FLast;
  end;

  { Hvordan forbindelsen sikres.

    smtpStartTls er standard fordi det er det riktige svaret i nesten alle
    tilfeller, og fordi et opplegg som stille faller tilbake til klartekst
    er verre enn et som sier fra. Vil man ha klartekst, sier man det. }
  TSmtpSecurity = (
    { Ingen kryptering. Til en lokal relé på loopback, og ikke ellers. }
    smtpPlain,
    { Krev STARTTLS. Tilbyr ikke serveren det, avbrytes sendingen. }
    smtpStartTls,
    { TLS fra første byte, uten klartekstfase. Vanligvis port 465. }
    smtpTlsDirect);

  TSmtpTransport = class(TMailTransport)
  private
    FHost: string;
    FPort: Word;
    FTimeoutMs: Integer;
    FSock: TSocket;
    FSecurity: TSmtpSecurity;
    FVerifyPeer: Boolean;
    FCtx: TTlsContext;
    FTls: TTlsConn;
    FEhlo: string;
    function ReadLine: string;
    function Expect(const Code: string): string;
    procedure SendLine(const S: string);
    procedure Connect;
    procedure StartTls;
    { EHLO og oppsamling av det serveren svarer at den kan. }
    procedure Greet;
    function Offers(const Capability: string): Boolean;
  public
    constructor Create(const AHost: string; APort: Word = 25;
      ASecurity: TSmtpSecurity = smtpStartTls);
    destructor Destroy; override;
    procedure Send(M: TMailMessage); override;
    function Describe: string; override;
    property TimeoutMs: Integer read FTimeoutMs write FTimeoutMs;
    { Av bare til selvsignerte sertifikater i test. En klient som ikke
      verifiserer har kryptering, men ingen visshet om hvem den snakker med. }
    property VerifyPeer: Boolean read FVerifyPeer write FVerifyPeer;
    property Security: TSmtpSecurity read FSecurity;
  end;

  TMailer = class
  private
    FTransport: TMailTransport;
    FOwnsTransport: Boolean;
    FDefaultFrom: TMailAddress;
    FSent: QWord;
  public
    constructor Create(ATransport: TMailTransport; AOwns: Boolean = True);
    destructor Destroy; override;
    function Message_: TMailMessage;
    procedure Send(M: TMailMessage; FreeAfter: Boolean = True);
    procedure SetDefaultFrom(const AAddress, AName: string);
    property Transport: TMailTransport read FTransport;
    property Sent: QWord read FSent;
  end;

function Mail: TMailer;
procedure SetMail(AMailer: TMailer);

implementation

var
  GMailer: TMailer = nil;

function Mail: TMailer;
begin
  if GMailer = nil then
    raise EMailError.Create('No mailer is configured. Call SetMail at startup.');
  Result := GMailer;
end;

procedure SetMail(AMailer: TMailer);
begin
  GMailer := AMailer;
end;

function Fold(const A: TMailAddress): string;
begin
  if A.Name_ = '' then
    Result := A.Address
  else
    { Navnet siteres alltid. Et komma i et navn uten anførselstegn deler
      adressefeltet i to, og da får feil person e-posten. }
    Result := '"' + StringReplace(A.Name_, '"', '''', [rfReplaceAll]) +
      '" <' + A.Address + '>';
end;

function FoldList(const L: array of TMailAddress): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(L) do
  begin
    if I > 0 then
      Result := Result + ', ';
    Result := Result + Fold(L[I]);
  end;
end;

{ TMailMessage }

constructor TMailMessage.Create;
begin
  inherited Create;
  FHeaders := TStringList.Create;
end;

destructor TMailMessage.Destroy;
begin
  FHeaders.Free;
  inherited Destroy;
end;

function TMailMessage.From(const AAddress, AName: string): TMailMessage;
begin
  FFrom.Address := AAddress;
  FFrom.Name_ := AName;
  Result := Self;
end;

function TMailMessage.AddTo(const AAddress, AName: string): TMailMessage;
var
  I: Integer;
begin
  I := Length(FTo);
  SetLength(FTo, I + 1);
  FTo[I].Address := AAddress;
  FTo[I].Name_ := AName;
  Result := Self;
end;

function TMailMessage.Cc(const AAddress, AName: string): TMailMessage;
var
  I: Integer;
begin
  I := Length(FCc);
  SetLength(FCc, I + 1);
  FCc[I].Address := AAddress;
  FCc[I].Name_ := AName;
  Result := Self;
end;

function TMailMessage.Bcc(const AAddress, AName: string): TMailMessage;
var
  I: Integer;
begin
  I := Length(FBcc);
  SetLength(FBcc, I + 1);
  FBcc[I].Address := AAddress;
  FBcc[I].Name_ := AName;
  Result := Self;
end;

function TMailMessage.Subject(const S: string): TMailMessage;
begin
  FSubject := S;
  Result := Self;
end;

function TMailMessage.Text(const S: string): TMailMessage;
begin
  FText := S;
  Result := Self;
end;

function TMailMessage.Html(const S: string): TMailMessage;
begin
  FHtml := S;
  Result := Self;
end;

function TMailMessage.Header(const Name_, Value: string): TMailMessage;
begin
  FHeaders.Values[Name_] := Value;
  Result := Self;
end;

function TMailMessage.Recipients: TStringArray;
var
  I, N: Integer;
begin
  Result := nil;
  N := Length(FTo) + Length(FCc) + Length(FBcc);
  SetLength(Result, N);
  N := 0;
  for I := 0 to High(FTo) do begin Result[N] := FTo[I].Address; Inc(N); end;
  for I := 0 to High(FCc) do begin Result[N] := FCc[I].Address; Inc(N); end;
  for I := 0 to High(FBcc) do begin Result[N] := FBcc[I].Address; Inc(N); end;
end;

{ Kodet som quoted-printable ville vært riktigere, men 8bit med UTF-8 er
  akseptert av alt som er i bruk, og det holder teksten lesbar i loggen. }
function TMailMessage.Render: string;
var
  A: TArena;
  B: TStrBuilder;
  Grense: string;
  I: Integer;
begin
  if FFrom.Address = '' then
    raise EMailError.Create('Meldingen mangler avsender');
  if Length(FTo) + Length(FCc) + Length(FBcc) = 0 then
    raise EMailError.Create('The message has no recipients');

  if FMessageId = '' then
    FMessageId := Format('<%d.%d@askr>', [UnixNow, Random(1000000)]);

  A := TArena.Create(16 * 1024);
  try
    B.Init(A, 4096);
    B.Append('From: ' + Fold(FFrom) + #13#10);
    if Length(FTo) > 0 then
      B.Append('To: ' + FoldList(FTo) + #13#10);
    if Length(FCc) > 0 then
      B.Append('Cc: ' + FoldList(FCc) + #13#10);
    B.Append('Subject: ' + FSubject + #13#10);
    B.Append('Date: ');
    AppendHttpDateNow(B);
    B.Append(#13#10);
    B.Append('Message-ID: ' + FMessageId + #13#10);
    B.Append('MIME-Version: 1.0'#13#10);
    for I := 0 to FHeaders.Count - 1 do
      B.Append(FHeaders.Names[I] + ': ' +
        FHeaders.ValueFromIndex[I] + #13#10);

    if (FHtml <> '') and (FText <> '') then
    begin
      Grense := Format('askr-%d-%d', [UnixNow, Random(1000000)]);
      B.Append('Content-Type: multipart/alternative; boundary="' +
        Grense + '"'#13#10#13#10);
      B.Append('--' + Grense + #13#10);
      B.Append('Content-Type: text/plain; charset=utf-8'#13#10);
      B.Append('Content-Transfer-Encoding: 8bit'#13#10#13#10);
      B.Append(FText + #13#10#13#10);
      B.Append('--' + Grense + #13#10);
      B.Append('Content-Type: text/html; charset=utf-8'#13#10);
      B.Append('Content-Transfer-Encoding: 8bit'#13#10#13#10);
      B.Append(FHtml + #13#10#13#10);
      B.Append('--' + Grense + '--'#13#10);
    end
    else if FHtml <> '' then
    begin
      B.Append('Content-Type: text/html; charset=utf-8'#13#10);
      B.Append('Content-Transfer-Encoding: 8bit'#13#10#13#10);
      B.Append(FHtml);
    end
    else
    begin
      B.Append('Content-Type: text/plain; charset=utf-8'#13#10);
      B.Append('Content-Transfer-Encoding: 8bit'#13#10#13#10);
      B.Append(FText);
    end;
    Result := B.ToString;
  finally
    A.Free;
  end;
end;

{ TLogTransport }

constructor TLogTransport.Create(const APath: string);
begin
  inherited Create;
  FPath := APath;
end;

procedure TLogTransport.Send(M: TMailMessage);
var
  L: TStringList;
  Tekst: string;
begin
  Tekst := '=== ' + FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) +
    ' ===' + LineEnding + M.Render + LineEnding;
  Inc(FCount);
  if FPath = '' then
  begin
    Write(Tekst);
    Exit;
  end;
  { Katalogen lages. En loggtransport som feiler fordi storage/ ikke
    finnes er ubrukelig akkurat der den skal hjelpe — første gang noen
    prøver en passordtilbakestilling i utvikling. }
  ForceDirectories(ExtractFilePath(ExpandFileName(FPath)));
  L := TStringList.Create;
  try
    if FileExists(FPath) then
      L.LoadFromFile(FPath);
    L.Add(Tekst);
    L.SaveToFile(FPath);
  finally
    L.Free;
  end;
end;

function TLogTransport.Describe: string;
begin
  if FPath = '' then
    Result := 'log (stdout)'
  else
    Result := 'log (' + FPath + ')';
end;

{ TNullTransport }

procedure TNullTransport.Send(M: TMailMessage);
begin
  FLast := M.Render;
  Inc(FCount);
end;

function TNullTransport.Describe: string;
begin
  Result := 'null';
end;

{ TSmtpTransport }

constructor TSmtpTransport.Create(const AHost: string; APort: Word;
  ASecurity: TSmtpSecurity);
begin
  inherited Create;
  FHost := AHost;
  FPort := APort;
  FTimeoutMs := 15000;
  FSock := -1;
  FSecurity := ASecurity;
  FVerifyPeer := True;
end;

destructor TSmtpTransport.Destroy;
begin
  FreeAndNil(FTls);
  FreeAndNil(FCtx);
  inherited Destroy;
end;

function TSmtpTransport.Describe: string;
const
  Navn: array[TSmtpSecurity] of string =
    ('uten TLS', 'STARTTLS', 'TLS');
begin
  Result := Format('smtp %s:%d (%s)', [FHost, FPort, Navn[FSecurity]]);
  if (FSecurity <> smtpPlain) and not FVerifyPeer then
    Result := Result + ', uverifisert';
end;

procedure TSmtpTransport.SendLine(const S: string);
var
  Linje: string;
begin
  Linje := S + #13#10;
  if FTls <> nil then
  begin
    if not FTls.WriteAll(PChar(Linje), Length(Linje)) then
      raise EMailError.Create('SMTP: writing over TLS failed');
  end
  else
    fpSend(FSock, PChar(Linje), Length(Linje), 0);
end;

function TSmtpTransport.ReadLine: string;
var
  C: Char;
  N: ssize_t;
begin
  Result := '';
  repeat
    if FTls <> nil then
      N := FTls.Read(@C, 1)
    else
      N := fpRecv(FSock, @C, 1, 0);
    if N <= 0 then
      raise EMailError.Create('The SMTP connection closed');
    if C = #10 then
      Break;
    if C <> #13 then
      Result := Result + C;
  until False;
end;

function TSmtpTransport.Expect(const Code: string): string;
var
  Alle: string;
begin
  { Flerlinjes svar: «250-noe» fortsetter, «250 noe» avslutter. }
  Alle := '';
  repeat
    Result := ReadLine;
    if Copy(Result, 1, 3) <> Code then
      raise EMailError.CreateFmt('SMTP expected %s, got: %s', [Code, Result]);
    Alle := Alle + Result + #10;
  until (Length(Result) < 4) or (Result[4] <> '-');
  { Hele svaret tas vare på, ikke bare siste linje: det er i de foregående
    linjene serveren lister hva den kan, STARTTLS iberegnet. }
  FEhlo := Alle;
end;

function TSmtpTransport.Offers(const Capability: string): Boolean;
begin
  { Linjene ser ut som «250-STARTTLS». Et enkelt delstrengsøk ville også
    truffet «250-SIZE 35651584» hvis noen het SIZE; derfor krever vi at
    navnet står rett etter koden og skilletegnet. }
  Result := (Pos(#10'250-' + Capability, #10 + FEhlo) > 0) or
            (Pos(#10'250 ' + Capability, #10 + FEhlo) > 0);
end;

procedure TSmtpTransport.Greet;
begin
  SendLine('EHLO askr');
  Expect('250');
end;

procedure TSmtpTransport.StartTls;
begin
  if FCtx = nil then
  begin
    FCtx := TTlsContext.Create(trClient);
    FCtx.SetVerifyPeer(FVerifyPeer);
  end;
  { Vertsnavnet går med som SNI. Er FHost en IP-adresse, hopper vi over
    det — SNI med IP er ikke lov, og servere som får det svarer surt. }
  if StrToNetAddr(FHost).s_addr <> 0 then
    FTls := TTlsConn.Create(FCtx, FSock)
  else
    FTls := TTlsConn.Create(FCtx, FSock, FHost);
end;

procedure TSmtpTransport.Connect;
var
  Addr: TInetSockAddr;
  TV: TTimeVal;
  Vert: THostEntry;
begin
  FSock := fpSocket(AF_INET, SOCK_STREAM, 0);
  if FSock < 0 then
    raise EMailError.Create('Could not create a socket');

  TV.tv_sec := FTimeoutMs div 1000;
  TV.tv_usec := (FTimeoutMs mod 1000) * 1000;
  fpSetSockOpt(FSock, SOL_SOCKET, SO_RCVTIMEO, @TV, SizeOf(TV));
  fpSetSockOpt(FSock, SOL_SOCKET, SO_SNDTIMEO, @TV, SizeOf(TV));

  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := HToNS(FPort);
  Addr.sin_addr := StrToNetAddr(FHost);
  if Addr.sin_addr.s_addr = 0 then
  begin
    { To oppslag, i den rekkefølgen systemet selv bruker: først /etc/hosts,
      så DNS. netdb deler dem i to funksjoner som returnerer adressen i hver
      sin byteorden — GetHostByName i vertens, ResolveHostByName i nettets.
      Å bomme på det gir en adresse som ser gyldig ut og peker feil vei. }
    if GetHostByName(FHost, Vert) then
      Addr.sin_addr.s_addr := HToNL(Vert.Addr.s_addr)
    else if ResolveHostByName(FHost, Vert) then
      Addr.sin_addr := Vert.Addr
    else
      raise EMailError.CreateFmt(
        'Could not resolve the SMTP host %s', [FHost]);
  end;
  if fpConnect(FSock, @Addr, SizeOf(Addr)) <> 0 then
    raise EMailError.CreateFmt('Could not connect to %s:%d', [FHost, FPort]);
end;

procedure TSmtpTransport.Send(M: TMailMessage);
var
  Mottakere: TStringArray;
  I: Integer;
  Body: string;
begin
  Connect;
  try
    if FSecurity = smtpTlsDirect then
      { Ingen klartekstfase i det hele tatt: håndtrykket først, så 220. }
      StartTls;

    Expect('220');
    Greet;

    if FSecurity = smtpStartTls then
    begin
      if not Offers('STARTTLS') then
        raise EMailError.CreateFmt(
          '%s:%d does not offer STARTTLS. Pass smtpPlain to the constructor ' +
          'if plain text is really what you want.', [FHost, FPort]);
      SendLine('STARTTLS');
      Expect('220');
      StartTls;
      { RFC 3207: alt serveren sa før håndtrykket er ubeskyttet og skal
        glemmes. Derfor ny EHLO. }
      Greet;
    end;

    SendLine('MAIL FROM:<' + M.Sender.Address + '>');
    Expect('250');

    Mottakere := M.AllRecipients;
    for I := 0 to High(Mottakere) do
    begin
      SendLine('RCPT TO:<' + Mottakere[I] + '>');
      Expect('250');
    end;

    SendLine('DATA');
    Expect('354');
    Body := M.Render;
    { En linje som bare er et punktum avslutter DATA. En slik linje i
      innholdet må dobles, ellers kuttes meldingen der. }
    Body := StringReplace(Body, #13#10'.'#13#10, #13#10'..'#13#10,
      [rfReplaceAll]);
    SendLine(Body);
    SendLine('.');
    Expect('250');

    SendLine('QUIT');
  finally
    if FTls <> nil then
    begin
      FTls.Shutdown;
      FreeAndNil(FTls);
    end;
    CloseSocket(FSock);
    FSock := -1;
  end;
end;

{ TMailer }

constructor TMailer.Create(ATransport: TMailTransport; AOwns: Boolean);
begin
  inherited Create;
  if ATransport = nil then
    raise EMailError.Create('Mailer without a transport');
  FTransport := ATransport;
  FOwnsTransport := AOwns;
end;

destructor TMailer.Destroy;
begin
  if FOwnsTransport then
    FTransport.Free;
  inherited Destroy;
end;

procedure TMailer.SetDefaultFrom(const AAddress, AName: string);
begin
  FDefaultFrom.Address := AAddress;
  FDefaultFrom.Name_ := AName;
end;

function TMailer.Message_: TMailMessage;
begin
  Result := TMailMessage.Create;
  if FDefaultFrom.Address <> '' then
    Result.From(FDefaultFrom.Address, FDefaultFrom.Name_);
end;

procedure TMailer.Send(M: TMailMessage; FreeAfter: Boolean);
begin
  try
    FTransport.Send(M);
    Inc(FSent);
  finally
    if FreeAfter then
      M.Free;
  end;
end;

initialization
  Randomize;

end.
