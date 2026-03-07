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

/// Call `orch parse <orchfile> [overlays...] [--arg key=value ...]` and return stdout JSON.
fn call_orch_parse(config: &Config) -> Result<String, EngineError> {
    let mut cmd = Command::new(&config.orch_bin);
    cmd.arg("parse");
    cmd.arg(&config.orchfile);

    // Add overlay files
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
