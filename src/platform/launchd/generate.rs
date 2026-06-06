use std::fmt::Write;

use crate::config::Config;
use crate::exec::ExecSet;
use crate::orchdi::{parse_duration_secs, service_label, supervise_spec_path, DepGate};
use crate::types::{RestartPolicy, Service};

/// A dependency readiness gate: poll `poll_cmd` until it succeeds (or times out)
/// before starting the service. `required` distinguishes REQUIRES (must pass —
/// abort start on timeout) from AFTER (ordering only — proceed on timeout).
// `DepGate`, the spec builders, and `service_label` now live in `orchdi`.

/// Generate a launchd .plist with no dependencies (test convenience).
#[cfg(test)]
pub fn generate_service_plist(service: &Service, exec_set: &ExecSet, config: &Config) -> String {
    generate_service_plist_with_deps(service, exec_set, config, &[])
}

/// Generate a launchd .plist, prepending readiness polls for `deps`.
/// launchd has no dependency model, so ordering is realized as a poll prologue
/// inside the service's own program (see `program_command`).
pub fn generate_service_plist_with_deps(
    service: &Service,
    exec_set: &ExecSet,
    config: &Config,
    deps: &[DepGate],
) -> String {
    let label = service_label(config, &service.name);
    let log_dir = log_dir(config);
    let stdout_path = format!("{}/{}.out.log", log_dir, label);
    let stderr_path = format!("{}/{}.err.log", log_dir, label);

    let mut p = String::with_capacity(1024);

    writeln!(p, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>").unwrap();
    writeln!(p, "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">").unwrap();
    writeln!(p, "<plist version=\"1.0\">").unwrap();
    writeln!(p, "<dict>").unwrap();

    // Label
    writeln!(p, "  <key>Label</key>").unwrap();
    writeln!(p, "  <string>{}</string>", xml_escape(&label)).unwrap();

    // ProgramArguments. Two strategies:
    //   - Orchestrated services (have dependencies and/or teardown) delegate to
    //     `orchd supervise --spec <path>`: launchd has no dependency model and no
    //     ExecStop, so a real supervisor process renders those for it.
    //   - Trivial services (no deps, no teardown) keep the lightweight `exec`
    //     path so launchd tracks the real PID directly.
    let needs_supervisor =
        !deps.is_empty() || exec_set.stop.is_some() || exec_set.post_stop.is_some();
    writeln!(p, "  <key>ProgramArguments</key>").unwrap();
    writeln!(p, "  <array>").unwrap();
    if needs_supervisor {
        let spec_path = supervise_spec_path(config, &label);
        writeln!(p, "    <string>{}</string>", xml_escape(&orchd_exe())).unwrap();
        writeln!(p, "    <string>supervise</string>").unwrap();
        writeln!(p, "    <string>--spec</string>").unwrap();
        writeln!(p, "    <string>{}</string>", xml_escape(&spec_path)).unwrap();
    } else {
        let start_cmd = fast_path_command(exec_set);
        writeln!(p, "    <string>/bin/bash</string>").unwrap();
        writeln!(p, "    <string>-c</string>").unwrap();
        writeln!(p, "    <string>{}</string>", xml_escape(&start_cmd)).unwrap();
    }
    writeln!(p, "  </array>").unwrap();

    // RunAtLoad
    writeln!(p, "  <key>RunAtLoad</key>").unwrap();
    writeln!(p, "  <true/>").unwrap();

    // KeepAlive — translate from RestartPolicy
    // oneshot: omit KeepAlive (one-time run)
    // Always: KeepAlive=true
    // OnFailure: KeepAlive=<dict SuccessfulExit=false>
    // No: omit KeepAlive
    if !service.oneshot {
        match service.restart.policy {
            RestartPolicy::Always => {
                writeln!(p, "  <key>KeepAlive</key>").unwrap();
                writeln!(p, "  <true/>").unwrap();
            }
            RestartPolicy::OnFailure => {
                writeln!(p, "  <key>KeepAlive</key>").unwrap();
                writeln!(p, "  <dict>").unwrap();
                writeln!(p, "    <key>SuccessfulExit</key>").unwrap();
                writeln!(p, "    <false/>").unwrap();
                writeln!(p, "  </dict>").unwrap();
            }
            RestartPolicy::No => {}
        }
    }

    // ThrottleInterval (RestartSec equivalent)
    if let Some(ref delay) = service.restart.delay {
        if let Some(secs) = parse_duration_secs(delay) {
            writeln!(p, "  <key>ThrottleInterval</key>").unwrap();
            writeln!(p, "  <integer>{}</integer>", secs).unwrap();
        }
    }

    // WorkingDirectory
    if let Some(ref wd) = service.workdir {
        let resolved = resolve_path(wd, &config.project_dir);
        writeln!(p, "  <key>WorkingDirectory</key>").unwrap();
        writeln!(p, "  <string>{}</string>", xml_escape(&resolved)).unwrap();
    }

    // EnvironmentVariables. launchd spawns agents with a minimal PATH
    // (/usr/bin:/bin:/usr/sbin:/sbin) that omits /usr/local/bin and homebrew,
    // so `container`, `curl`, etc. aren't found. Inject a sane PATH unless the
    // service overrides it.
    let has_path = service.env.keys().any(|k| k == "PATH");
    if !service.env.is_empty() || !has_path {
        writeln!(p, "  <key>EnvironmentVariables</key>").unwrap();
        writeln!(p, "  <dict>").unwrap();
        if !has_path {
            writeln!(p, "    <key>PATH</key>").unwrap();
            writeln!(
                p,
                "    <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>"
            )
            .unwrap();
        }
        let mut keys: Vec<&String> = service.env.keys().collect();
        keys.sort();
        for k in keys {
            writeln!(p, "    <key>{}</key>", xml_escape(k)).unwrap();
            writeln!(p, "    <string>{}</string>", xml_escape(&service.env[k])).unwrap();
        }
        writeln!(p, "  </dict>").unwrap();
    }

    // UserName
    if let Some(ref user) = service.user {
        writeln!(p, "  <key>UserName</key>").unwrap();
        writeln!(p, "  <string>{}</string>", xml_escape(user)).unwrap();
    }

    // StandardOutPath / StandardErrorPath: prefer service.logging overrides
    let out = service.logging.stdout.as_ref()
        .map(|s| resolve_path(s, &config.project_dir))
        .unwrap_or(stdout_path);
    let err = service.logging.stderr.as_ref()
        .map(|s| resolve_path(s, &config.project_dir))
        .unwrap_or(stderr_path);
    writeln!(p, "  <key>StandardOutPath</key>").unwrap();
    writeln!(p, "  <string>{}</string>", xml_escape(&out)).unwrap();
    writeln!(p, "  <key>StandardErrorPath</key>").unwrap();
    writeln!(p, "  <string>{}</string>", xml_escape(&err)).unwrap();

    // Resource limits — only file/process counts have launchd equivalents.
    // MEMORY/CPUS/CPU_QUOTA/TASKS_MAX/IO_WEIGHT are not enforced (spec: advisory).
    if service.resources.limit_nofile.is_some() || service.resources.limit_nproc.is_some() {
        writeln!(p, "  <key>SoftResourceLimits</key>").unwrap();
        writeln!(p, "  <dict>").unwrap();
        if let Some(nofile) = service.resources.limit_nofile {
            writeln!(p, "    <key>NumberOfFiles</key>").unwrap();
            writeln!(p, "    <integer>{}</integer>", nofile).unwrap();
        }
        if let Some(nproc) = service.resources.limit_nproc {
            writeln!(p, "    <key>NumberOfProcesses</key>").unwrap();
            writeln!(p, "    <integer>{}</integer>", nproc).unwrap();
        }
        writeln!(p, "  </dict>").unwrap();
    }

    // ProcessType: without this, launchd applies "light resource limits",
    // throttling CPU and I/O. Dev services should run unthrottled.
    writeln!(p, "  <key>ProcessType</key>").unwrap();
    writeln!(p, "  <string>Interactive</string>").unwrap();

    // ExitTimeOut (SIGTERM→SIGKILL window). Explicit TIMEOUT_STOP wins; otherwise
    // services with teardown (container stop+delete) get a generous default so
    // cleanup completes before launchd escalates to SIGKILL.
    let exit_timeout = service
        .timeouts
        .stop
        .as_deref()
        .and_then(parse_duration_secs)
        .or(if exec_set.stop.is_some() || exec_set.post_stop.is_some() {
            Some(30)
        } else {
            None
        });
    if let Some(secs) = exit_timeout {
        writeln!(p, "  <key>ExitTimeOut</key>").unwrap();
        writeln!(p, "  <integer>{}</integer>", secs).unwrap();
    }

    writeln!(p, "</dict>").unwrap();
    writeln!(p, "</plist>").unwrap();

    p
}

/// Build the lightweight `bash -c` command for trivial services (no deps, no
/// teardown). Orchestrated services go through `orchd supervise` instead.
fn fast_path_command(exec_set: &ExecSet) -> String {
    match exec_set.pre_start.as_deref() {
        Some(p) => format!("{p} && exec {}", exec_set.start),
        None => format!("exec {}", exec_set.start),
    }
}

/// Absolute path to the running orchd executable (for plist ProgramArguments).
fn orchd_exe() -> String {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.to_str().map(String::from))
        .unwrap_or_else(|| "orchd".to_string())
}

/// Plist filename: `{label}.plist`.
pub fn plist_filename(config: &Config, service_name: &str) -> String {
    format!("{}.plist", service_label(config, service_name))
}

/// Log directory: `$HOME/Library/Logs` for user, `/Library/Logs` for system.
fn log_dir(config: &Config) -> String {
    if config.scope.is_user() {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        format!("{}/Library/Logs", home)
    } else {
        "/Library/Logs".to_string()
    }
}

fn resolve_path(path: &str, project_dir: &std::path::Path) -> String {
    if std::path::Path::new(path).is_absolute() {
        path.to_string()
    } else {
        project_dir.join(path).display().to_string()
    }
}

/// Minimal XML entity escaping for plist string values.
fn xml_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            _ => out.push(c),
        }
    }
    out
}

