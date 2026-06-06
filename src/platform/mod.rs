pub mod launchd;
pub mod orchdi;
pub mod systemd;

use crate::config::Config;

/// Errors from platform operations.
#[derive(Debug, thiserror::Error)]
pub enum PlatformError {
    /// Platform prerequisites not met.
    #[error("prerequisite missing: {0}")]
    PrerequisiteMissing(String),
    /// Failed to generate artifacts.
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
}

/// A platform knows how to install and manage services on a specific init system.
///
/// Platforms consume ExecSets (from runtimes) and produce native artifacts
/// (systemd units, launchd plists, etc.).
pub trait Platform {
    /// Check that the platform is available on this system.
    fn check(&self) -> Result<(), PlatformError>;

    /// Install generated artifacts (symlink to system dirs, daemon-reload, etc.).
    fn install(&self, config: &Config) -> Result<(), PlatformError>;

    /// Remove all generated artifacts and unlink from system dirs.
    fn clean(&self, config: &Config) -> Result<(), PlatformError>;
}
