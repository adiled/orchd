use std::collections::HashSet;
use std::fmt::Write;

use crate::config::Config;
use crate::exec::ExecSet;
use crate::types::{RestartPolicy, Service};

/// Generate a systemd .service unit file for a service.
///
/// `ready_gates` is the set of service names that have ready gate units generated.
/// Dependencies that have ready gates use After=orch-<dep>-ready.service for ordering.
pub fn generate_service_unit(
    service: &Service,
    exec_set: &ExecSet,
    config: &Config,
    ready_gates: &HashSet<String>,
) -> String {
    let mut unit = String::with_capacity(1024);

    // [Unit] section
    writeln!(unit, "[Unit]").unwrap();
    writeln!(unit, "Description=orch: {}", service.name).unwrap();
    writeln!(unit, "PartOf={}", config.target_name()).unwrap();

    // Dependencies
    let (after_deps, binds_to_deps) = build_dependencies(service, config, ready_gates);

    if !after_deps.is_empty() {
        writeln!(unit, "After={}", after_deps.join(" ")).unwrap();
    }
    if !binds_to_deps.is_empty() {
        writeln!(unit, "BindsTo={}", binds_to_deps.join(" ")).unwrap();
    }

    // [Service] section
    writeln!(unit).unwrap();
    writeln!(unit, "[Service]").unwrap();

    if service.oneshot {
        writeln!(unit, "Type=oneshot").unwrap();
        writeln!(unit, "RemainAfterExit=yes").unwrap();
    } else {
        writeln!(unit, "Type=simple").unwrap();
    }

    // ExecStartPre
    if let Some(ref pre_start) = exec_set.pre_start {
        writeln!(unit, "ExecStartPre=/bin/bash -c '{}'", escape_bash(pre_start)).unwrap();
    }

    // ExecStart
    writeln!(unit, "ExecStart=/bin/bash -c '{}'", escape_bash(&exec_set.start)).unwrap();

    // ExecStop
    if let Some(ref stop) = exec_set.stop {
        writeln!(unit, "ExecStop=/bin/bash -c '{}'", escape_bash(stop)).unwrap();
    }

    // ExecStopPost
    if let Some(ref post_stop) = exec_set.post_stop {
        writeln!(unit, "ExecStopPost=/bin/bash -c '{}'", escape_bash(post_stop)).unwrap();
    }

    // WorkingDirectory
    if let Some(ref workdir) = service.workdir {
        let resolved = resolve_workdir(workdir, &config.project_dir);
        writeln!(unit, "WorkingDirectory={}", resolved).unwrap();
    }

    // Environment
    // Sort keys for deterministic output
    let mut env_keys: Vec<&String> = service.env.keys().collect();
    env_keys.sort();
    for key in env_keys {
        let value = &service.env[key];
        writeln!(unit, "Environment=\"{}={}\"", key, value).unwrap();
    }

    // EnvironmentFile
    for env_file in &service.env_files {
        let resolved = resolve_path(env_file, &config.project_dir);
        writeln!(unit, "EnvironmentFile={}", resolved).unwrap();
    }

    // User
    if let Some(ref user) = service.user {
        writeln!(unit, "User={}", user).unwrap();
    }

    // Restart (only for non-oneshot)
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

    // Start limits
    if let Some(burst) = service.restart.start_limit_burst {
        writeln!(unit, "StartLimitBurst={}", burst).unwrap();
    }
    if let Some(ref interval) = service.restart.start_limit_interval {
        writeln!(unit, "StartLimitIntervalSec={}", interval).unwrap();
    }

    // Timeouts
    if let Some(ref start) = service.timeouts.start {
        writeln!(unit, "TimeoutStartSec={}", start).unwrap();
    }
    if let Some(ref stop) = service.timeouts.stop {
        writeln!(unit, "TimeoutStopSec={}", stop).unwrap();
    }

    // Resource limits
    if let Some(ref memory) = service.resources.memory {
        writeln!(unit, "MemoryMax={}", memory).unwrap();
    }

    // CPUS → CPUQuota: cpu_quota takes precedence over cpus
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

    // Logging
    if let Some(ref stdout) = service.logging.stdout {
        writeln!(unit, "StandardOutput=file:{}", resolve_path(stdout, &config.project_dir)).unwrap();
    }
    if let Some(ref stderr) = service.logging.stderr {
        writeln!(unit, "StandardError=file:{}", resolve_path(stderr, &config.project_dir)).unwrap();
    }

    // [Install] section
    writeln!(unit).unwrap();
    writeln!(unit, "[Install]").unwrap();
    writeln!(unit, "WantedBy={}", config.target_name()).unwrap();

    unit
}

/// Generate a ready gate unit for a service that has a healthcheck.
///
/// The ready gate is a oneshot that polls the healthcheck until it passes.
/// Dependent services After= this unit instead of the main service unit.
pub fn generate_ready_gate(service: &Service, config: &Config) -> String {
    let healthcheck = service.healthcheck.as_deref().unwrap_or("true");
    let timeout = service.readiness_timeout.as_deref().unwrap_or("120s");

    let mut unit = String::with_capacity(512);

    writeln!(unit, "[Unit]").unwrap();
    writeln!(unit, "Description=orch: wait for {} health", service.name).unwrap();
    writeln!(unit, "After={}", config.unit_name(&service.name)).unwrap();
    writeln!(unit, "BindsTo={}", config.unit_name(&service.name)).unwrap();

    writeln!(unit).unwrap();
    writeln!(unit, "[Service]").unwrap();
    writeln!(unit, "Type=oneshot").unwrap();
    writeln!(unit, "RemainAfterExit=yes").unwrap();
    writeln!(
        unit,
        "ExecStart=/bin/bash -c 'until {} >/dev/null 2>&1; do sleep 2; done'",
        escape_bash(healthcheck)
    )
    .unwrap();
    writeln!(unit, "TimeoutStartSec={}", timeout).unwrap();

    unit
}