#[cfg(test)]
#[allow(non_snake_case)]
mod tests {
    use super::*;
    use crate::orchdi::{build_dep_gates, build_supervise_spec};
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

    fn simple_exec_set(start: &str) -> ExecSet {
        ExecSet { start: start.to_string(), pre_start: None, stop: None, post_stop: None }
    }

    #[test]
    fn test_generate_service_plist__basic_structure() {
        let cfg = test_config();
        let svc = simple_host_service("web", "python server.py");
        let exec = simple_exec_set("python server.py");
        let p = generate_service_plist(&svc, &exec, &cfg);

        assert!(p.starts_with("<?xml version=\"1.0\""));
        assert!(p.contains("<!DOCTYPE plist"));
        assert!(p.contains("<plist version=\"1.0\">"));
        assert!(p.contains("</plist>"));
        assert!(p.contains("<key>Label</key>"));
        assert!(p.contains("<string>orch.web</string>"));
        assert!(p.contains("<key>ProgramArguments</key>"));
        assert!(p.contains("<string>/bin/bash</string>"));
        assert!(p.contains("<string>-c</string>"));
        assert!(p.contains("exec python server.py"));
        assert!(p.contains("<key>RunAtLoad</key>"));
        assert!(p.contains("<true/>"));
    }

    #[test]
    fn test_generate_service_plist__keepalive_on_failure() {
        let cfg = test_config();
        let mut svc = simple_host_service("worker", "celery worker");
        svc.restart.policy = RestartPolicy::OnFailure;
        let exec = simple_exec_set("celery worker");
        let p = generate_service_plist(&svc, &exec, &cfg);

        assert!(p.contains("<key>KeepAlive</key>"));
        assert!(p.contains("<key>SuccessfulExit</key>"));
        assert!(p.contains("<false/>"));
    }

