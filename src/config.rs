use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scope { System, User }

impl Scope {
    pub fn from_str(s: &str) -> Option<Self> {
        match s.to_ascii_lowercase().as_str() {
            "system" => Some(Scope::System),
            "user"   => Some(Scope::User),
            _ => None,
        }
    }
    pub fn is_user(self) -> bool { matches!(self, Scope::User) }
}

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
    pub platform: String,
    /// Scope: System (default, /etc/systemd/system) or User (~/.config/systemd/user, launchd LaunchAgents).
    pub scope: Scope,
    /// State directory for generated artifacts.
    pub state_dir: PathBuf,
    /// Project root directory.
    pub project_dir: PathBuf,
    /// Data directory for service storage.
    pub data_dir: PathBuf,
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
    /// Build config by merging CLI args > environment > .orchrc > defaults.
    ///
    /// `.orchrc` is a KEY=VALUE file searched in project_dir then HOME.
    /// Supported keys: `runtime`, `platform`, `namespace`, `state_dir`,
    /// `data_dir`, `orchfile`.
    pub fn load(cli: &crate::cli::Cli) -> Self {
        // project_dir is resolved first (it locates .orchrc), so it gets
        // CLI > env > cwd, with no .orchrc layer.
        let project_dir = cli
            .project_dir
            .clone()
            .or_else(|| std::env::var("ORCH_PROJECT").ok().map(PathBuf::from))
            .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));

        // Load .orchrc (project_dir first, then home)
        let rc = load_orchrc(&project_dir);

        // Every other setting resolves CLI > env > .orchrc > default, uniformly.
        let orchfile = path_setting(cli.orchfile.as_ref(), "ORCH_ORCHFILE", &rc, "orchfile", || {
            project_dir.join("Orchfile")
        });
        let state_dir = path_setting(cli.state_dir.as_ref(), "ORCH_STATE_DIR", &rc, "state_dir", || {
            dirs_or_home().join(".orch")
        });
        let data_dir = path_setting(cli.data_dir.as_ref(), "ORCH_DATA", &rc, "data_dir", || {
            state_dir.join("data")
        });
        let runtime = str_setting(cli.runtime.as_ref(), "ORCH_RUNTIME", &rc, "runtime", || {
            "bare".to_string()
        });
        let platform =
            str_setting(cli.platform.as_ref(), "ORCH_PLATFORM", &rc, "platform", detect_platform);
        let namespace = str_setting(cli.namespace.as_ref(), "ORCH_NAMESPACE", &rc, "namespace", || {
            "orch".to_string()
        });

        let scope = if cli.user {
            Scope::User
        } else if cli.system {
            Scope::System
        } else {
            std::env::var("ORCH_SCOPE").ok()
                .or_else(|| rc.get("scope").cloned())
                .and_then(|s| Scope::from_str(&s))
                .unwrap_or(Scope::System)
        };

        Config {
            orchfile,
            overlays: cli.overlay.clone(),
            runtime,
            platform,
            scope,
            state_dir,
            project_dir,
            data_dir,
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

/// Resolve a path setting: CLI flag > env var > `.orchrc` key > default.
fn path_setting(
    cli: Option<&PathBuf>,
    env: &str,
    rc: &std::collections::HashMap<String, String>,
    key: &str,
    default: impl FnOnce() -> PathBuf,
) -> PathBuf {
    if let Some(v) = cli {
        return v.clone();
    }
    if let Ok(v) = std::env::var(env) {
        return PathBuf::from(v);
    }
    if let Some(v) = rc.get(key) {
        return PathBuf::from(v);
    }
    default()
}

/// Resolve a string setting: CLI flag > env var > `.orchrc` key > default.
fn str_setting(
    cli: Option<&String>,
    env: &str,
    rc: &std::collections::HashMap<String, String>,
    key: &str,
    default: impl FnOnce() -> String,
) -> String {
    if let Some(v) = cli {
        return v.clone();
    }
    if let Ok(v) = std::env::var(env) {
        return v;
    }
    if let Some(v) = rc.get(key) {
        return v.clone();
    }
    default()
}

/// Load `.orchrc` key-value config file.
///
/// Search order: `project_dir/.orchrc`, then `$HOME/.orchrc`.
/// First file found wins (no merging between files).
/// Format: `KEY=VALUE` per line, `#` comments, blank lines ignored.
fn load_orchrc(project_dir: &std::path::Path) -> std::collections::HashMap<String, String> {
    let candidates = [
        project_dir.join(".orchrc"),
        dirs_or_home().join(".orchrc"),
    ];

    for path in &candidates {
        if let Ok(content) = std::fs::read_to_string(path) {
            return parse_orchrc(&content);
        }
    }

    std::collections::HashMap::new()
}

/// Parse `.orchrc` content into key-value pairs.
fn parse_orchrc(content: &str) -> std::collections::HashMap<String, String> {
    let mut map = std::collections::HashMap::new();
    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some(pos) = line.find('=') {
            let key = line[..pos].trim().to_string();
            let value = line[pos + 1..].trim().to_string();
            if !key.is_empty() {
                map.insert(key, value);
            }
        }
    }
    map
}

