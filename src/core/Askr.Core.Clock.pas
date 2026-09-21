{ Askr.Core.Clock — time in UTC, with no dependency on time-zone setup.

  HTTP requires a Date header in RFC 9110 format. The usual date routines
  in Pascal go by way of local time and the time-zone database; here epoch
  seconds are converted to a calendar date with plain arithmetic, so the
  result is UTC by definition and costs the same on every platform.

  The formatted date is cached per thread per second. A server taking
  thousands of requests a second then formats the date once, not once per
  response. }
unit Askr.Core.Clock;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Askr.Core.Text;

{ Sekunder siden 1970-01-01T00:00:00Z. }
function UnixNow: Int64;
{ Milliseconds since the epoch. The same clock as the file system's mtime,
  so the two can be subtracted from one another — MonotonicMs cannot. }
function UnixNowMs: Int64;
{ A monotonic reading in milliseconds, for timeouts and measurement. }
function MonotonicMs: Int64;

{ 'Sun, 06 Nov 1994 08:49:37 GMT' — exactly 29 bytes. }
procedure AppendHttpDate(var B: TStrBuilder; Epoch: Int64);
procedure AppendHttpDateNow(var B: TStrBuilder);

{ ISO 8601 in UTC with milliseconds: 2026-09-20T08:11:12.345Z.

  Returns an ordinary string and needs no arena — it is called from the
  logger, which also runs at startup, from queue workers and from the
  scheduler, all places where there is no surrounding arena. UTC because a
  log that changes time zone twice a year cannot be sorted. }
function IsoTimestamp(EpochMs: Int64): string;
function IsoTimestampNow: string;

{ Now as a TDateTime, in UTC.

  `SysUtils.Now` gives local time. Two servers in different time zones
  would write different values for the same instant into a created_at, and
  a row made at 02:30 in the autumn would appear twice. The same reason
  the scheduler works in UTC. }
function UtcNow: TDateTime;

implementation

uses
{$IFDEF UNIX}
  BaseUnix, Unix;
{$ELSE}
  Windows;
{$ENDIF}

const
  DayNames: array[0..6] of string[3] =
    ('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat');
  MonthNames: array[1..12] of string[3] =
    ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
     'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec');

function UnixNow: Int64;
{$IFDEF UNIX}
var
  TV: TTimeVal;
begin
  fpGetTimeOfDay(@TV, nil);
  Result := TV.tv_sec;
end;
{$ELSE}
var
  FT: TFileTime;
  U: QWord;
begin
  GetSystemTimeAsFileTime(FT);
  U := (QWord(FT.dwHighDateTime) shl 32) or FT.dwLowDateTime;
  { FILETIME teller 100 ns siden 1601-01-01. }
  Result := Int64(U div 10000000) - 11644473600;
end;
{$ENDIF}

{$IFDEF UNIX}
const
  { CLOCK_MONOTONIC has a different value per kernel. Declared directly
    against libc rather than through the Linux unit, so macOS and BSD take
    the same code path. }
  ClockMonotonic = {$IFDEF DARWIN} 6 {$ELSE} 1 {$ENDIF};

function clock_gettime(ClockId: cint; TP: ptimespec): cint; cdecl;
  external 'c' name 'clock_gettime';
{$ENDIF}

function UnixNowMs: Int64;
{$IFDEF UNIX}
var
  TV: TTimeVal;
begin
  fpGetTimeOfDay(@TV, nil);
  Result := Int64(TV.tv_sec) * 1000 + TV.tv_usec div 1000;
end;
{$ELSE}
var
  FT: TFileTime;
  U: QWord;
begin
  GetSystemTimeAsFileTime(FT);
  U := (QWord(FT.dwHighDateTime) shl 32) or FT.dwLowDateTime;
  Result := Int64(U div 10000) - 11644473600000;
end;
{$ENDIF}

function MonotonicMs: Int64;
{$IFDEF UNIX}
var
  TS: TTimeSpec;
begin
  if clock_gettime(ClockMonotonic, @TS) = 0 then
    Result := Int64(TS.tv_sec) * 1000 + TS.tv_nsec div 1000000
  else
    Result := UnixNow * 1000;
end;
{$ELSE}
begin
  Result := Int64(GetTickCount64);
end;
{$ENDIF}

{ Howard Hinnant's civil_from_days: days since the epoch to
  year/month/day with no loops and no tables. Valid far beyond anything an
  HTTP server needs. }
procedure CivilFromDays(Z: Int64; out Y: Int64; out M, D: Word);
var
  Era, DoE, YoE, Doy, Mp: Int64;
