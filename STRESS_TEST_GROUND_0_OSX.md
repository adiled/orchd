# Stress Test: Ground Zero (orchd-osx)

End-to-end validation of the **from-scratch Apple container runtime** built in
Zig on Virtualization.framework, with no daemon, no Swift, and no `container`
CLI anywhere. The companion to `STRESS_TEST_GROUND_0_XPC.md` (which drove the
pinned daemon over XPC); this one exercises orchd-osx, where we own the whole
stack: host VMM, guest init, wire protocol, image pull, and rootfs.

## Environment

| Component | Version |
|-----------|---------|
| macOS | 26.x (arm64) |
| orchd-osx | Zig 0.16, hand-written ObjC + vsock |
| Kernel | kata 6.18.28-194 arm64 (our pinned asset) |
| Daemon / Swift / container CLI | none |

## What is exercised

The whole runtime, per container:

```
pull   -> curl registry (OS TLS, generic Bearer auth) -> unpack layers -> cache
run    -> cpio initramfs (rootfs + our guest init) -> VZ boot (kernel + initrd)
       -> ip=dhcp (NAT) -> vsock connect -> exec the container process
       -> stream stdout/stderr -> exit code
stop   -> pidfile + SIGTERM -> the VM dies with the run process (no orphan)
```

## Single-container proof

```
orchd-osx run web public.ecr.aws/docker/library/nginx:alpine
  -> container ip 192.168.64.x
  -> curl http://192.168.64.x -> HTTP 200, "Welcome to nginx!"
orchd-osx stop web -> run process gone, container unreachable
```

## Under orchd (launchd)

```
orchd grow --runtime apple --platform launchd  (ORCHD_APPLE_MODE=osx)
  -> nginx container under launchd supervision, HTTP 200
orchd fell -> run process gone, container unreachable, launchd job removed
```

## Stress results

nginx:alpine (cached), on a real Mac. Each container is its own lightweight VM.

| # | Scenario | Result |
|---|----------|--------|
| **G1** | Burst: 4 concurrent `run` (4 VMs in parallel) | 4 running, distinct IPs (.13 to .16) |
| **G2** | Serve-check all 4 | 4x HTTP 200 |
| **G3** | `stop` all 4 (pidfile + SIGTERM) | 0 leftover processes |
| **G4** | Rapid cycle: 2 up + immediate stop, 3 rounds | each round: 0 leftover |
| **G5** | Chaos: `stop` 1s after launch (mid-boot) | 0 leftover, no orphans |

Final orphan sweep after all scenarios: **0** `orchd-osx run` processes.

G5 is the nastiest: stopping containers while their VMs are still booting (before
they serve). Because the VM is owned by the `run` process, SIGTERM exits the
process and the OS reclaims the VM atomically. There is no daemon holding state,
so there is nothing to orphan.

## Why this is robust by construction

The daemon model can leave orphaned VMs if the daemon and its bookkeeping
diverge. orchd-osx has no such gap: **one container = one process that owns one
VM.** Kill the process (stop, crash, launchd boot-out) and the VM goes with it.
The pidfile makes `stop` find the right process; everything else is the OS
reclaiming a child.

## What this proves

1. A real container runtime can be built from scratch in Zig on
   Virtualization.framework: pull, rootfs, boot, network, exec, teardown, all
   ours. No daemon, no Swift, no `container` CLI.
2. Real images run and serve over the network (nginx HTTP 200), pulled from any
   OCI registry (tested: Docker Hub and AWS ECR Public).
3. It is robust under load: concurrent creates, rapid cycling, and mid-boot stop
   storms all converge to zero orphans.
4. It integrates with orchd identically to the other runtimes: `grow` brings a
   container up under launchd, `fell` tears it down clean.

## Reproduce

```sh
APP=orchd-osx/zig-out/bin/orchd-osx
REF=public.ecr.aws/docker/library/nginx:alpine
$APP run web $REF &      # pull + boot + serve
curl http://<ip>          # HTTP 200 (ip printed as "container ip ...")
$APP stop web             # clean teardown, no orphan
```
