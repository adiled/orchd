use serde::Deserialize;
use std::collections::HashMap;

/// Top-level JSON output from `orch parse`.
#[derive(Debug, Deserialize)]
pub struct OrchFile {
    pub version: String,
    #[serde(default)]
    pub args: HashMap<String, String>,
    #[serde(default)]
    pub services: Vec<Service>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum ServiceMode {
    Container,
    Host,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum RestartPolicy {
    No,
    Always,
    OnFailure,
}

impl Default for RestartPolicy {
    fn default() -> Self {
        RestartPolicy::No
    }
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum RecreatePolicy {
    Always,
    Never,
}

impl Default for RecreatePolicy {
    fn default() -> Self {
        RecreatePolicy::Never
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct PortMapping {
    pub host: u16,
    pub container: u16,
}

#[derive(Debug, Clone, Deserialize)]
pub struct VolumeMount {
    pub source: String,
    pub destination: String,
    pub is_named: bool,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct ResourceLimits {
    pub memory: Option<String>,
    pub cpus: Option<f64>,
    pub cpu_quota: Option<String>,
    pub limit_nofile: Option<u64>,
    pub limit_nproc: Option<u64>,
    pub tasks_max: Option<u64>,
    pub io_weight: Option<u32>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct RestartConfig {
    #[serde(default)]
    pub policy: RestartPolicy,
    pub delay: Option<String>,
    pub start_limit_burst: Option<u32>,
    pub start_limit_interval: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct TimeoutConfig {
    pub start: Option<String>,
    pub stop: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct LogConfig {
    pub stdout: Option<String>,
    pub stderr: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
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

    #[serde(default)]
    pub oneshot: bool,
    #[serde(default)]
    pub disabled: bool,
    #[serde(default)]
    pub recreate: RecreatePolicy,

    #[serde(default)]
    pub restart: RestartConfig,
    #[serde(default)]
    pub timeouts: TimeoutConfig,
    #[serde(default)]
    pub resources: ResourceLimits,
    #[serde(default)]
    pub logging: LogConfig,
}

impl Service {
    /// Returns true if this service runs directly on the host (not in a container).
    pub fn is_host(&self) -> bool {
        self.mode == ServiceMode::Host
    }

    /// Returns true if this service runs in a container.
    pub fn is_container(&self) -> bool {
        self.mode == ServiceMode::Container
    }
}
