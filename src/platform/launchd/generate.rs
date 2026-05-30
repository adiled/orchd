use std::fmt::Write;

use crate::config::Config;
use crate::exec::ExecSet;
use crate::types::{RestartPolicy, Service};

/// Generate a launchd .plist (Property List XML) for a service.
pub fn generate_service_plist(
    service: &Service,
    exec_set: &ExecSet,
    config: &Config,
) -> String {
    let label = plist_label(config, &service.name);
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

    // ProgramArguments: wrap start in /bin/bash -c so we get full shell semantics
    // (same as systemd's ExecStart=/bin/bash -c '...').
    // If pre_start exists, chain it with && so it runs before the main command.
    let start_cmd = match &exec_set.pre_start {
        Some(pre) => format!("{} && exec {}", pre, exec_set.start),
        None => format!("exec {}", exec_set.start),
    };
    writeln!(p, "  <key>ProgramArguments</key>").unwrap();
    writeln!(p, "  <array>").unwrap();
    writeln!(p, "    <string>/bin/bash</string>").unwrap();
    writeln!(p, "    <string>-c</string>").unwrap();
    writeln!(p, "    <string>{}</string>", xml_escape(&start_cmd)).unwrap();
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

    // EnvironmentVariables
    if !service.env.is_empty() {
        writeln!(p, "  <key>EnvironmentVariables</key>").unwrap();
        writeln!(p, "  <dict>").unwrap();
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

    // Resource limits — only memory and nofile have launchd equivalents
    if let Some(nofile) = service.resources.limit_nofile {
        writeln!(p, "  <key>SoftResourceLimits</key>").unwrap();
        writeln!(p, "  <dict>").unwrap();
        writeln!(p, "    <key>NumberOfFiles</key>").unwrap();
        writeln!(p, "    <integer>{}</integer>", nofile).unwrap();
        writeln!(p, "  </dict>").unwrap();
    }

    // ExitTimeOut (TimeoutStopSec equivalent)
    if let Some(ref stop) = service.timeouts.stop {
        if let Some(secs) = parse_duration_secs(stop) {
            writeln!(p, "  <key>ExitTimeOut</key>").unwrap();
            writeln!(p, "  <integer>{}</integer>", secs).unwrap();
        }
    }

    writeln!(p, "</dict>").unwrap();
    writeln!(p, "</plist>").unwrap();

    p
}

/// Label format: `{namespace}.{service}` (reverse-DNS style).
pub fn plist_label(config: &Config, service_name: &str) -> String {
    format!("{}.{}", config.namespace, service_name)
}

/// Plist filename: `{label}.plist`.
pub fn plist_filename(config: &Config, service_name: &str) -> String {
    format!("{}.plist", plist_label(config, service_name))
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

/// Parse "30s" / "2m" / "120" → seconds. Returns None on parse failure.
fn parse_duration_secs(s: &str) -> Option<u32> {
    let s = s.trim();
    if let Some(n) = s.strip_suffix('s') { n.parse().ok() }
    else if let Some(n) = s.strip_suffix('m') { n.parse::<u32>().ok().map(|v| v * 60) }
    else { s.parse().ok() }
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
            orch_bin: PathBuf::from("orch"),
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

        // Find KeepAlive followed by <true/>
        let pos = p.find("<key>KeepAlive</key>").unwrap();
        let after = &p[pos..];
        assert!(after.contains("<true/>"));
        assert!(!after[..200].contains("<dict>"));
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
    fn test_plist_label__format() {
        let cfg = test_config();
        assert_eq!(plist_label(&cfg, "web"), "orch.web");
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
