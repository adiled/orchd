/// The runtime-produced command set for a service, consumed by platforms.
///
/// For host-mode services, only `start` is populated (the `run_command`).
/// For container runtimes, all fields may be populated (pull, create, start, stop, rm).
///
/// Serializable so the apple runtime (orchd-apple Zig binary) can emit it as JSON.
#[derive(Debug, Default, Clone, serde::Serialize, serde::Deserialize)]
pub struct ExecSet {
    /// The main process command (ExecStart= / ProgramArguments)
    pub start: String,

    /// Optional pre-start command (ExecStartPre=)
    /// e.g., container create, image pull
    pub pre_start: Option<String>,

    /// Optional stop command (ExecStop=)
    /// e.g., container stop <name>
    pub stop: Option<String>,

    /// Optional post-stop command (ExecStopPost=)
    /// e.g., container rm <name> (if recreate=always)
    pub post_stop: Option<String>,
}
