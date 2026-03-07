# 10 - Versioning & Compatibility

## Overview

orchd operates at the intersection of independently-shipping projects: the orch parser, container runtimes (containerd, podman, Apple containers), and platform binaries (systemctl, launchctl). Each ships on its own cadence. This document defines how orchd declares, checks, and enforces compatibility with all of them.

## orchd Versioning

orchd follows [Semantic Versioning](https://semver.org/):

- **Major**: breaking change to CLI interface, config format, or dropped runtime/platform support
- **Minor**: new runtime, new platform, new CLI subcommand, new config key, new supported orch schema version
- **Patch**: bug fixes, better error messages, internal refactors

Pre-1.0 (`0.x.y`): minor bumps may contain breaking changes. This is expected per SemVer convention.

## orch Schema Compatibility

### The Contract

The interface between orch and orchd is the **JSON schema** produced by `orch parse`, not the orch binary itself. The JSON includes a `version` field (e.g., `"0.2.0"`) that identifies the schema.

orchd tracks compatibility by **major.minor match**:

- orchd declares which schema major.minor versions it supports (e.g., `["0.2"]`)
- Patch differences are ignored (`0.2.0`, `0.2.1`, `0.2.99` all match `0.2`)
- Unsupported schema versions produce a clear error

### Schema Check

```rust
const SUPPORTED_SCHEMAS: &[&str] = &["0.2"];

fn validate_schema(orch: &OrchFile) -> Result<()> {
    let version = &orch.version;
    let major_minor = version
        .rsplitn(2, '.')
        .last()
        .unwrap_or(version);

    if !SUPPORTED_SCHEMAS.iter().any(|s| version.starts_with(s)) {
        return Err(anyhow!(
            "orch schema version {} is not supported by orchd {}.\n\
             Supported schemas: {}\n\
             Update orchd or use a compatible orch version.",
            version,
            env!("CARGO_PKG_VERSION"),
            SUPPORTED_SCHEMAS.join(", ")
        ));
    }
    Ok(())
}
```

### Forward-Compatible Deserialization

orchd uses **lenient serde deserialization**: unknown fields in orch JSON are silently ignored. When orch adds a new directive (e.g., `NETWORK`) and includes it in the JSON, orchd continues to work -- it simply doesn't use the new field until support is added.

This is critical for ecosystem velocity. orch can ship new features without waiting for orchd to catch up, and orchd doesn't crash on newer patch/minor orch releases within the same schema major.minor.

```rust
// Correct: lenient (serde default behavior)
#[derive(Deserialize)]
pub struct Service {
    pub name: String,
    pub mode: ServiceMode,
    // ... known fields only
    // unknown fields silently skipped
}

// Wrong: strict (breaks on any new field)
// #[serde(deny_unknown_fields)]
```

### Schema Evolution Policy

When orch bumps its schema version:

| Change type | Schema version | orchd impact |
|-------------|---------------|--------------|
| New optional field | Patch (0.2.x) | None -- ignored by serde |
| New directive with new field | Minor (0.x.0) | orchd adds support, bumps own minor |
| Renamed/removed field | Major (x.0.0) | orchd adds new schema support, bumps own minor or major |

orchd may support multiple schema versions simultaneously:

```rust
const SUPPORTED_SCHEMAS: &[&str] = &["0.2", "0.3"];
```

## Runtime Compatibility

### Capability Detection over Version Checks

Runtimes wrap external CLI tools (nerdctl, podman, container). Version strings are unreliable across distros, forks, and packaging. orchd checks **capabilities** instead.

### Two-Tier Check: Critical vs Advisory

Each runtime's `check()` validates capabilities in two tiers:

| Tier | Behavior | Examples |
|------|----------|---------|
| **Critical** | `check()` returns `Err`, orchd refuses to run | Binary not found, cannot create containers, daemon not running |
| **Advisory** | `check()` emits warnings, orchd continues | Resource limit flags unsupported, specific CLI options missing |

```rust
pub struct RuntimeCheckResult {
    pub ok: bool,
    pub warnings: Vec<String>,
}

// In the Runtime trait:
fn check(&self) -> Result<RuntimeCheckResult>;
```

Engine behavior:
```rust
let check = runtime.check()?;  // Err = critical failure, abort
for warning in &check.warnings {
    eprintln!("[WARN] {}", warning);  // advisory, continue
}
```

### Examples

**Bare runtime (critical only):**
```rust
fn check(&self) -> Result<RuntimeCheckResult> {
    which::which("orch")
        .map_err(|_| anyhow!("orch binary not found in PATH"))?;
    Ok(RuntimeCheckResult { ok: true, warnings: vec![] })
}
```

**containerd runtime (critical + advisory):**
```rust
fn check(&self) -> Result<RuntimeCheckResult> {
    // Critical: binary exists
    which::which("nerdctl")
        .map_err(|_| anyhow!("nerdctl not found in PATH"))?;

    // Critical: daemon running
    let status = Command::new("nerdctl").args(["info"]).output()?;
    if !status.status.success() {
        return Err(anyhow!("containerd daemon not running"));
    }

    let mut warnings = vec![];

    // Advisory: resource limit support
    let help = Command::new("nerdctl").args(["create", "--help"]).output()?;
    let help_text = String::from_utf8_lossy(&help.stdout);
    if !help_text.contains("--memory") {
        warnings.push("nerdctl does not support --memory flag; MEMORY limits will be ignored".into());
    }
    if !help_text.contains("--cpus") {
        warnings.push("nerdctl does not support --cpus flag; CPU limits will be ignored".into());
    }

    Ok(RuntimeCheckResult { ok: true, warnings })
}
```

## Platform Compatibility

Platform binaries (systemctl, launchctl) are OS-provided and rarely change their core interface. orchd does minimal checking:

- **systemd**: verify `systemctl` exists and responds to `systemctl --version`
- **launchd**: verify `launchctl` exists (no version command)

Platform compatibility is primarily an OS detection concern (handled by auto-detection), not a version concern.

## Version Reporting

orchd provides full compatibility info via `orchd version`:

### Human-readable

```
$ orchd version
orchd 0.1.0
  orch schema: 0.2 (supported: 0.2)
  runtime: bare
  platform: systemd
  orch binary: /usr/local/bin/orch
  systemd: 252
```

### Machine-readable

```
$ orchd version --json
{
  "orchd": "0.1.0",
  "supported_schemas": ["0.2"],
  "runtime": {
    "name": "bare",
    "status": "ok",
    "warnings": []
  },
  "platform": {
    "name": "systemd",
    "status": "ok"
  },
  "detected": {
    "orch_bin": "/usr/local/bin/orch",
    "orch_schema": "0.2.0",
    "systemd_version": "252"
  }
}
```

## Lock File

No lock file for now. orchd does not manage a dependency registry or resolve versions from multiple candidates. It uses whatever binaries are in PATH.

The `orchd version --json` output serves the reproducibility and debugging purpose. CI pipelines can capture it as a build artifact.

A lock file becomes relevant if orchd ever manages runtime plugin installation (e.g., `orchd install-runtime containerd@1.7`). That is out of scope for the current design.

## Compatibility Table

Maintained in README and in `orchd version` output:

| orchd version | orch schema | Runtimes | Platforms |
|--------------|-------------|----------|-----------|
| 0.1.x | 0.2 | bare | systemd |
| (future) | 0.2, 0.3 | bare, containerd | systemd, launchd |

This table is updated with each orchd release that adds or changes compatibility.
