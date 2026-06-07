//! containerd runtime: orchd drives containerd's gRPC API directly, in process.
//! Linux.
//!
//! The exec_set for a container is a single stateless foreground command,
//! `orchd containerd-run --spec <base64>` (see `run`), which the supervisor
//! (orchdi/launchd/systemd) tracks. That process pulls the image, creates and
//! starts the container task over the containerd socket in the host network
//! namespace (so there is no CNI/iptables dependency), waits for it to exit,
//! and on SIGTERM kills + deletes it. One command owns the whole lifecycle, so
//! there is no separate pre_start/stop/post_stop.

use std::path::Path;

use crate::config::Config;
use crate::exec::ExecSet;
use crate::runtime::{Runtime, RuntimeError};
use crate::types::Service;

pub mod run;
use run::{encode_spec, ContainerdRunSpec, Resources, VolumeMount};

const DEFAULT_SOCKET: &str = "/run/containerd/containerd.sock";

pub struct ContainerdRuntime {
    namespace: String,
    data_dir: std::path::PathBuf,
    socket: String,
}

impl ContainerdRuntime {
    pub fn new(config: &Config) -> Self {
        ContainerdRuntime {
            namespace: config.namespace.clone(),
            data_dir: config.data_dir.clone(),
            socket: std::env::var("ORCHD_CONTAINERD_SOCKET")
                .unwrap_or_else(|_| DEFAULT_SOCKET.to_string()),
        }
    }

    fn container_name(&self, service: &Service) -> String {
        format!("{}-{}", self.namespace, service.name)
    }

    fn require_image<'a>(&self, service: &'a Service) -> Result<&'a str, RuntimeError> {
        service.image.as_deref().ok_or_else(|| {
            RuntimeError::Other(format!(
                "service '{}' is container-mode but has no FROM image",
                service.name
            ))
        })
    }

    /// Path to the orchd binary to invoke for `containerd-run` (this same exe).
    fn orchd_exe() -> String {
        std::env::current_exe()
            .ok()
            .and_then(|p| p.to_str().map(String::from))
            .unwrap_or_else(|| "orchd".to_string())
    }
}

impl Runtime for ContainerdRuntime {
    fn name(&self) -> &str {
        "containerd"
    }

    fn check(&self) -> Result<(), RuntimeError> {
        // We talk to containerd directly over its gRPC socket; the actual
        // connection happens in `containerd-run`. Here we just confirm the
        // socket exists, which fails cleanly off-Linux (no containerd).
        if Path::new(&self.socket).exists() {
            Ok(())
        } else {
            Err(RuntimeError::Other(format!(
                "containerd socket '{}' not found (is containerd running?)",
                self.socket
            )))
        }
    }

    fn prepare(&self, service: &Service) -> Result<(), RuntimeError> {
        if service.is_host() {
            let dir = self.data_dir.join(&service.name);
            std::fs::create_dir_all(&dir).map_err(|e| {
                RuntimeError::Other(format!(
                    "failed to create data directory '{}': {e}",
                    dir.display()
                ))
            })?;
            return Ok(());
        }
        // Image pull is deferred to pre_start (no I/O at prepare time).
        Ok(())
    }

    fn exec_set(&self, service: &Service) -> Result<ExecSet, RuntimeError> {
        if service.is_host() {
            // Host-mode services pass through as plain programs, same as bare.
            let start = service.run_command.clone().ok_or_else(|| {
                RuntimeError::Other(format!(
                    "service '{}' is host-mode but has no RUN command",
                    service.name
                ))
            })?;
            return Ok(ExecSet {
                start,
                pre_start: None,
                stop: service.stop_command.clone(),
                post_stop: None,
            });
        }

        let image = self.require_image(service)?;
        let name = self.container_name(service);

        // Resolve argv from the service's ENTRYPOINT + CMD (space-split). Empty
        // means containerd-run falls back to the image config's Entrypoint+Cmd.
        let mut args: Vec<String> = Vec::new();
        if let Some(ep) = &service.entrypoint {
            args.extend(ep.split_whitespace().map(String::from));
        }
        if let Some(cmd) = &service.cmd {
            args.extend(cmd.split_whitespace().map(String::from));
        }

        let mut env: Vec<String> = service
            .env
            .iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect();
        env.sort();

        // Resource caps: cpus -> cgroup cpu.max (quota = cpus * period); else a
        // CPU_QUOTA percentage. memory/pids/io/rlimits map straight through.
        let r = &service.resources;
        let (cpu_quota_us, cpu_period_us) = if let Some(c) = r.cpus.filter(|c| *c > 0.0) {
            (Some((c * 100_000.0) as u64), Some(100_000u64))
        } else if let Some(q) = r.cpu_quota.as_deref().and_then(parse_cpu_quota_pct) {
            (Some(q), Some(100_000u64))
        } else {
            (None, None)
        };
        let resources = Resources {
            memory_bytes: r.memory.as_deref().and_then(parse_memory_bytes),
            cpu_quota_us,
            cpu_period_us,
            pids_max: r.tasks_max.or(r.limit_nproc),
            nofile: r.limit_nofile,
            nproc: r.limit_nproc,
            io_weight: r.io_weight,
        };

        let spec = ContainerdRunSpec {
            socket: self.socket.clone(),
            namespace: self.namespace.clone(),
            image: image.to_string(),
            container_id: name,
            args,
            env,
            cwd: service.workdir.clone().unwrap_or_default(),
            user: service.user.clone(),
            env_files: service.env_files.clone(),
            volumes: service
                .volumes
                .iter()
                .map(|v| VolumeMount {
                    source: v.source.clone(),
                    destination: v.destination.clone(),
                })
                .collect(),
            resources,
        };

        // start is a single foreground process the supervisor tracks: it pulls
        // (if needed), runs the container task over containerd's gRPC socket in
        // the host network namespace, and on SIGTERM kills + deletes it.
        let start = format!(
            "{} containerd-run --spec {}",
            Self::orchd_exe(),
            encode_spec(&spec)
        );

        Ok(ExecSet {
            start,
            pre_start: None,
            stop: None,
            post_stop: None,
        })
    }
}

