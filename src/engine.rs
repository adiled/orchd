use std::process::Command;

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
    #[error("JSON deserialization failed: {0}")]
    JsonDeserialize(String),
    #[error("runtime error: {0}")]
    Runtime(#[from] crate::runtime::RuntimeError),
    #[error("platform error: {0}")]
    Platform(#[from] crate::platform::PlatformError),
}

/// Run the full generate pipeline:
/// 1. Check mtime (skip if up-to-date unless `force`)
/// 2. Call `orch parse` to get JSON
/// 3. Deserialize into OrchFile
/// 4. Create runtime, check prerequisites
/// 5. For each enabled service: runtime.prepare() + runtime.exec_set()
/// 6. Platform generate_all() + install()
pub fn generate(config: &Config, force: bool) -> Result<(), EngineError> {
    // 1. Skip if artifacts are newer than Orchfile (unless --force)
    if !force && is_up_to_date(config) {
        if !config.quiet {
            eprintln!("artifacts up to date, skipping generate (use --force to override)");
        }
        return Ok(());
    }

    // 2. Call orch parse
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
    let generated = match config.platform.as_str() {
        "launchd" => {
            let platform = LaunchdPlatform::new();
            platform.check()?;
            let g = platform.generate_all(&orchfile.services, &exec_sets, config)?;
            if !config.quiet {
                for path in &g { eprintln!("  wrote: {}", path); }
            }
            platform.install(config)?;
            g
        }
        _ => {
            let platform = SystemdPlatform::new();
            platform.check()?;
            let g = platform.generate_all(&orchfile.services, &exec_sets, config)?;
            if !config.quiet {
                for path in &g { eprintln!("  wrote: {}", path); }
            }
            platform.install(config)?;
            g
        }
    };

    if !config.quiet {
        eprintln!("installed {} units", generated.len());
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
        generate(config, false)?;
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
pub fn grow(config: &Config, services: &[String], no_start: bool) -> Result<(), EngineError> {
    if no_start {
        generate(config, false)
    } else {
        up(config, services, false)
    }
}

/// Show status of managed services.
pub fn status(config: &Config, as_json: bool) -> Result<(), EngineError> {
    match config.platform.as_str() {
        "launchd" => crate::platform::launchd::lifecycle::status(config, as_json)?,
        _ => crate::platform::systemd::lifecycle::status(config, as_json)?,
    }
    Ok(())
}

/// Tail logs for a service.
pub fn logs(config: &Config, service: &str, follow: bool, lines: u32) -> Result<(), EngineError> {
    match config.platform.as_str() {
        "launchd" => crate::platform::launchd::lifecycle::logs(service, follow, lines, config)?,
        _ => crate::platform::systemd::lifecycle::logs(service, follow, lines, config)?,
    }
    Ok(())
}

/// Remove all generated artifacts and stop services.
pub fn clean(config: &Config, keep_data: bool) -> Result<(), EngineError> {
    // Stop all services first (ignore errors — they might not be running)
    match config.platform.as_str() {
        "launchd" => { let _ = crate::platform::launchd::lifecycle::stop(&[], config); }
        _ => { let _ = crate::platform::systemd::lifecycle::stop(&[], config); }
    }

    // Platform clean (remove units, unlink, daemon-reload)
    match config.platform.as_str() {
        "launchd" => {
            let platform = crate::platform::launchd::LaunchdPlatform::new();
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

/// Check if generated artifacts are newer than all input files (Orchfile + overlays).
/// Returns true if no regeneration is needed.
fn is_up_to_date(config: &Config) -> bool {
    let units_dir = config.units_dir();
    if !units_dir.exists() {
        return false;
    }

    // Find the newest input mtime (Orchfile + overlays)
    let mut newest_input = match std::fs::metadata(&config.orchfile) {
        Ok(m) => match m.modified() {
            Ok(t) => t,
            Err(_) => return false,
        },
        Err(_) => return false,
    };

    for overlay in &config.overlays {
        if let Ok(m) = std::fs::metadata(overlay) {
            if let Ok(t) = m.modified() {
                if t > newest_input {
                    newest_input = t;
                }
            }
        }
    }

    // Find the oldest generated unit file mtime
    let entries = match std::fs::read_dir(&units_dir) {
        Ok(e) => e,
        Err(_) => return false,
    };

    let mut has_units = false;
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) == Some("service")
            || path.extension().and_then(|e| e.to_str()) == Some("target")
        {
            has_units = true;
            match std::fs::metadata(&path) {
                Ok(m) => match m.modified() {
                    Ok(t) => {
                        if t < newest_input {
                            // At least one unit is older than input
                            return false;
                        }
                    }
                    Err(_) => return false,
                },
                Err(_) => return false,
            }
        }
    }

    // If no units found, not up to date
    has_units
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
            command: crate::cli::Commands::Survey { json: false },
            orchfile: None,
            overlay: vec![],
            runtime: None,
            platform: None,
            state_dir: Some(tmp.clone()),
            project_dir: Some(std::path::PathBuf::from("/srv/project")),
            data_dir: Some(std::path::PathBuf::from("/srv/data")),
            orch_bin: None,
            namespace: None,
            user: false,
            system: false,
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
            command: crate::cli::Commands::Survey { json: false },
            orchfile: Some(fixture),
            overlay: vec![],
            runtime: Some("bare".to_string()),
            platform: Some("systemd".to_string()),
            state_dir: Some(state_dir.clone()),
            project_dir: Some(tmp.clone()),
            data_dir: Some(data_dir.clone()),
            orch_bin: None, // defaults to "orch" in PATH
            namespace: Some("integ".to_string()),
            user: false,
            system: false,
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
