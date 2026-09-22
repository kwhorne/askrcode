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

end.
