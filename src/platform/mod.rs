pub mod systemd;

use crate::config::Config;
use crate::exec::ExecSet;
use crate::types::Service;
use std::fmt;

/// Errors from platform operations.
#[derive(Debug)]
pub enum PlatformError {
    /// Platform prerequisites not met.
    PrerequisiteMissing(String),
    /// Failed to generate artifacts.
    GenerationFailed(String),
    /// Failed to install artifacts (symlink, reload, etc.).
    InstallFailed(String),
    /// Failed lifecycle operation (start, stop, etc.).
    LifecycleFailed(String),
    /// I/O error.
    Io(std::io::Error),
    /// General error.
    Other(String),
}

impl fmt::Display for PlatformError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PlatformError::PrerequisiteMissing(msg) => write!(f, "prerequisite missing: {}", msg),
            PlatformError::GenerationFailed(msg) => write!(f, "generation failed: {}", msg),
            PlatformError::InstallFailed(msg) => write!(f, "install failed: {}", msg),
            PlatformError::LifecycleFailed(msg) => write!(f, "lifecycle failed: {}", msg),
            PlatformError::Io(err) => write!(f, "I/O error: {}", err),
            PlatformError::Other(msg) => write!(f, "{}", msg),
        }
    }
}

impl std::error::Error for PlatformError {}

impl From<std::io::Error> for PlatformError {
    fn from(err: std::io::Error) -> Self {
        PlatformError::Io(err)
    }
}

/// A platform knows how to install and manage services on a specific init system.
///
/// Platforms consume ExecSets (from runtimes) and produce native artifacts
/// (systemd units, launchd plists, etc.).
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