    #[test]
    fn test_generate_service_plist__keepalive_always() {
        let cfg = test_config();
        let mut svc = simple_host_service("worker", "loop.sh");
        svc.restart.policy = RestartPolicy::Always;
        let exec = simple_exec_set("loop.sh");
        let p = generate_service_plist(&svc, &exec, &cfg);

        // KeepAlive=Always is `<true/>`, not the `<dict>` OnFailure form. Scope to
        // the KeepAlive value (up to the next key) rather than a fixed window.
        let pos = p.find("<key>KeepAlive</key>").unwrap();
        let after = &p[pos + "<key>KeepAlive</key>".len()..];
        let value = &after[..after.find("<key>").unwrap_or(after.len())];
        assert!(value.contains("<true/>"));
        assert!(!value.contains("<dict>"));
    }

    #[test]
    fn test_generate_service_plist__no_keepalive_when_oneshot() {
        let cfg = test_config();
        let mut svc = simple_host_service("migrate", "migrate.sh");
        svc.oneshot = true;
        let exec = simple_exec_set("migrate.sh");
        let p = generate_service_plist(&svc, &exec, &cfg);

        assert!(!p.contains("<key>KeepAlive</key>"));
    }

    #[test]
    fn test_generate_service_plist__throttle_interval_from_delay() {
        let cfg = test_config();
        let mut svc = simple_host_service("worker", "w");
        svc.restart.policy = RestartPolicy::OnFailure;
        svc.restart.delay = Some("5s".to_string());
        let exec = simple_exec_set("w");
        let p = generate_service_plist(&svc, &exec, &cfg);

        assert!(p.contains("<key>ThrottleInterval</key>"));
        assert!(p.contains("<integer>5</integer>"));
    }

