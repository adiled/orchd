//! containerd runtime: an ExecSet over `nerdctl` (containerd's docker-compatible
//! CLI). Linux.
//!
//! nerdctl drives containerd directly, so this is "containerd as the runtime"
//! with no Docker daemon on top. It fits the four-string ExecSet contract today
//! (the pragmatic wiring). A future mode-2 will drive containerd's gRPC API in
//! process; this CLI path is the v1.
//!
//! Container lifecycle, supervised by orchdi/launchd/systemd:
//!   pre_start  nerdctl pull <image>
//!   start      nerdctl run --name <ns>-<svc> --init [flags] <image> [cmd]
//!   stop       nerdctl stop <ns>-<svc>
//!   post_stop  nerdctl rm -f <ns>-<svc>

use std::process::{Command, Stdio};

use crate::config::Config;
use crate::exec::ExecSet;
use crate::runtime::{Runtime, RuntimeError};
use crate::types::Service;

pub struct ContainerdRuntime {
    namespace: String,
    data_dir: std::path::PathBuf,
}

impl ContainerdRuntime {
    pub fn new(config: &Config) -> Self {
        ContainerdRuntime {
            namespace: config.namespace.clone(),
            data_dir: config.data_dir.clone(),
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
}

impl Runtime for ContainerdRuntime {
    fn name(&self) -> &str {
        "containerd"
    }

    fn check(&self) -> Result<(), RuntimeError> {
        let status = Command::new("nerdctl")
            .arg("version")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map_err(|e| {
                RuntimeError::BinaryNotFound(format!("could not spawn 'nerdctl': {e}"))
            })?;
        if status.success() {
            Ok(())
        } else {
            Err(RuntimeError::Other(
                "containerd not reachable via nerdctl (is containerd running?)".to_string(),
            ))
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

        let pre_start = format!("nerdctl pull {image}");

        // --init forwards signals and reaps zombies inside the container.
        let mut start = format!("nerdctl run --name {name} --init");

        let mut envs: Vec<(&String, &String)> = service.env.iter().collect();
        envs.sort_by(|a, b| a.0.cmp(b.0));
        for (k, v) in envs {
            start.push_str(&format!(" --env {k}={v}"));
        }
        for ef in &service.env_files {
            start.push_str(&format!(" --env-file {ef}"));
        }
        for vol in &service.volumes {
            start.push_str(&format!(" --volume {}:{}", vol.source, vol.destination));
        }
        for p in &service.publish {
            match &p.address {
                Some(addr) => {
                    start.push_str(&format!(" --publish {addr}:{}:{}", p.host, p.container))
                }
                None => start.push_str(&format!(" --publish {}:{}", p.host, p.container)),
            }
        }
        if let Some(mem) = &service.resources.memory {
            start.push_str(&format!(" --memory {mem}"));
        }
        if let Some(cpus) = service.resources.cpus {
            if cpus.fract() == 0.0 {
                start.push_str(&format!(" --cpus {}", cpus as u64));
            } else {
                start.push_str(&format!(" --cpus {cpus}"));
            }
        }
        if let Some(user) = &service.user {
            start.push_str(&format!(" --user {user}"));
        }
        if let Some(wd) = &service.workdir {
            start.push_str(&format!(" --workdir {wd}"));
        }
        if let Some(ep) = &service.entrypoint {
            start.push_str(&format!(" --entrypoint {ep}"));
        }
        start.push_str(&format!(" {image}"));
        if let Some(cmd) = &service.cmd {
            start.push_str(&format!(" {cmd}"));
        }

        Ok(ExecSet {
            start,
            pre_start: Some(pre_start),
            stop: Some(format!("nerdctl stop {name}")),
            post_stop: Some(format!("nerdctl rm -f {name}")),
        })
    }
}

#[cfg(test)]
#[allow(non_snake_case)]
mod tests {
    use super::*;

    fn runtime() -> ContainerdRuntime {
        ContainerdRuntime {
            namespace: "orch".to_string(),
            data_dir: std::env::temp_dir().join("orchd-containerd-test"),
        }
    }

    #[test]
    fn test_exec_set__container_maps_to_nerdctl() {
        let rt = runtime();
        let mut svc: Service = serde_json::from_str(STUB_CONTAINER).unwrap();
        svc.name = "web".into();
        svc.image = Some("nginx:alpine".into());
        svc.env.insert("FOO".into(), "bar".into());
        svc.publish = vec![crate::types::PortMapping {
            address: None,
            host: 8080,
            container: 80,
        }];
        svc.resources.memory = Some("512M".into());

        let exec = rt.exec_set(&svc).expect("exec_set");
        assert_eq!(exec.pre_start.as_deref(), Some("nerdctl pull nginx:alpine"));
        assert!(exec.start.starts_with("nerdctl run --name orch-web --init"));
        assert!(exec.start.contains(" --env FOO=bar"));
        assert!(exec.start.contains(" --publish 8080:80"));
        assert!(exec.start.contains(" --memory 512M"));
        assert!(exec.start.ends_with(" nginx:alpine"));
        assert_eq!(exec.stop.as_deref(), Some("nerdctl stop orch-web"));
        assert_eq!(exec.post_stop.as_deref(), Some("nerdctl rm -f orch-web"));
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