/// Generate the orch.target that groups all managed services.
pub fn generate_target(_config: &Config) -> String {
    let mut unit = String::with_capacity(128);

    writeln!(unit, "[Unit]").unwrap();
    writeln!(unit, "Description=orch managed services").unwrap();

    writeln!(unit).unwrap();
    writeln!(unit, "[Install]").unwrap();
    writeln!(unit, "WantedBy=multi-user.target").unwrap();

    unit
}

/// Determine which services need ready gates.
///
/// A service needs a ready gate when it has a healthcheck AND at least one
/// other enabled service lists it in `requires` or `after`.
pub fn services_needing_ready_gates(services: &[Service]) -> HashSet<String> {
    // Collect all dependency references
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

    // A service needs a ready gate if it has a healthcheck and is depended upon
    let mut gates = HashSet::new();
    for svc in services {
        if svc.disabled {
            continue;
        }
        if svc.healthcheck.is_some() && depended_upon.contains(&svc.name) {
            gates.insert(svc.name.clone());
        }
    }

    gates
}

/// Build After= and BindsTo= dependency lists for a service.
fn build_dependencies(
    service: &Service,
    config: &Config,
    ready_gates: &HashSet<String>,
) -> (Vec<String>, Vec<String>) {
    let mut after = Vec::new();
    let mut binds_to = Vec::new();

    // REQUIRES: hard dependency — BindsTo + After
    for dep in &service.requires {
        binds_to.push(config.unit_name(dep));

        // If the dep has a ready gate, After= the ready gate for ordering
        if ready_gates.contains(dep) {
            after.push(format!("{}-{}-ready.service", config.namespace, dep));
        } else {
            after.push(config.unit_name(dep));
        }
    }

    // AFTER: soft dependency — After only
    for dep in &service.after {
        if ready_gates.contains(dep) {
            after.push(format!("{}-{}-ready.service", config.namespace, dep));
        } else {
            after.push(config.unit_name(dep));
        }
    }

    (after, binds_to)
}

/// Escape single quotes in a bash command for use in: /bin/bash -c '...'
fn escape_bash(cmd: &str) -> String {
    // Replace ' with '\'' (end quote, escaped quote, start quote)
    cmd.replace('\'', "'\\''")
}

/// Resolve a path: if relative, join with project_dir.
fn resolve_path(path: &str, project_dir: &std::path::Path) -> String {
    if std::path::Path::new(path).is_absolute() {
        path.to_string()
    } else {
        project_dir.join(path).display().to_string()
    }
}

/// Resolve workdir: if relative, join with project_dir.
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
        svc.env.insert("DJANGO_SETTINGS_MODULE".to_string(), "myapp.settings.dev".to_string());
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

        // postgres has a ready gate, redis and localstack do not
        let mut gates = HashSet::new();
        gates.insert("postgres".to_string());

        let unit = generate_service_unit(&svc, &exec, &config, &gates);

        // BindsTo for requires
        assert!(unit.contains("BindsTo=orch-postgres.service orch-redis.service"));
        // After: postgres uses ready gate, redis uses main unit
        assert!(unit.contains("orch-postgres-ready.service"));
        assert!(unit.contains("orch-redis.service"));
        // After: localstack (soft dep, no ready gate)
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

        assert!(unit.contains("WorkingDirectory=/test/project/backend"));
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
        assert!(unit.contains("until pg_isready -h localhost -p 5433 >/dev/null 2>&1; do sleep 2; done"));
        assert!(unit.contains("TimeoutStartSec=60s"));
    }

    #[test]
    fn test_generate_ready_gate__default_timeout() {
        let config = test_config();
        let mut svc = simple_host_service("redis", "redis-server");
        svc.healthcheck = Some("redis-cli ping".to_string());

        let unit = generate_ready_gate(&svc, &config);

        assert!(unit.contains("TimeoutStartSec=120s"));
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

        // redis has healthcheck but nobody depends on it → no gate
        // postgres has healthcheck and django depends on it → gate
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
    fn test_services_needing_ready_gates__no_healthcheck_no_gate() {
        let postgres = simple_host_service("postgres", "postgres -p 5433");
        // no healthcheck

        let mut django = simple_host_service("django", "python manage.py runserver");
        django.requires = vec!["postgres".to_string()];

        let services = vec![postgres, django];
        let gates = services_needing_ready_gates(&services);

        assert!(gates.is_empty());
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

        // django is disabled, so nobody effectively depends on postgres
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

    #[test]
    fn test_generate_service_unit__with_env_files() {
        let config = test_config();
        let mut svc = simple_host_service("app", "python run.py");
        svc.env_files = vec![".env.local".to_string(), "/etc/app/env".to_string()];
        let exec = simple_exec_set("python run.py");
        let gates = HashSet::new();

        let unit = generate_service_unit(&svc, &exec, &config, &gates);

        assert!(unit.contains("EnvironmentFile=/test/project/.env.local"));
        assert!(unit.contains("EnvironmentFile=/etc/app/env"));
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

        assert!(unit.contains("StandardOutput=file:/var/log/app/stdout.log"));
        assert!(unit.contains("StandardError=file:/var/log/app/stderr.log"));
    }
}
