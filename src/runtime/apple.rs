//! Apple container runtime — a thin envelope over three operating modes.
//!
//! The `apple` runtime is one Rust shell with three interchangeable backends.
//! All three turn a container Service into the same `ExecSet` contract; they
//! differ only in HOW the container is actually run:
//!
//!   1. ContainerCli  — shell out to Apple's `container` CLI. Generated here
//!                       in Rust as plain `container run/stop/delete` strings.
//!   2. OrchdApple    — co-process `orchd-apple`, driving the pinned daemon
//!                       directly over XPC (no CLI). Current default.
//!   3. OrchdOsx      — co-process `orchd-osx`, a from-scratch runtime built on
//!                       Virtualization.framework (no daemon, no Swift linked).
//!
//! Modes 2 and 3 are the same code path from Rust's side: spawn a co-process
//! that speaks a small JSON-over-stdio protocol (check / exec-set / prepare /
//! cleanup). They differ only in which binary is spawned, so `orchd-osx` can be
//! built out independently as a drop-in that honors the same contract.
//!
//! Select the mode with `ORCHD_APPLE_MODE`:
//!   container | cli      -> ContainerCli
//!   xpc | daemon | apple -> OrchdApple   (default)
//!   osx | vz             -> OrchdOsx
//!
//! Override binary locations with `ORCHD_APPLE_BIN` / `ORCHD_OSX_BIN`.

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use crate::config::Config;
use crate::exec::ExecSet;
use crate::runtime::{Runtime, RuntimeError};
use crate::types::Service;

/// Which backend actually runs containers for the `apple` runtime.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum AppleMode {
    /// Shell out to Apple's `container` CLI.
    ContainerCli,
    /// Co-process `orchd-apple`: drive the pinned daemon over XPC.
    OrchdApple,
    /// Co-process `orchd-osx`: from-scratch Virtualization.framework runtime.
    OrchdOsx,
}

impl AppleMode {
    /// Resolve the mode from `ORCHD_APPLE_MODE`, defaulting to the proven XPC
    /// co-process. Unknown values fall back to the default with a warning.
    fn from_env() -> Self {
        match std::env::var("ORCHD_APPLE_MODE") {
            Ok(v) => Self::parse(&v),
            Err(_) => AppleMode::OrchdApple,
        }
    }

    fn parse(s: &str) -> Self {
        match s.trim().to_ascii_lowercase().as_str() {
            "container" | "cli" => AppleMode::ContainerCli,
            "osx" | "vz" | "orchd-osx" => AppleMode::OrchdOsx,
            "xpc" | "daemon" | "apple" | "orchd-apple" | "" => AppleMode::OrchdApple,
            other => {
                eprintln!(
                    "warning: unknown ORCHD_APPLE_MODE '{other}', using 'xpc' (orchd-apple)"
                );
                AppleMode::OrchdApple
            }
        }
    }

    /// The co-process binary for binary-backed modes, if any.
    fn binary(self) -> Option<(&'static str, &'static str)> {
        match self {
            AppleMode::ContainerCli => None,
            AppleMode::OrchdApple => Some(("orchd-apple", "ORCHD_APPLE_BIN")),
            AppleMode::OrchdOsx => Some(("orchd-osx", "ORCHD_OSX_BIN")),
        }
    }
}

pub struct AppleRuntime {
    /// Selected backend.
    mode: AppleMode,
    /// Co-process binary path (None in ContainerCli mode).
    bin: Option<PathBuf>,
    /// Namespace prefix for container names (e.g. "orch" -> "orch-postgres").
    namespace: String,
    /// Data directory (for host-mode services that share the bare prepare step).
    data_dir: PathBuf,
}

impl AppleRuntime {
    pub fn new(config: &Config) -> Self {
        let mode = AppleMode::from_env();
        let bin = mode
            .binary()
            .map(|(name, env_var)| resolve_bin(name, env_var));

        AppleRuntime {
            mode,
            bin,
            namespace: config.namespace.clone(),
            data_dir: config.data_dir.clone(),
        }
    }

    fn container_name(&self, service: &Service) -> String {
        format!("{}-{}", self.namespace, service.name)
    }

    /// Spawn the co-process `<bin> <subcommand> [namespace]` with `input` on
    /// stdin. Returns stdout on success. Used by OrchdApple / OrchdOsx modes.
    fn call(&self, subcommand: &str, input: Option<&[u8]>) -> Result<String, RuntimeError> {
        let bin = self
            .bin
            .as_ref()
            .expect("call() is only used in binary-backed modes");

        let mut cmd = Command::new(bin);
        cmd.arg(subcommand).arg(&self.namespace);

        if input.is_some() {
            cmd.stdin(Stdio::piped());
        }
        cmd.stdout(Stdio::piped());
        // stderr is inherited so orchd's terminal shows pull progress, etc.

        let mut child = cmd.spawn().map_err(|e| {
            RuntimeError::BinaryNotFound(format!("could not spawn '{}': {e}", bin.display()))
        })?;

        if let Some(bytes) = input {
            let stdin = child.stdin.as_mut().expect("stdin piped");
            stdin
                .write_all(bytes)
                .map_err(|e| RuntimeError::Other(format!("failed to write to co-process stdin: {e}")))?;
        }

        let output = child
            .wait_with_output()
            .map_err(|e| RuntimeError::Other(format!("co-process wait failed: {e}")))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(RuntimeError::Other(format!(
                "{} {subcommand} failed (exit {}): {}",
                bin.display(),
                output.status.code().unwrap_or(-1),
                stderr.trim()
            )));
        }

