# 03 - Platform Interface

## Overview

A platform supervises processes using the OS-native service manager. It generates platform-specific artifacts (systemd units, launchd plists) from the `ExecSet` + service metadata, and provides lifecycle management (start, stop, status, logs, health).

The platform never interacts with the runtime. It receives fully assembled `ExecSet` structs from the engine and maps them to platform-specific directives.

## The Platform Trait

```rust
pub trait Platform {
    /// Human-readable name for this platform (e.g., "systemd", "launchd")
    fn name(&self) -> &str;

    /// Check if this platform is available on the current system.
    /// Returns Err with a descriptive message if unavailable.
    fn check(&self) -> Result<()>;

    /// Generate platform artifacts for all services.
    /// Input: orch data (services + metadata), exec sets from runtime, config.
    /// Output: writes unit files / plists to the state directory.
    fn generate(
        &self,
        orch: &OrchFile,
        exec_sets: &HashMap<String, ExecSet>,
        config: &Config,
    ) -> Result<GenerateResult>;

    /// Install generated artifacts into the platform's service directory.
    /// For systemd: symlink units to /etc/systemd/system/, daemon-reload.
    /// For launchd: symlink plists to ~/Library/LaunchAgents/.
    fn install(&self, config: &Config) -> Result<()>;

    /// Start services. Empty slice = all enabled services.
    fn start(&self, services: &[String], config: &Config) -> Result<()>;

    /// Stop services. Empty slice = all managed services.
    fn stop(&self, services: &[String], config: &Config) -> Result<()>;

    /// Restart services. Empty slice = all managed services.
    fn restart(&self, services: &[String], config: &Config) -> Result<()>;

    /// Return status of all managed services.
    fn status(&self, orch: &OrchFile, config: &Config) -> Result<Vec<ServiceStatus>>;

    /// Tail logs for a service.
    fn logs(&self, service: &str, follow: bool, lines: Option<u32>) -> Result<()>;

    /// Wait for all enabled services to pass healthchecks.
    fn health(
        &self,
        orch: &OrchFile,
        timeout: Duration,
        config: &Config,
    ) -> Result<HealthResult>;

    /// Remove all generated artifacts and unload services.
    fn clean(&self, config: &Config) -> Result<()>;
}
```

## Supporting Types

```rust
pub struct GenerateResult {
    pub units_generated: usize,
    pub output_dir: PathBuf,
}

pub struct ServiceStatus {
    pub name: String,
    pub mode: ServiceMode,
    pub state: ServiceState,
    pub pid: Option<u32>,
    pub exit_code: Option<i32>,
}

pub enum ServiceState {
    Running,
    Stopped,
    Failed,
    Disabled,
    Waiting,   // waiting for dependency healthcheck
    Exited,    // oneshot completed successfully
}

pub struct HealthResult {
    pub all_healthy: bool,
    pub healthy: Vec<String>,
    pub unhealthy: Vec<String>,
    pub elapsed: Duration,
}
```

## ExecSet to Platform Mapping

The platform maps `ExecSet` fields to its native directives:

| ExecSet field | systemd | launchd |
|---------------|---------|---------|
| `pre_start` | `ExecStartPre=` | Prepended to bash -c chain |
| `start` | `ExecStart=` | `ProgramArguments` |
| `stop` | `ExecStop=` | Not directly supported (SIGTERM) |
| `post_stop` | `ExecStopPost=` | Not directly supported |

## Service Metadata to Platform Mapping

Beyond the ExecSet, the platform maps service metadata to native directives:

| Service field | systemd | launchd |
|---------------|---------|---------|
| `name` | Unit name: `orch-<name>.service` | Label: `com.orch.<name>` |
| `workdir` | `WorkingDirectory=` | `WorkingDirectory` key |
| `env` | `Environment="K=V"` | `EnvironmentVariables` dict |
| `env_files` | `EnvironmentFile=` | Parsed and inlined |
| `user` | `User=` | `UserName` key |
| `stop_command` | `ExecStop=` | Not supported |
| `reload_command` | `ExecReload=` | Not supported |
| `restart.policy` | `Restart=` | `KeepAlive` / `SuccessfulExit` |
| `restart.delay` | `RestartSec=` | `ThrottleInterval` |
| `restart.start_limit_burst` | `StartLimitBurst=` | Not supported |
| `restart.start_limit_interval` | `StartLimitIntervalSec=` | Not supported |
| `timeouts.start` | `TimeoutStartSec=` | Not supported |
| `timeouts.stop` | `TimeoutStopSec=` | `ExitTimeOut` |
| `resources.memory` | `MemoryMax=` | Advisory only |
| `resources.cpus` | `CPUQuota=` (cpus * 100%) | Advisory only |
| `resources.cpu_quota` | `CPUQuota=` | Not supported |
| `resources.limit_nofile` | `LimitNOFILE=` | `SoftResourceLimits/NumberOfFiles` |
| `resources.limit_nproc` | `LimitNPROC=` | `SoftResourceLimits/NumberOfProcesses` |
| `resources.tasks_max` | `TasksMax=` | Not supported |
| `resources.io_weight` | `IOWeight=` | Not supported |
| `oneshot` | `Type=oneshot` + `RemainAfterExit=yes` | `RunAtLoad` + no `KeepAlive` |
| `logging.stdout` | `StandardOutput=file:<path>` | `StandardOutPath` |
| `logging.stderr` | `StandardError=file:<path>` | `StandardErrorPath` |
| `requires` | `BindsTo=` + `After=` | Dependency wait in bash chain |
| `after` | `After=` (no BindsTo) | Dependency wait in bash chain |

## Dependency Handling

Platforms handle `requires` and `after` differently based on their native capabilities:

### systemd (native dependency support)

- `REQUIRES dep` --> `BindsTo=orch-dep.service` + `After=orch-dep.service`
- `AFTER dep` --> `After=orch-dep.service` (weak, no BindsTo)
- Healthcheck-gated deps: generate `orch-<dep>-ready.service` companion units (see [04-systemd-platform.md](04-systemd-platform.md))

### launchd (no native dependency support)

- Dependencies implemented as wait loops in the ProgramArguments bash chain
- Healthcheck deps: `until <healthcheck_cmd>; do sleep 2; done`
- Oneshot deps: `while [ ! -f <ready_dir>/<dep> ]; do sleep 1; done`

## Implementing a Platform

To add a new platform, implement the `Platform` trait and register it in the engine's platform resolution.

## Planned Platforms

| Platform | Status | Description |
|----------|--------|-------------|
| **systemd** | Phase 2-3 | Linux service manager. Full cgroup v2 resource enforcement. |
| **launchd** | Deferred | macOS service manager. To be extracted from your-project osx-port. |
