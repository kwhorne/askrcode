{ Askr.Urd.Driver — grensesnittet alle databasedrivere ligger bak.

  Det finnes tre dialekter, og de er ulike på tre punkter som lekker helt opp
  i query builderen hvis de ikke stoppes her:

    * Plassholdere er $1, $2 i Postgres og ? i MySQL og SQLite.
    * Identifikatorer siteres med " i Postgres og SQLite, med ` i MySQL.
    * RETURNING finnes i Postgres og SQLite, men ikke i MySQL, som må hente
      LAST_INSERT_ID() etterpå.

  Derfor er «sett inn og gi meg id-en» én operasjon på driveren — InsertGetId
  — og ikke noe query builderen setter sammen selv. Det er den avgjørelsen som
  er lett nå og vond om seks uker.

  Et resultatsett eier ingenting fra driverbiblioteket. Alt kopieres inn i
  arenaen før Exec returnerer. }
unit Askr.Urd.Driver;

{$mode Delphi}{$H+}
{$POINTERMATH ON}

interface

uses
  SysUtils, Askr.Core.Arena, Askr.Core.Text;

type
  TSqlDialect = (sdPostgres, sdMySql, sdSqlite);

  EDbError = class(Exception)
  private
    FSqlState: string;
  public
    constructor Create(const AMessage: string; const ASqlState: string = '');
    { Femtegns SQLSTATE fra serveren, tom når feilen er lokal. '23505' er
      unik-brudd i Postgres. Se også IsUniqueViolation. }
    property SqlState: string read FSqlState;
    function IsUniqueViolation: Boolean;
    function IsForeignKeyViolation: Boolean;
  end;

  { Driverbiblioteket finnes ikke på maskinen. Eget navn fordi dette er et
    driftsproblem, ikke en spørringsfeil. }
  EDbUnavailable = class(EDbError);

  PDbParam = ^TDbParam;
  TDbParam = record
    Value: TStr;
    IsNull: Boolean;
  end;

  PDbCell = ^TDbCell;
  TDbCell = record
    Value: TStr;
    IsNull: Boolean;
  end;

  { Ferdig lest resultatsett i arenaen. Driveren fyller det med Allocate,
    SetFieldName og SetCell; alle andre bare leser. }
  TDbResult = class(TArenaObject)
  private
    FRowCount: Integer;
    FFieldCount: Integer;
    FCells: PDbCell;
    FNames: PStr;
    FAffected: Int64;
  public
    procedure Allocate(ARowCount, AFieldCount: Integer);
    procedure SetFieldName(Col: Integer; const AName: TStr);
    procedure SetCell(Row, Col: Integer; const AValue: TStr; ANull: Boolean);
    procedure SetAffected(Value: Int64);

    function IsNull(Row, Col: Integer): Boolean; overload;
    function IsNull(Row: Integer; const AField: string): Boolean; overload;
    function Value(Row, Col: Integer): TStr; overload;
    function Value(Row: Integer; const AField: string): TStr; overload;
    function FieldName(Col: Integer): TStr;
    function IndexOfField(const AName: string): Integer;

    { Bekvemmeligheter for enkeltverdier — count(*), RETURNING id og liknende. }
    function AsInt64(Row, Col: Integer; Default: Int64 = 0): Int64;
    function IsEmpty: Boolean;

    property RowCount: Integer read FRowCount;
    property FieldCount: Integer read FFieldCount;
    { Rader berørt av INSERT, UPDATE eller DELETE. -1 når det ikke gjelder. }
    property AffectedRows: Int64 read FAffected;
  end;

  TDbConnection = class abstract
  protected
    FInTransaction: Boolean;
  public
    function Dialect: TSqlDialect; virtual; abstract;
    function IsAlive: Boolean; virtual; abstract;

    function Exec(A: TArena; const Sql: string): TDbResult; virtual; abstract;
    function ExecParams(A: TArena; const Sql: string;
      const Params: array of TDbParam): TDbResult; virtual; abstract;

    { Sql skal være en komplett INSERT uten RETURNING. Driveren legger til det
      dialekten trenger for å få id-en tilbake. Returnerer 0 når tabellen ikke
      har en autogenerert nøkkel. }
    function InsertGetId(A: TArena; const Sql: string;
      const Params: array of TDbParam; const IdColumn: string): Int64;
      virtual; abstract;

    procedure StartTransaction; virtual; abstract;
    procedure Commit; virtual; abstract;
    procedure Rollback; virtual; abstract;

    { Plassholder nummer Index, 1-basert. }
    procedure AppendPlaceholder(var B: TStrBuilder; Index: Integer); virtual;
    { Sitert identifikator. Doble anførselstegn inni navnet dobles. }
    procedure AppendIdent(var B: TStrBuilder; const AName: TStr); virtual;
    procedure AppendIdentStr(var B: TStrBuilder; const AName: string);

    function SupportsReturning: Boolean; virtual;
    property InTransaction: Boolean read FInTransaction;
  end;

  TDbConnectionFactory = function(const Dsn: string): TDbConnection;

