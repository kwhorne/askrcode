{ Askr.Console.Commands — the names, in one place.

  Two programs need this list and they are different binaries. `Askr.Console`
  is compiled into the *application*, which is what actually runs a command;
  the `askr` tool has to know which words to forward to that application
  before it has asked it anything.

  It used to be written out twice, with a comment on the second copy saying
  it was a mirror of the first. The first command added after that comment
  was added to one of them, and `askr token:list` answered "Unknown
  command" from a tool that had the binary right there. A mirror with a
  note on it is still a mirror.

  Only the names and the help text live here. What a command *does* stays
  in `Askr.Console`, which is where the migrations, routes, jobs and
  schedule actually are. }
unit Askr.Console.Commands;

{$mode Delphi}{$H+}

interface

type
  TConsoleCommand = record
    Name_: string;
    Help: string;
  end;

const
  ConsoleCommands: array[0..26] of TConsoleCommand = (
    (Name_: 'about';            Help: 'what this app is configured with'),
    (Name_: 'routes';           Help: 'the routing table'),
    (Name_: 'migrate';          Help: 'run pending migrations'),
    (Name_: 'migrate:status';   Help: 'what has run and what has not'),
    (Name_: 'migrate:rollback'; Help: 'roll back the last batch (--step=N)'),
    (Name_: 'migrate:reset';    Help: 'roll back everything'),
    (Name_: 'migrate:fresh';    Help: 'drop all tables, then migrate (--seed)'),
    (Name_: 'migrate:refresh';  Help: 'reset, then migrate (--seed)'),
    (Name_: 'db:seed';          Help: 'run the seeders (--class=Name)'),
    (Name_: 'db:show';          Help: 'tables in the database'),
    (Name_: 'db:table';         Help: 'columns, indexes and keys of one table'),
    (Name_: 'db:wipe';          Help: 'drop every table (--force in production)'),
    (Name_: 'schema';           Help: 'generate typed columns from the database'),
    (Name_: 'schema:check';     Help: 'do the typed columns still describe the database'),
    (Name_: 'queue:work';       Help: 'run the queue until interrupted'),
    (Name_: 'queue:status';     Help: 'counters for the queue'),
    (Name_: 'schedule:list';    Help: 'the schedule'),
    (Name_: 'schedule:run';     Help: 'dispatch what is due, once'),
    (Name_: 'cache:clear';      Help: 'empty the cache'),
    (Name_: 'token:issue';      Help: 'mint an API token (--scopes=a,b [--days=N])'),
    (Name_: 'token:list';       Help: 'the API tokens one user has'),
    (Name_: 'token:revoke';     Help: 'revoke one token, or --user=<id> for all'),
    (Name_: 'openapi';          Help: 'the OpenAPI document (--check for drift)'),
    (Name_: 'down';             Help: 'maintenance mode on'),
    (Name_: 'up';               Help: 'maintenance mode off'),
    (Name_: 'env';              Help: 'the current environment'),
    (Name_: 'list';             Help: 'these commands'));

{ Is this a word the application answers to? Used by the tool to decide
  what to forward, and by the application to decide what to run. }
function IsConsoleCommand(const K: string): Boolean;

const
  { The words the askr tool answers to itself, before any app is asked.

    The tool routes by this list: a word on neither list goes to the
    app, for a command the app registered. So a tool command added
    without being listed here goes to the app and does not work -- which
    is noticed the first time it is run -- rather than an app's command
    of the same name being shadowed by the tool in silence. }
  ToolCommands: array[0..16] of string = (
    'build', 'config', 'help', 'install', 'key:generate', 'make', 'mcp',
    'mcp:install', 'new', 'outdated', 'repl', 'run', 'serve', 'test',
    'update', 'version', 'routes');

function IsToolCommand(const K: string): Boolean;

const
  { askr <word> for a word nothing answers to, from the tool and from the
    app alike. EX_USAGE, so a script can tell "no such command" from a
    command that ran and failed. }
  UnknownCommandExit = 64;

{ Why an app may not register a command by this name, or '' when it may:
  it is the tool's or the app's own, or it is not a word a command line
  can carry unquoted. }
function CommandNameProblem(const K: string): string;

implementation

function IsConsoleCommand(const K: string): Boolean;
var
  I: Integer;
begin
  for I := Low(ConsoleCommands) to High(ConsoleCommands) do
    if ConsoleCommands[I].Name_ = K then
      Exit(True);
  Result := False;
end;

function IsToolCommand(const K: string): Boolean;
var
  I: Integer;
begin
  for I := Low(ToolCommands) to High(ToolCommands) do
    if ToolCommands[I] = K then
      Exit(True);
  Result := False;
end;

function CommandNameProblem(const K: string): string;
var
  I: Integer;
begin
  if K = '' then
    Exit('A command needs a name.');
  if not (K[1] in ['a'..'z']) then
    Exit(K + ' has to start with a lower case letter.');
  for I := 1 to Length(K) do
    if not (K[I] in ['a'..'z', '0'..'9', ':', '-']) then
      Exit(K + ' may have lower case letters, digits, : and - in it, ' +
        'as invoices:send does.');
  if IsToolCommand(K) then
    Exit(K + ' is the askr tool''s own command. The tool answers it before ' +
      'the app is asked, so this one would never run.');
  if IsConsoleCommand(K) then
    Exit(K + ' is a command every Askr app has. Registering it again ' +
      'would change what askr ' + K + ' does in this app alone.');
  Result := '';
end;

end.