    #[test]
    fn test_generate_service_plist__environment_sorted() {
        let cfg = test_config();
        let mut svc = simple_host_service("app", "app");
        svc.env.insert("ZED".to_string(), "1".to_string());
        svc.env.insert("ALPHA".to_string(), "2".to_string());
        let exec = simple_exec_set("app");
        let p = generate_service_plist(&svc, &exec, &cfg);

        assert!(p.contains("<key>EnvironmentVariables</key>"));
        let alpha_pos = p.find("<key>ALPHA</key>").unwrap();
        let zed_pos = p.find("<key>ZED</key>").unwrap();
        assert!(alpha_pos < zed_pos);
    }

    #[test]
    fn test_generate_service_plist__workdir_resolved() {
        let cfg = test_config();
        let mut svc = simple_host_service("app", "app");
        svc.workdir = Some("backend".to_string());
        let exec = simple_exec_set("app");
        let p = generate_service_plist(&svc, &exec, &cfg);

        assert!(p.contains("<key>WorkingDirectory</key>"));
        assert!(p.contains("<string>/test/project/backend</string>"));
    }

    #[test]
    fn test_generate_service_plist__user() {
        let cfg = test_config();
        let mut svc = simple_host_service("pg", "postgres");
        svc.user = Some("postgres".to_string());
        let exec = simple_exec_set("postgres");
        let p = generate_service_plist(&svc, &exec, &cfg);

        assert!(p.contains("<key>UserName</key>"));
        assert!(p.contains("<string>postgres</string>"));
    }

