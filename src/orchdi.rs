use std::path::Path;
use std::process::{Child, Command};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::config::Config;
use crate::exec::ExecSet;
use crate::types::Service;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DepSpec {
    pub poll_cmd: String,
    pub timeout_secs: u32,
    pub required: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SuperviseSpec {
    pub label: String,
    pub pre_start: Option<String>,
    pub start: String,
    pub stop: Option<String>,
    pub post_stop: Option<String>,
    #[serde(default)]
    pub deps: Vec<DepSpec>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ready_marker: Option<String>,
    pub stop_timeout_secs: u32,
}

static TERM: AtomicBool = AtomicBool::new(false);

extern "C" fn on_term(_sig: i32) {
    TERM.store(true, Ordering::SeqCst);
}

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

    if let Some(pre) = &spec.pre_start {
        if !run_cmd(pre) {
            eprintln!("supervise[{}]: pre_start failed: {pre}", spec.label);
            return 1;
        }
    }

    install_signal_handlers();
    let mut child = match spawn_in_group(&spec.start) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("supervise[{}]: failed to start: {e}", spec.label);
            return 1;
        }
    };
    let pgid = child.id() as i32; // == pid, since the child is its own group leader

    loop {
        if TERM.load(Ordering::SeqCst) {
            teardown(&spec, &mut child, pgid);
            return 0;
        }
        match child.try_wait() {
            Ok(Some(status)) => {
                run_optional(&spec.post_stop);
                let code = status.code().unwrap_or(0);
                if let Some(ref marker) = spec.ready_marker {
                    if code == 0 {
                        let _ = std::fs::write(marker, "");
                    } else {
                        let _ = std::fs::remove_file(marker);
                    }
                }
                return code;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(100)),
            Err(e) => {
                eprintln!("supervise[{}]: wait error: {e}", spec.label);
                return 1;
            }
        }
    }
}

