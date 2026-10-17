use std::collections::HashSet;
use std::fmt::Write;

use crate::config::Config;
use crate::exec::ExecSet;
use crate::orchdi::healthcheck_to_cmd;
use crate::types::{RestartPolicy, Service};

pub fn generate_service_unit(
    service: &Service,
    exec_set: &ExecSet,
    config: &Config,
    ready_gates: &HashSet<String>,
) -> String {
    let mut unit = String::with_capacity(1024);

    writeln!(unit, "[Unit]").unwrap();
    writeln!(unit, "Description=orch: {}", service.name).unwrap();
    writeln!(unit, "PartOf={}", config.target_name()).unwrap();

    let (after_deps, binds_to_deps) = build_dependencies(service, config, ready_gates);

    if !after_deps.is_empty() {
        writeln!(unit, "After={}", after_deps.join(" ")).unwrap();
    }
    if !binds_to_deps.is_empty() {
        writeln!(unit, "BindsTo={}", binds_to_deps.join(" ")).unwrap();
    }

    // systemd ignores StartLimit* in [Service]; these are [Unit] keys.
    if let Some(burst) = service.restart.start_limit_burst {
        writeln!(unit, "StartLimitBurst={}", burst).unwrap();
    }
    if let Some(ref interval) = service.restart.start_limit_interval {
        writeln!(unit, "StartLimitIntervalSec={}", interval).unwrap();
    }

    writeln!(unit).unwrap();
    writeln!(unit, "[Service]").unwrap();

    if service.oneshot {
        writeln!(unit, "Type=oneshot").unwrap();
        writeln!(unit, "RemainAfterExit=yes").unwrap();
    } else {
        writeln!(unit, "Type=simple").unwrap();
    }

    if let Some(ref pre_start) = exec_set.pre_start {
        writeln!(
            unit,
            "ExecStartPre=/bin/bash -c '{}'",
            escape_bash(pre_start)
        )
        .unwrap();
    }

    writeln!(
        unit,
        "ExecStart=/bin/bash -c '{}'",
        escape_bash(&exec_set.start)
    )
    .unwrap();

    if let Some(ref stop) = exec_set.stop {
        writeln!(unit, "ExecStop=/bin/bash -c '{}'", escape_bash(stop)).unwrap();
    }

    if let Some(ref post_stop) = exec_set.post_stop {
        writeln!(
            unit,
            "ExecStopPost=/bin/bash -c '{}'",
            escape_bash(post_stop)
        )
        .unwrap();
    }

    if let Some(ref workdir) = service.workdir {
        let resolved = resolve_workdir(workdir, &config.project_dir);
        writeln!(unit, "WorkingDirectory=\"{}\"", escape_systemd(&resolved)).unwrap();
    }

    let mut env_keys: Vec<&String> = service.env.keys().collect();
    env_keys.sort();
    for key in env_keys {
        let value = &service.env[key];
        writeln!(unit, "Environment=\"{}={}\"", key, escape_systemd(value)).unwrap();
    }

    for env_file in &service.env_files {
        let resolved = resolve_path(env_file, &config.project_dir);
        writeln!(unit, "EnvironmentFile=\"{}\"", escape_systemd(&resolved)).unwrap();
    }

    if let Some(ref user) = service.user {
        writeln!(unit, "User={}", user).unwrap();
    }

    if !service.oneshot {
        let restart_str = match service.restart.policy {
            RestartPolicy::No => "no",
            RestartPolicy::Always => "always",
            RestartPolicy::OnFailure => "on-failure",
        };
        writeln!(unit, "Restart={}", restart_str).unwrap();

        if let Some(ref delay) = service.restart.delay {
            writeln!(unit, "RestartSec={}", delay).unwrap();
        }
    }

    if let Some(ref start) = service.timeouts.start {
        writeln!(unit, "TimeoutStartSec={}", start).unwrap();
    }
    if let Some(ref stop) = service.timeouts.stop {
        writeln!(unit, "TimeoutStopSec={}", stop).unwrap();
    }

    if let Some(ref memory) = service.resources.memory {
        writeln!(unit, "MemoryMax={}", memory).unwrap();
    }

    if let Some(ref cpu_quota) = service.resources.cpu_quota {
        writeln!(unit, "CPUQuota={}", cpu_quota).unwrap();
    } else if let Some(cpus) = service.resources.cpus {
        let percent = (cpus * 100.0) as u32;
        writeln!(unit, "CPUQuota={}%", percent).unwrap();
    }

    if let Some(nofile) = service.resources.limit_nofile {
        writeln!(unit, "LimitNOFILE={}", nofile).unwrap();
    }
    if let Some(nproc) = service.resources.limit_nproc {
        writeln!(unit, "LimitNPROC={}", nproc).unwrap();
    }
    if let Some(tasks_max) = service.resources.tasks_max {
        writeln!(unit, "TasksMax={}", tasks_max).unwrap();
    }
    if let Some(io_weight) = service.resources.io_weight {
        writeln!(unit, "IOWeight={}", io_weight).unwrap();
    }

    if let Some(ref stdout) = service.logging.stdout {
        writeln!(
            unit,
            "StandardOutput=\"file:{}\"",
            escape_systemd(&resolve_path(stdout, &config.project_dir))
        )
        .unwrap();
    }
    if let Some(ref stderr) = service.logging.stderr {
        writeln!(
            unit,
            "StandardError=\"file:{}\"",
            escape_systemd(&resolve_path(stderr, &config.project_dir))
        )
        .unwrap();
    }

    writeln!(unit).unwrap();
    writeln!(unit, "[Install]").unwrap();
    writeln!(unit, "WantedBy={}", config.target_name()).unwrap();

    unit
}