    #[test]
    fn test_generate_service_plist__default_log_paths_user_scope() {
        let cfg = test_config();
        let svc = simple_host_service("web", "x");
        let exec = simple_exec_set("x");
        let p = generate_service_plist(&svc, &exec, &cfg);

        assert!(p.contains("<key>StandardOutPath</key>"));
        assert!(p.contains("orch.web.out.log"));
        assert!(p.contains("orch.web.err.log"));
        // Should use $HOME/Library/Logs (whatever HOME is in test env)
        assert!(p.contains("/Library/Logs/"));
    }

    #[test]
    fn test_generate_service_plist__system_scope_log_paths() {
        let mut cfg = test_config();
        cfg.scope = Scope::System;
        let svc = simple_host_service("web", "x");
        let exec = simple_exec_set("x");
        let p = generate_service_plist(&svc, &exec, &cfg);

        assert!(p.contains("<string>/Library/Logs/orch.web.out.log</string>"));
        assert!(p.contains("<string>/Library/Logs/orch.web.err.log</string>"));
    }

    #[test]
    fn test_generate_service_plist__custom_log_paths_override_defaults() {
        let cfg = test_config();
        let mut svc = simple_host_service("app", "app");
        svc.logging.stdout = Some("/var/log/app/out.log".to_string());
        svc.logging.stderr = Some("/var/log/app/err.log".to_string());
        let exec = simple_exec_set("app");
        let p = generate_service_plist(&svc, &exec, &cfg);

        assert!(p.contains("<string>/var/log/app/out.log</string>"));
        assert!(p.contains("<string>/var/log/app/err.log</string>"));
    }

    #[test]
    fn test_generate_service_plist__pre_start_chained() {
        let cfg = test_config();
        let svc = simple_host_service("nginx", "nginx -g 'daemon off;'");
        let exec = ExecSet {
            start: "nginx -g 'daemon off;'".to_string(),
            pre_start: Some("nginx -t".to_string()),
            stop: None,
            post_stop: None,
        };
        let p = generate_service_plist(&svc, &exec, &cfg);

        assert!(p.contains("nginx -t &amp;&amp; exec nginx -g &apos;daemon off;&apos;"));
    }

    #[test]
    fn test_generate_service_plist__limit_nofile() {
        let cfg = test_config();
        let mut svc = simple_host_service("pg", "postgres");
        svc.resources.limit_nofile = Some(65536);
        let exec = simple_exec_set("postgres");
        let p = generate_service_plist(&svc, &exec, &cfg);

        assert!(p.contains("<key>SoftResourceLimits</key>"));
        assert!(p.contains("<key>NumberOfFiles</key>"));
        assert!(p.contains("<integer>65536</integer>"));
    }

    #[test]
    fn test_generate_service_plist__limit_nproc() {
        let cfg = test_config();
        let mut svc = simple_host_service("app", "app");
        svc.resources.limit_nproc = Some(4096);
        let exec = simple_exec_set("app");
        let p = generate_service_plist(&svc, &exec, &cfg);

        assert!(p.contains("<key>NumberOfProcesses</key>"));
        assert!(p.contains("<integer>4096</integer>"));
    }

    #[test]
    fn test_generate_service_plist__no_teardown_uses_exec() {
        // Host/bare services (no stop/post_stop) keep the fast exec path.
        let cfg = test_config();
        let svc = simple_host_service("web", "python server.py");
        let exec = simple_exec_set("python server.py");
        let p = generate_service_plist(&svc, &exec, &cfg);

        assert!(p.contains("exec python server.py"));
        assert!(!p.contains("__orch_down"));
    }

