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

    /// Namespace for isolation
    #[arg(long)]
    pub namespace: Option<String>,

    /// Use user scope (~/.config/systemd/user, ~/Library/LaunchAgents). Default.
    #[arg(long, conflicts_with = "system")]
    pub user: bool,

    /// Use system scope (/etc/systemd/system; root).
    #[arg(long, conflicts_with = "user")]
    pub system: bool,

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
    // ----- walks (the common path) -----------------------------------------
    /// Bring the grove up: sow, plant, and tend in one step.
    Grow {
        /// Specific services to start (default: all enabled).
        services: Vec<String>,

        /// Write and install but do not start.
        #[arg(long)]
        no_start: bool,

        #[arg(
            long,
            help = "Fail if any service cannot be materialized, instead of warning."
        )]
        strict: bool,

        #[arg(long, help = "Regenerate even when the Orchfile has not changed.")]
        force: bool,
    },

    /// Report the grove: each tree's state.
    Survey {
        /// Output as JSON instead of a table.
        #[arg(long)]
        json: bool,
    },

    /// Tear the grove down: stop and remove its beds.
    Fell {
        /// Keep service data directories.
        #[arg(long)]
        keep_data: bool,
    },

    /// Tail a tree's logs.
    Logs {
        /// Service name.
        service: String,

        /// Follow log output.
        #[arg(long, default_value = "true")]
        follow: bool,

        /// Number of lines to show initially.
        #[arg(long, short = 'n', default_value = "100")]
        lines: u32,
    },

    // ----- rows (composable pipes) -----------------------------------------
    /// Row: spec (stdin) -> cuttings (stdout). Pair each service with its ExecSet.
    Sow {},

    /// Row: cuttings (stdin) -> beds (stdout). Render each service's native files.
    Plant {},

    /// Row: beds (stdin) -> running. Write, install, and start.
    /// With a service, supervise that one service for its lifetime instead.
    Tend {
        #[arg(help = "Service to supervise for its lifetime (the tree keeper)")]
        service: Option<String>,

        #[arg(
            long,
            conflicts_with = "service",
            help = "Supervise from an explicit spec file. Used by launchd and orchdi, which know the path because plant baked it."
        )]
        spec: Option<PathBuf>,

        #[arg(long, help = "Write and install but do not start.")]
        no_start: bool,
    },
}
