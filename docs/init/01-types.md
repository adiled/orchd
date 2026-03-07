# 01 - Types

## Overview

orchd deserializes the JSON output of `orch parse` into Rust types via serde. These types mirror the final (resolved) types in `orch/src/types.rs` -- not the raw/intermediate types used during parsing.

The JSON schema is the interface contract between orch and orchd. orchd never imports orch as a crate (until workspace merge). It only consumes the JSON.

## orch JSON Output Structure

`orch parse <files>` outputs a single JSON object:

```json
{
  "version": "0.2.0",
  "args": {
    "postgres_port": "5433",
    "redis_port": "6380"
  },
  "services": [
    {
      "name": "postgres",
      "mode": "container",
      "image": "pgvector/pgvector:pg15",
      "publish": [{ "host": 5433, "container": 5432 }],
      "volumes": [{ "source": "app-pgdata", "destination": "/var/lib/postgresql/data", "is_named": true }],
      "env": { "POSTGRES_USER": "postgres" },
      "healthcheck": "pg_isready -h localhost -p 5433",
      "restart": { "policy": "on_failure", "delay": "5s" },
      "resources": { "memory": "4G", "cpus": 2.0 },
      "oneshot": false,
      "disabled": false,
      "recreate": "never"
    }
  ]
}
```

## orchd Deserialization Types

```rust
use serde::Deserialize;
use std::collections::HashMap;

#[derive(Debug, Deserialize)]
pub struct OrchFile {
    pub version: String,
    pub args: HashMap<String, String>,
    pub services: Vec<Service>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ServiceMode {
    Container,
    Host,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RestartPolicy {
    No,
    Always,
    OnFailure,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RecreatePolicy {
    Always,
    Never,
}

#[derive(Debug, Deserialize)]
pub struct PortMapping {
    pub host: u16,
    pub container: u16,
}

#[derive(Debug, Deserialize)]
pub struct VolumeMount {
    pub source: String,
    pub destination: String,
    pub is_named: bool,
}

#[derive(Debug, Deserialize, Default)]
pub struct ResourceLimits {
    pub memory: Option<String>,
    pub cpus: Option<f64>,
    pub cpu_quota: Option<String>,
    pub limit_nofile: Option<u64>,
    pub limit_nproc: Option<u64>,
    pub tasks_max: Option<u64>,
    pub io_weight: Option<u32>,
}

#[derive(Debug, Deserialize, Default)]
pub struct RestartConfig {
    pub policy: RestartPolicy,
    pub delay: Option<String>,
    pub start_limit_burst: Option<u32>,
    pub start_limit_interval: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct TimeoutConfig {
    pub start: Option<String>,
    pub stop: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct LogConfig {
    pub stdout: Option<String>,
    pub stderr: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct Service {
    pub name: String,
    pub mode: ServiceMode,

    // Mode-specific
    pub image: Option<String>,
    pub run_command: Option<String>,

    // Container-only
    pub entrypoint: Option<String>,
    pub cmd: Option<String>,
    #[serde(default)]
    pub publish: Vec<PortMapping>,
    #[serde(default)]
    pub volumes: Vec<VolumeMount>,

    // Host-only
    pub user: Option<String>,
    pub stop_command: Option<String>,
    pub reload_command: Option<String>,

    // Common
    pub workdir: Option<String>,
    #[serde(default)]
    pub env: HashMap<String, String>,
    #[serde(default)]
    pub env_files: Vec<String>,
    #[serde(default)]
    pub requires: Vec<String>,
    #[serde(default)]
    pub after: Vec<String>,
    pub healthcheck: Option<String>,
    pub readiness_timeout: Option<String>,

    pub oneshot: bool,
    pub disabled: bool,
    pub recreate: RecreatePolicy,

    pub restart: RestartConfig,
    pub timeouts: TimeoutConfig,
    pub resources: ResourceLimits,
    pub logging: LogConfig,
}
```

## ExecSet -- The Engine's Output to Platforms

The engine assembles runtime-produced commands into an `ExecSet` per service:

```rust
#[derive(Debug, Default)]
pub struct ExecSet {
    /// The main process command (ExecStart / ProgramArguments)
    pub start: String,

    /// Optional pre-start command (ExecStartPre)
    /// e.g., container create, image pull
    pub pre_start: Option<String>,

    /// Optional stop command (ExecStop)
    /// e.g., container stop <name>
    pub stop: Option<String>,

    /// Optional post-stop command (ExecStopPost)
    /// e.g., container rm <name> (if recreate=always)
    pub post_stop: Option<String>,
}
```

For host-mode services, `ExecSet` contains only `start` (the `run_command`). For container runtimes, all fields may be populated.

## serde Defaults and Skip Behavior

orch uses `#[serde(skip_serializing_if = "...")]` on optional fields. orchd's deserialization uses `Option<T>` and `#[serde(default)]` to handle absent fields gracefully. The types must tolerate missing keys without failing.

Key serde attributes used:
- `#[serde(default)]` on Vec and HashMap fields (absent = empty)
- `Option<T>` on all optional scalars (absent = None)
- `#[serde(rename_all = "snake_case")]` on enums matching orch's serialization

## RestartPolicy Default

orch serializes `RestartPolicy` as part of the `RestartConfig` struct, always present. orchd deserializes it with `Default` impl returning `RestartPolicy::No` as fallback.

```rust
impl Default for RestartPolicy {
    fn default() -> Self {
        RestartPolicy::No
    }
}
```

## Validation After Deserialization

orchd does NOT re-validate constraints (C1-C4). The `orch parse` command already validates and errors on invalid input. orchd trusts the JSON. If deserialization succeeds, the data is valid.

However, orchd does validate runtime-specific constraints:
- Bare runtime: container-mode service without overlay --> error
- containerd runtime: image reference must be valid --> validated during `runtime.prepare()`