    #[test]
    fn test_generate_service_plist__teardown_delegates_to_supervisor() {
        // Container services carry stop+post_stop; launchd has no ExecStop, so the
        // plist delegates to `orchd supervise` (teardown handled in the supervisor).
        let cfg = test_config();
        let svc = simple_host_service("postgres", "container run --name orch-postgres pg:15");
        let exec = ExecSet {
            start: "container run --name orch-postgres pg:15".to_string(),
            pre_start: Some("container image pull pg:15".to_string()),
            stop: Some("container stop orch-postgres".to_string()),
            post_stop: Some("container delete --force orch-postgres".to_string()),
        };
        let p = generate_service_plist(&svc, &exec, &cfg);

        // ProgramArguments delegates to the supervisor with this service's spec.
        assert!(p.contains("<string>supervise</string>"));
        assert!(p.contains("<string>--spec</string>"));
        assert!(p.contains("orch.postgres.json"));
        // The bash trap wrapper is retired — supervision is a real process now.
        assert!(!p.contains("__orch_down"));
        assert!(!p.contains("trap "));
    }

    #[test]
    fn test_generate_service_plist__process_type_interactive() {
        // Without ProcessType, launchd throttles CPU/IO. We always set Interactive.
        let cfg = test_config();
        let svc = simple_host_service("web", "server");
        let exec = simple_exec_set("server");
        let p = generate_service_plist(&svc, &exec, &cfg);

        assert!(p.contains("<key>ProcessType</key>"));
        assert!(p.contains("<string>Interactive</string>"));
    }

    #[test]
    fn test_generate_service_plist__container_default_exit_timeout() {
        // Teardown present, no explicit TIMEOUT_STOP → generous default (30s)
        // so container stop+delete finishes before launchd SIGKILLs the wrapper.
        let cfg = test_config();
        let svc = simple_host_service("pg", "container run --name orch-pg pg:15");
        let exec = ExecSet {
            start: "container run --name orch-pg pg:15".to_string(),
            pre_start: None,
            stop: Some("container stop orch-pg".to_string()),
            post_stop: Some("container delete --force orch-pg".to_string()),
        };
        let p = generate_service_plist(&svc, &exec, &cfg);

        assert!(p.contains("<key>ExitTimeOut</key>"));
        assert!(p.contains("<integer>30</integer>"));
    }

    #[test]
    fn test_generate_service_plist__explicit_timeout_stop_wins() {
        let cfg = test_config();
        let mut svc = simple_host_service("pg", "x");
        svc.timeouts.stop = Some("45s".to_string());
        let exec = ExecSet {
            start: "x".to_string(),
            pre_start: None,
            stop: Some("container stop orch-pg".to_string()),
            post_stop: None,
        };
        let p = generate_service_plist(&svc, &exec, &cfg);

        assert!(p.contains("<integer>45</integer>"));
        assert!(!p.contains("<integer>30</integer>"));
    }

    #[test]
    fn test_generate_service_plist__no_exit_timeout_for_plain_host() {
        // Host service, no teardown, no TIMEOUT_STOP → no ExitTimeOut emitted.
        let cfg = test_config();
        let svc = simple_host_service("web", "server");
        let exec = simple_exec_set("server");
        let p = generate_service_plist(&svc, &exec, &cfg);

        assert!(!p.contains("<key>ExitTimeOut</key>"));
    }

    #[test]
    fn test_build_dep_gates__requires_and_after() {
        let mut pg = simple_host_service("postgres", "postgres");
        pg.healthcheck = Some("pg_isready -h localhost".to_string());
        pg.readiness_timeout = Some("60s".to_string());

        let mut ls = simple_host_service("localstack", "localstack");
        ls.healthcheck = Some("http://localhost:4566/health".to_string());

        let nohc = simple_host_service("redis", "redis-server"); // no healthcheck → no gate

        let mut app = simple_host_service("app", "app");
        app.requires = vec!["postgres".to_string(), "redis".to_string()];
        app.after = vec!["localstack".to_string()];

        let all = vec![pg, ls, nohc, app.clone()];
        let gates = build_dep_gates(&app, &all);

        // postgres (required, command HC, 60s) + localstack (after, http→curl) ; redis skipped
        assert_eq!(gates.len(), 2);
        let pg_gate = &gates[0];
        assert!(pg_gate.required);
        assert_eq!(pg_gate.poll_cmd, "pg_isready -h localhost");
        assert_eq!(pg_gate.timeout_secs, 60);
        let ls_gate = &gates[1];
        assert!(!ls_gate.required);
        assert_eq!(ls_gate.poll_cmd, "curl -sf 'http://localhost:4566/health'");
        assert_eq!(ls_gate.timeout_secs, 90); // default
    }