{ Drivere registrerer seg selv i sin initialization-seksjon, slik at det å ta
  med en unit i uses er alt som skal til for å få dialekten. }
procedure RegisterDbDriver(const Scheme: string; Factory: TDbConnectionFactory);
function OpenDbConnection(const Dsn: string): TDbConnection;
function DsnScheme(const Dsn: string): string;
function RegisteredDrivers: string;

{ Parametre. Verdien må leve til spørringen er kjørt, så alt som lager en ny
  streng tar arenaen eksplisitt. }
function DbParam(const Value: TStr): TDbParam; overload;
function DbParam(A: TArena; const Value: string): TDbParam; overload;
function DbParam(A: TArena; Value: Int64): TDbParam; overload;
function DbParam(A: TArena; Value: Currency): TDbParam; overload;
function DbParam(A: TArena; Value: Boolean): TDbParam; overload;
function DbParamDateTime(A: TArena; Value: TDateTime): TDbParam;
function DbNull: TDbParam;

{ Locale-uavhengig formatering. CurrToStr og FloatToStr bruker systemets
  desimalskilletegn, og et komma i en SQL-parameter er en feil som først
  dukker opp på en maskin med norsk locale. }
function CurrencyToSql(Value: Currency): string;
function FloatToSql(Value: Double): string;
function DateTimeToSql(Value: TDateTime): string;

{ Den andre veien: tekst fra databasen til Pascal-verdier, uten å gå om
  StrToFloat og systemets desimalskilletegn. Alle returnerer False på søppel
  i stedet for å kaste, fordi kalleren vet hvilken kolonne det gjaldt. }
function SqlToInt64(const S: TStr; out V: Int64): Boolean;
function SqlToCurrency(const S: TStr; out V: Currency): Boolean;
function SqlToFloat(const S: TStr; out V: Double): Boolean;
function SqlToBool(const S: TStr; out V: Boolean): Boolean;
{ Tåler 'YYYY-MM-DD', 'YYYY-MM-DD HH:MM:SS', ISO-T mellom dato og tid,
  brøkdels sekunder og etterfølgende tidssone. }
function SqlToDateTime(const S: TStr; out V: TDateTime): Boolean;

implementation

uses
  SyncObjs;

type
  TDriverEntry = record
    Scheme: string;
    Factory: TDbConnectionFactory;
  end;

var
  GDrivers: array of TDriverEntry;
  GDriverLock: TCriticalSection;

{ EDbError }

constructor EDbError.Create(const AMessage: string; const ASqlState: string);
begin
  inherited Create(AMessage);
  FSqlState := ASqlState;
end;

function EDbError.IsUniqueViolation: Boolean;
begin
  Result := FSqlState = '23505';
end;

function EDbError.IsForeignKeyViolation: Boolean;
begin
  Result := FSqlState = '23503';
end;

{ TDbResult }

procedure TDbResult.Allocate(ARowCount, AFieldCount: Integer);
begin
  FRowCount := ARowCount;
  FFieldCount := AFieldCount;
  FAffected := -1;
  if AFieldCount > 0 then
    FNames := PStr(Arena.AllocZero(PtrUInt(AFieldCount) * SizeOf(TStr)));
  if (ARowCount > 0) and (AFieldCount > 0) then
    FCells := PDbCell(Arena.AllocZero(
      PtrUInt(ARowCount) * PtrUInt(AFieldCount) * SizeOf(TDbCell)));
end;

procedure TDbResult.SetFieldName(Col: Integer; const AName: TStr);
begin
  if (Col >= 0) and (Col < FFieldCount) then
    FNames[Col] := AName;
end;

procedure TDbResult.SetCell(Row, Col: Integer; const AValue: TStr; ANull: Boolean);
var
  C: PDbCell;
