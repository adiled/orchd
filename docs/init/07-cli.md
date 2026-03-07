# 07 - CLI Design

## Overview

orchd provides a single binary with subcommands modeled after familiar patterns (`docker compose`, `systemctl`). Built with `clap` derive API.

## Subcommands

```
orchd <command> [options]

Commands:
  generate               Generate platform artifacts from Orchfile
  up [services...]       Generate artifacts and start services
  down [services...]     Stop services
  restart [services...]  Restart services
  status                 Show status of all managed services
  logs <service>         Tail logs for a service
  health [--timeout]     Wait for all enabled services to be healthy
  list                   List all services defined in Orchfile
  clean                  Remove all generated artifacts and stop services
  help                   Show help
```

## Global Flags

```
Options:
  --orchfile <path>       Path to Orchfile (default: ./Orchfile)
  --overlay <path>        Overlay file (repeatable)
  --runtime <name>        Runtime: bare, containerd, podman, apple
  --platform <name>       Platform: systemd, launchd
  --state-dir <path>      State directory (default: ~/.orch)
  --project-dir <path>    Project root directory
  --data-dir <path>       Data directory for service storage
  --orch-bin <path>       Path to orch parser binary
  --namespace <name>      Namespace for isolation
  --arg <key=value>       Pass-through arg to orch parse (repeatable)
  --verbose               Verbose output
  --quiet                 Suppress non-error output
  --help                  Show help
  --version               Show version
```

## Subcommand Details

### `orchd generate`

Generate platform artifacts without starting services.

```
orchd generate [--force]

Options:
  --force    Regenerate even if artifacts exist and Orchfile hasn't changed
```

Pipeline:
1. Load config
2. Call `orch parse <orchfile> [overlays...] [--args...]`
3. Deserialize JSON
4. Call `runtime.check()` and `runtime.prepare()` for container services
5. Build ExecSets
6. Call `platform.generate()`
7. Call `platform.install()` (symlink + daemon-reload)

### `orchd up [services...]`

Generate and start services. If no services specified, starts all enabled.

```
orchd up [services...] [--no-generate] [--health-timeout <duration>]

Options:
  --no-generate       Skip generation (use existing artifacts)
  --health-timeout    Wait for health after start (0 = don't wait, default: 0)
```

Pipeline:
1. `orchd generate` (unless `--no-generate`)
2. `platform.stop()` any currently running managed services
3. `platform.start(services)` or `platform.start([])` for all enabled
4. If `--health-timeout` > 0: `platform.health(timeout)`

### `orchd down [services...]`

Stop services. If no services specified, stops all managed services.

```
orchd down [services...]
```

Pipeline:
1. Load config
2. `platform.stop(services)`

### `orchd restart [services...]`

Stop then start services.

```
orchd restart [services...]
```

Pipeline:
1. `orchd down [services...]`
2. `orchd up [services...]`

### `orchd status`

Show status table for all managed services.

```
orchd status [--json]

Options:
  --json    Output as JSON instead of table
```

Output (table):
```
SERVICE          TYPE        STATUS      PID
-------          ----        ------      ---
postgres         host        running     1234
redis            host        running     1235
django           host        running     1240
celery           host        running     1241
celery-beat      host        stopped     -
frontend         host        disabled    -
```

Output (JSON):
```json
[
  {"name": "postgres", "mode": "host", "state": "running", "pid": 1234},
  {"name": "redis", "mode": "host", "state": "running", "pid": 1235}
]
```

### `orchd logs <service>`

Tail logs for a service.

```
orchd logs <service> [--follow] [--lines <n>]

Options:
  --follow    Follow log output (default: true)
  --lines     Number of lines to show initially (default: 100)
```

Delegates to platform:
- systemd: `journalctl -u orch-<service>.service`
- launchd: `tail -f ${state_dir}/logs/<service>.log`

### `orchd health`

Wait for all enabled services to pass healthchecks.

