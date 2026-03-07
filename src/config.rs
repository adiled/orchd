use std::path::PathBuf;

/// orchd configuration, merged from CLI > env > .orchrc > defaults.
#[derive(Debug, Clone)]
pub struct Config {
    /// Path to the Orchfile.
    pub orchfile: PathBuf,
    /// Overlay files applied on top of the Orchfile.
    pub overlays: Vec<PathBuf>,
    /// Runtime name: bare, containerd, podman, apple.
    pub runtime: String,
    /// Platform name: systemd, launchd.
    #[allow(dead_code)]
    pub platform: String,
    /// State directory for generated artifacts.
    pub state_dir: PathBuf,
    /// Project root directory.
    pub project_dir: PathBuf,
    /// Data directory for service storage.
    pub data_dir: PathBuf,
    /// Path to the orch parser binary.
    pub orch_bin: PathBuf,
    /// Namespace for isolation (used as unit prefix).
    pub namespace: String,
    /// Pass-through args to orch parse (key=value).
    pub args: Vec<String>,
    /// Verbose output.
    pub verbose: bool,
    /// Suppress non-error output.
    pub quiet: bool,
}

impl Config {
    /// Build config by merging CLI args > environment > defaults.
    pub fn load(cli: &crate::cli::Cli) -> Self {
        let project_dir = cli.project_dir.clone().unwrap_or_else(|| {
            std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
        });

        let orchfile = cli.orchfile.clone().unwrap_or_else(|| project_dir.join("Orchfile"));

        let state_dir = cli.state_dir.clone().unwrap_or_else(|| {
            std::env::var("ORCH_STATE_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|_| {
                    dirs_or_home().join(".orch")
                })
        });

        let data_dir = cli.data_dir.clone().unwrap_or_else(|| state_dir.join("data"));

        let orch_bin = cli.orch_bin.clone().unwrap_or_else(|| {
            std::env::var("ORCH_BIN")
                .map(PathBuf::from)
                .unwrap_or_else(|_| PathBuf::from("orch"))
        });

        let runtime = cli.runtime.clone().unwrap_or_else(|| {
            std::env::var("ORCH_RUNTIME").unwrap_or_else(|_| "bare".to_string())
        });

        let platform = cli.platform.clone().unwrap_or_else(|| {
            std::env::var("ORCH_PLATFORM").unwrap_or_else(|_| detect_platform())
        });

        let namespace = cli.namespace.clone().unwrap_or_else(|| {
            std::env::var("ORCH_NAMESPACE").unwrap_or_else(|_| "orch".to_string())
        });

        Config {
            orchfile,
            overlays: cli.overlay.clone(),
            runtime,
            platform,
            state_dir,
            project_dir,
            data_dir,
            orch_bin,
            namespace,
            args: cli.args.clone(),
            verbose: cli.verbose,
            quiet: cli.quiet,
        }
    }

    /// Returns the directory where generated unit files are written.
    pub fn units_dir(&self) -> PathBuf {
        self.state_dir.join("units")
    }

    /// Returns the systemd unit name for a service.
    pub fn unit_name(&self, service_name: &str) -> String {
        format!("{}-{}.service", self.namespace, service_name)
    }

    /// Returns the systemd target name.
    pub fn target_name(&self) -> String {
        format!("{}.target", self.namespace)
    }
}

/// Auto-detect platform based on available init system.
fn detect_platform() -> String {
    if std::path::Path::new("/run/systemd/system").exists() {
        "systemd".to_string()
    } else if cfg!(target_os = "macos") {
        "launchd".to_string()
    } else {
        "systemd".to_string()
    }
}

/// Return home directory or /root as fallback.
fn dirs_or_home() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/root"))
}