        String::from_utf8(output.stdout)
            .map_err(|e| RuntimeError::Other(format!("co-process stdout is invalid UTF-8: {e}")))
    }

    // ── Mode 1: container CLI ──────────────────────────────────────────────

    /// Liveness via the `container` CLI: `container ls` requires a live daemon.
    fn cli_check(&self) -> Result<(), RuntimeError> {
        let status = Command::new("container")
            .arg("ls")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map_err(|e| {
                RuntimeError::BinaryNotFound(format!("could not spawn 'container': {e}"))
            })?;
        if status.success() {
            Ok(())
        } else {
            Err(RuntimeError::Other(
                "container CLI/daemon not reachable (run: container system start)".to_string(),
            ))
        }
    }

    fn cli_prepare(&self, service: &Service) -> Result<(), RuntimeError> {
        let image = self.require_image(service)?;
        let status = Command::new("container")
            .args(["image", "pull", image])
            .status()
            .map_err(|e| {
                RuntimeError::BinaryNotFound(format!("could not spawn 'container': {e}"))
            })?;
        if status.success() {
            Ok(())
        } else {
            Err(RuntimeError::Other(format!(
                "container image pull {image} failed"
            )))
        }
    }

    /// Generate the `container` CLI ExecSet (the historical mode-1 path).
    fn cli_exec_set(&self, service: &Service) -> Result<ExecSet, RuntimeError> {
        let image = self.require_image(service)?;
        let name = self.container_name(service);

        let pre_start = format!("container image pull {image}");

        // --init forwards signals and reaps zombies inside the container.
        let mut start = format!("container run --name {name} --init");

        // env, sorted for deterministic output.
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
            stop: Some(format!("container stop {name}")),
            post_stop: Some(format!("container delete --force {name}")),
        })
    }

    // ── Shared helpers ─────────────────────────────────────────────────────

    fn require_image<'a>(&self, service: &'a Service) -> Result<&'a str, RuntimeError> {
        service.image.as_deref().ok_or_else(|| {
            RuntimeError::Other(format!(
                "service '{}' is container-mode but has no FROM image",
                service.name
            ))
        })
    }

    /// Host-mode services are handled identically across all three modes:
    /// they pass through as a plain process, same as the bare runtime.
    fn host_prepare(&self, service: &Service) -> Result<(), RuntimeError> {
        let service_data = self.data_dir.join(&service.name);
        std::fs::create_dir_all(&service_data).map_err(|e| {
            RuntimeError::Other(format!(
                "failed to create data directory '{}': {e}",
                service_data.display()
            ))
        })
    }

    fn host_exec_set(&self, service: &Service) -> Result<ExecSet, RuntimeError> {
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
}

impl Runtime for AppleRuntime {
    fn name(&self) -> &str {
        "apple"
    }

    fn check(&self) -> Result<(), RuntimeError> {
        match self.mode {
            AppleMode::ContainerCli => self.cli_check(),
            AppleMode::OrchdApple | AppleMode::OrchdOsx => self.call("check", None).map(|_| ()),
        }
    }

    fn prepare(&self, service: &Service) -> Result<(), RuntimeError> {
        if service.is_host() {
            return self.host_prepare(service);
        }
        match self.mode {
            AppleMode::ContainerCli => self.cli_prepare(service),
            AppleMode::OrchdApple | AppleMode::OrchdOsx => {
                let service_json =
                    serde_json::to_vec(service).map_err(|e| RuntimeError::Other(e.to_string()))?;
                self.call("prepare", Some(&service_json)).map(|_| ())
            }
        }
    }

    fn exec_set(&self, service: &Service) -> Result<ExecSet, RuntimeError> {
        if service.is_host() {
            return self.host_exec_set(service);
        }
        match self.mode {
            AppleMode::ContainerCli => self.cli_exec_set(service),
            AppleMode::OrchdApple | AppleMode::OrchdOsx => {
                let service_json =
                    serde_json::to_vec(service).map_err(|e| RuntimeError::Other(e.to_string()))?;
                let stdout = self.call("exec-set", Some(&service_json))?;
                serde_json::from_str::<ExecSet>(&stdout).map_err(|e| {
                    RuntimeError::Other(format!(
                        "failed to deserialize ExecSet from co-process: {e}\nraw: {stdout}"
                    ))
                })
            }
        }
    }
}

/// Resolve a co-process binary: explicit env override, else next to the current
/// executable, else bare name on PATH.
fn resolve_bin(binary: &str, env_var: &str) -> PathBuf {
    std::env::var(env_var)
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            std::env::current_exe()
                .ok()
                .and_then(|p| p.parent().map(|d| d.join(binary)))
                .filter(|p| p.exists())
                .unwrap_or_else(|| PathBuf::from(binary))
        })
}