```
orchd health [--timeout <duration>] [--verbose]

Options:
  --timeout    Maximum wait time (default: 60s)
  --verbose    Show per-service health details
```

Exit codes:
- 0: all healthy
- 1: timeout or failures

### `orchd list`

List all services defined in the Orchfile.

```
orchd list [--enabled] [--disabled] [--json]

Options:
  --enabled     Show only enabled services
  --disabled    Show only disabled services
  --json        Output as JSON
```

Output:
```
Enabled:
  postgres (host)
  redis (host)
  django (host)

Disabled:
  voice (host)
  storybook (host)
```

### `orchd clean`

Remove all generated artifacts and stop managed services.

```
orchd clean [--keep-data]

Options:
  --keep-data    Don't remove data directories
```

Pipeline:
1. `platform.stop([])` -- stop all
2. `platform.clean()` -- remove units/plists, unlink, daemon-reload
3. `runtime.cleanup()` for each service
4. Remove `${state_dir}/units/` (unless `--keep-data`)

## clap Derive Structure

```rust
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "orchd", about = "Orch execution engine")]
pub struct Cli {
    #[command(subcommand)]
    pub command: Commands,

    #[arg(long)]
    pub orchfile: Option<PathBuf>,

    #[arg(long, action = clap::ArgAction::Append)]
    pub overlay: Vec<PathBuf>,

    #[arg(long)]
    pub runtime: Option<String>,

    #[arg(long)]
    pub platform: Option<String>,

    #[arg(long)]
    pub state_dir: Option<PathBuf>,

    #[arg(long)]
    pub project_dir: Option<PathBuf>,

    #[arg(long)]
    pub data_dir: Option<PathBuf>,

    #[arg(long)]
    pub orch_bin: Option<PathBuf>,

    #[arg(long)]
    pub namespace: Option<String>,

    #[arg(long = "arg", action = clap::ArgAction::Append)]
    pub args: Vec<String>,

    #[arg(long, short)]
    pub verbose: bool,

    #[arg(long, short)]
    pub quiet: bool,
}

#[derive(Subcommand)]
pub enum Commands {
    Generate {
        #[arg(long)]
        force: bool,
    },
    Up {
        services: Vec<String>,
        #[arg(long)]
        no_generate: bool,
        #[arg(long)]
        health_timeout: Option<String>,
    },
    Down {
        services: Vec<String>,
    },
    Restart {
        services: Vec<String>,
    },
    Status {
        #[arg(long)]
        json: bool,
    },
    Logs {
        service: String,
        #[arg(long, default_value = "true")]
        follow: bool,
        #[arg(long, short = 'n', default_value = "100")]
        lines: u32,
    },
    Health {
        #[arg(long, default_value = "60s")]
        timeout: String,
        #[arg(long, short)]
        verbose: bool,
    },
    List {
        #[arg(long)]
        enabled: bool,
        #[arg(long)]
        disabled: bool,
        #[arg(long)]
        json: bool,
    },
    Clean {
        #[arg(long)]
        keep_data: bool,
    },
}
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Runtime error (service failure, health timeout, etc.) |
| 2 | Usage error (bad arguments, missing file) |
| 3 | Configuration error (invalid config, missing orch binary) |

## Execution Flow (Full Pipeline)

```
main()
  |
  +-- parse CLI (clap)
  |
  +-- Config::load(cli)
  |     +-- merge CLI > env > .orchrc > user config > defaults
  |     +-- auto-detect platform
  |     +-- validate
  |
  +-- resolve runtime (bare / containerd / ...)
  +-- resolve platform (systemd / launchd / ...)
  |
  +-- runtime.check()
  +-- platform.check()
  |
  +-- match command:
        Generate => engine::generate(config, runtime, platform)
        Up       => engine::up(config, runtime, platform, services)
        Down     => engine::down(config, platform, services)
        Status   => engine::status(config, platform)
        ...
```
