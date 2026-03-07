pub mod bare;

use crate::config::Config;
use crate::exec::ExecSet;
use crate::types::Service;
use std::fmt;

/// Errors from runtime operations.
#[derive(Debug)]
pub enum RuntimeError {
    /// A container-mode service was passed to a host-only runtime.
    UnsupportedMode { service: String, mode: String },
    /// The runtime's prerequisites are not met.
    PrerequisiteMissing(String),
    /// A required binary or tool is not found.
    BinaryNotFound(String),
    /// General error.
    Other(String),
}

impl fmt::Display for RuntimeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RuntimeError::UnsupportedMode { service, mode } => {
                write!(f, "service '{}' has mode '{}' which is not supported by this runtime", service, mode)
            }
            RuntimeError::PrerequisiteMissing(msg) => write!(f, "prerequisite missing: {}", msg),
            RuntimeError::BinaryNotFound(bin) => write!(f, "binary not found: {}", bin),
            RuntimeError::Other(msg) => write!(f, "{}", msg),
        }
    }
}

impl std::error::Error for RuntimeError {}

/// A runtime knows how to prepare and produce execution commands for services.
///
/// Runtimes are stateless -- they inspect the system and produce ExecSets.
/// They do NOT start/stop services (that's the platform's job).
pub trait Runtime {
    /// Human-readable name for this runtime (e.g., "bare", "containerd").
    fn name(&self) -> &str;

    /// Check that the runtime's prerequisites are met on this system.
    /// Called once at startup before any service processing.
    fn check(&self) -> Result<(), RuntimeError>;

    /// Prepare infrastructure for a service (e.g., create data directories,
    /// pull container images). Called once per service before exec_set().
    fn prepare(&self, service: &Service) -> Result<(), RuntimeError>;

    /// Produce the ExecSet for a service. The platform will consume this
    /// to generate its native artifacts (systemd units, launchd plists, etc.).
    fn exec_set(&self, service: &Service) -> Result<ExecSet, RuntimeError>;

    /// Clean up runtime-specific artifacts for a service.
    /// Called during `orchd clean`.
    fn cleanup(&self, service: &Service) -> Result<(), RuntimeError>;
}

/// Create a runtime by name, using the given config for runtime-specific settings.
pub fn create_runtime(name: &str, config: &Config) -> Result<Box<dyn Runtime>, RuntimeError> {
    match name {
        "bare" => Ok(Box::new(bare::BareRuntime::new(config.data_dir.clone()))),
        _ => Err(RuntimeError::Other(format!(
            "unknown runtime '{}'. Available: bare",
            name
        ))),
    }
}
