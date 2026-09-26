{ Askr.Core.Mime — the content type a file name says it has.

  One table, for everything that sends a file: the static file server and
  a mail attachment. Two tables would give a PDF one type on the site and
  another in a mail, and the first sign would be a download that opens in
  the wrong program. }
unit Askr.Core.Mime;

{$mode Delphi}{$H+}

interface

{ The type for an extension, with its dot: '.pdf'. Unknown is
  application/octet-stream, which every client treats as "save it". }
function ContentTypeForExt(const Ext: string): string;

implementation

uses
  SysUtils;

function ContentTypeForExt(const Ext: string): string;
var
  E: string;
begin
  E := LowerCase(Ext);
  if (E = '.html') or (E = '.htm') then Exit('text/html; charset=utf-8');
  if E = '.js' then Exit('text/javascript; charset=utf-8');
  if E = '.mjs' then Exit('text/javascript; charset=utf-8');
  if E = '.css' then Exit('text/css; charset=utf-8');
  if E = '.json' then Exit('application/json');
  if E = '.svg' then Exit('image/svg+xml');
  if E = '.png' then Exit('image/png');
  if (E = '.jpg') or (E = '.jpeg') then Exit('image/jpeg');
  if E = '.webp' then Exit('image/webp');
  if E = '.gif' then Exit('image/gif');
  if E = '.ico' then Exit('image/x-icon');
  if E = '.woff2' then Exit('font/woff2');
  if E = '.woff' then Exit('font/woff');
  if E = '.map' then Exit('application/json');
  if E = '.txt' then Exit('text/plain; charset=utf-8');
  if E = '.wasm' then Exit('application/wasm');
  if E = '.pdf' then Exit('application/pdf');
  if E = '.csv' then Exit('text/csv; charset=utf-8');
  if E = '.xml' then Exit('application/xml');
  if E = '.zip' then Exit('application/zip');
  if E = '.ics' then Exit('text/calendar; charset=utf-8');
  if E = '.md' then Exit('text/markdown; charset=utf-8');
  if E = '.docx' then
    Exit('application/vnd.openxmlformats-officedocument.wordprocessingml.document');
  if E = '.xlsx' then
    Exit('application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
  if E = '.pptx' then
    Exit('application/vnd.openxmlformats-officedocument.presentationml.presentation');
  if E = '.odt' then Exit('application/vnd.oasis.opendocument.text');
  if E = '.ods' then Exit('application/vnd.oasis.opendocument.spreadsheet');
  Result := 'application/octet-stream';
end;

end.
