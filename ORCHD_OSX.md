# orchd-osx

A from-scratch Apple container runtime for orchd, built on
**Virtualization.framework** with no container daemon and no Swift linked. It is
the third operating mode of the `apple` runtime:

| Mode | `ORCHD_APPLE_MODE` | Backend | Status |
|------|--------------------|---------|--------|
| 1 | `container` / `cli` | shell out to Apple's `container` CLI | works |
| 2 | `xpc` / `daemon` (default) | `orchd-apple`: drive the pinned daemon over XPC | works |
| 3 | `osx` / `vz` | `orchd-osx`: this runtime | scaffold |

All three turn a container Service into the same `ExecSet` contract. The Rust
`apple` runtime (`src/runtime/apple.rs`) is a thin envelope that selects one.
Modes 2 and 3 are the same code path from Rust's side: spawn a co-process that
speaks a small JSON-over-stdio protocol. So orchd-osx is a drop-in that can be
built out independently without touching orchd-apple.

## Why this exists

The XPC path (mode 2) works but depends on Apple's `container` daemon running.
orchd-osx removes that dependency entirely: own the host side in Zig, reuse only
Apple's artifacts (the Linux kernel and the `vminitd` guest binary) as data.

This is feasible because the real architecture is a two-layer stack, and the
host layer is an Objective-C framework that non-Swift languages already drive in
production (Go's Code-Hex/vz, vfkit used by podman-machine and minikube):

```
[host, macOS]                          [guest, Linux VM]
Virtualization.framework  ── vsock ──  vminitd (PID 1, gRPC server)
  driven via objc_msgSend                process/exec/wait/kill/IO/mount
  boots: kernel + ext4 rootfs
```

We already drive Objective-C from Zig (the XPC client hand-builds the ObjC Block
ABI), so the host side is known ground, not a leap.

### Why not link the `containerization` Swift package directly

Considered and rejected. Swift's stable ABI is Swift-to-Swift only; its general
API (async/await, structs, Codable) is not C-callable. Bridging needs a Swift
`@_cdecl` shim, which:

- cannot produce a static binary on macOS (the Swift runtime ships with the OS
  and Darwin routes syscalls through `libsystem.dylib`),
- drags the whole Swift toolchain + grpc-swift + NIO + protobuf into the build,
- rests on `@_cdecl` (functions only, no async) plus a fragile async-to-sync
  bridge.

For a minimal-dependency Zig project that inverts the ethos. Owning the host VMM
in Zig is more work up front but keeps a single static binary and no Swift.

## Build-out order

Each step is independently testable. The entry points already exist and stub
honestly (`vz.zig` returns `NotImplemented`); fill them in order.

1. **objc.zig** — Objective-C runtime helpers: class lookup, `objc_msgSend`
   shims, autorelease. Reuse the patterns from orchd-apple's XPC client.
2. **Boot a bare VM** — `VZVirtualMachineConfiguration` with a
   `VZLinuxBootLoader` (kernel), a memory/CPU config, and a
   `VZVirtioSocketDevice`. Start it; confirm it boots.
3. **vsock.zig** — a minimal gRPC-over-vsock client to vminitd (single HTTP/2
   connection + a protobuf codec for just the messages we use). Goal: exec
   `echo` inside the guest and read its output. This is the long pole; size it
   first by pulling vminitd's `.proto` from `apple/containerization`.
4. **ext4.zig** — OCI image to ext4 rootfs. Reuse the daemon's prepared
   artifacts first (fastest path to a running container); own the builder later
   for full independence (parity with `ContainerizationEXT4`).
5. **Lifecycle** — wire create / wait / stop / delete in `vz.zig` and remove the
   stubs in `main.zig`.

## Module boundaries

One job per module. Boundaries are contracts: a module knows only the layer
directly below it, never reaches past it. The unsafe and the OS-specific are
contained, so the rest is plain testable Zig.

Host side (orchd-osx binary, macOS):

| Module | Single responsibility | Knows about | Never touches |
|--------|-----------------------|-------------|---------------|
| `main.zig` | CLI dispatch + the JSON-over-stdio protocol with orchd | types, exec_set, vz facade | objc, VZ, sockets |
| `types.zig` | Data shapes mirroring orch (Service, ExecSet). Pure data | nothing | everything |
| `exec_set.zig` | Pure transform Service -> ExecSet. No side effects | types | everything else |
| `vz.zig` | Backend facade: the lifecycle verbs (prepare/run/wait/stop/delete). Composes the layers below | oci, ext4, vm, vsock | objc directly |
| `objc.zig` | THE ONLY place that calls the Objective-C runtime: class lookup, msgSend shims, blocks, autorelease | C ABI / libobjc | VZ semantics |
| `vm.zig` | Build VZVirtualMachineConfiguration, boot/stop a VM, hand back the vsock connection fd. async->sync via dispatch_semaphore | objc, kernel | containers, OCI, protocol |
| `vsock.zig` | Host end of our wire protocol over the connection fd | proto, an fd | VZ, objc |
| `proto.zig` | The host<->guest wire format (message types, framing). Single source of truth, shared with the guest | nothing | everything |
| `oci.zig` | Image ref -> local rootfs + config (entrypoint/env/cwd) | registry/content | VMs, ext4 layout |
| `ext4.zig` | rootfs dir -> ext4 image file | filesystem | VMs, OCI |
| `kernel.zig` | Provide the path to our kernel asset | our asset store | everything |

Guest side (separate static aarch64-linux binary):

| Module | Single responsibility |
|--------|-----------------------|
| `guest/init.zig` | PID 1: mount rootfs, listen on vsock, exec the container process per the host's spec, stream stdio, reap, report exit |
| `proto.zig` (shared) | Same wire contract as the host imports |

The key containment boundaries:
- **`objc.zig`** is the FFI airlock: unsafe `objc_msgSend` in, typed Zig out.
  Nobody else calls the runtime.
- **`proto.zig`** is the host<->guest contract: both ends compile the same file,
  so the wire can never drift.
- **`vz.zig`** is the facade orchd-osx presents upward; `main.zig` is the
  contract with orchd. Neither leaks the layers beneath.

## Protocol (the contract with the Rust envelope)

```
orchd-osx check                 -- exit 0 if the VZ backend is usable
orchd-osx exec-set <namespace>  -- stdin: Service JSON -> stdout: ExecSet JSON
orchd-osx prepare  <namespace>  -- stdin: Service JSON, fetch/prepare rootfs
orchd-osx cleanup  <namespace>  -- stdin: Service JSON, tear down
orchd-osx pull   <image>        -- fetch an image
orchd-osx run    <name> <image> -- create+boot a VM, start the container
orchd-osx wait   <name>         -- block until the container exits (foreground)
orchd-osx stop   <name>         -- graceful stop
orchd-osx delete <name>         -- remove
```

`exec-set` emits an ExecSet whose `start` is
`orchd-osx run <name> <image> && orchd-osx wait <name>`, so the launchd
supervisor runs the container in the foreground (run starts it, wait blocks
while it lives), exactly like the XPC path.

## Runtime requirements

- Apple silicon, macOS with Virtualization.framework.
- The `com.apple.security.virtualization` entitlement (codesign), same as the
  container daemon and vfkit.
- A Linux kernel (>= 6.14.9) and the vminitd guest binary. Reuse the daemon's
  fetched artifacts during build-out.

## Build

```sh
cd orchd-osx && zig build           # binary at zig-out/bin/orchd-osx
zig build test                      # exec-set unit tests
```

## Scouted: the boot contract (step 0)

Building blocks come from ONE pre-installed source, Virtualization.framework
(full ObjC API in the SDK headers). Everything inside the VM is ours. We reuse
nothing from the container daemon.

Minimal headless Linux boot, with the exact selectors `objc.zig` must call:

- `VZLinuxBootLoader` — `initWithKernelURL:`, `.commandLine` (kernel cmdline),
  `.initialRamdiskURL` is **nullable**, so an initramfs is optional. We boot
  kernel + ext4 rootfs directly with `init=/orchd-init`.
- Root disk — `VZDiskImageStorageDeviceAttachment initWithURL:readOnly:error:`
  -> `VZVirtioBlockDeviceConfiguration initWithAttachment:`. Our ext4 file
  appears as `/dev/vda` (cmdline `root=/dev/vda rw`).
- vsock — `VZVirtioSocketDeviceConfiguration` (plain init) on the config; after
  start, `vm.socketDevices[0]` is a `VZVirtioSocketDevice`.
- **Host<->guest pipe** — `connectToPort:completionHandler:` returns a
  `VZVirtioSocketConnection` exposing a raw `fileDescriptor` (int). We read/write
  bytes on that fd directly. **No gRPC, no HTTP/2, no protobuf** — our own
  length-prefixed protocol (our init listens on a vsock port; host connects).
- VM config — `VZVirtualMachineConfiguration`: set `bootLoader`, `CPUCount`,
  `memorySize`, `storageDevices`, `socketDevices`, `serialPorts` (console logs),
  `entropyDevices` (virtio-rng for boot); then `validateWithError:`.
- Run — `VZVirtualMachine initWithConfiguration:queue:` (a serial
  `dispatch_queue`), then `startWithCompletionHandler:`.

Async to sync: `startWithCompletionHandler:` and `connectToPort:` take ObjC
completion blocks. We already build ObjC blocks from Zig (the XPC client), and we
own this co-process, so we wrap each in a `dispatch_semaphore` and block until
done. No event loop, no Swift concurrency.

The one external artifact: a Linux kernel (raw arm64 `Image`). macOS ships none;
orchd-osx supplies its own (task: provide our own kernel asset). Everything else
(guest init, vsock protocol, ext4 rootfs) we build.
