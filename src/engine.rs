use crate::config::Config;
use crate::exec::ExecSet;
use crate::platform::Platform;
use crate::platform::launchd::LaunchdPlatform;
use crate::platform::systemd::SystemdPlatform;
use crate::runtime;
use crate::types::OrchFile;

/// Errors from the engine pipeline.
#[derive(Debug, thiserror::Error)]
pub enum EngineError {
    #[error("orch parse failed: {0}")]
    OrchParse(String),
    #[error("runtime error: {0}")]
    Runtime(#[from] crate::runtime::RuntimeError),
    #[error("platform error: {0}")]
    Platform(#[from] crate::platform::PlatformError),
    #[error("service(s) skipped:\n{0}")]
    ServiceSkipped(String),
}

/// Run the full generate pipeline:
/// 1. Check mtime (skip if up-to-date unless `force`)
/// 2. Parse the Orchfile (+ overlays) in-process via the orch library
/// 3. Create runtime, check prerequisites
/// 4. For each enabled service: runtime.prepare() + runtime.exec_set()
/// 5. Platform generate_all() + install()
pub fn generate(config: &Config, force: bool, strict: bool) -> Result<(), EngineError> {
    // 1. Skip if artifacts are newer than Orchfile (unless --force)
    if !force && is_up_to_date(config) {
        if !config.quiet {
            eprintln!("artifacts up to date, skipping generate (use --force to override)");
        }
        return Ok(());
    }

    // 2. Parse the Orchfile (+ overlays) in-process via the orch library.
    let orchfile: OrchFile = parse_orchfile(config)?;

    if !config.quiet {
        eprintln!(
            "parsed {} services (orch v{})",
            orchfile.services.len(),
            orchfile.version
        );
    }

    // 3. Create runtime and check
    let rt = runtime::create_runtime(&config.runtime, config)?;
    rt.check()?;

    if !config.quiet {
        eprintln!("runtime: {}", rt.name());
    }

    // 4. Process each enabled service
    let mut exec_sets: Vec<(usize, ExecSet)> = Vec::new();
    let mut skipped = 0;
    let mut errors = Vec::new();

    for (idx, service) in orchfile.services.iter().enumerate() {
        if service.disabled {
            skipped += 1;
            if config.verbose {
                eprintln!("  skip: {} (disabled)", service.name);
            }
            continue;
        }

        lint_service(&config.platform, service);

        // Prepare (create data dirs, etc.)
        if let Err(e) = rt.prepare(service) {
            errors.push(format!("{}: {}", service.name, e));
            continue;
        }

        // Build ExecSet
        match rt.exec_set(service) {
            Ok(exec_set) => {
                if config.verbose {
                    eprintln!("  exec: {} -> {}", service.name, exec_set.start);
                }
                exec_sets.push((idx, exec_set));
            }
            Err(e) => {
                errors.push(format!("{}: {}", service.name, e));
            }
        }
    }

    if !errors.is_empty() {
        let summary = format!(
            "{} service(s) skipped (runtime incompatible):\n  {}",
            errors.len(),
            errors.join("\n  ")
        );
        if strict {
            return Err(EngineError::ServiceSkipped(summary));
        }
        eprintln!("warning: {}", summary);
    }

    if !config.quiet {
        eprintln!(
            "generating {} units ({} disabled)",
            exec_sets.len(),
            skipped
        );
    }

    // 5. Platform generate + install
    let generated = match config.platform.as_str() {
        "launchd" => {
            let platform = LaunchdPlatform::new();
            platform.check()?;
            let g = platform.generate_all(&orchfile.services, &exec_sets, config)?;
            if !config.quiet {
                for path in &g {
                    eprintln!("  wrote: {}", path);
                }
            }
            platform.install(config)?;
            g
        }
        "orchdi" => {
            let platform = crate::platform::orchdi::OrchdiPlatform::new();
            platform.check()?;
            let g = platform.generate_all(&orchfile.services, &exec_sets, config)?;
            if !config.quiet {
                for path in &g {
                    eprintln!("  wrote: {}", path);
                }
            }
            platform.install(config)?;
            g
        }
        _ => {
            let platform = SystemdPlatform::new();
            platform.check()?;
            let g = platform.generate_all(&orchfile.services, &exec_sets, config)?;
            if !config.quiet {
                for path in &g {
                    eprintln!("  wrote: {}", path);
                }
            }
            platform.install(config)?;
            g
        }
    };

    if !config.quiet {
        eprintln!("installed {} units", generated.len());
    }

    let mut env_files: Vec<std::path::PathBuf> = Vec::new();
    for service in &orchfile.services {
        for ef in &service.env_files {
            let resolved = if std::path::Path::new(ef).is_absolute() {
                std::path::PathBuf::from(ef)
            } else {
                config.project_dir.join(ef)
            };
            if !env_files.contains(&resolved) {
                env_files.push(resolved);
            }
        }
    }
    write_stamp(config, &env_files);

    Ok(())
}

/// Generate and start services.
/// If `no_generate` is false, runs generate first.
pub fn up(
    config: &Config,
    services: &[String],
    no_generate: bool,
    strict: bool,
    force: bool,
) -> Result<(), EngineError> {
    if !no_generate {
        generate(config, force, strict)?;
    }

    if !config.quiet {
        if services.is_empty() {
            eprintln!("starting all services...");
        } else {
            eprintln!("starting: {}", services.join(", "));
        }
    }

    match config.platform.as_str() {
        "launchd" => crate::platform::launchd::lifecycle::start(services, config)?,
        "orchdi" => crate::platform::orchdi::lifecycle::start(services, config)?,
        _ => crate::platform::systemd::lifecycle::start(services, config)?,
    }

    if !config.quiet {
        eprintln!("started");
    }

    Ok(())
}

/// Tear the grove down: stop everything and remove its beds.
pub fn fell(config: &Config, keep_data: bool) -> Result<(), EngineError> {
    clean(config, keep_data)
}

/// Bring the grove up: generate artifacts, then start (unless `no_start`).
pub fn grow(
    config: &Config,
    services: &[String],
    no_start: bool,
    strict: bool,
    force: bool,
) -> Result<(), EngineError> {
    if no_start {
        generate(config, force, strict)
    } else {
        up(config, services, false, strict, force)
    }
}

/// Show status of managed services.
pub fn status(config: &Config, as_json: bool) -> Result<(), EngineError> {
    match config.platform.as_str() {
        "launchd" => crate::platform::launchd::lifecycle::status(config, as_json)?,
        "orchdi" => crate::platform::orchdi::lifecycle::status(config, as_json)?,
        _ => crate::platform::systemd::lifecycle::status(config, as_json)?,
    }
    Ok(())
}

/// Tail logs for a service.
pub fn logs(config: &Config, service: &str, follow: bool, lines: u32) -> Result<(), EngineError> {
    match config.platform.as_str() {
        "launchd" => crate::platform::launchd::lifecycle::logs(service, follow, lines, config)?,
        "orchdi" => crate::platform::orchdi::lifecycle::logs(service, follow, lines, config)?,
        _ => crate::platform::systemd::lifecycle::logs(service, follow, lines, config)?,
    }
    Ok(())
}

/// Remove all generated artifacts and stop services.
pub fn clean(config: &Config, keep_data: bool) -> Result<(), EngineError> {
    // Stop all services first (ignore errors — they might not be running)
    match config.platform.as_str() {
        "launchd" => {
            let _ = crate::platform::launchd::lifecycle::stop(&[], config);
        }
        "orchdi" => {
            let _ = crate::platform::orchdi::lifecycle::stop(&[], config);
        }
        _ => {
            let _ = crate::platform::systemd::lifecycle::stop(&[], config);
        }
    }

    // Platform clean (remove units, unlink, daemon-reload)
    match config.platform.as_str() {
        "launchd" => {
            let platform = crate::platform::launchd::LaunchdPlatform::new();
            platform.clean(config)?;
        }
        "orchdi" => {
            let platform = crate::platform::orchdi::OrchdiPlatform::new();
            platform.clean(config)?;
        }
        _ => {
            let platform = crate::platform::systemd::SystemdPlatform::new();
            platform.clean(config)?;
        }
    }

    if !config.quiet {
        eprintln!("removed generated units");
    }

    // Remove data directories unless --keep-data
    if !keep_data {
        if config.data_dir.exists() {
            let _ = std::fs::remove_dir_all(&config.data_dir);
            if !config.quiet {
                eprintln!("removed data directory: {}", config.data_dir.display());
            }
        }
    }

    Ok(())
}

fn unsupported_directives(platform: &str, svc: &crate::types::Service) -> Vec<&'static str> {
    if platform != "launchd" {
        return Vec::new();
    }
    let mut out = Vec::new();
    let r = &svc.resources;
    if r.memory.is_some() {
        out.push("MEMORY");
    }
    if r.cpus.is_some() {
        out.push("CPUS");
    }
    if r.cpu_quota.is_some() {
        out.push("CPU_QUOTA");
    }
    if r.tasks_max.is_some() {
        out.push("TASKS_MAX");
    }
    if r.io_weight.is_some() {
        out.push("IO_WEIGHT");
    }
    if svc.timeouts.start.is_some() {
        out.push("TIMEOUT_START");
    }
    if svc.restart.start_limit_burst.is_some() {
        out.push("START_LIMIT_BURST");
    }
    if svc.restart.start_limit_interval.is_some() {
        out.push("START_LIMIT_INTERVAL");
    }
    out
}

fn lint_service(platform: &str, svc: &crate::types::Service) {
    let dropped = unsupported_directives(platform, svc);
    if !dropped.is_empty() {
        eprintln!(
            "warning: service '{}': {} not supported on {}; ignoring",
            svc.name,
            dropped.join(", "),
            platform
        );
    }

    if svc.reload_command.is_some() {
        eprintln!(
            "warning: service '{}': RELOAD is not implemented yet; ignoring",
            svc.name
        );
    }

    let durations: [(&str, Option<&String>); 5] = [
        ("RESTART_DELAY", svc.restart.delay.as_ref()),
        (
            "START_LIMIT_INTERVAL",
            svc.restart.start_limit_interval.as_ref(),
        ),
        ("TIMEOUT_START", svc.timeouts.start.as_ref()),
        ("TIMEOUT_STOP", svc.timeouts.stop.as_ref()),
        ("READINESS_TIMEOUT", svc.readiness_timeout.as_ref()),
    ];
    for (name, value) in durations {
        if let Some(v) = value {
            if crate::orchdi::parse_duration_secs(v).is_none() {
                eprintln!(
                    "warning: service '{}': {} '{}' is not a valid duration \
                     (grammar: integer followed by 's' or 'm')",
                    svc.name, name, v
                );
            }
        }
    }
}

#[derive(serde::Serialize, serde::Deserialize, Debug, PartialEq)]
struct InputStamp {
    path: String,
    mtime_ns: u128,
    size: u64,
}

#[derive(serde::Serialize, serde::Deserialize, Debug, PartialEq)]
struct Stamp {
    config_hash: u64,
    inputs: Vec<InputStamp>,
}

fn stamp_path(config: &Config) -> std::path::PathBuf {
    config.units_dir().join(".orchd-stamp")
}

fn config_hash(config: &Config) -> u64 {
    config_hash_for(config, env!("CARGO_PKG_VERSION"))
}

fn config_hash_for(config: &Config, orchd_version: &str) -> u64 {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let mut h = DefaultHasher::new();
    orchd_version.hash(&mut h);
    config.runtime.hash(&mut h);
    config.platform.hash(&mut h);
    config.namespace.hash(&mut h);
    format!("{:?}", config.scope).hash(&mut h);
    config.state_dir.hash(&mut h);
    config.project_dir.hash(&mut h);
    config.data_dir.hash(&mut h);
    for a in &config.args {
        a.hash(&mut h);
    }
    for (k, v) in env_arg_overrides() {
        k.hash(&mut h);
        v.hash(&mut h);
    }
    h.finish()
}

fn fingerprint(path: &std::path::Path) -> Option<InputStamp> {
    let meta = std::fs::metadata(path).ok()?;
    let mtime_ns = meta
        .modified()
        .ok()?
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_nanos();
    Some(InputStamp {
        path: path.display().to_string(),
        mtime_ns,
        size: meta.len(),
    })
}

fn write_stamp(config: &Config, env_files: &[std::path::PathBuf]) {
    let mut inputs: Vec<InputStamp> = Vec::new();
    let mut seen = std::collections::HashSet::new();
    let sources = std::iter::once(&config.orchfile)
        .chain(config.overlays.iter())
        .chain(env_files.iter());
    for p in sources {
        if let Some(fp) = fingerprint(p) {
            if seen.insert(fp.path.clone()) {
                inputs.push(fp);
            }
        }
    }
    let stamp = Stamp {
        config_hash: config_hash(config),
        inputs,
    };
    if let Ok(json) = serde_json::to_string_pretty(&stamp) {
        let _ = std::fs::write(stamp_path(config), json);
    }
}

fn is_up_to_date(config: &Config) -> bool {
    let units_dir = config.units_dir();
    if !units_dir.exists() {
        return false;
    }

    let has_artifacts = std::fs::read_dir(&units_dir)
        .map(|entries| {
            entries.flatten().any(|e| {
                matches!(
                    e.path().extension().and_then(|x| x.to_str()),
                    Some("plist") | Some("service") | Some("target")
                )
            })
        })
        .unwrap_or(false);
    if !has_artifacts {
        return false;
    }

    let data = match std::fs::read_to_string(stamp_path(config)) {
        Ok(d) => d,
        Err(_) => return false,
    };
    let stamp: Stamp = match serde_json::from_str(&data) {
        Ok(s) => s,
        Err(_) => return false,
    };

    if stamp.config_hash != config_hash(config) {
        return false;
    }

    for recorded in &stamp.inputs {
        match fingerprint(std::path::Path::new(&recorded.path)) {
            Some(now) if now == *recorded => {}
            _ => return false,
        }
    }

    true
}

fn parse_orchfile(config: &Config) -> Result<OrchFile, EngineError> {
    let mut files: Vec<(String, String)> = Vec::new();

    files.push(("orchd-vars.orch".to_string(), vars_overlay_content(config)));

    // Main Orchfile.
    let content = std::fs::read_to_string(&config.orchfile).map_err(|e| {
        EngineError::OrchParse(format!(
            "failed to read '{}': {}",
            config.orchfile.display(),
            e
        ))
    })?;
    files.push((config.orchfile.display().to_string(), content));

    // User overlays (merged left-to-right, so these override).
    for overlay in &config.overlays {
        let content = std::fs::read_to_string(overlay).map_err(|e| {
            EngineError::OrchParse(format!(
                "failed to read overlay '{}': {}",
                overlay.display(),
                e
            ))
        })?;
        files.push((overlay.display().to_string(), content));
    }

    let mut overrides = env_arg_overrides();

    for arg in &config.args {
        if let Some((k, v)) = arg.split_once('=') {
            overrides.insert(k.to_string(), v.to_string());
        } else if config.verbose {
            eprintln!("warning: ignoring --arg '{}' (expected name=value)", arg);
        }
    }

    if config.verbose {
        eprintln!("parsing {} file(s) in-process via the-orch", files.len());
    }

    let parsed = the_orch::parse_files(&files, &overrides).map_err(|errs| {
        let msg = errs
            .iter()
            .map(|e| e.to_string())
            .collect::<Vec<_>>()
            .join("; ");
        EngineError::OrchParse(msg)
    })?;

    let mut unknown: Vec<&String> = overrides
        .keys()
        .filter(|k| !parsed.args.contains_key(*k))
        .collect();
    unknown.sort();
    for key in unknown {
        eprintln!(
            "warning: no ARG named '{}' is declared; the override is ignored",
            key
        );
    }

    Ok(parsed)
}

fn env_arg_overrides() -> std::collections::HashMap<String, String> {
    let mut out = std::collections::HashMap::new();
    for (key, value) in std::env::vars() {
        if let Some(name) = key.strip_prefix("ORCH_ARG_") {
            if !name.is_empty() {
                out.insert(name.to_string(), value);
            }
        }
    }
    out
}

fn vars_overlay_content(config: &Config) -> String {
    format!(
        "# Auto-generated by orchd — built-in variable declarations\n\
         ARG ORCH_DATA={}\n\
         ARG ORCH_PROJECT={}\n\
         ARG ORCH_STATE_DIR={}\n\
         ARG ORCH_CONTAINERS_DIR={}\n",
        config.data_dir.display(),
        config.project_dir.display(),
        config.state_dir.display(),
        config.project_dir.display(), // ORCH_CONTAINERS_DIR defaults to project_dir
    )
}

#[cfg(test)]
#[allow(non_snake_case)]
mod tests {
    use super::*;

