{ Askr.Storage — files, on this disk or in S3, the same way.

      SetStorage(StorageFromConfig);
      ...
      Path := Storage.PutUpload('avatars', F);        // avatars/3f9c...e1.png
      Storage.Get(Path, Bytes);
      Link := Storage.TemporaryUrl(Path, 15 * 60);    // for a private file

  An app writes to a disk and does not care which: a directory on this
  machine in development, S3 -- or anything that speaks it: MinIO, R2,
  Spaces -- in production, where the files have to outlive the server and
  be shared by every process.

  **A path is checked, never trusted.** Segments separated by /, and none
  of them empty, . or .., nor holding a backslash or a NUL. A path from a
  request that reaches a disk cannot climb out of it, on either kind.

  **S3 is signed with Signature V4**, in Pascal on the crypto that is here,
  over the HTTP client that is here -- no SDK. The signatures are held to
  botocore's, AWS's own signer (tests/vectors/sigv4.txt), and ./askr
  storage:check stores, reads, looks for and deletes against versitygw, an
  S3 server that checks every signature it is sent. **No request has gone to AWS itself from
  here**, and that is said until one has.

  **A private file is handed out with a temporary URL.** On S3 that is a
  presigned URL; on the local disk it is a signed link to a route
  UseStoredFiles serves, which checks the signature and the expiry before
  it reads a byte. }
unit Askr.Storage;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, Askr.Http.Multipart, Askr.Http.Router;

type
  EStorageError = class(Exception);

  TStorageDisk = class
  public
    procedure Put(const Path, Data: string; const ContentType: string = ''); virtual; abstract;
    { False when there is no such file. }
    function Get(const Path: string; out Data: string): Boolean; virtual; abstract;
    function Exists(const Path: string): Boolean; virtual; abstract;
    { A file that is not there is not an error: it is gone either way. }
    procedure Delete(const Path: string); virtual; abstract;
    { The address of a public file. }
    function Url(const Path: string): string; virtual; abstract;
    { An address that works for LifetimeSeconds, for a private file. }
    function TemporaryUrl(const Path: string; LifetimeSeconds: Integer): string; virtual; abstract;
    function Describe: string; virtual; abstract;
    { An upload under Dir, with a random name and the upload's extension --
      never the client's name -- and the type the extension says. The path
      it was stored at comes back. }
    function PutUpload(const Dir: string; const F: TUploadedFile): string;
  end;

  TLocalDisk = class(TStorageDisk)
  private
    FRoot: string;
    FPublicUrl: string;
    FSignedPrefix: string;
    function FullPath(const Path: string): string;
  public
    { Root is the directory; PublicUrl is where it is served for Url, a
      path like /storage or a whole address. }
    constructor Create(const ARoot: string; const APublicUrl: string = '/storage');
    procedure Put(const Path, Data: string; const ContentType: string = ''); override;
    function Get(const Path: string; out Data: string): Boolean; override;
    function Exists(const Path: string): Boolean; override;
    procedure Delete(const Path: string); override;
    function Url(const Path: string): string; override;
    function TemporaryUrl(const Path: string; LifetimeSeconds: Integer): string; override;
    function Describe: string; override;
    property Root: string read FRoot;
  end;

  TS3Disk = class(TStorageDisk)
  private
    FBucket, FRegion, FAccessKey, FSecret, FEndpoint: string;
    FPathStyle: Boolean;
    function ObjectUrl(const Path: string): string;
    function Signed(const Method, Path, Body, ContentType: string; out Status: Integer): string;
  public
    { Endpoint is empty for AWS, and the S3-compatible server's address
      otherwise -- http://127.0.0.1:9000 for a MinIO on this machine. A bucket in the path is
      what those servers take; AWS takes it in the host name. }
    constructor Create(const ABucket, ARegion, AAccessKey, ASecret: string;
      const AEndpoint: string = '');
    procedure Put(const Path, Data: string; const ContentType: string = ''); override;
    function Get(const Path: string; out Data: string): Boolean; override;
    function Exists(const Path: string): Boolean; override;
    procedure Delete(const Path: string); override;
    function Url(const Path: string): string; override;
    function TemporaryUrl(const Path: string; LifetimeSeconds: Integer): string; override;
    function Describe: string; override;
    property PathStyle: Boolean read FPathStyle write FPathStyle;
  end;

function Storage: TStorageDisk;
procedure SetStorage(ADisk: TStorageDisk);

(* The disk storage.disk names: 'local' -- storage.root, storage/app unless
   set, served at storage.url -- or 's3', with s3.bucket, s3.region,
   s3.key, s3.secret and s3.endpoint. An unknown name raises: a typo in
   production would otherwise put the files on a disk that is gone at the
   next deploy. *)
