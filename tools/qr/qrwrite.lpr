{ Writes QR codes for ./askr qr:check to read back in Chrome: every level,
  lengths from a few bytes to what version 40 holds, the mask chosen by the
  penalty score as it is in use. Each case is <n>.svg and a line in
  cases.txt: n|level|version|the text as hex. }
program QrWrite;

{$mode Delphi}{$H+}

uses
  SysUtils, Classes, Askr.Qr;

const
  Levels: array[TQrEcc] of string = ('L', 'M', 'Q', 'H');
  { What it is for, and text outside ASCII. }
  Extra: array[0..1] of string = (
    'otpauth://totp/My%20Shop:ada@example.com?secret=JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP&issuer=My%20Shop&algorithm=SHA1&digits=6&period=30',
    'blåbærsyltetøy fra Ås');
  { Bytes at each level that land on versions across the range, the last
    the most version 40 holds. }
  Lengths: array[TQrEcc, 0..9] of Integer = (
    (5, 32, 78, 154, 321, 586, 929, 1370, 1990, 2953),
    (5, 26, 62, 122, 251, 461, 732, 1066, 1528, 2331),
    (5, 20, 46, 86, 177, 331, 520, 772, 1093, 1663),
    (5, 14, 34, 64, 142, 253, 400, 604, 868, 1273));

var
  Dir, Text_, Hex: string;
  Cases, F: TStringList;
  E: TQrEcc;
  I, J, N, Seed: Integer;
  Q: TQrCode;
begin
  Dir := ParamStr(1);
  ForceDirectories(Dir);
  Cases := TStringList.Create;
  F := TStringList.Create;
  try
    N := 0;
    Seed := 12345;
    for E := Low(TQrEcc) to High(TQrEcc) do
      for I := 0 to 9 do
      begin
        Text_ := '';
        for J := 1 to Lengths[E, I] do
        begin
          Seed := (Seed * 1103515245 + 12345) and $7FFFFFFF;
          Text_ := Text_ + Chr(33 + (Seed shr 16) mod 94);
        end;
        Q := QrEncode(Text_, E);
        Inc(N);
        F.Text := QrSvg(Q);
        F.SaveToFile(Dir + '/' + IntToStr(N) + '.svg');
        Hex := '';
        for J := 1 to Length(Text_) do
          Hex := Hex + LowerCase(IntToHex(Ord(Text_[J]), 2));
        Cases.Add(Format('%d|%s|%d|%s', [N, Levels[E], Q.Version, Hex]));
      end;
    for I := 0 to High(Extra) do
    begin
      Text_ := Extra[I];
      Q := QrEncode(Text_, qrMedium);
      Inc(N);
      F.Text := QrSvg(Q);
      F.SaveToFile(Dir + '/' + IntToStr(N) + '.svg');
      Hex := '';
      for J := 1 to Length(Text_) do
        Hex := Hex + LowerCase(IntToHex(Ord(Text_[J]), 2));
      Cases.Add(Format('%d|M|%d|%s', [N, Q.Version, Hex]));
    end;
    Cases.SaveToFile(Dir + '/cases.txt');
  finally
    F.Free;
    Cases.Free;
  end;
end.
