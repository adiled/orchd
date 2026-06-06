//! `orchdi` — orchd's own service supervisor. The init orchd carries with it.
//!
//! This is the mechanism the platforms wrap: it reads a `SuperviseSpec` (four
//! ExecSet command strings + deps + timeout) and babysits one service through
//! its whole life. It is runtime-agnostic (apple / containerd / podman / bare
//! all flow through the same four strings) and platform-independent.
//!
//! Who launches it differs by platform: `launchd` and `systemd` register it as
//! a job (so the OS starts it on boot and resurrects it); the `orchdi` platform
//! runs it raw, tracked by a pidfile, where there is no OS init to lean on
//! (containers, CI, WSL). Invoked as the `orchd supervise --spec <path>` leaf.
//!
//! Lifecycle:
//!   1. wait for dependencies to become healthy (REQUIRES aborts, AFTER proceeds)
//!   2. run pre_start (e.g. image pull); abort on failure
//!   3. spawn start in its own process group
//!   4. on child exit  -> run post_stop, exit with child's code
//!      on SIGTERM/INT  -> run stop (or signal the group), bounded wait,
//!                         SIGKILL the group if needed, run post_stop, exit 0

use std::path::Path;
use std::process::{Child, Command};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::config::Config;
use crate::exec::ExecSet;
use crate::types::Service;

/// A dependency the service waits on before starting.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DepSpec {
    /// Command whose success (exit 0) means the dependency is ready.
    pub poll_cmd: String,
    pub timeout_secs: u32,
    /// REQUIRES (true) aborts start on timeout; AFTER (false) proceeds.
    pub required: bool,
}

/// Everything the supervisor needs, built from a `Service` + its `ExecSet`.
/// Runtime-agnostic: only command strings, never runtime identity.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SuperviseSpec {
    pub label: String,
    pub pre_start: Option<String>,
    pub start: String,
    pub stop: Option<String>,
    pub post_stop: Option<String>,
    #[serde(default)]
    pub deps: Vec<DepSpec>,
    /// Seconds to wait for graceful stop before SIGKILLing the process group.
    pub stop_timeout_secs: u32,
}

static TERM: AtomicBool = AtomicBool::new(false);

extern "C" fn on_term(_sig: i32) {
    TERM.store(true, Ordering::SeqCst);
}

/// Entry point for `orchd supervise --spec <path>`. Blocks for the service's
/// lifetime. Returns the process exit code.
pub fn run(spec_path: &Path) -> i32 {
    let data = match std::fs::read_to_string(spec_path) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("supervise: cannot read spec {}: {e}", spec_path.display());
            return 1;
        }
    };
    let spec: SuperviseSpec = match serde_json::from_str(&data) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("supervise: invalid spec {}: {e}", spec_path.display());
            return 1;
        }
    };

    // 1. Dependency readiness.
    for dep in &spec.deps {
        if !wait_healthy(&dep.poll_cmd, dep.timeout_secs) {
            if dep.required {
                eprintln!(
                    "supervise[{}]: required dependency not ready: {}",
                    spec.label, dep.poll_cmd
                );
                return 1;
            }
            eprintln!(
                "supervise[{}]: dependency not ready (proceeding): {}",
                spec.label, dep.poll_cmd
            );
        }
    }

    // 2. pre_start — abort on failure (this is the bug the bash wrapper had).
    if let Some(pre) = &spec.pre_start {
        if !run_cmd(pre) {
            eprintln!("supervise[{}]: pre_start failed: {pre}", spec.label);
            return 1;
        }
    }

    // 3. Signal handler + spawn start in its own process group.
    install_signal_handlers();
    let mut child = match spawn_in_group(&spec.start) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("supervise[{}]: failed to start: {e}", spec.label);
            return 1;
        }
    };
    let pgid = child.id() as i32; // == pid, since the child is its own group leader

    // 4. Supervise loop.
    loop {
        if TERM.load(Ordering::SeqCst) {
            teardown(&spec, &mut child, pgid);
            return 0;
        }
        match child.try_wait() {
            Ok(Some(status)) => {
                run_optional(&spec.post_stop);
                return status.code().unwrap_or(0);
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(100)),
            Err(e) => {
                eprintln!("supervise[{}]: wait error: {e}", spec.label);
                return 1;
            }
        }
    }
}

