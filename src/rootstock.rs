pub mod apple;
pub mod bare;
pub mod external;

use crate::config::Config;
use crate::exec::ExecSet;
use crate::types::Service;

/// Errors from rootstock operations.
#[derive(Debug, thiserror::Error)]
pub enum RootstockError {
    /// A container-mode service was passed to a host-only rootstock.
    #[error("service '{service}' has mode '{mode}' which is not supported by this rootstock")]
    UnsupportedMode { service: String, mode: String },
    /// A required binary or tool is not found.
    #[error("binary not found: {0}")]
    BinaryNotFound(String),
    /// General error.
    #[error("{0}")]
    Other(String),
}

/// A rootstock knows how to prepare and produce execution commands for services.
///
/// Rootstocks are stateless -- they inspect the system and produce ExecSets.
/// They do NOT start/stop services (that's the platform's job).
pub trait Rootstock {
    /// Human-readable name for this rootstock (e.g., "bare", "apple").
    fn name(&self) -> &str;

    /// Check that the rootstock's prerequisites are met on this system.
    /// Called once at startup before any service processing.
    fn check(&self) -> Result<(), RootstockError>;

    /// Prepare infrastructure for a service (e.g., create data directories,
    /// pull container images). Called once per service before exec_set().
    fn prepare(&self, service: &Service) -> Result<(), RootstockError>;

    /// Produce the ExecSet for a service. The platform will consume this
    /// to generate its native artifacts (systemd units, launchd plists, etc.).
    fn exec_set(&self, service: &Service) -> Result<ExecSet, RootstockError>;
}

/// Create a rootstock by name, using the given config for rootstock-specific settings.
pub fn create_rootstock(name: &str, config: &Config) -> Result<Box<dyn Rootstock>, RootstockError> {
    match name {
        "bare" => Ok(Box::new(bare::BareRootstock::new(config.data_dir.clone()))),
        "apple" => Ok(Box::new(apple::AppleRootstock::new(config))),
        _ => {
            let path_var = std::env::var("PATH").unwrap_or_default();
            let bin = external::find_on_path(name, &path_var).ok_or_else(|| {
                RootstockError::BinaryNotFound(format!(
                    "{} on PATH (built in: bare, apple)",
                    external::plugin_name(name)
                ))
            })?;
            Ok(Box::new(external::ExternalRootstock::new(
                name, bin, config,
            )))
        }
    }
}
