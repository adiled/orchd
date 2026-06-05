# Stress Test: Ground Zero (XPC)

End-to-end validation of the **full container lifecycle driven entirely over XPC**,
with no `container` CLI invoked at any point. The companion to
`STRESS_TEST_GROUND_0.md`, which covered the launchd supervisor path; this one
covers the from-scratch Zig XPC client talking directly to the pinned daemon.

## Environment

| Component | Version |
|-----------|---------|
| macOS | 26.2 (arm64) |
| Apple `container` daemon | 0.12.3 (pinned) |
| orchd-apple | Zig 0.16.0, hand-written XPC client |
| Container CLI calls | zero |

## What is driven over XPC

The whole lifecycle, across both of the daemon's XPC services:

```
run <id> <image>
  imageList              (core-images)  -> image descriptor
  contentGet x3          (core-images)  -> index -> manifest -> OCI config -> initProcess
  getDefaultKernel       (apiserver)    -> kernel
  containerCreate        (apiserver)    -> ContainerConfiguration
  containerBootstrap     (apiserver)    -> stdio FDs passed over XPC (xpc_fd_create)
  containerStartProcess  (apiserver)    -> live

list / stop / delete     (apiserver)    -> observe + control
```

Eleven XPC capabilities, two mach services
(`com.apple.container.apiserver` and `com.apple.container.core.container-core-images`),
no CLI anywhere.

## Single-container proof

```
orchd-apple run xpcrun docker.io/library/nginx:alpine
  -> started xpcrun via XPC
  -> list: ('xpcrun', 'running', ['192.168.64.7/24'])
  -> curl http://192.168.64.7 -> HTTP/1.1 200 OK, "Welcome to nginx!"
  -> stop + delete -> 0 containers left
```

## Stress results

All operations over XPC. nginx:alpine, on a real Mac.

| # | Scenario | Result |
|---|----------|--------|
| **G1** | Burst: 5 concurrent `run` (5 VMs in parallel) | 5 running, distinct IPs (.8 to .12) |
| **G2** | Serve-check all 5 | 5x HTTP 200 |
| **G3** | Concurrent `stop` + `delete` of all 5 | 0 left |
| **G4** | Rapid create -> teardown, 3 cycles | each cycle: 3 came up, 0 left after |
| **G5** | Chaos: `delete` while VMs still booting | 0 left, no orphans, no crash |

G5 is the nastiest: deleting containers mid-boot, while their lightweight VMs are
still starting. The XPC path converged to zero every time, the same no-orphan
robustness the launchd supervisor showed.

## Encoding lessons (why pinning is load-bearing)

The XPC wire protocol is private and differs between container versions. Every
struct was read at the exact installed tag (`git show 0.12.3:<file>`), not HEAD.
Three traps that only the pinned source revealed:

- **`ContainerStopOptions.signal` is `Int32` at 0.12.3** (a number, default 15),
  but `String?` at HEAD. Reading HEAD source produced a wrong payload that the
  daemon rejected.
- **`AttachmentConfiguration` requires `options.hostname`.** An empty network
  entry fails to decode.
- **The synthesized Swift decoder demands non-optional keys be present**, even at
  their default values (the `forceDelete` bool, the `signal` field, etc.). A
  Zig `setBool` that wrote a string instead of a real xpc bool silently no-opped
  `delete` until fixed with the real `xpc_dictionary_set_bool`.
- **Init process: `processIdentifier == containerId`** (the init process has no
  separate id).

Floating the version would break the protocol with no warning. Pinning is not
optional for this approach; it is the contract.

## What this proves

1. The container lifecycle can be driven entirely through the daemon's XPC
   interface from hand-written Zig. The `container` CLI is not required.
2. The from-scratch XPC client (including the Objective-C block ABI for the
   event handler and `xpc_fd_create` for stdio) is correct and complete enough
   for create, run, observe, and teardown.
3. It is robust under load: concurrent creates, concurrent teardown, rapid
   cycling, and mid-boot delete storms all converge clean with zero orphans.

## Known boundary

This validates the **client** side against an already-running, externally
installed daemon. Making orchd fully self-contained (vendoring and running its
own pinned `container-apiserver` so users install nothing) is a separate build
and code-signing effort. The client side, proven here, is the hard part and it
works.

## Reproduce

```sh
# prereq: pinned apple container daemon running, orchd-apple built (zig build)
APPLE=orchd-apple/zig-out/bin/orchd-apple

$APPLE run web docker.io/library/nginx:alpine     # create+bootstrap+start over XPC
$APPLE list                                        # structured snapshot (status, IP)
curl http://<ip>                                   # HTTP 200
$APPLE stop web && $APPLE delete web               # teardown over XPC
```