    #[test]
    fn test_generate_service_plist_with_deps__delegates_to_supervisor() {
        // A service with dependencies delegates to the supervisor (which runs the
        // readiness polls), not an inline bash prologue.
        let cfg = test_config();
        let svc = simple_host_service("app", "app run");
        let exec = simple_exec_set("app run");
        let deps = vec![
            DepGate { poll_cmd: "pg_isready".to_string(), timeout_secs: 60, required: true },
            DepGate { poll_cmd: "curl -sf 'http://x/health'".to_string(), timeout_secs: 90, required: false },
        ];
        let p = generate_service_plist_with_deps(&svc, &exec, &cfg, &deps);

        assert!(p.contains("<string>supervise</string>"));
        assert!(p.contains("orch.app.json"));
        assert!(!p.contains("__orch_wait")); // no inline bash poll loop anymore
    }

    #[test]
    fn test_build_supervise_spec__carries_execset_and_deps() {
        let cfg = test_config();
        let svc = simple_host_service("pg", "container run --name orch-pg pg:15");
        let exec = ExecSet {
            start: "container run --name orch-pg pg:15".to_string(),
            pre_start: Some("container image pull pg:15".to_string()),
            stop: Some("container stop orch-pg".to_string()),
            post_stop: Some("container delete --force orch-pg".to_string()),
        };
        let deps = vec![DepGate {
            poll_cmd: "pg_isready".to_string(),
            timeout_secs: 60,
            required: true,
        }];
        let spec = build_supervise_spec(&svc, &exec, &cfg, &deps);

        assert_eq!(spec.label, "orch.pg");
        assert_eq!(spec.pre_start.as_deref(), Some("container image pull pg:15"));
        assert_eq!(spec.stop.as_deref(), Some("container stop orch-pg"));
        assert_eq!(spec.post_stop.as_deref(), Some("container delete --force orch-pg"));
        assert_eq!(spec.deps.len(), 1);
        assert!(spec.deps[0].required);
        assert_eq!(spec.stop_timeout_secs, 30); // container default
    }

    #[test]
    fn test_generate_service_plist__exit_timeout() {
        let cfg = test_config();
        let mut svc = simple_host_service("slow", "x");
        svc.timeouts.stop = Some("30s".to_string());
        let exec = simple_exec_set("x");
        let p = generate_service_plist(&svc, &exec, &cfg);

        assert!(p.contains("<key>ExitTimeOut</key>"));
        assert!(p.contains("<integer>30</integer>"));
    }

    #[test]
    fn test_service_label__format() {
        let cfg = test_config();
        assert_eq!(service_label(&cfg, "web"), "orch.web");
    }

    #[test]
    fn test_plist_filename__format() {
        let cfg = test_config();
        assert_eq!(plist_filename(&cfg, "web"), "orch.web.plist");
    }

    #[test]
    fn test_parse_duration_secs__variants() {
        assert_eq!(parse_duration_secs("5s"), Some(5));
        assert_eq!(parse_duration_secs("2m"), Some(120));
        assert_eq!(parse_duration_secs("45"), Some(45));
        assert_eq!(parse_duration_secs("bad"), None);
    }

    #[test]
    fn test_xml_escape__special_chars() {
        assert_eq!(xml_escape("a & b"), "a &amp; b");
        assert_eq!(xml_escape("<x>"), "&lt;x&gt;");
        assert_eq!(xml_escape("\"x\""), "&quot;x&quot;");
        assert_eq!(xml_escape("'x'"), "&apos;x&apos;");
    }
}
