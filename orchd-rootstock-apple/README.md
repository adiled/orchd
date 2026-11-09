# orchd-rootstock-apple

orchd's rootstock for Apple's [container](https://github.com/apple/container)
runtime: each container in its own lightweight VM, no Docker daemon. It speaks
orchd's rootstock contract 1 and ships beside orchd; `--rootstock apple` picks it.

## Modes

`ORCHD_APPLE_MODE` picks how a container runs:

| Mode | | |
|---|---|---|
| `xpc` (default) | this binary drives Apple's container daemon over **XPC** | `orchd-rootstock-apple run`, `wait`, `stop`, `delete` |
| `cli` | Apple's `container` CLI | `container run --name <grove>-<svc> --init …`, `stop`, `delete --force` |

Either way the image is pulled with `container image pull`, and the container is
named `<grove>-<service>`. A host service (RUN, not FROM) runs as it would bare.

## The contract

| Verb | stdin | stdout | Does |
|---|---|---|---|
| `contract` | | `1` | |
| `check` | | | XPC ping (`xpc`) or `container ls` (`cli`); exit 0 if the daemon is reachable |
| `prepare` | envelope | | `container image pull <image>`; a host service gets its data dir |
| `exec-set` | envelope | ExecSet | the service as commands, per mode |

## Why XPC from Zig

The daemon listens on `com.apple.container.apiserver` over XPC, a C/block-based
macOS IPC mechanism with no Zig library. Zig's C interop builds the client from
scratch with no glue, including the Objective-C *block* that
`xpc_connection_set_event_handler` requires (`src/xpc_extern.zig`).

```
orchd ──envelope──> orchd-rootstock-apple ──XPC──> container-apiserver
                                          ──exec──> container CLI (image pull)
```

## Source layout

```
src/
├── main.zig         verbs: the contract, and the XPC runtime verbs the exec set calls
├── plugin.zig       the contract: envelope, modes, host and cli exec sets (+ tests)
├── exec_set.zig     the xpc exec set (+ tests)
├── xpc_extern.zig   raw XPC C declarations + Block ABI
├── xpc.zig          typed Connection / Message wrapper
├── client.zig       container-apiserver client
├── oci.zig          image config over XPC, and run
├── types.zig        Service and ExecSet
└── prepare.zig      image pull subprocess
```

## Build

```sh
zig build           # → zig-out/bin/orchd-rootstock-apple
zig build test
```

Requires Zig 0.17.1+, and macOS 26+ with Apple's `container` installed to run.