/// Graceful teardown: stop (or signal the group), bounded wait, SIGKILL the
/// group if it overruns, then post_stop.
fn teardown(spec: &SuperviseSpec, child: &mut Child, pgid: i32) {
    match &spec.stop {
        // Runtime-defined graceful stop (e.g. `container stop X`, `podman stop X`).
        Some(stop) => {
            run_cmd(stop);
        }
        // No stop command (plain host process) -> SIGTERM the whole group.
        None => unsafe {
            libc::killpg(pgid, libc::SIGTERM);
        },
    }

    // Bounded wait for the child to actually exit.
    let deadline = Instant::now() + Duration::from_secs(spec.stop_timeout_secs.max(1) as u64);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) => {
                if Instant::now() >= deadline {
                    // Overran the grace window — nuke the whole process group.
                    unsafe { libc::killpg(pgid, libc::SIGKILL) };
                    let _ = child.wait();
                    break;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            Err(_) => break,
        }
    }

    run_optional(&spec.post_stop);
}

fn run_optional(cmd: &Option<String>) {
    if let Some(c) = cmd {
        run_cmd(c);
    }
}

/// Spawn `cmd` via `/bin/sh -c` in a fresh process group so the whole tree can
/// be signalled together. macOS has no PR_SET_PDEATHSIG, so the group is how we
/// guarantee no orphans on teardown.
fn spawn_in_group(cmd: &str) -> std::io::Result<Child> {
    use std::os::unix::process::CommandExt;
    let mut c = Command::new("/bin/sh");
    c.arg("-c").arg(cmd);
    unsafe {
        c.pre_exec(|| {
            // Become group leader: new pgid == pid.
            if libc::setpgid(0, 0) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    c.spawn()
}

fn install_signal_handlers() {
    unsafe {
        libc::signal(libc::SIGTERM, on_term as *const () as libc::sighandler_t);
        libc::signal(libc::SIGINT, on_term as *const () as libc::sighandler_t);
    }
}

/// Poll `cmd` until it exits 0 or `timeout_secs` elapses.
fn wait_healthy(cmd: &str, timeout_secs: u32) -> bool {
    let deadline = Instant::now() + Duration::from_secs(timeout_secs as u64);
    loop {
        if run_cmd(cmd) {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_secs(2));
    }
}

fn run_cmd(cmd: &str) -> bool {
    Command::new("/bin/sh")
        .arg("-c")
        .arg(cmd)
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Convert a HEALTHCHECK value into a runnable poll command. HTTP(S) → curl.
pub fn healthcheck_to_cmd(hc: &str) -> String {
    if hc.starts_with("http://") || hc.starts_with("https://") {
        format!("curl -sf '{}'", hc)
    } else {
        hc.to_string()
    }
}

// ─── Spec building (shared by every platform; orchdi owns it) ──────────────

/// A dependency readiness gate: poll `poll_cmd` until it succeeds (or times
/// out) before starting the service. `required` distinguishes REQUIRES (must
/// pass) from AFTER (ordering only).
pub struct DepGate {
    pub poll_cmd: String,
    pub timeout_secs: u32,
    pub required: bool,
}

/// Service label: `{namespace}.{service}` (reverse-DNS style).
pub fn service_label(config: &Config, service_name: &str) -> String {
    format!("{}.{}", config.namespace, service_name)
}

/// Path to a service's SuperviseSpec JSON: `<state_dir>/supervise/<label>.json`.
pub fn supervise_spec_path(config: &Config, label: &str) -> String {
    config
        .state_dir
        .join("supervise")
        .join(format!("{label}.json"))
        .display()
        .to_string()
}

/// Parse "30s" / "2m" / "120" → seconds. Returns None on parse failure.
pub fn parse_duration_secs(s: &str) -> Option<u32> {
    let s = s.trim();
    if let Some(n) = s.strip_suffix('s') {
        n.parse().ok()
    } else if let Some(n) = s.strip_suffix('m') {
        n.parse::<u32>().ok().map(|v| v * 60)
    } else {
        s.parse().ok()
    }
}

/// Build the SuperviseSpec for a service from its ExecSet + dependency gates.
/// Runtime-agnostic: only command strings flow in.
pub fn build_supervise_spec(
    service: &Service,
    exec_set: &ExecSet,
    config: &Config,
    deps: &[DepGate],
) -> SuperviseSpec {
    let stop_timeout = service
        .timeouts
        .stop
        .as_deref()
        .and_then(parse_duration_secs)
        .unwrap_or(if exec_set.stop.is_some() || exec_set.post_stop.is_some() {
            30
        } else {
            10
        });
    SuperviseSpec {
        label: service_label(config, &service.name),
        pre_start: exec_set.pre_start.clone(),
        start: exec_set.start.clone(),
        stop: exec_set.stop.clone(),
        post_stop: exec_set.post_stop.clone(),
        deps: deps
            .iter()
            .map(|d| DepSpec {
                poll_cmd: d.poll_cmd.clone(),
                timeout_secs: d.timeout_secs,
                required: d.required,
            })
            .collect(),
        stop_timeout_secs: stop_timeout,
    }
}

/// Build the dependency readiness gates for `service`: for each REQUIRES/AFTER
/// dependency that is enabled and has a HEALTHCHECK, a poll the supervisor runs
/// before starting. Deps without a healthcheck are skipped.
pub fn build_dep_gates(service: &Service, all: &[Service]) -> Vec<DepGate> {
    let lookup = |name: &str| all.iter().find(|s| s.name == name && !s.disabled);
    let mut gates = Vec::new();
    for (names, required) in [(&service.requires, true), (&service.after, false)] {
        for dep_name in names {
            if let Some(dep) = lookup(dep_name) {
                if let Some(hc) = &dep.healthcheck {
                    gates.push(DepGate {
                        poll_cmd: healthcheck_to_cmd(hc),
                        timeout_secs: dep
                            .readiness_timeout
                            .as_deref()
                            .and_then(parse_duration_secs)
                            .unwrap_or(90),
                        required,
                    });
                }
            }
        }
    }
    gates
}

#[cfg(test)]
#[allow(non_snake_case)]
mod tests {
    use super::*;

    #[test]
    fn test_spec_roundtrip() {
        let spec = SuperviseSpec {
            label: "orch.pg".into(),
            pre_start: Some("echo pull".into()),
            start: "sleep 1".into(),
            stop: Some("echo stop".into()),
            post_stop: Some("echo delete".into()),
            deps: vec![DepSpec { poll_cmd: "true".into(), timeout_secs: 5, required: true }],
            stop_timeout_secs: 30,
        };
        let json = serde_json::to_string(&spec).unwrap();
        let back: SuperviseSpec = serde_json::from_str(&json).unwrap();
        assert_eq!(back.label, "orch.pg");
        assert_eq!(back.deps.len(), 1);
        assert!(back.deps[0].required);
    }

    #[test]
    fn test_healthcheck_to_cmd__http_becomes_curl() {
        assert_eq!(healthcheck_to_cmd("http://localhost/h"), "curl -sf 'http://localhost/h'");
        assert_eq!(healthcheck_to_cmd("pg_isready"), "pg_isready");
    }

    #[test]
    fn test_wait_healthy__succeeds_immediately() {
        assert!(wait_healthy("true", 5));
    }

    #[test]
    fn test_wait_healthy__times_out() {
        assert!(!wait_healthy("false", 1));
    }
}