begin
  Z := Z + 719468;
  if Z >= 0 then
    Era := Z div 146097
  else
    Era := (Z - 146096) div 146097;
  DoE := Z - Era * 146097;                                   { 0..146096 }
  YoE := (DoE - DoE div 1460 + DoE div 36524 - DoE div 146096) div 365;
  Y := YoE + Era * 400;
  Doy := DoE - (365 * YoE + YoE div 4 - YoE div 100);        { 0..365 }
  Mp := (5 * Doy + 2) div 153;                               { 0..11 }
  D := Word(Doy - (153 * Mp + 2) div 5 + 1);                 { 1..31 }
  if Mp < 10 then
    M := Word(Mp + 3)
  else
    M := Word(Mp - 9);
  if M <= 2 then
    Inc(Y);
end;

procedure Append2(var B: TStrBuilder; V: Integer); inline;
begin
  B.AppendByte(Ord('0') + Byte(V div 10));
  B.AppendByte(Ord('0') + Byte(V mod 10));
end;

procedure FormatHttpDate(var B: TStrBuilder; Epoch: Int64);
var
  Days, Secs, Y: Int64;
  M, D: Word;
  Dow, H, Mi, S: Integer;
begin
  Days := Epoch div 86400;
  Secs := Epoch mod 86400;
  if Secs < 0 then
  begin
    Dec(Days);
    Inc(Secs, 86400);
  end;

  { 1970-01-01 var en torsdag. }
  Dow := Integer((Days + 4) mod 7);
  if Dow < 0 then
    Inc(Dow, 7);

  CivilFromDays(Days, Y, M, D);
  H := Integer(Secs div 3600);
  Mi := Integer((Secs div 60) mod 60);
  S := Integer(Secs mod 60);

  B.Append(string(DayNames[Dow]));
  B.Append(', ');
  Append2(B, D);
  B.AppendByte(Ord(' '));
  B.Append(string(MonthNames[M]));
  B.AppendByte(Ord(' '));
  Append2(B, Integer(Y div 100));
  Append2(B, Integer(Y mod 100));
  B.AppendByte(Ord(' '));
  Append2(B, H);
  B.AppendByte(Ord(':'));
  Append2(B, Mi);
  B.AppendByte(Ord(':'));
  Append2(B, S);
  B.Append(' GMT');
end;

threadvar
  GCachedEpoch: Int64;
  GCachedDate: array[0..31] of Byte;
  GCachedLen: Integer;

procedure AppendHttpDate(var B: TStrBuilder; Epoch: Int64);
var
  Tmp: TStrBuilder;
  S: TStr;
begin
  if (GCachedLen > 0) and (GCachedEpoch = Epoch) then
  begin
    B.AppendBytes(@GCachedDate[0], GCachedLen);
    Exit;
  end;

  { Formats into the caller's arena and takes a copy for the thread cache. }
  Tmp.Init(B.Arena, 48);
  FormatHttpDate(Tmp, Epoch);
  S := Tmp.ToStr;
  if S.Len <= Length(GCachedDate) then
  begin
    Move(S.Data^, GCachedDate[0], S.Len);
    GCachedLen := S.Len;
    GCachedEpoch := Epoch;
  end;
  B.Append(S);
end;

procedure AppendHttpDateNow(var B: TStrBuilder);
begin
  AppendHttpDate(B, UnixNow);
end;


function IsoTimestamp(EpochMs: Int64): string;
var
  Days, Secs, Ms: Int64;
  Y: Int64;
  M, D: Word;
  T, Tim, Min_, S_: Int64;
begin
  Secs := EpochMs div 1000;
  Ms := EpochMs mod 1000;
  { A negative epoch — a date before 1970 — must not give negative times. }
  if Ms < 0 then
  begin
    Inc(Ms, 1000);
    Dec(Secs);
  end;
  if Secs >= 0 then
    Days := Secs div 86400
  else
    Days := (Secs - 86399) div 86400;
  T := Secs - Days * 86400;
  Tim := T div 3600;
  Min_ := (T div 60) mod 60;
  S_ := T mod 60;
  CivilFromDays(Days, Y, M, D);
  Result := Format('%.4d-%.2d-%.2dT%.2d:%.2d:%.2d.%.3dZ',
    [Y, M, D, Tim, Min_, S_, Ms]);
end;

function IsoTimestampNow: string;
begin
  Result := IsoTimestamp(UnixNowMs);
end;

function UtcNow: TDateTime;
begin
  { The Unix epoch as a TDateTime is 25569. Worked out here rather than
    pulling DateUtils into the clock. }
  Result := 25569 + UnixNow / 86400;
end;
end.