pub fn generate_ready_gate(service: &Service, config: &Config) -> String {
    let mut unit = String::with_capacity(512);

    writeln!(unit, "[Unit]").unwrap();
    writeln!(unit, "Description=orch: wait for {} health", service.name).unwrap();
    writeln!(unit, "After={}", config.unit_name(&service.name)).unwrap();
    writeln!(unit, "BindsTo={}", config.unit_name(&service.name)).unwrap();

    writeln!(unit).unwrap();
    writeln!(unit, "[Service]").unwrap();
    writeln!(unit, "Type=oneshot").unwrap();
    writeln!(unit, "RemainAfterExit=yes").unwrap();

    // A REQUIRES dependency with no HEALTHCHECK still gets a gate (enforcement
    // is the point), but there is no probe to poll. Match the launchd path,
    // which polls `true` in this case: gate on the unit coming up, which
    // After= + BindsTo= above already express.
    match service.healthcheck.as_deref() {
        Some(healthcheck) => {
            let timeout = service.readiness_timeout.as_deref().unwrap_or("90s");
            writeln!(
                unit,
                "ExecStart=/bin/bash -c 'until {} >/dev/null 2>&1; do sleep 2; done; exit 0'",
                escape_bash(&healthcheck_to_cmd(healthcheck))
            )
            .unwrap();
            writeln!(unit, "TimeoutStartSec={}", timeout).unwrap();
        }
        None => {
            writeln!(unit, "ExecStart=/bin/true").unwrap();
        }
    }

    unit
}

pub fn generate_target(_config: &Config) -> String {
    let mut unit = String::with_capacity(128);

    writeln!(unit, "[Unit]").unwrap();
    writeln!(unit, "Description=orch managed services").unwrap();

    writeln!(unit).unwrap();
    writeln!(unit, "[Install]").unwrap();
    writeln!(unit, "WantedBy=multi-user.target").unwrap();

    unit
}

