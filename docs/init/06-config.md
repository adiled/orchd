# 06 - Configuration

## Overview

orchd loads configuration from multiple sources with a clear precedence order. Configuration determines which runtime and platform to use, where state is stored, and how orch is invoked.

## Precedence (highest to lowest)

1. **CLI flags** -- `--runtime bare`, `--platform systemd`, `--orchfile path`
2. **Environment variables** -- `ORCH_RUNTIME=bare`, `ORCH_PLATFORM=systemd`
3. **Project config** -- `.orchrc` in the project root (same directory as Orchfile)
4. **User config** -- `~/.config/orch/config`
5. **Auto-detection** -- platform from OS, runtime defaults to bare
6. **Built-in defaults**

## Configuration Keys

| Key | CLI flag | Env var | Default | Description |
|-----|----------|---------|---------|-------------|
| `runtime` | `--runtime` | `ORCH_RUNTIME` | `bare` | Runtime plugin: bare, containerd, podman, apple |
| `platform` | `--platform` | `ORCH_PLATFORM` | auto-detect | Platform plugin: systemd, launchd |
| `orchfile` | `--orchfile` | `ORCHFILE` | `./Orchfile` | Path to base Orchfile |
| `overlays` | `--overlay` (repeatable) | `ORCH_OVERLAYS` | (none) | Comma-separated overlay file paths |
| `orch_bin` | `--orch-bin` | `ORCH_BIN` | `orch` | Path to orch parser binary |
| `state_dir` | `--state-dir` | `ORCH_STATE_DIR` | `~/.orch` | State directory for generated artifacts |
| `project_dir` | `--project-dir` | `ORCH_PROJECT_DIR` | parent of Orchfile | Project root directory |
| `data_dir` | `--data-dir` | `ORCH_DATA_DIR` | `${state_dir}/data` | Data directory for service storage |
| `unit_prefix` | -- | `ORCH_UNIT_PREFIX` | `orch` | Prefix for generated unit/plist names |
| `systemd_scope` | -- | `ORCH_SYSTEMD_SCOPE` | `system` | systemd scope: system or user |
| `namespace` | `--namespace` | `ORCH_NAMESPACE` | (none) | Namespace for isolation (affects state_dir, prefix) |

## Config File Format

`.orchrc` and `~/.config/orch/config` use simple `KEY=VALUE` format:

```bash
# .orchrc -- project-level orchd configuration
runtime=bare
platform=systemd
overlays=bare.orch
state_dir=/root/.myapp
project_dir=/root/myapp
data_dir=/root/.myapp/data
unit_prefix=myapp
systemd_scope=system
```

Lines starting with `#` are comments. Empty lines are ignored. No quoting required for values without spaces.

## Auto-Detection

### Platform

```rust
fn detect_platform() -> &'static str {
    match std::env::consts::OS {
        "macos" => "launchd",
        "linux" => "systemd",
        _ => "systemd", // default fallback
    }
}
```

### Runtime

Default is `bare`. No auto-detection for runtime -- the user must explicitly choose a container runtime if they want one.

## Namespace Isolation

When `namespace` is set, orchd derives isolated paths:

```rust
fn apply_namespace(config: &mut Config) {
    if let Some(ns) = &config.namespace {
        config.state_dir = format!("{}/.orch-{}", home_dir(), ns);
        config.unit_prefix = format!("{}-{}", config.unit_prefix, ns);
    }
}
```

This allows multiple orchd environments on the same machine (e.g., different branches, different projects).

## Config Struct

```rust
#[derive(Debug)]
pub struct Config {
    pub runtime: String,
    pub platform: String,
    pub orchfile: PathBuf,
    pub overlays: Vec<PathBuf>,
    pub orch_bin: PathBuf,
    pub state_dir: PathBuf,
    pub project_dir: PathBuf,
    pub data_dir: PathBuf,
    pub unit_prefix: String,
    pub systemd_scope: SystemdScope,
    pub namespace: Option<String>,
}

#[derive(Debug)]
pub enum SystemdScope {
    System,
    User,
}

impl Config {
    /// Load configuration from all sources in precedence order.
    pub fn load(cli: &CliArgs) -> Result<Self> { ... }
}
```

## Config Loading Pipeline

```
CLI args (highest priority)
    |
    v
Environment variables
    |
    v
.orchrc (project root)
    |
    v
~/.config/orch/config (user)
    |
    v
Auto-detection + defaults (lowest priority)
    |
    v
Final Config struct
    |
    v
Validate:
  - orchfile exists
  - overlay files exist
  - orch_bin is executable
  - state_dir is writable (or creatable)
```

## orch Parse Invocation

The engine assembles the `orch parse` command from config:

```rust
fn build_orch_command(config: &Config, extra_args: &[(String, String)]) -> Command {
    let mut cmd = Command::new(&config.orch_bin);
    cmd.arg("parse");
    cmd.arg(&config.orchfile);

    for overlay in &config.overlays {
        cmd.arg(overlay);
    }

    for (key, value) in extra_args {
        cmd.arg("--arg");
        cmd.arg(format!("{}={}", key, value));
    }

    cmd
}
```

## Built-in Variable Resolution

After deserializing orch JSON, orchd expands built-in variables that orch left unresolved:

| Variable | Resolved to |
|----------|-------------|
| `${ORCH_PROJECT}` | `config.project_dir` |
| `${ORCH_DATA}` | `config.data_dir` |
| `${ORCH_STATE_DIR}` | `config.state_dir` |
| `${ORCH_CONTAINERS_DIR}` | Directory containing the Orchfile |

These appear in workdir, env values, volume paths, and commands. orchd performs string substitution before passing data to the platform generator.
