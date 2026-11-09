pub mod apple;
pub mod external;

use crate::config::Config;
use crate::exec::ExecSet;
use crate::types::Service;

/// Errors from rootstock operations.
#[derive(Debug, thiserror::Error)]
pub enum RootstockError {
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
        "apple" => Ok(Box::new(apple::AppleRootstock::new(config))),
        _ => {
            let exe_dir = std::env::current_exe()
                .ok()
                .and_then(|p| p.parent().map(std::path::Path::to_path_buf));
            let path_var = std::env::var("PATH").unwrap_or_default();
            let bin =
                external::find_plugin(name, exe_dir.as_deref(), &path_var).ok_or_else(|| {
                    RootstockError::BinaryNotFound(format!(
                        "{} beside orchd or on PATH (built in: apple)",
                        external::plugin_name(name)
                    ))
                })?;
            Ok(Box::new(external::ExternalRootstock::new(
                name, bin, config,
            )))
        }
    }
}
