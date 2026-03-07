pub mod systemd;

use crate::config::Config;
use crate::exec::ExecSet;
use crate::types::Service;

/// Errors from platform operations.
#[derive(Debug, thiserror::Error)]
pub enum PlatformError {
    /// Platform prerequisites not met.
    #[error("prerequisite missing: {0}")]
    PrerequisiteMissing(String),
    /// Failed to generate artifacts.
    #[allow(dead_code)]
    #[error("generation failed: {0}")]
    GenerationFailed(String),
    /// Failed to install artifacts (symlink, reload, etc.).
    #[error("install failed: {0}")]
    InstallFailed(String),
    /// Failed lifecycle operation (start, stop, etc.).
    #[error("lifecycle failed: {0}")]
    LifecycleFailed(String),
    /// I/O error.
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    /// General error.
    #[allow(dead_code)]
    #[error("{0}")]
    Other(String),
}

/// A platform knows how to install and manage services on a specific init system.
///
/// Platforms consume ExecSets (from runtimes) and produce native artifacts
/// (systemd units, launchd plists, etc.).
#[allow(dead_code)]
pub trait Platform {
    /// Human-readable name (e.g., "systemd", "launchd").
    fn name(&self) -> &str;

    /// Check that the platform is available on this system.
    fn check(&self) -> Result<(), PlatformError>;

    /// Generate native artifacts for a service + its ExecSet.
    /// Returns the list of generated file paths.
    fn generate(
        &self,
        service: &Service,
        exec_set: &ExecSet,
        config: &Config,
    ) -> Result<Vec<String>, PlatformError>;

    /// Generate a group target that encompasses all managed services.
    fn generate_target(
        &self,
        services: &[&Service],
        config: &Config,
    ) -> Result<String, PlatformError>;

    /// Install generated artifacts (symlink to system dirs, daemon-reload, etc.).
    fn install(&self, config: &Config) -> Result<(), PlatformError>;

    /// Remove all generated artifacts and unlink from system dirs.
    fn clean(&self, config: &Config) -> Result<(), PlatformError>;
}
