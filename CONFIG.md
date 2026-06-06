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
| Data dir | `--data-dir` | `ORCH_DATA` | `data_dir` | `<state>/data` |
| Runtime | `--runtime` | `ORCH_RUNTIME` | `runtime` | `bare` |
| Platform | `--platform` | `ORCH_PLATFORM` | `platform` | auto (launchd on macOS, else systemd) |
| Namespace | `--namespace` | `ORCH_NAMESPACE` | `namespace` | `orch` |
| Scope | `--user` / `--system` | `ORCH_SCOPE` | `scope` | `system` |

Project dir has no `.orchrc` layer because `.orchrc` itself is found inside the
project dir.

## What they mean

- **Namespace**: the prefix stamped on every generated name (`orch-web.service`,
  `orch.target`). Lets separate stacks live on one machine. `survey` and `fell`
  match by this prefix.
- **Scope**: who runs the services and where they install. `user` installs to
  `~/Library/LaunchAgents` (macOS) or `~/.config/systemd/user` (Linux) and runs
  as you, no root. `system` installs to `/Library/LaunchDaemons` or
  `/etc/systemd/system`, runs at boot, needs root.
- **State dir**: orchd's working folder. It writes generated files to
  `<state>/units`, `<state>/supervise`, and `<state>/data`, then installs them
  into the scope's directory.

## `.orchrc`

A plain `KEY=value` file, one per line, `#` for comments. Searched in the project
dir first, then `$HOME`. The first file found wins (no merging between files).

```
runtime=apple
namespace=myapp
state_dir=/var/lib/myapp
```

## Alignment with the Orch spec

orchd reuses the [Orch spec](https://github.com/adiled/orch)'s built-in variable
names, so one name flows from your shell all the way into the Orchfile:

```
shell:     ORCH_DATA=/srv/data
  -> orchd config: data_dir = /srv/data
  -> passed to the parser as: ARG ORCH_DATA=/srv/data
  -> in your Orchfile: VOLUME ${ORCH_DATA}/pg:/data  ->  /srv/data/pg
```

`ORCH_PROJECT`, `ORCH_DATA`, and `ORCH_STATE_DIR` match the spec's `${ORCH_PROJECT}`,
`${ORCH_DATA}`, `${ORCH_STATE_DIR}`. This is separate from the parser's
`ORCH_ARG_<name>` convention, which overrides an Orchfile `ARG`.
