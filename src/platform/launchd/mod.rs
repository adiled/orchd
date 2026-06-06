pub mod generate;
pub mod lifecycle;

use std::path::PathBuf;

use crate::config::Config;
use crate::exec::ExecSet;
use crate::platform::{Platform, PlatformError};
use crate::types::Service;

use generate::{
    build_dep_gates, build_supervise_spec, generate_service_plist_with_deps, plist_filename,
    plist_label, supervise_spec_path,
};

pub struct LaunchdPlatform;

impl LaunchdPlatform {
    pub fn new() -> Self { LaunchdPlatform }
}

/// Install directory for plists, by scope.
pub fn install_dir(config: &Config) -> PathBuf {
    if config.scope.is_user() {
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("."));
        home.join("Library/LaunchAgents")
    } else {
        PathBuf::from("/Library/LaunchDaemons")
    }
}

/// Final installed plist path for a label.
pub fn plist_dest_path(config: &Config, label: &str) -> PathBuf {
    install_dir(config).join(format!("{}.plist", label))
}

impl Platform for LaunchdPlatform {
    fn check(&self) -> Result<(), PlatformError> {
        // launchctl must exist on PATH.
        let ok = std::process::Command::new("launchctl")
            .arg("help")
            .output()
            .map(|o| o.status.success() || !o.stdout.is_empty() || !o.stderr.is_empty())
            .unwrap_or(false);
        if !ok {
            return Err(PlatformError::PrerequisiteMissing(
                "launchctl not found on PATH".to_string(),
            ));
        }
        Ok(())
    }

    fn install(&self, config: &Config) -> Result<(), PlatformError> {
        let units_dir = config.units_dir();
        let dest_dir = install_dir(config);
        std::fs::create_dir_all(&dest_dir).map_err(|e| {
            PlatformError::InstallFailed(format!("create {}: {}", dest_dir.display(), e))
        })?;

        if let Ok(entries) = std::fs::read_dir(&units_dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) != Some("plist") {
                    continue;
                }
                if let Some(name) = path.file_name() {
                    let dest = dest_dir.join(name);
                    // Copy (not symlink) — launchd requires plists owned by the
                    // installing user and rejects some symlinks.
                    let _ = std::fs::remove_file(&dest);
                    std::fs::copy(&path, &dest).map_err(|e| {
                        PlatformError::InstallFailed(format!(
                            "copy {} -> {}: {}", path.display(), dest.display(), e
                        ))
                    })?;
                }
            }
        }
        Ok(())
    }

    fn clean(&self, config: &Config) -> Result<(), PlatformError> {
        let units_dir = config.units_dir();
        let dest_dir = install_dir(config);

        // bootout + remove each installed plist
        if let Ok(entries) = std::fs::read_dir(&units_dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) != Some("plist") {
                    continue;
                }
                if let Some(name) = path.file_name() {
                    let dest = dest_dir.join(name);
                    if dest.exists() {
                        let dom = if config.scope.is_user() {
                            format!("gui/{}", current_uid())
                        } else {
                            "system".to_string()
                        };
                        let _ = std::process::Command::new("launchctl")
                            .args(["bootout", &dom, dest.to_str().unwrap_or("")])
                            .status();
                        let _ = std::fs::remove_file(&dest);
                    }
                }
            }
        }

        let _ = std::fs::remove_dir_all(&units_dir);
        Ok(())
    }
}

impl LaunchdPlatform {
    /// Generate plists for all enabled services. Mirrors SystemdPlatform::generate_all.
    pub fn generate_all(
        &self,
        services: &[Service],
        exec_sets: &[(usize, ExecSet)],
        config: &Config,
    ) -> Result<Vec<String>, PlatformError> {
        let units_dir = config.units_dir();
        std::fs::create_dir_all(&units_dir)?;

        let mut generated = Vec::new();
        let spec_dir = config.state_dir.join("supervise");
        for (idx, exec_set) in exec_sets {
            let service = &services[*idx];
            let deps = build_dep_gates(service, services);

            // Orchestrated services (deps or teardown) need a supervisor spec.
            let needs_supervisor =
                !deps.is_empty() || exec_set.stop.is_some() || exec_set.post_stop.is_some();
            if needs_supervisor {
                std::fs::create_dir_all(&spec_dir)?;
                let label = plist_label(config, &service.name);
                let spec = build_supervise_spec(service, exec_set, config, &deps);
                let json = serde_json::to_string_pretty(&spec)
                    .map_err(|e| PlatformError::GenerationFailed(e.to_string()))?;
                let spec_path = supervise_spec_path(config, &label);
                std::fs::write(&spec_path, json)?;
                generated.push(spec_path);
            }

            let content = generate_service_plist_with_deps(service, exec_set, config, &deps);
            let path = units_dir.join(plist_filename(config, &service.name));
            std::fs::write(&path, &content)?;
            generated.push(path.display().to_string());
        }
        Ok(generated)
    }
}

fn current_uid() -> String {
    let out = std::process::Command::new("id").arg("-u").output();
    match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim().to_string(),
        _ => "0".to_string(),
    }
}

#[cfg(test)]
#[allow(non_snake_case)]
mod tests {
    use super::*;
    use crate::config::Scope;
    use std::path::PathBuf;

    fn test_config(scope: Scope) -> Config {
        Config {
            orchfile: PathBuf::from("/test/Orchfile"),
            overlays: Vec::new(),
            runtime: "bare".to_string(),
            platform: "launchd".to_string(),
            scope,
            state_dir: PathBuf::from("/test/.orch"),
            project_dir: PathBuf::from("/test/project"),
            data_dir: PathBuf::from("/test/.orch/data"),
            namespace: "orch".to_string(),
            args: Vec::new(),
            verbose: false,
            quiet: false,
        }
    }

    #[test]
    fn test_install_dir__system() {
        let cfg = test_config(Scope::System);
        assert_eq!(install_dir(&cfg), PathBuf::from("/Library/LaunchDaemons"));
    }

    #[test]
    fn test_install_dir__user_uses_home() {
        unsafe { std::env::set_var("HOME", "/Users/test"); }
        let cfg = test_config(Scope::User);
        assert_eq!(install_dir(&cfg), PathBuf::from("/Users/test/Library/LaunchAgents"));
    }

    #[test]
    fn test_plist_dest_path__joins_install_dir() {
        unsafe { std::env::set_var("HOME", "/Users/test"); }
        let cfg = test_config(Scope::User);
        let p = plist_dest_path(&cfg, "orch.web");
        assert_eq!(p, PathBuf::from("/Users/test/Library/LaunchAgents/orch.web.plist"));
    }
}