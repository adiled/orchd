use std::process::Command;

use crate::config::Config;
use crate::exec::ExecSet;
use crate::platform::Platform;
use crate::platform::systemd::SystemdPlatform;
use crate::runtime;
use crate::types::OrchFile;

/// Errors from the engine pipeline.
#[derive(Debug, thiserror::Error)]
pub enum EngineError {
    #[error("orch parse failed: {0}")]
    OrchParse(String),
    #[error("JSON deserialization failed: {0}")]
    JsonDeserialize(String),
    #[error("runtime error: {0}")]
    Runtime(#[from] crate::runtime::RuntimeError),
    #[error("platform error: {0}")]
    Platform(#[from] crate::platform::PlatformError),
}

/// Run the full generate pipeline:
/// 1. Call `orch parse` to get JSON
/// 2. Deserialize into OrchFile
/// 3. Create runtime, check prerequisites
/// 4. For each enabled service: runtime.prepare() + runtime.exec_set()
/// 5. Platform generate_all() + install()
pub fn generate(config: &Config) -> Result<(), EngineError> {
    // 1. Call orch parse
    let json = call_orch_parse(config)?;

    // 2. Deserialize
    let orchfile: OrchFile = serde_json::from_str(&json)
        .map_err(|e| EngineError::JsonDeserialize(format!("{}", e)))?;

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
        // Warn but continue — container services without overlays are expected
        // to fail in bare runtime. The user can add overlays or disable them.
        eprintln!(
            "warning: {} service(s) skipped (runtime incompatible):\n  {}",
            errors.len(),
            errors.join("\n  ")
        );
    }

    if !config.quiet {
        eprintln!(
            "generating {} units ({} disabled)",
            exec_sets.len(),
            skipped
        );
    }

    // 5. Platform generate + install
    let platform = SystemdPlatform::new();
    platform.check()?;

    let generated = platform.generate_all(&orchfile.services, &exec_sets, config)?;

    if !config.quiet {
        for path in &generated {
            eprintln!("  wrote: {}", path);
        }
    }

    // Install (symlink + daemon-reload)
    platform.install(config)?;

    if !config.quiet {
        eprintln!("installed {} units, daemon-reload done", generated.len());
    }

    Ok(())
}

/// Generate and start services.
/// If `no_generate` is false, runs generate first.
pub fn up(
    config: &Config,
    services: &[String],
    no_generate: bool,
) -> Result<(), EngineError> {
    if !no_generate {
        generate(config)?;
    }

    if !config.quiet {
        if services.is_empty() {
            eprintln!("starting all services...");
        } else {
            eprintln!("starting: {}", services.join(", "));
        }
    }

    crate::platform::systemd::lifecycle::start(services, config)?;

    if !config.quiet {
        eprintln!("started");
    }

    Ok(())
}

/// Stop services.
pub fn down(config: &Config, services: &[String]) -> Result<(), EngineError> {
    if !config.quiet {
        if services.is_empty() {
            eprintln!("stopping all services...");
        } else {
            eprintln!("stopping: {}", services.join(", "));
        }
    }

    crate::platform::systemd::lifecycle::stop(services, config)?;

    if !config.quiet {
        eprintln!("stopped");
    }

    Ok(())
}

/// Restart services.
pub fn restart(config: &Config, services: &[String]) -> Result<(), EngineError> {
    if !config.quiet {
        if services.is_empty() {
            eprintln!("restarting all services...");
        } else {
            eprintln!("restarting: {}", services.join(", "));
        }
    }

    crate::platform::systemd::lifecycle::restart(services, config)?;

    if !config.quiet {
        eprintln!("restarted");
    }

    Ok(())
}

/// Show status of managed services.
pub fn status(config: &Config, as_json: bool) -> Result<(), EngineError> {
    crate::platform::systemd::lifecycle::status(config, as_json)?;
    Ok(())
}

/// Tail logs for a service.
pub fn logs(config: &Config, service: &str, follow: bool, lines: u32) -> Result<(), EngineError> {
    crate::platform::systemd::lifecycle::logs(service, follow, lines, config)?;
    Ok(())
}

/// List all services from Orchfile.
pub fn list(
    config: &Config,
    only_enabled: bool,
    only_disabled: bool,
    as_json: bool,
) -> Result<(), EngineError> {
    let orchfile = parse_orchfile(config)?;

    let services: Vec<&crate::types::Service> = orchfile
        .services
        .iter()
        .filter(|s| {
            if only_enabled {
                !s.disabled
            } else if only_disabled {
                s.disabled
            } else {
                true
            }
        })
        .collect();

    if as_json {
        print!("[");
        for (i, s) in services.iter().enumerate() {
            if i > 0 {
                print!(",");
            }
            let mode = if s.is_host() { "host" } else { "container" };
            let hc = s.healthcheck.as_deref().unwrap_or("");
            print!(
                "\n  {{\"name\":\"{}\",\"mode\":\"{}\",\"disabled\":{},\"healthcheck\":{}}}",
                s.name,
                mode,
                s.disabled,
                if hc.is_empty() {
                    "null".to_string()
                } else {
                    format!("\"{}\"", hc)
                }
            );
        }
        println!("\n]");
    } else {
        println!(
            "{:<24} {:<10} {:<10} {}",
            "SERVICE", "MODE", "STATUS", "HEALTHCHECK"
        );
        println!("{}", "-".repeat(72));
        for s in &services {
            let mode = if s.is_host() { "host" } else { "container" };
            let status = if s.disabled { "disabled" } else { "enabled" };
            let hc = s.healthcheck.as_deref().unwrap_or("-");
            println!("{:<24} {:<10} {:<10} {}", s.name, mode, status, hc);
        }
    }

    Ok(())
}

/// Poll healthchecks for enabled services and report pass/fail.
pub fn health(config: &Config, timeout_str: &str, verbose: bool) -> Result<(), EngineError> {
    let orchfile = parse_orchfile(config)?;

    let timeout_secs = parse_duration_secs(timeout_str);
    let start = std::time::Instant::now();

    let services_with_hc: Vec<&crate::types::Service> = orchfile
        .services
        .iter()
        .filter(|s| !s.disabled && s.healthcheck.is_some())
        .collect();

    if services_with_hc.is_empty() {
        if !config.quiet {
            eprintln!("no services with healthchecks found");
        }
        return Ok(());
    }

    if !config.quiet {
        eprintln!(
            "checking health of {} service(s), timeout {}s...",
            services_with_hc.len(),
            timeout_secs
        );
    }

    let mut passed = Vec::new();
    let mut failed = Vec::new();

    for svc in &services_with_hc {
        let hc = svc.healthcheck.as_deref().unwrap();
        let svc_start = std::time::Instant::now();
        let remaining = timeout_secs.saturating_sub(start.elapsed().as_secs());

        if remaining == 0 {
            failed.push((svc.name.as_str(), "timeout (global)"));
            continue;
        }

        if verbose {
            eprintln!("  checking {}: {}", svc.name, hc);
        }

        // Determine if this is an HTTP healthcheck or a command
        let check_cmd = if hc.starts_with("http://") || hc.starts_with("https://") {
            format!("curl -sf '{}' >/dev/null 2>&1", hc)
        } else {
            format!("{} >/dev/null 2>&1", hc)
        };

        let ok = poll_healthcheck(&check_cmd, remaining);

        if ok {
            let elapsed = svc_start.elapsed().as_millis();
            if verbose {
                eprintln!("    pass ({}ms)", elapsed);
            }
            passed.push(svc.name.as_str());
        } else {
            if verbose {
                eprintln!("    FAIL");
            }
            failed.push((svc.name.as_str(), "healthcheck timed out"));
        }
    }

    // Print summary
    println!(
        "{:<24} {}",
        "SERVICE", "HEALTH"
    );
    println!("{}", "-".repeat(40));
    for name in &passed {
        println!("{:<24} pass", name);
    }
    for (name, reason) in &failed {
        println!("{:<24} FAIL ({})", name, reason);
    }

    if !failed.is_empty() {
        return Err(EngineError::Runtime(crate::runtime::RuntimeError::Other(
            format!("{}/{} healthchecks failed", failed.len(), passed.len() + failed.len()),
        )));
    }

    Ok(())
}

/// Remove all generated artifacts and stop services.
pub fn clean(config: &Config, keep_data: bool) -> Result<(), EngineError> {
    // Stop all services first (ignore errors — they might not be running)
    let _ = crate::platform::systemd::lifecycle::stop(&[], config);

    // Platform clean (remove units, unlink, daemon-reload)
    let platform = crate::platform::systemd::SystemdPlatform::new();
    platform.clean(config)?;

    if !config.quiet {
        eprintln!("removed generated units and symlinks");
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

/// Poll a healthcheck command until it succeeds or timeout is reached.
fn poll_healthcheck(cmd: &str, timeout_secs: u64) -> bool {
    let start = std::time::Instant::now();
    loop {
        let result = Command::new("/bin/bash")
            .args(["-c", cmd])
            .output();

        if let Ok(output) = result {
            if output.status.success() {
                return true;
            }
        }

        if start.elapsed().as_secs() >= timeout_secs {
            return false;
        }

        std::thread::sleep(std::time::Duration::from_secs(2));
    }
}

/// Parse a duration string like "60s", "2m", "120" into seconds.
fn parse_duration_secs(s: &str) -> u64 {
    let s = s.trim();
    if let Some(n) = s.strip_suffix('s') {
        n.parse().unwrap_or(60)
    } else if let Some(n) = s.strip_suffix('m') {
        n.parse::<u64>().unwrap_or(1) * 60
    } else {
        s.parse().unwrap_or(60)
    }
}

/// Parse the Orchfile and return the deserialized OrchFile.
/// Used by commands that need service info without generating (list, health).
pub fn parse_orchfile(config: &Config) -> Result<OrchFile, EngineError> {
    let json = call_orch_parse(config)?;
    serde_json::from_str(&json)
        .map_err(|e| EngineError::JsonDeserialize(format!("{}", e)))
}

/// Call `orch parse <orchfile> [overlays...] [--arg key=value ...]` and return stdout JSON.
///
/// Automatically injects a temporary overlay with ARG declarations for orchd's
/// built-in variables (ORCH_DATA, ORCH_PROJECT, etc.) so Orchfiles can reference
/// them without the user having to pass --arg manually.
fn call_orch_parse(config: &Config) -> Result<String, EngineError> {
    // Write temp overlay with built-in variable ARG declarations
    let vars_overlay = write_vars_overlay(config)?;

    let mut cmd = Command::new(&config.orch_bin);
    cmd.arg("parse");
    cmd.arg(&config.orchfile);

    // Inject vars overlay first so user overlays can override
    cmd.arg(&vars_overlay);

    // Add user overlay files
    for overlay in &config.overlays {
        cmd.arg(overlay);
    }

    // Add --arg flags
    for arg in &config.args {
        cmd.arg("--arg");
        cmd.arg(arg);
    }

    if config.verbose {
        eprintln!("exec: {:?}", cmd);
    }

    let output = cmd.output().map_err(|e| {
        EngineError::OrchParse(format!(
            "failed to execute '{}': {}",
            config.orch_bin.display(),
            e
        ))
    })?;

    // Clean up temp file
    let _ = std::fs::remove_file(&vars_overlay);

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(EngineError::OrchParse(format!(
            "exit code {}: {}",
            output.status.code().unwrap_or(-1),
            stderr.trim()
        )));
    }

    String::from_utf8(output.stdout).map_err(|e| {
        EngineError::OrchParse(format!("invalid UTF-8 in orch output: {}", e))
    })
}

/// Write a temporary Orchfile overlay containing ARG declarations for orchd's
/// built-in variables. These variables are referenced in Orchfiles (e.g.
/// `${ORCH_DATA}`) but aren't declared as ARGs — orch leaves them unresolved
/// unless we declare them.
fn write_vars_overlay(config: &Config) -> Result<std::path::PathBuf, EngineError> {
    let dir = config.state_dir.join("tmp");
    std::fs::create_dir_all(&dir).map_err(|e| {
        EngineError::OrchParse(format!("failed to create tmp dir: {}", e))
    })?;

    let path = dir.join("orchd-vars.orch");
    let content = format!(
        "# Auto-generated by orchd — built-in variable declarations\n\
         ARG ORCH_DATA={}\n\
         ARG ORCH_PROJECT={}\n\
         ARG ORCH_STATE_DIR={}\n\
         ARG ORCH_CONTAINERS_DIR={}\n",
        config.data_dir.display(),
        config.project_dir.display(),
        config.state_dir.display(),
        config.project_dir.display(), // ORCH_CONTAINERS_DIR defaults to project_dir
    );

    std::fs::write(&path, content).map_err(|e| {
        EngineError::OrchParse(format!("failed to write vars overlay: {}", e))
    })?;

    Ok(path)
}

#[cfg(test)]
#[allow(non_snake_case)]
mod tests {
    use super::*;

    // --- parse_duration_secs ---

    #[test]
    fn test_parse_duration_secs__seconds_suffix() {
        assert_eq!(parse_duration_secs("30s"), 30);
    }

    #[test]
    fn test_parse_duration_secs__minutes_suffix() {
        assert_eq!(parse_duration_secs("2m"), 120);
    }

    #[test]
    fn test_parse_duration_secs__plain_number() {
        assert_eq!(parse_duration_secs("45"), 45);
    }

    #[test]
    fn test_parse_duration_secs__invalid_falls_back_to_60() {
        assert_eq!(parse_duration_secs("abc"), 60);
    }

    #[test]
    fn test_parse_duration_secs__empty_falls_back_to_60() {
        assert_eq!(parse_duration_secs(""), 60);
    }

    #[test]
    fn test_parse_duration_secs__whitespace_trimmed() {
        assert_eq!(parse_duration_secs("  10s  "), 10);
    }

    // --- EngineError Display ---

    #[test]
    fn test_engine_error_display__orch_parse() {
        let err = EngineError::OrchParse("file not found".to_string());
        assert_eq!(format!("{}", err), "orch parse failed: file not found");
    }

    #[test]
    fn test_engine_error_display__json_deserialize() {
        let err = EngineError::JsonDeserialize("unexpected token".to_string());
        assert_eq!(
            format!("{}", err),
            "JSON deserialization failed: unexpected token"
        );
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

    // --- write_vars_overlay ---

    #[test]
    fn test_write_vars_overlay__creates_file_with_arg_declarations() {
        let tmp = std::env::temp_dir().join("orchd-test-vars-overlay");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();

        let cli = crate::cli::Cli {
            command: crate::cli::Commands::Generate { force: false },
            orchfile: None,
            overlay: vec![],
            runtime: None,
            platform: None,
            state_dir: Some(tmp.clone()),
            project_dir: Some(std::path::PathBuf::from("/srv/project")),
            data_dir: Some(std::path::PathBuf::from("/srv/data")),
            orch_bin: None,
            namespace: None,
            args: vec![],
            verbose: false,
            quiet: false,
        };
        let config = Config::load(&cli);

        let path = write_vars_overlay(&config).unwrap();
        assert!(path.exists());

        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("ARG ORCH_DATA=/srv/data"));
        assert!(content.contains("ARG ORCH_PROJECT=/srv/project"));
        assert!(content.contains("ARG ORCH_STATE_DIR="));
        assert!(content.contains("ARG ORCH_CONTAINERS_DIR="));

        let _ = std::fs::remove_dir_all(&tmp);
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

        let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/Orchfile");
        assert!(fixture.exists(), "fixture Orchfile not found at {:?}", fixture);

        let tmp = std::env::temp_dir().join("orchd-integ-test");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();

        let state_dir = tmp.join("state");
        let data_dir = tmp.join("data");

        let cli = crate::cli::Cli {
            command: crate::cli::Commands::Generate { force: false },
            orchfile: Some(fixture),
            overlay: vec![],
            runtime: Some("bare".to_string()),
            platform: Some("systemd".to_string()),
            state_dir: Some(state_dir.clone()),
            project_dir: Some(tmp.clone()),
            data_dir: Some(data_dir.clone()),
            orch_bin: None, // defaults to "orch" in PATH
            namespace: Some("integ".to_string()),
            args: vec![],
            verbose: false,
            quiet: true,
        };
        let config = Config::load(&cli);

        // Step 1: call_orch_parse should succeed and return valid JSON
        let json = call_orch_parse(&config)
            .expect("orch parse should succeed on fixture Orchfile");

        let orchfile: crate::types::OrchFile = serde_json::from_str(&json)
            .expect("JSON should deserialize into OrchFile");

        assert_eq!(orchfile.version, "0.2.0");
        assert_eq!(orchfile.services.len(), 3);

        // Verify services parsed correctly
        let postgres = &orchfile.services[0];
        assert_eq!(postgres.name, "postgres");
        assert!(postgres.is_host());
        assert!(!postgres.disabled);
        assert!(postgres.run_command.as_deref().unwrap().contains("pg_ctlcluster"));
        assert!(postgres.stop_command.is_some());
        assert_eq!(postgres.user.as_deref(), Some("postgres"));

        let redis = &orchfile.services[1];
        assert_eq!(redis.name, "redis");
        assert!(redis.after.contains(&"postgres".to_string()));

        let disabled = &orchfile.services[2];
        assert_eq!(disabled.name, "disabled-svc");
        assert!(disabled.disabled);

        // Step 2: bare runtime should produce ExecSets for enabled services
        let rt = crate::runtime::create_runtime("bare", &config)
            .expect("bare runtime should create");
        rt.check().expect("bare runtime check should pass");

        let mut exec_sets = Vec::new();
        for (idx, svc) in orchfile.services.iter().enumerate() {
            if svc.disabled {
                continue;
            }
            rt.prepare(svc).expect(&format!("prepare {} should succeed", svc.name));
            let es = rt.exec_set(svc).expect(&format!("exec_set {} should succeed", svc.name));
            assert!(!es.start.is_empty(), "{} start command should not be empty", svc.name);
            exec_sets.push((idx, es));
        }
        assert_eq!(exec_sets.len(), 2, "should have 2 enabled services");

        // Step 3: systemd generator should produce unit files
        let platform = crate::platform::systemd::SystemdPlatform::new();
        platform.check().expect("systemd platform check should pass");

        let generated = platform.generate_all(&orchfile.services, &exec_sets, &config)
            .expect("generate_all should succeed");

        // Should generate: 2 service units + ready gates + target
        assert!(generated.len() >= 3, "should generate at least 3 files, got {}", generated.len());

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
        assert!(redis_content.contains("After="), "redis should have After= dependency");

        // Verify target file exists
        let target_path = config.units_dir().join("integ.target");
        assert!(target_path.exists(), "target file should exist");

        // Services reference the target via WantedBy (reverse dependency)
        assert!(pg_content.contains("WantedBy=integ.target"),
            "postgres unit should reference integ.target via WantedBy");
        assert!(redis_content.contains("WantedBy=integ.target"),
            "redis unit should reference integ.target via WantedBy");

        // disabled-svc should NOT have a unit file generated
        let disabled_unit_path = config.units_dir().join("integ-disabled-svc.service");
        assert!(!disabled_unit_path.exists(), "disabled service should not have a unit file");

        // Cleanup
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
