use std::process::Command;

use crate::config::Config;
use crate::exec::ExecSet;
use crate::platform::Platform;
use crate::platform::systemd::SystemdPlatform;
use crate::runtime;
use crate::types::OrchFile;

/// Errors from the engine pipeline.
#[derive(Debug)]
pub enum EngineError {
    OrchParse(String),
    JsonDeserialize(String),
    Runtime(crate::runtime::RuntimeError),
    Platform(crate::platform::PlatformError),
}

impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EngineError::OrchParse(msg) => write!(f, "orch parse failed: {}", msg),
            EngineError::JsonDeserialize(msg) => write!(f, "JSON deserialization failed: {}", msg),
            EngineError::Runtime(err) => write!(f, "runtime error: {}", err),
            EngineError::Platform(err) => write!(f, "platform error: {}", err),
        }
    }
}

impl std::error::Error for EngineError {}

impl From<crate::runtime::RuntimeError> for EngineError {
    fn from(err: crate::runtime::RuntimeError) -> Self {
        EngineError::Runtime(err)
    }
}

impl From<crate::platform::PlatformError> for EngineError {
    fn from(err: crate::platform::PlatformError) -> Self {
        EngineError::Platform(err)
    }
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