function StorageFromConfig: TStorageDisk;

{ Serves the local disk's temporary URLs under Prefix, after the signature
  and the expiry have been checked. }
procedure UseStoredFiles(R: TRouter; Disk: TLocalDisk; const Prefix: string = '/files');

{ A path as the disks take it, or an exception that says why not. }
procedure CheckStoragePath(const Path: string);
{ Every byte but unreserved ones and / percent-encoded: the key in a URL. }
function EncodeKey(const Path: string): string;

{ Signature V4, exposed for the test that holds it to botocore. AmzDate is
  yyyymmddThhnnssZ. }
function S3Authorization(const Method, Url, Region, AccessKey, Secret,
  PayloadHash, AmzDate: string): string;
function S3PresignedUrl(const Url, Region, AccessKey, Secret, AmzDate: string;
  Expires: Integer): string;

implementation

uses
  DateUtils, Askr.Core.Crypto, Askr.Core.Config, Askr.Core.Mime, Askr.Core.Text,
  Askr.Core.Arena, Askr.Http.Types, Askr.Http.Request, Askr.Http.Response,
  Askr.Http.Client, Askr.Signed;

var
  GStorage: TStorageDisk = nil;

function Storage: TStorageDisk;
begin
  if GStorage = nil then
    raise EStorageError.Create('No storage is set. Call SetStorage at startup.');
  Result := GStorage;
end;

procedure SetStorage(ADisk: TStorageDisk);
begin
  GStorage := ADisk;
end;

procedure CheckStoragePath(const Path: string);
var
  L: TStringList;
  I: Integer;