pub fn services_needing_ready_gates(services: &[Service]) -> HashSet<String> {
    let mut depended_upon: HashSet<String> = HashSet::new();
    for svc in services {
        if svc.disabled {
            continue;
        }
        for dep in &svc.requires {
            depended_upon.insert(dep.clone());
        }
        for dep in &svc.after {
            depended_upon.insert(dep.clone());
        }
    }

    let mut gates = HashSet::new();
    let mut required_refs: HashSet<String> = HashSet::new();
    for svc in services {
        if svc.disabled {
            continue;
        }
        for dep in &svc.requires {
            required_refs.insert(dep.clone());
        }
    }
    for svc in services {
        if svc.disabled {
            continue;
        }
        if depended_upon.contains(&svc.name)
            && (svc.healthcheck.is_some() || required_refs.contains(&svc.name))
        {
            gates.insert(svc.name.clone());
        }
    }

    gates
}

fn build_dependencies(
    service: &Service,
    config: &Config,
    ready_gates: &HashSet<String>,
) -> (Vec<String>, Vec<String>) {
    let mut after = Vec::new();
    let mut binds_to = Vec::new();

    for dep in &service.requires {
        binds_to.push(config.unit_name(dep));

        if ready_gates.contains(dep) {
            after.push(format!("{}-{}-ready.service", config.namespace, dep));
        } else {
            after.push(config.unit_name(dep));
        }
    }

    for dep in &service.after {
        if ready_gates.contains(dep) {
            after.push(format!("{}-{}-ready.service", config.namespace, dep));
        } else {
            after.push(config.unit_name(dep));
        }
    }

    (after, binds_to)
}

fn escape_bash(cmd: &str) -> String {
    cmd.replace('\'', "'\\''")
}

/// Escape a value written into a double-quoted systemd directive.
///
/// systemd.syntax(7) unquotes with C-style escapes, and systemd.exec(5) is
/// explicit that Environment= performs *specifier* expansion ("Specifier
/// expansion is performed"). So a literal `"`, `\` or `%` has to be escaped as
/// `\"`, `\\` and `%%` or systemd either fails to parse the unit or silently
/// substitutes a specifier such as %d or %n into the value.
///
/// `$` is deliberately left alone: the same man page states that variable
/// expansion is not performed there and `$` has no special meaning.
fn escape_systemd(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for c in value.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '%' => out.push_str("%%"),
            _ => out.push(c),
        }
    }
    out
}

fn resolve_path(path: &str, project_dir: &std::path::Path) -> String {
    if std::path::Path::new(path).is_absolute() {
        path.to_string()
    } else {
        project_dir.join(path).display().to_string()
    }
}

fn resolve_workdir(workdir: &str, project_dir: &std::path::Path) -> String {
    resolve_path(workdir, project_dir)
}

#[cfg(test)]
#[allow(non_snake_case)]
mod tests {
    use super::*;
    use crate::types::*;
    use std::collections::HashMap;
    use std::path::PathBuf;

