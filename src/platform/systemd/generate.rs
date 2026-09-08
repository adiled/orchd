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

    writeln!(unit).unwrap();
    writeln!(unit, "[Service]").unwrap();

    if service.oneshot {
        writeln!(unit, "Type=oneshot").unwrap();
        writeln!(unit, "RemainAfterExit=yes").unwrap();
    } else {
        writeln!(unit, "Type=simple").unwrap();
    }

    if let Some(ref pre_start) = exec_set.pre_start {
        writeln!(unit, "ExecStartPre=/bin/bash -c '{}'", escape_bash(pre_start)).unwrap();
    }

    writeln!(unit, "ExecStart=/bin/bash -c '{}'", escape_bash(&exec_set.start)).unwrap();

    if let Some(ref stop) = exec_set.stop {
        writeln!(unit, "ExecStop=/bin/bash -c '{}'", escape_bash(stop)).unwrap();
    }

    if let Some(ref post_stop) = exec_set.post_stop {
        writeln!(unit, "ExecStopPost=/bin/bash -c '{}'", escape_bash(post_stop)).unwrap();
    }

    if let Some(ref workdir) = service.workdir {
        let resolved = resolve_workdir(workdir, &config.project_dir);
        writeln!(unit, "WorkingDirectory={}", resolved).unwrap();
    }

    let mut env_keys: Vec<&String> = service.env.keys().collect();
    env_keys.sort();
    for key in env_keys {
        let value = &service.env[key];
        writeln!(unit, "Environment=\"{}={}\"", key, value).unwrap();
    }

    for env_file in &service.env_files {
        let resolved = resolve_path(env_file, &config.project_dir);
        writeln!(unit, "EnvironmentFile={}", resolved).unwrap();
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

    if let Some(burst) = service.restart.start_limit_burst {
        writeln!(unit, "StartLimitBurst={}", burst).unwrap();
    }
    if let Some(ref interval) = service.restart.start_limit_interval {
        writeln!(unit, "StartLimitIntervalSec={}", interval).unwrap();
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
        writeln!(unit, "StandardOutput=file:{}", resolve_path(stdout, &config.project_dir)).unwrap();
    }
    if let Some(ref stderr) = service.logging.stderr {
        writeln!(unit, "StandardError=file:{}", resolve_path(stderr, &config.project_dir)).unwrap();
    }

    writeln!(unit).unwrap();
    writeln!(unit, "[Install]").unwrap();
    writeln!(unit, "WantedBy={}", config.target_name()).unwrap();

    unit
}

pub fn generate_ready_gate(service: &Service, config: &Config) -> String {
    let healthcheck = service.healthcheck.as_deref().expect("ready gate requires a healthcheck");
    let timeout = service.readiness_timeout.as_deref().unwrap_or("90s");

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
        "ExecStart=/bin/bash -c 'until {} >/dev/null 2>&1; do sleep 2; done; exit 0'",
        escape_bash(&healthcheck_to_cmd(healthcheck))
    )
    .unwrap();
    writeln!(unit, "TimeoutStartSec={}", timeout).unwrap();

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
        assert!(unit.contains("until pg_isready -h localhost -p 5433 >/dev/null 2>&1; do sleep 2; done; exit 0"));
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