#[cfg(test)]
#[allow(non_snake_case)]
mod tests {
    use super::*;

    fn runtime(mode: AppleMode, bin: Option<PathBuf>) -> AppleRuntime {
        AppleRuntime {
            mode,
            bin,
            namespace: "orch".to_string(),
            data_dir: std::env::temp_dir().join("orchd-apple-test-data"),
        }
    }

    /// Locate the built orchd-apple Zig binary, or skip the test if it's absent.
    fn zig_bin() -> Option<PathBuf> {
        let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("orchd-apple/zig-out/bin/orchd-apple");
        if p.exists() { Some(p) } else { None }
    }

    #[test]
    fn test_mode__parses_from_env_strings() {
        assert_eq!(AppleMode::parse("container"), AppleMode::ContainerCli);
        assert_eq!(AppleMode::parse("cli"), AppleMode::ContainerCli);
        assert_eq!(AppleMode::parse("xpc"), AppleMode::OrchdApple);
        assert_eq!(AppleMode::parse("daemon"), AppleMode::OrchdApple);
        assert_eq!(AppleMode::parse("osx"), AppleMode::OrchdOsx);
        assert_eq!(AppleMode::parse("vz"), AppleMode::OrchdOsx);
        assert_eq!(AppleMode::parse("OSX"), AppleMode::OrchdOsx);
        // Unknown falls back to the proven default.
        assert_eq!(AppleMode::parse("bogus"), AppleMode::OrchdApple);
    }

    #[test]
    fn test_mode__binary_mapping() {
        assert_eq!(AppleMode::ContainerCli.binary(), None);
        assert_eq!(
            AppleMode::OrchdApple.binary(),
            Some(("orchd-apple", "ORCHD_APPLE_BIN"))
        );
        assert_eq!(
            AppleMode::OrchdOsx.binary(),
            Some(("orchd-osx", "ORCHD_OSX_BIN"))
        );
    }

    /// Mode 1 generates the container CLI ExecSet purely in Rust (no co-process).
    #[test]
    fn test_cli_exec_set__generates_container_commands() {
        let rt = runtime(AppleMode::ContainerCli, None);
        let mut svc: Service = serde_json::from_str(STUB_CONTAINER).unwrap();
        svc.name = "postgres".into();
        svc.image = Some("postgres:15".into());
        svc.env.insert("FOO".into(), "bar".into());
        svc.publish = vec![crate::types::PortMapping {
            address: None,
            host: 8080,
            container: 80,
        }];
        svc.resources.memory = Some("512M".into());
        svc.resources.cpus = Some(2.0);

        let exec = rt.exec_set(&svc).expect("cli exec_set");

        assert_eq!(
            exec.pre_start.as_deref(),
            Some("container image pull postgres:15")
        );
        assert!(exec.start.starts_with("container run --name orch-postgres --init"));
        assert!(exec.start.contains(" --env FOO=bar"));
        assert!(exec.start.contains(" --publish 8080:80"));
        assert!(exec.start.contains(" --memory 512M"));
        assert!(exec.start.contains(" --cpus 2"));
        assert!(exec.start.ends_with(" postgres:15"));
        assert_eq!(exec.stop.as_deref(), Some("container stop orch-postgres"));
        assert_eq!(
            exec.post_stop.as_deref(),
            Some("container delete --force orch-postgres")
        );
    }

    /// Mode 2 (OrchdApple): the co-process drives the XPC backend. The ExecSet
    /// re-invokes the orchd-apple binary, not the `container` CLI.
    #[test]
    fn test_orchd_apple_mode__drives_zig_binary() {
        let Some(bin) = zig_bin() else {
            eprintln!("skipping: orchd-apple binary not built");
            return;
        };
        let rt = runtime(AppleMode::OrchdApple, Some(bin));

        let mut svc: Service = serde_json::from_str(STUB_CONTAINER).unwrap();
        svc.name = "postgres".into();
        svc.image = Some("postgres:15".into());

        let exec = rt.exec_set(&svc).expect("exec_set should succeed");
        assert!(exec.start.contains(" run orch-postgres postgres:15"));
        assert!(exec.start.contains(" wait orch-postgres"));
        assert!(!exec.start.contains("container "));
        assert!(exec.pre_start.as_deref().unwrap().ends_with(" pull postgres:15"));
        assert!(exec.stop.as_deref().unwrap().ends_with(" stop orch-postgres"));
        assert!(exec.post_stop.as_deref().unwrap().ends_with(" delete orch-postgres"));
    }

    /// Host-mode services pass through unchanged in every mode.
    #[test]
    fn test_host_mode__passthrough() {
        let rt = runtime(AppleMode::ContainerCli, None);
        let mut svc: Service = serde_json::from_str(STUB_HOST).unwrap();
        svc.run_command = Some("/usr/bin/nginx".into());

        let exec = rt.exec_set(&svc).expect("host passthrough");
        assert_eq!(exec.start, "/usr/bin/nginx");
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
