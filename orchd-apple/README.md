# orchd-apple

Apple [container](https://github.com/apple/container) runtime for [orchd](../).

A standalone Zig binary that orchd spawns as a co-process to run container-mode
services on macOS 26+ using Apple's native Containerization framework — each
container in its own lightweight VM, no Docker daemon.

## Why a separate Zig binary?

The runtime needs to talk to `com.apple.container.apiserver` over **XPC**, a
C/block-based macOS IPC mechanism with no Rust or Zig library. Zig's direct C
interop lets us build the XPC client from scratch with zero glue — including
hand-constructing the Objective-C *block* that `xpc_connection_set_event_handler`
requires (see `src/xpc_extern.zig`). orchd (Rust) drives it over a simple
JSON-on-stdin/stdout protocol.

```
orchd (Rust) ──JSON──> orchd-apple (Zig) ──XPC──> container-apiserver
                                          ──exec──> container CLI (image pull)
```

## Protocol

| Command                        | stdin          | stdout       | Action                              |
|--------------------------------|----------------|--------------|-------------------------------------|
| `orchd-apple check`            | —              | —            | XPC ping; exit 0 if daemon reachable |
| `orchd-apple exec-set <ns>`    | Service JSON   | ExecSet JSON | Translate service → container commands |
| `orchd-apple prepare <ns>`     | Service JSON   | —            | `container image pull`              |
| `orchd-apple cleanup <ns>`     | Service JSON   | —            | Delete container via XPC            |

Container naming: `<namespace>-<service.name>` (e.g. `orch-postgres`).

## ExecSet mapping

A container-mode service becomes:

| Field        | Command                                       |
|--------------|-----------------------------------------------|
| `pre_start`  | `container image pull <image>`                |
| `start`      | `container run --name <ns>-<svc> --init ...`  |
| `stop`       | `container stop <ns>-<svc>`                    |
| `post_stop`  | `container delete --force <ns>-<svc>`         |

`start` runs in the foreground (no `-d`) so the platform supervisor (launchd)
tracks the PID directly. `--init` is always added so signals are forwarded into
the container and zombies are reaped.

## Source layout

```
src/
├── main.zig         CLI dispatch + JSON stdin/stdout protocol
├── xpc_extern.zig   raw XPC C declarations + Block ABI (the from-scratch layer)
├── xpc.zig          typed Connection / Message wrapper
├── client.zig       container-apiserver client (ping, stop, delete)
├── types.zig        Service (input) + ExecSet (output) types
├── exec_set.zig     Service → container CLI command generation (+ unit tests)
└── prepare.zig      image pull subprocess
```

## Build

```sh
zig fetch --save https://github.com/Hejsil/zig-clap/archive/refs/tags/0.12.0.tar.gz  # once
zig build           # → zig-out/bin/orchd-apple
zig build test      # unit tests
```

Requires Zig 0.16+ and macOS 26+ (for the `container` runtime at execution time).

## Dependencies

- [zig-clap](https://github.com/Hejsil/zig-clap) 0.12.0 — CLI parsing
- macOS `libSystem` (XPC) — linked automatically, no SDK package needed
