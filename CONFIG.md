# Configuration

Every setting resolves through four layers. The first one that has a value wins:

```
CLI flag   >   env var   >   .orchrc   >   default
```

## Settings

| Setting | CLI flag | Env var | `.orchrc` key | Default |
|---------|----------|---------|---------------|---------|
| Project dir | `--project-dir` | `ORCH_PROJECT` | (n/a) | current directory |
| Orchfile | `--orchfile` | `ORCH_ORCHFILE` | `orchfile` | `<project>/Orchfile` |
| State dir | `--state-dir` | `ORCH_STATE_DIR` | `state_dir` | `~/.orch` |
| Data dir | `--data-dir` | `ORCH_DATA` | `data_dir` | `<state>/data/<grove>` |
| Rootstock | `--rootstock` | `ORCH_ROOTSTOCK` | `rootstock` | `bare` |
| Platform | `--platform` | `ORCH_PLATFORM` | `platform` | auto (launchd on macOS, else systemd) |
| Grove | `--grove` | `ORCH_GROVE` | `grove` | `orch` |
| Scope | `--user` / `--system` | `ORCH_SCOPE` | `scope` | `system` |

Project dir has no `.orchrc` layer because `.orchrc` itself is found inside the
project dir.

A path setting (project dir, Orchfile, overlays, state dir, data dir) may start
with `~`, read as `$HOME`, in any layer: `state_dir=~/.orch/g/shop` in `.orchrc`
means the same as `--state-dir ~/.orch/g/shop` in a shell.

## What they mean

- **Grove**: the prefix stamped on every generated name (`orch-web.service`,
  `orch.target`). Lets separate stacks live on one machine. `survey` and `fell`
  match by this prefix.
- **Scope**: who runs the services and where they install. `user` installs to
  `~/Library/LaunchAgents` (macOS) or `~/.config/systemd/user` (Linux) and runs
  as you, no root. `system` installs to `/Library/LaunchDaemons` or
  `/etc/systemd/system`, runs at boot, needs root.
- **State dir**: orchd's working folder. It writes generated files to
  `<state>/units`, `<state>/supervise`, and `<state>/data/<grove>`, then installs
  them into the scope's directory. launchd services log to `<state>/logs` unless
  the Orchfile sets `STDOUT`/`STDERR`.

## `.orchrc`

A plain `KEY=value` file, one per line, `#` for comments. Searched in the project
dir first, then `$HOME`. The first file found wins (no merging between files).

```
rootstock=apple
grove=myapp
state_dir=/var/lib/myapp
```

## Values orchd hands the Orchfile

orchd passes two of its settings to the parser as ARG overrides, the way the
[Orch spec](https://github.com/adiled/orch/blob/main/SPEC.md#arg) has a runtime
supply values:

| ARG | Value |
|-----|-------|
| `ORCH_PROJECT` | the project dir |
| `ORCH_DATA` | the data dir |

An Orchfile uses one by declaring it with a default, so it still resolves on its
own:

```
ARG ORCH_DATA=~/.orch/data

SERVICE db
FROM postgres:16
VOLUME ${ORCH_DATA}/pg:/var/lib/postgresql/data
```

Under orchd the volume lands in the grove's data dir; under a plain `orch resolve`
it takes the default. An Orchfile that declares neither is untouched. Your own
`--arg` or `ORCH_ARG_<name>` for the same name wins over orchd's.

## Paths

The spec has every path be absolute or start with `~`. orchd reads `~` as the
home of the user the service runs as:

- a host service: its `USER`, or else the user orchd runs as;
- a container service's host side (volume sources, env files, logs): the user
  orchd runs as.

Inside a container orchd cannot know the image's home, so a container's
`WORKDIR` or `VOLUME` destination under `~` is refused; write those absolute.

To point at the project's own files, use `${ORCH_PROJECT}`:

```
ARG ORCH_PROJECT=~/code/shop

SERVICE web
FROM nginx:alpine
VOLUME ${ORCH_PROJECT}/site:/usr/share/nginx/html:ro
```