/// Auto-detect platform based on OS / available init system.
fn detect_platform() -> String {
    if cfg!(target_os = "macos") {
        "launchd".to_string()
    } else if std::path::Path::new("/run/systemd/system").exists() {
        "systemd".to_string()
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

#[cfg(test)]
#[allow(non_snake_case)]
mod tests {
    use super::*;
    use crate::cli::{Cli, Commands};

    fn stub_cli() -> Cli {
        Cli {
            command: Commands::Survey { json: false },
            orchfile: None,
            overlay: vec![],
            runtime: None,
            platform: None,
            state_dir: None,
            project_dir: None,
            data_dir: None,
            namespace: None,
            user: false,
            system: false,
            args: vec![],
            verbose: false,
            quiet: false,
        }
    }

    #[test]
    fn test_load__defaults_runtime_to_bare() {
        let cli = stub_cli();
        // Clear env to ensure defaults
        unsafe { std::env::remove_var("ORCH_RUNTIME") };
        let config = Config::load(&cli);
        assert_eq!(config.runtime, "bare");
    }

    #[test]
    fn test_load__defaults_namespace_to_orch() {
        let cli = stub_cli();
        unsafe { std::env::remove_var("ORCH_NAMESPACE") };
        let config = Config::load(&cli);
        assert_eq!(config.namespace, "orch");
    }

    #[test]
    fn test_load__cli_runtime_overrides_default() {
        let mut cli = stub_cli();
        cli.runtime = Some("containerd".to_string());
        let config = Config::load(&cli);
        assert_eq!(config.runtime, "containerd");
    }

    #[test]
    fn test_load__cli_namespace_overrides_default() {
        let mut cli = stub_cli();
        cli.namespace = Some("myproject".to_string());
        let config = Config::load(&cli);
        assert_eq!(config.namespace, "myproject");
    }

    #[test]
    fn test_load__cli_state_dir_overrides_default() {
        let mut cli = stub_cli();
        cli.state_dir = Some(PathBuf::from("/tmp/test-state"));
        let config = Config::load(&cli);
        assert_eq!(config.state_dir, PathBuf::from("/tmp/test-state"));
    }

    #[test]
    fn test_load__data_dir_defaults_to_state_dir_data() {
        let mut cli = stub_cli();
        cli.state_dir = Some(PathBuf::from("/tmp/test-state"));
        let config = Config::load(&cli);
        assert_eq!(config.data_dir, PathBuf::from("/tmp/test-state/data"));
    }

    #[test]
    fn test_load__cli_data_dir_overrides_default() {
        let mut cli = stub_cli();
        cli.state_dir = Some(PathBuf::from("/tmp/test-state"));
        cli.data_dir = Some(PathBuf::from("/mnt/data"));
        let config = Config::load(&cli);
        assert_eq!(config.data_dir, PathBuf::from("/mnt/data"));
    }

    #[test]
    fn test_load__verbose_and_quiet_from_cli() {
        let mut cli = stub_cli();
        cli.verbose = true;
        cli.quiet = true;
        let config = Config::load(&cli);
        assert!(config.verbose);
        assert!(config.quiet);
    }

    #[test]
    fn test_load__overlays_passed_through() {
        let mut cli = stub_cli();
        cli.overlay = vec![PathBuf::from("a.orch"), PathBuf::from("b.orch")];
        let config = Config::load(&cli);
        assert_eq!(config.overlays.len(), 2);
        assert_eq!(config.overlays[0], PathBuf::from("a.orch"));
    }

    #[test]
    fn test_load__args_passed_through() {
        let mut cli = stub_cli();
        cli.args = vec!["FOO=bar".to_string(), "BAZ=qux".to_string()];
        let config = Config::load(&cli);
        assert_eq!(config.args.len(), 2);
        assert_eq!(config.args[0], "FOO=bar");
    }

    #[test]
    fn test_unit_name__formats_correctly() {
        let mut cli = stub_cli();
        cli.namespace = Some("orch".to_string());
        let config = Config::load(&cli);
        assert_eq!(config.unit_name("postgres"), "orch-postgres.service");
    }

    #[test]
    fn test_unit_name__custom_namespace() {
        let mut cli = stub_cli();
        cli.namespace = Some("myapp".to_string());
        let config = Config::load(&cli);
        assert_eq!(config.unit_name("redis"), "myapp-redis.service");
    }

    #[test]
    fn test_target_name__formats_correctly() {
        let mut cli = stub_cli();
        cli.namespace = Some("orch".to_string());
        let config = Config::load(&cli);
        assert_eq!(config.target_name(), "orch.target");
    }

    #[test]
    fn test_units_dir__is_under_state_dir() {
        let mut cli = stub_cli();
        cli.state_dir = Some(PathBuf::from("/tmp/test-state"));
        let config = Config::load(&cli);
        assert_eq!(config.units_dir(), PathBuf::from("/tmp/test-state/units"));
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn test_detect_platform__macos_returns_launchd() {
        assert_eq!(detect_platform(), "launchd");
    }

    #[test]
    #[cfg(not(target_os = "macos"))]
    fn test_detect_platform__non_macos_returns_systemd() {
        assert_eq!(detect_platform(), "systemd");
    }

    // --- parse_orchrc ---

    #[test]
    fn test_parse_orchrc__basic_key_value() {
        let content = "runtime=bare\nnamespace=myapp\n";
        let rc = parse_orchrc(content);
        assert_eq!(rc.get("runtime").unwrap(), "bare");
        assert_eq!(rc.get("namespace").unwrap(), "myapp");
    }

    #[test]
    fn test_parse_orchrc__comments_and_blanks_ignored() {
        let content = "# comment\n\nruntime=bare\n  # another comment\n";
        let rc = parse_orchrc(content);
        assert_eq!(rc.len(), 1);
        assert_eq!(rc.get("runtime").unwrap(), "bare");
    }

    #[test]
    fn test_parse_orchrc__value_with_equals() {
        let content = "namespace=a=b\n";
        let rc = parse_orchrc(content);
        assert_eq!(rc.get("namespace").unwrap(), "a=b");
    }

    #[test]
    fn test_parse_orchrc__whitespace_trimmed() {
        let content = "  runtime = bare  \n";
        let rc = parse_orchrc(content);
        assert_eq!(rc.get("runtime").unwrap(), "bare");
    }

    #[test]
    fn test_parse_orchrc__empty_content() {
        let rc = parse_orchrc("");
        assert!(rc.is_empty());
    }

    #[test]
    fn test_load__orchrc_sets_namespace() {
        let tmp = std::env::temp_dir().join("orchd-test-orchrc");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        std::fs::write(tmp.join(".orchrc"), "namespace=from-rc\n").unwrap();

        let mut cli = stub_cli();
        cli.project_dir = Some(tmp.clone());
        cli.namespace = None;
        unsafe { std::env::remove_var("ORCH_NAMESPACE") };
        let config = Config::load(&cli);
        assert_eq!(config.namespace, "from-rc");

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn test_load__cli_overrides_orchrc() {
        let tmp = std::env::temp_dir().join("orchd-test-orchrc-override");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        std::fs::write(tmp.join(".orchrc"), "namespace=from-rc\n").unwrap();

        let mut cli = stub_cli();
        cli.project_dir = Some(tmp.clone());
        cli.namespace = Some("from-cli".to_string());
        let config = Config::load(&cli);
        assert_eq!(config.namespace, "from-cli");

        let _ = std::fs::remove_dir_all(&tmp);
    }
}
