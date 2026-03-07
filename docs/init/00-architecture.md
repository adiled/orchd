# 00 - Architecture

## Mission

orchd is the execution engine for the [Orch specification](https://github.com/adiled/orch). It takes parsed Orchfile JSON and turns it into running, supervised services on any supported platform using any compatible runtime.

## The Three-Repo Model

| Repo | Responsibility | Language |
|------|---------------|----------|
| **orch** | Specification + parser. Orchfile --> JSON. Owns the grammar, merge semantics, and constraint validation. | Rust |
| **orchd** | Execution engine. JSON --> running services. Owns runtime/platform pluggability, unit generation, and lifecycle management. | Rust |
| **your-project** | Project-specific configuration. Orchfile, overlays, init scripts, data seeding. Consumes orch + orchd. | Any |

The interface between orch and orchd is the **JSON schema** produced by `orch parse`. orchd calls `orch parse` as a subprocess, captures JSON on stdout, and deserializes via serde. This is the only contract.

When both stabilize, they merge into a single Cargo workspace sharing an `orch-core` types crate.

## Core Abstraction

orchd separates two orthogonal concerns:

- **Runtime** -- how to run a `FROM` (container-mode) service. Bare host process? containerd? podman? Apple containers?
- **Platform** -- how to supervise a process. systemd? launchd?

Host-mode services (`RUN`) bypass the runtime entirely -- the command runs directly under the platform's supervision.

```
Orchfiles (base + overlays)
       |
   orch parse --> JSON
       |
   orchd engine
       |
  +----+----+
  v         v
Runtime   Platform
Plugin    Plugin
  |         |
  v         v
bare      systemd
containerd  launchd
podman
apple
```

## The Engine as Mediator

The engine orchestrates the interaction between runtime and platform without coupling them:

1. Deserialize orch JSON into typed `OrchFile` struct
2. For each container-mode service: call `runtime.exec_command()` to get the executable command, plus optional `stop_command()`, `pre_start()`, `post_stop()`
3. For each host-mode service: use `run_command` directly
4. Collect all commands into an `ExecSet` per service
5. Pass `ExecSet` + service metadata to `platform.generate()` which writes platform artifacts (unit files, plists)
6. Lifecycle commands (`up`, `down`, `status`) delegate to the platform

```
Engine
  |
  +-- calls Runtime.exec_command(service)  --> "nerdctl start --attach pg"
  +-- calls Runtime.stop_command(service)  --> Some("nerdctl stop pg")
  +-- calls Runtime.pre_start(service)     --> Some("nerdctl create ...")
  +-- calls Runtime.post_stop(service)     --> Some("nerdctl rm pg")
  |
  +-- assembles ExecSet { pre_start, start, stop, post_stop }
  |
  +-- passes ExecSet + Service to Platform.generate()
          --> writes systemd unit / launchd plist
```

## Compatibility Matrix

Not all runtime-platform combinations are valid. The constraint is environmental (does this runtime exist on this OS?), not architectural.

| Runtime \ Platform | systemd | launchd |
|--------------------|---------|---------|
| **bare**           | Linux, LXC, VM | macOS |
| **apple**          | --      | macOS (Apple Silicon) |
| **containerd**     | Linux   | -- |
| **podman**         | Linux   | -- |

Each runtime's `check()` method validates prerequisites and fails honestly if the runtime cannot operate on the current system. The engine does not hardcode the matrix -- it delegates validation to the plugins.

## Auto-Detection

When runtime or platform are not explicitly configured:

- **Platform**: `uname -s` -- Darwin --> launchd, Linux --> systemd
- **Runtime**: bare (default). Override via config.

## Crate Structure

```
orchd/
+-- Cargo.toml
+-- src/
|   +-- main.rs                    # CLI (clap)
|   +-- config.rs                  # Config loading, auto-detection
|   +-- types.rs                   # Deserialized orch JSON types
|   +-- engine.rs                  # Orchestration pipeline
|   +-- health.rs                  # Healthcheck runner
|   +-- vars.rs                    # Built-in variable expansion
|   +-- exec.rs                    # ExecSet type
|   +-- platform/
|   |   +-- mod.rs                 # Platform trait
|   |   +-- systemd/
|   |       +-- mod.rs
|   |       +-- generate.rs        # JSON --> systemd unit files
|   |       +-- lifecycle.rs       # systemctl operations
|   +-- runtime/
|       +-- mod.rs                 # Runtime trait
|       +-- bare/
|           +-- mod.rs             # Bare runtime
+-- tests/
|   +-- fixtures/
|   +-- systemd_generate_test.rs
|   +-- bare_runtime_test.rs
+-- docs/
+-- LICENSE
```

## Design Principles

1. **Plugin independence** -- platforms never import runtimes, runtimes never import platforms. They communicate through the engine via shared types (`ExecSet`, `Service`).
2. **Fail loudly** -- validate prerequisites before operating. `runtime.check()` and `platform.check()` run before any mutation.
3. **Idempotency** -- `orchd generate` is idempotent. `orchd up` is idempotent. Running them twice produces the same result.
4. **Minimal dependencies** -- serde, serde_json, clap. No async framework initially.
5. **The JSON contract** -- orchd treats `orch parse` output as the source of truth. If the JSON schema changes, orchd's `types.rs` updates to match. No other coupling.
