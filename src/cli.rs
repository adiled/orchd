use clap::{Parser, Subcommand};
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "orchd", version, about = "Orch execution engine")]
pub struct Cli {
    #[command(subcommand)]
    pub command: Commands,

    /// Path to Orchfile (default: ./Orchfile)
    #[arg(long)]
    pub orchfile: Option<PathBuf>,

    /// Overlay file (repeatable)
    #[arg(long, action = clap::ArgAction::Append)]
    pub overlay: Vec<PathBuf>,

    /// Runtime: bare, containerd, podman, apple
    #[arg(long)]
    pub runtime: Option<String>,

    /// Platform: systemd, launchd
    #[arg(long)]
    pub platform: Option<String>,

    /// State directory (default: ~/.orch)
    #[arg(long)]
    pub state_dir: Option<PathBuf>,

    /// Project root directory
    #[arg(long)]
    pub project_dir: Option<PathBuf>,

    /// Data directory for service storage
    #[arg(long)]
    pub data_dir: Option<PathBuf>,

    /// Path to orch parser binary
    #[arg(long)]
    pub orch_bin: Option<PathBuf>,

    /// Namespace for isolation
    #[arg(long)]
    pub namespace: Option<String>,

    /// Pass-through arg to orch parse (repeatable, format: key=value)
    #[arg(long = "arg", action = clap::ArgAction::Append)]
    pub args: Vec<String>,

    /// Verbose output
    #[arg(long, short)]
    pub verbose: bool,

    /// Suppress non-error output
    #[arg(long, short)]
    pub quiet: bool,
}

#[derive(Subcommand)]
pub enum Commands {
    /// Generate platform artifacts from Orchfile
    Generate {
        /// Regenerate even if artifacts exist and Orchfile hasn't changed
        #[arg(long)]
        force: bool,
    },

    /// Generate artifacts and start services
    Up {
        /// Specific services to start (default: all enabled)
        services: Vec<String>,

        /// Skip generation (use existing artifacts)
        #[arg(long)]
        no_generate: bool,

        /// Wait for health after start (e.g., "60s", "0" = don't wait)
        #[arg(long)]
        health_timeout: Option<String>,
    },

    /// Stop services
    Down {
        /// Specific services to stop (default: all managed)
        services: Vec<String>,
    },

    /// Restart services
    Restart {
        /// Specific services to restart (default: all managed)
        services: Vec<String>,
    },

    /// Show status of all managed services
    Status {
        /// Output as JSON instead of table
        #[arg(long)]
        json: bool,
    },

    /// Tail logs for a service
    Logs {
        /// Service name
        service: String,

        /// Follow log output
        #[arg(long, default_value = "true")]
        follow: bool,

        /// Number of lines to show initially
        #[arg(long, short = 'n', default_value = "100")]
        lines: u32,
    },

    /// Wait for all enabled services to be healthy
    Health {
        /// Maximum wait time (e.g., "60s")
        #[arg(long, default_value = "60s")]
        timeout: String,

        /// Show per-service health details
        #[arg(long, short)]
        verbose: bool,
    },

    /// List all services defined in Orchfile
    List {
        /// Show only enabled services
        #[arg(long)]
        enabled: bool,

        /// Show only disabled services
        #[arg(long)]
        disabled: bool,

        /// Output as JSON
        #[arg(long)]
        json: bool,
    },

    /// Remove all generated artifacts and stop services
    Clean {
        /// Don't remove data directories
        #[arg(long)]
        keep_data: bool,
    },
}
