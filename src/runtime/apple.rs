//! Apple container runtime — delegates to the `orchd-apple` Zig binary.
//!
//! The Zig binary handles:
//!   check   → XPC ping to com.apple.container.apiserver
//!   exec-set → translate Service → ExecSet (container CLI commands)
//!   prepare  → `container image pull`
//!   cleanup  → delete container via XPC
//!
//! Communication protocol: JSON on stdin/stdout.

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use crate::config::Config;
use crate::exec::ExecSet;
use crate::runtime::{Runtime, RuntimeError};
use crate::types::Service;

pub struct AppleRuntime {
    /// Path to the `orchd-apple` Zig binary.
    bin: PathBuf,
    /// Namespace prefix for container names (e.g. "orch" → "orch-postgres").
    namespace: String,
    /// Data directory (for bare services that share the same prepare step).
    data_dir: PathBuf,
}

impl AppleRuntime {
    pub fn new(config: &Config) -> Self {
        // Convention: orchd-apple lives next to the orchd binary, or is found
        // in PATH. Configurable via ORCHD_APPLE_BIN env var.
        let bin = std::env::var("ORCHD_APPLE_BIN")
            .map(PathBuf::from)
            .unwrap_or_else(|_| {
                // Try next to the current executable first.
                std::env::current_exe()
                    .ok()
                    .and_then(|p| p.parent().map(|d| d.join("orchd-apple")))
                    .filter(|p| p.exists())
                    .unwrap_or_else(|| PathBuf::from("orchd-apple"))
            });

        AppleRuntime {
            bin,
            namespace: config.namespace.clone(),
            data_dir: config.data_dir.clone(),
        }
    }

    /// Spawn `orchd-apple <subcommand> [namespace]` with `input` on stdin.
    /// Returns stdout as a String on success, RuntimeError on non-zero exit.
    fn call(&self, subcommand: &str, input: Option<&[u8]>) -> Result<String, RuntimeError> {
        let mut cmd = Command::new(&self.bin);
        cmd.arg(subcommand).arg(&self.namespace);

        if input.is_some() {
            cmd.stdin(Stdio::piped());
        }
        cmd.stdout(Stdio::piped());
        // stderr is inherited so orchd's terminal shows pull progress, etc.

        let mut child = cmd.spawn().map_err(|e| {
            RuntimeError::BinaryNotFound(format!(
                "could not spawn '{}': {e}",
                self.bin.display()
            ))
        })?;

        if let Some(bytes) = input {
            let stdin = child.stdin.as_mut().expect("stdin piped");
            stdin.write_all(bytes).map_err(|e| {
                RuntimeError::Other(format!("failed to write to orchd-apple stdin: {e}"))
            })?;
        }

        let output = child.wait_with_output().map_err(|e| {
            RuntimeError::Other(format!("orchd-apple wait failed: {e}"))
        })?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(RuntimeError::Other(format!(
                "orchd-apple {subcommand} failed (exit {}): {}",
                output.status.code().unwrap_or(-1),
                stderr.trim()
            )));
        }

        String::from_utf8(output.stdout).map_err(|e| {
            RuntimeError::Other(format!("orchd-apple stdout is invalid UTF-8: {e}"))
        })
    }
}

impl Runtime for AppleRuntime {
    fn name(&self) -> &str {
        "apple"
    }

    fn check(&self) -> Result<(), RuntimeError> {
        self.call("check", None).map(|_| ())
    }

    fn prepare(&self, service: &Service) -> Result<(), RuntimeError> {
        if service.is_host() {
            // Host-mode services on macOS need a data directory, same as bare.
            let service_data = self.data_dir.join(&service.name);
            std::fs::create_dir_all(&service_data).map_err(|e| {
                RuntimeError::Other(format!(
                    "failed to create data directory '{}': {e}",
                    service_data.display()
                ))
            })?;
            return Ok(());
        }

        let service_json = serde_json::to_vec(service)
            .map_err(|e| RuntimeError::Other(e.to_string()))?;

        self.call("prepare", Some(&service_json)).map(|_| ())
    }

    fn exec_set(&self, service: &Service) -> Result<ExecSet, RuntimeError> {
        if service.is_host() {
            // Apple runtime passes host-mode services straight through (same as bare).
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

        let service_json = serde_json::to_vec(service)
            .map_err(|e| RuntimeError::Other(e.to_string()))?;

        let stdout = self.call("exec-set", Some(&service_json))?;

        serde_json::from_str::<ExecSet>(&stdout).map_err(|e| {
            RuntimeError::Other(format!(
                "failed to deserialize ExecSet from orchd-apple: {e}\nraw: {stdout}"
            ))
        })
    }
}

#[cfg(test)]
#[allow(non_snake_case)]
mod tests {
    use super::*;
    use crate::types::ServiceMode;

    /// Locate the built orchd-apple Zig binary, or skip the test if it's absent.
    fn zig_bin() -> Option<PathBuf> {
        let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("orchd-apple/zig-out/bin/orchd-apple");
        if p.exists() { Some(p) } else { None }
    }

    fn apple_runtime(bin: PathBuf) -> AppleRuntime {
        AppleRuntime {
            bin,
            namespace: "orch".to_string(),
            data_dir: std::env::temp_dir().join("orchd-apple-test-data"),
        }
    }

    /// Integration: the Rust shim drives the real Zig binary to translate a
    /// container Service into an ExecSet. Requires `cd orchd-apple && zig build`.
    #[test]
    fn test_exec_set__drives_zig_binary() {
        let Some(bin) = zig_bin() else {
            eprintln!("skipping: orchd-apple binary not built");
            return;
        };
        let rt = apple_runtime(bin);

        let mut svc = Service {
            name: "postgres".to_string(),
            mode: ServiceMode::Container,
            image: Some("postgres:15".to_string()),
            ..serde_json::from_str(STUB_CONTAINER).unwrap()
        };
        svc.publish = vec![];

        let exec = rt.exec_set(&svc).expect("exec_set should succeed");

        assert!(exec.start.contains("container run --name orch-postgres"));
        assert!(exec.start.contains("--init"));
        assert!(exec.start.contains("postgres:15"));
        assert_eq!(
            exec.pre_start.as_deref(),
            Some("container image pull postgres:15")
        );
        assert_eq!(exec.stop.as_deref(), Some("container stop orch-postgres"));
        assert_eq!(
            exec.post_stop.as_deref(),
            Some("container delete --force orch-postgres")
        );
    }

    /// Host-mode services pass through unchanged (same as bare runtime).
    #[test]
    fn test_exec_set__host_mode_passthrough() {
        let Some(bin) = zig_bin() else { return };
        let rt = apple_runtime(bin);

        let svc = Service {
            name: "web".to_string(),
            mode: ServiceMode::Host,
            run_command: Some("/usr/bin/nginx".to_string()),
            ..serde_json::from_str(STUB_HOST).unwrap()
        };

        let exec = rt.exec_set(&svc).expect("host passthrough should succeed");
        assert_eq!(exec.start, "/usr/bin/nginx");
        assert!(exec.pre_start.is_none());
    }

    // Minimal JSON stubs to fill the non-relevant Service fields via serde defaults.
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