    static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    #[allow(clippy::type_complexity)]
    fn cache_fixture(
        name: &str,
        artifact: &str,
    ) -> (
        Config,
        std::path::PathBuf,
        std::sync::MutexGuard<'static, ()>,
    ) {
        let guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let root = std::env::temp_dir().join(format!("orchd-cache-{}", name));
        let _ = std::fs::remove_dir_all(&root);
        let proj = root.join("proj");
        std::fs::create_dir_all(&proj).unwrap();
        std::fs::write(proj.join("Orchfile"), "SERVICE web\nRUN sleep 1\n").unwrap();
        let cfg = Config {
            orchfile: proj.join("Orchfile"),
            overlays: vec![],
            runtime: "bare".to_string(),
            platform: if artifact == "plist" {
                "launchd".to_string()
            } else {
                "systemd".to_string()
            },
            scope: crate::config::Scope::User,
            state_dir: root.join(".orch"),
            project_dir: proj,
            data_dir: root.join(".orch/data"),
            namespace: "orch".to_string(),
            args: vec![],
            verbose: false,
            quiet: true,
        };
        std::fs::create_dir_all(cfg.units_dir()).unwrap();
        std::fs::write(cfg.units_dir().join(format!("orch.web.{}", artifact)), "x").unwrap();
        (cfg, root, guard)
    }

