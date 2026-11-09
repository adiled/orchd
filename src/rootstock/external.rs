use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use serde::Serialize;

use super::{Rootstock, RootstockError};
use crate::config::Config;
use crate::exec::ExecSet;
use crate::types::Service;

pub const CONTRACT: u32 = 1;

pub fn plugin_name(name: &str) -> String {
    format!("orchd-rootstock-{}", name)
}

pub fn find_plugin(name: &str, exe_dir: Option<&Path>, path_var: &str) -> Option<PathBuf> {
    let file = plugin_name(name);
    exe_dir
        .map(Path::to_path_buf)
        .into_iter()
        .chain(std::env::split_paths(path_var))
        .map(|dir| dir.join(&file))
        .find(|p| is_executable(p))
}

fn is_executable(p: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(p)
        .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

#[derive(Serialize)]
struct Context {
    grove: String,
    project_dir: String,
    data_dir: String,
    state_dir: String,
}

#[derive(Serialize)]
struct Envelope<'a> {
    contract: u32,
    #[serde(flatten)]
    context: &'a Context,
    service: &'a Service,
}

pub struct ExternalRootstock {
    name: String,
    bin: PathBuf,
    context: Context,
}

impl ExternalRootstock {
    pub fn new(name: &str, bin: PathBuf, config: &Config) -> Self {
        ExternalRootstock {
            name: name.to_string(),
            bin,
            context: Context {
                grove: config.grove.clone(),
                project_dir: config.project_dir.display().to_string(),
                data_dir: config.data_dir.display().to_string(),
                state_dir: config.state_dir.display().to_string(),
            },
        }
    }

    fn call(&self, verb: &str, service: Option<&Service>) -> Result<String, RootstockError> {
        let plugin = plugin_name(&self.name);
        let mut child = Command::new(&self.bin)
            .arg(verb)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| RootstockError::Other(format!("{} {}: {}", plugin, verb, e)))?;

        let mut stdin = child.stdin.take().expect("stdin piped");
        if let Some(service) = service {
            let envelope = Envelope {
                contract: CONTRACT,
                context: &self.context,
                service,
            };
            let json = serde_json::to_vec(&envelope)
                .map_err(|e| RootstockError::Other(format!("{} {}: {}", plugin, verb, e)))?;
            match stdin.write_all(&json) {
                Err(e) if e.kind() != std::io::ErrorKind::BrokenPipe => {
                    return Err(RootstockError::Other(format!("{} {}: {}", plugin, verb, e)));
                }
                _ => {}
            }
        }
        drop(stdin);

        let out = child
            .wait_with_output()
            .map_err(|e| RootstockError::Other(format!("{} {}: {}", plugin, verb, e)))?;
        if !out.status.success() {
            return Err(RootstockError::Other(format!(
                "{} {} failed: {}",
                plugin,
                verb,
                String::from_utf8_lossy(&out.stderr).trim()
            )));
        }
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    }
}

impl Rootstock for ExternalRootstock {
    fn name(&self) -> &str {
        &self.name
    }

    fn check(&self) -> Result<(), RootstockError> {
        let spoken = self.call("contract", None)?;
        if !spoken.split_whitespace().any(|v| v == CONTRACT.to_string()) {
            return Err(RootstockError::Other(format!(
                "{} speaks contract {}, orchd needs {}",
                plugin_name(&self.name),
                spoken.trim(),
                CONTRACT
            )));
        }
        self.call("check", None).map(|_| ())
    }

    fn prepare(&self, service: &Service) -> Result<(), RootstockError> {
        self.call("prepare", Some(service)).map(|_| ())
    }

    fn exec_set(&self, service: &Service) -> Result<ExecSet, RootstockError> {
        let out = self.call("exec-set", Some(service))?;
        serde_json::from_str(&out).map_err(|e| {
            RootstockError::Other(format!(
                "{} exec-set: not an ExecSet: {}",
                plugin_name(&self.name),
                e
            ))
        })
    }
}

