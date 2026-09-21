{ Askr.Http.Multipart — `multipart/form-data`, altså skjemaer med filer.

  Parseren kopierer ingenting. Kroppen ligger allerede sammenhengende i
  workerens lesebuffer, og hver del blir et `TStr`-utsnitt inn i det samme
  bufferet. En opplasting på fem megabyte koster derfor fem megabyte én
  gang — i bufferet som uansett måtte lese dem — og ikke en kopi til i
  arenaen. Det er den samme modellen som resten av request-parsingen.

  **Taket er `MaxBodyBytes`** (8 MB som standard, satt i `TServerOptions`).
  Hele opplastingen må få plass i minnet på én gang. Det holder for skjemaer
  med vedlegg, profilbilder og CSV-import, og det holder ikke for video.
  Å laste opp noe som ikke får plass i minnet krever at kroppen strømmes til
  disk mens den leses, og det er en annen form enn «kroppen er ett utsnitt» —
  den ville måttet endres i `TWorker`, ikke her.

  **Filnavnet fra klienten er ikke til å stole på.** Det er en tekst en
  angriper skriver, og den klassiske feilen er å skjøte den rett på en
  katalogsti: `../../etc/passwd` eller en fil som heter `.bashrc`. Derfor
  har `TUploadedFile` både `SafeName`, som rydder navnet, og `StoreIn`, som
  ikke bruker klientens navn i det hele tatt. `SaveAs` skriver dit du sier,
  og da er stien ditt ansvar. }
unit Askr.Http.Multipart;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, Askr.Core.Arena, Askr.Core.Text;

const
  { Grenser mot en kropp som er liten, men skadelig: tusenvis av bittesmå
    deler koster parsing og allokering uten å bryte MaxBodyBytes. }
  MaxMultipartParts = 512;
  MaxPartHeaderBytes = 16 * 1024;

type
  TMultipartError = (
    mpOk,
    mpNoBoundary,       { Content-Type mangler boundary= }
    mpMalformed,        { grensene står ikke der de skal }
    mpTooManyParts
  );

  { Én fil fra skjemaet. Innholdet peker inn i requestens lesebuffer og er
    gyldig så lenge requesten er det — ikke lenger. Skal den overleve, må
    den lagres eller kopieres. }
  TUploadedFile = record
    FieldName: TStr;
    { Nøyaktig det klienten sendte. Ikke bruk den som filnavn. }
    ClientName: TStr;
    { Klientens Content-Type. Også en påstand fra klienten, ikke en måling:
      en .exe kan meldes som image/png. Skal typen være til å stole på, må
      innholdet sjekkes. }
    ContentType: TStr;
    Content: TStr;

    function IsEmpty: Boolean;
    function Size: SizeInt;
    { Klientnavnet uten katalogdeler og uten tegn som betyr noe for et
      filsystem. Tomt eller umulig navn blir 'upload'. }
    function SafeName: string;
    { Filendelsen fra SafeName, med punktum og i små bokstaver, eller ''. }
    function Extension: string;
    { Skriver til nøyaktig denne stien. Stien er kallerens ansvar — sett
      aldri sammen en sti av ClientName. }
    function SaveAs(const Path: string): Boolean;
    { Skriver til katalogen under et tilfeldig navn med den opprinnelige
      endelsen, og gir hele stien tilbake. Tom streng hvis det ikke gikk.
      Dette er den trygge veien: klientens navn når aldri filsystemet. }
    function StoreIn(const Dir: string): string;
  end;

  PUploadedFile = ^TUploadedFile;
  TUploadedFiles = array of TUploadedFile;

  TMultipartField = record
    Name: TStr;
    Value: TStr;
  end;
  PMultipartField = ^TMultipartField;

  { Tabellene er arena-allokerte blokker med teller, ikke dynamiske
    arrayer. Grunnen er målt og har en egen test: et dynamisk array er et
    finaliseringspliktig felt, og `TRequest` som har ett slikt betaler en
    `Defer`-oppføring per request — på hver eneste request, også de uten
    en eneste fil. Hele arena-modellen er at en request ikke skal koste
    opprydning. }
  TMultipartForm = record
    Fields: PMultipartField;
    FieldCount: Integer;
    Files: PUploadedFile;
    FileCount: Integer;
    Error: TMultipartError;

    function Ok: Boolean;
    function FieldAt(Index: Integer): PMultipartField;
    function FileAt(Index: Integer): PUploadedFile;
    function Value(const AName: string): TStr;
    function Has(const AName: string): Boolean;
    function FileFor(const AName: string): TUploadedFile;
    { Returverdien er et dynamisk array — den er en funksjonsverdi hos
      kalleren, ikke et felt på requesten, og koster derfor ingen Defer. }
    function FilesFor(const AName: string): TUploadedFiles;
    function ErrorText: string;
  end;

