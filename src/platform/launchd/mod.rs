pub mod generate;
pub mod lifecycle;

use std::path::PathBuf;

use crate::config::Config;
use crate::exec::ExecSet;
use crate::platform::{Platform, PlatformError};
use crate::types::Service;

use generate::{generate_service_plist, plist_filename, plist_label};

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
    fn name(&self) -> &str { "launchd" }

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

    fn generate(
        &self,
        service: &Service,
        exec_set: &ExecSet,
        config: &Config,
    ) -> Result<Vec<String>, PlatformError> {
        let content = generate_service_plist(service, exec_set, config);
        let units_dir = config.units_dir();
        std::fs::create_dir_all(&units_dir)?;

        let path = units_dir.join(plist_filename(config, &service.name));
        std::fs::write(&path, &content)?;
        Ok(vec![path.display().to_string()])
    }

    fn generate_target(
        &self,
        _services: &[&Service],
        _config: &Config,
    ) -> Result<String, PlatformError> {
        // launchd has no native "target" concept — services are managed
        // individually. Return empty path to keep the trait happy.
        Ok(String::new())
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
        for (idx, exec_set) in exec_sets {
            let service = &services[*idx];
            let content = generate_service_plist(service, exec_set, config);
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

#[allow(dead_code)]
pub fn label_for(config: &Config, service_name: &str) -> String {
    plist_label(config, service_name)
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
            orch_bin: PathBuf::from("orch"),
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

    #[test]
    fn test_platform_name__is_launchd() {
        let p = LaunchdPlatform::new();
        assert_eq!(p.name(), "launchd");
    }

    #[test]
    fn test_label_for__namespace_dot_name() {
        let cfg = test_config(Scope::User);
        assert_eq!(label_for(&cfg, "web"), "orch.web");
    }
}
