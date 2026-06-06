//! The `orchdi` platform: run orchd's own supervisor directly, no OS init.
//!
//! launchd and systemd register the supervisor (`orchd supervise`) as an OS job
//! so the OS starts it on boot and resurrects it. This platform skips that: it
//! writes a SuperviseSpec per service and spawns the supervisor directly,
//! detached and pidfile-tracked. For environments with no usable init: inside a
//! container, CI, WSL-without-systemd, minimal boxes.
//!
//! It carries no boot persistence (who babysits the babysitter); something in
//! the environment starts orchd. That is the tradeoff, and the point.

use crate::config::Config;
use crate::exec::ExecSet;
use crate::orchdi::{build_dep_gates, build_supervise_spec, service_label, supervise_spec_path};
use crate::platform::{Platform, PlatformError};
use crate::types::Service;

pub mod lifecycle;

pub struct OrchdiPlatform;

impl OrchdiPlatform {
    pub fn new() -> Self {
        OrchdiPlatform
    }

    /// Write a SuperviseSpec per enabled service. orchdi IS the supervisor, so
    /// every service runs under it: there are no native unit files, just the
    /// specs the leaf reads.
    pub fn generate_all(
        &self,
        services: &[Service],
        exec_sets: &[(usize, ExecSet)],
        config: &Config,
    ) -> Result<Vec<String>, PlatformError> {
        let spec_dir = config.state_dir.join("supervise");
        std::fs::create_dir_all(&spec_dir)?;

        let mut generated = Vec::new();
        for (idx, exec_set) in exec_sets {
            let service = &services[*idx];
            let deps = build_dep_gates(service, services);
            let label = service_label(config, &service.name);
            let spec = build_supervise_spec(service, exec_set, config, &deps);
            let json = serde_json::to_string_pretty(&spec)
                .map_err(|e| PlatformError::GenerationFailed(e.to_string()))?;
            let spec_path = supervise_spec_path(config, &label);
            std::fs::write(&spec_path, json)?;
            generated.push(spec_path);
        }
        Ok(generated)
    }
}

impl Platform for OrchdiPlatform {
    fn check(&self) -> Result<(), PlatformError> {
        // Needs only POSIX process control, available wherever orchd runs.
        Ok(())
    }

    fn install(&self, _config: &Config) -> Result<(), PlatformError> {
        // Nothing to register with an OS init. generate_all wrote the specs;
        // lifecycle::start spawns the supervisors.
        Ok(())
    }

    fn clean(&self, config: &Config) -> Result<(), PlatformError> {
        let _ = lifecycle::stop(&[], config);
        let _ = std::fs::remove_dir_all(config.state_dir.join("supervise"));
        let _ = std::fs::remove_dir_all(config.state_dir.join("run"));
        Ok(())
    }
}