#[cfg(test)]
#[allow(non_snake_case)]
mod tests {
    use super::*;
    use crate::config::Scope;
    use crate::types::*;
    use std::collections::HashMap;
    use std::os::unix::fs::PermissionsExt;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("orchd-rootstock-{}", name));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn plugin(dir: &Path, name: &str, body: &str) -> PathBuf {
        let path = dir.join(plugin_name(name));
        let draft = dir.join(format!("{}.draft", plugin_name(name)));
        std::fs::write(&draft, format!("#!/bin/sh\n{}\n", body)).unwrap();
        let copied = Command::new("cp").arg(&draft).arg(&path).status().unwrap();
        assert!(copied.success());
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    fn config(dir: &Path) -> Config {
        Config {
            orchfile: dir.join("Orchfile"),
            overlays: Vec::new(),
            rootstock: "fake".to_string(),
            platform: "launchd".to_string(),
            scope: Scope::User,
            state_dir: dir.join("state"),
            project_dir: dir.join("proj"),
            data_dir: dir.join("state/data/g"),
            grove: "g".to_string(),
            args: Vec::new(),
            verbose: false,
            quiet: true,
        }
    }

    fn service(name: &str) -> Service {
        Service {
            name: name.to_string(),
            mode: ServiceMode::Host,
            image: None,
            run_command: Some("sleep 1".to_string()),
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
    fn test_find_plugin__beside_orchd_first_then_path() {
        let dir = scratch("path");
        let (a, b) = (dir.join("a"), dir.join("b"));
        std::fs::create_dir_all(&a).unwrap();
        std::fs::create_dir_all(&b).unwrap();
        std::fs::write(a.join(plugin_name("fake")), "not executable").unwrap();
        let want = plugin(&b, "fake", "exit 0");
        let path_var = format!("{}:{}", a.display(), b.display());

        assert_eq!(find_plugin("fake", None, &path_var), Some(want));
        assert_eq!(find_plugin("absent", None, &path_var), None);

        let beside = dir.join("beside");
        std::fs::create_dir_all(&beside).unwrap();
        let own = plugin(&beside, "fake", "exit 0");
        assert_eq!(find_plugin("fake", Some(&beside), &path_var), Some(own));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_exec_set__sends_the_envelope_and_reads_the_exec_set() {
        let dir = scratch("exec-set");
        let seen = dir.join("envelope.json");
        let bin = plugin(
            &dir,
            "fake",
            &format!(
                "case \"$1\" in\n  contract) echo 1 ;;\n  check) exit 0 ;;\n  exec-set) cat > {} ; echo '{{\"start\":\"fake run web\"}}' ;;\nesac",
                seen.display()
            ),
        );
        let rootstock = ExternalRootstock::new("fake", bin, &config(&dir));

        rootstock.check().unwrap();
        let exec = rootstock.exec_set(&service("web")).unwrap();

        assert_eq!(exec.start, "fake run web");
        let envelope: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&seen).unwrap()).unwrap();
        assert_eq!(envelope["contract"], CONTRACT);
        assert_eq!(envelope["grove"], "g");
        assert_eq!(
            envelope["project_dir"],
            dir.join("proj").display().to_string()
        );
        assert_eq!(
            envelope["data_dir"],
            dir.join("state/data/g").display().to_string()
        );
        assert_eq!(envelope["service"]["name"], "web");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_check__refuses_another_contract() {
        let dir = scratch("contract");
        let bin = plugin(&dir, "fake", "echo 2");
        let rootstock = ExternalRootstock::new("fake", bin, &config(&dir));

        let err = rootstock.check().unwrap_err().to_string();
        assert!(err.contains("speaks contract 2, orchd needs 1"), "{}", err);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_call__a_failing_verb_carries_its_stderr() {
        let dir = scratch("fail");
        let bin = plugin(&dir, "fake", "echo 'no image for web' >&2; exit 3");
        let rootstock = ExternalRootstock::new("fake", bin, &config(&dir));

        let err = rootstock.prepare(&service("web")).unwrap_err().to_string();
        assert!(
            err.contains("orchd-rootstock-fake prepare failed: no image for web"),
            "{}",
            err
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