begin
  if (Path = '') or (Path[1] = '/') or (Pos('\', Path) > 0) or (Pos(#0, Path) > 0) then
    raise EStorageError.CreateFmt('"%s" is not a storage path: segments ' +
      'separated by /, with no leading /', [Path]);
  L := TStringList.Create;
  try
    L.StrictDelimiter := True;
    L.Delimiter := '/';
    L.DelimitedText := Path;
    for I := 0 to L.Count - 1 do
      if (L[I] = '') or (L[I] = '.') or (L[I] = '..') then
        raise EStorageError.CreateFmt('"%s" is not a storage path: a segment is ' +
          'empty, . or ..', [Path]);
  finally
    L.Free;
  end;
end;

function EncodeKey(const Path: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(Path) do
    if Path[I] in ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~', '/'] then
      Result := Result + Path[I]
    else
      Result := Result + '%' + IntToHex(Ord(Path[I]), 2);
end;

{ TStorageDisk }

function TStorageDisk.PutUpload(const Dir: string; const F: TUploadedFile): string;
begin
  CheckStoragePath(Dir);
  Result := Dir + '/' + LowerCase(RandomHex(16)) + F.Extension;
  Put(Result, F.Content.ToString, ContentTypeForExt(F.Extension));
end;

{ TLocalDisk }

constructor TLocalDisk.Create(const ARoot, APublicUrl: string);
begin
  inherited Create;
  FRoot := ExcludeTrailingPathDelimiter(ExpandFileName(ARoot));
  FPublicUrl := APublicUrl;
  while (FPublicUrl <> '') and (FPublicUrl[Length(FPublicUrl)] = '/') do
    SetLength(FPublicUrl, Length(FPublicUrl) - 1);
  FSignedPrefix := '/files';
end;

function TLocalDisk.FullPath(const Path: string): string;
begin
  CheckStoragePath(Path);
  Result := FRoot + PathDelim + StringReplace(Path, '/', PathDelim, [rfReplaceAll]);
end;

procedure TLocalDisk.Put(const Path, Data, ContentType: string);
var
  P, Tmp: string;
  F: TFileStream;
begin
  P := FullPath(Path);
  ForceDirectories(ExtractFilePath(P));
  { Written beside it and renamed over it: a reader never sees half a
    file. }
  Tmp := P + '.' + LowerCase(RandomHex(4)) + '.tmp';
  F := TFileStream.Create(Tmp, fmCreate);
  try
    if Data <> '' then
      F.WriteBuffer(Data[1], Length(Data));
  finally
    F.Free;
  end;
  if FileExists(P) then
    SysUtils.DeleteFile(P);
  if not RenameFile(Tmp, P) then
    raise EStorageError.CreateFmt('Could not write %s', [Path]);
end;

function TLocalDisk.Get(const Path: string; out Data: string): Boolean;
var
  P: string;
  F: TFileStream;
begin
  Data := '';
  P := FullPath(Path);
  if not FileExists(P) then
    Exit(False);
  F := TFileStream.Create(P, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Data, F.Size);
    if F.Size > 0 then
      F.ReadBuffer(Data[1], F.Size);
  finally
    F.Free;
  end;
  Result := True;
end;

function TLocalDisk.Exists(const Path: string): Boolean;
begin
  Result := FileExists(FullPath(Path));
end;

procedure TLocalDisk.Delete(const Path: string);
var
  P: string;
begin
  P := FullPath(Path);
  if FileExists(P) then
    SysUtils.DeleteFile(P);
end;

function TLocalDisk.Url(const Path: string): string;
begin
  CheckStoragePath(Path);
  Result := FPublicUrl + '/' + EncodeKey(Path);
end;

function TLocalDisk.TemporaryUrl(const Path: string; LifetimeSeconds: Integer): string;
begin
  CheckStoragePath(Path);
  Result := SignedUrl(FSignedPrefix + '/' + EncodeKey(Path), LifetimeSeconds);
end;

function TLocalDisk.Describe: string;
begin
  Result := 'local (' + FRoot + ')';
end;

{ ------------------------------------------------------ Signature V4 -- }

function Hex(const D: TSha256Digest): string;
var
  B: TBytes;
begin
  B := nil;
  SetLength(B, 32);
  Move(D[0], B[0], 32);
  Result := LowerCase(HexEncode(B));
end;

function Bytes(const S: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(S));
  if S <> '' then
    Move(S[1], Result[0], Length(S));
end;

function Hmac(const Key: TBytes; const Msg: string): TBytes;
var
  D: TSha256Digest;
begin
  D := HmacSha256(Key, Bytes(Msg));
  Result := nil;
  SetLength(Result, 32);
  Move(D[0], Result[0], 32);
end;

{ The parts of a URL SigV4 needs: the host as the client sends it -- with
  the port when it is not the scheme's own -- and the path as it stands. }
procedure SplitUrl(const Url: string; out Host, Path, Query: string);
var
  Scheme, H: string;
  Port: Word;
  Rest: string;
  P: Integer;
begin
  P := Pos('://', Url);
  Scheme := LowerCase(Copy(Url, 1, P - 1));
  Rest := Copy(Url, P + 3, MaxInt);
  P := Pos('/', Rest);
  if P = 0 then
  begin
    H := Rest;
    Path := '/';
  end
  else
  begin
    H := Copy(Rest, 1, P - 1);
    Path := Copy(Rest, P, MaxInt);
  end;
  Query := '';
  P := Pos('?', Path);
  if P > 0 then
  begin
    Query := Copy(Path, P + 1, MaxInt);
    Path := Copy(Path, 1, P - 1);
  end;
  { A default port is left off, as the client leaves it off. }
  if Pos(':', H) > 0 then
  begin
    Port := StrToIntDef(Copy(H, Pos(':', H) + 1, MaxInt), 0);
    if ((Scheme = 'https') and (Port = 443)) or ((Scheme = 'http') and (Port = 80)) then
      H := Copy(H, 1, Pos(':', H) - 1);
  end;
  Host := LowerCase(H);
end;

function Scope(const AmzDate, Region: string): string;
begin
  Result := Copy(AmzDate, 1, 8) + '/' + Region + '/s3/aws4_request';
end;

function Signature(const Secret, AmzDate, Region, Canonical: string): string;
var
  K: TBytes;
  ToSign: string;
begin
  ToSign := 'AWS4-HMAC-SHA256' + #10 + AmzDate + #10 + Scope(AmzDate, Region) + #10 +
    Hex(Sha256(Canonical));
  K := Hmac(Bytes('AWS4' + Secret), Copy(AmzDate, 1, 8));
  K := Hmac(K, Region);
  K := Hmac(K, 's3');
  K := Hmac(K, 'aws4_request');
  Result := LowerCase(HexEncode(Hmac(K, ToSign)));
end;

function S3Authorization(const Method, Url, Region, AccessKey, Secret,
  PayloadHash, AmzDate: string): string;
var
  Host, Path, Query, Canonical: string;
begin
  SplitUrl(Url, Host, Path, Query);
  Canonical := Method + #10 + Path + #10 + Query + #10 +
    'host:' + Host + #10 +
    'x-amz-content-sha256:' + PayloadHash + #10 +
    'x-amz-date:' + AmzDate + #10 +
    #10 +
    'host;x-amz-content-sha256;x-amz-date' + #10 +
    PayloadHash;
  Result := 'AWS4-HMAC-SHA256 Credential=' + AccessKey + '/' + Scope(AmzDate, Region) +
    ', SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=' +
    Signature(Secret, AmzDate, Region, Canonical);
end;

{ A query value as SigV4 wants it: everything but unreserved bytes
  encoded, the slash too. }
function QueryEncode(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    if S[I] in ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~'] then
      Result := Result + S[I]
    else
      Result := Result + '%' + IntToHex(Ord(S[I]), 2);
end;

function S3PresignedUrl(const Url, Region, AccessKey, Secret, AmzDate: string;
  Expires: Integer): string;
var
  Host, Path, Query, Q, Canonical: string;
begin
  SplitUrl(Url, Host, Path, Query);
  { In the order SigV4 sorts them. }
  Q := 'X-Amz-Algorithm=AWS4-HMAC-SHA256' +
    '&X-Amz-Credential=' + QueryEncode(AccessKey + '/' + Scope(AmzDate, Region)) +
    '&X-Amz-Date=' + AmzDate +
    '&X-Amz-Expires=' + IntToStr(Expires) +
    '&X-Amz-SignedHeaders=host';
  Canonical := 'GET' + #10 + Path + #10 + Q + #10 +
    'host:' + Host + #10 + #10 + 'host' + #10 + 'UNSIGNED-PAYLOAD';
  Result := Copy(Url, 1, Pos('?', Url + '?') - 1) + '?' + Q + '&X-Amz-Signature=' +
    Signature(Secret, AmzDate, Region, Canonical);
end;

function AmzNow: string;
begin
  Result := FormatDateTime('yyyymmdd"T"hhnnss"Z"', LocalTimeToUniversal(Now));
end;

{ TS3Disk }

constructor TS3Disk.Create(const ABucket, ARegion, AAccessKey, ASecret,
  AEndpoint: string);
begin
  inherited Create;
  if (ABucket = '') or (ARegion = '') then
    raise EStorageError.Create('An S3 disk needs a bucket and a region');
  FBucket := ABucket;
  FRegion := ARegion;
  FAccessKey := AAccessKey;
  FSecret := ASecret;
  FEndpoint := AEndpoint;
  while (FEndpoint <> '') and (FEndpoint[Length(FEndpoint)] = '/') do
    SetLength(FEndpoint, Length(FEndpoint) - 1);
  FPathStyle := FEndpoint <> '';
end;

function TS3Disk.ObjectUrl(const Path: string): string;
begin
  CheckStoragePath(Path);
  if FPathStyle then
  begin
    if FEndpoint <> '' then
      Result := FEndpoint + '/' + FBucket + '/' + EncodeKey(Path)
    else
      Result := 'https://s3.' + FRegion + '.amazonaws.com/' + FBucket + '/' + EncodeKey(Path);
  end
  else
    Result := 'https://' + FBucket + '.s3.' + FRegion + '.amazonaws.com/' + EncodeKey(Path);
end;

function TS3Disk.Signed(const Method, Path, Body, ContentType: string;
  out Status: Integer): string;
var
  C: THttpClient;
  R: THttpResponse;
  Url, Hash_, Date_: string;
begin
  Url := ObjectUrl(Path);
  Hash_ := Sha256Hex(Body);
  Date_ := AmzNow;
  C := THttpClient.Create;
  try
    C.MaxRedirects := 0;
    C.WithHeader('x-amz-date', Date_);
    C.WithHeader('x-amz-content-sha256', Hash_);
    C.WithHeader('Authorization', S3Authorization(Method, Url, FRegion, FAccessKey,
      FSecret, Hash_, Date_));
    R := C.Request(Method, Url, Body, ContentType);
    Status := R.Status;
    Result := R.Body;
  finally
    C.Free;
  end;
end;

{ What S3 said, without the key: an error body names the bucket and the
  key, never the secret, and the status says the rest. }
function S3Error(const What, Path: string; Status: Integer; const Body: string): EStorageError;
var
  Code: string;
begin
  Code := '';
  if Pos('<Code>', Body) > 0 then
    Code := Copy(Body, Pos('<Code>', Body) + 6, Pos('</Code>', Body) - Pos('<Code>', Body) - 6);
  Result := EStorageError.CreateFmt('S3 would not %s %s: %d %s', [What, Path, Status, Code]);
end;

procedure TS3Disk.Put(const Path, Data, ContentType: string);
var
  Status: Integer;
  Body, CT: string;
begin
  CT := ContentType;
  if CT = '' then
    CT := ContentTypeForExt(ExtractFileExt(Path));
  Body := Signed('PUT', Path, Data, CT, Status);
  if (Status < 200) or (Status > 299) then
    raise S3Error('store', Path, Status, Body);
end;

function TS3Disk.Get(const Path: string; out Data: string): Boolean;
var
  Status: Integer;
begin
  Data := Signed('GET', Path, '', '', Status);
  if Status = 404 then
  begin
    Data := '';
    Exit(False);
  end;
  if (Status < 200) or (Status > 299) then
    raise S3Error('read', Path, Status, Data);
  Result := True;
end;

function TS3Disk.Exists(const Path: string): Boolean;
var
  Status: Integer;
begin
  Signed('HEAD', Path, '', '', Status);
  if Status = 404 then
    Exit(False);
  if (Status < 200) or (Status > 299) then
    raise S3Error('look for', Path, Status, '');
  Result := True;
end;

procedure TS3Disk.Delete(const Path: string);
var
  Status: Integer;
  Body: string;
begin
  Body := Signed('DELETE', Path, '', '', Status);
  if ((Status < 200) or (Status > 299)) and (Status <> 404) then
    raise S3Error('delete', Path, Status, Body);
end;

function TS3Disk.Url(const Path: string): string;
begin
  Result := ObjectUrl(Path);
end;

function TS3Disk.TemporaryUrl(const Path: string; LifetimeSeconds: Integer): string;
begin
  { A week is the longest S3 takes. }
  if (LifetimeSeconds < 1) or (LifetimeSeconds > 604800) then
    raise EStorageError.Create('A presigned URL lasts from a second to a week');
  Result := S3PresignedUrl(ObjectUrl(Path), FRegion, FAccessKey, FSecret, AmzNow,
    LifetimeSeconds);
end;

function TS3Disk.Describe: string;
begin
  { Never the secret. }
  if FEndpoint <> '' then
    Result := 's3 (' + FBucket + ' at ' + FEndpoint + ')'
  else
    Result := 's3 (' + FBucket + ', ' + FRegion + ')';
end;

function StorageFromConfig: TStorageDisk;
var
  Name_: string;
begin
  Name_ := LowerCase(Cfg('storage.disk', 'local'));
  if Name_ = 'local' then
    Exit(TLocalDisk.Create(Cfg('storage.root', 'storage/app'), Cfg('storage.url', '/storage')));
  if Name_ = 's3' then
    Exit(TS3Disk.Create(Cfg('s3.bucket', ''), Cfg('s3.region', ''), Cfg('s3.key', ''),
      Cfg('s3.secret', ''), Cfg('s3.endpoint', '')));
  raise EStorageError.CreateFmt('storage.disk is "%s", and the disks are local and s3', [Name_]);
end;

{ ------------------------------------------------ signed local files -- }

type
  TStoredFiles = class
    Disk: TLocalDisk;
    Prefix: string;
    function Serve(Req: TRequest): TResponse;
  end;

var
  GStoredFiles: TStoredFiles = nil;

function DecodePath(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if (S[I] = '%') and (I + 2 <= Length(S)) then
    begin
      Result := Result + Chr(StrToIntDef('$' + Copy(S, I + 1, 2), Ord('?')));
      Inc(I, 3);
    end
    else
    begin
      Result := Result + S[I];
      Inc(I);
    end;
  end;
end;

function TStoredFiles.Serve(Req: TRequest): TResponse;
var
  Raw, Path, Data: string;
begin
  Result := nil;
  Raw := Req.RawPath.ToString;
  if Copy(Raw, 1, Length(Prefix) + 1) <> Prefix + '/' then
    Exit;
  case CheckSignature(Req) of
    scExpired: Exit(ErrorResponse(410, 'This link has expired'));
    scInvalid: Exit(ErrorResponse(403));
    scValid: ;
  end;
  Path := DecodePath(Copy(Raw, Length(Prefix) + 2, MaxInt));
  try
    if not Disk.Get(Path, Data) then
      Exit(ErrorResponse(404));
  except
    on EStorageError do
      Exit(ErrorResponse(404));
  end;
  Result := Respond(200).WithBody(Data)
    .WithContentType(ContentTypeForExt(ExtractFileExt(Path)))
    { The link is the permission; a shared cache must not keep it. }
    .WithHeader('Cache-Control', 'private, no-store');
end;

procedure UseStoredFiles(R: TRouter; Disk: TLocalDisk; const Prefix: string);
begin
  if GStoredFiles = nil then
    GStoredFiles := TStoredFiles.Create;
  GStoredFiles.Disk := Disk;
  GStoredFiles.Prefix := Prefix;
  Disk.FSignedPrefix := Prefix;
  R.Use(GStoredFiles.Serve);
end;

end.