    #[test]
    fn test_is_up_to_date__launchd_plist_counts_as_generated() {
        let (cfg, root, _guard) = cache_fixture("plist", "plist");
        write_stamp(&cfg, &[]);
        assert!(
            is_up_to_date(&cfg),
            "a fresh launchd build with only .plist must be considered up to date"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn test_is_up_to_date__no_stamp_means_regenerate() {
        let (cfg, root, _guard) = cache_fixture("nostamp", "plist");
        assert!(!is_up_to_date(&cfg), "no stamp file means not up to date");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn test_is_up_to_date__missing_artifacts_means_regenerate() {
        let (cfg, root, _guard) = cache_fixture("noart", "plist");
        write_stamp(&cfg, &[]);
        std::fs::remove_file(cfg.units_dir().join("orch.web.plist")).unwrap();
        assert!(!is_up_to_date(&cfg));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn test_is_up_to_date__changed_orchfile_invalidates() {
        let (cfg, root, _guard) = cache_fixture("edit", "plist");
        write_stamp(&cfg, &[]);
        assert!(is_up_to_date(&cfg));
        std::thread::sleep(std::time::Duration::from_millis(1100));
        std::fs::write(cfg.orchfile.clone(), "SERVICE web\nRUN sleep 2\n").unwrap();
        assert!(!is_up_to_date(&cfg), "edited Orchfile must invalidate");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn test_is_up_to_date__changed_runtime_invalidates() {
        let (mut cfg, root, _guard) = cache_fixture("runtime", "plist");
        write_stamp(&cfg, &[]);
        assert!(is_up_to_date(&cfg));
        cfg.runtime = "apple".to_string();
        assert!(!is_up_to_date(&cfg), "runtime change must invalidate");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn test_is_up_to_date__changed_arg_invalidates() {
        let (mut cfg, root, _guard) = cache_fixture("arg", "plist");
        write_stamp(&cfg, &[]);
        assert!(is_up_to_date(&cfg));
        cfg.args.push("port=9999".to_string());
        assert!(!is_up_to_date(&cfg), "--arg change must invalidate");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn test_is_up_to_date__changed_namespace_invalidates() {
        let (mut cfg, root, _guard) = cache_fixture("ns", "plist");
        write_stamp(&cfg, &[]);
        assert!(is_up_to_date(&cfg));
        cfg.namespace = "staging".to_string();
        assert!(!is_up_to_date(&cfg));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn test_is_up_to_date__changed_env_file_invalidates() {
        let (cfg, root, _guard) = cache_fixture("envfile", "plist");
        let envf = cfg.project_dir.join("app.env");
        std::fs::write(&envf, "A=1\n").unwrap();
        write_stamp(&cfg, &[envf.clone()]);
        assert!(is_up_to_date(&cfg));

        std::thread::sleep(std::time::Duration::from_millis(1100));
        std::fs::write(&envf, "A=2\n").unwrap();
        assert!(
            !is_up_to_date(&cfg),
            "an edited ENV_FILE must invalidate the launchd build"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn test_is_up_to_date__deleted_env_file_invalidates() {
        let (cfg, root, _guard) = cache_fixture("envgone", "plist");
        let envf = cfg.project_dir.join("app.env");
        std::fs::write(&envf, "A=1\n").unwrap();
        write_stamp(&cfg, &[envf.clone()]);
        assert!(is_up_to_date(&cfg));
        std::fs::remove_file(&envf).unwrap();
        assert!(!is_up_to_date(&cfg));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn test_is_up_to_date__changed_overlay_invalidates() {
        let (mut cfg, root, _guard) = cache_fixture("overlay", "service");
        let ov = cfg.project_dir.join("staging.orch");
        std::fs::write(&ov, "# overlay\n").unwrap();
        cfg.overlays = vec![ov.clone()];
        write_stamp(&cfg, &[]);
        assert!(is_up_to_date(&cfg));
        std::thread::sleep(std::time::Duration::from_millis(1100));
        std::fs::write(&ov, "# changed\n").unwrap();
        assert!(!is_up_to_date(&cfg));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn test_config_hash__includes_orchd_version() {
        let (cfg, root, _guard) = cache_fixture("version", "plist");
        assert_ne!(
            config_hash_for(&cfg, "0.3.4"),
            config_hash_for(&cfg, "0.3.5"),
            "an orchd upgrade must invalidate the generate cache"
        );
        assert_eq!(
            config_hash_for(&cfg, "0.3.4"),
            config_hash_for(&cfg, "0.3.4"),
            "hash must be stable for a fixed version"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn test_env_arg_overrides__reads_prefixed_env() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        unsafe {
            std::env::set_var("ORCH_ARG_prometheus_port", "9999");
            std::env::set_var("ORCH_ARG_", "ignored-no-name");
            std::env::set_var("NOT_ORCH_ARG_x", "no");
        }
        let got = env_arg_overrides();
        unsafe {
            std::env::remove_var("ORCH_ARG_prometheus_port");
            std::env::remove_var("ORCH_ARG_");
            std::env::remove_var("NOT_ORCH_ARG_x");
        }
        assert_eq!(got.get("prometheus_port").map(String::as_str), Some("9999"));
        assert!(!got.contains_key(""), "empty ARG name must be skipped");
        assert!(!got.contains_key("NOT_ORCH_ARG_x"));
    }

    #[test]
    fn test_parse_orchfile__orch_arg_env_overrides_default() {
        let root = std::env::temp_dir().join("orchd-orcharg-env");
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(
            root.join("Orchfile"),
            "ARG port=8000\nSERVICE web\nRUN ./s ${port}\n",
        )
        .unwrap();

        let mut cfg = Config {
            orchfile: root.join("Orchfile"),
            overlays: vec![],
            runtime: "bare".to_string(),
            platform: "systemd".to_string(),
            scope: crate::config::Scope::User,
            state_dir: root.join(".orch"),
            project_dir: root.clone(),
            data_dir: root.join(".orch/data"),
            namespace: "orch".to_string(),
            args: vec![],
            verbose: false,
            quiet: true,
        };
        cfg.quiet = true;
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());

        let parsed = parse_orchfile(&cfg).unwrap();
        assert_eq!(parsed.args.get("port").map(String::as_str), Some("8000"));

        unsafe { std::env::set_var("ORCH_ARG_port", "9001") };
        let parsed = parse_orchfile(&cfg).unwrap();
        assert_eq!(
            parsed.args.get("port").map(String::as_str),
            Some("9001"),
            "ORCH_ARG_* env must override the Orchfile default"
        );

        cfg.args.push("port=7000".to_string());
        let parsed = parse_orchfile(&cfg).unwrap();
        assert_eq!(
            parsed.args.get("port").map(String::as_str),
            Some("7000"),
            "--arg must win over ORCH_ARG_*"
        );
        unsafe { std::env::remove_var("ORCH_ARG_port") };

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn test_clean__scopes_to_namespace_prefix() {
        use crate::platform::Platform;
        use crate::platform::launchd::LaunchdPlatform;

        let root = std::env::temp_dir().join("orchd-clean-ns");
        let _ = std::fs::remove_dir_all(&root);
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let prev_home = std::env::var_os("HOME");
        unsafe { std::env::set_var("HOME", &root) };

        let units = root.join(".orch/units");
        std::fs::create_dir_all(&units).unwrap();
        let agents = root.join("Library/LaunchAgents");
        std::fs::create_dir_all(&agents).unwrap();
        std::fs::write(units.join("orch.web.plist"), "mine").unwrap();
        std::fs::write(units.join("staging.api.plist"), "theirs").unwrap();
        std::fs::write(units.join("notes.txt"), "unrelated").unwrap();
        std::fs::write(agents.join("orch.web.plist"), "mine").unwrap();
        std::fs::write(agents.join("staging.api.plist"), "theirs").unwrap();

        let cfg = Config {
            orchfile: root.join("Orchfile"),
            overlays: vec![],
            runtime: "bare".to_string(),
            platform: "launchd".to_string(),
            scope: crate::config::Scope::User,
            state_dir: root.join(".orch"),
            project_dir: root.clone(),
            data_dir: root.join(".orch/data"),
            namespace: "orch".to_string(),
            args: vec![],
            verbose: false,
            quiet: true,
        };

        LaunchdPlatform::new().clean(&cfg).unwrap();

        assert!(
            !agents.join("orch.web.plist").exists(),
            "own namespace should be unlinked from LaunchAgents"
        );
        assert!(
            agents.join("staging.api.plist").exists(),
            "a sibling namespace must survive fell"
        );
        assert!(
            units.join("notes.txt").exists(),
            "unrelated files must survive fell"
        );
        assert!(units.exists(), "units_dir itself must survive");

        match prev_home {
            Some(h) => unsafe { std::env::set_var("HOME", h) },
            None => unsafe { std::env::remove_var("HOME") },
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn test_clean__systemd_target_is_scoped_too() {
        use crate::platform::Platform;
        use crate::platform::systemd::SystemdPlatform;

        let root = std::env::temp_dir().join("orchd-clean-ns-systemd");
        let _ = std::fs::remove_dir_all(&root);
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let prev_xdg = std::env::var_os("XDG_CONFIG_HOME");
        unsafe { std::env::set_var("XDG_CONFIG_HOME", &root.join("xdg")) };

        let units = root.join(".orch/units");
        std::fs::create_dir_all(&units).unwrap();
        let sysd = root.join("xdg/systemd/user");
        std::fs::create_dir_all(&sysd).unwrap();
        for n in [
            "orch-web.service",
            "orch.target",
            "staging-web.service",
            "staging.target",
        ] {
            std::fs::write(units.join(n), "x").unwrap();
        }
        for n in [
            "orch-web.service",
            "orch.target",
            "staging-web.service",
            "staging.target",
        ] {
            std::fs::write(sysd.join(n), "installed").unwrap();
        }

        let cfg = Config {
            orchfile: root.join("Orchfile"),
            overlays: vec![],
            runtime: "bare".to_string(),
            platform: "systemd".to_string(),
            scope: crate::config::Scope::User,
            state_dir: root.join(".orch"),
            project_dir: root.clone(),
            data_dir: root.join(".orch/data"),
            namespace: "orch".to_string(),
            args: vec![],
            verbose: false,
            quiet: true,
        };

        SystemdPlatform::new().clean(&cfg).unwrap();

        assert!(
            !sysd.join("orch-web.service").exists(),
            "own unit should be unlinked"
        );
        assert!(
            !sysd.join("orch.target").exists(),
            "the grove target must be removed with its namespace"
        );
        assert!(
            sysd.join("staging-web.service").exists(),
            "a sibling namespace's unit must survive"
        );
        assert!(sysd.join("staging.target").exists());

        match prev_xdg {
            Some(h) => unsafe { std::env::set_var("XDG_CONFIG_HOME", h) },
            None => unsafe { std::env::remove_var("XDG_CONFIG_HOME") },
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn test_parse_orchfile__orchfile_can_override_builtin_args() {
        let root = std::env::temp_dir().join("orchd-builtin-args");
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(
            root.join("Orchfile"),
            "ARG ORCH_DATA=/my/data\nSERVICE web\nRUN ./s ${ORCH_DATA}\n",
        )
        .unwrap();

        let cfg = Config {
            orchfile: root.join("Orchfile"),
            overlays: vec![],
            runtime: "bare".to_string(),
            platform: "systemd".to_string(),
            scope: crate::config::Scope::User,
            state_dir: root.join(".orch"),
            project_dir: root.clone(),
            data_dir: root.join(".orch/data"),
            namespace: "orch".to_string(),
            args: vec![],
            verbose: false,
            quiet: true,
        };

        let parsed = parse_orchfile(&cfg).unwrap();
        assert_eq!(
            parsed.args.get("ORCH_DATA").map(String::as_str),
            Some("/my/data"),
            "Orchfile ARG must win over the built-in default"
        );
        assert_eq!(
            parsed.args.get("ORCH_PROJECT").map(String::as_str),
            Some(root.to_str().unwrap())
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn test_unsupported_directives__launchd_reports_what_it_cannot_map() {
        let mut svc = simple_service();
        svc.resources.memory = Some("1G".into());
        svc.resources.cpus = Some(2.0);
        svc.resources.cpu_quota = Some("150%".into());
        svc.resources.tasks_max = Some(100u64);
        svc.resources.io_weight = Some(500u32);
        svc.timeouts.start = Some("30s".into());
        svc.restart.start_limit_burst = Some(3);
        svc.restart.start_limit_interval = Some("60s".into());

        let got = unsupported_directives("launchd", &svc);
        assert_eq!(
            got,
            vec![
                "MEMORY",
                "CPUS",
                "CPU_QUOTA",
                "TASKS_MAX",
                "IO_WEIGHT",
                "TIMEOUT_START",
                "START_LIMIT_BURST",
                "START_LIMIT_INTERVAL"
            ]
        );
        assert!(unsupported_directives("systemd", &svc).is_empty());
    }

    #[test]
    fn test_unsupported_directives__limits_launchd_does_map_are_not_listed() {
        let mut svc = simple_service();
        svc.resources.limit_nofile = Some(1024u64);
        svc.resources.limit_nproc = Some(64u64);
        assert!(unsupported_directives("launchd", &svc).is_empty());
    }

    #[test]
    fn test_unsupported_directives__clean_service_reports_nothing() {
        let svc = simple_service();
        assert!(unsupported_directives("launchd", &svc).is_empty());
    }

    fn simple_service() -> crate::types::Service {
        use crate::types::*;
        Service {
            name: "app".into(),
            mode: ServiceMode::Host,
            image: None,
            run_command: Some("./run".into()),
            entrypoint: None,
            cmd: None,
            publish: Vec::new(),
            volumes: Vec::new(),
            user: None,
            stop_command: None,
            reload_command: None,
            workdir: None,
            env: std::collections::HashMap::new(),
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

    // --- EngineError Display ---

    #[test]
    fn test_engine_error_display__orch_parse() {
        let err = EngineError::OrchParse("file not found".to_string());
        assert_eq!(format!("{}", err), "orch parse failed: file not found");
    }

    #[test]
    fn test_engine_error_display__runtime_wraps_inner() {
        let inner = crate::runtime::RuntimeError::Other("boom".to_string());
        let err = EngineError::Runtime(inner);
        assert_eq!(format!("{}", err), "runtime error: boom");
    }

    #[test]
    fn test_engine_error_display__platform_wraps_inner() {
        let inner = crate::platform::PlatformError::LifecycleFailed("start failed".to_string());
        let err = EngineError::Platform(inner);
        assert_eq!(
            format!("{}", err),
            "platform error: lifecycle failed: start failed"
        );
    }

    // --- From conversions ---

    #[test]
    fn test_engine_error_from_runtime_error() {
        let inner = crate::runtime::RuntimeError::UnsupportedMode {
            service: "web".to_string(),
            mode: "container".to_string(),
        };
        let err: EngineError = inner.into();
        assert!(matches!(err, EngineError::Runtime(_)));
    }

    #[test]
    fn test_engine_error_from_platform_error() {
        let inner = crate::platform::PlatformError::InstallFailed("symlink error".to_string());
        let err: EngineError = inner.into();
        assert!(matches!(err, EngineError::Platform(_)));
    }

    // --- vars_overlay_content ---

    #[test]
    fn test_vars_overlay_content__has_arg_declarations() {
        let cli = crate::cli::Cli {
            command: crate::cli::Commands::Survey { json: false },
            orchfile: None,
            overlay: vec![],
            runtime: None,
            platform: None,
            state_dir: Some(std::path::PathBuf::from("/tmp/orchd-test-state")),
            project_dir: Some(std::path::PathBuf::from("/srv/project")),
            data_dir: Some(std::path::PathBuf::from("/srv/data")),
            namespace: None,
            user: false,
            system: false,
            args: vec![],
            verbose: false,
            quiet: false,
        };
        let config = Config::load(&cli);

        let content = vars_overlay_content(&config);
        assert!(content.contains("ARG ORCH_DATA=/srv/data"));
        assert!(content.contains("ARG ORCH_PROJECT=/srv/project"));
        assert!(content.contains("ARG ORCH_STATE_DIR="));
        assert!(content.contains("ARG ORCH_CONTAINERS_DIR="));
    }

    // --- Integration: orch parse → bare runtime → systemd generate ---

    /// Full pipeline integration test: parse fixture Orchfile via real `orch` binary,
    /// run through bare runtime + systemd generator, assert unit file contents.
    ///
    /// Requires: `orch` binary in PATH, systemd available.
    /// Run with: `cargo test -- --ignored`
    #[test]
    #[ignore]
    fn test_integration__full_generate_pipeline() {
        use std::path::PathBuf;

        let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/Orchfile");
        assert!(
            fixture.exists(),
            "fixture Orchfile not found at {:?}",
            fixture
        );

        let tmp = std::env::temp_dir().join("orchd-integ-test");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();

        let state_dir = tmp.join("state");
        let data_dir = tmp.join("data");

        let cli = crate::cli::Cli {
            command: crate::cli::Commands::Survey { json: false },
            orchfile: Some(fixture),
            overlay: vec![],
            runtime: Some("bare".to_string()),
            platform: Some("systemd".to_string()),
            state_dir: Some(state_dir.clone()),
            project_dir: Some(tmp.clone()),
            data_dir: Some(data_dir.clone()),
            namespace: Some("integ".to_string()),
            user: false,
            system: false,
            args: vec![],
            verbose: false,
            quiet: true,
        };
        let config = Config::load(&cli);

        // Step 1: in-process parse should succeed and return the OrchFile
        let orchfile: crate::types::OrchFile =
            parse_orchfile(&config).expect("orch parse should succeed on fixture Orchfile");

        assert_eq!(orchfile.services.len(), 3);

        // Verify services parsed correctly
        let postgres = &orchfile.services[0];
        assert_eq!(postgres.name, "postgres");
        assert!(postgres.is_host());
        assert!(!postgres.disabled);
        assert!(
            postgres
                .run_command
                .as_deref()
                .unwrap()
                .contains("pg_ctlcluster")
        );
        assert!(postgres.stop_command.is_some());
        assert_eq!(postgres.user.as_deref(), Some("postgres"));

        let redis = &orchfile.services[1];
        assert_eq!(redis.name, "redis");
        assert!(redis.after.contains(&"postgres".to_string()));

        let disabled = &orchfile.services[2];
        assert_eq!(disabled.name, "disabled-svc");
        assert!(disabled.disabled);

        // Step 2: bare runtime should produce ExecSets for enabled services
        let rt =
            crate::runtime::create_runtime("bare", &config).expect("bare runtime should create");
        rt.check().expect("bare runtime check should pass");

        let mut exec_sets = Vec::new();
        for (idx, svc) in orchfile.services.iter().enumerate() {
            if svc.disabled {
                continue;
            }
            rt.prepare(svc)
                .expect(&format!("prepare {} should succeed", svc.name));
            let es = rt
                .exec_set(svc)
                .expect(&format!("exec_set {} should succeed", svc.name));
            assert!(
                !es.start.is_empty(),
                "{} start command should not be empty",
                svc.name
            );
            exec_sets.push((idx, es));
        }
        assert_eq!(exec_sets.len(), 2, "should have 2 enabled services");

        // Step 3: systemd generator should produce unit files
        let platform = crate::platform::systemd::SystemdPlatform::new();
        platform
            .check()
            .expect("systemd platform check should pass");

        let generated = platform
            .generate_all(&orchfile.services, &exec_sets, &config)
            .expect("generate_all should succeed");

        // Should generate: 2 service units + ready gates + target
        assert!(
            generated.len() >= 3,
            "should generate at least 3 files, got {}",
            generated.len()
        );

        // Verify postgres unit file content
        let pg_unit_path = config.units_dir().join("integ-postgres.service");
        assert!(pg_unit_path.exists(), "postgres unit file should exist");
        let pg_content = std::fs::read_to_string(&pg_unit_path).unwrap();
        assert!(pg_content.contains("[Unit]"));
        assert!(pg_content.contains("[Service]"));
        assert!(pg_content.contains("ExecStart="));
        assert!(pg_content.contains("pg_ctlcluster"));
        assert!(pg_content.contains("User=postgres"));
        assert!(pg_content.contains("ExecStop="));

        // Verify redis unit depends on postgres
        let redis_unit_path = config.units_dir().join("integ-redis.service");
        assert!(redis_unit_path.exists(), "redis unit file should exist");
        let redis_content = std::fs::read_to_string(&redis_unit_path).unwrap();
        assert!(
            redis_content.contains("After="),
            "redis should have After= dependency"
        );

        // Verify target file exists
        let target_path = config.units_dir().join("integ.target");
        assert!(target_path.exists(), "target file should exist");

        // Services reference the target via WantedBy (reverse dependency)
        assert!(
            pg_content.contains("WantedBy=integ.target"),
            "postgres unit should reference integ.target via WantedBy"
        );
        assert!(
            redis_content.contains("WantedBy=integ.target"),
            "redis unit should reference integ.target via WantedBy"
        );

        // disabled-svc should NOT have a unit file generated
        let disabled_unit_path = config.units_dir().join("integ-disabled-svc.service");
        assert!(
            !disabled_unit_path.exists(),
            "disabled service should not have a unit file"
        );

        // Cleanup
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
