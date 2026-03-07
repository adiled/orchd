# 09 - Phased Delivery

## Overview

orchd is built in phases, each delivering a usable increment. The first milestone is `orchd generate` producing valid systemd units from an Orchfile with a bare overlay on this LXC.

## Phase 0: Bootstrap

**Goal:** Working `orch` binary and Rust toolchain on this VM.

**Tasks:**
1. Install Rust via rustup
2. Build `orch` from `/root/orch` -- `cargo build --release`
3. Add `orch` to PATH (symlink to `/usr/local/bin/`)
4. Verify: `orch parse /root/your-project/Orchfile` outputs valid JSON

**Dependencies:** None
**Deliverable:** `orch` binary producing JSON on this machine

## Phase 1: Scaffold

**Goal:** Compiling `orchd` binary with `orchd --help` working.

**Tasks:**
1. `cargo init` in `/root/orchd`
2. Add dependencies: serde, serde_json, clap
3. Implement `src/types.rs` -- deserialization types mirroring orch JSON
4. Implement `src/config.rs` -- config struct, loading skeleton
5. Implement `src/main.rs` -- clap CLI with all subcommands (stubs)
6. Define `src/runtime/mod.rs` -- Runtime trait
7. Define `src/platform/mod.rs` -- Platform trait
8. Define `src/exec.rs` -- ExecSet type
9. Verify: `cargo build` succeeds, `orchd --help` shows all subcommands

**Dependencies:** Phase 0 (need orch JSON for type verification)
**Deliverable:** Compiling binary, trait definitions, type system

## Phase 2: systemd Generator

**Goal:** `orchd generate` produces valid `.service` unit files.

**Tasks:**
1. Implement `src/platform/systemd/generate.rs`:
   - Service --> unit file string
   - Handle all directive mappings per [04-systemd-platform.md](04-systemd-platform.md)
   - Ready gate generation for healthcheck-gated dependencies
   - orch.target generation
2. Implement `src/vars.rs` -- built-in variable expansion
3. Implement unit file writing to `${state_dir}/units/`
4. Implement symlink installation + `systemctl daemon-reload`
5. Wire into engine: `orchd generate` calls orch parse, deserializes, generates
6. Tests: unit file content assertions for all directive types

**Dependencies:** Phase 1
**Deliverable:** `orchd generate` produces correct systemd units from Orchfile JSON

## Phase 3: systemd Lifecycle

**Goal:** `orchd up/down/status/logs/health` work with systemd.

**Tasks:**
1. Implement `src/platform/systemd/lifecycle.rs`:
   - `start()` -- systemctl start
   - `stop()` -- systemctl stop
   - `restart()` -- systemctl restart
   - `status()` -- systemctl show, formatted table output
   - `logs()` -- journalctl delegation
2. Implement `src/health.rs`:
   - HTTP healthcheck (GET, expect 2xx)
   - Command healthcheck (exec, expect exit 0)
   - Timeout + polling loop
   - Per-service result reporting
3. Wire lifecycle commands in engine and CLI
4. Tests: mock systemctl for lifecycle tests, real healthcheck tests

**Dependencies:** Phase 2
**Deliverable:** Full lifecycle management via orchd CLI

## Phase 4: Bare Runtime

**Goal:** Bare runtime validates and prepares host-mode services.

**Tasks:**
1. Implement `src/runtime/bare/mod.rs`:
   - `check()` -- verify orch binary exists
   - `prepare()` -- create data directories
   - `exec_command()` -- return run_command or error on container-mode
   - `cleanup()` -- no-op
2. Wire runtime into engine pipeline
3. Tests: accept host services, reject container services, directory creation

**Dependencies:** Phase 1
**Deliverable:** Bare runtime plugin, integrated with engine

## Phase 5: Engine Integration

**Goal:** Full end-to-end pipeline working on this LXC.

**Tasks:**
1. Implement `src/engine.rs`:
   - Config loading --> orch parse invocation --> JSON deserialization
   - Runtime dispatch --> ExecSet assembly
   - Platform dispatch --> generation + lifecycle
2. Wire all CLI subcommands to engine functions
3. Error handling: user-friendly error messages with context
4. Output formatting: colored status tables, progress messages
5. End-to-end test: Orchfile --> systemd units --> services running

**Dependencies:** Phases 2, 3, 4
**Deliverable:** `orchd up` works end-to-end

## Phase 6: Tests and Quality

**Goal:** Comprehensive test suite, CI, code quality.

**Tasks:**
1. Write fixture JSON files for all service configurations
2. Unit tests for all directive mappings
3. Integration tests for CLI --> engine --> platform pipeline
4. Set up GitHub Actions CI (test, clippy, fmt)
5. Error message review -- ensure all errors are actionable
6. Code review pass -- naming, module organization, documentation

**Dependencies:** Phase 5
**Deliverable:** `cargo test` passes, CI green, clippy clean

## Phase 7: Project Validation

**Goal:** Development services running on this LXC via orchd.

**Tasks:**
1. Write `bare.orch` overlay for the project:
   - postgres, redis, nginx --> RUN with host paths/ports
   - localstack --> DISABLED (or bare command if feasible)
2. Write `.orchrc` for the project
3. Install prerequisites on this LXC (postgres, redis, nginx, python, etc.)
4. Run `orchd up` -- verify all services start
5. Run `orchd health` -- verify healthchecks pass
6. Run `orchd status` -- verify status table
7. Document the setup in the project repo

**Dependencies:** Phase 5, host software installation
**Deliverable:** Project stack running on this LXC via `orchd up`

## Milestone Summary

| Phase | Milestone | Key Deliverable |
|-------|-----------|-----------------|
| 0 | Bootstrap | `orch` binary on this VM |
| 1 | Scaffold | `orchd --help` |
| 2 | Generator | `orchd generate` --> .service files |
| 3 | Lifecycle | `orchd up/down/status/logs/health` |
| 4 | Bare runtime | Container-mode rejection, dir creation |
| 5 | Integration | Full pipeline end-to-end |
| 6 | Quality | Tests, CI, clippy clean |
| 7 | Validation | Project running on this LXC |

## Future Work (Post-MVP)

- **containerd runtime** -- for Linux environments where containers are available
- **podman runtime** -- OCI container alternative
- **apple runtime** -- extract from existing macOS port
- **launchd platform** -- extract from existing macOS port
- **Workspace merge** -- merge orchd into orch Cargo workspace
- **Parallel healthchecks** -- async polling with tokio
- **Watch mode** -- `orchd watch` regenerates on Orchfile changes
- **Shell completions** -- clap-generated completions for bash/zsh/fish
