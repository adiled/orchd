# 08 - Testing Strategy

## Overview

orchd uses Rust's built-in test framework for unit and integration tests. The test strategy prioritizes determinism and avoids requiring a running systemd or container runtime for most tests.

## Test Categories

### Unit Tests (in-module `#[cfg(test)]`)

Colocated with source code. Test individual functions in isolation.

**What they cover:**
- Config loading and precedence
- Type deserialization from JSON fixtures
- ExecSet assembly logic
- systemd unit file generation (string assertions)
- Built-in variable expansion
- Workdir resolution
- Duration parsing
- Healthcheck URL/command classification

### Integration Tests (`tests/` directory)

Test the full pipeline from JSON input to generated artifacts.

**What they cover:**
- Full engine pipeline: JSON --> ExecSets --> unit files
- CLI argument parsing and config resolution
- Bare runtime validation (error on container-mode services)
- Generated unit file correctness (parse and validate)

### System Tests (manual / CI with systemd)

Require a real systemd instance. Run in CI (Linux containers) or manually on dev machines.

**What they cover:**
- `orchd generate` produces loadable units
- `orchd up` / `orchd down` actually starts/stops services
- `orchd status` reflects real process state
- `orchd health` correctly polls healthchecks

## Fixtures

### JSON Fixtures

Sample `orch parse` output for testing deserialization and generation:

```
tests/
  fixtures/
    minimal.json          # Single host service
    container_service.json # Single container service
    full_myapp.json      # Full myapp stack (all service types)
    dependencies.json     # Services with complex REQUIRES/AFTER chains
    oneshot.json          # Oneshot services
    disabled.json         # Mix of enabled and disabled services
    resources.json        # Services with all resource limits set
```

Each fixture is a valid `orch parse` output that can be deserialized into `OrchFile`.

### Mock orch Binary

For integration tests that invoke `orch parse` as a subprocess, provide a mock:

```rust
// tests/helpers/mock_orch.rs
// A simple binary that reads a fixture file and outputs it
// Usage: mock-orch parse <fixture_path> --> cat fixture_path to stdout
```

Set `ORCH_BIN=./target/debug/mock-orch` in test config.

## Unit Test Patterns

### Testing Unit File Generation

```rust
#[test]
fn test_generate_simple_host_service() {
    let service = Service {
        name: "django".into(),
        mode: ServiceMode::Host,
        run_command: Some("python manage.py runserver 0.0.0.0:9090".into()),
        workdir: Some("backend/myapp".into()),
        restart: RestartConfig {
            policy: RestartPolicy::OnFailure,
            delay: Some("2s".into()),
            ..Default::default()
        },
        ..test_defaults()
    };

    let exec_set = ExecSet {
        start: service.run_command.clone().unwrap(),
        ..Default::default()
    };

    let config = test_config();
    let unit = generate_unit(&service, &exec_set, &config);

    assert!(unit.contains("Type=simple"));
    assert!(unit.contains("Restart=on-failure"));
    assert!(unit.contains("RestartSec=2"));
    assert!(unit.contains("ExecStart=/bin/bash -c"));
    assert!(unit.contains("python manage.py runserver"));
    assert!(unit.contains("WorkingDirectory=/project/backend/myapp"));
}
```

### Testing Ready Gate Generation

```rust
#[test]
fn test_ready_gate_for_healthchecked_dependency() {
    let postgres = Service {
        name: "postgres".into(),
        healthcheck: Some("pg_isready -h localhost -p 5433".into()),
        ..test_defaults()
    };

    let django = Service {
        name: "django".into(),
        requires: vec!["postgres".into()],
        ..test_defaults()
    };

    let orch = OrchFile {
        services: vec![postgres, django],
        ..Default::default()
    };

    let units = generate_all_units(&orch, &exec_sets, &config);

    // Ready gate should exist
    assert!(units.contains_key("orch-postgres-ready.service"));

    let gate = &units["orch-postgres-ready.service"];
    assert!(gate.contains("Type=oneshot"));
    assert!(gate.contains("RemainAfterExit=yes"));
    assert!(gate.contains("pg_isready -h localhost -p 5433"));

    // Django should depend on the ready gate, not the service directly
    let django_unit = &units["orch-django.service"];
    assert!(django_unit.contains("After=orch-postgres-ready.service"));
}
```

### Testing Bare Runtime Errors

```rust
#[test]
fn test_bare_runtime_rejects_container_service() {
    let runtime = BareRuntime;
    let service = Service {
        name: "postgres".into(),
        mode: ServiceMode::Container,
        image: Some("pgvector/pgvector:pg15".into()),
        ..test_defaults()
    };

    let result = runtime.exec_command(&service, &test_config());
    assert!(result.is_err());
    assert!(result.unwrap_err().to_string().contains("overlay"));
}
```

### Testing Config Precedence

```rust
#[test]
fn test_cli_overrides_env() {
    std::env::set_var("ORCH_RUNTIME", "containerd");

    let cli = CliArgs {
        runtime: Some("bare".into()),
        ..Default::default()
    };

    let config = Config::load(&cli).unwrap();
    assert_eq!(config.runtime, "bare"); // CLI wins

    std::env::remove_var("ORCH_RUNTIME");
}
```

## Test Helpers

```rust
// tests/helpers.rs

/// Default service with all required fields set to sensible values
fn test_defaults() -> Service { ... }

/// Default config pointing to temp directories
fn test_config() -> Config { ... }

/// Create a temp directory with a fixture Orchfile
fn fixture_project(json: &str) -> TempDir { ... }
```

## CI Configuration

```yaml
# .github/workflows/test.yml
name: Test
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - run: cargo test
      - run: cargo clippy -- -D warnings
      - run: cargo fmt -- --check
```

## Coverage Goals

| Area | Target |
|------|--------|
| Type deserialization | All fields, all variants, missing optionals |
| systemd unit generation | All directive mappings from the spec |
| Ready gate logic | Generated when needed, omitted when not |
| Dependency wiring | REQUIRES vs AFTER, with and without healthchecks |
| Config loading | All precedence levels, auto-detection |
| Bare runtime | Accept host services, reject container services |
| CLI parsing | All subcommands, all flags, error cases |
| Variable expansion | All built-in variables, nested paths |

## What We Don't Test in Unit Tests

- Actual systemctl/launchctl invocations (system tests only)
- Real process start/stop
- Network connectivity for HTTP healthchecks
- File permissions and ownership
- systemd cgroup enforcement
