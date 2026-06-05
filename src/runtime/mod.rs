pub mod apple;
pub mod bare;

use crate::config::Config;
use crate::exec::ExecSet;
use crate::types::Service;

/// Errors from runtime operations.
#[derive(Debug, thiserror::Error)]
pub enum RuntimeError {
    /// A container-mode service was passed to a host-only runtime.
    #[error("service '{service}' has mode '{mode}' which is not supported by this runtime")]
    UnsupportedMode { service: String, mode: String },
    /// The runtime's prerequisites are not met.
    #[allow(dead_code)]
    #[error("prerequisite missing: {0}")]
    PrerequisiteMissing(String),
    /// A required binary or tool is not found.
    #[allow(dead_code)]
    #[error("binary not found: {0}")]
    BinaryNotFound(String),
    /// General error.
    #[error("{0}")]
    Other(String),
}

/// A runtime knows how to prepare and produce execution commands for services.
///
/// Runtimes are stateless -- they inspect the system and produce ExecSets.
/// They do NOT start/stop services (that's the platform's job).
#[allow(dead_code)]
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
        "apple" => Ok(Box::new(apple::AppleRuntime::new(config))),
        _ => Err(RuntimeError::Other(format!(
            "unknown runtime '{}'. Available: bare, apple",
            name
        ))),
    }
}
