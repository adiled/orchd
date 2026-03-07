use std::path::PathBuf;

use crate::exec::ExecSet;
use crate::runtime::{Runtime, RuntimeError};
use crate::types::{Service, ServiceMode};

/// Bare runtime -- runs services directly on the host, no container layer.
///
/// Container-mode services must be converted to host-mode via Orchfile overlays
/// before orchd processes them. Any remaining container-mode service is an error.
pub struct BareRuntime {
    data_dir: PathBuf,
}

impl BareRuntime {
    pub fn new(data_dir: PathBuf) -> Self {
        BareRuntime { data_dir }
    }
}

impl Runtime for BareRuntime {
    fn name(&self) -> &str {
        "bare"
    }

    fn check(&self) -> Result<(), RuntimeError> {
        // Bare runtime has no prerequisites beyond the host OS.
        // The orch binary is checked by the engine, not the runtime.
        Ok(())
    }

    fn prepare(&self, service: &Service) -> Result<(), RuntimeError> {
        // Create a data directory for this service under the data_dir.
        // Host services may reference ${ORCH_DATA}/<name>/ in their commands.
        let service_data = self.data_dir.join(&service.name);
        std::fs::create_dir_all(&service_data).map_err(|e| {
            RuntimeError::Other(format!(
                "failed to create data directory '{}': {}",
                service_data.display(),
                e
            ))
        })?;
        Ok(())
    }

    fn exec_set(&self, service: &Service) -> Result<ExecSet, RuntimeError> {
        match service.mode {
            ServiceMode::Host => {
                let start = service.run_command.clone().ok_or_else(|| {
                    RuntimeError::Other(format!(
                        "service '{}' is host-mode but has no RUN command",
                        service.name
                    ))
                })?;

                Ok(ExecSet {
                    start,
                    pre_start: None,
                    stop: service.stop_command.clone(),
                    post_stop: None,
                })
            }
            ServiceMode::Container => Err(RuntimeError::UnsupportedMode {
                service: service.name.clone(),
                mode: format!(
                    "container (FROM {}). Create a bare overlay that redefines it with RUN, \
                     or use a container runtime (--runtime containerd)",
                    service.image.as_deref().unwrap_or("unknown")
                ),
            }),
        }
    }

    fn cleanup(&self, _service: &Service) -> Result<(), RuntimeError> {
        // Nothing to clean up for bare services -- data dirs are left intact.
        Ok(())
    }
}

#[cfg(test)]
#[allow(non_snake_case)]
mod tests {
    use super::*;
    use crate::types::*;
    use std::collections::HashMap;

    fn host_service(name: &str, run_command: &str) -> Service {
        Service {
            name: name.to_string(),
            mode: ServiceMode::Host,
            image: None,
            run_command: Some(run_command.to_string()),
            entrypoint: None,
            cmd: None,
            publish: Vec::new(),
            volumes: Vec::new(),
            user: None,
            stop_command: None,
            reload_command: None,
            workdir: None,
            env: HashMap::new(),
            env_files: Vec::new(),
            requires: Vec::new(),
            after: Vec::new(),
            healthcheck: None,
            readiness_timeout: None,
            oneshot: false,
            disabled: false,
            recreate: RecreatePolicy::default(),
            restart: RestartConfig::default(),
            timeouts: TimeoutConfig::default(),
            resources: ResourceLimits::default(),
            logging: LogConfig::default(),
        }
    }

    fn container_service(name: &str, image: &str) -> Service {
        Service {
            name: name.to_string(),
            mode: ServiceMode::Container,
            image: Some(image.to_string()),
            run_command: None,
            entrypoint: None,
            cmd: None,
            publish: Vec::new(),
            volumes: Vec::new(),
            user: None,
            stop_command: None,
            reload_command: None,
            workdir: None,
            env: HashMap::new(),
            env_files: Vec::new(),
            requires: Vec::new(),
            after: Vec::new(),
            healthcheck: None,
            readiness_timeout: None,
            oneshot: false,
            disabled: false,
            recreate: RecreatePolicy::default(),
            restart: RestartConfig::default(),
            timeouts: TimeoutConfig::default(),
            resources: ResourceLimits::default(),
            logging: LogConfig::default(),
        }
    }

    #[test]
    fn test_exec_set__host_service_returns_start_command() {
        let rt = BareRuntime::new(PathBuf::from("/tmp/orchd-test-data"));
        let svc = host_service("django", "/usr/bin/python manage.py runserver 0.0.0.0:9090");

        let exec = rt.exec_set(&svc).unwrap();
        assert_eq!(exec.start, "/usr/bin/python manage.py runserver 0.0.0.0:9090");
        assert!(exec.pre_start.is_none());
        assert!(exec.stop.is_none());
        assert!(exec.post_stop.is_none());
    }

    #[test]
    fn test_exec_set__host_service_includes_stop_command() {
        let rt = BareRuntime::new(PathBuf::from("/tmp/orchd-test-data"));
        let mut svc = host_service("nginx", "nginx -g 'daemon off;'");
        svc.stop_command = Some("nginx -s quit".to_string());

        let exec = rt.exec_set(&svc).unwrap();
        assert_eq!(exec.start, "nginx -g 'daemon off;'");
        assert_eq!(exec.stop.as_deref(), Some("nginx -s quit"));
    }

    #[test]
    fn test_exec_set__container_service_rejected() {
        let rt = BareRuntime::new(PathBuf::from("/tmp/orchd-test-data"));
        let svc = container_service("postgres", "pgvector/pgvector:pg15");

        let err = rt.exec_set(&svc).unwrap_err();
        match err {
            RuntimeError::UnsupportedMode { service, mode } => {
                assert_eq!(service, "postgres");
                assert!(mode.contains("pgvector/pgvector:pg15"));
            }
            other => panic!("expected UnsupportedMode, got: {:?}", other),
        }
    }

    #[test]
    fn test_exec_set__host_service_without_run_command_errors() {
        let rt = BareRuntime::new(PathBuf::from("/tmp/orchd-test-data"));
        let mut svc = host_service("broken", "placeholder");
        svc.run_command = None;

        let err = rt.exec_set(&svc).unwrap_err();
        let msg = format!("{}", err);
        assert!(msg.contains("no RUN command"), "got: {}", msg);
    }

    #[test]
    fn test_check__always_succeeds() {
        let rt = BareRuntime::new(PathBuf::from("/tmp/orchd-test-data"));
        assert!(rt.check().is_ok());
    }

    #[test]
    fn test_name__returns_bare() {
        let rt = BareRuntime::new(PathBuf::from("/tmp/orchd-test-data"));
        assert_eq!(rt.name(), "bare");
    }

    #[test]
    fn test_prepare__creates_service_data_directory() {
        let tmp = std::env::temp_dir().join("orchd-test-bare-prepare");
        let _ = std::fs::remove_dir_all(&tmp);

        let rt = BareRuntime::new(tmp.clone());
        let svc = host_service("postgres", "postgres -p 5433");

        rt.prepare(&svc).unwrap();
        assert!(tmp.join("postgres").is_dir());

        // Cleanup
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn test_cleanup__is_noop() {
        let rt = BareRuntime::new(PathBuf::from("/tmp/orchd-test-data"));
        let svc = host_service("redis", "redis-server");
        assert!(rt.cleanup(&svc).is_ok());
    }
}
