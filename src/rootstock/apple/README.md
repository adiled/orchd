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

`RECREATE never`, the default, keeps a stopped container and wakes it on the next
grow if its definition (image, command, env, mounts, limits) is unchanged; a
changed definition replaces it. `RECREATE always` replaces it on every grow and
deletes it on stop.

## The contract

| Verb | stdin | stdout | Does |
|---|---|---|---|
| `contract` | | `1 2` | |
| `check` | | | XPC ping (`xpc`) or `container ls` (`cli`); exit 0 if the daemon is reachable |
| `prepare` | envelope | | `container image pull <image>`; a host service gets its data dir |
| `exec-set` | envelope | ExecSet | the service as commands, per mode |
| `remove` | envelope | | delete the service's kept container |

## Why XPC from Zig

The daemon listens on `com.apple.container.apiserver` over XPC, a C/block-based
macOS IPC mechanism with no Zig library. Zig's C interop builds the client from
scratch with no glue, including the Objective-C *block* that
`xpc_connection_set_event_handler` requires (`xpc_extern.zig`).

```
orchd ──envelope──> orchd-rootstock-apple ──XPC──> container-apiserver
                                          ──exec──> container CLI (image pull)
```

## Source layout

```
src/rootstock/apple/
├── main.zig         verbs: the contract, and the XPC runtime verbs the exec set calls
├── plugin.zig       envelope to exec set: modes, host and cli exec sets, the definition
├── exec_set.zig     the xpc exec set
├── xpc_extern.zig   raw XPC C declarations + Block ABI
├── xpc.zig          typed Connection / Message wrapper
├── client.zig       container-apiserver client
├── oci.zig          image config over XPC, and run
└── prepare.zig      image pull subprocess
```

The envelope, Service and ExecSet come from the shared `contract` module
(`src/contract/`).

## Build

From the repository root, on macOS:

```sh
zig build           # → zig-out/bin/orchd-rootstock-apple, beside orchd
zig build test
```

Requires Zig 0.17.1+, and macOS 26+ with Apple's `container` installed to run.
