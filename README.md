# orchd

Execution engine for the [Orch specification](https://github.com/adiled/orch). Takes parsed Orchfile JSON and turns it into running, supervised services.

```
Orchfile → orch parse (JSON) → Runtime (ExecSet) → Platform (native artifacts)
```

**Runtime** produces execution commands from service definitions. **Platform** consumes them and generates native service manager artifacts.

| Layer    | Implemented      | Planned                |
|----------|------------------|------------------------|
| Runtime  | `bare`, `apple`  | `containerd`, `podman` |
| Platform | `systemd`        | `launchd`              |

The [`apple`](orchd-apple/) runtime runs container-mode services on macOS 26+
via Apple's native [container](https://github.com/apple/container) framework. It
is a standalone Zig co-process (`orchd-apple/`) that speaks XPC to
`container-apiserver`; build it with `cd orchd-apple && zig build`.

## Install

```sh
cargo build --release
ln -sf target/release/orchd /usr/local/bin/orchd
```

Requires [orch](https://github.com/adiled/orch) in `PATH`.

## Commands

```
orchd generate [--force]
orchd up [services...] [--no-generate]
orchd down [services...]
orchd restart [services...]
orchd status [--json]
orchd logs <service> [-n lines] [--follow]
orchd health [--timeout 60s] [-v]
orchd list [--enabled] [--disabled] [--json]
orchd clean [--keep-data]
```

## Global Flags

```
--orchfile <path>       Path to Orchfile (default: ./Orchfile)
--overlay <path>        Overlay file (repeatable)
--runtime <name>        bare (default), apple
--namespace <name>      Unit prefix (default: orch)
--state-dir <path>      Artifact directory (default: ~/.orch)
--data-dir <path>       Service data (default: <state-dir>/data)
--orch-bin <path>       orch binary (default: orch)
-v, --verbose
-q, --quiet
```

## Configuration

`.orchrc` in project directory or `$HOME`, one `KEY=VALUE` per line:

```
runtime=bare
namespace=myapp
state_dir=/var/lib/myapp
```

Supported keys: `runtime`, `platform`, `namespace`, `state_dir`, `data_dir`, `orch_bin`, `orchfile`.

Merge order: CLI > environment > `.orchrc` > defaults.

## Example

```sh
# Generate systemd units from Orchfile + bare overlay
orchd --orchfile ./Orchfile --overlay bare.orch generate

# Start all enabled services
orchd up

# Check health
orchd health --timeout 30s -v

# Tail logs
orchd logs postgres

# Stop everything and clean up
orchd clean
```

## Tests

```sh
cargo test                        # 74 unit tests
cargo test -- --include-ignored   # + integration test (needs orch binary)
```

## License

Apache 2.0
