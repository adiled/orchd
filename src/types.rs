use serde::Deserialize;
use std::collections::HashMap;

/// Top-level JSON output from `orch parse`.
#[derive(Debug, Deserialize)]
pub struct OrchFile {
    pub version: String,
    #[allow(dead_code)]
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

#[allow(dead_code)]
#[derive(Debug, Clone, Deserialize)]
pub struct PortMapping {
    pub host: u16,
    pub container: u16,
}

#[allow(dead_code)]
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
    #[allow(dead_code)]
    pub entrypoint: Option<String>,
    #[allow(dead_code)]
    pub cmd: Option<String>,
    #[allow(dead_code)]
    #[serde(default)]
    pub publish: Vec<PortMapping>,
    #[allow(dead_code)]
    #[serde(default)]
    pub volumes: Vec<VolumeMount>,

    // Host-only
    pub user: Option<String>,
    pub stop_command: Option<String>,
    #[allow(dead_code)]
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
    #[allow(dead_code)]
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
    #[allow(dead_code)]
    pub fn is_container(&self) -> bool {
        self.mode == ServiceMode::Container
    }
}

#[cfg(test)]
#[allow(non_snake_case)]
mod tests {
    use super::*;

    fn stub_minimal_json() -> &'static str {
        r#"{
            "version": "0.2.0",
            "services": [
                {
                    "name": "web",
                    "mode": "host",
                    "run_command": "/usr/bin/nginx"
                }
            ]
        }"#
    }

    fn stub_full_service_json() -> &'static str {
        r#"{
            "version": "0.2.0",
            "args": {"FOO": "bar"},
            "services": [
                {
                    "name": "api",
                    "mode": "container",
                    "image": "myapp:latest",
                    "entrypoint": "/entrypoint.sh",
                    "cmd": "serve",
                    "publish": [{"host": 8080, "container": 80}],
                    "volumes": [{"source": "/data", "destination": "/app/data", "is_named": false}],
                    "env": {"DB_HOST": "localhost"},
                    "env_files": [".env"],
                    "requires": ["postgres"],
                    "after": ["postgres"],
                    "healthcheck": "curl -sf http://localhost:8080/health",
                    "readiness_timeout": "30s",
                    "oneshot": false,
                    "disabled": false,
                    "recreate": "always",
                    "restart": {
                        "policy": "on_failure",
                        "delay": "5s",
                        "start_limit_burst": 3,
                        "start_limit_interval": "60s"
                    },
                    "timeouts": {"start": "30s", "stop": "10s"},
                    "resources": {
                        "memory": "512M",
                        "cpus": 2.0,
                        "limit_nofile": 65536
                    },
                    "logging": {"stdout": "journal", "stderr": "journal"}
                }
            ]
        }"#
    }

    #[test]
    fn test_deserialize__minimal_orchfile() {
        let orchfile: OrchFile = serde_json::from_str(stub_minimal_json()).unwrap();
        assert_eq!(orchfile.version, "0.2.0");
        assert_eq!(orchfile.services.len(), 1);
        assert_eq!(orchfile.services[0].name, "web");
        assert!(orchfile.services[0].is_host());
    }

    #[test]
    fn test_deserialize__full_service() {
        let orchfile: OrchFile = serde_json::from_str(stub_full_service_json()).unwrap();
        let svc = &orchfile.services[0];
        assert_eq!(svc.name, "api");
        assert_eq!(svc.mode, ServiceMode::Container);
        assert!(svc.is_container());
        assert!(!svc.is_host());
        assert_eq!(svc.image.as_deref(), Some("myapp:latest"));
        assert_eq!(svc.entrypoint.as_deref(), Some("/entrypoint.sh"));
        assert_eq!(svc.cmd.as_deref(), Some("serve"));
        assert_eq!(svc.publish.len(), 1);
        assert_eq!(svc.publish[0].host, 8080);
        assert_eq!(svc.volumes.len(), 1);
        assert_eq!(svc.env.get("DB_HOST").unwrap(), "localhost");
        assert_eq!(svc.env_files, vec![".env"]);
        assert_eq!(svc.requires, vec!["postgres"]);
        assert_eq!(svc.after, vec!["postgres"]);
        assert_eq!(
            svc.healthcheck.as_deref(),
            Some("curl -sf http://localhost:8080/health")
        );
        assert_eq!(svc.readiness_timeout.as_deref(), Some("30s"));
        assert!(!svc.oneshot);
        assert!(!svc.disabled);
        assert_eq!(svc.recreate, RecreatePolicy::Always);
    }

    #[test]
    fn test_deserialize__restart_config() {
        let orchfile: OrchFile = serde_json::from_str(stub_full_service_json()).unwrap();
        let restart = &orchfile.services[0].restart;
        assert_eq!(restart.policy, RestartPolicy::OnFailure);
        assert_eq!(restart.delay.as_deref(), Some("5s"));
        assert_eq!(restart.start_limit_burst, Some(3));
        assert_eq!(restart.start_limit_interval.as_deref(), Some("60s"));
    }

    #[test]
    fn test_deserialize__timeout_config() {
        let orchfile: OrchFile = serde_json::from_str(stub_full_service_json()).unwrap();
        let timeouts = &orchfile.services[0].timeouts;
        assert_eq!(timeouts.start.as_deref(), Some("30s"));
        assert_eq!(timeouts.stop.as_deref(), Some("10s"));
    }

    #[test]
    fn test_deserialize__resource_limits() {
        let orchfile: OrchFile = serde_json::from_str(stub_full_service_json()).unwrap();
        let res = &orchfile.services[0].resources;
        assert_eq!(res.memory.as_deref(), Some("512M"));
        assert_eq!(res.cpus, Some(2.0));
        assert_eq!(res.limit_nofile, Some(65536));
    }

    #[test]
    fn test_deserialize__args_map() {
        let orchfile: OrchFile = serde_json::from_str(stub_full_service_json()).unwrap();
        assert_eq!(orchfile.args.get("FOO").unwrap(), "bar");
    }

    #[test]
    fn test_deserialize__defaults_when_missing() {
        let json = r#"{
            "version": "0.1.0",
            "services": [
                {
                    "name": "svc",
                    "mode": "host"
                }
            ]
        }"#;
        let orchfile: OrchFile = serde_json::from_str(json).unwrap();
        let svc = &orchfile.services[0];
        assert!(orchfile.args.is_empty());
        assert!(svc.env.is_empty());
        assert!(svc.env_files.is_empty());
        assert!(svc.requires.is_empty());
        assert!(svc.after.is_empty());
        assert!(svc.publish.is_empty());
        assert!(svc.volumes.is_empty());
        assert!(!svc.oneshot);
        assert!(!svc.disabled);
        assert_eq!(svc.restart.policy, RestartPolicy::No);
        assert_eq!(svc.recreate, RecreatePolicy::Never);
    }

    #[test]
    fn test_is_host__returns_true_for_host_mode() {
        let orchfile: OrchFile = serde_json::from_str(stub_minimal_json()).unwrap();
        assert!(orchfile.services[0].is_host());
        assert!(!orchfile.services[0].is_container());
    }

    #[test]
    fn test_is_container__returns_true_for_container_mode() {
        let orchfile: OrchFile = serde_json::from_str(stub_full_service_json()).unwrap();
        assert!(orchfile.services[0].is_container());
        assert!(!orchfile.services[0].is_host());
    }
}