begin
  if (Row < 0) or (Row >= FRowCount) or (Col < 0) or (Col >= FFieldCount) then
    Exit;
  C := FCells + (Row * FFieldCount + Col);
  C^.Value := AValue;
  C^.IsNull := ANull;
end;

procedure TDbResult.SetAffected(Value: Int64);
begin
  FAffected := Value;
end;

function TDbResult.IsNull(Row, Col: Integer): Boolean;
begin
  if (Row < 0) or (Row >= FRowCount) or (Col < 0) or (Col >= FFieldCount) then
    Exit(True);
  Result := FCells[Row * FFieldCount + Col].IsNull;
end;

function TDbResult.IsNull(Row: Integer; const AField: string): Boolean;
begin
  Result := IsNull(Row, IndexOfField(AField));
end;

function TDbResult.Value(Row, Col: Integer): TStr;
begin
  if (Row < 0) or (Row >= FRowCount) or (Col < 0) or (Col >= FFieldCount) then
    Exit(StrEmpty);
  Result := FCells[Row * FFieldCount + Col].Value;
end;

function TDbResult.Value(Row: Integer; const AField: string): TStr;
var
  Col: Integer;
begin
  Col := IndexOfField(AField);
  if Col < 0 then
    Exit(StrEmpty);
  Result := Value(Row, Col);
end;

function TDbResult.FieldName(Col: Integer): TStr;
begin
  if (Col < 0) or (Col >= FFieldCount) then
    Exit(StrEmpty);
  Result := FNames[Col];
end;

