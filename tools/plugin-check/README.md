# The plugin gate's fixtures

`./askr plugin:check` copies these into a git repository of its own inside
the container, tags them, and drives a new app through adding, building,
migrating, serving and removing them. They are here, in the repository,
rather than written by the gate, because a file written on the host just
before a container reads it can read as empty there.

- `hello` is a plugin with a route, a command, a migration under its own
  name and a page of docs.
- `other` claims the table `hello` owns, so the build has something to
  refuse.
