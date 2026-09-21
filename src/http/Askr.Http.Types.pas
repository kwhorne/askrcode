{ Askr.Http.Types — methods, status codes and URL encoding.

  No proper nouns in the HTTP layer, as the PRD says. Everything here is
  plain values and stateless functions, so both the server and the
  desktop shell can use them without dragging a host along. }
unit Askr.Http.Types;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Askr.Core.Arena, Askr.Core.Text;

type
  THttpMethod = (
    hmUnknown, hmGet, hmHead, hmPost, hmPut, hmPatch, hmDelete, hmOptions
  );

  THttpHeader = record
    Name: TStr;
    Value: TStr;
  end;
  PHttpHeader = ^THttpHeader;

const
  { Limits the parser enforces. A request that breaks them is refused with
    431 or 413 rather than being allowed to blow the arena up. }
  MaxRequestLineBytes = 8 * 1024;
  MaxHeaderBytes      = 32 * 1024;
  MaxHeaderCount      = 100;
  DefaultMaxBodyBytes = 8 * 1024 * 1024;

function MethodFromStr(const S: TStr): THttpMethod;
function MethodName(M: THttpMethod): string;

{ The default reason for a status code. Unknown codes get an empty
  string, and the server then writes only the number — which is legal in
  HTTP/1.1. }
function StatusText(Code: Integer): string;

{ Percent decoding. '+' is read as a space only when PlusAsSpace is set,
  that is for the query and for forms, not for path segments.
  Returns a slice in the arena. With nothing to decode, the input is
  returned unchanged and uncopied. }
function UrlDecode(A: TArena; const S: TStr; PlusAsSpace: Boolean = False): TStr;

{ Henter én verdi fra en application/x-www-form-urlencoded-streng. }
function QueryValue(A: TArena; const QueryString: TStr; const Name: string;
  out Value: TStr): Boolean;

implementation

function MethodFromStr(const S: TStr): THttpMethod;
begin
  { Method names are case-sensitive in HTTP, so we compare exactly. }
  case S.Len of
    3: if S.EqualsStr('GET') then Exit(hmGet)
       else if S.EqualsStr('PUT') then Exit(hmPut);
    4: if S.EqualsStr('POST') then Exit(hmPost)
       else if S.EqualsStr('HEAD') then Exit(hmHead);
    5: if S.EqualsStr('PATCH') then Exit(hmPatch);
    6: if S.EqualsStr('DELETE') then Exit(hmDelete);
    7: if S.EqualsStr('OPTIONS') then Exit(hmOptions);
  end;
  Result := hmUnknown;
end;

function MethodName(M: THttpMethod): string;
begin
  case M of
    hmGet:     Result := 'GET';
    hmHead:    Result := 'HEAD';
    hmPost:    Result := 'POST';
    hmPut:     Result := 'PUT';
    hmPatch:   Result := 'PATCH';
    hmDelete:  Result := 'DELETE';
    hmOptions: Result := 'OPTIONS';
  else
    Result := '';
  end;
end;

function StatusText(Code: Integer): string;
begin
  case Code of
    200: Result := 'OK';
    201: Result := 'Created';
    202: Result := 'Accepted';
    204: Result := 'No Content';
    301: Result := 'Moved Permanently';
    302: Result := 'Found';
    303: Result := 'See Other';
    304: Result := 'Not Modified';
    307: Result := 'Temporary Redirect';
    308: Result := 'Permanent Redirect';
    400: Result := 'Bad Request';
    401: Result := 'Unauthorized';
    403: Result := 'Forbidden';
    404: Result := 'Not Found';
    405: Result := 'Method Not Allowed';
    408: Result := 'Request Timeout';
    409: Result := 'Conflict';
    413: Result := 'Content Too Large';
    414: Result := 'URI Too Long';
    415: Result := 'Unsupported Media Type';
    419: Result := 'Page Expired';
    422: Result := 'Unprocessable Content';
    429: Result := 'Too Many Requests';
    431: Result := 'Request Header Fields Too Large';
    500: Result := 'Internal Server Error';
    501: Result := 'Not Implemented';
    503: Result := 'Service Unavailable';
    505: Result := 'HTTP Version Not Supported';
  else
    Result := '';
  end;
end;

function HexVal(B: Byte; out V: Byte): Boolean; inline;
begin
  case B of
    Ord('0')..Ord('9'): V := B - Ord('0');
    Ord('a')..Ord('f'): V := B - Ord('a') + 10;
    Ord('A')..Ord('F'): V := B - Ord('A') + 10;
  else
    V := 0;
    Exit(False);
  end;
  Result := True;
end;

function NeedsDecode(const S: TStr; PlusAsSpace: Boolean): Boolean;
var
  I: SizeInt;
  B: Byte;
begin
  for I := 0 to S.Len - 1 do
  begin
    B := (S.Data + I)^;
    if (B = Ord('%')) or (PlusAsSpace and (B = Ord('+'))) then
      Exit(True);
  end;
  Result := False;
end;

function UrlDecode(A: TArena; const S: TStr; PlusAsSpace: Boolean): TStr;
var
  I, O: SizeInt;
  B, H, L: Byte;
  Dst: PByte;
begin
  if (S.Len = 0) or not NeedsDecode(S, PlusAsSpace) then
    Exit(S);

  Dst := PByte(A.Alloc(S.Len));
  I := 0;
  O := 0;
  while I < S.Len do
  begin
    B := (S.Data + I)^;
    if (B = Ord('%')) and (I + 2 < S.Len) and
       HexVal((S.Data + I + 1)^, H) and HexVal((S.Data + I + 2)^, L) then
    begin
      (Dst + O)^ := (H shl 4) or L;
      Inc(I, 3);
    end
    else if PlusAsSpace and (B = Ord('+')) then
    begin
      (Dst + O)^ := Ord(' ');
      Inc(I);
    end
    else
    begin
      { An invalid % sequence is kept as it stands. Refusing the request here
        would make the parser stricter than the browsers. }
      (Dst + O)^ := B;
      Inc(I);
    end;
    Inc(O);
  end;
  Result := StrRef(Dst, O);
end;

function QueryValue(A: TArena; const QueryString: TStr; const Name: string;
  out Value: TStr): Boolean;
var
  Rest, Pair, K, V: TStr;
begin
  Value := StrEmpty;
  Rest := QueryString;
  while Rest.Len > 0 do
  begin
    { The last pair has no '&' after it. SplitAt then gives the whole
      remainder as Pair and empties Rest, which is exactly what the loop
      needs. }
    Rest.SplitAt(Ord('&'), Pair, Rest);
    if Pair.Len = 0 then
      Continue;
    if not Pair.SplitAt(Ord('='), K, V) then
      V := StrEmpty;
    if UrlDecode(A, K, True).EqualsStr(Name) then
    begin
      Value := UrlDecode(A, V, True);
      Exit(True);
    end;
  end;
  Result := False;
end;

end.
