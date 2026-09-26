{ ./askr storage:check's other half: Askr.Storage's S3 disk against a real
  S3 server -- the Versity gateway, which checks every signature it is
  sent. The bucket is made with the same signer, so even the setup is a
  test of it. }
program S3Probe;

{$mode Delphi}{$H+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  SysUtils, DateUtils, Askr.Core.Crypto, Askr.Http.Client, Askr.Storage;

var
  Endpoint, Key, Secret: string;
  Fails: Integer = 0;

procedure Check(Ok: Boolean; const What: string);
begin
  if Ok then
    WriteLn('  ok    ', What)
  else
  begin
    WriteLn('  FAIL  ', What);
    Inc(Fails);
  end;
end;

function AllBytes: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to 1023 do
    Result := Result + Chr(I mod 256);
end;

var
  Disk, Wrong: TS3Disk;
  C: THttpClient;
  R: THttpResponse;
  Data, Link, Date_, Hash_, Msg: string;
begin
  Endpoint := ParamStr(1);
  Key := ParamStr(2);
  Secret := ParamStr(3);

  { The bucket, with a PUT signed by hand through the same function. }
  Date_ := FormatDateTime('yyyymmdd"T"hhnnss"Z"', LocalTimeToUniversal(Now));
  Hash_ := Sha256Hex('');
  C := THttpClient.Create;
  try
    C.WithHeader('x-amz-date', Date_);
    C.WithHeader('x-amz-content-sha256', Hash_);
    C.WithHeader('Authorization', S3Authorization('PUT', Endpoint + '/assets', 'us-east-1',
      Key, Secret, Hash_, Date_));
    R := C.Request('PUT', Endpoint + '/assets', '', '');
    Check(R.Status = 200, 'the bucket is made with a PUT this signer signed (' + IntToStr(R.Status) + ')');
  finally
    C.Free;
  end;

  Disk := TS3Disk.Create('assets', 'us-east-1', Key, Secret, Endpoint);
  Wrong := TS3Disk.Create('assets', 'us-east-1', Key, Secret + 'x', Endpoint);
  try
    Disk.Put('hello.txt', 'Hello, S3');
    Check(Disk.Get('hello.txt', Data) and (Data = 'Hello, S3'), 'a file goes in and comes back');
    Disk.Put('photos/ferie på Ås.jpg', AllBytes);
    Check(Disk.Get('photos/ferie på Ås.jpg', Data) and (Data = AllBytes),
      'every byte of a binary file, under a key with spaces and letters outside ASCII');
    Disk.Put('a+b=c&d e.txt', 'plus');
    Check(Disk.Get('a+b=c&d e.txt', Data) and (Data = 'plus'), 'and a key with + = & in it');
    Check(Disk.Exists('hello.txt'), 'HEAD finds it');
    Check(not Disk.Exists('nothing.txt'), 'and not one that is not there');
    Check(not Disk.Get('nothing.txt', Data), 'which Get gives as False');

    Link := Disk.TemporaryUrl('photos/ferie på Ås.jpg', 60);
    C := THttpClient.Create;
    try
      R := C.Get(Link);
      Check((R.Status = 200) and (R.Body = AllBytes), 'a presigned URL opens the file with no key at all');
      R := C.Get(StringReplace(Link, 'X-Amz-Expires=60', 'X-Amz-Expires=61', []));
      Check(R.Status = 403, 'and one with its expiry changed does not (' + IntToStr(R.Status) + ')');
      R := C.Get(Disk.Url('photos/ferie på Ås.jpg'));
      Check(R.Status = 403, 'nor does the plain URL of a private file');
    finally
      C.Free;
    end;

    Msg := '';
    try
      Wrong.Put('hello.txt', 'overwritten');
    except
      on E: EStorageError do Msg := E.Message;
    end;
    Check(Pos('403', Msg) > 0, 'the wrong secret is refused: ' + Msg);
    Check((Pos(Secret, Msg) = 0), 'and the message does not carry the secret');
    Check(Disk.Get('hello.txt', Data) and (Data = 'Hello, S3'), 'and nothing was overwritten');

    Disk.Delete('hello.txt');
    Check(not Disk.Exists('hello.txt'), 'a deleted file is gone');
    Disk.Delete('hello.txt');
    Check(True, 'and deleting it again is not an error');
  finally
    Wrong.Free;
    Disk.Free;
  end;
  if Fails > 0 then
    Halt(1);
end.