{ Grensen ut av Content-Type. Tom TStr hvis den ikke er der. Verdien kan
  stå i anførselstegn, og da hører de ikke med. }
function MultipartBoundary(const ContentType: TStr): TStr;

{ Parts_ kroppen. Returnerer False og setter Error ved feil — en ødelagt
  kropp er en 400 fra kalleren, ikke en exception herfra. }
function ParseMultipart(A: TArena; const Body, Boundary: TStr;
  out Form: TMultipartForm): Boolean;

{ Navnet en fil får på disk. Eksponert fordi den er verdt å kunne teste og
  kalle direkte. }
function SanitizeFileName(const S: string): string;

implementation

uses
  Askr.Core.Crypto;

{ ------------------------------------------------------------- filnavn -- }

function SanitizeFileName(const S: string): string;
var
  I: Integer;
  C: Char;
  Base: string;
begin
  { Først vekk med alt som ligner en katalogsti. Både / og \, fordi en
    Windows-klient sender \ og en Unix-server ellers ville sett det som et
    helt vanlig tegn i navnet. }
  Base := S;
  for I := Length(Base) downto 1 do
    if (Base[I] = '/') or (Base[I] = '\') or (Base[I] = ':') then
    begin
      Base := Copy(Base, I + 1, MaxInt);
      Break;
    end;

  Result := '';
  for I := 1 to Length(Base) do
  begin
    C := Base[I];
    if ((C >= 'a') and (C <= 'z')) or ((C >= 'A') and (C <= 'Z')) or
       ((C >= '0') and (C <= '9')) or (C = '.') or (C = '-') or (C = '_') then
      Result := Result + C
    else
      { Alt annet blir understrek, også mellomrom og ikke-ASCII. Et navn
        som overlever hit skal ikke kunne bety noe for et skall. }
      Result := Result + '_';
  end;

  { Ledende punktum vekk: «.bashrc» og «..» er begge navn man ikke vil ha
    laget ved et uhell. }
  while (Result <> '') and (Result[1] = '.') do
    Delete(Result, 1, 1);

  if Length(Result) > 200 then
    Result := Copy(Result, 1, 200);
  if Result = '' then
    Result := 'upload';
end;

{ ------------------------------------------------------- TUploadedFile -- }

function TUploadedFile.IsEmpty: Boolean;
begin
  { Tom betyr «det kom ingen fil». Et skjemafelt der brukeren ikke valgte
    noe sender en del med tomt filnavn og null bytes, og det skal ikke se
    ut som en opplasting. }
  Result := (ClientName.Len = 0) and (Content.Len = 0);
end;

function TUploadedFile.Size: SizeInt;
begin
  Result := Content.Len;
end;

function TUploadedFile.SafeName: string;
begin
  Result := SanitizeFileName(ClientName.ToString);
end;

function TUploadedFile.Extension: string;
var
  N: string;
  P: Integer;
begin
  N := SafeName;
  Result := '';
  for P := Length(N) downto 1 do
    if N[P] = '.' then
    begin
      Result := LowerCase(Copy(N, P, MaxInt));
      Break;
    end;
  { En «endelse» på tjue tegn er ikke en endelse. }
  if Length(Result) > 16 then
    Result := '';
end;

function TUploadedFile.SaveAs(const Path: string): Boolean;
var
  F: TFileStream;
begin
  Result := False;
  try
    F := TFileStream.Create(Path, fmCreate);
    try
      if Content.Len > 0 then
        F.WriteBuffer(Content.Data^, Content.Len);
      Result := True;
    finally
      F.Free;
    end;
  except
    on EStreamError do
      Result := False;
  end;
end;

function TUploadedFile.StoreIn(const Dir: string): string;
var
  Path_: string;
begin
  Result := '';
  if not ForceDirectories(Dir) then
    Exit;
  { Tilfeldig navn, ikke klientens. To brukere som laster opp «bilde.jpg»
    skal ikke skrive over hverandre, og klientens navn skal ikke nå
    filsystemet i det hele tatt. Det opprinnelige navnet er fortsatt der i
    ClientName hvis appen vil lagre det ved siden av. }
  Path_ := IncludeTrailingPathDelimiter(Dir) + RandomHex(16) + Extension;
  if not SaveAs(Path_) then
    Exit;
  Result := Path_;
end;

{ -------------------------------------------------------- TMultipartForm -- }

function TMultipartForm.Ok: Boolean;
begin
  Result := Error = mpOk;
end;

function TMultipartForm.FieldAt(Index: Integer): PMultipartField;
begin
  if (Index < 0) or (Index >= FieldCount) then
    Exit(nil);
  Result := Fields;
  Inc(Result, Index);
end;

function TMultipartForm.FileAt(Index: Integer): PUploadedFile;
begin
  if (Index < 0) or (Index >= FileCount) then
    Exit(nil);
  Result := Files;
  Inc(Result, Index);
end;

function TMultipartForm.Value(const AName: string): TStr;
var
  I: Integer;
begin
  for I := 0 to FieldCount - 1 do
    if FieldAt(I)^.Name.EqualsStr(AName) then
      Exit(FieldAt(I)^.Value);
  Result.Data := nil;
  Result.Len := 0;
end;

function TMultipartForm.Has(const AName: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to FieldCount - 1 do
    if FieldAt(I)^.Name.EqualsStr(AName) then
      Exit(True);
  Result := False;
end;

function TMultipartForm.FileFor(const AName: string): TUploadedFile;
var
  I: Integer;
begin
  for I := 0 to FileCount - 1 do
    if FileAt(I)^.FieldName.EqualsStr(AName) then
      Exit(FileAt(I)^);
  FillChar(Result, SizeOf(Result), 0);
end;

function TMultipartForm.FilesFor(const AName: string): TUploadedFiles;
var
  I, N: Integer;
begin
  Result := nil;
  N := 0;
  for I := 0 to FileCount - 1 do
    if FileAt(I)^.FieldName.EqualsStr(AName) then
    begin
      SetLength(Result, N + 1);
      Result[N] := FileAt(I)^;
      Inc(N);
    end;
end;

function TMultipartForm.ErrorText: string;
begin
  case Error of
    mpOk: Result := '';
    mpNoBoundary: Result := 'The multipart Content-Type has no boundary.';
    mpMalformed: Result := 'The multipart body is malformed.';
    mpTooManyParts: Result := 'The multipart body has too many parts.';
  end;
end;

{ ------------------------------------------------------------ parsing -- }

function MultipartBoundary(const ContentType: TStr): TStr;
var
  P: SizeInt;
  Rest: TStr;
begin
  Result.Data := nil;
  Result.Len := 0;
  P := ContentType.IndexOfStr('boundary=');
  if P < 0 then
    Exit;
  Rest := ContentType.Slice(P + Length('boundary='));
  { Verdien kan stå i anførselstegn. RFC 2046 tillater tegn i en grense som
    ellers må siteres, og en klient som gjør det skal ikke gi en grense som
    begynner med ". }
  if (Rest.Len > 0) and (Rest.Data^ = Ord('"')) then
  begin
    Rest := Rest.Slice(1);
    P := Rest.IndexOfByte(Ord('"'));
    if P < 0 then
      Exit;
    Result := Rest.Slice(0, P);
    Exit;
  end;
  { Ellers slutter den ved semikolon eller ved slutten. }
  P := Rest.IndexOfByte(Ord(';'));
  if P >= 0 then
    Rest := Rest.Slice(0, P);
  Result := Rest.TrimSpace;
end;

{ Henter en navngitt parameter ut av en Content-Disposition-linje:
  `form-data; name="fil"; filename="bilde.jpg"`. Verdien kan stå med eller
  uten anførselstegn. }
function DispositionParam(const Line: TStr; const Key: string): TStr;
var
  P: SizeInt;
  Rest: TStr;
begin
  Result.Data := nil;
  Result.Len := 0;
  P := Line.IndexOfStr(Key + '=');
  if P < 0 then
    Exit;
  Rest := Line.Slice(P + Length(Key) + 1);
  if (Rest.Len > 0) and (Rest.Data^ = Ord('"')) then
  begin
    Rest := Rest.Slice(1);
    P := Rest.IndexOfByte(Ord('"'));
    if P < 0 then
      Exit;
    Result := Rest.Slice(0, P);
    Exit;
  end;
  P := Rest.IndexOfByte(Ord(';'));
  if P >= 0 then
    Rest := Rest.Slice(0, P);
  Result := Rest.TrimSpace;
end;

{ Én navngitt header ut av delens headerblokk. }
function PartHeader(const Block: TStr; const Name_: string): TStr;
var
  Rest, Line, K, V: TStr;
  P: SizeInt;
begin
  Result.Data := nil;
  Result.Len := 0;
  Rest := Block;
  while Rest.Len > 0 do
  begin
    P := Rest.IndexOfStr(#13#10);
    if P < 0 then
    begin
      Line := Rest;
      Rest.Len := 0;
    end
    else
    begin
      Line := Rest.Slice(0, P);
      Rest := Rest.Slice(P + 2);
    end;
    if Line.SplitAt(Ord(':'), K, V) and K.TrimSpace.SameTextStr(Name_) then
      Exit(V.TrimSpace);
  end;
end;

function ParseMultipart(A: TArena; const Body, Boundary: TStr;
  out Form: TMultipartForm): Boolean;
var
  Skille: TStrBuilder;
  Delim, Start: TStr;
  P, HodeSlutt, Neste: SizeInt;
  Hode, Content_, Disp, Name_, Filnavn: TStr;
  FieldsSeen, FilesSeen, PartsSeen: Integer;
  FieldCap, KapFil: Integer;
  NewField: PMultipartField;
  NewFile: PUploadedFile;
begin
  Form.Fields := nil;
  Form.FieldCount := 0;
  Form.Files := nil;
  Form.FileCount := 0;
  Form.Error := mpOk;
  FieldsSeen := 0;
  FilesSeen := 0;
  PartsSeen := 0;
  FieldCap := 0;
  KapFil := 0;

  if Boundary.Len = 0 then
  begin
    Form.Error := mpNoBoundary;
    Exit(False);
  end;

  { Skilletegnet er CRLF + "--" + grensen. CRLF-en foran hører til
    skilletegnet, ikke til innholdet — glemmer man det, får hver eneste fil
    to ekstra byte på slutten, og det merkes først når noen åpner en
    zip-fil som ikke lar seg åpne. }
  Skille.Init(A, Boundary.Len + 8);
  Skille.Append(#13#10'--');
  Skille.Append(Boundary);
  Delim := Skille.ToStr;
  { Den aller første grensen står uten CRLF foran hvis det ikke er noen
    preambel. }
  Start := Delim.Slice(2);

  if (Body.Len >= Start.Len) and
     (CompareByte(Body.Data^, Start.Data^, Start.Len) = 0) then
    P := Start.Len
  else
  begin
    { With_ preambel: let etter den første ekte grensen. }
    P := Body.IndexOfStr(Delim);
    if P < 0 then
    begin
      Form.Error := mpMalformed;
      Exit(False);
    end;
    Inc(P, Delim.Len);
  end;

  while True do
  begin
    { After_ grensen: enten "--" og slutt, eller CRLF og en del til. }
    if P + 2 > Body.Len then
    begin
      Form.Error := mpMalformed;
      Exit(False);
    end;
    if ((Body.Data + P)^ = Ord('-')) and ((Body.Data + P + 1)^ = Ord('-')) then
      Break;
    if ((Body.Data + P)^ <> 13) or ((Body.Data + P + 1)^ <> 10) then
    begin
      { Noen klienter legger på mellomrom etter grensen. Skip over dem
        heller enn å avvise en kropp som ellers er i orden. }
      while (P < Body.Len) and
            (((Body.Data + P)^ = 32) or ((Body.Data + P)^ = 9)) do
        Inc(P);
      if (P + 2 > Body.Len) or ((Body.Data + P)^ <> 13) or
         ((Body.Data + P + 1)^ <> 10) then
      begin
        Form.Error := mpMalformed;
        Exit(False);
      end;
    end;
    Inc(P, 2);

    Inc(PartsSeen);
    if PartsSeen > MaxMultipartParts then
    begin
      Form.Error := mpTooManyParts;
      Exit(False);
    end;

    HodeSlutt := Body.IndexOfStr(#13#10#13#10, P);
    if (HodeSlutt < 0) or (HodeSlutt - P > MaxPartHeaderBytes) then
    begin
      Form.Error := mpMalformed;
      Exit(False);
    end;
    Hode := Body.Slice(P, HodeSlutt - P);
    P := HodeSlutt + 4;

    Neste := Body.IndexOfStr(Delim, P);
    if Neste < 0 then
    begin
      { Without en avsluttende grense er kroppen kuttet. Å ta med resten
        likevel ville gitt en halv fil som ser hel ut. }
      Form.Error := mpMalformed;
      Exit(False);
    end;
    Content_ := Body.Slice(P, Neste - P);
    P := Neste + Delim.Len;

    Disp := PartHeader(Hode, 'Content-Disposition');
    Name_ := DispositionParam(Disp, 'name');
    if Name_.Len = 0 then
      { En del uten navn hører ikke til skjemaet. Den hoppes over i stedet
        for å velte hele kroppen. }
      Continue;

    { `filename` er det som skiller en fil fra et vanlig felt — også når
      den er tom, slik et skjema med et tomt filfelt sender den. }
    Filnavn := DispositionParam(Disp, 'filename');
    if Disp.IndexOfStr('filename=') >= 0 then
    begin
      { Dobling i arenaen. Den forrige blokken blir liggende til Reset —
        samme avveining som TStrBuilder gjør, og den koster ingenting i en
        arena. Et skjema har som regel én fil, så det blir null vekster. }
      if FilesSeen >= KapFil then
      begin
        if KapFil = 0 then
          KapFil := 4
        else
          KapFil := KapFil * 2;
        NewFile := PUploadedFile(A.Alloc(PtrUInt(KapFil) * SizeOf(TUploadedFile)));
        if FilesSeen > 0 then
          Move(Form.Files^, NewFile^, PtrUInt(FilesSeen) * SizeOf(TUploadedFile));
        Form.Files := NewFile;
      end;
      NewFile := Form.Files;
      Inc(NewFile, FilesSeen);
      NewFile^.FieldName := Name_;
      NewFile^.ClientName := Filnavn;
      NewFile^.ContentType := PartHeader(Hode, 'Content-Type');
      NewFile^.Content := Content_;
      Inc(FilesSeen);
      Form.FileCount := FilesSeen;
    end
    else
    begin
      if FieldsSeen >= FieldCap then
      begin
        if FieldCap = 0 then
          FieldCap := 8
        else
          FieldCap := FieldCap * 2;
        NewField := PMultipartField(
          A.Alloc(PtrUInt(FieldCap) * SizeOf(TMultipartField)));
        if FieldsSeen > 0 then
          Move(Form.Fields^, NewField^, PtrUInt(FieldsSeen) * SizeOf(TMultipartField));
        Form.Fields := NewField;
      end;
      NewField := Form.Fields;
      Inc(NewField, FieldsSeen);
      NewField^.Name := Name_;
      NewField^.Value := Content_;
      Inc(FieldsSeen);
      Form.FieldCount := FieldsSeen;
    end;
  end;

  Result := True;
end;

end.
