# orchd-osx

A from-scratch Apple container runtime for orchd, built on
**Virtualization.framework** with no container daemon and no Swift linked. It is
the third operating mode of the `apple` runtime:

| Mode | `ORCHD_APPLE_MODE` | Backend | Status |
|------|--------------------|---------|--------|
| 1 | `container` / `cli` | shell out to Apple's `container` CLI | works |
| 2 | `xpc` / `daemon` (default) | `orchd-apple`: drive the pinned daemon over XPC | works |
| 3 | `osx` / `vz` | `orchd-osx`: this runtime | **works** |

All three turn a container Service into the same `ExecSet` contract. The Rust
`apple` runtime (`src/runtime/apple.rs`) is a thin envelope that selects one.
Modes 2 and 3 are the same code path from Rust's side: spawn a co-process that
speaks a small JSON-over-stdio protocol.

## Why this exists

The XPC path (mode 2) works but depends on Apple's `container` daemon running.
orchd-osx removes that dependency entirely: we own the whole stack in Zig and
reuse nothing from the daemon. The only external artifact is a pinned Linux
kernel (macOS ships none); the guest init, wire protocol, image pull, and
rootfs are all ours.

The host layer is an Objective-C framework that non-Swift languages already
drive in production (Go's Code-Hex/vz, vfkit used by podman-machine and
minikube), so driving it from Zig (which we already do for XPC) is known ground:

```
[host, macOS]                          [guest, Linux VM]
Virtualization.framework  ── vsock ──  our init (PID 1, Zig static binary)
  driven via objc_msgSend                length-prefixed protocol (no gRPC):
  boots: kernel + cpio initramfs         exec / stdout / stderr / exit / ipinfo
```

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
in Zig is more work up front but keeps a single binary and no Swift.

## How it works

A container runs entirely on our own stack, no daemon:

1. **pull** (`oci.zig`) — fetch the image from any OCI registry. Registry HTTP
   goes through `curl` (the OS TLS stack + system CAs; Zig 0.16 std TLS fails
   against real CDNs). Generic Bearer auth via the `WWW-Authenticate` challenge,
   so docker.io, ghcr.io, public.ecr.aws, quay.io all work. Layers (gzip / zstd
   / plain tar) unpack into a rootfs, cached under `~/.orch/osx/images/<ref>` so
   an image is pulled at most once.
2. **rootfs** (`cpio.zig`) — pack the unpacked rootfs plus our guest init into a
   newc cpio initramfs. Correct-by-construction (no block-filesystem superblock
   to get subtly wrong); the kernel unpacks it to tmpfs and runs `/init`.
3. **boot** (`vm.zig`, via `objc.zig`) — build a `VZVirtualMachineConfiguration`
   (Linux boot loader + cpio initramfs + virtio block/console/vsock/entropy + a
   NAT network device), start it on a serial dispatch queue. `ip=dhcp` gives the
   container an IP from VZ's NAT.
4. **exec** (`vsock.zig` + `guest/init.zig`) — the guest init mounts /proc /sys
   /dev, reports its IP, and listens on vsock; the host connects, sends the
   process spec, the guest exec's it (PATH-resolved), streams stdout/stderr back,
   and reports the exit code.
5. **lifecycle** — `run` is the foreground process that owns the VM and blocks
   until the container exits. `stop` finds the run process via its pidfile and
   SIGTERMs it; the VM dies with the process (no orphan). `delete` removes the
   per-container state.

Service overrides (env / cmd / entrypoint / workdir) ride into `run` as a
base64 `--spec` blob and layer on the image defaults with Docker semantics.

Requirements: a pinned kernel asset (`kernel.zig`, see below) and the
`com.apple.security.virtualization` entitlement (ad-hoc codesign via
`scripts/sign.sh`).

See `STRESS_TEST_GROUND_0_OSX.md` for the load/robustness validation.

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
| `oci.zig` | Image ref -> local rootfs + config (entrypoint/cmd/env/cwd). curl pull, generic registry auth, gzip/zstd/tar layers, caching | registry/content | VMs, rootfs format |
| `cpio.zig` | rootfs dir + guest init -> newc cpio initramfs | filesystem | VMs, OCI |
| `kernel.zig` | Provide the path to our pinned kernel asset | our asset store | everything |

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

`exec-set` emits an ExecSet whose `start` is `orchd-osx run <name> <image>
--spec <b64>`. Because the VM lives inside the `run` process, `run` IS the
foreground process launchd tracks (it blocks until the container exits); there
is no separate `wait`. `stop` SIGTERMs the run process via its pidfile.

## Runtime requirements

- Apple silicon, macOS with Virtualization.framework.
- The `com.apple.security.virtualization` entitlement (codesign), same as the
  container daemon and vfkit.
- Our own pinned Linux kernel asset (we do NOT reuse the daemon's): a known-good
  aarch64 kernel with virtio_blk, virtio_console, vsock, and ext4 built in (=y),
  so no initramfs is needed. Resolved from `$ORCHD_OSX_KERNEL` or
  `~/.orch/osx/kernel/vmlinux` (see `kernel.zig`, pin `6.12-lts-aarch64-virtio`).
- Our guest init (`orchd-osx-init`) and ext4 rootfs are built by orchd-osx
  itself; nothing is taken from the container daemon.

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