/// Parse a memory size ("512M", "2G", "1Gi", "1073741824") into bytes. k/m/g
/// (case-insensitive) are 1024-based; a bare number is bytes. None if invalid.
fn parse_memory_bytes(s: &str) -> Option<u64> {
    let t = s.trim();
    let end = t.find(|c: char| !c.is_ascii_digit()).unwrap_or(t.len());
    if end == 0 {
        return None;
    }
    let num: u64 = t[..end].parse().ok()?;
    let mult = match t[end..].trim().chars().next().map(|c| c.to_ascii_lowercase()) {
        Some('k') => 1024,
        Some('m') => 1024 * 1024,
        Some('g') => 1024 * 1024 * 1024,
        _ => 1,
    };
    Some(num.saturating_mul(mult))
}

/// Parse a CPU quota percentage ("50%" or "50") into a cgroup cpu.max quota in
/// microseconds (period 100000). None if invalid/zero.
fn parse_cpu_quota_pct(s: &str) -> Option<u64> {
    let pct: u64 = s.trim().trim_end_matches('%').trim().parse().ok()?;
    if pct == 0 {
        return None;
    }
    Some(pct * 100_000 / 100)
}

#[cfg(test)]
#[allow(non_snake_case)]
mod tests {
    use super::*;

    fn runtime() -> ContainerdRuntime {
        ContainerdRuntime {
            namespace: "orch".to_string(),
            data_dir: std::env::temp_dir().join("orchd-containerd-test"),
            socket: super::DEFAULT_SOCKET.to_string(),
        }
    }

    fn decode(b64: &str) -> ContainerdRunSpec {
        use base64::Engine;
        let json = base64::engine::general_purpose::STANDARD
            .decode(b64)
            .unwrap();
        serde_json::from_slice(&json).unwrap()
    }

    #[test]
    fn test_exec_set__container_emits_containerd_run() {
        let rt = runtime();
        let mut svc: Service = serde_json::from_str(STUB_CONTAINER).unwrap();
        svc.name = "web".into();
        svc.image = Some("nginx:alpine".into());
        svc.env.insert("FOO".into(), "bar".into());
        svc.cmd = Some("sleep 300".into());

        let exec = rt.exec_set(&svc).expect("exec_set");
        // start is `<orchd> containerd-run --spec <b64>`; no separate
        // pull/stop/post_stop (containerd-run owns the whole lifecycle).
        assert!(exec.start.contains(" containerd-run --spec "));
        assert!(exec.pre_start.is_none());
        assert!(exec.stop.is_none());
        assert!(exec.post_stop.is_none());

        let b64 = exec.start.rsplit(' ').next().unwrap();
        let spec = decode(b64);
        assert_eq!(spec.image, "nginx:alpine");
        assert_eq!(spec.container_id, "orch-web");
        assert_eq!(spec.namespace, "orch");
        assert_eq!(spec.args, vec!["sleep".to_string(), "300".to_string()]);
        assert_eq!(spec.env, vec!["FOO=bar".to_string()]);
    }

    #[test]
    fn test_exec_set__host_passthrough() {
        let rt = runtime();
        let mut svc: Service = serde_json::from_str(STUB_HOST).unwrap();
        svc.run_command = Some("/usr/bin/redis-server".into());
        let exec = rt.exec_set(&svc).expect("host passthrough");
        assert_eq!(exec.start, "/usr/bin/redis-server");
        assert!(exec.pre_start.is_none());
    }

    const STUB_CONTAINER: &str = r#"{
        "name":"x","mode":"container","image":"x",
        "oneshot":false,"disabled":false,"recreate":"never",
        "restart":{"policy":"no"},"timeouts":{},"resources":{},"logging":{}
    }"#;
    const STUB_HOST: &str = r#"{
        "name":"x","mode":"host","run_command":"x",
        "oneshot":false,"disabled":false,"recreate":"never",
        "restart":{"policy":"no"},"timeouts":{},"resources":{},"logging":{}
    }"#;
}