fn teardown(spec: &SuperviseSpec, child: &mut Child, pgid: i32) {
    match &spec.stop {
        Some(stop) => {
            run_cmd(stop);
        }
        None => unsafe {
            libc::killpg(pgid, libc::SIGTERM);
        },
    }

    let deadline = Instant::now() + Duration::from_secs(spec.stop_timeout_secs.max(1) as u64);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) => {
                if Instant::now() >= deadline {
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

fn spawn_in_group(cmd: &str) -> std::io::Result<Child> {
    use std::os::unix::process::CommandExt;
    let mut c = Command::new("/bin/sh");
    c.arg("-c").arg(cmd);
    unsafe {
        c.pre_exec(|| {
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

pub fn healthcheck_to_cmd(hc: &str) -> String {
    if hc.starts_with("http://") || hc.starts_with("https://") {
        format!("curl -sf '{}'", hc)
    } else {
        hc.to_string()
    }
}

pub struct DepGate {
    pub poll_cmd: String,
    pub timeout_secs: u32,
    pub required: bool,
}

pub fn service_label(config: &Config, service_name: &str) -> String {
    format!("{}.{}", config.namespace, service_name)
}

pub fn supervise_spec_path(config: &Config, label: &str) -> String {
    config
        .state_dir
        .join("supervise")
        .join(format!("{label}.json"))
        .display()
        .to_string()
}

pub fn parse_duration_secs(s: &str) -> Option<u32> {
    let s = s.trim();
    if let Some(n) = s.strip_suffix('s') {
        n.parse().ok()
    } else if let Some(n) = s.strip_suffix('m') {
        n.parse::<u32>().ok().map(|v| v * 60)
    } else {
        None
    }
}

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
    let ready_marker = if service.oneshot {
        let path = ready_marker_path(config, &service.name);
        let _ = std::fs::create_dir_all(config.state_dir.join("ready"));
        Some(path)
    } else {
        None
    };
    SuperviseSpec {
        label: service_label(config, &service.name),
        pre_start: exec_set.pre_start.clone(),
        start: exec_set.start.clone(),
        stop: exec_set.stop.clone(),
        post_stop: exec_set.post_stop.clone(),
        ready_marker,
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

pub fn build_dep_gates(config: &Config, service: &Service, all: &[Service]) -> Vec<DepGate> {
    let lookup = |name: &str| all.iter().find(|s| s.name == name && !s.disabled);
    let mut gates = Vec::new();
    for (names, required) in [(&service.requires, true), (&service.after, false)] {
        for dep_name in names {
            if let Some(dep) = lookup(dep_name) {
                if required {
                    let base = oneshot_marker_or_up(config, dep);
                    let poll_cmd = match &dep.healthcheck {
                        Some(hc) => format!("{base} && {}", healthcheck_to_cmd(hc)),
                        None => base,
                    };
                    gates.push(DepGate {
                        poll_cmd,
                        timeout_secs: dep
                            .readiness_timeout
                            .as_deref()
                            .and_then(parse_duration_secs)
                            .unwrap_or(90),
                        required,
                    });
                } else if let Some(hc) = &dep.healthcheck {
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

fn oneshot_marker_or_up(config: &Config, dep: &Service) -> String {
    let marker = ready_marker_path(config, &dep.name);
    if dep.oneshot {
        format!("test -f {marker}")
    } else {
        format!("true")
    }
}

pub fn ready_marker_path(config: &Config, service_name: &str) -> String {
    config
        .state_dir
        .join("ready")
        .join(format!("{}.ready", service_label(config, service_name)))
        .display()
        .to_string()
}

#[cfg(test)]
#[allow(non_snake_case)]
mod tests {
    use super::*;
    use crate::config::Scope;
    use crate::types::*;
    use std::collections::HashMap;
    use std::path::PathBuf;

    fn test_config() -> Config {
        Config {
            orchfile: PathBuf::from("/test/Orchfile"),
            overlays: Vec::new(),
            runtime: "bare".to_string(),
            platform: "launchd".to_string(),
            scope: Scope::User,
            state_dir: PathBuf::from("/test/.orch"),
            project_dir: PathBuf::from("/test/project"),
            data_dir: PathBuf::from("/test/.orch/data"),
            namespace: "orch".to_string(),
            args: Vec::new(),
            verbose: false,
            quiet: false,
        }
    }

    fn simple_host_service(name: &str, run_cmd: &str) -> Service {
        Service {
            name: name.to_string(),
            mode: ServiceMode::Host,
            image: None,
            run_command: Some(run_cmd.to_string()),
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
    fn test_spec_roundtrip() {
        let spec = SuperviseSpec {
            label: "orch.pg".into(),
            pre_start: Some("echo pull".into()),
            start: "sleep 1".into(),
            stop: Some("echo stop".into()),
            post_stop: Some("echo delete".into()),
            deps: vec![DepSpec {
                poll_cmd: "true".into(),
                timeout_secs: 5,
                required: true,
            }],
            ready_marker: None,
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
        assert_eq!(
            healthcheck_to_cmd("http://localhost/h"),
            "curl -sf 'http://localhost/h'"
        );
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

    #[test]
    fn test_build_dep_gates__requires_healthcheck_plus_started() {
        let cfg = test_config();
        let mut pg = simple_host_service("postgres", "postgres");
        pg.oneshot = true;
        pg.healthcheck = Some("pg_isready -h localhost".to_string());

        let mut app = simple_host_service("app", "app");
        app.requires = vec!["postgres".to_string()];

        let all = vec![pg.clone(), app.clone()];
        let gates = build_dep_gates(&cfg, &app, &all);

        assert_eq!(gates.len(), 1);
        assert!(gates[0].required);
        let marker = ready_marker_path(&cfg, "postgres");
        assert_eq!(
            gates[0].poll_cmd,
            format!("test -f {marker} && pg_isready -h localhost")
        );
    }
}