    fn test_config() -> Config {
        Config {
            orchfile: PathBuf::from("/test/Orchfile"),
            overlays: Vec::new(),
            runtime: "bare".to_string(),
            platform: "systemd".to_string(),
            scope: crate::config::Scope::System,
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
        ExecSet {
            start: start.to_string(),
            pre_start: None,
            stop: None,
            post_stop: None,
        }
    }

    #[test]
    fn test_generate_service_unit__basic_host_service() {
        let config = test_config();
        let svc = simple_host_service("django", "python manage.py runserver 0.0.0.0:9090");
        let exec = simple_exec_set("python manage.py runserver 0.0.0.0:9090");
        let gates = HashSet::new();

        let unit = generate_service_unit(&svc, &exec, &config, &gates);

        assert!(unit.contains("[Unit]"));
        assert!(unit.contains("Description=orch: django"));
        assert!(unit.contains("PartOf=orch.target"));
        assert!(unit.contains("[Service]"));
        assert!(unit.contains("Type=simple"));
        assert!(unit.contains("ExecStart=/bin/bash -c 'python manage.py runserver 0.0.0.0:9090'"));
        assert!(unit.contains("Restart=no"));
        assert!(unit.contains("[Install]"));
        assert!(unit.contains("WantedBy=orch.target"));
    }

    #[test]
    fn test_generate_service_unit__oneshot() {
        let config = test_config();
        let mut svc = simple_host_service("migrate", "python manage.py migrate");
        svc.oneshot = true;
        let exec = simple_exec_set("python manage.py migrate");
        let gates = HashSet::new();

        let unit = generate_service_unit(&svc, &exec, &config, &gates);

        assert!(unit.contains("Type=oneshot"));
        assert!(unit.contains("RemainAfterExit=yes"));
        assert!(!unit.contains("Restart="));
    }

    #[test]
    fn test_generate_service_unit__with_environment() {
        let config = test_config();
        let mut svc = simple_host_service("webapp", "python manage.py runserver");
        svc.env.insert(
            "DJANGO_SETTINGS_MODULE".to_string(),
            "myapp.settings.dev".to_string(),
        );
        svc.env.insert("DEBUG".to_string(), "true".to_string());
        let exec = simple_exec_set("python manage.py runserver");
        let gates = HashSet::new();

        let unit = generate_service_unit(&svc, &exec, &config, &gates);

        assert!(unit.contains("Environment=\"DEBUG=true\""));
        assert!(unit.contains("Environment=\"DJANGO_SETTINGS_MODULE=myapp.settings.dev\""));
    }

    #[test]
    fn test_generate_service_unit__with_restart_on_failure() {
        let config = test_config();
        let mut svc = simple_host_service("worker", "celery -A myapp worker");
        svc.restart = RestartConfig {
            policy: RestartPolicy::OnFailure,
            delay: Some("5s".to_string()),
            start_limit_burst: Some(3),
            start_limit_interval: Some("60s".to_string()),
        };
        let exec = simple_exec_set("celery -A myapp worker");
        let gates = HashSet::new();

        let unit = generate_service_unit(&svc, &exec, &config, &gates);

        assert!(unit.contains("Restart=on-failure"));
        assert!(unit.contains("RestartSec=5s"));
        assert!(unit.contains("StartLimitBurst=3"));
        assert!(unit.contains("StartLimitIntervalSec=60s"));
    }

    /// Start limiting lives in [Unit]. systemd logs "Unknown key name
    /// 'StartLimitBurst' in section 'Service'" and ignores it there, which
    /// silently turns a bounded restart policy into an infinite crash loop.
    #[test]
    fn test_generate_service_unit__start_limits_are_in_unit_section() {
        let config = test_config();
        let mut svc = simple_host_service("worker", "celery -A myapp worker");
        svc.restart = RestartConfig {
            policy: RestartPolicy::OnFailure,
            delay: Some("5s".to_string()),
            start_limit_burst: Some(3),
            start_limit_interval: Some("60s".to_string()),
        };
        let exec = simple_exec_set("celery -A myapp worker");
        let gates = HashSet::new();

        let unit = generate_service_unit(&svc, &exec, &config, &gates);

        let (unit_section, service_section) = split_sections(&unit);
        assert!(
            unit_section.contains("StartLimitBurst=3"),
            "StartLimitBurst must be in [Unit], got:\n{}",
            unit_section
        );
        assert!(
            unit_section.contains("StartLimitIntervalSec=60s"),
            "StartLimitIntervalSec must be in [Unit], got:\n{}",
            unit_section
        );
        assert!(
            !service_section.contains("StartLimitBurst"),
            "StartLimitBurst must not be in [Service], got:\n{}",
            service_section
        );
        assert!(
            !service_section.contains("StartLimitIntervalSec"),
            "StartLimitIntervalSec must not be in [Service], got:\n{}",
            service_section
        );
        // Restart=/RestartSec= are [Service] keys and must stay there.
        assert!(service_section.contains("Restart=on-failure"));
        assert!(service_section.contains("RestartSec=5s"));
    }

    /// Split a unit file into its [Unit] and [Service] section bodies.
    fn split_sections(unit: &str) -> (String, String) {
        let mut current = String::new();
        let mut unit_section = String::new();
        let mut service_section = String::new();
        for line in unit.lines() {
            match line.trim() {
                "[Unit]" => current = "unit".to_string(),
                "[Service]" => current = "service".to_string(),
                _ => {
                    if current == "unit" {
                        unit_section.push_str(line);
                        unit_section.push('\n');
                    } else if current == "service" {
                        service_section.push_str(line);
                        service_section.push('\n');
                    }
                }
            }
        }
        (unit_section, service_section)
    }

    #[test]
    fn test_generate_service_unit__with_resources() {
        let config = test_config();
        let mut svc = simple_host_service("postgres", "postgres -p 5433");
        svc.resources = ResourceLimits {
            memory: Some("4G".to_string()),
            cpus: Some(2.0),
            cpu_quota: None,
            limit_nofile: Some(65536),
            limit_nproc: None,
            tasks_max: None,
            io_weight: None,
        };
        let exec = simple_exec_set("postgres -p 5433");
        let gates = HashSet::new();

        let unit = generate_service_unit(&svc, &exec, &config, &gates);

        assert!(unit.contains("MemoryMax=4G"));
        assert!(unit.contains("CPUQuota=200%"));
        assert!(unit.contains("LimitNOFILE=65536"));
    }

    #[test]
    fn test_generate_service_unit__cpu_quota_overrides_cpus() {
        let config = test_config();
        let mut svc = simple_host_service("app", "app run");
        svc.resources = ResourceLimits {
            cpus: Some(2.0),
            cpu_quota: Some("150%".to_string()),
            ..ResourceLimits::default()
        };
        let exec = simple_exec_set("app run");
        let gates = HashSet::new();

        let unit = generate_service_unit(&svc, &exec, &config, &gates);

        assert!(unit.contains("CPUQuota=150%"));
        assert!(!unit.contains("CPUQuota=200%"));
    }

    #[test]
    fn test_generate_service_unit__with_dependencies() {
        let config = test_config();
        let mut svc = simple_host_service("django", "python manage.py runserver");
        svc.requires = vec!["postgres".to_string(), "redis".to_string()];
        svc.after = vec!["localstack".to_string()];
        let exec = simple_exec_set("python manage.py runserver");

        let mut gates = HashSet::new();
        gates.insert("postgres".to_string());

        let unit = generate_service_unit(&svc, &exec, &config, &gates);

        assert!(unit.contains("BindsTo=orch-postgres.service orch-redis.service"));
        assert!(unit.contains("orch-postgres-ready.service"));
        assert!(unit.contains("orch-redis.service"));
        assert!(unit.contains("orch-localstack.service"));
    }

    #[test]
    fn test_generate_service_unit__with_workdir() {
        let config = test_config();
        let mut svc = simple_host_service("app", "python run.py");
        svc.workdir = Some("backend".to_string());
        let exec = simple_exec_set("python run.py");
        let gates = HashSet::new();

        let unit = generate_service_unit(&svc, &exec, &config, &gates);

        assert!(unit.contains("WorkingDirectory=\"/test/project/backend\""));
    }

    #[test]
    fn test_generate_service_unit__with_user() {
        let config = test_config();
        let mut svc = simple_host_service("postgres", "postgres -p 5433");
        svc.user = Some("postgres".to_string());
        let exec = simple_exec_set("postgres -p 5433");
        let gates = HashSet::new();

        let unit = generate_service_unit(&svc, &exec, &config, &gates);

        assert!(unit.contains("User=postgres"));
    }

    #[test]
    fn test_generate_service_unit__with_exec_set_stop() {
        let config = test_config();
        let svc = simple_host_service("nginx", "nginx -g 'daemon off;'");
        let exec = ExecSet {
            start: "nginx -g 'daemon off;'".to_string(),
            pre_start: Some("nginx -t".to_string()),
            stop: Some("nginx -s quit".to_string()),
            post_stop: Some("rm /run/nginx.pid".to_string()),
        };
        let gates = HashSet::new();

        let unit = generate_service_unit(&svc, &exec, &config, &gates);

        assert!(unit.contains("ExecStartPre=/bin/bash -c 'nginx -t'"));
        assert!(unit.contains("ExecStart=/bin/bash -c 'nginx -g '\\''daemon off;'\\'''"));
        assert!(unit.contains("ExecStop=/bin/bash -c 'nginx -s quit'"));
        assert!(unit.contains("ExecStopPost=/bin/bash -c 'rm /run/nginx.pid'"));
    }

    #[test]
    fn test_generate_ready_gate__basic() {
        let config = test_config();
        let mut svc = simple_host_service("postgres", "postgres -p 5433");
        svc.healthcheck = Some("pg_isready -h localhost -p 5433".to_string());
        svc.readiness_timeout = Some("60s".to_string());

        let unit = generate_ready_gate(&svc, &config);

        assert!(unit.contains("Description=orch: wait for postgres health"));
        assert!(unit.contains("After=orch-postgres.service"));
        assert!(unit.contains("BindsTo=orch-postgres.service"));
        assert!(unit.contains("Type=oneshot"));
        assert!(unit.contains("RemainAfterExit=yes"));
        assert!(unit.contains(
            "until pg_isready -h localhost -p 5433 >/dev/null 2>&1; do sleep 2; done; exit 0"
        ));
        assert!(unit.contains("TimeoutStartSec=60s"));
    }

    #[test]
    fn test_generate_ready_gate__http_converted_to_curl() {
        let config = test_config();
        let mut svc = simple_host_service("web", "web");
        svc.healthcheck = Some("http://localhost:8000/health".to_string());

        let unit = generate_ready_gate(&svc, &config);

        assert!(unit.contains("curl -sf"));
        assert!(unit.contains("http://localhost:8000/health"));
        assert!(!unit.contains("http://localhost:8000/health; do"));
    }

    #[test]
    fn test_generate_ready_gate__default_timeout() {
        let config = test_config();
        let mut svc = simple_host_service("redis", "redis-server");
        svc.healthcheck = Some("redis-cli ping".to_string());

        let unit = generate_ready_gate(&svc, &config);

        assert!(unit.contains("TimeoutStartSec=90s"));
    }

    #[test]
    fn test_generate_ready_gate__proceeds_on_timeout() {
        let config = test_config();
        let mut svc = simple_host_service("db", "db");
        svc.healthcheck = Some("pg_isready".to_string());

        let unit = generate_ready_gate(&svc, &config);

        assert!(unit.contains("done; exit 0"));
    }

    /// A REQUIRES dependency with no HEALTHCHECK gets a gate, but has no probe
    /// to poll. This used to panic on `.expect("ready gate requires a
    /// healthcheck")` -- the fallback removed in #51 was reachable after all.
    #[test]
    fn test_generate_ready_gate__no_healthcheck_does_not_panic() {
        let config = test_config();
        let svc = simple_host_service("postgres", "postgres -p 5433"); // no healthcheck

        let unit = generate_ready_gate(&svc, &config);

        assert!(unit.contains("After=orch-postgres.service"));
        assert!(unit.contains("BindsTo=orch-postgres.service"));
        assert!(unit.contains("ExecStart=/bin/true"));
        assert!(
            !unit.contains("until "),
            "no probe to poll without a healthcheck:\n{}",
            unit
        );
        assert!(!unit.contains("TimeoutStartSec="));
    }

    /// End-to-end through the gate selection: a required dep lacking a
    /// healthcheck is selected for a gate, so generation must survive it.
    #[test]
    fn test_required_dep_without_healthcheck_generates_without_panic() {
        let config = test_config();
        let db = simple_host_service("postgres", "postgres -p 5433");
        let mut web = simple_host_service("web", "web run");
        web.requires = vec!["postgres".to_string()];
        let services = vec![db, web];

        let gates = services_needing_ready_gates(&services);
        assert!(gates.contains("postgres"));

        for svc in services.iter().filter(|s| gates.contains(&s.name)) {
            let unit = generate_ready_gate(svc, &config);
            assert!(unit.contains("ExecStart=/bin/true"));
        }
    }

    #[test]
    fn test_generate_target() {
        let config = test_config();
        let unit = generate_target(&config);

        assert!(unit.contains("Description=orch managed services"));
        assert!(unit.contains("WantedBy=multi-user.target"));
    }

    #[test]
    fn test_services_needing_ready_gates__basic() {
        let mut postgres = simple_host_service("postgres", "postgres -p 5433");
        postgres.healthcheck = Some("pg_isready".to_string());

        let mut redis = simple_host_service("redis", "redis-server");
        redis.healthcheck = Some("redis-cli ping".to_string());

        let mut django = simple_host_service("django", "python manage.py runserver");
        django.requires = vec!["postgres".to_string()];

        let services = vec![postgres, redis, django];
        let gates = services_needing_ready_gates(&services);

        assert!(gates.contains("postgres"));
        assert!(!gates.contains("redis"));
        assert!(!gates.contains("django"));
    }

    #[test]
    fn test_services_needing_ready_gates__after_dep() {
        let mut localstack = simple_host_service("localstack", "localstack start");
        localstack.healthcheck = Some("curl -sf http://localhost:4566".to_string());

        let mut celery = simple_host_service("celery", "celery worker");
        celery.after = vec!["localstack".to_string()];

        let services = vec![localstack, celery];
        let gates = services_needing_ready_gates(&services);

        assert!(gates.contains("localstack"));
    }

    #[test]
    fn test_services_needing_ready_gates__requires_no_healthcheck_gets_gate() {
        let postgres = simple_host_service("postgres", "postgres -p 5433");

        let mut django = simple_host_service("django", "python manage.py runserver");
        django.requires = vec!["postgres".to_string()];

        let services = vec![postgres, django];
        let gates = services_needing_ready_gates(&services);

        assert!(gates.contains("postgres"));
    }

    #[test]
    fn test_services_needing_ready_gates__disabled_deps_ignored() {
        let mut postgres = simple_host_service("postgres", "postgres -p 5433");
        postgres.healthcheck = Some("pg_isready".to_string());

        let mut django = simple_host_service("django", "python manage.py runserver");
        django.requires = vec!["postgres".to_string()];
        django.disabled = true; // disabled service's deps don't count

        let services = vec![postgres, django];
        let gates = services_needing_ready_gates(&services);

        assert!(gates.is_empty());
    }

    #[test]
    fn test_escape_bash__single_quotes() {
        let result = escape_bash("echo 'hello world'");
        assert_eq!(result, "echo '\\''hello world'\\''");
    }

    #[test]
    fn test_escape_bash__no_special_chars() {
        let result = escape_bash("python manage.py runserver");
        assert_eq!(result, "python manage.py runserver");
    }

    // --- systemd value/path escaping ----------------------------------------

    #[test]
    fn test_escape_systemd__escapes_quotes_backslash_and_percent() {
        assert_eq!(escape_systemd("plain"), "plain");
        assert_eq!(escape_systemd(r#"has "quotes""#), r#"has \"quotes\""#);
        assert_eq!(escape_systemd(r"back\slash"), r"back\\slash");
        assert_eq!(escape_systemd("100%"), "100%%");
        assert_eq!(escape_systemd("%d"), "%%d");
        // $ is explicitly NOT special inside Environment=, so leave it alone.
        assert_eq!(escape_systemd("$HOME"), "$HOME");
    }

    #[test]
    fn test_generate_service_unit__env_value_with_quote_is_escaped() {
        let config = test_config();
        let mut svc = simple_host_service("app", "app run");
        svc.env.insert("NOTE".into(), r#"he said "hi""#.into());
        let exec = simple_exec_set("app run");
        let unit = generate_service_unit(&svc, &exec, &config, &HashSet::new());

        assert!(
            unit.contains(r#"Environment="NOTE=he said \"hi\"""#),
            "quote not escaped:\n{}",
            unit
        );
    }

    #[test]
    fn test_generate_service_unit__env_value_with_percent_is_escaped() {
        let config = test_config();
        let mut svc = simple_host_service("app", "app run");
        svc.env.insert("PW".into(), "a%d%b".into());
        let exec = simple_exec_set("app run");
        let unit = generate_service_unit(&svc, &exec, &config, &HashSet::new());

        assert!(
            unit.contains(r#"Environment="PW=a%%d%%b""#),
            "percent not escaped for specifier expansion:\n{}",
            unit
        );
    }

    #[test]
    fn test_generate_service_unit__paths_are_quoted() {
        let config = test_config();
        let mut svc = simple_host_service("app", "app run");
        svc.workdir = Some("my dir".to_string());
        svc.env_files = vec!["some dir/.env".to_string()];
        svc.logging = LogConfig {
            stdout: Some("log dir/out.log".to_string()),
            stderr: Some("log dir/err.log".to_string()),
        };
        let exec = simple_exec_set("app run");
        let unit = generate_service_unit(&svc, &exec, &config, &HashSet::new());

        assert!(
            unit.contains("WorkingDirectory=\"/test/project/my dir\""),
            "workdir not quoted:\n{}",
            unit
        );
        assert!(
            unit.contains("EnvironmentFile=\"/test/project/some dir/.env\""),
            "env file not quoted:\n{}",
            unit
        );
        assert!(
            unit.contains("StandardOutput=\"file:/test/project/log dir/out.log\""),
            "stdout not quoted:\n{}",
            unit
        );
        assert!(unit.contains("StandardError=\"file:/test/project/log dir/err.log\""));
    }

    #[test]
    fn test_generate_service_unit__with_env_files() {
        let config = test_config();
        let mut svc = simple_host_service("app", "python run.py");
        svc.env_files = vec![".env.local".to_string(), "/etc/app/env".to_string()];
        let exec = simple_exec_set("python run.py");
        let gates = HashSet::new();

        let unit = generate_service_unit(&svc, &exec, &config, &gates);

        assert!(unit.contains("EnvironmentFile=\"/test/project/.env.local\""));
        assert!(unit.contains("EnvironmentFile=\"/etc/app/env\""));
    }

    #[test]
    fn test_generate_service_unit__with_timeouts() {
        let config = test_config();
        let mut svc = simple_host_service("slow", "slow-start");
        svc.timeouts = TimeoutConfig {
            start: Some("300s".to_string()),
            stop: Some("30s".to_string()),
        };
        let exec = simple_exec_set("slow-start");
        let gates = HashSet::new();

        let unit = generate_service_unit(&svc, &exec, &config, &gates);

        assert!(unit.contains("TimeoutStartSec=300s"));
        assert!(unit.contains("TimeoutStopSec=30s"));
    }

    #[test]
    fn test_generate_service_unit__with_logging() {
        let config = test_config();
        let mut svc = simple_host_service("app", "app run");
        svc.logging = LogConfig {
            stdout: Some("/var/log/app/stdout.log".to_string()),
            stderr: Some("/var/log/app/stderr.log".to_string()),
        };
        let exec = simple_exec_set("app run");
        let gates = HashSet::new();

        let unit = generate_service_unit(&svc, &exec, &config, &gates);

        assert!(unit.contains("StandardOutput=\"file:/var/log/app/stdout.log\""));
        assert!(unit.contains("StandardError=\"file:/var/log/app/stderr.log\""));
    }
}