function TDbResult.IndexOfField(const AName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to FFieldCount - 1 do
    if FNames[I].SameTextStr(AName) then
      Exit(I);
  Result := -1;
end;

function TDbResult.AsInt64(Row, Col: Integer; Default: Int64): Int64;
begin
  if IsNull(Row, Col) then
    Exit(Default);
  Result := Value(Row, Col).ToIntDef(Default);
end;

function TDbResult.IsEmpty: Boolean;
begin
  Result := FRowCount = 0;
end;

{ TDbConnection }

procedure TDbConnection.AppendPlaceholder(var B: TStrBuilder; Index: Integer);
begin
  { Flertallet bruker ?. Postgres overstyrer. }
  B.AppendByte(Ord('?'));
end;

procedure TDbConnection.AppendIdent(var B: TStrBuilder; const AName: TStr);
var
  I: SizeInt;
  Q: Byte;
begin
  if Dialect = sdMySql then
    Q := Ord('`')
  else
    Q := Ord('"');
  B.AppendByte(Q);
  for I := 0 to AName.Len - 1 do
  begin
    if (AName.Data + I)^ = Q then
      B.AppendByte(Q);
    B.AppendByte((AName.Data + I)^);
  end;
  B.AppendByte(Q);
end;

procedure TDbConnection.AppendIdentStr(var B: TStrBuilder; const AName: string);
begin
  AppendIdent(B, Str(AName));
end;

function TDbConnection.SupportsReturning: Boolean;
begin
  Result := Dialect <> sdMySql;
end;

{ Registrering }

procedure RegisterDbDriver(const Scheme: string; Factory: TDbConnectionFactory);
var
  I: Integer;
begin
  GDriverLock.Acquire;
  try
    for I := 0 to High(GDrivers) do
      if SameText(GDrivers[I].Scheme, Scheme) then
      begin
        GDrivers[I].Factory := Factory;
        Exit;
      end;
    SetLength(GDrivers, Length(GDrivers) + 1);
    GDrivers[High(GDrivers)].Scheme := LowerCase(Scheme);
    GDrivers[High(GDrivers)].Factory := Factory;
  finally
    GDriverLock.Release;
  end;
end;

function DsnScheme(const Dsn: string): string;
var
  P: Integer;
begin
  { Både 'postgresql://host/db' og 'sqlite:fil.db' skal treffe. }
  P := Pos(':', Dsn);
  if P <= 1 then
    Exit('');
  Result := LowerCase(Copy(Dsn, 1, P - 1));
end;

function RegisteredDrivers: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(GDrivers) do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + GDrivers[I].Scheme;
  end;
  if Result = '' then
    Result := '(ingen)';
end;

function OpenDbConnection(const Dsn: string): TDbConnection;
var
  Scheme: string;
  I: Integer;
  F: TDbConnectionFactory;
begin
  Scheme := DsnScheme(Dsn);
  if Scheme = '' then
    raise EDbError.Create('DSN has no scheme: ' + Dsn);

  F := nil;
  GDriverLock.Acquire;
  try
    for I := 0 to High(GDrivers) do
      if GDrivers[I].Scheme = Scheme then
      begin
        F := GDrivers[I].Factory;
        Break;
      end;
  finally
    GDriverLock.Release;
  end;

  if not Assigned(F) then
    raise EDbError.CreateFmt(
      'No driver for "%s". Registered: %s. ' +
      'Add the matching Askr.Urd unit to your uses clause.', [Scheme, RegisteredDrivers]);
  Result := F(Dsn);
end;

{ Parametre }

function DbParam(const Value: TStr): TDbParam;
begin
  Result.Value := Value;
  Result.IsNull := False;
end;

function DbParam(A: TArena; const Value: string): TDbParam;
begin
  Result.Value := StrDup(A, Value);
  Result.IsNull := False;
end;

function DbParam(A: TArena; Value: Int64): TDbParam;
var
  B: TStrBuilder;
begin
  B.Init(A, 24);
  B.AppendInt(Value);
  Result.Value := B.ToStr;
  Result.IsNull := False;
end;

function DbParam(A: TArena; Value: Currency): TDbParam;
begin
  Result := DbParam(A, CurrencyToSql(Value));
end;

function DbParam(A: TArena; Value: Boolean): TDbParam;
begin
  { 1 og 0 er det eneste alle tre dialektene tolker likt. }
  if Value then
    Result := DbParam(A, '1')
  else
    Result := DbParam(A, '0');
end;

function DbParamDateTime(A: TArena; Value: TDateTime): TDbParam;
begin
  Result := DbParam(A, DateTimeToSql(Value));
end;

function DbNull: TDbParam;
begin
  Result.Value := StrEmpty;
  Result.IsNull := True;
end;

function CurrencyToSql(Value: Currency): string;
var
  Scaled: Int64;
  Neg: Boolean;
  Whole, Frac: Int64;
begin
  { Currency er en Int64 skalert med 10000. Vi formaterer for hånd i stedet
    for å gå om FloatToStr, som følger systemets desimalskilletegn. }
  Scaled := PInt64(@Value)^;
  Neg := Scaled < 0;
  if Neg then
    Scaled := -Scaled;
  Whole := Scaled div 10000;
  Frac := Scaled mod 10000;
  Result := IntToStr(Whole) + '.' + Copy(IntToStr(10000 + Frac), 2, 4);
  if Neg then
    Result := '-' + Result;
end;

function FloatToSql(Value: Double): string;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := #0;
  { 17 signifikante siffer er nok til å få nøyaktig samme double tilbake. }
  Result := FloatToStrF(Value, ffGeneral, 17, 0, FS);
end;

function DateTimeToSql(Value: TDateTime): string;
var
  Y, M, D, H, N, S, Ms: Word;
begin
  DecodeDate(Value, Y, M, D);
  DecodeTime(Value, H, N, S, Ms);
  Result := Format('%.4d-%.2d-%.2d %.2d:%.2d:%.2d', [Y, M, D, H, N, S]);
end;

function SqlToInt64(const S: TStr; out V: Int64): Boolean;
begin
  Result := S.ToInt64(V);
end;

{ Deler opp i heltallsdel og opptil Decimals desimaler, uten flyttall
  underveis. Det som er igjen av desimaler forkastes, slik databasen selv
  ville gjort ved lagring i en skalert kolonne. }
function SplitDecimal(const S: TStr; Decimals: Integer;
  out Scaled: Int64): Boolean;
var
  I: SizeInt;
  Neg, SeenDigit, AfterDot: Boolean;
  Taken: Integer;
  D: Byte;
begin
  Scaled := 0;
  if S.Len = 0 then
    Exit(False);
  I := 0;
  Neg := False;
  SeenDigit := False;
  AfterDot := False;
  Taken := 0;

  if ((S.Data)^ = Ord('-')) or ((S.Data)^ = Ord('+')) then
  begin
    Neg := (S.Data)^ = Ord('-');
    I := 1;
  end;

  while I < S.Len do
  begin
    D := (S.Data + I)^;
    if D = Ord('.') then
    begin
      if AfterDot then
        Exit(False);
      AfterDot := True;
    end
    else if (D >= Ord('0')) and (D <= Ord('9')) then
    begin
      SeenDigit := True;
      if AfterDot then
      begin
        if Taken < Decimals then
        begin
          Scaled := Scaled * 10 + Int64(D - Ord('0'));
          Inc(Taken);
        end;
        { Flere desimaler enn vi har plass til forkastes. }
      end
      else
        Scaled := Scaled * 10 + Int64(D - Ord('0'));
    end
    else
      Exit(False);
    Inc(I);
  end;

  if not SeenDigit then
    Exit(False);
  while Taken < Decimals do
  begin
    Scaled := Scaled * 10;
    Inc(Taken);
  end;
  if Neg then
    Scaled := -Scaled;
  Result := True;
end;

function SqlToCurrency(const S: TStr; out V: Currency): Boolean;
var
  Scaled: Int64;
begin
  V := 0;
  { Currency er en Int64 skalert med 10000. }
  Result := SplitDecimal(S, 4, Scaled);
  if Result then
    PInt64(@V)^ := Scaled;
end;

function SqlToFloat(const S: TStr; out V: Double): Boolean;
var
  FS: TFormatSettings;
begin
  { Egne innstillinger, ikke systemets — en norsk locale ville tolket
    '1234.50' som 123450. }
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := #0;
  Result := TryStrToFloat(S.ToString, V, FS);
end;

function SqlToBool(const S: TStr; out V: Boolean): Boolean;
begin
  V := False;
  if S.Len = 0 then
    Exit(False);
  { Postgres sier t/f, MySQL og SQLite 1/0, og JSON-veien kan si true/false. }
  if S.SameTextStr('t') or S.SameTextStr('true') or S.EqualsStr('1') or
     S.SameTextStr('y') or S.SameTextStr('yes') then
  begin
    V := True;
    Exit(True);
  end;
  if S.SameTextStr('f') or S.SameTextStr('false') or S.EqualsStr('0') or
     S.SameTextStr('n') or S.SameTextStr('no') then
    Exit(True);
  Result := False;
end;

function TwoDigits(const S: TStr; Offset: SizeInt; out V: Integer): Boolean;
var
  A, B: Byte;
begin
  V := 0;
  if Offset + 1 >= S.Len then
    Exit(False);
  A := (S.Data + Offset)^;
  B := (S.Data + Offset + 1)^;
  if (A < Ord('0')) or (A > Ord('9')) or (B < Ord('0')) or (B > Ord('9')) then
    Exit(False);
  V := (A - Ord('0')) * 10 + (B - Ord('0'));
  Result := True;
end;

function SqlToDateTime(const S: TStr; out V: TDateTime): Boolean;
var
  Mo, D, H, Mi, Se: Integer;
  Y: Int64;
  I: Integer;
  Dt, Tm: TDateTime;
  Sep: Byte;
begin
  V := 0;
  if S.Len < 10 then
    Exit(False);
  if not S.Slice(0, 4).ToInt64(Y) then
    Exit(False);
  if ((S.Data + 4)^ <> Ord('-')) or ((S.Data + 7)^ <> Ord('-')) then
    Exit(False);
  if not TwoDigits(S, 5, Mo) then
    Exit(False);
  if not TwoDigits(S, 8, D) then
    Exit(False);
  if not TryEncodeDate(Word(Y), Word(Mo), Word(D), Dt) then
    Exit(False);

  if S.Len = 10 then
  begin
    V := Dt;
    Exit(True);
  end;

  Sep := (S.Data + 10)^;
  if (Sep <> Ord(' ')) and (Sep <> Ord('T')) and (Sep <> Ord('t')) then
    Exit(False);
  if S.Len < 19 then
    Exit(False);
  if not TwoDigits(S, 11, H) then Exit(False);
  if not TwoDigits(S, 14, Mi) then Exit(False);
  if not TwoDigits(S, 17, Se) then Exit(False);
  if not TryEncodeTime(Word(H), Word(Mi), Word(Se), 0, Tm) then
    Exit(False);

  { Brøkdels sekunder og tidssone ignoreres med vilje. Tidssonehåndtering
    hører hjemme i modellaget, ikke i en tekstparser. }
  I := 19;
  if (I < S.Len) and ((S.Data + I)^ = Ord('.')) then
  begin
    Inc(I);
    while (I < S.Len) and ((S.Data + I)^ >= Ord('0')) and
          ((S.Data + I)^ <= Ord('9')) do
      Inc(I);
  end;

  V := Dt + Tm;
  Result := True;
end;

initialization
  GDriverLock := TCriticalSection.Create;

finalization
  GDriverLock.Free;

end.
