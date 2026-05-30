pub mod generate;
pub mod lifecycle;

use std::path::PathBuf;

use crate::config::Config;
use crate::exec::ExecSet;
use crate::platform::{Platform, PlatformError};
use crate::types::Service;

use generate::{
    generate_ready_gate, generate_service_unit, generate_target, services_needing_ready_gates,
};

pub struct SystemdPlatform;

impl SystemdPlatform {
    pub fn new() -> Self { SystemdPlatform }

    /// Directory where units are symlinked, by scope.
    fn systemd_dir(&self, config: &Config) -> PathBuf {
        if config.scope.is_user() {
            let xdg = std::env::var_os("XDG_CONFIG_HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| {
                    let home = std::env::var_os("HOME")
                        .map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
                    home.join(".config")
                });
            xdg.join("systemd").join("user")
        } else {
            PathBuf::from("/etc/systemd/system")
        }
    }
}

impl Platform for SystemdPlatform {
    fn name(&self) -> &str {
        "systemd"
    }

    fn check(&self) -> Result<(), PlatformError> {
        if !std::path::Path::new("/run/systemd/system").exists() {
            return Err(PlatformError::PrerequisiteMissing(
                "systemd is not running (no /run/systemd/system)".to_string(),
            ));
        }
        Ok(())
    }


    fn generate(
        &self,
        service: &Service,
        exec_set: &ExecSet,
        config: &Config,
    ) -> Result<Vec<String>, PlatformError> {
        // This method generates a single service's unit.
        // The caller (engine) handles ready gates and target separately.
        // We need all services' info for ready gates, which the engine provides
        // via generate_all().
        //
        // For the Platform trait, we generate just this service's unit.
        // The ready_gates set is empty here — the engine calls generate_all() instead.
        let ready_gates = std::collections::HashSet::new();
        let unit_content = generate_service_unit(service, exec_set, config, &ready_gates);
        let unit_name = config.unit_name(&service.name);

        let units_dir = config.units_dir();
        std::fs::create_dir_all(&units_dir)?;

        let unit_path = units_dir.join(&unit_name);
        std::fs::write(&unit_path, &unit_content)?;

        Ok(vec![unit_path.display().to_string()])
    }

    fn generate_target(
        &self,
        _services: &[&Service],
        config: &Config,
    ) -> Result<String, PlatformError> {
        let content = generate_target(config);
        let units_dir = config.units_dir();
        std::fs::create_dir_all(&units_dir)?;

        let target_path = units_dir.join(config.target_name());
        std::fs::write(&target_path, &content)?;

        Ok(target_path.display().to_string())
    }

    fn install(&self, config: &Config) -> Result<(), PlatformError> {
        let units_dir = config.units_dir();
        let systemd_dir = self.systemd_dir(config);
        std::fs::create_dir_all(&systemd_dir).map_err(|e| {
            PlatformError::InstallFailed(format!("create {}: {}", systemd_dir.display(), e))
        })?;

        // Symlink each unit file into the systemd directory
        if let Ok(entries) = std::fs::read_dir(&units_dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if let Some(name) = path.file_name() {
                    let dest = systemd_dir.join(name);
                    // Remove existing symlink/file first
                    let _ = std::fs::remove_file(&dest);
                    std::os::unix::fs::symlink(&path, &dest).map_err(|e| {
                        PlatformError::InstallFailed(format!(
                            "failed to symlink {} -> {}: {}",
                            path.display(),
                            dest.display(),
                            e
                        ))
                    })?;
                }
            }
        }

        let mut cmd = std::process::Command::new("systemctl");
        if config.scope.is_user() { cmd.arg("--user"); }
        let status = cmd.arg("daemon-reload").status()
            .map_err(|e| PlatformError::InstallFailed(format!("systemctl daemon-reload: {}", e)))?;
        if !status.success() {
            return Err(PlatformError::InstallFailed("systemctl daemon-reload failed".into()));
        }
        Ok(())
    }

    fn clean(&self, config: &Config) -> Result<(), PlatformError> {
        let units_dir = config.units_dir();
        let systemd_dir = self.systemd_dir(config);

        // Remove symlinks from systemd directory
        if let Ok(entries) = std::fs::read_dir(&units_dir) {
            for entry in entries.flatten() {
                if let Some(name) = entry.path().file_name() {
                    let dest = systemd_dir.join(name);
                    let _ = std::fs::remove_file(&dest);
                }
            }
        }

        // Remove generated units
        let _ = std::fs::remove_dir_all(&units_dir);

        let mut cmd = std::process::Command::new("systemctl");
        if config.scope.is_user() { cmd.arg("--user"); }
        let _ = cmd.arg("daemon-reload").status();
        Ok(())
    }
}

impl SystemdPlatform {
    /// Generate all units for all services, including ready gates and target.
    /// This is the main entry point called by the engine.
    pub fn generate_all(
        &self,
        services: &[Service],
        exec_sets: &[(usize, ExecSet)],
        config: &Config,
    ) -> Result<Vec<String>, PlatformError> {
        let units_dir = config.units_dir();
        std::fs::create_dir_all(&units_dir)?;

        let ready_gates = services_needing_ready_gates(services);
        let mut generated = Vec::new();

        // Generate service units
        for (idx, exec_set) in exec_sets {
            let service = &services[*idx];
            let unit_content =
                generate_service_unit(service, exec_set, config, &ready_gates);
            let unit_name = config.unit_name(&service.name);
            let unit_path = units_dir.join(&unit_name);
            std::fs::write(&unit_path, &unit_content)?;
            generated.push(unit_path.display().to_string());
        }

        // Generate ready gate units
        for service in services {
            if ready_gates.contains(&service.name) {
                let gate_content = generate_ready_gate(service, config);
                let gate_name = format!("{}-{}-ready.service", config.namespace, service.name);
                let gate_path = units_dir.join(&gate_name);
                std::fs::write(&gate_path, &gate_content)?;
                generated.push(gate_path.display().to_string());
            }
        }

        // Generate target
        let target_content = generate_target(config);
        let target_path = units_dir.join(config.target_name());
        std::fs::write(&target_path, &target_content)?;
        generated.push(target_path.display().to_string());

        Ok(generated)
    }
}
